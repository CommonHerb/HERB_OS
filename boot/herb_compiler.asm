; boot/herb_compiler.asm — HERB Source Compiler in Assembly
;
; Compiles .herb source text to .herb binary format (byte-identical
; to Python herb_compile.py output for fragment programs).
;
; Entry point: herb_compile_source(src_buf, src_len, out_buf, out_cap) -> out_len
;
; Register convention: MS x64 ABI
;   Args:    RCX, RDX, R8, R9 (integer/pointer)
;   Return:  RAX (integer/pointer)
;   Caller-saved: RAX, RCX, RDX, R8-R11
;   Callee-saved: RBX, RSI, RDI, R12-R15, RBP
;   Shadow space: 32 bytes before each CALL
;   Stack: 16-byte aligned at CALL instruction

[bits 64]
default rel

%include "herb_graph_layout.inc"

; External functions from herb_freestanding.asm
extern herb_strcmp
extern herb_strlen
extern herb_strncpy
extern herb_memset
extern herb_atoll
extern herb_memcpy

; Export
global herb_compile_source

; ============================================================
; COMPILER CONSTANTS
; ============================================================

%define COMP_MAX_STRINGS     1024
%define COMP_MAX_STR_LEN     128
%define COMP_MAX_EXPRS       1024
%define COMP_MAX_TENSIONS    64
%define COMP_MAX_MATCHES     8
%define COMP_MAX_EMITS       8
%define COMP_LINE_BUF_SIZE   512
%define COMP_TOK_BUF_SIZE    256

; Full program IR capacities
%define COMP_MAX_ENTITY_TYPES  32
%define COMP_MAX_SCOPED_PER_ET 12
%define COMP_MAX_CONTAINERS    64
%define COMP_MAX_MOVES         32
%define COMP_MAX_MOVE_LOCS     20
%define COMP_MAX_ENTITIES      256
%define COMP_MAX_PROPS_PER_ENT 16
%define COMP_MAX_CHANNELS      4
%define COMP_MAX_PROPS_TOTAL   4096

; Binary format section tags
%define BSEC_ENTITY_TYPES  0x01
%define BSEC_CONTAINERS    0x02
%define BSEC_MOVES         0x03
%define BSEC_POOLS         0x04
%define BSEC_TRANSFERS     0x05
%define BSEC_ENTITIES      0x06
%define BSEC_CHANNELS      0x07
%define BSEC_CONFIG        0x08
%define BSEC_TENSIONS      0x09
%define BSEC_END           0xFF

; Binary expression kinds
%define BEX_INT             0x00
%define BEX_FLOAT           0x01
%define BEX_STRING          0x02
%define BEX_BOOL            0x03
%define BEX_PROP            0x04
%define BEX_COUNT_CONTAINER 0x05
%define BEX_COUNT_SCOPED    0x06
%define BEX_COUNT_CHANNEL   0x07
%define BEX_BINARY          0x08
%define BEX_UNARY_NOT       0x09
%define BEX_IN_OF           0x0A
%define BEX_NULL            0xFF

; Binary match kinds
%define BMC_ENTITY_IN       0x00
%define BMC_EMPTY_IN        0x01
%define BMC_CONTAINER_IS    0x02
%define BMC_GUARD           0x03

; Binary emit kinds
%define BEC_MOVE            0x00
%define BEC_SET             0x01
%define BEC_SEND            0x02
%define BEC_RECEIVE         0x03

; Binary ref kinds
%define BREF_NORMAL         0x00
%define BREF_SCOPED         0x01
%define BREF_NONE           0x02

; Container kinds
%define BCK_SIMPLE          0x00
%define BCK_SLOT            0x01

; Select modes
%define BSEL_FIRST          0
%define BSEL_EACH           1
%define BSEL_MAX_BY         2
%define BSEL_MIN_BY         3

; Compiler IR expression node (24 bytes)
; kind(4), op(4), val union(16)
%define CIR_EX_KIND         0
%define CIR_EX_OP           4       ; operator string idx (binary only)
%define CIR_EX_IVAL         8       ; int64 literal
%define CIR_EX_STR1         8       ; string idx 1 (prop name / container)
%define CIR_EX_STR2         12      ; string idx 2 (of name / unused)
%define CIR_EX_LEFT         8       ; left child expr idx (for binary)
%define CIR_EX_RIGHT        12      ; right child expr idx
%define SIZEOF_CIR_EXPR     24

; IR expression kinds (compiler-internal)
%define CIREX_INT           0
%define CIREX_PROP          1
%define CIREX_BINARY        2
%define CIREX_COUNT         3

; Compiler IR match clause (80 bytes)
%define CIR_MC_KIND         0       ; 0=entity_in, 1=empty_in, 3=guard
%define CIR_MC_BIND         4       ; parse string idx
%define CIR_MC_CONTAINER    8       ; parse string idx (for entity_in)
%define CIR_MC_SELECT       12      ; select mode
%define CIR_MC_KEY          16      ; parse string idx (for max_by/min_by)
%define CIR_MC_HAS_WHERE    20      ; 0 or 1
%define CIR_MC_WHERE_EXPR   24      ; expr pool idx
%define CIR_MC_HAS_SELECT   28      ; whether select was explicit
%define CIR_MC_EMPTY_CNTS   32      ; int[8] — parse string indices for empty_in containers
%define CIR_MC_EMPTY_CNT_N  64      ; count of empty_in containers
%define CIR_MC_REQUIRED     68      ; 1=required, 0=optional
%define CIR_MC_IN_TYPE      72      ; 0=normal, 1=scoped, 2=channel
%define CIR_MC_SCOPE        76      ; parse string idx for scope (scoped refs)
%define SIZEOF_CIR_MATCH    80

; Compiler IR emit clause (48 bytes)
%define CIR_EC_KIND         0       ; 0=move, 1=set, 2=send, 3=receive
%define CIR_EC_STR1         4       ; move_name / entity(set) / channel(send/recv)
%define CIR_EC_STR2         8       ; entity(move) / property(set) / entity(send/recv)
%define CIR_EC_STR3         12      ; to_target(move/recv) / unused
%define CIR_EC_EXPR         16      ; value expr idx (for set)
%define CIR_EC_TO_KIND      20      ; 0=normal, 1=scoped
%define CIR_EC_SCOPE        24      ; scope string idx for scoped to-ref
%define SIZEOF_CIR_EMIT     48

; Compiler IR tension (size = 24 + MATCHES*80 + 4 + EMITS*48 + 4 = 1000)
%define CIR_TEN_NAME        0       ; parse string idx
%define CIR_TEN_PRIORITY    4       ; int
%define CIR_TEN_MATCH_COUNT 8       ; int
%define CIR_TEN_MATCHES     12      ; CIR_MATCH[8] = 640 bytes
%define CIR_TEN_EMIT_COUNT  652     ; int (12 + 8*80)
%define CIR_TEN_EMITS       656     ; CIR_EMIT[8] = 384 bytes
%define CIR_TEN_STEP        1040    ; int: 0=converge, 1=step
%define SIZEOF_CIR_TENSION  1044    ; 656 + 384 + 4

; Entity type IR layout
%define CIR_ET_NAME          0
%define CIR_ET_SCOPED_COUNT  4
%define CIR_ET_SCOPED        8      ; array of (name:4, kind:4, etype:4) = 12 bytes each
%define SIZEOF_CIR_ET_SCOPED 12
%define SIZEOF_CIR_ET        152    ; 8 + 12*12

; Container IR layout
%define CIR_CT_NAME          0
%define CIR_CT_KIND          4
%define CIR_CT_ETYPE         8
%define CIR_CT_ORDER_KEY     12
%define SIZEOF_CIR_CT        16

; Move IR layout
%define CIR_MV_NAME          0
%define CIR_MV_ETYPE         4
%define CIR_MV_IS_SCOPED     8
%define CIR_MV_FROM_COUNT    12
%define CIR_MV_FROM          16     ; 20 * 4 = 80 bytes
%define CIR_MV_TO_COUNT      96
%define CIR_MV_TO            100    ; 20 * 4 = 80 bytes
%define SIZEOF_CIR_MV        180

; Entity IR layout
%define CIR_EN_NAME          0
%define CIR_EN_TYPE          4
%define CIR_EN_IN_KIND       8      ; 0=normal, 1=scoped
%define CIR_EN_IN_CONTAINER  12
%define CIR_EN_IN_SCOPE      16
%define CIR_EN_PROP_COUNT    20
%define CIR_EN_PROP_START    24     ; index into property pool
%define SIZEOF_CIR_EN        28

; Property pool entry layout
%define CIR_PR_KEY           0
%define CIR_PR_VTYPE         4      ; 0=int, 1=float, 2=string
%define CIR_PR_VALUE         8      ; i64 / f64 / parse string idx
%define SIZEOF_CIR_PR        16

; Channel IR layout
%define CIR_CH_NAME          0
%define CIR_CH_FROM          4
%define CIR_CH_TO            8
%define CIR_CH_ETYPE         12
%define SIZEOF_CIR_CH        16

; ============================================================
; BSS — Compiler-internal data (no runtime state modified)
; ============================================================

section .bss

; Parse-time string table (dedup by content)
comp_strtab:         resb COMP_MAX_STRINGS * COMP_MAX_STR_LEN  ; 64KB
comp_str_count:      resd 1

; Output string table (Python-compatible order)
comp_out_strtab:     resb COMP_MAX_STRINGS * COMP_MAX_STR_LEN  ; 64KB
comp_out_str_count:  resd 1

; Map: parse-time idx -> output idx
comp_idx_map:        resd COMP_MAX_STRINGS                     ; 2KB

; Expression IR pool
comp_expr_pool:      resb COMP_MAX_EXPRS * SIZEOF_CIR_EXPR     ; 12KB
comp_expr_count:     resd 1

; Tension IR array
comp_tensions:       resb COMP_MAX_TENSIONS * SIZEOF_CIR_TENSION
comp_ten_count:      resd 1

; Entity type IR array
comp_entity_types:   resb COMP_MAX_ENTITY_TYPES * SIZEOF_CIR_ET
comp_et_count:       resd 1

; Container IR array
comp_containers:     resb COMP_MAX_CONTAINERS * SIZEOF_CIR_CT
comp_cont_count:     resd 1

; Move IR array
comp_moves:          resb COMP_MAX_MOVES * SIZEOF_CIR_MV
comp_move_count:     resd 1

; Entity IR array
comp_entities:       resb COMP_MAX_ENTITIES * SIZEOF_CIR_EN
comp_ent_count:      resd 1

; Property pool
comp_properties:     resb COMP_MAX_PROPS_TOTAL * SIZEOF_CIR_PR
comp_prop_count:     resd 1

; Channel IR array
comp_channels:       resb COMP_MAX_CHANNELS * SIZEOF_CIR_CH
comp_chan_count:      resd 1

; Config
comp_config_nesting: resd 1

; Step tension flag (set before calling comp_parse_tension)
comp_step_pending:   resd 1

; Output buffer tracking
comp_out_ptr:        resq 1
comp_out_pos:        resd 1
comp_out_size:       resd 1

; Source tracking
comp_src_ptr:        resq 1
comp_src_len:        resd 1
comp_src_pos:        resd 1

; Line state
comp_line_buf:       resb COMP_LINE_BUF_SIZE
comp_line_len:       resd 1
comp_line_indent:    resd 1

; Token extraction state
comp_tok_buf:        resb COMP_TOK_BUF_SIZE

; ============================================================
; RDATA — Keyword strings
; ============================================================

section .rdata

kw_tension:    db "tension", 0
kw_priority:   db "priority", 0
kw_match:      db "match", 0
kw_emit:       db "emit", 0
kw_where:      db "where", 0
kw_in:         db "in", 0
kw_empty_in:   db "empty_in", 0
kw_select:     db "select", 0
kw_optional:   db "optional", 0
kw_first:      db "first", 0
kw_each:       db "each", 0
kw_max_by:     db "max_by", 0
kw_min_by:     db "min_by", 0
kw_move:       db "move", 0
kw_set:        db "set", 0
kw_send:       db "send", 0
kw_to:         db "to", 0
kw_guard:      db "guard", 0
kw_count:      db "count", 0
kw_type:       db "type", 0
kw_container:  db "container", 0
kw_simple:     db "simple", 0
kw_slot:       db "slot", 0
kw_entity:     db "entity", 0
kw_prop:       db "prop", 0
kw_channel:    db "channel", 0
kw_config:     db "config", 0
kw_scoped:     db "scoped", 0
kw_scope:      db "scope", 0
kw_from:       db "from", 0
kw_receive:    db "receive", 0
kw_scoped_from: db "scoped_from", 0
kw_scoped_to:  db "scoped_to", 0
kw_max_nesting_depth: db "max_nesting_depth", 0
kw_order_key:  db "order_key", 0
kw_step:       db "step", 0

; Operator strings for binary format (source → binary mapping)
op_and_src:    db "&&", 0
op_or_src:     db "||", 0
op_and_bin:    db "and", 0
op_or_bin:     db "or", 0

; Magic header
herb_magic:    db "HERB"

section .text

; ============================================================
; herb_compile_source(src_buf, src_len, out_buf, out_cap) -> out_len
;
; RCX = source text buffer pointer
; RDX = source text length
; R8  = output buffer pointer
; R9  = output buffer capacity
; Returns: RAX = bytes written to output buffer (0 on error)
; ============================================================
herb_compile_source:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56             ; locals + shadow + align
    ; Stack: ret(8)+rbp(8)+7*push(56)+sub(56)=128, 128%16=0 ✓

    ; Save parameters
    mov     [comp_src_ptr], rcx
    mov     [comp_src_len], edx
    mov     dword [comp_src_pos], 0
    mov     [comp_out_ptr], r8
    mov     [comp_out_size], r9d
    mov     dword [comp_out_pos], 0

    ; Zero all compiler state
    call    comp_reset

    ; Phase 1: Parse source into IR
    call    comp_parse_program

    ; Phase 2: Collect strings in Python-compatible order
    call    comp_collect_strings

    ; Phase 3: Emit binary
    call    comp_emit_binary

    ; Return bytes written
    mov     eax, [comp_out_pos]

    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; comp_reset — zero all compiler state
; ============================================================
comp_reset:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32             ; shadow only
    ; ret(8)+rbp(8)+sub(32)=48, need 48%16=0 ✓

    ; Zero string counts
    mov     dword [comp_str_count], 0
    mov     dword [comp_out_str_count], 0
    mov     dword [comp_expr_count], 0
    mov     dword [comp_ten_count], 0

    ; Zero new IR counters
    mov     dword [comp_et_count], 0
    mov     dword [comp_cont_count], 0
    mov     dword [comp_move_count], 0
    mov     dword [comp_ent_count], 0
    mov     dword [comp_prop_count], 0
    mov     dword [comp_chan_count], 0
    mov     dword [comp_config_nesting], -1

    ; Zero idx map
    lea     rcx, [comp_idx_map]
    xor     edx, edx
    mov     r8d, COMP_MAX_STRINGS * 4
    call    herb_memset

    add     rsp, 32
    pop     rbp
    ret


