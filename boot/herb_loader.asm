; boot/herb_loader.asm — HERB Binary Loader in Assembly
;
; Phase 4h: Binary loader + init/load ported from C to x86-64:
;   alloc_expr, br_u8, br_u16, br_i16, br_i64, br_f64, bstr,
;   br_expr, br_to_ref, load_program_binary, herb_load_program,
;   herb_init, herb_load
;
; Register convention: MS x64 ABI
;   Args:    RCX, RDX, R8, R9 (integer/pointer)
;   Return:  RAX (integer/pointer), XMM0 (float/double)
;   Caller-saved: RAX, RCX, RDX, R8-R11
;   Callee-saved: RBX, RSI, RDI, R12-R15, RBP
;   Shadow space: 32 bytes before each CALL
;   Stack: 16-byte aligned at CALL instruction
;
; Assembled with: nasm -f win64 herb_loader.asm -o herb_loader.o

[bits 64]
default rel

%include "herb_graph_layout.inc"
%include "herb_freestanding_layout.inc"

; External functions from herb_graph.asm
extern intern
extern str_of
extern entity_set_prop
extern create_entity
extern graph_find_container_by_name
extern graph_find_entity_by_name
extern graph_find_move_type_by_name
extern graph_find_channel_by_name
extern graph_find_transfer_by_name
extern get_scoped_container
extern ham_mark_dirty

; External functions from herb_freestanding.asm
extern herb_memset
extern herb_memcpy
extern herb_error
extern herb_snprintf
extern herb_arena_init
extern herb_set_error_handler


; External data
extern g_graph          ; Graph (720568 bytes)
extern g_strings        ; char[2048][128]
extern g_string_count   ; int
extern g_expr_pool      ; Expr[4096]
extern g_expr_count     ; int

; Export our functions
global alloc_expr
global load_program_binary
global herb_load_program
global herb_init
global herb_load

section .bss
    g_bin_str_ids:   resd MAX_STRINGS      ; int[2048] — binary string table mapping
    g_bin_str_count: resd 1                 ; int
    arena_storage:   resb SIZEOF_ARENA      ; HerbArena — static storage for herb_init
    g_arena_ptr:     resq 1                 ; HerbArena* — pointer to arena_storage

section .rdata
    str_expr_full:    db "expr pool full", 0
    str_bin_short:    db "binary too short", 0
    str_bad_magic:    db "bad magic", 0
    str_bad_version:  db "unsupported version", 0
    str_json_disabled: db "JSON loading disabled (HERB_BINARY_ONLY)", 0
    str_unknown_sec:  db "unknown binary section", 0
    str_frag_infra:   db "program fragment has non-empty infrastructure section", 0
    str_chan_fmt:      db "channel:%s", 0
    str_name_fmt:     db "%s.%s", 0

section .text

; ============================================================
; alloc_expr() -> Expr*
;
; Allocates an expression from the global pool.
; Returns pointer to zeroed Expr, or NULL if pool full.
; ============================================================
alloc_expr:
    push    rbp
    mov     rbp, rsp
    push    rbx
    sub     rsp, 40             ; shadow(32) + align(8)
    ; Alignment: ret(8) + push rbp(8) + push rbx(8) + sub 40 = 64 total, 64%16=0 ✓

    ; Check if pool is full
    lea     rax, [g_expr_count]
    mov     eax, [rax]
    cmp     eax, MAX_EXPR_POOL
    jge     .ae_full

    ; Compute pointer: &g_expr_pool[count]
    mov     ecx, eax
    imul    ecx, SIZEOF_EXPR
    lea     rbx, [g_expr_pool]
    add     rbx, rcx            ; RBX = new Expr* (callee-saved)

    ; Increment count
    lea     rax, [g_expr_count]
    inc     dword [rax]

    ; herb_memset(e, 0, sizeof(Expr))
    mov     rcx, rbx
    xor     edx, edx
    mov     r8d, SIZEOF_EXPR
    call    herb_memset

    mov     rax, rbx            ; return pointer
    jmp     .ae_return

.ae_full:
    xor     ecx, ecx
    lea     rdx, [str_expr_full]
    call    herb_error
    xor     eax, eax            ; return NULL

.ae_return:
    add     rsp, 40
    pop     rbx
    pop     rbp
    ret


; ============================================================
; br_u8(BinReader* r) -> uint8_t in EAX
;
; Leaf function — reads one byte, advances pos.
; RCX = BinReader*
; ============================================================
br_u8:
    mov     rax, [rcx + BR_POS]
    cmp     rax, [rcx + BR_LEN]
    jge     .br_u8_eof
    mov     rdx, [rcx + BR_DATA]
    movzx   eax, byte [rdx + rax]
    inc     qword [rcx + BR_POS]
    ret
.br_u8_eof:
    xor     eax, eax
    ret


; ============================================================
; br_u16(BinReader* r) -> uint16_t in EAX
;
; Leaf function — reads two bytes LE, advances pos by 2.
; RCX = BinReader*
; ============================================================
br_u16:
    mov     rax, [rcx + BR_POS]
    lea     rdx, [rax + 2]
    cmp     rdx, [rcx + BR_LEN]
    jg      .br_u16_eof
    mov     rdx, [rcx + BR_DATA]
    add     rdx, rax                        ; RDX = &data[pos]
    movzx   eax, byte [rdx]                ; low byte
    movzx   r8d, byte [rdx + 1]            ; high byte
    shl     r8d, 8
    or      eax, r8d
    add     qword [rcx + BR_POS], 2
    ret
.br_u16_eof:
    xor     eax, eax
    ret


; ============================================================
; br_i16(BinReader* r) -> int16_t in EAX (sign-extended to int)
;
; Leaf function — calls br_u16 logic inline, sign-extends.
; RCX = BinReader*
; ============================================================
br_i16:
    mov     rax, [rcx + BR_POS]
    lea     rdx, [rax + 2]
    cmp     rdx, [rcx + BR_LEN]
    jg      .br_i16_eof
    mov     rdx, [rcx + BR_DATA]
    add     rdx, rax                        ; RDX = &data[pos]
    movzx   eax, byte [rdx]
    movzx   r8d, byte [rdx + 1]
    shl     r8d, 8
    or      eax, r8d
    movsx   eax, ax             ; sign-extend 16-bit to 32-bit
    add     qword [rcx + BR_POS], 2
    ret
.br_i16_eof:
    xor     eax, eax
    ret


; ============================================================
; br_i64(BinReader* r) -> int64_t in RAX
;
; Leaf function — reads 8 bytes LE, advances pos by 8.
; RCX = BinReader*
; ============================================================
br_i64:
    mov     rax, [rcx + BR_POS]
    lea     rdx, [rax + 8]
    cmp     rdx, [rcx + BR_LEN]
    jg      .br_i64_eof
    mov     rdx, [rcx + BR_DATA]
    add     rdx, rax            ; RDX = &data[pos]
    mov     rax, [rdx]          ; read 8 bytes (x86 is LE, so this works)
    add     qword [rcx + BR_POS], 8
    ret
.br_i64_eof:
    xor     eax, eax
    ret


; ============================================================
; br_f64(BinReader* r) -> double in XMM0
;
; Leaf function — reads 8 bytes LE as double.
; RCX = BinReader*
; ============================================================
br_f64:
    mov     rax, [rcx + BR_POS]
    lea     rdx, [rax + 8]
    cmp     rdx, [rcx + BR_LEN]
    jg      .br_f64_eof
    mov     rdx, [rcx + BR_DATA]
    add     rdx, rax
    movsd   xmm0, [rdx]        ; load 8 bytes as double
    add     qword [rcx + BR_POS], 8
    ret
.br_f64_eof:
    xorpd   xmm0, xmm0         ; return 0.0
    ret


; ============================================================
; bstr(uint16_t idx) -> int string_id in EAX
;
; Leaf function — looks up binary string index in mapping table.
; ECX = idx (uint16_t)
; Returns interned string id, or -1 if idx == 0xFFFF or out of range.
; ============================================================
bstr:
    cmp     cx, 0xFFFF
    je      .bstr_none
    movzx   eax, cx
    lea     rdx, [g_bin_str_count]
    cmp     eax, [rdx]
    jge     .bstr_none
    lea     rdx, [g_bin_str_ids]
    mov     eax, [rdx + rax*4]
    ret
.bstr_none:
    mov     eax, -1
    ret