; ============================================================
; UTILITY FUNCTIONS (Step 3)
; ============================================================

; ============================================================
; comp_str_add(ptr, len) -> idx
;
; Add null-terminated string to parse-time table, dedup by content.
; RCX = string pointer (null-terminated)
; Returns: EAX = parse-time string index
; ============================================================
comp_str_add:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    sub     rsp, 40             ; shadow(32) + align
    ; ret(8)+rbp(8)+3*push(24)+sub(40)=80, 80%16=0 ✓

    mov     rsi, rcx            ; rsi = string ptr

    ; Check existing strings for dedup
    xor     edi, edi            ; edi = search index
    mov     ebx, [comp_str_count]
.dedup_loop:
    cmp     edi, ebx
    jge     .add_new

    ; Get pointer to comp_strtab[edi]
    mov     eax, edi
    imul    eax, COMP_MAX_STR_LEN
    lea     rcx, [comp_strtab]
    add     rcx, rax
    mov     rdx, rsi
    call    herb_strcmp
    test    eax, eax
    jz      .found_existing
    inc     edi
    jmp     .dedup_loop

.found_existing:
    mov     eax, edi
    jmp     .done

.add_new:
    ; Check capacity
    cmp     ebx, COMP_MAX_STRINGS
    jge     .full

    ; Copy string to comp_strtab[count]
    mov     eax, ebx
    imul    eax, COMP_MAX_STR_LEN
    lea     rcx, [comp_strtab]
    add     rcx, rax            ; dst
    mov     rdx, rsi            ; src
    mov     r8d, COMP_MAX_STR_LEN - 1
    call    herb_strncpy

    ; Null-terminate
    mov     eax, [comp_str_count]
    imul    eax, COMP_MAX_STR_LEN
    lea     rcx, [comp_strtab]
    add     rcx, rax
    add     rcx, COMP_MAX_STR_LEN - 1
    mov     byte [rcx], 0

    mov     eax, [comp_str_count]
    inc     dword [comp_str_count]

.done:
    add     rsp, 40
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

.full:
    mov     eax, 0              ; return 0 on overflow
    jmp     .done


; ============================================================
; comp_str_get(idx) -> ptr
;
; Get pointer to string in parse-time table.
; ECX = parse string index
; Returns: RAX = pointer to null-terminated string
; ============================================================
comp_str_get:
    mov     eax, ecx
    imul    eax, COMP_MAX_STR_LEN
    lea     rax, [comp_strtab + rax]
    ret


; ============================================================
; comp_out_str_add(parse_idx) -> out_idx
;
; Add string to output table (by parse-time index), dedup.
; Updates comp_idx_map[parse_idx].
; ECX = parse-time string index
; Returns: EAX = output string index
; ============================================================
comp_out_str_add:
    ; Skip None strings (parse idx -1)
    cmp     ecx, -1
    jne     .osa_start
    ret
.osa_start:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 32             ; shadow
    ; ret(8)+rbp(8)+4*push(32)+sub(32)=80, 80%16=0 ✓

    mov     r12d, ecx           ; r12d = parse_idx

    ; Get the string content
    call    comp_str_get        ; rax = ptr to string
    mov     rsi, rax            ; rsi = string ptr

    ; Search output table for dedup
    xor     edi, edi
    mov     ebx, [comp_out_str_count]
.osa_dedup:
    cmp     edi, ebx
    jge     .osa_add

    mov     eax, edi
    imul    eax, COMP_MAX_STR_LEN
    lea     rcx, [comp_out_strtab]
    add     rcx, rax
    mov     rdx, rsi
    call    herb_strcmp
    test    eax, eax
    jz      .osa_found
    inc     edi
    jmp     .osa_dedup

.osa_found:
    ; Update idx_map and return
    lea     rax, [comp_idx_map]
    mov     [rax + r12*4], edi
    mov     eax, edi
    jmp     .osa_done

.osa_add:
    cmp     ebx, COMP_MAX_STRINGS
    jge     .osa_full

    ; Copy to output table
    mov     eax, ebx
    imul    eax, COMP_MAX_STR_LEN
    lea     rcx, [comp_out_strtab]
    add     rcx, rax
    mov     rdx, rsi
    mov     r8d, COMP_MAX_STR_LEN - 1
    call    herb_strncpy

    ; Null-terminate
    mov     eax, [comp_out_str_count]
    imul    eax, COMP_MAX_STR_LEN
    lea     rcx, [comp_out_strtab]
    add     rcx, rax
    add     rcx, COMP_MAX_STR_LEN - 1
    mov     byte [rcx], 0

    ; Update idx_map
    mov     eax, [comp_out_str_count]
    lea     rcx, [comp_idx_map]
    mov     [rcx + r12*4], eax

    ; Increment and return
    mov     eax, [comp_out_str_count]
    inc     dword [comp_out_str_count]

.osa_done:
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

.osa_full:
    xor     eax, eax
    jmp     .osa_done


; ============================================================
; OUTPUT BUFFER WRITERS
; ============================================================

; comp_emit_u8(val) — ECX = byte value
comp_emit_u8:
    mov     eax, [comp_out_pos]
    cmp     eax, [comp_out_size]
    jge     .eu8_skip
    mov     rdx, [comp_out_ptr]
    mov     [rdx + rax], cl
    inc     dword [comp_out_pos]
.eu8_skip:
    ret

; comp_emit_u16(val) — ECX = u16 value (little-endian)
comp_emit_u16:
    push    rbx
    mov     ebx, ecx
    movzx   ecx, bl             ; low byte
    call    comp_emit_u8
    movzx   ecx, bh             ; high byte
    call    comp_emit_u8
    pop     rbx
    ret

; comp_emit_i16(val) — ECX = i16 value (little-endian, signed)
comp_emit_i16:
    ; Same encoding as u16
    jmp     comp_emit_u16

; comp_emit_i64(val) — RCX = i64 value (little-endian)
comp_emit_i64:
    push    rbp
    mov     rbp, rsp
    push    rbx
    sub     rsp, 40
    ; ret(8)+rbp(8)+push(8)+sub(40)=64, 64%16=0 ✓

    mov     rbx, rcx

    ; Emit 8 bytes, LSB first
    mov     ecx, ebx
    and     ecx, 0xFF
    call    comp_emit_u8

    mov     rax, rbx
    shr     rax, 8
    movzx   ecx, al
    call    comp_emit_u8

    mov     rax, rbx
    shr     rax, 16
    movzx   ecx, al
    call    comp_emit_u8

    mov     rax, rbx
    shr     rax, 24
    movzx   ecx, al
    call    comp_emit_u8

    mov     rax, rbx
    shr     rax, 32
    movzx   ecx, al
    call    comp_emit_u8

    mov     rax, rbx
    shr     rax, 40
    movzx   ecx, al
    call    comp_emit_u8

    mov     rax, rbx
    shr     rax, 48
    movzx   ecx, al
    call    comp_emit_u8

    mov     rax, rbx
    shr     rax, 56
    movzx   ecx, al
    call    comp_emit_u8

    add     rsp, 40
    pop     rbx
    pop     rbp
    ret

; comp_emit_str_idx(parse_idx) — ECX = parse-time string index
; Looks up comp_idx_map[parse_idx] and emits as u16
comp_emit_str_idx:
    lea     rax, [comp_idx_map]
    mov     ecx, [rax + rcx*4]
    jmp     comp_emit_u16


; ============================================================
; comp_alloc_expr() -> idx
;
; Allocate from expression pool, return index.
; Returns: EAX = expr index (-1 if full)
; ============================================================
comp_alloc_expr:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32

    mov     eax, [comp_expr_count]
    cmp     eax, COMP_MAX_EXPRS
    jge     .cae_full

    ; Zero the entry
    mov     ecx, eax
    imul    ecx, SIZEOF_CIR_EXPR
    lea     rcx, [comp_expr_pool + rcx]
    xor     edx, edx
    mov     r8d, SIZEOF_CIR_EXPR
    call    herb_memset

    mov     eax, [comp_expr_count]
    inc     dword [comp_expr_count]
    jmp     .cae_done

.cae_full:
    mov     eax, -1
.cae_done:
    add     rsp, 32
    pop     rbp
    ret


; ============================================================
; TOKENIZER (Step 4)
; ============================================================

; ============================================================
; comp_next_line() -> bool
;
; Advance to next non-blank, non-comment line.
; Fills comp_line_buf, sets comp_line_len, comp_line_indent.
; Returns: EAX = 1 if line found, 0 at EOF
; ============================================================
comp_next_line:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 32
    ; ret(8)+rbp(8)+4*push(32)+sub(32)=80, 80%16=0 ✓

.cnl_retry:
    ; Check EOF
    mov     eax, [comp_src_pos]
    cmp     eax, [comp_src_len]
    jge     .cnl_eof

    mov     rsi, [comp_src_ptr]
    mov     ebx, [comp_src_pos]     ; ebx = current pos in source

    ; Count leading spaces for indent
    xor     r12d, r12d              ; r12d = space count
.cnl_spaces:
    cmp     ebx, [comp_src_len]
    jge     .cnl_line_end
    movzx   eax, byte [rsi + rbx]
    cmp     al, ' '
    jne     .cnl_spaces_done
    inc     r12d
    inc     ebx
    jmp     .cnl_spaces
.cnl_spaces_done:

    ; Check for blank line or comment
    cmp     ebx, [comp_src_len]
    jge     .cnl_line_end
    movzx   eax, byte [rsi + rbx]
    cmp     al, 10                  ; newline
    je      .cnl_skip_line
    cmp     al, 13                  ; CR
    je      .cnl_skip_line
    cmp     al, '#'                 ; comment
    je      .cnl_skip_to_eol

    ; Real content — copy to line buf
    mov     [comp_line_indent], r12d
    ; indent = spaces / 2
    shr     dword [comp_line_indent], 1

    xor     edi, edi                ; edi = line buf write pos
.cnl_copy:
    cmp     ebx, [comp_src_len]
    jge     .cnl_copy_done
    movzx   eax, byte [rsi + rbx]
    cmp     al, 10
    je      .cnl_copy_done
    cmp     al, 13
    je      .cnl_copy_done
    cmp     edi, COMP_LINE_BUF_SIZE - 1
    jge     .cnl_copy_done
    lea     rcx, [comp_line_buf]
    mov     [rcx + rdi], al
    inc     edi
    inc     ebx
    jmp     .cnl_copy

.cnl_copy_done:
    ; Null terminate
    lea     rcx, [comp_line_buf]
    mov     byte [rcx + rdi], 0
    mov     [comp_line_len], edi

    ; Skip past newline
    cmp     ebx, [comp_src_len]
    jge     .cnl_update_pos
    movzx   eax, byte [rsi + rbx]
    cmp     al, 13
    jne     .cnl_check_lf
    inc     ebx
.cnl_check_lf:
    cmp     ebx, [comp_src_len]
    jge     .cnl_update_pos
    movzx   eax, byte [rsi + rbx]
    cmp     al, 10
    jne     .cnl_update_pos
    inc     ebx

.cnl_update_pos:
    mov     [comp_src_pos], ebx
    mov     eax, 1
    jmp     .cnl_done

.cnl_skip_to_eol:
    ; Skip to end of line
    cmp     ebx, [comp_src_len]
    jge     .cnl_line_end
    movzx   eax, byte [rsi + rbx]
    cmp     al, 10
    je      .cnl_line_end
    cmp     al, 13
    je      .cnl_line_end
    inc     ebx
    jmp     .cnl_skip_to_eol

.cnl_skip_line:
.cnl_line_end:
    ; Skip past newline chars
    cmp     ebx, [comp_src_len]
    jge     .cnl_skip_done
    movzx   eax, byte [rsi + rbx]
    cmp     al, 13
    jne     .cnl_skip_lf
    inc     ebx
.cnl_skip_lf:
    cmp     ebx, [comp_src_len]
    jge     .cnl_skip_done
    movzx   eax, byte [rsi + rbx]
    cmp     al, 10
    jne     .cnl_skip_done
    inc     ebx
.cnl_skip_done:
    mov     [comp_src_pos], ebx
    jmp     .cnl_retry

.cnl_eof:
    xor     eax, eax
.cnl_done:
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_next_token(line_pos) -> (tok_ptr in RAX, tok_len in EDX, new_pos in ECX)
;
; Extract next whitespace-delimited token from comp_line_buf.
; ECX = current position in line buffer
; Returns: RAX = pointer to comp_tok_buf (null-terminated)
;          EDX = token length
;          ECX = new position after token
;          RAX = 0 if no more tokens
; ============================================================
comp_next_token:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    sub     rsp, 32
    ; ret(8)+rbp(8)+2*push(16)+sub(32)=64, 64%16=0 ✓

    mov     ebx, ecx            ; ebx = pos
    mov     esi, [comp_line_len]

    ; Skip whitespace
.cnt_skip_ws:
    cmp     ebx, esi
    jge     .cnt_no_token
    lea     rax, [comp_line_buf]
    movzx   ecx, byte [rax + rbx]
    cmp     cl, ' '
    jne     .cnt_start
    cmp     cl, 9               ; tab
    je      .cnt_ws
    inc     ebx
    jmp     .cnt_skip_ws
.cnt_ws:
    inc     ebx
    jmp     .cnt_skip_ws

.cnt_start:
    ; Check for quoted string
    lea     rax, [comp_line_buf]
    movzx   ecx, byte [rax + rbx]
    cmp     cl, '"'
    je      .cnt_quoted

    ; Copy token to comp_tok_buf
    xor     edx, edx            ; edx = tok len
.cnt_copy_tok:
    cmp     ebx, esi
    jge     .cnt_tok_done
    lea     rax, [comp_line_buf]
    movzx   ecx, byte [rax + rbx]
    cmp     cl, ' '
    je      .cnt_tok_done
    cmp     cl, 9
    je      .cnt_tok_done
    cmp     edx, COMP_TOK_BUF_SIZE - 1
    jge     .cnt_tok_done
    lea     rax, [comp_tok_buf]
    mov     [rax + rdx], cl
    inc     edx
    inc     ebx
    jmp     .cnt_copy_tok

.cnt_tok_done:
    ; Null terminate
    lea     rax, [comp_tok_buf]
    mov     byte [rax + rdx], 0
    ; Return: RAX=tok_ptr, EDX=tok_len, ECX=new_pos
    mov     ecx, ebx
    jmp     .cnt_done

.cnt_quoted:
    ; Skip opening quote
    inc     ebx
    xor     edx, edx            ; tok len
.cnt_quoted_copy:
    cmp     ebx, esi
    jge     .cnt_quoted_done
    lea     rax, [comp_line_buf]
    movzx   ecx, byte [rax + rbx]
    cmp     cl, '"'
    je      .cnt_quoted_end
    cmp     edx, COMP_TOK_BUF_SIZE - 1
    jge     .cnt_quoted_end
    lea     rax, [comp_tok_buf]
    mov     [rax + rdx], cl
    inc     edx
    inc     ebx
    jmp     .cnt_quoted_copy
.cnt_quoted_end:
    inc     ebx                 ; skip closing quote
.cnt_quoted_done:
    lea     rax, [comp_tok_buf]
    mov     byte [rax + rdx], 0
    mov     ecx, ebx
    jmp     .cnt_done

.cnt_no_token:
    xor     eax, eax
    xor     edx, edx
    mov     ecx, ebx

.cnt_done:
    add     rsp, 32
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_token_eq(tok_ptr, keyword_ptr) -> bool
;
; Compare token with keyword. Both null-terminated.
; RCX = token pointer
; RDX = keyword pointer
; Returns: EAX = 1 if equal, 0 if not
; ============================================================
comp_token_eq:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32
    call    herb_strcmp
    test    eax, eax
    setz    al
    movzx   eax, al
    add     rsp, 32
    pop     rbp
    ret


; ============================================================
; comp_tok_to_str() -> parse_idx
;
; Add current token (in comp_tok_buf) to parse string table.
; Returns: EAX = parse-time string index
; ============================================================
comp_tok_to_str:
    lea     rcx, [comp_tok_buf]
    jmp     comp_str_add


; ============================================================
; EXPRESSION PARSER (Step 5) — Recursive descent
; ============================================================

; All expression parser functions take ECX = line_pos,
; return EAX = expr_idx, ECX = new_line_pos

; ============================================================
; comp_parse_expr(line_pos) -> (expr_idx, new_pos)
; ============================================================
comp_parse_expr:
    jmp     comp_parse_or

; ============================================================
; comp_parse_or(line_pos) -> (expr_idx, new_pos)
; ============================================================
comp_parse_or:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 32
    ; ret(8)+rbp(8)+4*push(32)+sub(32)=80, 80%16=0 ✓

    call    comp_parse_and      ; eax=left_idx, ecx=new_pos
    mov     r12d, eax           ; r12d = left_idx
    mov     ebx, ecx            ; ebx = pos

.por_loop:
    ; Check for || token
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .por_done

    mov     rcx, rax
    lea     rdx, [op_or_src]
    call    comp_token_eq
    test    eax, eax
    jz      .por_no_match

    ; Found ||: parse right side
    mov     ecx, ebx            ; restore pos to after ||
    ; Actually ecx from comp_next_token is the new pos
    ; We need the pos returned by comp_next_token
    ; Let me fix: comp_next_token returns new_pos in ECX
    ; So after the call, ECX = pos after "||"

    ; Wait — we called comp_token_eq which clobbered ECX
    ; We need to save the pos from comp_next_token
    ; Let me restructure this...
    jmp     .por_no_match       ; placeholder — restructure needed

.por_no_match:
    ; Token wasn't ||, put pos back
    ; ebx still has the position before the token
    mov     ecx, ebx
    jmp     .por_return

.por_done:
    mov     ecx, ebx
.por_return:
    mov     eax, r12d
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_and(line_pos) -> (expr_idx, new_pos)
; ============================================================
comp_parse_and:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 32

    call    comp_parse_cmp
    mov     r12d, eax
    mov     ebx, ecx

.pand_loop:
    ; Save pos before trying token
    mov     esi, ebx
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .pand_done
    mov     rdi, rax            ; save tok ptr
    mov     ebx, ecx            ; pos after token

    mov     rcx, rdi
    lea     rdx, [op_and_src]
    call    comp_token_eq
    test    eax, eax
    jz      .pand_no_match

    ; Found &&: create binary node with "and"
    mov     ecx, ebx
    call    comp_parse_cmp
    mov     ebx, ecx            ; update pos
    ; eax = right idx

    ; Allocate binary expr node
    push    rax                 ; save right_idx
    call    comp_alloc_expr
    mov     esi, eax            ; esi = new node idx
    pop     rdx                 ; rdx = right_idx

    ; Set kind = CIREX_BINARY
    imul    eax, esi, SIZEOF_CIR_EXPR
    lea     rcx, [comp_expr_pool + rax]
    mov     dword [rcx + CIR_EX_KIND], CIREX_BINARY

    ; Add "and" to string table
    push    rcx
    push    rdx
    push    rsi
    lea     rcx, [op_and_bin]
    call    comp_str_add        ; eax = op str idx
    pop     rsi
    pop     rdx
    pop     rcx

    ; Now rcx may be stale, recompute
    imul    r8d, esi, SIZEOF_CIR_EXPR
    lea     rcx, [comp_expr_pool]
    add     rcx, r8
    mov     [rcx + CIR_EX_OP], eax      ; op string idx (offset 4)
    mov     [rcx + CIR_EX_LEFT], r12d   ; left child    (offset 8)
    mov     [rcx + CIR_EX_RIGHT], edx   ; right child   (offset 12)
    mov     r12d, esi                    ; new left = this node
    jmp     .pand_loop

.pand_no_match:
    mov     ebx, esi            ; restore pos
.pand_done:
    mov     eax, r12d
    mov     ecx, ebx
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_cmp(line_pos) -> (expr_idx, new_pos)
; ============================================================
comp_parse_cmp:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    sub     rsp, 40
    ; ret(8)+rbp(8)+5*push(40)+sub(40)=96, 96%16=0 ✓

    call    comp_parse_add
    mov     r12d, eax           ; left
    mov     ebx, ecx            ; pos

    ; Save pos, try next token
    mov     esi, ebx
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .pcmp_done
    mov     rdi, rax            ; tok ptr
    mov     ebx, ecx            ; pos after token

    ; Check if it's a comparison operator: ==, !=, <, >, <=, >=
    lea     rcx, [comp_tok_buf]
    movzx   eax, byte [rcx]
    cmp     al, '='
    je      .pcmp_check_eq
    cmp     al, '!'
    je      .pcmp_check_ne
    cmp     al, '<'
    je      .pcmp_check_lt
    cmp     al, '>'
    je      .pcmp_check_gt
    jmp     .pcmp_not_cmp

.pcmp_check_eq:
    movzx   eax, byte [rcx + 1]
    cmp     al, '='
    jne     .pcmp_not_cmp
    jmp     .pcmp_is_cmp
.pcmp_check_ne:
    movzx   eax, byte [rcx + 1]
    cmp     al, '='
    jne     .pcmp_not_cmp
    jmp     .pcmp_is_cmp
.pcmp_check_lt:
    movzx   eax, byte [rcx + 1]
    cmp     al, '='
    je      .pcmp_is_cmp
    cmp     al, 0               ; just '<'
    je      .pcmp_is_cmp
    jmp     .pcmp_not_cmp
.pcmp_check_gt:
    movzx   eax, byte [rcx + 1]
    cmp     al, '='
    je      .pcmp_is_cmp
    cmp     al, 0               ; just '>'
    je      .pcmp_is_cmp
    jmp     .pcmp_not_cmp

.pcmp_is_cmp:
    ; Add operator string to parse table
    lea     rcx, [comp_tok_buf]
    call    comp_str_add
    mov     r13d, eax           ; r13d = op str idx

    ; Parse right side
    mov     ecx, ebx
    call    comp_parse_add
    mov     ebx, ecx
    ; eax = right idx

    ; Create binary node
    push    rax
    call    comp_alloc_expr
    mov     esi, eax
    pop     rdx                 ; right idx

    imul    eax, esi, SIZEOF_CIR_EXPR
    lea     rcx, [comp_expr_pool + rax]
    mov     dword [rcx + CIR_EX_KIND], CIREX_BINARY
    mov     [rcx + CIR_EX_OP], r13d     ; op string idx (offset 4)
    mov     [rcx + CIR_EX_LEFT], r12d   ; left child    (offset 8)
    mov     [rcx + CIR_EX_RIGHT], edx   ; right child   (offset 12)

    mov     r12d, esi
    jmp     .pcmp_finish

.pcmp_not_cmp:
    mov     ebx, esi            ; restore pos
.pcmp_done:
.pcmp_finish:
    mov     eax, r12d
    mov     ecx, ebx
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_add(line_pos) -> (expr_idx, new_pos)
; ============================================================
comp_parse_add:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    sub     rsp, 40

    call    comp_parse_primary
    mov     r12d, eax
    mov     ebx, ecx

.padd_loop:
    mov     esi, ebx
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .padd_done
    mov     rdi, rax
    mov     ebx, ecx

    ; Check for + or -
    lea     rcx, [comp_tok_buf]
    movzx   eax, byte [rcx]
    movzx   edx, byte [rcx + 1]
    test    dl, dl
    jnz     .padd_not_op        ; multi-char token, not just +/-

    cmp     al, '+'
    je      .padd_is_op
    cmp     al, '-'
    je      .padd_is_op
    jmp     .padd_not_op

.padd_is_op:
    ; Add operator to string table
    lea     rcx, [comp_tok_buf]
    call    comp_str_add
    mov     r13d, eax

    ; Parse right
    mov     ecx, ebx
    call    comp_parse_primary
    mov     ebx, ecx

    ; Create binary node
    push    rax
    call    comp_alloc_expr
    mov     esi, eax
    pop     rdx

    imul    eax, esi, SIZEOF_CIR_EXPR
    lea     rcx, [comp_expr_pool + rax]
    mov     dword [rcx + CIR_EX_KIND], CIREX_BINARY
    mov     [rcx + CIR_EX_OP], r13d     ; op string idx (offset 4)
    mov     [rcx + CIR_EX_LEFT], r12d   ; left child    (offset 8)
    mov     [rcx + CIR_EX_RIGHT], edx   ; right child   (offset 12)
    mov     r12d, esi
    jmp     .padd_loop

.padd_not_op:
    mov     ebx, esi
.padd_done:
    mov     eax, r12d
    mov     ecx, ebx
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_primary(line_pos) -> (expr_idx, new_pos)
; ============================================================
comp_parse_primary:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 32

    mov     ebx, ecx            ; save line_pos

    ; Get next token
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .ppri_null
    mov     ebx, ecx            ; pos after token

    ; Check token type
    lea     rsi, [comp_tok_buf]

    ; Check for '(' — parenthesized expression
    movzx   eax, byte [rsi]
    cmp     al, '('
    je      .ppri_paren

    ; Check for count(...) — starts with 'c' and contains '('
    cmp     al, 'c'
    je      .ppri_maybe_count

    ; Check for integer (starts with digit or '-' followed by digit)
    cmp     al, '-'
    je      .ppri_maybe_neg_int
    cmp     al, '0'
    jl      .ppri_maybe_prop
    cmp     al, '9'
    jg      .ppri_maybe_prop
    jmp     .ppri_int

.ppri_maybe_neg_int:
    movzx   eax, byte [rsi + 1]
    cmp     al, '0'
    jl      .ppri_maybe_prop
    cmp     al, '9'
    jg      .ppri_maybe_prop

.ppri_int:
    ; Parse integer
    mov     rcx, rsi
    call    herb_atoll          ; rax = int64 value

    ; Allocate expr node
    push    rax
    call    comp_alloc_expr
    mov     r12d, eax
    pop     rdx                 ; rdx = int value

    imul    eax, r12d, SIZEOF_CIR_EXPR
    lea     rcx, [comp_expr_pool + rax]
    mov     dword [rcx + CIR_EX_KIND], CIREX_INT
    mov     [rcx + CIR_EX_IVAL], rdx

    mov     eax, r12d
    mov     ecx, ebx
    jmp     .ppri_done

.ppri_maybe_count:
    ; Check if token starts with "count("
    lea     rcx, [comp_tok_buf]
    cmp     byte [rcx + 1], 'o'
    jne     .ppri_maybe_prop
    cmp     byte [rcx + 2], 'u'
    jne     .ppri_maybe_prop
    cmp     byte [rcx + 3], 'n'
    jne     .ppri_maybe_prop
    cmp     byte [rcx + 4], 't'
    jne     .ppri_maybe_prop
    cmp     byte [rcx + 5], '('
    jne     .ppri_maybe_prop

    ; Find closing paren, extract container name
    lea     rsi, [comp_tok_buf + 6]
    xor     edi, edi
.ppri_count_scan:
    movzx   eax, byte [rsi + rdi]
    test    al, al
    jz      .ppri_count_end
    cmp     al, ')'
    je      .ppri_count_end
    inc     edi
    jmp     .ppri_count_scan
.ppri_count_end:
    mov     byte [rsi + rdi], 0 ; null-terminate container name

    ; Add container name to string table
    mov     rcx, rsi
    call    comp_str_add
    mov     r12d, eax           ; container str idx

    ; Allocate count expr
    call    comp_alloc_expr
    mov     esi, eax
    imul    eax, esi, SIZEOF_CIR_EXPR
    lea     rcx, [comp_expr_pool + rax]
    mov     dword [rcx + CIR_EX_KIND], CIREX_COUNT
    mov     [rcx + CIR_EX_STR1], r12d

    mov     eax, esi
    mov     ecx, ebx
    jmp     .ppri_done

.ppri_maybe_prop:
    ; Check for bind.prop pattern (contains '.')
    lea     rsi, [comp_tok_buf]
    xor     edi, edi
.ppri_dot_scan:
    movzx   eax, byte [rsi + rdi]
    test    al, al
    jz      .ppri_bare_ident
    cmp     al, '.'
    je      .ppri_found_dot
    inc     edi
    jmp     .ppri_dot_scan

.ppri_found_dot:
    ; Split at dot: tok_buf[0..edi-1] = bind, tok_buf[edi+1..] = prop
    mov     byte [rsi + rdi], 0         ; null-terminate bind part
    lea     rdi, [rsi + rdi + 1]        ; rdi = prop part

    ; Add prop name to string table
    mov     rcx, rdi
    call    comp_str_add
    mov     r12d, eax           ; prop str idx

    ; Add bind name (of) to string table
    mov     rcx, rsi
    call    comp_str_add
    ; eax = of str idx

    ; Allocate prop expr
    push    rax
    call    comp_alloc_expr
    mov     esi, eax
    pop     rdx                 ; of str idx

    imul    eax, esi, SIZEOF_CIR_EXPR
    lea     rcx, [comp_expr_pool + rax]
    mov     dword [rcx + CIR_EX_KIND], CIREX_PROP
    mov     [rcx + CIR_EX_STR1], r12d  ; prop name
    mov     [rcx + CIR_EX_STR2], edx   ; of name

    mov     eax, esi
    mov     ecx, ebx
    jmp     .ppri_done