; ============================================================
; br_expr(BinReader* r) -> Expr* in RAX
;
; Parses an expression from binary. Recursive (BINARY has left/right).
; RCX = BinReader*
; ============================================================
br_expr:
    push    rbp
    mov     rbp, rsp
    push    rbx             ; RBX = BinReader*
    push    rsi             ; RSI = Expr*
    push    rdi             ; RDI = scratch
    push    r12             ; R12 = scratch
    sub     rsp, 32         ; shadow space (32 + 4 pushes*8=32 = 64, total from rbp: 64+8=72 odd, need +8)
    ; After push rbp (8) + 4 pushes (32) + sub 32 = 72 bytes. Entry was 8 mod 16.
    ; 8 + 72 = 80, 80 % 16 = 0 ✓

    mov     rbx, rcx        ; RBX = BinReader*

    ; uint8_t kind = br_u8(r)
    ; RCX = rbx already
    call    br_u8
    cmp     al, 0xFF
    je      .bre_null

    movzx   edi, al         ; EDI = kind

    ; Expr* e = alloc_expr()
    call    alloc_expr
    test    rax, rax
    jz      .bre_null
    mov     rsi, rax        ; RSI = e

    ; Switch on kind
    cmp     edi, 0x00
    je      .bre_int
    cmp     edi, 0x01
    je      .bre_float
    cmp     edi, 0x02
    je      .bre_string
    cmp     edi, 0x03
    je      .bre_bool
    cmp     edi, 0x04
    je      .bre_prop
    cmp     edi, 0x05
    je      .bre_count
    cmp     edi, 0x06
    je      .bre_count_scoped
    cmp     edi, 0x07
    je      .bre_count_channel
    cmp     edi, 0x08
    je      .bre_binary
    cmp     edi, 0x09
    je      .bre_unary
    cmp     edi, 0x0A
    je      .bre_in_of
    ; Unknown kind — return NULL
    jmp     .bre_null

.bre_int:
    ; e->kind = EX_INT; e->int_val = br_i64(r)
    mov     dword [rsi + EX_KIND], EX_INT_T
    mov     rcx, rbx
    call    br_i64
    mov     [rsi + EX_INT_VAL], rax
    jmp     .bre_done

.bre_float:
    ; e->kind = EX_FLOAT; e->float_val = br_f64(r)
    mov     dword [rsi + EX_KIND], EX_FLOAT_T
    mov     rcx, rbx
    call    br_f64
    movsd   [rsi + EX_FLOAT_VAL], xmm0
    jmp     .bre_done

.bre_string:
    ; e->kind = EX_STRING; e->string_id = bstr(br_u16(r))
    mov     dword [rsi + EX_KIND], EX_STRING_T
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EX_STRING_ID], eax
    jmp     .bre_done

.bre_bool:
    ; e->kind = EX_BOOL; e->bool_val = br_u8(r)
    mov     dword [rsi + EX_KIND], EX_BOOL_T
    mov     rcx, rbx
    call    br_u8
    mov     [rsi + EX_BOOL_VAL], eax
    jmp     .bre_done

.bre_prop:
    ; e->kind = EX_PROP; e->prop.prop_id = bstr(br_u16(r)); e->prop.of_id = bstr(br_u16(r))
    mov     dword [rsi + EX_KIND], EX_PROP_T
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EX_PROP_ID], eax
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EX_OF_ID], eax
    jmp     .bre_done

.bre_count:
    ; e->kind = EX_COUNT; e->count.container_idx = graph_find_container_by_name(bstr(br_u16(r)))
    ; e->count.is_scoped = 0; e->count.is_channel = 0
    mov     dword [rsi + EX_KIND], EX_COUNT_T
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [rsi + EX_COUNT_CIDX], eax
    mov     dword [rsi + EX_COUNT_SCOPED], 0
    mov     dword [rsi + EX_COUNT_ISCHAN], 0
    jmp     .bre_done

.bre_count_scoped:
    ; e->kind = EX_COUNT; is_scoped=1, is_channel=0, container_idx=-1
    ; scope_bind_id = bstr(br_u16(r)); scope_cname_id = bstr(br_u16(r))
    mov     dword [rsi + EX_KIND], EX_COUNT_T
    mov     dword [rsi + EX_COUNT_SCOPED], 1
    mov     dword [rsi + EX_COUNT_ISCHAN], 0
    mov     dword [rsi + EX_COUNT_CIDX], -1
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EX_COUNT_SBIND], eax
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EX_COUNT_SCNAME], eax
    jmp     .bre_done

.bre_count_channel:
    ; e->kind = EX_COUNT; is_channel=1, is_scoped=0, container_idx=-1
    ; channel_idx = graph_find_channel_by_name(bstr(br_u16(r)))
    mov     dword [rsi + EX_KIND], EX_COUNT_T
    mov     dword [rsi + EX_COUNT_ISCHAN], 1
    mov     dword [rsi + EX_COUNT_SCOPED], 0
    mov     dword [rsi + EX_COUNT_CIDX], -1
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_channel_by_name
    mov     [rsi + EX_COUNT_CHANIDX], eax
    jmp     .bre_done

.bre_binary:
    ; e->kind = EX_BINARY; op_id = bstr(br_u16(r))
    ; left = br_expr(r); right = br_expr(r)
    mov     dword [rsi + EX_KIND], EX_BINARY_T
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EX_BINARY_OP_ID], eax
    ; left = br_expr(r)
    mov     rcx, rbx
    call    br_expr
    mov     [rsi + EX_BINARY_LEFT], rax
    ; right = br_expr(r)
    mov     rcx, rbx
    call    br_expr
    mov     [rsi + EX_BINARY_RIGHT], rax
    jmp     .bre_done

.bre_unary:
    ; e->kind = EX_UNARY; e->unary.arg = br_expr(r)
    mov     dword [rsi + EX_KIND], EX_UNARY_T
    mov     rcx, rbx
    call    br_expr
    mov     [rsi + EX_UNARY_ARG], rax
    jmp     .bre_done

.bre_in_of:
    ; e->kind = EX_IN_OF
    ; e->in_of.container_idx = graph_find_container_by_name(bstr(br_u16(r)))
    ; e->in_of.entity_ref_id = bstr(br_u16(r))
    mov     dword [rsi + EX_KIND], EX_INOF_T
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [rsi + EX_INOF_CIDX], eax
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EX_INOF_EREF], eax
    jmp     .bre_done

.bre_done:
    mov     rax, rsi        ; return e
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

.bre_null:
    xor     eax, eax        ; return NULL
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; br_to_ref(BinReader* r, int* out_ref, int* out_scope_bind, int* out_scope_cname)
;
; Parses a reference target from binary.
; RCX = BinReader*, RDX = out_ref, R8 = out_scope_bind, R9 = out_scope_cname
; ============================================================
br_to_ref:
    push    rbp
    mov     rbp, rsp
    push    rbx             ; RBX = BinReader*
    push    rsi             ; RSI = out_ref
    push    rdi             ; RDI = out_scope_bind
    push    r12             ; R12 = out_scope_cname
    sub     rsp, 32         ; shadow

    mov     rbx, rcx
    mov     rsi, rdx
    mov     rdi, r8
    mov     r12, r9

    ; Initialize outputs to -1
    mov     dword [rsi], -1
    mov     dword [rdi], -1
    mov     dword [r12], -1

    ; uint8_t kind = br_u8(r)
    mov     rcx, rbx
    call    br_u8

    cmp     al, 0x00
    je      .btr_normal
    cmp     al, 0x01
    je      .btr_scoped
    ; kind == 0x02 = NONE — no data
    jmp     .btr_done

.btr_normal:
    ; *out_ref = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi], eax
    jmp     .btr_done

.btr_scoped:
    ; *out_scope_bind = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi], eax
    ; *out_scope_cname = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [r12], eax

.btr_done:
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; _parse_match_clause(BinReader* r, MatchClause* mc)
;
; Internal helper — parses one match clause from binary.
; Shared by load_program_binary and herb_load_program.
; RCX = BinReader*, RDX = MatchClause*
; ============================================================
_parse_match_clause:
    push    rbp
    mov     rbp, rsp
    push    rbx             ; RBX = BinReader*
    push    rsi             ; RSI = MatchClause*
    push    rdi             ; scratch
    push    r12             ; scratch
    push    r13             ; scratch
    sub     rsp, 40         ; shadow + align (5 pushes + rbp = 48, entry +8 = 56, 56+40=96, 96%16=0)

    mov     rbx, rcx
    mov     rsi, rdx

    ; Initialize MatchClause with defaults
    mov     rcx, rsi
    xor     edx, edx
    mov     r8d, SIZEOF_MATCHCLAUSE
    call    herb_memset
    mov     dword [rsi + MC_REQUIRED], 1
    mov     dword [rsi + MC_BIND_ID], -1
    mov     dword [rsi + MC_CONTAINER_IDX], -1
    mov     dword [rsi + MC_SCOPE_BIND_ID], -1
    mov     dword [rsi + MC_SCOPE_CNAME_ID], -1
    mov     dword [rsi + MC_CHANNEL_IDX], -1
    mov     dword [rsi + MC_KEY_PROP_ID], -1

    ; uint8_t mk = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    movzx   edi, al         ; EDI = mk

    cmp     edi, 0x00
    je      .pmc_entity_in
    cmp     edi, 0x01
    je      .pmc_empty_in
    cmp     edi, 0x02
    je      .pmc_container_is
    cmp     edi, 0x03
    je      .pmc_guard
    jmp     .pmc_done