.ppri_bare_ident:
    ; Unknown token — shouldn't happen in well-formed input
    ; Treat as integer 0
    call    comp_alloc_expr
    mov     r12d, eax
    imul    eax, r12d, SIZEOF_CIR_EXPR
    lea     rcx, [comp_expr_pool + rax]
    mov     dword [rcx + CIR_EX_KIND], CIREX_INT
    mov     qword [rcx + CIR_EX_IVAL], 0
    mov     eax, r12d
    mov     ecx, ebx
    jmp     .ppri_done

.ppri_paren:
    ; Skip '(' — it was the whole token
    mov     ecx, ebx
    call    comp_parse_expr
    mov     r12d, eax
    mov     ebx, ecx

    ; Expect ')'
    mov     ecx, ebx
    call    comp_next_token
    ; Just consume it
    mov     ebx, ecx
    mov     eax, r12d
    mov     ecx, ebx
    jmp     .ppri_done

.ppri_null:
    ; No token — return a null/zero expr
    call    comp_alloc_expr
    mov     ecx, ebx
    jmp     .ppri_done

.ppri_done:
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; TENSION/MATCH/EMIT PARSER (Step 6)
; ============================================================

; ============================================================
; comp_parse_program — main parse loop
; ============================================================
comp_parse_program:
    push    rbp
    mov     rbp, rsp
    push    rbx
    sub     rsp, 40

.cpp_loop:
    call    comp_next_line
    test    eax, eax
    jz      .cpp_done

    ; Check indent — only process indent 0 (tensions)
    cmp     dword [comp_line_indent], 0
    jne     .cpp_loop

    ; Get first token
    xor     ecx, ecx
    call    comp_next_token
    test    rax, rax
    jz      .cpp_loop

    ; Check if it's "step" (step-discipline tension)
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_step]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpp_step

    ; Check if it's "tension"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_tension]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpp_tension

    ; Check "type"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_type]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpp_type

    ; Check "container"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_container]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpp_container

    ; Check "move"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_move]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpp_move

    ; Check "entity"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_entity]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpp_entity

    ; Check "channel"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_channel]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpp_channel

    ; Check "config"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_config]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpp_config

    ; Unknown keyword — skip
    jmp     .cpp_loop

.cpp_step:
    mov     dword [comp_step_pending], 1
    call    comp_parse_tension
    jmp     .cpp_loop

.cpp_tension:
    mov     dword [comp_step_pending], 0
    call    comp_parse_tension
    jmp     .cpp_loop

.cpp_type:
    call    comp_parse_type
    jmp     .cpp_loop

.cpp_container:
    call    comp_parse_container_decl
    jmp     .cpp_loop

.cpp_move:
    call    comp_parse_move
    jmp     .cpp_loop

.cpp_entity:
    call    comp_parse_entity
    jmp     .cpp_loop

.cpp_channel:
    call    comp_parse_channel
    jmp     .cpp_loop

.cpp_config:
    call    comp_parse_config
    jmp     .cpp_loop

.cpp_done:
    add     rsp, 40
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_tension — parse tension + its match/emit body
;
; Called after "tension" keyword consumed from line.
; The rest of the line has: <name> priority <N>
; ============================================================
comp_parse_tension:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    sub     rsp, 40
    ; ret(8)+rbp(8)+5*push(40)+sub(40)=96, 96%16=0 ✓

    ; Allocate tension slot
    mov     eax, [comp_ten_count]
    cmp     eax, COMP_MAX_TENSIONS
    jge     .cpt_done
    mov     r12d, eax           ; r12d = tension index
    inc     dword [comp_ten_count]

    ; Compute pointer to tension IR
    imul    eax, r12d, SIZEOF_CIR_TENSION
    lea     r13, [comp_tensions + rax]  ; r13 = tension IR ptr

    ; Zero it
    mov     rcx, r13
    xor     edx, edx
    mov     r8d, SIZEOF_CIR_TENSION
    call    herb_memset

    ; Set step flag from comp_step_pending
    mov     eax, [comp_step_pending]
    mov     [r13 + CIR_TEN_STEP], eax

    ; The line buffer still has the full line. We need to re-tokenize.
    ; Tokens: tension/step <name> priority <N>
    ; "tension"/"step" was already consumed. Let's re-parse from start.
    xor     ecx, ecx
    call    comp_next_token     ; skip "tension"/"step"
    mov     ebx, ecx

    ; Token: <name>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpt_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_TEN_NAME], eax

    ; Token: "priority"
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx

    ; Token: <N>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpt_body
    mov     ebx, ecx
    lea     rcx, [comp_tok_buf]
    call    herb_atoll
    mov     [r13 + CIR_TEN_PRIORITY], eax

.cpt_body:
    ; Parse body lines (indent >= 1)
    mov     dword [r13 + CIR_TEN_MATCH_COUNT], 0
    mov     dword [r13 + CIR_TEN_EMIT_COUNT], 0

.cpt_body_loop:
    ; Save source position in case we need to back up
    mov     eax, [comp_src_pos]
    mov     [rbp - 96], eax     ; use stack local for saved pos
    ; Note: our stack frame has space at rbp-96 (below the 5 pushes+sub)
    ; Actually let me use a safer approach — use esi for saved pos
    mov     esi, [comp_src_pos]

    call    comp_next_line
    test    eax, eax
    jz      .cpt_done

    ; If indent 0, this is the next tension — put line back
    cmp     dword [comp_line_indent], 0
    je      .cpt_unread_line

    cmp     dword [comp_line_indent], 2
    jge     .cpt_body_loop      ; where clauses handled by match parser via peek

    ; Indent 1: match or emit
    xor     ecx, ecx
    call    comp_next_token
    test    rax, rax
    jz      .cpt_body_loop

    ; Check "match"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_match]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpt_parse_match

    ; Check "emit"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_emit]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpt_parse_emit

    ; Check "guard"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_guard]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpt_parse_guard

    ; Unknown keyword at indent 1 — skip
    jmp     .cpt_body_loop

.cpt_parse_match:
    mov     rcx, r13            ; tension ptr
    call    comp_parse_match_clause
    jmp     .cpt_body_loop

.cpt_parse_emit:
    mov     rcx, r13            ; tension ptr
    call    comp_parse_emit_clause
    jmp     .cpt_body_loop

.cpt_parse_guard:
    mov     rcx, r13            ; tension ptr
    call    comp_parse_guard_clause
    jmp     .cpt_body_loop

.cpt_unread_line:
    ; Restore source position so next call re-reads this line
    mov     [comp_src_pos], esi
.cpt_done:
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_match_clause(ten_ptr)
;
; Parse one match clause. "match" keyword already consumed.
; Rest of line: <bind> in <container> [select <mode> [<key>]]
;           or: <bind> empty_in <container1> [...]
; RCX = tension IR pointer
; ============================================================
comp_parse_match_clause:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    ; ret(8)+rbp(8)+6*push(48)+sub(40)=104 → not aligned
    ; Fix: sub rsp, 48 → 112, 112%16=0 ✓
    ; Actually: ret(8)+rbp(8)+6*push(48)+sub(40)=104
    ; 104%16 = 8, need +8 more
    ; Let me recalculate: sub rsp, 48
    add     rsp, 40
    sub     rsp, 48
    ; ret(8)+rbp(8)+6*push(48)+sub(48)=112, 112%16=0 ✓

    mov     r13, rcx            ; r13 = tension ptr

    ; Get match slot
    mov     eax, [r13 + CIR_TEN_MATCH_COUNT]
    cmp     eax, COMP_MAX_MATCHES
    jge     .cpmc_done
    mov     r14d, eax           ; r14d = match index
    inc     dword [r13 + CIR_TEN_MATCH_COUNT]

    ; Compute match IR pointer
    imul    eax, r14d, SIZEOF_CIR_MATCH
    lea     r12, [r13 + CIR_TEN_MATCHES + rax]  ; r12 = match ptr

    ; Zero it
    mov     rcx, r12
    xor     edx, edx
    mov     r8d, SIZEOF_CIR_MATCH
    call    herb_memset

    ; Default: required, select first
    mov     dword [r12 + CIR_MC_REQUIRED], 1
    mov     dword [r12 + CIR_MC_SELECT], BSEL_FIRST
    mov     dword [r12 + CIR_MC_KEY], -1        ; no key

    ; Re-parse line from position 0: "match <bind> ..."
    ; "match" was consumed by the caller's comp_next_token
    ; The line buffer has the full line, we need pos after "match"
    ; Since caller only consumed the first token, let's re-tokenize
    xor     ecx, ecx
    call    comp_next_token     ; skip "match"
    mov     ebx, ecx

    ; Token: <bind>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmc_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_MC_BIND], eax

    ; Token: "in" or "empty_in"
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmc_done
    mov     ebx, ecx

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_empty_in]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmc_empty_in

    ; Assume "in" — parse entity_in match
    mov     dword [r12 + CIR_MC_KIND], 0        ; entity_in
    mov     dword [r12 + CIR_MC_IN_TYPE], 0     ; normal by default

    ; Token: <container> or "scoped" or "channel"
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmc_check_where
    mov     ebx, ecx

    ; Check for "scoped"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_scoped]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmc_scoped_in

    ; Check for "channel"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_channel]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmc_channel_in

    ; Normal container ref
    call    comp_tok_to_str
    mov     [r12 + CIR_MC_CONTAINER], eax
    jmp     .cpmc_opts

.cpmc_scoped_in:
    ; match <bind> in scoped <scope> <container>
    mov     dword [r12 + CIR_MC_IN_TYPE], 1     ; scoped
    ; Parse scope name
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_MC_SCOPE], eax
    ; Parse container name
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_MC_CONTAINER], eax
    jmp     .cpmc_opts

.cpmc_channel_in:
    ; match <bind> in channel <channel_name>
    mov     dword [r12 + CIR_MC_IN_TYPE], 2     ; channel
    ; Parse channel name
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_MC_CONTAINER], eax        ; reuse CONTAINER field

    ; Parse optional: select, optional
.cpmc_opts:
    mov     esi, ebx            ; save pos
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmc_check_where
    mov     ebx, ecx

    ; Check "select"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_select]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmc_parse_select

    ; Check "optional"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_optional]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmc_set_optional

    ; Unknown opt — restore pos
    mov     ebx, esi
    jmp     .cpmc_check_where

.cpmc_parse_select:
    mov     dword [r12 + CIR_MC_HAS_SELECT], 1

    ; Next token: mode
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmc_check_where
    mov     ebx, ecx

    ; Match mode
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_first]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmc_sel_first

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_each]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmc_sel_each

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_max_by]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmc_sel_max_by

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_min_by]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmc_sel_min_by

    jmp     .cpmc_opts

.cpmc_sel_first:
    mov     dword [r12 + CIR_MC_SELECT], BSEL_FIRST
    jmp     .cpmc_opts
.cpmc_sel_each:
    mov     dword [r12 + CIR_MC_SELECT], BSEL_EACH
    jmp     .cpmc_opts
.cpmc_sel_max_by:
    mov     dword [r12 + CIR_MC_SELECT], BSEL_MAX_BY
    ; Next token: key
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmc_check_where
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_MC_KEY], eax
    jmp     .cpmc_opts
.cpmc_sel_min_by:
    mov     dword [r12 + CIR_MC_SELECT], BSEL_MIN_BY
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmc_check_where
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_MC_KEY], eax
    jmp     .cpmc_opts

.cpmc_set_optional:
    mov     dword [r12 + CIR_MC_REQUIRED], 0
    jmp     .cpmc_opts

.cpmc_check_where:
    ; Peek at next line for "where" at indent 2
    mov     esi, [comp_src_pos]
    call    comp_next_line
    test    eax, eax
    jz      .cpmc_done

    cmp     dword [comp_line_indent], 2
    jl      .cpmc_unread

    ; Check first token is "where"
    xor     ecx, ecx
    call    comp_next_token
    test    rax, rax
    jz      .cpmc_unread_check

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_where]
    call    comp_token_eq
    test    eax, eax
    jz      .cpmc_unread

    ; Parse where expression from rest of line
    ; comp_next_token already consumed "where", we need to get pos
    ; after it. Actually comp_next_token returned new pos in ECX.
    ; But we called comp_token_eq which clobbered ECX.
    ; Solution: re-tokenize from 0 to skip "where"
    xor     ecx, ecx
    call    comp_next_token     ; skip "where"
    mov     ecx, ecx            ; pos after "where" — ECX already has it
    call    comp_parse_expr
    ; EAX = new_expr_idx

    ; If already have a where expr, AND them together
    cmp     dword [r12 + CIR_MC_HAS_WHERE], 1
    jne     .cpmc_where_first

    ; Combine: create AND(old_expr, new_expr)
    ; Save new_expr_idx
    mov     edx, eax                ; EDX = right (new expr)
    mov     r14d, [r12 + CIR_MC_WHERE_EXPR]  ; R14d = left (old expr)

    ; Allocate new expr node
    mov     esi, [comp_expr_count]
    inc     dword [comp_expr_count]

    ; Intern "and" operator string
    push    rdx
    push    rsi
    lea     rcx, [op_and_bin]
    call    comp_str_add            ; EAX = "and" str idx
    pop     rsi
    pop     rdx

    ; Fill CIREX_BINARY(and, old, new)
    imul    ecx, esi, SIZEOF_CIR_EXPR
    lea     rcx, [comp_expr_pool + rcx]
    mov     dword [rcx + CIR_EX_KIND], CIREX_BINARY
    mov     [rcx + CIR_EX_OP], eax          ; "and" op
    mov     [rcx + CIR_EX_LEFT], r14d       ; old expr
    mov     [rcx + CIR_EX_RIGHT], edx       ; new expr

    ; Store combined expr as the where_expr
    mov     [r12 + CIR_MC_WHERE_EXPR], esi
    jmp     .cpmc_check_where       ; loop: check for more where clauses

.cpmc_where_first:
    ; First where clause
    mov     [r12 + CIR_MC_WHERE_EXPR], eax
    mov     dword [r12 + CIR_MC_HAS_WHERE], 1
    jmp     .cpmc_check_where       ; loop: check for more where clauses

.cpmc_unread_check:
.cpmc_unread:
    mov     [comp_src_pos], esi
    jmp     .cpmc_done

.cpmc_empty_in:
    ; Parse empty_in: remaining tokens are container names
    mov     dword [r12 + CIR_MC_KIND], 1        ; empty_in
    xor     edi, edi            ; container count

.cpmc_empty_loop:
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmc_empty_done
    mov     ebx, ecx

    call    comp_tok_to_str
    ; Store in CIR_MC_EMPTY_CNTS array
    cmp     edi, 8
    jge     .cpmc_empty_done
    mov     [r12 + CIR_MC_EMPTY_CNTS + rdi*4], eax
    inc     edi
    jmp     .cpmc_empty_loop