.pmc_entity_in:
    mov     dword [rsi + MC_KIND], MC_ENTITY_IN_V
    ; bind_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + MC_BIND_ID], eax
    ; required = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    mov     [rsi + MC_REQUIRED], eax
    ; sel = br_u8(r); convert to SelectMode
    mov     rcx, rbx
    call    br_u8
    ; sel: 0=FIRST, 1=EACH, 2=MAX_BY, 3=MIN_BY
    cmp     al, 1
    je      .pmc_sel_each
    cmp     al, 2
    je      .pmc_sel_max
    cmp     al, 3
    je      .pmc_sel_min
    mov     dword [rsi + MC_SELECT], SEL_FIRST_V
    jmp     .pmc_sel_done
.pmc_sel_each:
    mov     dword [rsi + MC_SELECT], SEL_EACH_V
    jmp     .pmc_sel_done
.pmc_sel_max:
    mov     dword [rsi + MC_SELECT], SEL_MAX_BY_V
    jmp     .pmc_sel_done
.pmc_sel_min:
    mov     dword [rsi + MC_SELECT], SEL_MIN_BY_V
.pmc_sel_done:
    ; key_prop_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + MC_KEY_PROP_ID], eax
    ; ik = br_u8(r) — container source kind
    mov     rcx, rbx
    call    br_u8
    movzx   edi, al         ; EDI = ik
    cmp     edi, 0
    je      .pmc_ik_normal
    cmp     edi, 1
    je      .pmc_ik_scoped
    cmp     edi, 2
    je      .pmc_ik_channel
    jmp     .pmc_ei_where
.pmc_ik_normal:
    ; container_idx = graph_find_container_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [rsi + MC_CONTAINER_IDX], eax
    jmp     .pmc_ei_where
.pmc_ik_scoped:
    ; scope_bind_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + MC_SCOPE_BIND_ID], eax
    ; scope_cname_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + MC_SCOPE_CNAME_ID], eax
    jmp     .pmc_ei_where
.pmc_ik_channel:
    ; channel_idx = graph_find_channel_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_channel_by_name
    mov     [rsi + MC_CHANNEL_IDX], eax
.pmc_ei_where:
    ; if (br_u8(r)) mc->where_expr = br_expr(r)
    mov     rcx, rbx
    call    br_u8
    test    al, al
    jz      .pmc_done
    mov     rcx, rbx
    call    br_expr
    mov     [rsi + MC_WHERE_EXPR], rax
    jmp     .pmc_done

.pmc_empty_in:
    mov     dword [rsi + MC_KIND], MC_EMPTY_IN_V
    ; bind_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + MC_BIND_ID], eax
    ; sel = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    cmp     al, 1
    je      .pmc_ei_each
    mov     dword [rsi + MC_SELECT], SEL_FIRST_V
    jmp     .pmc_ei_cnt
.pmc_ei_each:
    mov     dword [rsi + MC_SELECT], SEL_EACH_V
.pmc_ei_cnt:
    ; container_count = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    mov     [rsi + MC_CONTAINER_COUNT], eax
    mov     r12d, eax       ; R12 = container_count
    ; for k in 0..container_count: containers[k] = graph_find_container_by_name(bstr(br_u16(r)))
    xor     r13d, r13d      ; k = 0
.pmc_ei_cloop:
    cmp     r13d, r12d
    jge     .pmc_done
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [rsi + MC_CONTAINERS + r13*4], eax
    inc     r13d
    jmp     .pmc_ei_cloop

.pmc_container_is:
    mov     dword [rsi + MC_KIND], MC_CONTAINER_IS_V
    ; guard_container_idx = graph_find_container_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [rsi + MC_GUARD_CNT_IDX], eax
    ; is_empty = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    mov     [rsi + MC_IS_EMPTY], eax
    jmp     .pmc_done

.pmc_guard:
    mov     dword [rsi + MC_KIND], MC_GUARD_V
    ; guard_expr = br_expr(r)
    mov     rcx, rbx
    call    br_expr
    mov     [rsi + MC_GUARD_EXPR], rax

.pmc_done:
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; _parse_emit_clause(BinReader* r, EmitClause* ec)
;
; Internal helper — parses one emit clause from binary.
; Shared by load_program_binary and herb_load_program.
; RCX = BinReader*, RDX = EmitClause*
; ============================================================
_parse_emit_clause:
    push    rbp
    mov     rbp, rsp
    push    rbx             ; RBX = BinReader*
    push    rsi             ; RSI = EmitClause*
    push    rdi             ; scratch
    sub     rsp, 40         ; shadow + align

    mov     rbx, rcx
    mov     rsi, rdx

    ; Initialize EmitClause
    mov     rcx, rsi
    xor     edx, edx
    mov     r8d, SIZEOF_EMITCLAUSE
    call    herb_memset
    mov     dword [rsi + EC_TO_REF], -1
    mov     dword [rsi + EC_TO_SCOPE_BIND_ID], -1
    mov     dword [rsi + EC_RECV_TO_REF], -1
    mov     dword [rsi + EC_RECV_TO_SCOPE_BIND_ID], -1
    mov     dword [rsi + EC_DUP_IN_REF], -1
    mov     dword [rsi + EC_DUP_IN_SCOPE_BIND_ID], -1

    ; uint8_t ek = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    movzx   edi, al         ; EDI = ek

    cmp     edi, 0x00
    je      .pec_move
    cmp     edi, 0x01
    je      .pec_set
    cmp     edi, 0x02
    je      .pec_send
    cmp     edi, 0x03
    je      .pec_receive
    cmp     edi, 0x04
    je      .pec_transfer
    cmp     edi, 0x05
    je      .pec_duplicate
    jmp     .pec_done

.pec_move:
    mov     dword [rsi + EC_KIND], EC_MOVE_V
    ; move_type_idx = graph_find_move_type_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_move_type_by_name
    mov     [rsi + EC_MOVE_TYPE_IDX], eax
    ; entity_ref = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EC_ENTITY_REF], eax
    ; br_to_ref(r, &ec->to_ref, &ec->to_scope_bind_id, &ec->to_scope_cname_id)
    mov     rcx, rbx
    lea     rdx, [rsi + EC_TO_REF]
    lea     r8, [rsi + EC_TO_SCOPE_BIND_ID]
    lea     r9, [rsi + EC_TO_SCOPE_CNAME_ID]
    call    br_to_ref
    jmp     .pec_done

.pec_set:
    mov     dword [rsi + EC_KIND], EC_SET_V
    ; set_entity_ref = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EC_SET_ENTITY_REF], eax
    ; set_prop_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EC_SET_PROP_ID], eax
    ; value_expr = br_expr(r)
    mov     rcx, rbx
    call    br_expr
    mov     [rsi + EC_VALUE_EXPR], rax
    jmp     .pec_done

.pec_send:
    mov     dword [rsi + EC_KIND], EC_SEND_V
    ; send_channel_idx = graph_find_channel_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_channel_by_name
    mov     [rsi + EC_SEND_CHANNEL_IDX], eax
    ; send_entity_ref = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EC_SEND_ENTITY_REF], eax
    jmp     .pec_done

.pec_receive:
    mov     dword [rsi + EC_KIND], EC_RECEIVE_V
    ; recv_channel_idx = graph_find_channel_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_channel_by_name
    mov     [rsi + EC_RECV_CHANNEL_IDX], eax
    ; recv_entity_ref = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EC_RECV_ENTITY_REF], eax
    ; br_to_ref(r, &ec->recv_to_ref, &ec->recv_to_scope_bind_id, &ec->recv_to_scope_cname_id)
    mov     rcx, rbx
    lea     rdx, [rsi + EC_RECV_TO_REF]
    lea     r8, [rsi + EC_RECV_TO_SCOPE_BIND_ID]
    lea     r9, [rsi + EC_RECV_TO_SCOPE_CNAME_ID]
    call    br_to_ref
    jmp     .pec_done

.pec_transfer:
    mov     dword [rsi + EC_KIND], EC_TRANSFER_V
    ; transfer_type_idx = graph_find_transfer_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_transfer_by_name
    mov     [rsi + EC_TRANSFER_TYPE_IDX], eax
    ; transfer_from_ref = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EC_TRANSFER_FROM_REF], eax
    ; transfer_to_ref = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EC_TRANSFER_TO_REF], eax
    ; transfer_amount_expr = br_expr(r)
    mov     rcx, rbx
    call    br_expr
    mov     [rsi + EC_TRANSFER_AMOUNT_EXPR], rax
    jmp     .pec_done

.pec_duplicate:
    mov     dword [rsi + EC_KIND], EC_DUPLICATE_V
    ; dup_entity_ref = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rsi + EC_DUP_ENTITY_REF], eax
    ; br_to_ref(r, &ec->dup_in_ref, &ec->dup_in_scope_bind_id, &ec->dup_in_scope_cname_id)
    mov     rcx, rbx
    lea     rdx, [rsi + EC_DUP_IN_REF]
    lea     r8, [rsi + EC_DUP_IN_SCOPE_BIND_ID]
    lea     r9, [rsi + EC_DUP_IN_SCOPE_CNAME_ID]
    call    br_to_ref

.pec_done:
    add     rsp, 40
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; load_program_binary(const uint8_t* data, herb_size_t len) -> int
;
; Main binary loader. Parses HERB binary format and populates the graph.
; RCX = data pointer, RDX = length
; Returns 0 on success, -1 on error.
;
; Stack frame (344 bytes local):
;   [rsp+0..31]    shadow space
;   [rsp+32..39]   5th arg slot
;   [rsp+40..63]   BinReader struct (24 bytes)
;   [rsp+64..79]   PropVal temp (16 bytes)
;   [rsp+80..335]  tmp buffer (256 bytes)
;   [rsp+336..343] padding
;
; Callee-saved register usage:
;   RBX = &BinReader (rsp+40)
;   RSI, RDI, R12, R13, R14, R15 — section-specific
; ============================================================

%define LPB_SHADOW      0
%define LPB_5TH_ARG     32
%define LPB_READER      40
%define LPB_PROPVAL     64
%define LPB_TMPBUF      80
%define LPB_FRAME       344     ; 344 % 16 = 8 → with 8 pushes (64 bytes) + ret (8) = 72 odd → 72+344=416, 416%16=0 ✓

load_program_binary:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, LPB_FRAME

    ; Initialize BinReader on stack
    lea     rbx, [rsp + LPB_READER]
    mov     [rbx + BR_DATA], rcx        ; data
    mov     [rbx + BR_LEN], rdx         ; len
    mov     qword [rbx + BR_POS], 0     ; pos = 0

    ; Check minimum length
    cmp     rdx, 8
    jl      .lpb_too_short

    ; Check magic: data[0..3] == "HERB"
    cmp     byte [rcx], 'H'
    jne     .lpb_bad_magic
    cmp     byte [rcx+1], 'E'
    jne     .lpb_bad_magic
    cmp     byte [rcx+2], 'R'
    jne     .lpb_bad_magic
    cmp     byte [rcx+3], 'B'
    jne     .lpb_bad_magic

    ; r->pos = 4
    mov     qword [rbx + BR_POS], 4

    ; version = br_u8(r); must be 1
    mov     rcx, rbx
    call    br_u8
    cmp     al, 1
    jne     .lpb_bad_version

    ; br_u8(r) — flags (reserved, skip)
    mov     rcx, rbx
    call    br_u8

    ; str_count = br_u16(r)
    mov     rcx, rbx
    call    br_u16
    movzx   r12d, ax        ; R12 = str_count

    ; Intern string table
    lea     rax, [g_bin_str_count]
    mov     dword [rax], 0
    xor     r13d, r13d      ; R13 = i (string index)

.lpb_str_loop:
    cmp     r13d, r12d
    jge     .lpb_str_done

    ; slen = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    movzx   r14d, al        ; R14 = slen

    ; Read slen bytes into tmp buffer
    lea     r15, [rsp + LPB_TMPBUF]   ; R15 = tmp buf
    xor     edi, edi        ; j = 0
.lpb_str_copy:
    cmp     edi, r14d
    jge     .lpb_str_null
    cmp     edi, 255
    jge     .lpb_str_null
    ; tmp[j] = (char)br_u8(r)
    mov     rcx, rbx
    call    br_u8
    mov     [r15 + rdi], al
    inc     edi
    jmp     .lpb_str_copy

.lpb_str_null:
    ; Null terminate: tmp[min(slen,255)] = '\0'
    mov     eax, r14d
    cmp     eax, 255
    jl      .lpb_str_nt
    mov     eax, 255
.lpb_str_nt:
    mov     byte [r15 + rax], 0

    ; g_bin_str_ids[g_bin_str_count++] = intern(tmp)
    mov     rcx, r15
    call    intern
    lea     rcx, [g_bin_str_count]
    mov     edx, [rcx]
    lea     r8, [g_bin_str_ids]
    mov     [r8 + rdx*4], eax
    inc     edx
    mov     [rcx], edx

    inc     r13d
    jmp     .lpb_str_loop

.lpb_str_done:
    ; Initialize graph
    lea     rcx, [g_graph]
    xor     edx, edx
    mov     r8d, SIZEOF_GRAPH
    call    herb_memset

    ; g_graph.entity_location[i] = -1 for all i
    lea     rdi, [g_graph + GRAPH_ENTITY_LOCATION]
    xor     esi, esi
.lpb_init_loc:
    cmp     esi, MAX_ENTITIES
    jge     .lpb_init_loc_done
    mov     dword [rdi + rsi*4], -1
    inc     esi
    jmp     .lpb_init_loc

.lpb_init_loc_done:
    ; g_graph.max_nesting_depth = -1
    lea     rax, [g_graph + GRAPH_MAX_NESTING_DEPTH]
    mov     dword [rax], -1

    ; g_graph.containers[i].owner = -1 for all i
    lea     rdi, [g_graph + GRAPH_CONTAINERS]
    xor     esi, esi
.lpb_init_owner:
    cmp     esi, MAX_CONTAINERS
    jge     .lpb_init_owner_done
    mov     eax, esi
    imul    eax, SIZEOF_CONTAINER
    mov     dword [rdi + rax + CNT_OWNER], -1
    inc     esi
    jmp     .lpb_init_owner

.lpb_init_owner_done:
    ; Main section loop
.lpb_section_loop:
    mov     rax, [rbx + BR_POS]
    cmp     rax, [rbx + BR_LEN]
    jge     .lpb_success

    ; sec = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    movzx   r12d, al        ; R12 = section id

    cmp     r12d, 0xFF
    je      .lpb_success    ; SEC_END

    ; Dispatch section
    cmp     r12d, 0x01
    je      .lpb_sec_entity_types
    cmp     r12d, 0x02
    je      .lpb_sec_containers
    cmp     r12d, 0x03
    je      .lpb_sec_moves
    cmp     r12d, 0x04
    je      .lpb_sec_pools
    cmp     r12d, 0x05
    je      .lpb_sec_transfers
    cmp     r12d, 0x06
    je      .lpb_sec_entities
    cmp     r12d, 0x07
    je      .lpb_sec_channels
    cmp     r12d, 0x08
    je      .lpb_sec_config
    cmp     r12d, 0x09
    je      .lpb_sec_tensions
    ; Unknown section
    jmp     .lpb_unknown_sec


; ---- Section 0x01: Entity Types ----
.lpb_sec_entity_types:
    mov     rcx, rbx
    call    br_u16
    movzx   r13d, ax        ; R13 = count
    xor     r14d, r14d      ; R14 = i