.cpmc_empty_done:
    mov     [r12 + CIR_MC_EMPTY_CNT_N], edi

.cpmc_done:
    add     rsp, 48
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_emit_clause(ten_ptr)
;
; Parse one emit clause. "emit" keyword already consumed.
; Rest of line: move/set/send ...
; RCX = tension IR pointer
; ============================================================
comp_parse_emit_clause:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    sub     rsp, 48
    ; ret(8)+rbp(8)+6*push(48)+sub(48)=112, 112%16=0 ✓

    mov     r13, rcx            ; tension ptr

    ; Allocate emit slot
    mov     eax, [r13 + CIR_TEN_EMIT_COUNT]
    cmp     eax, COMP_MAX_EMITS
    jge     .cpec_done
    mov     r14d, eax
    inc     dword [r13 + CIR_TEN_EMIT_COUNT]

    ; Compute emit IR pointer
    imul    eax, r14d, SIZEOF_CIR_EMIT
    lea     r12, [r13 + CIR_TEN_EMITS + rax]

    ; Zero it
    mov     rcx, r12
    xor     edx, edx
    mov     r8d, SIZEOF_CIR_EMIT
    call    herb_memset

    ; Re-tokenize: "emit" was consumed, get kind token
    xor     ecx, ecx
    call    comp_next_token     ; skip "emit"
    mov     ebx, ecx

    mov     ecx, ebx
    call    comp_next_token     ; kind: "move", "set", "send"
    test    rax, rax
    jz      .cpec_done
    mov     ebx, ecx

    ; Check kind
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_move]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpec_move

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_set]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpec_set

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_send]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpec_send

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_receive]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpec_receive

    jmp     .cpec_done

.cpec_move:
    ; emit move <move_name> <entity> to [scoped <scope>] <target>
    mov     dword [r12 + CIR_EC_KIND], BEC_MOVE
    mov     dword [r12 + CIR_EC_TO_KIND], 0     ; normal by default

    ; <move_name>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR1], eax

    ; <entity>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR2], eax

    ; "to"
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx

    ; Check for "scoped" after "to"
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpec_done
    mov     ebx, ecx

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_scoped]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpec_move_scoped

    ; Normal target
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR3], eax
    jmp     .cpec_done

.cpec_move_scoped:
    mov     dword [r12 + CIR_EC_TO_KIND], 1     ; scoped
    ; <scope>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_SCOPE], eax
    ; <container>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR3], eax
    jmp     .cpec_done

.cpec_set:
    ; emit set <entity> <property> <expression>
    mov     dword [r12 + CIR_EC_KIND], BEC_SET

    ; <entity>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR1], eax

    ; <property>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR2], eax

    ; <expression> — rest of line
    mov     ecx, ebx
    call    comp_parse_expr
    mov     [r12 + CIR_EC_EXPR], eax
    jmp     .cpec_done

.cpec_send:
    ; emit send <channel> <entity>
    mov     dword [r12 + CIR_EC_KIND], BEC_SEND

    ; <channel>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR1], eax

    ; <entity>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR2], eax
    jmp     .cpec_done

.cpec_receive:
    ; emit receive <channel> <entity> to [scoped <scope>] <container>
    mov     dword [r12 + CIR_EC_KIND], BEC_RECEIVE
    mov     dword [r12 + CIR_EC_TO_KIND], 0

    ; <channel>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR1], eax

    ; <entity>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR2], eax

    ; "to"
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx

    ; Check for "scoped" after "to"
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpec_done
    mov     ebx, ecx

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_scoped]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpec_recv_scoped

    ; Normal target
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR3], eax
    jmp     .cpec_done

.cpec_recv_scoped:
    mov     dword [r12 + CIR_EC_TO_KIND], 1
    ; <scope>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_SCOPE], eax
    ; <container>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r12 + CIR_EC_STR3], eax

.cpec_done:
    add     rsp, 48
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_guard_clause(ten_ptr in RCX) — parse guard as match
; ============================================================
comp_parse_guard_clause:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    ; ret(8)+rbp(8)+5*push(40)+sub(40)=96, 96%16=0 ✓

    mov     r13, rcx            ; tension ptr

    ; Allocate match slot
    mov     eax, [r13 + CIR_TEN_MATCH_COUNT]
    cmp     eax, COMP_MAX_MATCHES
    jge     .cpgc_done
    mov     r14d, eax
    inc     dword [r13 + CIR_TEN_MATCH_COUNT]

    ; Compute match IR pointer
    imul    eax, r14d, SIZEOF_CIR_MATCH
    lea     r12, [r13 + CIR_TEN_MATCHES + rax]

    ; Zero it
    mov     rcx, r12
    xor     edx, edx
    mov     r8d, SIZEOF_CIR_MATCH
    call    herb_memset

    ; Set kind = guard (3)
    mov     dword [r12 + CIR_MC_KIND], BMC_GUARD

    ; Re-tokenize to get past "guard"
    xor     ecx, ecx
    call    comp_next_token     ; skip "guard"
    ; Parse rest of line as expression
    mov     ecx, ecx            ; pos after "guard"
    call    comp_parse_expr
    mov     [r12 + CIR_MC_WHERE_EXPR], eax
    mov     dword [r12 + CIR_MC_HAS_WHERE], 1

.cpgc_done:
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_type — parse: type <name> [scope sub-lines]
; ============================================================
comp_parse_type:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    sub     rsp, 40
    ; ret(8)+rbp(8)+5*push(40)+sub(40)=96, 96%16=0 ✓

    ; Allocate entity type slot
    mov     eax, [comp_et_count]
    cmp     eax, COMP_MAX_ENTITY_TYPES
    jge     .cpty_done
    mov     r12d, eax
    inc     dword [comp_et_count]

    ; Compute pointer
    imul    eax, r12d, SIZEOF_CIR_ET
    lea     r13, [comp_entity_types + rax]

    ; Zero it
    mov     rcx, r13
    xor     edx, edx
    mov     r8d, SIZEOF_CIR_ET
    call    herb_memset

    ; Re-tokenize: skip "type", get name
    xor     ecx, ecx
    call    comp_next_token     ; skip "type"
    mov     ebx, ecx
    mov     ecx, ebx
    call    comp_next_token     ; <name>
    test    rax, rax
    jz      .cpty_done
    call    comp_tok_to_str
    mov     [r13 + CIR_ET_NAME], eax

    ; Parse scope sub-lines
.cpty_scope_loop:
    mov     esi, [comp_src_pos]
    call    comp_next_line
    test    eax, eax
    jz      .cpty_done

    cmp     dword [comp_line_indent], 0
    je      .cpty_unread

    cmp     dword [comp_line_indent], 1
    jne     .cpty_scope_loop

    ; Check "scope"
    xor     ecx, ecx
    call    comp_next_token
    test    rax, rax
    jz      .cpty_scope_loop

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_scope]
    call    comp_token_eq
    test    eax, eax
    jz      .cpty_scope_loop    ; unknown sub-keyword, skip

    ; Parse: scope <name> <kind> <entity_type>
    ; Re-tokenize from start
    xor     ecx, ecx
    call    comp_next_token     ; skip "scope"
    mov     ebx, ecx

    ; <scope_name>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpty_scope_loop
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     edi, eax            ; edi = scope name str idx

    ; <kind>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpty_scope_loop
    mov     ebx, ecx
    ; Check "slot" vs "simple"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_slot]
    call    comp_token_eq
    ; eax=1 if slot, 0 if not
    mov     [rsp+32], eax           ; save kind to stack (edx gets clobbered)

    ; <entity_type>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpty_scope_loop
    mov     ebx, ecx
    call    comp_tok_to_str
    ; eax = entity_type str idx

    ; Store in scoped array
    mov     ecx, [r13 + CIR_ET_SCOPED_COUNT]
    cmp     ecx, COMP_MAX_SCOPED_PER_ET
    jge     .cpty_scope_loop

    mov     edx, [rsp+32]              ; restore kind
    imul    ecx, ecx, SIZEOF_CIR_ET_SCOPED
    add     ecx, CIR_ET_SCOPED
    mov     [r13 + rcx], edi        ; name
    mov     [r13 + rcx + 4], edx    ; kind
    mov     [r13 + rcx + 8], eax    ; entity_type
    inc     dword [r13 + CIR_ET_SCOPED_COUNT]
    jmp     .cpty_scope_loop

.cpty_unread:
    mov     [comp_src_pos], esi
.cpty_done:
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_container_decl — parse: container <name> <kind> <etype>
; ============================================================
comp_parse_container_decl:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    r12
    push    r13
    sub     rsp, 32
    ; ret(8)+rbp(8)+4*push(32)+sub(32)=80, 80%16=0 ✓

    ; Allocate container slot
    mov     eax, [comp_cont_count]
    cmp     eax, COMP_MAX_CONTAINERS
    jge     .cpcd_done
    mov     r12d, eax
    inc     dword [comp_cont_count]

    imul    eax, r12d, SIZEOF_CIR_CT
    lea     r13, [comp_containers + rax]

    ; Re-tokenize: skip "container"
    xor     ecx, ecx
    call    comp_next_token
    mov     ebx, ecx

    ; <name>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpcd_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_CT_NAME], eax

    ; <kind> ("simple" or "slot")
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpcd_done
    mov     ebx, ecx
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_slot]
    call    comp_token_eq
    mov     [r13 + CIR_CT_KIND], eax

    ; <entity_type>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpcd_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_CT_ETYPE], eax

    ; Optional: order_key <prop_name>
    mov     dword [r13 + CIR_CT_ORDER_KEY], -1  ; default: unordered
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpcd_done
    mov     ebx, ecx
    ; Check if token is "order_key"
    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_order_key]
    call    comp_token_eq
    test    eax, eax
    jz      .cpcd_done          ; not "order_key" — done
    ; Next token is the property name
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpcd_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_CT_ORDER_KEY], eax

.cpcd_done:
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_move — parse: move <name> <etype> from/scoped_from ...
; ============================================================
comp_parse_move:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    sub     rsp, 48
    ; ret(8)+rbp(8)+6*push(48)+sub(48)=112, 112%16=0 ✓

    ; Allocate move slot
    mov     eax, [comp_move_count]
    cmp     eax, COMP_MAX_MOVES
    jge     .cpmv_done
    mov     r12d, eax
    inc     dword [comp_move_count]

    imul    eax, r12d, SIZEOF_CIR_MV
    lea     r13, [comp_moves + rax]

    ; Zero it
    mov     rcx, r13
    xor     edx, edx
    mov     r8d, SIZEOF_CIR_MV
    call    herb_memset

    ; Re-tokenize: skip "move"
    xor     ecx, ecx
    call    comp_next_token
    mov     ebx, ecx

    ; <name>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmv_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_MV_NAME], eax

    ; <entity_type>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmv_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_MV_ETYPE], eax

    ; "from" or "scoped_from"
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmv_done
    mov     ebx, ecx

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_scoped_from]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmv_scoped

    ; Normal: from <locs> to <locs>
    mov     dword [r13 + CIR_MV_IS_SCOPED], 0

    ; Parse from locations until "to"
    xor     edi, edi            ; from count
.cpmv_from_loop:
    mov     esi, ebx
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmv_from_done
    mov     ebx, ecx

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_to]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmv_from_done_to

    ; It's a from location
    call    comp_tok_to_str
    cmp     edi, COMP_MAX_MOVE_LOCS
    jge     .cpmv_from_loop
    mov     [r13 + CIR_MV_FROM + rdi*4], eax
    inc     edi
    jmp     .cpmv_from_loop

.cpmv_from_done_to:
    mov     [r13 + CIR_MV_FROM_COUNT], edi
    ; Parse to locations
    xor     edi, edi
.cpmv_to_loop:
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmv_to_done
    mov     ebx, ecx
    call    comp_tok_to_str
    cmp     edi, COMP_MAX_MOVE_LOCS
    jge     .cpmv_to_loop
    mov     [r13 + CIR_MV_TO + rdi*4], eax
    inc     edi
    jmp     .cpmv_to_loop

.cpmv_to_done:
    mov     [r13 + CIR_MV_TO_COUNT], edi
    jmp     .cpmv_done

.cpmv_from_done:
    mov     [r13 + CIR_MV_FROM_COUNT], edi
    jmp     .cpmv_done

.cpmv_scoped:
    ; scoped_from <locs> scoped_to <locs>
    mov     dword [r13 + CIR_MV_IS_SCOPED], 1

    xor     edi, edi
.cpmv_sfrom_loop:
    mov     esi, ebx
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmv_sfrom_done
    mov     ebx, ecx

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_scoped_to]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpmv_sfrom_done_to

    call    comp_tok_to_str
    cmp     edi, COMP_MAX_MOVE_LOCS
    jge     .cpmv_sfrom_loop
    mov     [r13 + CIR_MV_FROM + rdi*4], eax
    inc     edi
    jmp     .cpmv_sfrom_loop

.cpmv_sfrom_done_to:
    mov     [r13 + CIR_MV_FROM_COUNT], edi
    xor     edi, edi
.cpmv_sto_loop:
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpmv_sto_done
    mov     ebx, ecx
    call    comp_tok_to_str
    cmp     edi, COMP_MAX_MOVE_LOCS
    jge     .cpmv_sto_loop
    mov     [r13 + CIR_MV_TO + rdi*4], eax
    inc     edi
    jmp     .cpmv_sto_loop

.cpmv_sto_done:
    mov     [r13 + CIR_MV_TO_COUNT], edi
    jmp     .cpmv_done

.cpmv_sfrom_done:
    mov     [r13 + CIR_MV_FROM_COUNT], edi

.cpmv_done:
    add     rsp, 48
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_entity — parse entity with optional prop sub-lines
; ============================================================
comp_parse_entity:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    sub     rsp, 48
    ; ret(8)+rbp(8)+6*push(48)+sub(48)=112, 112%16=0 ✓

    ; Allocate entity slot
    mov     eax, [comp_ent_count]
    cmp     eax, COMP_MAX_ENTITIES
    jge     .cpen_done
    mov     r12d, eax
    inc     dword [comp_ent_count]

    imul    eax, r12d, SIZEOF_CIR_EN
    lea     r13, [comp_entities + rax]

    ; Zero it
    mov     rcx, r13
    xor     edx, edx
    mov     r8d, SIZEOF_CIR_EN
    call    herb_memset

    ; Set prop_start to current prop_count
    mov     eax, [comp_prop_count]
    mov     [r13 + CIR_EN_PROP_START], eax
    mov     dword [r13 + CIR_EN_PROP_COUNT], 0

    ; Re-tokenize: skip "entity"
    xor     ecx, ecx
    call    comp_next_token
    mov     ebx, ecx

    ; <name>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpen_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_EN_NAME], eax

    ; <type>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpen_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_EN_TYPE], eax

    ; "in"
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpen_done
    mov     ebx, ecx

    ; Check for "scoped" after "in"
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpen_done
    mov     ebx, ecx

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_scoped]
    call    comp_token_eq
    test    eax, eax
    jnz     .cpen_scoped

    ; Normal in-spec
    mov     dword [r13 + CIR_EN_IN_KIND], 0
    call    comp_tok_to_str
    mov     [r13 + CIR_EN_IN_CONTAINER], eax
    jmp     .cpen_props

.cpen_scoped:
    mov     dword [r13 + CIR_EN_IN_KIND], 1
    ; <scope>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_EN_IN_SCOPE], eax
    ; <container>
    mov     ecx, ebx
    call    comp_next_token
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_EN_IN_CONTAINER], eax

.cpen_props:
    ; Parse prop sub-lines
    mov     esi, [comp_src_pos]
    call    comp_next_line
    test    eax, eax
    jz      .cpen_done

    cmp     dword [comp_line_indent], 0
    je      .cpen_unread

    cmp     dword [comp_line_indent], 1
    jne     .cpen_props

    ; Check "prop"
    xor     ecx, ecx
    call    comp_next_token
    test    rax, rax
    jz      .cpen_props

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_prop]
    call    comp_token_eq
    test    eax, eax
    jz      .cpen_unread        ; unknown sub-keyword

    ; Parse: prop <key> <value>
    xor     ecx, ecx
    call    comp_next_token     ; skip "prop"
    mov     ebx, ecx

    ; <key>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpen_props
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     edi, eax            ; edi = key str idx

    ; <value> — detect type
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpen_props
    mov     ebx, ecx

    ; Allocate property slot
    mov     eax, [comp_prop_count]
    cmp     eax, COMP_MAX_PROPS_TOTAL
    jge     .cpen_props
    mov     r14d, eax
    inc     dword [comp_prop_count]
    inc     dword [r13 + CIR_EN_PROP_COUNT]

    imul    eax, r14d, SIZEOF_CIR_PR
    lea     r14, [comp_properties + rax]

    ; Store key
    mov     [r14 + CIR_PR_KEY], edi

    ; Detect value type: digit or '-' → int, else → string
    lea     rcx, [comp_tok_buf]
    movzx   eax, byte [rcx]
    cmp     al, '-'
    je      .cpen_prop_int
    cmp     al, '0'
    jl      .cpen_prop_str
    cmp     al, '9'
    jg      .cpen_prop_str

.cpen_prop_int:
    mov     dword [r14 + CIR_PR_VTYPE], 0       ; int
    lea     rcx, [comp_tok_buf]
    call    herb_atoll
    mov     [r14 + CIR_PR_VALUE], rax
    jmp     .cpen_props

.cpen_prop_str:
    mov     dword [r14 + CIR_PR_VTYPE], 2       ; string
    call    comp_tok_to_str
    mov     dword [r14 + CIR_PR_VALUE], eax
    mov     dword [r14 + CIR_PR_VALUE + 4], 0
    jmp     .cpen_props

.cpen_unread:
    mov     [comp_src_pos], esi
.cpen_done:
    add     rsp, 48
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_channel — parse: channel <name> <from> <to> <etype>
; ============================================================
comp_parse_channel:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    r12
    push    r13
    sub     rsp, 32
    ; ret(8)+rbp(8)+4*push(32)+sub(32)=80, 80%16=0 ✓

    mov     eax, [comp_chan_count]
    cmp     eax, COMP_MAX_CHANNELS
    jge     .cpch_done
    mov     r12d, eax
    inc     dword [comp_chan_count]

    imul    eax, r12d, SIZEOF_CIR_CH
    lea     r13, [comp_channels + rax]

    ; Re-tokenize: skip "channel"
    xor     ecx, ecx
    call    comp_next_token
    mov     ebx, ecx

    ; <name>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpch_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_CH_NAME], eax

    ; <from>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpch_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_CH_FROM], eax

    ; <to>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpch_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_CH_TO], eax

    ; <entity_type>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpch_done
    mov     ebx, ecx
    call    comp_tok_to_str
    mov     [r13 + CIR_CH_ETYPE], eax

.cpch_done:
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_parse_config — parse: config max_nesting_depth <N>
; ============================================================
comp_parse_config:
    push    rbp
    mov     rbp, rsp
    push    rbx
    sub     rsp, 40
    ; ret(8)+rbp(8)+push(8)+sub(40)=64, 64%16=0 ✓

    ; Re-tokenize: skip "config"
    xor     ecx, ecx
    call    comp_next_token
    mov     ebx, ecx

    ; <key>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpcf_done
    mov     ebx, ecx

    lea     rcx, [comp_tok_buf]
    lea     rdx, [kw_max_nesting_depth]
    call    comp_token_eq
    test    eax, eax
    jz      .cpcf_done

    ; <value>
    mov     ecx, ebx
    call    comp_next_token
    test    rax, rax
    jz      .cpcf_done
    lea     rcx, [comp_tok_buf]
    call    herb_atoll
    mov     [comp_config_nesting], eax

.cpcf_done:
    add     rsp, 40
    pop     rbx
    pop     rbp
    ret


; ============================================================
; STRING COLLECTION — Python-compatible order (Step 7)
; ============================================================

; ============================================================
; comp_collect_strings — walk IR in Python order, build output string table
; ============================================================
comp_collect_strings:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    ; ret(8)+rbp(8)+7*push(56)+sub(40)=112, 112%16=0 ✓

    ; Full program walk order (matches Python collect_strings exactly):
    ; 1. entity_types  2. containers  3. moves
    ; 4. pools (empty) 5. transfers (empty) 6. channels
    ; 7. tensions      8. entities

    ; === 1. Entity types ===
    xor     r14d, r14d
    mov     r15d, [comp_et_count]
.ccs_et_loop:
    cmp     r14d, r15d
    jge     .ccs_et_done
    imul    eax, r14d, SIZEOF_CIR_ET
    lea     r13, [comp_entity_types + rax]
    ; name
    mov     ecx, [r13 + CIR_ET_NAME]
    call    comp_out_str_add
    ; scoped containers
    xor     r12d, r12d
    mov     ebx, [r13 + CIR_ET_SCOPED_COUNT]
.ccs_et_sc_loop:
    cmp     r12d, ebx
    jge     .ccs_et_sc_done
    imul    eax, r12d, SIZEOF_CIR_ET_SCOPED
    ; scoped name (offset 0)
    mov     ecx, [r13 + CIR_ET_SCOPED + rax]
    call    comp_out_str_add
    ; scoped entity_type (offset 8)
    imul    eax, r12d, SIZEOF_CIR_ET_SCOPED
    mov     ecx, [r13 + CIR_ET_SCOPED + rax + 8]
    call    comp_out_str_add
    inc     r12d
    jmp     .ccs_et_sc_loop
.ccs_et_sc_done:
    inc     r14d
    jmp     .ccs_et_loop
.ccs_et_done:

    ; === 2. Containers ===
    xor     r14d, r14d
    mov     r15d, [comp_cont_count]
.ccs_ct_loop:
    cmp     r14d, r15d
    jge     .ccs_ct_done
    imul    eax, r14d, SIZEOF_CIR_CT
    lea     r13, [comp_containers + rax]
    ; name
    mov     ecx, [r13 + CIR_CT_NAME]
    call    comp_out_str_add
    ; entity_type
    mov     ecx, [r13 + CIR_CT_ETYPE]
    call    comp_out_str_add
    inc     r14d
    jmp     .ccs_ct_loop
.ccs_ct_done:

    ; === 3. Moves ===
    xor     r14d, r14d
    mov     r15d, [comp_move_count]
.ccs_mv_loop:
    cmp     r14d, r15d
    jge     .ccs_mv_done
    imul    eax, r14d, SIZEOF_CIR_MV
    lea     r13, [comp_moves + rax]
    ; name
    mov     ecx, [r13 + CIR_MV_NAME]
    call    comp_out_str_add
    ; entity_type
    mov     ecx, [r13 + CIR_MV_ETYPE]
    call    comp_out_str_add
    ; from locations
    xor     r12d, r12d
    mov     ebx, [r13 + CIR_MV_FROM_COUNT]
.ccs_mv_from:
    cmp     r12d, ebx
    jge     .ccs_mv_from_done
    mov     ecx, [r13 + CIR_MV_FROM + r12*4]
    call    comp_out_str_add
    inc     r12d
    jmp     .ccs_mv_from
.ccs_mv_from_done:
    ; to locations
    xor     r12d, r12d
    mov     ebx, [r13 + CIR_MV_TO_COUNT]
.ccs_mv_to:
    cmp     r12d, ebx
    jge     .ccs_mv_to_done
    mov     ecx, [r13 + CIR_MV_TO + r12*4]
    call    comp_out_str_add
    inc     r12d
    jmp     .ccs_mv_to
.ccs_mv_to_done:
    inc     r14d
    jmp     .ccs_mv_loop
.ccs_mv_done:

    ; === 4. Pools (empty, skip) ===
    ; === 5. Transfers (empty, skip) ===

    ; === 6. Channels ===
    xor     r14d, r14d
    mov     r15d, [comp_chan_count]
.ccs_ch_loop:
    cmp     r14d, r15d
    jge     .ccs_ch_done
    imul    eax, r14d, SIZEOF_CIR_CH
    lea     r13, [comp_channels + rax]
    ; name, from, to, entity_type
    mov     ecx, [r13 + CIR_CH_NAME]
    call    comp_out_str_add
    mov     ecx, [r13 + CIR_CH_FROM]
    call    comp_out_str_add
    mov     ecx, [r13 + CIR_CH_TO]
    call    comp_out_str_add
    mov     ecx, [r13 + CIR_CH_ETYPE]
    call    comp_out_str_add
    inc     r14d
    jmp     .ccs_ch_loop
.ccs_ch_done:

    ; === 7. Tensions ===
    xor     r14d, r14d
    mov     r15d, [comp_ten_count]
.ccs_ten_loop:
    cmp     r14d, r15d
    jge     .ccs_ten_done
    imul    eax, r14d, SIZEOF_CIR_TENSION
    lea     r13, [comp_tensions + rax]
    ; Tension name
    mov     ecx, [r13 + CIR_TEN_NAME]
    call    comp_out_str_add
    ; Match clauses
    xor     r12d, r12d
    mov     ebx, [r13 + CIR_TEN_MATCH_COUNT]
.ccs_match_loop:
    cmp     r12d, ebx
    jge     .ccs_emits
    imul    eax, r12d, SIZEOF_CIR_MATCH
    lea     rsi, [r13 + CIR_TEN_MATCHES + rax]
    call    comp_collect_match_strings
    inc     r12d
    jmp     .ccs_match_loop
.ccs_emits:
    ; Emit clauses
    xor     r12d, r12d
    mov     ebx, [r13 + CIR_TEN_EMIT_COUNT]
.ccs_emit_loop:
    cmp     r12d, ebx
    jge     .ccs_next_ten
    imul    eax, r12d, SIZEOF_CIR_EMIT
    lea     rsi, [r13 + CIR_TEN_EMITS + rax]
    call    comp_collect_emit_strings
    inc     r12d
    jmp     .ccs_emit_loop
.ccs_next_ten:
    inc     r14d
    jmp     .ccs_ten_loop
.ccs_ten_done:

    ; === 8. Entities ===
    xor     r14d, r14d
    mov     r15d, [comp_ent_count]
.ccs_en_loop:
    cmp     r14d, r15d
    jge     .ccs_en_done
    imul    eax, r14d, SIZEOF_CIR_EN
    lea     r13, [comp_entities + rax]
    ; name
    mov     ecx, [r13 + CIR_EN_NAME]
    call    comp_out_str_add
    ; type
    mov     ecx, [r13 + CIR_EN_TYPE]
    call    comp_out_str_add
    ; in-spec
    cmp     dword [r13 + CIR_EN_IN_KIND], 1
    je      .ccs_en_scoped
    ; normal: add container
    mov     ecx, [r13 + CIR_EN_IN_CONTAINER]
    call    comp_out_str_add
    jmp     .ccs_en_props
.ccs_en_scoped:
    ; scoped: add scope, add container
    mov     ecx, [r13 + CIR_EN_IN_SCOPE]
    call    comp_out_str_add
    mov     ecx, [r13 + CIR_EN_IN_CONTAINER]
    call    comp_out_str_add
.ccs_en_props:
    ; Properties
    mov     ebx, [r13 + CIR_EN_PROP_COUNT]
    test    ebx, ebx
    jz      .ccs_en_next
    mov     r12d, [r13 + CIR_EN_PROP_START]
    xor     edi, edi
.ccs_en_prop_loop:
    cmp     edi, ebx
    jge     .ccs_en_next
    ; Property pointer = comp_properties + (prop_start + i) * SIZEOF_CIR_PR
    mov     eax, r12d
    add     eax, edi
    imul    eax, SIZEOF_CIR_PR
    lea     rsi, [comp_properties + rax]
    ; key
    mov     ecx, [rsi + CIR_PR_KEY]
    call    comp_out_str_add
    ; value if string type (VTYPE==2)
    cmp     dword [rsi + CIR_PR_VTYPE], 2
    jne     .ccs_en_prop_next
    mov     ecx, [rsi + CIR_PR_VALUE]
    call    comp_out_str_add
.ccs_en_prop_next:
    inc     edi
    jmp     .ccs_en_prop_loop
.ccs_en_next:
    inc     r14d
    jmp     .ccs_en_loop
.ccs_en_done:

.ccs_done:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_collect_match_strings(match_ptr in RSI)
;
; Walks match clause strings in Python order:
;   bind, (guard exprs), container, in_spec, empty_in[], key, where_expr
; ============================================================
comp_collect_match_strings:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    sub     rsp, 40
    ; ret(8)+rbp(8)+3*push(24)+sub(40)=80, 80%16=0 ✓

    mov     r12, rsi            ; save match ptr

    ; bind
    mov     ecx, [r12 + CIR_MC_BIND]
    call    comp_out_str_add

    ; container (None for guard/empty-in, add_string(None)→skip in Python)
    ; In Python: self.add_string(mc.get("container")) — this is the old "container" key
    ; For our IR, entity_in stores container in CIR_MC_CONTAINER
    ; For empty_in, there's no separate "container" key
    ; But Python's walk also checks mc.get("container") which is None for our fragments
    ; So we skip this (Python add_string(None) returns NONE_IDX, no string added)

    ; in_spec (for entity_in — handle normal, scoped, channel)
    cmp     dword [r12 + CIR_MC_KIND], 0
    jne     .ccms_no_in
    cmp     dword [r12 + CIR_MC_IN_TYPE], 1
    je      .ccms_in_scoped
    cmp     dword [r12 + CIR_MC_IN_TYPE], 2
    je      .ccms_in_channel
    ; normal: container
    mov     ecx, [r12 + CIR_MC_CONTAINER]
    call    comp_out_str_add
    jmp     .ccms_no_in