.lpb_et_loop:
    cmp     r14d, r13d
    jge     .lpb_section_loop
    ; tid = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     edi, eax        ; EDI = tid
    ; g_graph.type_names[type_count++] = tid
    lea     rax, [g_graph + GRAPH_TYPE_COUNT]
    mov     esi, [rax]      ; ESI = old type_count
    mov     [rax], esi      ; (will inc after)
    lea     rax, [g_graph + GRAPH_TYPE_NAMES]
    mov     [rax + rsi*4], edi
    lea     rax, [g_graph + GRAPH_TYPE_COUNT]
    inc     dword [rax]

    ; sc_count = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    movzx   r15d, al        ; R15 = sc_count
    test    r15d, r15d
    jz      .lpb_et_next

    ; Create scope template entry
    lea     rax, [g_graph + GRAPH_TYPE_SCOPE_COUNT]
    mov     esi, [rax]      ; ESI = tsi = type_scope_count
    inc     dword [rax]

    ; type_scope_type_ids[tsi] = tid
    lea     rax, [g_graph + GRAPH_TYPE_SCOPE_TYPE_IDS]
    mov     [rax + rsi*4], edi

    ; type_scope_counts[tsi] = 0
    lea     rax, [g_graph + GRAPH_TYPE_SCOPE_COUNTS]
    mov     dword [rax + rsi*4], 0

    ; Save tsi in R12 (reuse since we're inside the section switch)
    mov     r12d, esi       ; R12 = tsi (overwriting section id, which is fine within this handler)

    ; for j in 0..sc_count
    xor     esi, esi        ; j = 0
.lpb_et_sc_loop:
    cmp     esi, r15d
    jge     .lpb_et_next
    ; RSI (j) is callee-saved — preserved across all calls below

    ; ScopeTemplate* st = &type_scope_templates[tsi][scope_counts[tsi]]
    ; Compute: &g_graph.type_scope_templates[tsi * 16 + scope_counts[tsi]]
    lea     rax, [g_graph + GRAPH_TYPE_SCOPE_COUNTS]
    mov     ecx, [rax + r12*4]      ; current count for this tsi
    mov     eax, r12d
    shl     eax, 4                  ; tsi * 16
    add     eax, ecx                ; + scope_counts[tsi]
    imul    eax, SIZEOF_SCOPETEMPLATE
    lea     rdi, [g_graph + GRAPH_TYPE_SCOPE_TEMPLATES]
    add     rdi, rax                ; RDI = ScopeTemplate* st

    ; Increment scope_counts[tsi]
    lea     rax, [g_graph + GRAPH_TYPE_SCOPE_COUNTS]
    inc     dword [rax + r12*4]

    ; st->name_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + ST_NAME_ID], eax

    ; st->kind = br_u8(r) ? CK_SLOT : CK_SIMPLE
    mov     rcx, rbx
    call    br_u8
    test    al, al
    jz      .lpb_et_sc_simple
    mov     dword [rdi + ST_KIND], CK_SLOT_V
    jmp     .lpb_et_sc_type
.lpb_et_sc_simple:
    mov     dword [rdi + ST_KIND], CK_SIMPLE_V
.lpb_et_sc_type:
    ; st->entity_type = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + ST_ENTITY_TYPE], eax

    inc     esi
    jmp     .lpb_et_sc_loop

.lpb_et_next:
    inc     r14d
    jmp     .lpb_et_loop


; ---- Section 0x02: Containers ----
.lpb_sec_containers:
    mov     rcx, rbx
    call    br_u16
    movzx   r13d, ax        ; R13 = count
    xor     r14d, r14d      ; R14 = i
.lpb_cnt_loop:
    cmp     r14d, r13d
    jge     .lpb_section_loop
    ; ci = g_graph.container_count++
    lea     rax, [g_graph + GRAPH_CONTAINER_COUNT]
    mov     esi, [rax]      ; ESI = ci
    inc     dword [rax]
    ; Container* c = &g_graph.containers[ci]
    mov     eax, esi
    imul    eax, SIZEOF_CONTAINER
    lea     rdi, [g_graph + GRAPH_CONTAINERS]
    add     rdi, rax        ; RDI = Container*
    ; c->id = ci
    mov     [rdi + CNT_ID], esi
    ; c->name_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + CNT_NAME_ID], eax
    ; c->kind = br_u8(r) ? CK_SLOT : CK_SIMPLE
    mov     rcx, rbx
    call    br_u8
    test    al, al
    jz      .lpb_cnt_simple
    mov     dword [rdi + CNT_KIND], CK_SLOT_V
    jmp     .lpb_cnt_etype
.lpb_cnt_simple:
    mov     dword [rdi + CNT_KIND], CK_SIMPLE_V
.lpb_cnt_etype:
    ; c->entity_type = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + CNT_ENTITY_TYPE], eax
    ; c->entity_count = 0 (already 0 from graph memset)
    ; c->owner = -1
    mov     dword [rdi + CNT_OWNER], -1
    inc     r14d
    jmp     .lpb_cnt_loop


; ---- Section 0x03: Moves ----
.lpb_sec_moves:
    mov     rcx, rbx
    call    br_u16
    movzx   r13d, ax        ; R13 = count
    xor     r14d, r14d      ; R14 = i
.lpb_mv_loop:
    cmp     r14d, r13d
    jge     .lpb_section_loop
    ; mi = g_graph.move_type_count++
    lea     rax, [g_graph + GRAPH_MOVE_TYPE_COUNT]
    mov     esi, [rax]      ; ESI = mi
    inc     dword [rax]
    ; MoveType* mt = &g_graph.move_types[mi]
    mov     eax, esi
    imul    eax, SIZEOF_MOVETYPE
    lea     rdi, [g_graph + GRAPH_MOVE_TYPES]
    add     rdi, rax        ; RDI = MoveType*
    ; memset(mt, 0, sizeof(MoveType))
    mov     rcx, rdi
    xor     edx, edx
    mov     r8d, SIZEOF_MOVETYPE
    call    herb_memset
    ; mt->name_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + MT_NAME_ID], eax
    ; mt->entity_type = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + MT_ENTITY_TYPE], eax
    ; mt->is_scoped = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    mov     [rdi + MT_IS_SCOPED], eax
    mov     r15d, eax       ; R15 = is_scoped

    ; fc = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    movzx   esi, al         ; ESI = fc (from count)

    test    r15d, r15d
    jnz     .lpb_mv_scoped_from

    ; Normal from: mt->from_count = fc
    mov     [rdi + MT_FROM_COUNT], esi
    xor     r12d, r12d      ; j = 0
.lpb_mv_from_loop:
    cmp     r12d, esi
    jge     .lpb_mv_to
    ; ESI is callee-saved — preserved across calls
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [rdi + MT_FROM_CONTAINERS + r12*4], eax
    inc     r12d
    jmp     .lpb_mv_from_loop

.lpb_mv_scoped_from:
    mov     [rdi + MT_SCOPED_FROM_COUNT], esi
    xor     r12d, r12d
.lpb_mv_sf_loop:
    cmp     r12d, esi
    jge     .lpb_mv_to
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + MT_SCOPED_FROM_NAMES + r12*4], eax
    inc     r12d
    jmp     .lpb_mv_sf_loop

.lpb_mv_to:
    ; tc = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    movzx   esi, al         ; ESI = tc (to count)

    test    r15d, r15d
    jnz     .lpb_mv_scoped_to

    ; Normal to: mt->to_count = tc
    mov     [rdi + MT_TO_COUNT], esi
    xor     r12d, r12d
.lpb_mv_to_loop:
    cmp     r12d, esi
    jge     .lpb_mv_next
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [rdi + MT_TO_CONTAINERS + r12*4], eax
    inc     r12d
    jmp     .lpb_mv_to_loop

.lpb_mv_scoped_to:
    mov     [rdi + MT_SCOPED_TO_COUNT], esi
    xor     r12d, r12d
.lpb_mv_st_loop:
    cmp     r12d, esi
    jge     .lpb_mv_next
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + MT_SCOPED_TO_NAMES + r12*4], eax
    inc     r12d
    jmp     .lpb_mv_st_loop

.lpb_mv_next:
    inc     r14d
    jmp     .lpb_mv_loop


; ---- Section 0x04: Pools ----
.lpb_sec_pools:
    mov     rcx, rbx
    call    br_u16
    movzx   r13d, ax        ; R13 = count
    xor     r14d, r14d
.lpb_pool_loop:
    cmp     r14d, r13d
    jge     .lpb_section_loop
    ; pi = g_graph.pool_count++
    lea     rax, [g_graph + GRAPH_POOL_COUNT]
    mov     esi, [rax]
    inc     dword [rax]
    ; pools[pi].name_id = bstr(br_u16(r))
    mov     eax, esi
    imul    eax, SIZEOF_POOL
    lea     rdi, [g_graph + GRAPH_POOLS]
    add     rdi, rax
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + POOL_NAME_ID], eax
    ; pools[pi].property_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + POOL_PROPERTY_ID], eax
    inc     r14d
    jmp     .lpb_pool_loop


; ---- Section 0x05: Transfers ----
.lpb_sec_transfers:
    mov     rcx, rbx
    call    br_u16
    movzx   r13d, ax        ; R13 = count
    xor     r14d, r14d
.lpb_xfer_loop:
    cmp     r14d, r13d
    jge     .lpb_section_loop
    ; ti = g_graph.transfer_type_count++
    lea     rax, [g_graph + GRAPH_TRANSFER_TYPE_COUNT]
    mov     esi, [rax]
    inc     dword [rax]
    ; TransferType* tt = &g_graph.transfer_types[ti]
    mov     eax, esi
    imul    eax, SIZEOF_TRANSFERTYPE
    lea     rdi, [g_graph + GRAPH_TRANSFER_TYPES]
    add     rdi, rax
    ; tt->name_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + TT_NAME_ID], eax
    ; pool_name = bstr(br_u16(r))
    ; RDI is callee-saved — preserved across calls
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     r15d, eax       ; R15 = pool_name
    ; tt->pool_idx = -1
    mov     dword [rdi + TT_POOL_IDX], -1
    ; Search pools for matching name
    cmp     r15d, 0
    jl      .lpb_xfer_etype
    lea     rax, [g_graph + GRAPH_POOL_COUNT]
    mov     esi, [rax]
    xor     r12d, r12d