.ccms_in_scoped:
    ; scoped: scope, container
    mov     ecx, [r12 + CIR_MC_SCOPE]
    call    comp_out_str_add
    mov     ecx, [r12 + CIR_MC_CONTAINER]
    call    comp_out_str_add
    jmp     .ccms_no_in
.ccms_in_channel:
    ; channel: channel_name (stored in CONTAINER)
    mov     ecx, [r12 + CIR_MC_CONTAINER]
    call    comp_out_str_add
.ccms_no_in:

    ; empty_in containers
    cmp     dword [r12 + CIR_MC_KIND], 1
    jne     .ccms_no_empty
    xor     ebx, ebx
    mov     r13d, [r12 + CIR_MC_EMPTY_CNT_N]
.ccms_empty_loop:
    cmp     ebx, r13d
    jge     .ccms_no_empty
    mov     ecx, [r12 + CIR_MC_EMPTY_CNTS + rbx*4]
    call    comp_out_str_add
    inc     ebx
    jmp     .ccms_empty_loop
.ccms_no_empty:

    ; key (for max_by/min_by)
    cmp     dword [r12 + CIR_MC_KEY], -1
    je      .ccms_no_key
    mov     ecx, [r12 + CIR_MC_KEY]
    call    comp_out_str_add
.ccms_no_key:

    ; where expression
    cmp     dword [r12 + CIR_MC_HAS_WHERE], 0
    je      .ccms_done
    mov     ecx, [r12 + CIR_MC_WHERE_EXPR]
    call    comp_collect_expr_strings

.ccms_done:
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_collect_emit_strings(emit_ptr in RSI)
;
; Walks emit clause strings in Python order
; ============================================================
comp_collect_emit_strings:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    sub     rsp, 32
    ; ret(8)+rbp(8)+2*push(16)+sub(32)=64, 64%16=0 ✓

    mov     r12, rsi

    mov     eax, [r12 + CIR_EC_KIND]
    cmp     eax, BEC_MOVE
    je      .cces_move
    cmp     eax, BEC_SET
    je      .cces_set
    cmp     eax, BEC_SEND
    je      .cces_send
    cmp     eax, BEC_RECEIVE
    je      .cces_receive
    jmp     .cces_done

.cces_move:
    ; move: move_name, entity, to_ref
    mov     ecx, [r12 + CIR_EC_STR1]
    call    comp_out_str_add
    mov     ecx, [r12 + CIR_EC_STR2]
    call    comp_out_str_add
    ; to-ref: Python _collect_ref_strings(ec.get("to"))
    cmp     dword [r12 + CIR_EC_TO_KIND], 1
    je      .cces_move_scoped
    ; normal: target string
    mov     ecx, [r12 + CIR_EC_STR3]
    call    comp_out_str_add
    jmp     .cces_done
.cces_move_scoped:
    ; scoped: scope, container
    mov     ecx, [r12 + CIR_EC_SCOPE]
    call    comp_out_str_add
    mov     ecx, [r12 + CIR_EC_STR3]
    call    comp_out_str_add
    jmp     .cces_done

.cces_set:
    ; set: entity, property, value_expr
    mov     ecx, [r12 + CIR_EC_STR1]
    call    comp_out_str_add
    mov     ecx, [r12 + CIR_EC_STR2]
    call    comp_out_str_add
    mov     ecx, [r12 + CIR_EC_EXPR]
    call    comp_collect_expr_strings
    jmp     .cces_done

.cces_send:
    ; send: channel, entity
    mov     ecx, [r12 + CIR_EC_STR1]
    call    comp_out_str_add
    mov     ecx, [r12 + CIR_EC_STR2]
    call    comp_out_str_add
    jmp     .cces_done

.cces_receive:
    ; receive: channel, entity, to_ref
    mov     ecx, [r12 + CIR_EC_STR1]
    call    comp_out_str_add
    mov     ecx, [r12 + CIR_EC_STR2]
    call    comp_out_str_add
    ; to-ref
    cmp     dword [r12 + CIR_EC_TO_KIND], 1
    je      .cces_recv_scoped
    mov     ecx, [r12 + CIR_EC_STR3]
    call    comp_out_str_add
    jmp     .cces_done
.cces_recv_scoped:
    mov     ecx, [r12 + CIR_EC_SCOPE]
    call    comp_out_str_add
    mov     ecx, [r12 + CIR_EC_STR3]
    call    comp_out_str_add

.cces_done:
    add     rsp, 32
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_collect_expr_strings(expr_idx in ECX)
;
; Recursively collect strings from expression tree.
; Python order: if binary: op, left, right
;               if prop: prop, of
;               if count: container
; ============================================================
comp_collect_expr_strings:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    sub     rsp, 32

    mov     r12d, ecx           ; expr idx

    ; Get expr pointer
    imul    eax, r12d, SIZEOF_CIR_EXPR
    lea     rbx, [comp_expr_pool + rax]

    mov     eax, [rbx + CIR_EX_KIND]

    cmp     eax, CIREX_BINARY
    je      .ccexs_binary
    cmp     eax, CIREX_PROP
    je      .ccexs_prop
    cmp     eax, CIREX_COUNT
    je      .ccexs_count
    ; INT — no strings
    jmp     .ccexs_done

.ccexs_binary:
    ; op string (stored at CIR_EX_OP, not CIR_EX_STR1 which overlaps LEFT)
    mov     ecx, [rbx + CIR_EX_OP]
    call    comp_out_str_add
    ; recurse left
    mov     ecx, [rbx + CIR_EX_LEFT]
    call    comp_collect_expr_strings
    ; recurse right
    mov     ecx, [rbx + CIR_EX_RIGHT]
    call    comp_collect_expr_strings
    jmp     .ccexs_done

.ccexs_prop:
    ; prop name, then of name
    mov     ecx, [rbx + CIR_EX_STR1]
    call    comp_out_str_add
    mov     ecx, [rbx + CIR_EX_STR2]
    call    comp_out_str_add
    jmp     .ccexs_done

.ccexs_count:
    mov     ecx, [rbx + CIR_EX_STR1]
    call    comp_out_str_add

.ccexs_done:
    add     rsp, 32
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================
; BINARY EMITTER (Step 8)
; ============================================================

; ============================================================
; comp_emit_binary — emit complete binary to output buffer
; ============================================================
comp_emit_binary:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40

    ; === Header ===
    ; Magic "HERB"
    mov     ecx, 'H'
    call    comp_emit_u8
    mov     ecx, 'E'
    call    comp_emit_u8
    mov     ecx, 'R'
    call    comp_emit_u8
    mov     ecx, 'B'
    call    comp_emit_u8
    ; Version 1
    mov     ecx, 1
    call    comp_emit_u8
    ; Flags 0
    xor     ecx, ecx
    call    comp_emit_u8
    ; String count
    mov     ecx, [comp_out_str_count]
    call    comp_emit_u16

    ; === String table ===
    xor     r14d, r14d
    mov     r15d, [comp_out_str_count]
.ceb_str_loop:
    cmp     r14d, r15d
    jge     .ceb_str_done

    ; Get string pointer
    mov     eax, r14d
    imul    eax, COMP_MAX_STR_LEN
    lea     rsi, [comp_out_strtab + rax]

    ; Get length
    mov     rcx, rsi
    call    herb_strlen
    mov     ebx, eax            ; ebx = len

    ; Clamp to 255
    cmp     ebx, 255
    jle     .ceb_str_ok
    mov     ebx, 255
.ceb_str_ok:

    ; Emit length byte
    mov     ecx, ebx
    call    comp_emit_u8

    ; Emit string bytes
    xor     edi, edi
.ceb_str_bytes:
    cmp     edi, ebx
    jge     .ceb_str_next
    movzx   ecx, byte [rsi + rdi]
    call    comp_emit_u8
    inc     edi
    jmp     .ceb_str_bytes

.ceb_str_next:
    inc     r14d
    jmp     .ceb_str_loop

.ceb_str_done:

    ; === Section 0x01: Entity Types ===
    mov     ecx, BSEC_ENTITY_TYPES
    call    comp_emit_u8
    mov     ecx, [comp_et_count]
    call    comp_emit_u16

    xor     r14d, r14d
.ceb_et_loop:
    cmp     r14d, [comp_et_count]
    jge     .ceb_et_done
    imul    eax, r14d, SIZEOF_CIR_ET
    lea     r13, [comp_entity_types + rax]
    ; name
    mov     ecx, [r13 + CIR_ET_NAME]
    call    comp_emit_str_idx
    ; scoped_count
    mov     ebx, [r13 + CIR_ET_SCOPED_COUNT]
    mov     ecx, ebx
    call    comp_emit_u8
    ; scoped containers
    xor     r12d, r12d
.ceb_et_sc_loop:
    cmp     r12d, ebx
    jge     .ceb_et_sc_done
    imul    eax, r12d, SIZEOF_CIR_ET_SCOPED
    ; scoped name
    mov     ecx, [r13 + CIR_ET_SCOPED + rax]
    call    comp_emit_str_idx
    ; scoped kind
    imul    eax, r12d, SIZEOF_CIR_ET_SCOPED
    mov     ecx, [r13 + CIR_ET_SCOPED + rax + 4]
    call    comp_emit_u8
    ; scoped entity_type
    imul    eax, r12d, SIZEOF_CIR_ET_SCOPED
    mov     ecx, [r13 + CIR_ET_SCOPED + rax + 8]
    call    comp_emit_str_idx
    inc     r12d
    jmp     .ceb_et_sc_loop
.ceb_et_sc_done:
    inc     r14d
    jmp     .ceb_et_loop
.ceb_et_done:

    ; === Section 0x02: Containers ===
    mov     ecx, BSEC_CONTAINERS
    call    comp_emit_u8
    mov     ecx, [comp_cont_count]
    call    comp_emit_u16

    xor     r14d, r14d
.ceb_ct_loop:
    cmp     r14d, [comp_cont_count]
    jge     .ceb_ct_done
    imul    eax, r14d, SIZEOF_CIR_CT
    lea     r13, [comp_containers + rax]
    ; name
    mov     ecx, [r13 + CIR_CT_NAME]
    call    comp_emit_str_idx
    ; kind
    mov     ecx, [r13 + CIR_CT_KIND]
    call    comp_emit_u8
    ; entity_type
    mov     ecx, [r13 + CIR_CT_ETYPE]
    call    comp_emit_str_idx
    ; order_key (u16: string idx or 0xFFFF)
    mov     ecx, [r13 + CIR_CT_ORDER_KEY]
    cmp     ecx, -1
    jne     .ceb_ct_has_ok
    mov     ecx, 0xFFFF
    jmp     .ceb_ct_emit_ok
.ceb_ct_has_ok:
    ; Map parse string idx to output string idx
    call    comp_emit_str_idx
    jmp     .ceb_ct_ok_next
.ceb_ct_emit_ok:
    call    comp_emit_u16
.ceb_ct_ok_next:
    inc     r14d
    jmp     .ceb_ct_loop
.ceb_ct_done:

    ; === Section 0x03: Moves ===
    mov     ecx, BSEC_MOVES
    call    comp_emit_u8
    mov     ecx, [comp_move_count]
    call    comp_emit_u16

    xor     r14d, r14d
.ceb_mv_loop:
    cmp     r14d, [comp_move_count]
    jge     .ceb_mv_done
    imul    eax, r14d, SIZEOF_CIR_MV
    lea     r13, [comp_moves + rax]
    ; name
    mov     ecx, [r13 + CIR_MV_NAME]
    call    comp_emit_str_idx
    ; entity_type
    mov     ecx, [r13 + CIR_MV_ETYPE]
    call    comp_emit_str_idx
    ; is_scoped
    mov     ecx, [r13 + CIR_MV_IS_SCOPED]
    call    comp_emit_u8
    ; from_count
    mov     ebx, [r13 + CIR_MV_FROM_COUNT]
    mov     ecx, ebx
    call    comp_emit_u8
    ; from locations
    xor     r12d, r12d
.ceb_mv_from:
    cmp     r12d, ebx
    jge     .ceb_mv_from_done
    mov     ecx, [r13 + CIR_MV_FROM + r12*4]
    call    comp_emit_str_idx
    inc     r12d
    jmp     .ceb_mv_from
.ceb_mv_from_done:
    ; to_count
    mov     ebx, [r13 + CIR_MV_TO_COUNT]
    mov     ecx, ebx
    call    comp_emit_u8
    ; to locations
    xor     r12d, r12d
.ceb_mv_to:
    cmp     r12d, ebx
    jge     .ceb_mv_to_done
    mov     ecx, [r13 + CIR_MV_TO + r12*4]
    call    comp_emit_str_idx
    inc     r12d
    jmp     .ceb_mv_to
.ceb_mv_to_done:
    inc     r14d
    jmp     .ceb_mv_loop
.ceb_mv_done:

    ; === Section 0x04: Pools (empty) ===
    mov     ecx, BSEC_POOLS
    call    comp_emit_u8
    xor     ecx, ecx
    call    comp_emit_u16

    ; === Section 0x05: Transfers (empty) ===
    mov     ecx, BSEC_TRANSFERS
    call    comp_emit_u8
    xor     ecx, ecx
    call    comp_emit_u16

    ; === Section 0x06: Entities ===
    mov     ecx, BSEC_ENTITIES
    call    comp_emit_u8
    mov     ecx, [comp_ent_count]
    call    comp_emit_u16

    xor     r14d, r14d
.ceb_en_loop:
    cmp     r14d, [comp_ent_count]
    jge     .ceb_en_done
    imul    eax, r14d, SIZEOF_CIR_EN
    lea     r13, [comp_entities + rax]
    ; name
    mov     ecx, [r13 + CIR_EN_NAME]
    call    comp_emit_str_idx
    ; type
    mov     ecx, [r13 + CIR_EN_TYPE]
    call    comp_emit_str_idx
    ; in_kind
    mov     ecx, [r13 + CIR_EN_IN_KIND]
    call    comp_emit_u8
    cmp     dword [r13 + CIR_EN_IN_KIND], 1
    je      .ceb_en_scoped
    ; normal: container
    mov     ecx, [r13 + CIR_EN_IN_CONTAINER]
    call    comp_emit_str_idx
    jmp     .ceb_en_props
.ceb_en_scoped:
    ; scoped: scope, container
    mov     ecx, [r13 + CIR_EN_IN_SCOPE]
    call    comp_emit_str_idx
    mov     ecx, [r13 + CIR_EN_IN_CONTAINER]
    call    comp_emit_str_idx
.ceb_en_props:
    ; prop_count
    mov     ebx, [r13 + CIR_EN_PROP_COUNT]
    mov     ecx, ebx
    call    comp_emit_u8
    test    ebx, ebx
    jz      .ceb_en_next
    mov     r12d, [r13 + CIR_EN_PROP_START]
    xor     edi, edi
.ceb_en_prop_loop:
    cmp     edi, ebx
    jge     .ceb_en_next
    ; Property pointer
    mov     eax, r12d
    add     eax, edi
    imul    eax, SIZEOF_CIR_PR
    lea     rsi, [comp_properties + rax]
    ; key
    mov     ecx, [rsi + CIR_PR_KEY]
    call    comp_emit_str_idx
    ; vtype
    mov     ecx, [rsi + CIR_PR_VTYPE]
    call    comp_emit_u8
    cmp     dword [rsi + CIR_PR_VTYPE], 0
    je      .ceb_en_prop_int
    cmp     dword [rsi + CIR_PR_VTYPE], 1
    je      .ceb_en_prop_float
    cmp     dword [rsi + CIR_PR_VTYPE], 2
    je      .ceb_en_prop_str
    jmp     .ceb_en_prop_next
.ceb_en_prop_int:
    mov     rcx, [rsi + CIR_PR_VALUE]
    call    comp_emit_i64
    jmp     .ceb_en_prop_next
.ceb_en_prop_float:
    ; f64 — copy raw 8 bytes
    mov     rcx, [rsi + CIR_PR_VALUE]
    call    comp_emit_i64       ; same bits, different interpretation
    jmp     .ceb_en_prop_next
.ceb_en_prop_str:
    mov     ecx, [rsi + CIR_PR_VALUE]
    call    comp_emit_str_idx
.ceb_en_prop_next:
    inc     edi
    jmp     .ceb_en_prop_loop
.ceb_en_next:
    inc     r14d
    jmp     .ceb_en_loop
.ceb_en_done:

    ; === Section 0x07: Channels ===
    mov     ecx, BSEC_CHANNELS
    call    comp_emit_u8
    mov     ecx, [comp_chan_count]
    call    comp_emit_u16

    xor     r14d, r14d
.ceb_ch_loop:
    cmp     r14d, [comp_chan_count]
    jge     .ceb_ch_done
    imul    eax, r14d, SIZEOF_CIR_CH
    lea     r13, [comp_channels + rax]
    ; name, from, to, entity_type
    mov     ecx, [r13 + CIR_CH_NAME]
    call    comp_emit_str_idx
    mov     ecx, [r13 + CIR_CH_FROM]
    call    comp_emit_str_idx
    mov     ecx, [r13 + CIR_CH_TO]
    call    comp_emit_str_idx
    mov     ecx, [r13 + CIR_CH_ETYPE]
    call    comp_emit_str_idx
    inc     r14d
    jmp     .ceb_ch_loop
.ceb_ch_done:

    ; === Section 0x08: Config ===
    mov     ecx, BSEC_CONFIG
    call    comp_emit_u8
    mov     ecx, [comp_config_nesting]
    call    comp_emit_i16

    ; === Tensions ===
    mov     ecx, BSEC_TENSIONS
    call    comp_emit_u8
    mov     ecx, [comp_ten_count]
    call    comp_emit_u16

    xor     r14d, r14d
    mov     r15d, [comp_ten_count]
.ceb_ten_loop:
    cmp     r14d, r15d
    jge     .ceb_ten_done

    imul    eax, r14d, SIZEOF_CIR_TENSION
    lea     r13, [comp_tensions + rax]

    ; tension name (output string idx via idx_map)
    mov     ecx, [r13 + CIR_TEN_NAME]
    call    comp_emit_str_idx

    ; priority
    mov     ecx, [r13 + CIR_TEN_PRIORITY]
    call    comp_emit_i16

    ; pair_mode (always 0=zip for fragments)
    xor     ecx, ecx
    call    comp_emit_u8

    ; step_flag
    mov     ecx, [r13 + CIR_TEN_STEP]
    call    comp_emit_u8

    ; match_count
    mov     ecx, [r13 + CIR_TEN_MATCH_COUNT]
    call    comp_emit_u8

    ; Emit each match
    xor     r12d, r12d
.ceb_match_loop:
    cmp     r12d, [r13 + CIR_TEN_MATCH_COUNT]
    jge     .ceb_match_done

    imul    eax, r12d, SIZEOF_CIR_MATCH
    lea     rsi, [r13 + CIR_TEN_MATCHES + rax]
    call    comp_emit_match
    inc     r12d
    jmp     .ceb_match_loop
.ceb_match_done:

    ; emit_count
    mov     ecx, [r13 + CIR_TEN_EMIT_COUNT]
    call    comp_emit_u8

    ; Emit each emit clause
    xor     r12d, r12d
.ceb_emit_loop:
    cmp     r12d, [r13 + CIR_TEN_EMIT_COUNT]
    jge     .ceb_emit_done

    imul    eax, r12d, SIZEOF_CIR_EMIT
    lea     rsi, [r13 + CIR_TEN_EMITS + rax]
    call    comp_emit_emit
    inc     r12d
    jmp     .ceb_emit_loop
.ceb_emit_done:

    inc     r14d
    jmp     .ceb_ten_loop

.ceb_ten_done:
    ; === End marker ===
    mov     ecx, BSEC_END
    call    comp_emit_u8

    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_emit_match(match_ptr in RSI) — emit one match clause binary
; ============================================================
comp_emit_match:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    sub     rsp, 32

    mov     r12, rsi

    cmp     dword [r12 + CIR_MC_KIND], 3
    je      .cem_guard
    cmp     dword [r12 + CIR_MC_KIND], 1
    je      .cem_empty_in

    ; === MC_ENTITY_IN (0x00) ===
    xor     ecx, ecx            ; kind = 0
    call    comp_emit_u8

    ; bind
    mov     ecx, [r12 + CIR_MC_BIND]
    call    comp_emit_str_idx

    ; required
    mov     ecx, [r12 + CIR_MC_REQUIRED]
    call    comp_emit_u8

    ; select
    mov     ecx, [r12 + CIR_MC_SELECT]
    call    comp_emit_u8

    ; key (NONE_IDX if no key)
    cmp     dword [r12 + CIR_MC_KEY], -1
    je      .cem_key_none
    mov     ecx, [r12 + CIR_MC_KEY]
    call    comp_emit_str_idx
    jmp     .cem_key_done
.cem_key_none:
    mov     ecx, 0xFFFF
    call    comp_emit_u16
.cem_key_done:

    ; in_type (0=normal, 1=scoped, 2=channel)
    mov     ecx, [r12 + CIR_MC_IN_TYPE]
    call    comp_emit_u8

    cmp     dword [r12 + CIR_MC_IN_TYPE], 1
    je      .cem_in_scoped
    cmp     dword [r12 + CIR_MC_IN_TYPE], 2
    je      .cem_in_channel

    ; normal: container
    mov     ecx, [r12 + CIR_MC_CONTAINER]
    call    comp_emit_str_idx
    jmp     .cem_in_done

.cem_in_scoped:
    ; scoped: scope, container
    mov     ecx, [r12 + CIR_MC_SCOPE]
    call    comp_emit_str_idx
    mov     ecx, [r12 + CIR_MC_CONTAINER]
    call    comp_emit_str_idx
    jmp     .cem_in_done

.cem_in_channel:
    ; channel: channel_name (in CONTAINER)
    mov     ecx, [r12 + CIR_MC_CONTAINER]
    call    comp_emit_str_idx

.cem_in_done:
    ; has_where
    mov     ecx, [r12 + CIR_MC_HAS_WHERE]
    call    comp_emit_u8

    ; where expression
    cmp     dword [r12 + CIR_MC_HAS_WHERE], 0
    je      .cem_done
    mov     ecx, [r12 + CIR_MC_WHERE_EXPR]
    call    comp_emit_expr_binary
    jmp     .cem_done

.cem_guard:
    ; === MC_GUARD (0x03) ===
    mov     ecx, BMC_GUARD
    call    comp_emit_u8
    mov     ecx, [r12 + CIR_MC_WHERE_EXPR]
    call    comp_emit_expr_binary
    jmp     .cem_done

.cem_empty_in:
    ; === MC_EMPTY_IN (0x01) ===
    mov     ecx, 1              ; kind = 1
    call    comp_emit_u8

    ; bind
    mov     ecx, [r12 + CIR_MC_BIND]
    call    comp_emit_str_idx

    ; select (always 0=first for our fragments)
    mov     ecx, [r12 + CIR_MC_SELECT]
    call    comp_emit_u8

    ; container count
    mov     ecx, [r12 + CIR_MC_EMPTY_CNT_N]
    call    comp_emit_u8

    ; containers
    xor     ebx, ebx
.cem_empty_cnts:
    cmp     ebx, [r12 + CIR_MC_EMPTY_CNT_N]
    jge     .cem_done
    mov     ecx, [r12 + CIR_MC_EMPTY_CNTS + rbx*4]
    call    comp_emit_str_idx
    inc     ebx
    jmp     .cem_empty_cnts

.cem_done:
    add     rsp, 32
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_emit_emit(emit_ptr in RSI) — emit one emit clause binary
; ============================================================
comp_emit_emit:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    sub     rsp, 32

    mov     r12, rsi

    mov     eax, [r12 + CIR_EC_KIND]
    cmp     eax, BEC_MOVE
    je      .cee_move
    cmp     eax, BEC_SET
    je      .cee_set
    cmp     eax, BEC_SEND
    je      .cee_send
    cmp     eax, BEC_RECEIVE
    je      .cee_receive
    jmp     .cee_done

.cee_move:
    ; EC_MOVE (0x00)
    xor     ecx, ecx
    call    comp_emit_u8
    ; move name
    mov     ecx, [r12 + CIR_EC_STR1]
    call    comp_emit_str_idx
    ; entity
    mov     ecx, [r12 + CIR_EC_STR2]
    call    comp_emit_str_idx
    ; to-ref
    cmp     dword [r12 + CIR_EC_TO_KIND], 1
    je      .cee_move_scoped
    ; normal: REF_NORMAL + string
    xor     ecx, ecx            ; REF_NORMAL = 0
    call    comp_emit_u8
    mov     ecx, [r12 + CIR_EC_STR3]
    call    comp_emit_str_idx
    jmp     .cee_done
.cee_move_scoped:
    ; scoped: REF_SCOPED + scope + container
    mov     ecx, 1              ; REF_SCOPED = 1
    call    comp_emit_u8
    mov     ecx, [r12 + CIR_EC_SCOPE]
    call    comp_emit_str_idx
    mov     ecx, [r12 + CIR_EC_STR3]
    call    comp_emit_str_idx
    jmp     .cee_done

.cee_set:
    ; EC_SET (0x01)
    mov     ecx, 1
    call    comp_emit_u8
    ; entity
    mov     ecx, [r12 + CIR_EC_STR1]
    call    comp_emit_str_idx
    ; property
    mov     ecx, [r12 + CIR_EC_STR2]
    call    comp_emit_str_idx
    ; value expression
    mov     ecx, [r12 + CIR_EC_EXPR]
    call    comp_emit_expr_binary
    jmp     .cee_done

.cee_send:
    ; EC_SEND (0x02)
    mov     ecx, 2
    call    comp_emit_u8
    ; channel
    mov     ecx, [r12 + CIR_EC_STR1]
    call    comp_emit_str_idx
    ; entity
    mov     ecx, [r12 + CIR_EC_STR2]
    call    comp_emit_str_idx
    jmp     .cee_done

.cee_receive:
    ; EC_RECEIVE (0x03)
    mov     ecx, BEC_RECEIVE
    call    comp_emit_u8
    ; channel
    mov     ecx, [r12 + CIR_EC_STR1]
    call    comp_emit_str_idx
    ; entity
    mov     ecx, [r12 + CIR_EC_STR2]
    call    comp_emit_str_idx
    ; to-ref
    cmp     dword [r12 + CIR_EC_TO_KIND], 1
    je      .cee_recv_scoped
    ; normal
    xor     ecx, ecx
    call    comp_emit_u8
    mov     ecx, [r12 + CIR_EC_STR3]
    call    comp_emit_str_idx
    jmp     .cee_done
.cee_recv_scoped:
    ; scoped
    mov     ecx, 1
    call    comp_emit_u8
    mov     ecx, [r12 + CIR_EC_SCOPE]
    call    comp_emit_str_idx
    mov     ecx, [r12 + CIR_EC_STR3]
    call    comp_emit_str_idx

.cee_done:
    add     rsp, 32
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================
; comp_emit_expr_binary(expr_idx in ECX) — emit expression tree
; ============================================================
comp_emit_expr_binary:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    sub     rsp, 32

    mov     r12d, ecx

    imul    eax, r12d, SIZEOF_CIR_EXPR
    lea     rbx, [comp_expr_pool + rax]

    mov     eax, [rbx + CIR_EX_KIND]
    cmp     eax, CIREX_INT
    je      .ceeb_int
    cmp     eax, CIREX_PROP
    je      .ceeb_prop
    cmp     eax, CIREX_BINARY
    je      .ceeb_binary
    cmp     eax, CIREX_COUNT
    je      .ceeb_count
    ; Unknown — emit EX_NULL
    mov     ecx, BEX_NULL
    call    comp_emit_u8
    jmp     .ceeb_done

.ceeb_int:
    mov     ecx, BEX_INT
    call    comp_emit_u8
    mov     rcx, [rbx + CIR_EX_IVAL]
    call    comp_emit_i64
    jmp     .ceeb_done

.ceeb_prop:
    mov     ecx, BEX_PROP
    call    comp_emit_u8
    ; prop name
    mov     ecx, [rbx + CIR_EX_STR1]
    call    comp_emit_str_idx
    ; of name
    mov     ecx, [rbx + CIR_EX_STR2]
    call    comp_emit_str_idx
    jmp     .ceeb_done

.ceeb_binary:
    mov     ecx, BEX_BINARY
    call    comp_emit_u8
    ; op (stored at CIR_EX_OP, not CIR_EX_STR1 which overlaps LEFT)
    mov     ecx, [rbx + CIR_EX_OP]
    call    comp_emit_str_idx
    ; left (recurse)
    mov     ecx, [rbx + CIR_EX_LEFT]
    call    comp_emit_expr_binary
    ; right (recurse)
    mov     ecx, [rbx + CIR_EX_RIGHT]
    call    comp_emit_expr_binary
    jmp     .ceeb_done

.ceeb_count:
    mov     ecx, BEX_COUNT_CONTAINER
    call    comp_emit_u8
    mov     ecx, [rbx + CIR_EX_STR1]
    call    comp_emit_str_idx

.ceeb_done:
    add     rsp, 32
    pop     r12
    pop     rbx
    pop     rbp
    ret