.lpb_xfer_pool_search:
    cmp     r12d, esi
    jge     .lpb_xfer_etype
    mov     eax, r12d
    imul    eax, SIZEOF_POOL
    lea     rcx, [g_graph + GRAPH_POOLS]
    cmp     r15d, [rcx + rax + POOL_NAME_ID]
    je      .lpb_xfer_pool_found
    inc     r12d
    jmp     .lpb_xfer_pool_search
.lpb_xfer_pool_found:
    mov     [rdi + TT_POOL_IDX], r12d
.lpb_xfer_etype:
    ; tt->entity_type = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + TT_ENTITY_TYPE], eax
    inc     r14d
    jmp     .lpb_xfer_loop


; ---- Section 0x06: Entities ----
.lpb_sec_entities:
    mov     rcx, rbx
    call    br_u16
    movzx   r13d, ax        ; R13 = count
    xor     r14d, r14d
.lpb_ent_loop:
    cmp     r14d, r13d
    jge     .lpb_section_loop
    ; name_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     esi, eax        ; ESI = name_id
    ; type_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     edi, eax        ; EDI = type_id
    ; in_kind = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    movzx   r15d, al        ; R15 = in_kind
    mov     r12d, -1        ; R12 = ci (container index, default -1)

    cmp     r15d, 0
    je      .lpb_ent_normal
    cmp     r15d, 1
    je      .lpb_ent_scoped
    jmp     .lpb_ent_create

.lpb_ent_normal:
    ; ci = graph_find_container_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    cmp     eax, 0
    jl      .lpb_ent_create
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     r12d, eax
    jmp     .lpb_ent_create

.lpb_ent_scoped:
    ; scope_eid = graph_find_entity_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_entity_by_name
    mov     r15d, eax       ; R15 = scope_eid (reuse)
    ; scope_cname = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    ; ci = get_scoped_container(scope_eid, scope_cname)
    cmp     r15d, 0
    jl      .lpb_ent_create
    cmp     eax, 0
    jl      .lpb_ent_create
    mov     ecx, r15d
    mov     edx, eax
    call    get_scoped_container
    mov     r12d, eax

.lpb_ent_create:
    ; ei = create_entity(type_id, name_id, ci)
    mov     ecx, edi        ; type_id
    mov     edx, esi        ; name_id
    mov     r8d, r12d       ; ci
    call    create_entity
    mov     r15d, eax       ; R15 = ei

    ; pc = br_u8(r) — property count
    mov     rcx, rbx
    call    br_u8
    movzx   r12d, al        ; R12 = pc
    xor     esi, esi        ; j = 0
.lpb_ent_prop_loop:
    cmp     esi, r12d
    jge     .lpb_ent_next
    ; RSI (j) is callee-saved — preserved across all calls

    ; pk = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     edi, eax        ; EDI = pk (callee-saved)

    ; vk = br_u8(r)
    mov     rcx, rbx
    call    br_u8

    cmp     al, 0
    je      .lpb_ent_pv_int
    cmp     al, 1
    je      .lpb_ent_pv_float
    cmp     al, 2
    je      .lpb_ent_pv_string
    jmp     .lpb_ent_pv_done

.lpb_ent_pv_int:
    ; PropVal = { PV_INT, br_i64(r) }
    mov     dword [rsp + LPB_PROPVAL + PV_TYPE], PV_INT_T
    mov     rcx, rbx
    call    br_i64
    mov     [rsp + LPB_PROPVAL + PV_VALUE], rax
    jmp     .lpb_ent_pv_call

.lpb_ent_pv_float:
    ; PropVal = { PV_FLOAT, br_f64(r) }
    mov     dword [rsp + LPB_PROPVAL + PV_TYPE], PV_FLOAT_T
    mov     rcx, rbx
    call    br_f64
    movsd   [rsp + LPB_PROPVAL + PV_VALUE], xmm0
    jmp     .lpb_ent_pv_call

.lpb_ent_pv_string:
    ; PropVal = { PV_STRING, bstr(br_u16(r)) }
    mov     dword [rsp + LPB_PROPVAL + PV_TYPE], PV_STRING_T
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    movsxd  rax, eax        ; sign-extend to 64-bit
    mov     [rsp + LPB_PROPVAL + PV_VALUE], rax
    jmp     .lpb_ent_pv_call

.lpb_ent_pv_call:
    ; entity_set_prop(ei, pk, &propval)
    mov     ecx, r15d       ; ei
    mov     edx, edi        ; pk
    lea     r8, [rsp + LPB_PROPVAL]
    call    entity_set_prop

.lpb_ent_pv_done:
    inc     esi
    jmp     .lpb_ent_prop_loop

.lpb_ent_next:
    inc     r14d
    jmp     .lpb_ent_loop


; ---- Section 0x07: Channels ----
.lpb_sec_channels:
    mov     rcx, rbx
    call    br_u16
    movzx   r13d, ax        ; R13 = count
    xor     r14d, r14d
.lpb_ch_loop:
    cmp     r14d, r13d
    jge     .lpb_section_loop
    ; chi = g_graph.channel_count++
    lea     rax, [g_graph + GRAPH_CHANNEL_COUNT]
    mov     esi, [rax]
    inc     dword [rax]
    ; Channel* ch = &g_graph.channels[chi]
    mov     eax, esi
    imul    eax, SIZEOF_CHANNEL
    lea     rdi, [g_graph + GRAPH_CHANNELS]
    add     rdi, rax        ; RDI = Channel*

    ; ch->name_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + CH_NAME_ID], eax

    ; ch->sender = graph_find_entity_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_entity_by_name
    mov     [rdi + CH_SENDER], eax

    ; ch->receiver = graph_find_entity_by_name(bstr(br_u16(r)))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     ecx, eax
    call    graph_find_entity_by_name
    mov     [rdi + CH_RECEIVER], eax

    ; ch->entity_type = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + CH_ENTITY_TYPE], eax

    ; Create buffer container
    ; herb_snprintf(buf_name, 256, "channel:%s", str_of(ch->name_id))
    ; RDI is callee-saved — preserved across calls
    mov     ecx, [rdi + CH_NAME_ID]
    call    str_of
    mov     r12, rax        ; R12 = str_of result

    lea     rcx, [rsp + LPB_TMPBUF]
    mov     edx, 256
    lea     r8, [str_chan_fmt]
    mov     r9, r12
    call    herb_snprintf

    ; buf_ci = g_graph.container_count++
    lea     rax, [g_graph + GRAPH_CONTAINER_COUNT]
    mov     esi, [rax]
    inc     dword [rax]
    ; Container* bc = &g_graph.containers[buf_ci]
    mov     eax, esi
    imul    eax, SIZEOF_CONTAINER
    lea     r12, [g_graph + GRAPH_CONTAINERS]
    add     r12, rax        ; R12 = Container* bc

    ; bc->id = buf_ci
    mov     [r12 + CNT_ID], esi
    ; bc->name_id = intern(buf_name)
    lea     rcx, [rsp + LPB_TMPBUF]
    call    intern
    mov     [r12 + CNT_NAME_ID], eax
    ; bc->kind = CK_SIMPLE
    mov     dword [r12 + CNT_KIND], CK_SIMPLE_V
    ; bc->entity_type = ch->entity_type
    mov     eax, [rdi + CH_ENTITY_TYPE]
    mov     [r12 + CNT_ENTITY_TYPE], eax
    ; bc->entity_count = 0 (already 0)
    mov     dword [r12 + CNT_ENTITY_COUNT], 0
    ; bc->owner = -1
    mov     dword [r12 + CNT_OWNER], -1
    ; ch->buffer = buf_ci
    mov     [rdi + CH_BUFFER], esi

    inc     r14d
    jmp     .lpb_ch_loop


; ---- Section 0x08: Config ----
.lpb_sec_config:
    mov     rcx, rbx
    call    br_i16
    lea     rcx, [g_graph + GRAPH_MAX_NESTING_DEPTH]
    mov     [rcx], eax
    jmp     .lpb_section_loop


; ---- Section 0x09: Tensions ----
.lpb_sec_tensions:
    mov     rcx, rbx
    call    br_u16
    movzx   r13d, ax        ; R13 = count
    xor     r14d, r14d
.lpb_ten_loop:
    cmp     r14d, r13d
    jge     .lpb_section_loop
    ; ti = g_graph.tension_count++
    lea     rax, [g_graph + GRAPH_TENSION_COUNT]
    mov     esi, [rax]
    inc     dword [rax]
    ; Tension* t = &g_graph.tensions[ti]
    movsxd  rax, esi
    imul    rax, SIZEOF_TENSION
    lea     rdi, [g_graph + GRAPH_TENSIONS]
    add     rdi, rax        ; RDI = Tension*

    ; memset(t, 0, sizeof(Tension))
    mov     rcx, rdi
    xor     edx, edx
    mov     r8d, SIZEOF_TENSION
    call    herb_memset

    ; t->enabled = 1; t->owner = -1; t->owner_run_container = -1
    mov     dword [rdi + TEN_ENABLED], 1
    mov     dword [rdi + TEN_OWNER], -1
    mov     dword [rdi + TEN_OWNER_RUN_CNT], -1

    ; t->name_id = bstr(br_u16(r))
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     [rdi + TEN_NAME_ID], eax

    ; t->priority = (int)br_i16(r)
    mov     rcx, rbx
    call    br_i16
    mov     [rdi + TEN_PRIORITY], eax

    ; t->pair_mode = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    mov     [rdi + TEN_PAIR_MODE], eax

    ; Match clauses
    mov     rcx, rbx
    call    br_u8
    mov     [rdi + TEN_MATCH_COUNT], eax
    movzx   r12d, al        ; R12 = match_count
    xor     r15d, r15d      ; j = 0
.lpb_ten_mc_loop:
    cmp     r15d, r12d
    jge     .lpb_ten_emit
    ; R15 and RDI are callee-saved — preserved by _parse_match_clause
    mov     eax, r15d
    imul    eax, SIZEOF_MATCHCLAUSE
    lea     rdx, [rdi + TEN_MATCHES]
    add     rdx, rax        ; RDX = mc
    mov     rcx, rbx        ; RCX = reader
    call    _parse_match_clause
    inc     r15d
    jmp     .lpb_ten_mc_loop

.lpb_ten_emit:
    ; Emit clauses
    mov     rcx, rbx
    call    br_u8
    mov     [rdi + TEN_EMIT_COUNT], eax
    movzx   r12d, al        ; R12 = emit_count
    xor     r15d, r15d      ; j = 0
.lpb_ten_ec_loop:
    cmp     r15d, r12d
    jge     .lpb_ten_next
    mov     eax, r15d
    imul    eax, SIZEOF_EMITCLAUSE
    lea     rdx, [rdi + TEN_EMITS]
    add     rdx, rax        ; RDX = ec
    mov     rcx, rbx        ; RCX = reader
    call    _parse_emit_clause
    inc     r15d
    jmp     .lpb_ten_ec_loop

.lpb_ten_next:
    inc     r14d
    jmp     .lpb_ten_loop


; ---- Error handlers ----
.lpb_too_short:
    xor     ecx, ecx
    lea     rdx, [str_bin_short]
    call    herb_error
    jmp     .lpb_fail

.lpb_bad_magic:
    xor     ecx, ecx
    lea     rdx, [str_bad_magic]
    call    herb_error
    jmp     .lpb_fail

.lpb_bad_version:
    xor     ecx, ecx
    lea     rdx, [str_bad_version]
    call    herb_error
    jmp     .lpb_fail

.lpb_unknown_sec:
    mov     ecx, HERB_ERR_WARN
    lea     rdx, [str_unknown_sec]
    call    herb_error
    ; Skip to end
    mov     rax, [rbx + BR_LEN]
    mov     [rbx + BR_POS], rax
    jmp     .lpb_section_loop

.lpb_fail:
    mov     eax, -1
    jmp     .lpb_epilog

.lpb_success:
    xor     eax, eax        ; return 0

.lpb_epilog:
    add     rsp, LPB_FRAME
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
; herb_load_program(const uint8_t* data, herb_size_t len,
;                   int owner_entity, const char* run_container) -> int
;
; Loads a HERB program fragment (process programs).
; Only processes tension sections — adds to existing graph.
; RCX = data, RDX = len, R8D = owner_entity, R9 = run_container
; Returns number of tensions loaded, or -1 on error.
;
; Stack frame (400 bytes):
;   [rsp+0..31]    shadow space
;   [rsp+32..39]   5th arg slot
;   [rsp+40..63]   BinReader struct (24 bytes)
;   [rsp+64..319]  tmp buffer (256 bytes) — for tension name building
;   [rsp+320..327] owner_entity (saved)
;   [rsp+328..335] run_cidx (saved)
;   [rsp+336..343] owner_name pointer (saved)
;   [rsp+344..347] loaded count (saved)
;   [rsp+348..399] padding to 400
; ============================================================

%define HLP_READER       40
%define HLP_TMPBUF       64
%define HLP_OWNER        320
%define HLP_RUN_CIDX     328
%define HLP_OWNER_NAME   336
%define HLP_LOADED       344
%define HLP_TENSION_PTR  352     ; saved Tension* for snprintf calls
%define HLP_FRAME        408     ; 408 % 16 = 8 → with 8 pushes (64) + ret (8) = 72+408=480, 480%16=0 ✓

herb_load_program:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, HLP_FRAME

    ; Save all args IMMEDIATELY before any calls clobber them
    ; RCX=data, RDX=len, R8D=owner_entity, R9=run_container
    mov     [rsp + HLP_OWNER], r8d
    mov     [rsp + HLP_OWNER_NAME], r9     ; temporarily store run_container ptr here
    mov     dword [rsp + HLP_LOADED], 0

    ; Initialize BinReader on stack
    lea     rbx, [rsp + HLP_READER]
    mov     [rbx + BR_DATA], rcx
    mov     [rbx + BR_LEN], rdx
    mov     qword [rbx + BR_POS], 0

    ; Check minimum length
    cmp     rdx, 8
    jl      .hlp_fail

    ; Check magic
    cmp     byte [rcx], 'H'
    jne     .hlp_fail
    cmp     byte [rcx+1], 'E'
    jne     .hlp_fail
    cmp     byte [rcx+2], 'R'
    jne     .hlp_fail
    cmp     byte [rcx+3], 'B'
    jne     .hlp_fail

    mov     qword [rbx + BR_POS], 4

    ; version check
    mov     rcx, rbx
    call    br_u8
    cmp     al, 1
    jne     .hlp_fail

    ; skip flags
    mov     rcx, rbx
    call    br_u8

    ; str_count = br_u16(r)
    mov     rcx, rbx
    call    br_u16
    movzx   r12d, ax

    ; Intern string table
    lea     rax, [g_bin_str_count]
    mov     dword [rax], 0
    xor     r13d, r13d
.hlp_str_loop:
    cmp     r13d, r12d
    jge     .hlp_str_done
    mov     rcx, rbx
    call    br_u8
    movzx   r14d, al
    lea     r15, [rsp + HLP_TMPBUF]
    xor     edi, edi
.hlp_str_copy:
    cmp     edi, r14d
    jge     .hlp_str_null
    cmp     edi, 255
    jge     .hlp_str_null
    mov     rcx, rbx
    call    br_u8
    mov     [r15 + rdi], al
    inc     edi
    jmp     .hlp_str_copy
.hlp_str_null:
    mov     eax, r14d
    cmp     eax, 255
    jl      .hlp_str_nt
    mov     eax, 255
.hlp_str_nt:
    mov     byte [r15 + rax], 0
    mov     rcx, r15
    call    intern
    lea     rcx, [g_bin_str_count]
    mov     edx, [rcx]
    lea     r8, [g_bin_str_ids]
    mov     [r8 + rdx*4], eax
    inc     edx
    mov     [rcx], edx
    inc     r13d
    jmp     .hlp_str_loop
.hlp_str_done:

    ; Resolve run container (run_container pointer was saved at HLP_OWNER_NAME)
    mov     dword [rsp + HLP_RUN_CIDX], -1
    mov     rcx, [rsp + HLP_OWNER_NAME]
    test    rcx, rcx
    jz      .hlp_owner_name_setup
    cmp     byte [rcx], 0
    je      .hlp_owner_name_setup
    call    intern
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [rsp + HLP_RUN_CIDX], eax

.hlp_owner_name_setup:
    ; Now set up owner_name
    ; owner_name = ""
    lea     rax, [str_empty]
    mov     [rsp + HLP_OWNER_NAME], rax
    ; if owner_entity >= 0 && < entity_count: owner_name = str_of(entities[owner].name_id)
    mov     eax, [rsp + HLP_OWNER]
    cmp     eax, 0
    jl      .hlp_section_loop
    lea     rcx, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     eax, [rcx]
    jge     .hlp_section_loop
    movsxd  rcx, eax
    imul    rcx, SIZEOF_ENTITY
    lea     rdx, [g_graph + GRAPH_ENTITIES]
    mov     ecx, [rdx + rcx + ENT_NAME_ID]
    call    str_of
    mov     [rsp + HLP_OWNER_NAME], rax

    ; Main section loop
.hlp_section_loop:
    mov     rax, [rbx + BR_POS]
    cmp     rax, [rbx + BR_LEN]
    jge     .hlp_done

    mov     rcx, rbx
    call    br_u8
    movzx   r12d, al

    cmp     r12d, 0xFF
    je      .hlp_done

    ; Infrastructure sections (0x01-0x07): read count, must be 0
    cmp     r12d, 0x01
    jl      .hlp_unknown
    cmp     r12d, 0x07
    jle     .hlp_infra

    cmp     r12d, 0x08
    je      .hlp_config

    cmp     r12d, 0x09
    je      .hlp_tensions

    jmp     .hlp_unknown

.hlp_infra:
    mov     rcx, rbx
    call    br_u16
    test    ax, ax
    jz      .hlp_section_loop
    ; Non-empty infrastructure section in fragment — error
    mov     ecx, HERB_ERR_WARN
    lea     rdx, [str_frag_infra]
    call    herb_error
    jmp     .hlp_fail

.hlp_config:
    mov     rcx, rbx
    call    br_i16
    ; Skip config in fragments
    jmp     .hlp_section_loop

.hlp_tensions:
    mov     rcx, rbx
    call    br_u16
    movzx   r13d, ax        ; R13 = tension count
    xor     r14d, r14d      ; i = 0

.hlp_ten_loop:
    cmp     r14d, r13d
    jge     .hlp_section_loop

    ; Check MAX_TENSIONS
    lea     rax, [g_graph + GRAPH_TENSION_COUNT]
    mov     esi, [rax]
    cmp     esi, MAX_TENSIONS
    jge     .hlp_section_loop

    ; ti = g_graph.tension_count++
    inc     dword [rax]
    ; Tension* t = &g_graph.tensions[ti]
    movsxd  rax, esi
    imul    rax, SIZEOF_TENSION
    lea     rdi, [g_graph + GRAPH_TENSIONS]
    add     rdi, rax

    ; memset(t, 0, sizeof(Tension))
    mov     rcx, rdi
    xor     edx, edx
    mov     r8d, SIZEOF_TENSION
    call    herb_memset

    ; t->enabled = 1
    mov     dword [rdi + TEN_ENABLED], 1
    ; t->owner = owner_entity
    mov     eax, [rsp + HLP_OWNER]
    mov     [rdi + TEN_OWNER], eax
    ; t->owner_run_container = run_cidx
    mov     eax, [rsp + HLP_RUN_CIDX]
    mov     [rdi + TEN_OWNER_RUN_CNT], eax

    ; Tension name: prefix with owner name if owned
    mov     rcx, rbx
    call    br_u16
    movzx   ecx, ax
    call    bstr
    mov     r15d, eax       ; R15 = base_name_id

    ; Check if owner_entity >= 0 && owner_name[0] != '\0'
    mov     eax, [rsp + HLP_OWNER]
    cmp     eax, 0
    jl      .hlp_ten_plain_name
    mov     rax, [rsp + HLP_OWNER_NAME]
    cmp     byte [rax], 0
    je      .hlp_ten_plain_name

    ; Build prefixed name: "%s.%s" % (owner_name, base_name)
    ; RDI (Tension*) is callee-saved — preserved across calls
    mov     ecx, r15d
    call    str_of
    mov     r12, rax        ; R12 = base_name string

    lea     rcx, [rsp + HLP_TMPBUF]
    mov     edx, 128
    lea     r8, [str_name_fmt]
    mov     r9, [rsp + HLP_OWNER_NAME]
    mov     [rsp + 32], r12               ; 5th arg = base_name
    call    herb_snprintf

    lea     rcx, [rsp + HLP_TMPBUF]
    call    intern
    mov     [rdi + TEN_NAME_ID], eax
    jmp     .hlp_ten_pri

.hlp_ten_plain_name:
    mov     [rdi + TEN_NAME_ID], r15d

.hlp_ten_pri:
    ; t->priority = (int)br_i16(r)
    mov     rcx, rbx
    call    br_i16
    mov     [rdi + TEN_PRIORITY], eax
    ; t->pair_mode = br_u8(r)
    mov     rcx, rbx
    call    br_u8
    mov     [rdi + TEN_PAIR_MODE], eax

    ; Match clauses (same as load_program_binary)
    mov     rcx, rbx
    call    br_u8
    mov     [rdi + TEN_MATCH_COUNT], eax
    movzx   r12d, al
    xor     r15d, r15d
.hlp_ten_mc_loop:
    cmp     r15d, r12d
    jge     .hlp_ten_emit
    mov     eax, r15d
    imul    eax, SIZEOF_MATCHCLAUSE
    lea     rdx, [rdi + TEN_MATCHES]
    add     rdx, rax
    mov     rcx, rbx
    call    _parse_match_clause
    inc     r15d
    jmp     .hlp_ten_mc_loop

.hlp_ten_emit:
    mov     rcx, rbx
    call    br_u8
    mov     [rdi + TEN_EMIT_COUNT], eax
    movzx   r12d, al
    xor     r15d, r15d
.hlp_ten_ec_loop:
    cmp     r15d, r12d
    jge     .hlp_ten_next
    mov     eax, r15d
    imul    eax, SIZEOF_EMITCLAUSE
    lea     rdx, [rdi + TEN_EMITS]
    add     rdx, rax
    mov     rcx, rbx
    call    _parse_emit_clause
    inc     r15d
    jmp     .hlp_ten_ec_loop

.hlp_ten_next:
    inc     dword [rsp + HLP_LOADED]
    inc     r14d
    jmp     .hlp_ten_loop

.hlp_unknown:
    mov     rax, [rbx + BR_LEN]
    mov     [rbx + BR_POS], rax
    jmp     .hlp_section_loop

.hlp_done:
    ; if loaded > 0: ham_mark_dirty()
    mov     eax, [rsp + HLP_LOADED]
    test    eax, eax
    jz      .hlp_return
    call    ham_mark_dirty

.hlp_return:
    mov     eax, [rsp + HLP_LOADED]
    jmp     .hlp_epilog

.hlp_fail:
    mov     eax, -1

.hlp_epilog:
    add     rsp, HLP_FRAME
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
; herb_init(void* arena_memory, herb_size_t arena_size, HerbErrorFn error_fn)
;
; Initialize the runtime. Must be called before herb_load().
; RCX = arena_memory, RDX = arena_size, R8 = error_fn
; ============================================================
herb_init:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    sub     rsp, 32         ; shadow

    ; Save args
    mov     rbx, rcx        ; arena_memory
    mov     rsi, rdx        ; arena_size

    ; herb_set_error_handler(error_fn)
    mov     rcx, r8
    call    herb_set_error_handler

    ; g_arena_ptr = &arena_storage
    lea     rax, [arena_storage]
    lea     rcx, [g_arena_ptr]
    mov     [rcx], rax

    ; herb_arena_init(&arena_storage, arena_memory, arena_size)
    lea     rcx, [arena_storage]
    mov     rdx, rbx
    mov     r8, rsi
    call    herb_arena_init

    ; g_string_count = 0
    lea     rax, [g_string_count]
    mov     dword [rax], 0

    ; g_expr_count = 0
    lea     rax, [g_expr_count]
    mov     dword [rax], 0

    add     rsp, 32
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; herb_load(const char* buf, herb_size_t len) -> int
;
; Load a HERB program from memory buffer. Binary format only
; in bare-metal build (HERB_BINARY_ONLY).
; RCX = buf, RDX = len
; Returns 0 on success, -1 on error.
; ============================================================
herb_load:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32         ; shadow

    ; Check minimum length for magic detection
    cmp     rdx, 4
    jl      .hl_json_disabled

    ; Check "HERB" magic
    cmp     byte [rcx], 'H'
    jne     .hl_json_disabled
    cmp     byte [rcx+1], 'E'
    jne     .hl_json_disabled
    cmp     byte [rcx+2], 'R'
    jne     .hl_json_disabled
    cmp     byte [rcx+3], 'B'
    jne     .hl_json_disabled

    ; Binary format detected — call load_program_binary
    ; RCX = (const uint8_t*)buf, RDX = len (already set)
    call    load_program_binary
    add     rsp, 32
    pop     rbp
    ret

.hl_json_disabled:
    ; HERB_BINARY_ONLY — no JSON support
    xor     ecx, ecx
    lea     rdx, [str_json_disabled]
    call    herb_error
    mov     eax, -1
    add     rsp, 32
    pop     rbp
    ret


section .rdata
    str_empty: db 0
