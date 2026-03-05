; boot/herb_graph.asm — HERB Graph Primitives in Assembly
;
; Phase 4b, Part 1 (Session 70): 6 core graph functions ported from C to x86-64:
;   intern, str_of, entity_get_prop_raw, entity_set_prop, container_add, container_remove
;
; Phase 4b, Part 2 (Session 71): 5 graph functions ported + 1 deferred:
;   graph_find_container_by_name, graph_find_entity_by_name, get_scoped_container,
;   do_channel_send, do_channel_receive
;   try_move: linked in Phase 4d (Discovery 48 resolved)
;
; Phase 4d: HAM bridge functions ported from C to assembly:
;   ham_ecnt, ham_entity_loc, ham_scan, ham_eprop, ham_eset
;
; Phase 4f: Tension API + Entity Creation + HAM Glue:
;   ham_mark_dirty, ham_ensure_compiled, ham_run_ham, ham_get_compiled_count, ham_get_bytecode_len
;   create_entity, herb_create
;   herb_remove_owner_tensions, herb_remove_tension_by_name
;   herb_tension_create, herb_tension_match_in, herb_tension_match_in_where
;   herb_tension_emit_set, herb_tension_emit_move
;   herb_expr_int, herb_expr_prop, herb_expr_binary
;
; Register convention: MS x64 ABI
;   Args:    RCX, RDX, R8, R9 (integer/pointer)
;   Return:  RAX (integer/pointer)
;   Caller-saved: RAX, RCX, RDX, R8-R11
;   Callee-saved: RBX, RSI, RDI, R12-R15, RBP
;   Shadow space: 32 bytes before each CALL
;   Stack: 16-byte aligned at CALL instruction
;
; Assembled with: nasm -f win64 herb_graph.asm -o herb_graph.o

[bits 64]
default rel

%include "herb_graph_layout.inc"
%include "herb_freestanding_layout.inc"

; External C functions we call
extern herb_strcmp
extern herb_strncpy
extern herb_error
extern herb_snprintf
extern herb_memset      ; Phase 4f
extern herb_memcpy      ; Phase 4f
extern ham_compile_all  ; Phase 4f — int ham_compile_all(uint8_t* buf, int buf_size, int* out_count)
extern ham_run          ; Phase 4f — int ham_run(uint8_t* bytecode_ptr, int bytecode_len)
extern ham_dirty_mark   ; Session 79 — void ham_dirty_mark(int container_idx)
extern alloc_expr       ; Phase 4f — Expr* alloc_expr(void)

; External data
extern g_arena_ptr      ; HerbArena* (from herb_loader.asm)
extern g_ham_bytecode       ; uint8_t[8192] (from herb_ham.asm)
extern g_ham_bytecode_len   ; int (from herb_ham.asm)
extern g_ham_compiled_count ; int (from herb_ham.asm)
extern g_ham_dirty          ; int (from herb_ham.asm)

; Graph data — owned by this file (Phase D Step 7d)
global g_strings, g_string_count, g_graph, g_expr_pool, g_expr_count
global container_order_keys, tension_step_flags
global g_tensions, g_tension_count
global g_container_entities, g_container_entity_counts

; Export our functions — Phase 4b Part 1
global intern
global str_of
global entity_get_prop_raw
global entity_set_prop
global container_add
global container_remove
; Phase 4b Part 2
global graph_find_container_by_name
global graph_find_entity_by_name
global get_scoped_container
global try_move             ; Phase 4d — Discovery 48 resolved (HAM calls assembly directly)
global do_channel_send
global do_channel_receive
; Phase 4d — HAM bridge functions
global ham_ecnt
global ham_entity_loc
global ham_scan
global ham_eprop
global ham_eset
; Phase 4e — Graph lookups
global graph_find_move_type_by_name
global graph_find_channel_by_name
global graph_find_transfer_by_name
global get_type_scope_idx
; Phase 4e — Public API read functions
global herb_container_count
global herb_container_entity
global herb_entity_name
global herb_entity_prop_int
global herb_entity_prop_str
global herb_entity_location
global herb_entity_total
global herb_tension_count
global herb_tension_name
global herb_tension_priority
global herb_tension_enabled
; Phase 4e — Mutations
global herb_tension_set_enabled
global herb_tension_owner
global herb_set_prop_int
; Phase 4e — Container/State functions
global herb_create_container
global herb_state
global is_property_pooled
; Phase 4f — HAM runtime glue
global ham_mark_dirty
global ham_ensure_compiled
global ham_run_ham
global ham_get_compiled_count
global ham_get_bytecode_len
; Phase 4f — Entity creation
global create_entity
global herb_create
; Phase 4f — Tension remove functions
global herb_remove_owner_tensions
global herb_remove_tension_by_name
; Phase 4f — Tension creation API
global herb_tension_create
global herb_tension_match_in
global herb_tension_match_in_where
global herb_tension_emit_set
global herb_tension_emit_move
; Phase 4f — Expression builders
global herb_expr_int
global herb_expr_prop
global herb_expr_binary
; Phase 4i — Arena queries
global herb_arena_usage
global herb_arena_total

; ============================================================
; BSS — Graph data (Phase D Step 7d: migrated from C)
; ============================================================

section .bss

align 16
g_strings:      resb 262144     ; char[2048][128] — string intern table
g_expr_pool:    resb 131072     ; Expr[4096] — expression pool (4096 × 32 bytes)
g_graph:        resb SIZEOF_GRAPH ; Graph struct (720568 bytes)

align 4
container_order_keys: resd MAX_CONTAINERS  ; parallel array: order_key prop string ID per container (-1 = unordered)
tension_step_flags:   resd MAX_TENSIONS    ; parallel array: step flag per tension (0 = converge, 1 = step)

; Session 74: Tension array extracted from Graph struct into standalone BSS
align 16
g_tensions:       resb MAX_TENSIONS * SIZEOF_TENSION  ; Tension[256] (~490KB)
g_tension_count:  resd 1                               ; int — number of active tensions

; Session 76: Container entity lists extracted from Container struct into standalone BSS
align 16
g_container_entities:      resd MAX_CONTAINERS * MAX_ENTITY_PER_CONTAINER  ; 256 × 256 × 4 = 256KB
g_container_entity_counts: resd MAX_CONTAINERS                             ; 256 × 4 = 1KB

; ============================================================
; DATA — Graph counters (Phase D Step 7d: migrated from C)
; ============================================================

section .data

align 4
g_string_count: dd 0            ; int — number of interned strings
g_expr_count:   dd 0            ; int — number of allocated expressions

; ============================================================
; RDATA — String constants
; ============================================================

section .rdata
    str_question:   db "?", 0
    str_table_full: db "string table full", 0
    str_empty:      db 0
    str_null:       db "null", 0
    ; Format strings for herb_state
    str_lld_fmt:    db "%lld", 0
    str_g_fmt:      db "%g", 0
    str_open_brace: db "{", 10, 0           ; "{\n"
    str_close_brace: db 10, "}", 10, 0      ; "\n}\n"
    str_comma_nl:   db ",", 10, 0           ; ",\n"
    str_ent_pre:    db '  "', 0             ; '  "'
    str_loc_mid:    db '": {"location": "', 0
    str_prop_pre:   db ', "', 0
    str_prop_mid:   db '": ', 0
    ; Phase 4f — format strings
    str_scope_fmt:  db "%s::%s", 0      ; for create_entity scoped container names
    str_expr_full:  db "expr pool full", 0

section .text

; ============================================================
; intern(const char* s) -> int string_id
;
; Linear search g_strings[0..g_string_count-1] via herb_strcmp.
; If found, return index. If not found and not full, copy and
; return g_string_count++. If full, call herb_error and return -1.
;
; RCX = pointer to string s
; Returns EAX = string id (or -1 on error)
; ============================================================
intern:
    push    rbp
    mov     rbp, rsp
    push    rbx             ; callee-saved: loop counter i
    push    rsi             ; callee-saved: input string pointer s
    push    rdi             ; callee-saved: g_string_count value
    sub     rsp, 40         ; 32 shadow + 8 pad → 16-byte aligned at CALL

    mov     rsi, rcx        ; RSI = input string s (callee-saved)
    xor     ebx, ebx        ; EBX = loop counter i = 0

    lea     rdi, [g_string_count]
    mov     edi, [rdi]      ; EDI = g_string_count (snapshot)

.search_loop:
    cmp     ebx, edi
    jge     .not_found

    ; Compute &g_strings[i]: base + i * MAX_STRING_LEN
    mov     eax, ebx
    shl     eax, 7          ; i * 128 (MAX_STRING_LEN = 128)
    lea     rcx, [g_strings]
    add     rcx, rax        ; RCX = &g_strings[i]
    mov     rdx, rsi        ; RDX = s
    call    herb_strcmp
    test    eax, eax
    jz      .found

    inc     ebx
    jmp     .search_loop

.found:
    mov     eax, ebx        ; return i
    jmp     .done

.not_found:
    ; Check if table is full
    cmp     edi, MAX_STRINGS
    jge     .table_full

    ; herb_strncpy(g_strings[g_string_count], s, 127)
    mov     eax, edi
    shl     eax, 7          ; g_string_count * 128
    lea     rcx, [g_strings]
    add     rcx, rax        ; RCX = dst = &g_strings[g_string_count]
    mov     rdx, rsi        ; RDX = src = s
    mov     r8d, MAX_STRING_LEN - 1  ; R8 = 127
    call    herb_strncpy

    ; Null-terminate: g_strings[g_string_count][127] = '\0'
    mov     eax, edi
    shl     eax, 7
    lea     rcx, [g_strings]
    add     rcx, rax
    mov     byte [rcx + MAX_STRING_LEN - 1], 0

    ; Return g_string_count++ (return old value, then increment)
    mov     eax, edi        ; return value = old g_string_count
    inc     edi
    lea     rcx, [g_string_count]
    mov     [rcx], edi      ; store incremented count
    jmp     .done

.table_full:
    ; herb_error(HERB_ERR_FATAL, "string table full")
    xor     ecx, ecx        ; ECX = 0 = HERB_ERR_FATAL
    lea     rdx, [str_table_full]
    call    herb_error
    mov     eax, -1         ; return -1
    ; fall through to .done

.done:
    add     rsp, 40
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; str_of(int id) -> const char*
;
; If id >= 0 && id < g_string_count, return &g_strings[id * 128].
; Else return pointer to "?" literal.
;
; ECX = id
; Returns RAX = pointer to string
; ============================================================
str_of:
    ; Bounds check
    test    ecx, ecx
    js      .str_of_bad         ; id < 0

    lea     rax, [g_string_count]
    cmp     ecx, [rax]
    jge     .str_of_bad         ; id >= g_string_count

    ; return &g_strings[id * MAX_STRING_LEN]
    mov     eax, ecx
    shl     eax, 7              ; id * 128
    lea     rcx, [g_strings]    ; base (RIP-relative)
    add     rax, rcx            ; base + offset
    ret

.str_of_bad:
    lea     rax, [str_question]
    ret


; ============================================================
; entity_get_prop_raw(int ei, int prop_id, PropVal* out)
;
; Explicit output pointer version — avoids MS x64 hidden pointer
; ABI issue with 16-byte struct returns (Discovery 47).
;
;   ECX = ei (entity index)
;   EDX = prop_id
;   R8  = pointer to PropVal output buffer
;
; Compute entity base, linear scan prop_keys, copy PropVal or write PV_NONE.
; ============================================================
entity_get_prop_raw:
    ; Compute entity base: &g_graph.entities[ei]
    ; = &g_graph + ei * SIZEOF_ENTITY
    movsxd  rax, ecx        ; RAX = ei (sign-extended)
    imul    rax, SIZEOF_ENTITY  ; RAX = ei * 344
    lea     rcx, [g_graph]
    add     rcx, rax        ; RCX = &entity

    ; Load prop_count
    mov     r10d, [rcx + ENT_PROP_COUNT]
    xor     r11d, r11d      ; R11 = loop counter i = 0

.egp_loop:
    cmp     r11d, r10d
    jge     .egp_not_found

    ; Compare prop_keys[i] with prop_id
    ; prop_keys is at ENT_PROP_KEYS + i*4
    mov     eax, [rcx + ENT_PROP_KEYS + r11*4]
    cmp     eax, edx
    je      .egp_found

    inc     r11d
    jmp     .egp_loop

.egp_found:
    ; Copy PropVal from prop_vals[i] to output buffer
    ; prop_vals is at ENT_PROP_VALS + i * SIZEOF_PV
    mov     eax, r11d
    shl     eax, 4          ; i * 16 (SIZEOF_PV)
    ; Copy 16 bytes: type (8 bytes padded) + value (8 bytes)
    mov     r10, [rcx + ENT_PROP_VALS + rax]
    mov     [r8], r10
    mov     r10, [rcx + ENT_PROP_VALS + rax + 8]
    mov     [r8 + 8], r10
    ret

.egp_not_found:
    ; Write PV_NONE: type=0, value=0
    xor     eax, eax
    mov     [r8], rax       ; type = PV_NONE (0) + padding
    mov     [r8 + 8], rax   ; value = 0
    ret


; ============================================================
; entity_set_prop(int ei, int prop_id, PropVal val)
;
; MS x64 ABI: PropVal is 16 bytes, passed by pointer.
;   ECX = ei
;   EDX = prop_id
;   R8  = pointer to PropVal
;
; Linear scan for existing key → update. If not found, append.
; ============================================================
entity_set_prop:
    ; Compute entity base: &g_graph.entities[ei]
    movsxd  rax, ecx
    imul    rax, SIZEOF_ENTITY
    lea     r9, [g_graph]
    add     r9, rax         ; R9 = &entity

    ; Load prop_count
    mov     r10d, [r9 + ENT_PROP_COUNT]
    xor     r11d, r11d      ; R11 = loop counter

.esp_loop:
    cmp     r11d, r10d
    jge     .esp_not_found

    ; Compare prop_keys[i] with prop_id
    mov     eax, [r9 + ENT_PROP_KEYS + r11*4]
    cmp     eax, edx
    je      .esp_update

    inc     r11d
    jmp     .esp_loop

.esp_update:
    ; Update existing: prop_vals[i] = val
    mov     eax, r11d
    shl     eax, 4          ; i * 16
    ; Copy 16 bytes from [R8] to prop_vals[i]
    mov     rcx, [r8]
    mov     [r9 + ENT_PROP_VALS + rax], rcx
    mov     rcx, [r8 + 8]
    mov     [r9 + ENT_PROP_VALS + rax + 8], rcx
    ret

.esp_not_found:
    ; Append if prop_count < MAX_PROPERTIES
    cmp     r10d, MAX_PROPERTIES
    jge     .esp_full

    ; prop_keys[prop_count] = prop_id
    mov     [r9 + ENT_PROP_KEYS + r10*4], edx

    ; prop_vals[prop_count] = val
    mov     eax, r10d
    shl     eax, 4          ; prop_count * 16
    mov     rcx, [r8]
    mov     [r9 + ENT_PROP_VALS + rax], rcx
    mov     rcx, [r8 + 8]
    mov     [r9 + ENT_PROP_VALS + rax + 8], rcx

    ; prop_count++
    inc     r10d
    mov     [r9 + ENT_PROP_COUNT], r10d

.esp_full:
    ret


; ============================================================
; container_add(int ci, int ei)
;
; ECX = ci (container index)
; EDX = ei (entity index)
;
; If entity_count < MAX_ENTITY_PER_CONTAINER, append ei.
; ============================================================
container_add:
    ; Session 76: Use parallel BSS arrays instead of in-struct entity list
    ; ECX = ci, EDX = ei
    movsxd  rax, ecx                        ; RAX = ci (sign-extended)

    ; Check entity_count < MAX_ENTITY_PER_CONTAINER
    lea     r9, [g_container_entity_counts]
    mov     r8d, [r9 + rax*4]               ; R8D = entity_count
    cmp     r8d, MAX_ENTITY_PER_CONTAINER
    jge     .ca_full

    ; g_container_entities[ci * 256 + count] = ei
    imul    r10, rax, MAX_ENTITY_PER_CONTAINER  ; R10 = ci * 256
    lea     r11, [g_container_entities]
    movsxd  rcx, r8d                        ; RCX = count (for indexing)
    add     rcx, r10                        ; RCX = ci * 256 + count
    mov     [r11 + rcx*4], edx              ; entities[count] = ei

    ; entity_count++
    inc     r8d
    mov     [r9 + rax*4], r8d

.ca_full:
    ret


; ============================================================
; container_remove(int ci, int ei)
;
; ECX = ci (container index)
; EDX = ei (entity index)
;
; Linear scan for ei, swap with last element, decrement count.
; ============================================================
container_remove:
    ; Session 76: Use parallel BSS arrays instead of in-struct entity list
    ; ECX = ci, EDX = ei
    movsxd  rax, ecx                        ; RAX = ci (sign-extended)

    ; Load entity_count from parallel array
    lea     r9, [g_container_entity_counts]
    mov     r10d, [r9 + rax*4]              ; R10D = entity_count

    ; Compute entity list base: &g_container_entities[ci * 256]
    imul    r8, rax, MAX_ENTITY_PER_CONTAINER  ; R8 = ci * 256
    lea     r9, [g_container_entities]
    lea     r9, [r9 + r8*4]                 ; R9 = base of this container's entity list

    xor     r11d, r11d                      ; R11 = loop counter

.cr_loop:
    cmp     r11d, r10d
    jge     .cr_not_found

    ; Compare entities[i] with ei
    mov     ecx, [r9 + r11*4]
    cmp     ecx, edx
    je      .cr_found

    inc     r11d
    jmp     .cr_loop

.cr_found:
    ; Swap with last: entities[i] = entities[--entity_count]
    dec     r10d
    mov     ecx, [r9 + r10*4]              ; last element
    mov     [r9 + r11*4], ecx              ; overwrite found slot
    ; Store decremented count
    lea     r9, [g_container_entity_counts]
    mov     [r9 + rax*4], r10d

.cr_not_found:
    ret


; ============================================================
; graph_find_container_by_name(int name_id) -> int index
;
; Linear scan containers[0..container_count-1].name_id.
; Returns index or -1 if not found.
;
; ECX = name_id
; Returns EAX = container index (or -1)
; ============================================================
graph_find_container_by_name:
    lea     r9, [g_graph + GRAPH_CONTAINER_COUNT]
    mov     r9d, [r9]              ; R9D = container_count
    xor     eax, eax               ; EAX = loop counter i = 0
    lea     r10, [g_graph + GRAPH_CONTAINERS]

.gfcbn_loop:
    cmp     eax, r9d
    jge     .gfcbn_not_found
    movsxd  rdx, eax
    imul    rdx, SIZEOF_CONTAINER
    cmp     ecx, [r10 + rdx + CNT_NAME_ID]
    je      .gfcbn_done            ; return i (already in EAX)
    inc     eax
    jmp     .gfcbn_loop

.gfcbn_not_found:
    mov     eax, -1
.gfcbn_done:
    ret


; ============================================================
; graph_find_entity_by_name(int name_id) -> int index
;
; Linear scan entities[0..entity_count-1].name_id.
; Returns index or -1 if not found.
;
; ECX = name_id
; Returns EAX = entity index (or -1)
; ============================================================
graph_find_entity_by_name:
    lea     r9, [g_graph + GRAPH_ENTITY_COUNT]
    mov     r9d, [r9]              ; R9D = entity_count
    xor     eax, eax               ; EAX = loop counter i = 0
    lea     r10, [g_graph]         ; entities start at offset 0

.gfebn_loop:
    cmp     eax, r9d
    jge     .gfebn_not_found
    movsxd  rdx, eax
    imul    rdx, SIZEOF_ENTITY
    cmp     ecx, [r10 + rdx + ENT_NAME_ID]
    je      .gfebn_done            ; return i (already in EAX)
    inc     eax
    jmp     .gfebn_loop

.gfebn_not_found:
    mov     eax, -1
.gfebn_done:
    ret


; ============================================================
; get_scoped_container(int entity_idx, int scope_name_id) -> int
;
; Bounds check entity_idx, then linear scan
; entity_scope_names[entity_idx][0..count-1].
; Returns matching entity_scope_cids entry or -1.
;
; ECX = entity_idx
; EDX = scope_name_id
; Returns EAX = container index (or -1)
; ============================================================
get_scoped_container:
    ; Bounds check
    test    ecx, ecx
    js      .gsc_fail              ; entity_idx < 0
    lea     r9, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     ecx, [r9]
    jge     .gsc_fail              ; entity_idx >= entity_count

    ; Load scope count for this entity
    movsxd  rax, ecx               ; RAX = entity_idx
    lea     r9, [g_graph + GRAPH_ENTITY_SCOPE_COUNT]
    mov     r8d, [r9 + rax*4]     ; R8D = scope count

    ; Compute row offset = entity_idx * 64 (MAX_SCOPE_TEMPLATES * 4)
    shl     rax, 6
    lea     r9, [g_graph + GRAPH_ENTITY_SCOPE_NAMES]
    add     r9, rax                ; R9 = &scope_names[entity_idx][0]
    lea     r10, [g_graph + GRAPH_ENTITY_SCOPE_CIDS]
    add     r10, rax               ; R10 = &scope_cids[entity_idx][0]

    xor     ecx, ecx               ; ECX = loop counter (entity_idx no longer needed)
.gsc_loop:
    cmp     ecx, r8d
    jge     .gsc_fail
    cmp     edx, [r9 + rcx*4]     ; scope_names[entity_idx][i] == scope_name_id?
    je      .gsc_found
    inc     ecx
    jmp     .gsc_loop

.gsc_found:
    mov     eax, [r10 + rcx*4]    ; return scope_cids[entity_idx][i]
    ret

.gsc_fail:
    mov     eax, -1
    ret


; ============================================================
; try_move(int mt_idx, int entity_idx, int to_container_idx) -> int
;
; The core MOVE primitive. Validates and executes entity movement.
; Two paths: scoped (intra-owner scope movement) and regular.
; Both validate type/from/to constraints, then do_move on success.
;
; ECX = mt_idx (MoveType index)
; EDX = entity_idx
; R8D = to_container_idx
; Returns EAX = 1 (success) or 0 (failed validation)
;
; Callee-saved: RBP, RBX, RSI, RDI, R12, R13, R14
; Stack: 7 pushes (56 bytes) + sub rsp,32 (shadow) = 16-byte aligned
; ============================================================
try_move:
    push    rbp
    mov     rbp, rsp
    push    rbx             ; EBX = from location
    push    rsi             ; ESI = entity_idx
    push    rdi             ; EDI = to_container_idx
    push    r12             ; R12 = MoveType*
    push    r13             ; R13D = entity type_id
    push    r14             ; R14D = from_owner (scoped path)
    sub     rsp, 32         ; shadow space (16-aligned: 7 pushes = 56, entry 8, total 96 = 16*6)

    mov     esi, edx        ; ESI = entity_idx (callee-saved)
    mov     edi, r8d        ; EDI = to_container_idx (callee-saved)

    ; Compute R12 = &g_graph.move_types[mt_idx]
    movsxd  rax, ecx
    imul    rax, SIZEOF_MOVETYPE
    lea     r12, [g_graph + GRAPH_MOVE_TYPES]
    add     r12, rax

    ; Compute R13D = g_graph.entities[entity_idx].type_id
    movsxd  rax, esi
    imul    rax, SIZEOF_ENTITY
    lea     rcx, [g_graph]
    mov     r13d, [rcx + rax + ENT_TYPE_ID]

    ; Branch on is_scoped
    cmp     dword [r12 + MT_IS_SCOPED], 0
    jne     .tm_scoped

    ; === REGULAR MOVE ===

    ; Type check: if mt->entity_type >= 0 && e->type_id != mt->entity_type
    mov     eax, [r12 + MT_ENTITY_TYPE]
    test    eax, eax
    js      .tm_reg_type_ok        ; entity_type < 0 → no constraint
    cmp     eax, r13d
    jne     .tm_return_0
.tm_reg_type_ok:

    ; from = entity_location[entity_idx]
    movsxd  rax, esi
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     ebx, [rcx + rax*4]    ; EBX = from
    test    ebx, ebx
    js      .tm_return_0           ; from < 0

    ; Check from is in mt->from_containers[0..from_count-1]
    mov     r8d, [r12 + MT_FROM_COUNT]
    xor     ecx, ecx
.tm_reg_from_loop:
    cmp     ecx, r8d
    jge     .tm_return_0
    cmp     ebx, [r12 + MT_FROM_CONTAINERS + rcx*4]
    je      .tm_reg_from_ok
    inc     ecx
    jmp     .tm_reg_from_loop
.tm_reg_from_ok:

    ; Check to is in mt->to_containers[0..to_count-1]
    mov     r8d, [r12 + MT_TO_COUNT]
    xor     ecx, ecx
.tm_reg_to_loop:
    cmp     ecx, r8d
    jge     .tm_return_0
    cmp     edi, [r12 + MT_TO_CONTAINERS + rcx*4]
    je      .tm_reg_to_ok
    inc     ecx
    jmp     .tm_reg_to_loop
.tm_reg_to_ok:

    ; Slot + type constraint on destination container
    movsxd  rax, edi
    imul    rax, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    add     rcx, rax               ; RCX = &containers[to]

    cmp     dword [rcx + CNT_KIND], CK_SLOT_V
    jne     .tm_reg_slot_ok
    ; Session 76: entity count from parallel array
    movsxd  rax, edi
    lea     r8, [g_container_entity_counts]
    cmp     dword [r8 + rax*4], 0
    jg      .tm_return_0
.tm_reg_slot_ok:

    mov     eax, [rcx + CNT_ENTITY_TYPE]
    test    eax, eax
    js      .tm_do_move            ; entity_type < 0 → no constraint
    cmp     eax, r13d
    jne     .tm_return_0
    jmp     .tm_do_move

    ; === SCOPED MOVE ===
.tm_scoped:
    ; Type check
    mov     eax, [r12 + MT_ENTITY_TYPE]
    test    eax, eax
    js      .tm_sc_type_ok
    cmp     eax, r13d
    jne     .tm_return_0
.tm_sc_type_ok:

    ; from = entity_location[entity_idx]
    movsxd  rax, esi
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     ebx, [rcx + rax*4]    ; EBX = from
    test    ebx, ebx
    js      .tm_return_0

    ; from_owner = containers[from].owner
    movsxd  rax, ebx
    imul    rax, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    mov     r14d, [rcx + rax + CNT_OWNER]  ; R14D = from_owner
    test    r14d, r14d
    js      .tm_return_0           ; from_owner < 0

    ; Find from_scope_name: scan entity_scope_cids[from_owner] for 'from'
    movsxd  rax, r14d
    lea     rcx, [g_graph + GRAPH_ENTITY_SCOPE_COUNT]
    mov     r8d, [rcx + rax*4]    ; R8D = scope count for from_owner

    ; Compute row offset = from_owner * 64
    shl     rax, 6
    lea     r9, [g_graph + GRAPH_ENTITY_SCOPE_CIDS]
    add     r9, rax                ; R9 = &scope_cids[from_owner][0]
    lea     r10, [g_graph + GRAPH_ENTITY_SCOPE_NAMES]
    add     r10, rax               ; R10 = &scope_names[from_owner][0]

    mov     r11d, -1               ; R11D = from_scope_name = -1
    xor     ecx, ecx
.tm_sc_from_scope_loop:
    cmp     ecx, r8d
    jge     .tm_sc_from_scope_done
    cmp     ebx, [r9 + rcx*4]     ; scope_cids[from_owner][i] == from?
    je      .tm_sc_from_scope_found
    inc     ecx
    jmp     .tm_sc_from_scope_loop
.tm_sc_from_scope_found:
    mov     r11d, [r10 + rcx*4]   ; from_scope_name = scope_names[from_owner][i]
.tm_sc_from_scope_done:

    ; Check from_scope_name is in mt->scoped_from_names
    mov     r8d, [r12 + MT_SCOPED_FROM_COUNT]
    xor     ecx, ecx
.tm_sc_from_check:
    cmp     ecx, r8d
    jge     .tm_return_0           ; not found → fail
    cmp     r11d, [r12 + MT_SCOPED_FROM_NAMES + rcx*4]
    je      .tm_sc_from_ok
    inc     ecx
    jmp     .tm_sc_from_check
.tm_sc_from_ok:

    ; to_owner = containers[to_container_idx].owner, must == from_owner
    movsxd  rax, edi
    imul    rax, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    mov     eax, [rcx + rax + CNT_OWNER]
    cmp     eax, r14d
    jne     .tm_return_0           ; to_owner != from_owner

    ; Find to_scope_name: scan entity_scope_cids[to_owner] for to_container_idx
    ; to_owner == from_owner, so R9 and R10 still point to correct rows
    ; Reload scope count (R8D was overwritten)
    movsxd  rax, r14d
    lea     rcx, [g_graph + GRAPH_ENTITY_SCOPE_COUNT]
    mov     r8d, [rcx + rax*4]

    mov     r11d, -1               ; to_scope_name = -1
    xor     ecx, ecx
.tm_sc_to_scope_loop:
    cmp     ecx, r8d
    jge     .tm_sc_to_scope_done
    cmp     edi, [r9 + rcx*4]     ; scope_cids[to_owner][i] == to_container_idx?
    je      .tm_sc_to_scope_found
    inc     ecx
    jmp     .tm_sc_to_scope_loop
.tm_sc_to_scope_found:
    mov     r11d, [r10 + rcx*4]   ; to_scope_name = scope_names[to_owner][i]
.tm_sc_to_scope_done:

    ; Check to_scope_name is in mt->scoped_to_names
    mov     r8d, [r12 + MT_SCOPED_TO_COUNT]
    xor     ecx, ecx
.tm_sc_to_check:
    cmp     ecx, r8d
    jge     .tm_return_0
    cmp     r11d, [r12 + MT_SCOPED_TO_NAMES + rcx*4]
    je      .tm_sc_to_ok
    inc     ecx
    jmp     .tm_sc_to_check
.tm_sc_to_ok:

    ; Slot + type constraint on destination
    movsxd  rax, edi
    imul    rax, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    add     rcx, rax

    cmp     dword [rcx + CNT_KIND], CK_SLOT_V
    jne     .tm_sc_slot_ok
    ; Session 76: entity count from parallel array
    movsxd  rax, edi
    lea     r8, [g_container_entity_counts]
    cmp     dword [r8 + rax*4], 0
    jg      .tm_return_0
.tm_sc_slot_ok:

    mov     eax, [rcx + CNT_ENTITY_TYPE]
    test    eax, eax
    js      .tm_do_move
    cmp     eax, r13d
    jne     .tm_return_0
    ; fall through to .tm_do_move

    ; === SHARED: Execute the move ===
.tm_do_move:
    ; container_remove(from, entity_idx)
    mov     ecx, ebx        ; ECX = from
    mov     edx, esi        ; EDX = entity_idx
    call    container_remove

    ; container_add(to_container_idx, entity_idx)
    mov     ecx, edi        ; ECX = to_container_idx
    mov     edx, esi        ; EDX = entity_idx
    call    container_add

    ; entity_location[entity_idx] = to_container_idx
    movsxd  rax, esi
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     [rcx + rax*4], edi

    ; Session 79: Mark source and dest containers dirty
    mov     ecx, ebx          ; EBX = from (callee-saved)
    call    ham_dirty_mark
    mov     ecx, edi          ; EDI = to (callee-saved)
    call    ham_dirty_mark

    ; op_count++
    lea     rcx, [g_graph + GRAPH_OP_COUNT]
    inc     dword [rcx]

    mov     eax, 1
    jmp     .tm_done

.tm_return_0:
    xor     eax, eax

.tm_done:
    add     rsp, 32
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; do_channel_send(int ch_idx, int entity_idx) -> int
;
; Move entity from sender's scope to channel buffer.
; Validates entity type, location in sender-owned container.
;
; ECX = ch_idx
; EDX = entity_idx
; Returns EAX = 1 (success) or 0 (fail)
; ============================================================
do_channel_send:
    push    rbp
    mov     rbp, rsp
    push    rbx             ; EBX = entity_idx
    push    rsi             ; ESI = from location
    push    rdi             ; EDI = buffer_container_idx
    sub     rsp, 40         ; 32 shadow + 8 pad → 16-byte aligned

    mov     ebx, edx        ; EBX = entity_idx

    ; Compute R9 = &g_graph.channels[ch_idx]
    movsxd  rax, ecx
    imul    rax, SIZEOF_CHANNEL
    lea     r9, [g_graph + GRAPH_CHANNELS]
    add     r9, rax

    ; Type check: ch->entity_type >= 0 && entity type != ch->entity_type
    mov     eax, [r9 + CH_ENTITY_TYPE]
    test    eax, eax
    js      .dcs_type_ok
    movsxd  rcx, ebx
    imul    rcx, SIZEOF_ENTITY
    lea     rdx, [g_graph]
    cmp     eax, [rdx + rcx + ENT_TYPE_ID]
    jne     .dcs_return_0
.dcs_type_ok:

    ; from = entity_location[entity_idx]
    movsxd  rax, ebx
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     esi, [rcx + rax*4]    ; ESI = from
    test    esi, esi
    js      .dcs_return_0

    ; from_owner = containers[from].owner, must == ch->sender_entity_idx
    movsxd  rax, esi
    imul    rax, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    mov     eax, [rcx + rax + CNT_OWNER]
    cmp     eax, [r9 + CH_SENDER]
    jne     .dcs_return_0

    ; Save buffer_container_idx before calls (R9 is volatile)
    mov     edi, [r9 + CH_BUFFER]

    ; container_remove(from, entity_idx)
    mov     ecx, esi
    mov     edx, ebx
    call    container_remove

    ; container_add(buffer, entity_idx)
    mov     ecx, edi
    mov     edx, ebx
    call    container_add

    ; entity_location[entity_idx] = buffer
    movsxd  rax, ebx
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     [rcx + rax*4], edi

    ; op_count++
    lea     rcx, [g_graph + GRAPH_OP_COUNT]
    inc     dword [rcx]

    mov     eax, 1
    jmp     .dcs_done

.dcs_return_0:
    xor     eax, eax

.dcs_done:
    add     rsp, 40
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; do_channel_receive(int ch_idx, int entity_idx, int to_container_idx) -> int
;
; Move entity from channel buffer to receiver's scope.
; Validates buffer location, receiver ownership, slot/type constraints.
;
; ECX = ch_idx
; EDX = entity_idx
; R8D = to_container_idx
; Returns EAX = 1 (success) or 0 (fail)
; ============================================================
do_channel_receive:
    push    rbp
    mov     rbp, rsp
    push    rbx             ; EBX = entity_idx
    push    rsi             ; ESI = from (buffer_container_idx)
    push    rdi             ; EDI = to_container_idx
    sub     rsp, 40         ; 32 shadow + 8 pad → 16-byte aligned

    mov     ebx, edx        ; EBX = entity_idx
    mov     edi, r8d        ; EDI = to_container_idx

    ; Compute R9 = &g_graph.channels[ch_idx]
    movsxd  rax, ecx
    imul    rax, SIZEOF_CHANNEL
    lea     r9, [g_graph + GRAPH_CHANNELS]
    add     r9, rax

    ; from = entity_location[entity_idx], must == ch->buffer_container_idx
    movsxd  rax, ebx
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     esi, [rcx + rax*4]    ; ESI = from
    cmp     esi, [r9 + CH_BUFFER]
    jne     .dcr_return_0

    ; to_owner = containers[to_container_idx].owner, must == ch->receiver_entity_idx
    movsxd  rax, edi
    imul    rax, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    add     rcx, rax               ; RCX = &containers[to]
    mov     eax, [rcx + CNT_OWNER]
    cmp     eax, [r9 + CH_RECEIVER]
    jne     .dcr_return_0

    ; Slot constraint
    cmp     dword [rcx + CNT_KIND], CK_SLOT_V
    jne     .dcr_slot_ok
    ; Session 76: entity count from parallel array
    movsxd  rax, edi
    lea     r8, [g_container_entity_counts]
    cmp     dword [r8 + rax*4], 0
    jg      .dcr_return_0
.dcr_slot_ok:

    ; Type constraint: to->entity_type >= 0 && e->type_id != to->entity_type
    mov     eax, [rcx + CNT_ENTITY_TYPE]
    test    eax, eax
    js      .dcr_do_move
    movsxd  r10, ebx
    imul    r10, SIZEOF_ENTITY
    lea     r11, [g_graph]
    cmp     eax, [r11 + r10 + ENT_TYPE_ID]
    jne     .dcr_return_0

.dcr_do_move:
    ; container_remove(from, entity_idx)
    mov     ecx, esi
    mov     edx, ebx
    call    container_remove

    ; container_add(to, entity_idx)
    mov     ecx, edi
    mov     edx, ebx
    call    container_add

    ; entity_location[entity_idx] = to_container_idx
    movsxd  rax, ebx
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     [rcx + rax*4], edi

    ; op_count++
    lea     rcx, [g_graph + GRAPH_OP_COUNT]
    inc     dword [rcx]

    mov     eax, 1
    jmp     .dcr_done

.dcr_return_0:
    xor     eax, eax

.dcr_done:
    add     rsp, 40
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; Phase 4d — HAM Bridge Functions (ported from C)
; ============================================================


; ============================================================
; ham_ecnt(int container_idx) -> int entity_count
;
; Returns entity count of container. 0 if out of bounds.
;
; ECX = container_idx
; Returns EAX = entity count
; ============================================================
ham_ecnt:
    ; Bounds check: container_idx < 0 || container_idx >= container_count
    test    ecx, ecx
    js      .hecnt_zero
    lea     rax, [g_graph + GRAPH_CONTAINER_COUNT]
    cmp     ecx, [rax]
    jge     .hecnt_zero

    ; Session 76: return entity count from parallel array
    movsxd  rax, ecx
    lea     rcx, [g_container_entity_counts]
    mov     eax, [rcx + rax*4]
    ret

.hecnt_zero:
    xor     eax, eax
    ret


; ============================================================
; ham_entity_loc(int entity_idx) -> int container_idx
;
; Returns container index where entity resides. -1 if out of bounds.
;
; ECX = entity_idx
; Returns EAX = container index (or -1)
; ============================================================
ham_entity_loc:
    ; Bounds check: entity_idx < 0 || entity_idx >= entity_count
    test    ecx, ecx
    js      .heloc_bad
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     ecx, [rax]
    jge     .heloc_bad

    ; return entity_location[entity_idx]
    movsxd  rax, ecx
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     eax, [rcx + rax*4]
    ret

.heloc_bad:
    mov     eax, -1
    ret


; ============================================================
; ham_scan(int container_idx, int* buf, int max_count) -> int count
;
; Copy entity IDs from container to buffer. Returns actual count.
; 0 if container out of bounds.
;
; ECX = container_idx
; RDX = buf (pointer to int array)
; R8D = max_count
; Returns EAX = number of entities copied
; ============================================================
ham_scan:
    ; Bounds check: container_idx < 0 || container_idx >= container_count
    test    ecx, ecx
    js      .hscan_zero
    lea     rax, [g_graph + GRAPH_CONTAINER_COUNT]
    cmp     ecx, [rax]
    jge     .hscan_zero

    ; Session 76: Use parallel BSS arrays
    movsxd  rax, ecx            ; RAX = container_idx

    ; n = min(entity_count, max_count)
    lea     r9, [g_container_entity_counts]
    mov     r10d, [r9 + rax*4]
    cmp     r10d, r8d
    cmovg   r10d, r8d           ; R10D = min(entity_count, max_count)

    ; Compute entity list base: &g_container_entities[ci * 256]
    imul    r9, rax, MAX_ENTITY_PER_CONTAINER
    lea     r11, [g_container_entities]
    lea     r9, [r11 + r9*4]   ; R9 = base of entity list

    ; Copy loop: buf[i] = entities[i] for i in 0..n-1
    xor     ecx, ecx            ; ECX = loop counter
.hscan_loop:
    cmp     ecx, r10d
    jge     .hscan_done
    mov     eax, [r9 + rcx*4]
    mov     [rdx + rcx*4], eax
    inc     ecx
    jmp     .hscan_loop

.hscan_done:
    mov     eax, r10d           ; return count
    ret

.hscan_zero:
    xor     eax, eax
    ret


; ============================================================
; ham_eprop(int entity_idx, int prop_id) -> int64_t
;
; Returns integer value of property on entity. 0 if not found.
; Calls entity_get_prop_raw(ei, prop_id, &pv) then dispatches
; on pv.type: PV_INT → return value, PV_FLOAT → convert to int64,
; else return 0.
;
; ECX = entity_idx
; EDX = prop_id
; Returns RAX = int64 property value (or 0)
;
; Stack layout (after push rbp):
;   [rbp-16] PropVal output buffer (16 bytes: 8 type + 8 value)
;   [rbp-48] shadow space (32 bytes) — at RSP for calls
;   Total: push rbp (8) + sub 48 = 56 bytes from entry RSP
;   Entry RSP was 8-misaligned → 8 + 56 = 64 → 16-aligned at CALL ✓
; ============================================================
ham_eprop:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 48             ; 16 (PropVal) + 32 (shadow) = 48

    ; Bounds check: entity_idx < 0 || entity_idx >= entity_count
    test    ecx, ecx
    js      .hep_zero
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     ecx, [rax]
    jge     .hep_zero

    ; entity_get_prop_raw(entity_idx, prop_id, &pv)
    ; ECX = entity_idx (already set)
    ; EDX = prop_id (already set)
    lea     r8, [rbp - 16]     ; R8 = &pv (PropVal on stack)
    call    entity_get_prop_raw

    ; Dispatch on pv.type
    mov     eax, [rbp - 16]    ; pv.type (4 bytes at PV_TYPE offset)
    cmp     eax, PV_INT_T
    je      .hep_int
    cmp     eax, PV_FLOAT_T
    je      .hep_float

    ; PV_NONE or PV_STRING → return 0
.hep_zero:
    xor     eax, eax
    leave
    ret

.hep_int:
    mov     rax, [rbp - 8]     ; pv.value (8 bytes at PV_VALUE offset)
    leave
    ret

.hep_float:
    ; Convert double to int64: cvttsd2si rax, xmm
    movsd   xmm0, [rbp - 8]   ; load double from pv.value
    cvttsd2si rax, xmm0       ; truncate to int64
    leave
    ret


; ============================================================
; ham_eset(int entity_idx, int prop_id, int64_t value) -> int
;
; Sets integer property on entity. Returns 1 if value changed, 0 if same.
; Calls entity_get_prop_raw to check old value, then entity_set_prop
; if different.
;
; ECX = entity_idx
; EDX = prop_id
; R8  = value (int64_t)
; Returns EAX = 1 (changed) or 0 (unchanged/error)
;
; Stack layout (after pushes):
;   RBX = entity_idx (callee-saved)
;   RSI = prop_id (callee-saved)
;   RDI = value (callee-saved)
;   [rbp-16] PropVal buffer (16 bytes)
;   [rbp-48] shadow space (32 bytes)
;   Total: push rbp (8) + 3 pushes (24) + sub 48 = 80 bytes from entry RSP
;   Entry RSP was 8-misaligned → 8 + 80 = 88 → not 16-aligned
;   Fix: 3 pushes = odd, need +8 pad. Use sub rsp, 56 instead of 48.
;   3 pushes (24) + sub 56 = 80 + push rbp (8) = 88 from entry
;   Entry at call: RSP = 16n - 8. After push rbp: RSP = 16n - 16 = 16n.
;   After 3 pushes: 16n - 24 = 16(n-1) - 8. Sub 56: 16(n-1) - 64 = 16-aligned ✓
; ============================================================
ham_eset:
    push    rbp
    mov     rbp, rsp
    push    rbx                 ; save entity_idx
    push    rsi                 ; save prop_id
    push    rdi                 ; save value
    sub     rsp, 56             ; 16 (PropVal) + 32 (shadow) + 8 (alignment pad)

    mov     ebx, ecx            ; EBX = entity_idx
    mov     esi, edx            ; ESI = prop_id
    mov     rdi, r8             ; RDI = value

    ; Bounds check
    test    ebx, ebx
    js      .hes_zero
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     ebx, [rax]
    jge     .hes_zero

    ; entity_get_prop_raw(entity_idx, prop_id, &pv)
    mov     ecx, ebx
    mov     edx, esi
    lea     r8, [rbp - 40]     ; PropVal at rbp - (3 pushes:24 + 16 PropVal) = rbp-40
    call    entity_get_prop_raw

    ; Check if old.type == PV_INT && old.i == value
    cmp     dword [rbp - 40], PV_INT_T    ; pv.type
    jne     .hes_do_set
    cmp     [rbp - 32], rdi                ; pv.value vs new value
    je      .hes_zero                      ; same → return 0

.hes_do_set:
    ; Build PropVal pv_int(value) on stack for entity_set_prop
    ; Reuse the same PropVal buffer at [rbp-40]
    mov     dword [rbp - 40], PV_INT_T    ; type = PV_INT
    mov     dword [rbp - 36], 0           ; padding = 0
    mov     [rbp - 32], rdi               ; value = int64

    ; entity_set_prop(entity_idx, prop_id, &PropVal)
    mov     ecx, ebx            ; entity_idx
    mov     edx, esi            ; prop_id
    lea     r8, [rbp - 40]      ; &PropVal
    call    entity_set_prop

    ; Session 79: Mark entity's container dirty
    movsxd  rax, ebx                    ; entity_idx (callee-saved)
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     ecx, [rcx + rax*4]
    test    ecx, ecx
    js      .hes_no_dirty
    call    ham_dirty_mark
.hes_no_dirty:

    mov     eax, 1              ; return 1 (changed)
    jmp     .hes_done

.hes_zero:
    xor     eax, eax            ; return 0

.hes_done:
    add     rsp, 56
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; Phase 4e — Graph Lookups
; ============================================================


; ============================================================
; graph_find_move_type_by_name(int name_id) -> int index
;
; Linear scan move_types[0..move_type_count-1].name_id.
; Returns index or -1 if not found.
;
; ECX = name_id
; Returns EAX = index (or -1)
; ============================================================
graph_find_move_type_by_name:
    lea     r9, [g_graph + GRAPH_MOVE_TYPE_COUNT]
    mov     r9d, [r9]              ; R9D = move_type_count
    xor     eax, eax               ; EAX = loop counter i = 0
    lea     r10, [g_graph + GRAPH_MOVE_TYPES]

.gfmtbn_loop:
    cmp     eax, r9d
    jge     .gfmtbn_not_found
    movsxd  rdx, eax
    imul    rdx, SIZEOF_MOVETYPE
    cmp     ecx, [r10 + rdx + MT_NAME_ID]
    je      .gfmtbn_done           ; return i (already in EAX)
    inc     eax
    jmp     .gfmtbn_loop

.gfmtbn_not_found:
    mov     eax, -1
.gfmtbn_done:
    ret


; ============================================================
; graph_find_channel_by_name(int name_id) -> int index
;
; Linear scan channels[0..channel_count-1].name_id.
; Returns index or -1 if not found.
;
; ECX = name_id
; Returns EAX = index (or -1)
; ============================================================
graph_find_channel_by_name:
    lea     r9, [g_graph + GRAPH_CHANNEL_COUNT]
    mov     r9d, [r9]              ; R9D = channel_count
    xor     eax, eax               ; EAX = loop counter i = 0
    lea     r10, [g_graph + GRAPH_CHANNELS]

.gfchbn_loop:
    cmp     eax, r9d
    jge     .gfchbn_not_found
    movsxd  rdx, eax
    imul    rdx, SIZEOF_CHANNEL
    cmp     ecx, [r10 + rdx + CH_NAME_ID]
    je      .gfchbn_done           ; return i (already in EAX)
    inc     eax
    jmp     .gfchbn_loop

.gfchbn_not_found:
    mov     eax, -1
.gfchbn_done:
    ret


; ============================================================
; graph_find_transfer_by_name(int name_id) -> int index
;
; Linear scan transfer_types[0..transfer_type_count-1].name_id.
; Returns index or -1 if not found.
;
; ECX = name_id
; Returns EAX = index (or -1)
; ============================================================
graph_find_transfer_by_name:
    lea     r9, [g_graph + GRAPH_TRANSFER_TYPE_COUNT]
    mov     r9d, [r9]              ; R9D = transfer_type_count
    xor     eax, eax               ; EAX = loop counter i = 0
    lea     r10, [g_graph + GRAPH_TRANSFER_TYPES]

.gftbn_loop:
    cmp     eax, r9d
    jge     .gftbn_not_found
    movsxd  rdx, eax
    imul    rdx, SIZEOF_TRANSFERTYPE
    cmp     ecx, [r10 + rdx + TT_NAME_ID]
    je      .gftbn_done            ; return i (already in EAX)
    inc     eax
    jmp     .gftbn_loop

.gftbn_not_found:
    mov     eax, -1
.gftbn_done:
    ret


; ============================================================
; get_type_scope_idx(int type_name_id) -> int index
;
; Linear scan type_scope_type_ids[0..type_scope_count-1].
; Returns index or -1 if not found.
;
; ECX = type_name_id
; Returns EAX = index (or -1)
; ============================================================
get_type_scope_idx:
    lea     r9, [g_graph + GRAPH_TYPE_SCOPE_COUNT]
    mov     r9d, [r9]              ; R9D = type_scope_count
    xor     eax, eax               ; EAX = loop counter i = 0
    lea     r10, [g_graph + GRAPH_TYPE_SCOPE_TYPE_IDS]

.gtsi_loop:
    cmp     eax, r9d
    jge     .gtsi_not_found
    cmp     ecx, [r10 + rax*4]    ; type_scope_type_ids[i] == type_name_id?
    je      .gtsi_done             ; return i (already in EAX)
    inc     eax
    jmp     .gtsi_loop

.gtsi_not_found:
    mov     eax, -1
.gtsi_done:
    ret


; ============================================================
; Phase 4e — Public API Read Functions
; ============================================================


; ============================================================
; herb_container_count(const char* container) -> int
;
; Returns entity count in named container, or -1 if not found.
;
; RCX = container name string pointer
; Returns EAX = entity count (or -1)
; ============================================================
herb_container_count:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32                ; shadow space

    ; intern(container) → EAX = name_id
    call    intern

    ; graph_find_container_by_name(name_id) → EAX = ci
    mov     ecx, eax
    call    graph_find_container_by_name

    ; if ci < 0 return -1
    test    eax, eax
    js      .hcc_done              ; -1 already in EAX

    ; Session 76: return entity count from parallel array
    movsxd  rdx, eax
    lea     rcx, [g_container_entity_counts]
    mov     eax, [rcx + rdx*4]

.hcc_done:
    leave
    ret


; ============================================================
; herb_container_entity(const char* container, int idx) -> int
;
; Returns entity ID at index idx in named container, or -1.
;
; RCX = container name string pointer
; EDX = idx
; Returns EAX = entity ID (or -1)
; ============================================================
herb_container_entity:
    push    rbp
    mov     rbp, rsp
    push    rsi                    ; save idx
    sub     rsp, 40                ; 32 shadow + 8 pad → 16-aligned

    mov     esi, edx               ; ESI = idx (callee-saved)

    ; intern(container)
    call    intern

    ; graph_find_container_by_name(name_id)
    mov     ecx, eax
    call    graph_find_container_by_name

    ; if ci < 0 return -1
    test    eax, eax
    js      .hce_fail

    ; Session 76: bounds check using parallel arrays
    test    esi, esi
    js      .hce_fail
    movsxd  rdx, eax               ; RDX = ci (sign-extended)
    lea     rcx, [g_container_entity_counts]
    cmp     esi, [rcx + rdx*4]
    jge     .hce_fail

    ; return g_container_entities[ci * 256 + idx]
    imul    rcx, rdx, MAX_ENTITY_PER_CONTAINER  ; RCX = ci * 256
    movsxd  rax, esi
    add     rax, rcx                            ; RAX = ci * 256 + idx
    lea     rcx, [g_container_entities]
    mov     eax, [rcx + rax*4]
    jmp     .hce_done

.hce_fail:
    mov     eax, -1
.hce_done:
    add     rsp, 40
    pop     rsi
    pop     rbp
    ret


; ============================================================
; herb_entity_name(int entity_id) -> const char*
;
; Returns entity name string, or "?" if invalid.
;
; ECX = entity_id
; Returns RAX = pointer to name string
; ============================================================
herb_entity_name:
    ; Bounds check
    test    ecx, ecx
    js      .hen_bad
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     ecx, [rax]
    jge     .hen_bad

    ; Load name_id and return str_of(name_id)
    movsxd  rax, ecx
    imul    rax, SIZEOF_ENTITY
    lea     rdx, [g_graph]
    mov     ecx, [rdx + rax + ENT_NAME_ID]
    jmp     str_of                 ; tail call

.hen_bad:
    lea     rax, [str_question]
    ret


; ============================================================
; herb_entity_prop_int(int entity_id, const char* property, int64_t default_val) -> int64_t
;
; Returns integer property value, or default_val if not found/wrong type.
;
; ECX = entity_id
; RDX = property string pointer
; R8  = default_val (int64_t)
; Returns RAX = property value (or default_val)
;
; Stack: push rbp + 3 pushes (32) + sub 48 = 80 from entry.
;   Entry RSP = 16n-8. After push rbp: 16n-16. 3 pushes: 16n-40.
;   Sub 48: 16n-88 = 16(n-6)+8 → not aligned.
;   Fix: sub 56 → 16n-96 = 16(n-6) → aligned ✓
; ============================================================
herb_entity_prop_int:
    push    rbp
    mov     rbp, rsp
    push    rbx                    ; EBX = entity_id
    push    rsi                    ; RSI = property string
    push    rdi                    ; RDI = default_val
    sub     rsp, 56                ; 16 (PropVal) + 32 (shadow) + 8 (pad)

    mov     ebx, ecx               ; EBX = entity_id
    mov     rsi, rdx               ; RSI = property string
    mov     rdi, r8                ; RDI = default_val

    ; Bounds check
    test    ebx, ebx
    js      .hepi_default
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     ebx, [rax]
    jge     .hepi_default

    ; intern(property) → EAX = key
    mov     rcx, rsi
    call    intern
    mov     esi, eax               ; ESI = key (reuse, no longer need string ptr)

    ; entity_get_prop_raw(entity_id, key, &pv)
    mov     ecx, ebx
    mov     edx, esi
    lea     r8, [rbp - 40]         ; PropVal buffer
    call    entity_get_prop_raw

    ; Check pv.type == PV_INT
    cmp     dword [rbp - 40], PV_INT_T
    jne     .hepi_default

    ; Return pv.value
    mov     rax, [rbp - 32]
    jmp     .hepi_done

.hepi_default:
    mov     rax, rdi               ; return default_val
.hepi_done:
    add     rsp, 56
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; herb_entity_prop_str(int entity_id, const char* property, const char* default_val)
;   -> const char*
;
; Returns string property value, or default_val.
;
; ECX = entity_id
; RDX = property string pointer
; R8  = default_val (const char*)
; Returns RAX = string pointer
;
; Same stack layout as herb_entity_prop_int.
; ============================================================
herb_entity_prop_str:
    push    rbp
    mov     rbp, rsp
    push    rbx                    ; EBX = entity_id
    push    rsi                    ; RSI = property string
    push    rdi                    ; RDI = default_val
    sub     rsp, 56                ; 16 (PropVal) + 32 (shadow) + 8 (pad)

    mov     ebx, ecx               ; EBX = entity_id
    mov     rsi, rdx               ; RSI = property string
    mov     rdi, r8                ; RDI = default_val

    ; Bounds check
    test    ebx, ebx
    js      .heps_default
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     ebx, [rax]
    jge     .heps_default

    ; intern(property)
    mov     rcx, rsi
    call    intern
    mov     esi, eax               ; ESI = key

    ; entity_get_prop_raw(entity_id, key, &pv)
    mov     ecx, ebx
    mov     edx, esi
    lea     r8, [rbp - 40]         ; PropVal buffer
    call    entity_get_prop_raw

    ; Check pv.type == PV_STRING
    cmp     dword [rbp - 40], PV_STRING_T
    jne     .heps_default

    ; Return str_of(pv.value) — pv.value is string_id
    mov     ecx, [rbp - 32]        ; pv.value (string_id, lower 32 bits)
    call    str_of
    jmp     .heps_done

.heps_default:
    mov     rax, rdi               ; return default_val
.heps_done:
    add     rsp, 56
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; herb_entity_location(int entity_id) -> const char*
;
; Returns container name where entity resides, or "?" / "null".
;
; ECX = entity_id
; Returns RAX = string pointer
; ============================================================
herb_entity_location:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32                ; shadow space

    ; Bounds check
    test    ecx, ecx
    js      .hel_bad
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     ecx, [rax]
    jge     .hel_bad

    ; loc = entity_location[entity_id]
    movsxd  rax, ecx
    lea     rdx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     eax, [rdx + rax*4]     ; EAX = loc
    test    eax, eax
    js      .hel_null

    ; return str_of(containers[loc].name_id)
    movsxd  rdx, eax
    imul    rdx, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    mov     ecx, [rcx + rdx + CNT_NAME_ID]
    call    str_of
    jmp     .hel_done

.hel_null:
    lea     rax, [str_null]
    jmp     .hel_done

.hel_bad:
    lea     rax, [str_question]

.hel_done:
    leave
    ret


; ============================================================
; herb_entity_total(void) -> int
;
; Returns total entity count in the graph.
; ============================================================
herb_entity_total:
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    mov     eax, [rax]
    ret


; ============================================================
; herb_tension_count(void) -> int
;
; Returns tension count in the graph.
; ============================================================
herb_tension_count:
    lea     rax, [g_tension_count]
    mov     eax, [rax]
    ret


; ============================================================
; herb_tension_name(int idx) -> const char*
;
; Returns tension name, or "" if out of bounds.
;
; ECX = idx
; Returns RAX = string pointer
; ============================================================
herb_tension_name:
    ; Bounds check
    test    ecx, ecx
    js      .htn_bad
    lea     rax, [g_tension_count]
    cmp     ecx, [rax]
    jge     .htn_bad

    ; return str_of(tensions[idx].name_id)
    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     rdx, [g_tensions]
    mov     ecx, [rdx + rax + TEN_NAME_ID]
    jmp     str_of                 ; tail call

.htn_bad:
    lea     rax, [str_empty]
    ret


; ============================================================
; herb_tension_priority(int idx) -> int
;
; Returns tension priority, or 0 if out of bounds.
;
; ECX = idx
; Returns EAX = priority
; ============================================================
herb_tension_priority:
    test    ecx, ecx
    js      .htp_zero
    lea     rax, [g_tension_count]
    cmp     ecx, [rax]
    jge     .htp_zero

    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     rdx, [g_tensions]
    mov     eax, [rdx + rax + TEN_PRIORITY]
    ret

.htp_zero:
    xor     eax, eax
    ret


; ============================================================
; herb_tension_enabled(int idx) -> int
;
; Returns tension enabled flag, or 0 if out of bounds.
;
; ECX = idx
; Returns EAX = enabled (0 or 1)
; ============================================================
herb_tension_enabled:
    test    ecx, ecx
    js      .hte_zero
    lea     rax, [g_tension_count]
    cmp     ecx, [rax]
    jge     .hte_zero

    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     rdx, [g_tensions]
    mov     eax, [rdx + rax + TEN_ENABLED]
    ret

.hte_zero:
    xor     eax, eax
    ret


; ============================================================
; Phase 4e — Mutations
; ============================================================


; ============================================================
; herb_tension_set_enabled(int idx, int enabled) -> void
;
; Sets tension enabled flag. No-op if out of bounds.
;
; ECX = idx
; EDX = enabled
; ============================================================
herb_tension_set_enabled:
    test    ecx, ecx
    js      .htse_done
    lea     rax, [g_tension_count]
    cmp     ecx, [rax]
    jge     .htse_done

    ; tensions[idx].enabled = enabled ? 1 : 0
    test    edx, edx
    setnz   dl                     ; DL = (enabled != 0) ? 1 : 0
    movzx   edx, dl

    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     rcx, [g_tensions]
    mov     [rcx + rax + TEN_ENABLED], edx

.htse_done:
    ret


; ============================================================
; herb_tension_owner(int idx) -> int
;
; Returns tension owner entity index, or -1 if out of bounds.
;
; ECX = idx
; Returns EAX = owner
; ============================================================
herb_tension_owner:
    test    ecx, ecx
    js      .hto_bad
    lea     rax, [g_tension_count]
    cmp     ecx, [rax]
    jge     .hto_bad

    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     rdx, [g_tensions]
    mov     eax, [rdx + rax + TEN_OWNER]
    ret

.hto_bad:
    mov     eax, -1
    ret


; ============================================================
; herb_set_prop_int(int entity_id, const char* property, int64_t value) -> int
;
; Sets integer property on entity. Returns 0 on success, -1 on error.
; Calls intern(property) to get key, then does inline set logic.
;
; ECX = entity_id
; RDX = property string pointer
; R8  = value (int64_t)
; Returns EAX = 0 (success) or -1 (error)
;
; Stack: push rbp + 4 pushes (32) + sub 48 = 80 from entry.
;   Entry RSP = 16n-8. After push rbp: 16n-16. 4 pushes: 16n-48.
;   Sub 48: 16n-96 = 16(n-6) → aligned ✓
; ============================================================
herb_set_prop_int:
    push    rbp
    mov     rbp, rsp
    push    rbx                    ; EBX = entity_id
    push    rsi                    ; RSI = property string ptr
    push    rdi                    ; RDI = value
    push    r12                    ; R12 = entity base pointer
    sub     rsp, 48                ; 32 shadow + 16 pad → 16-aligned
                                   ; 4 pushes (32) + sub 48 = 80 + push rbp 8 = 88
                                   ; Entry RSP 16n-8: 16n-8-88 = 16(n-6) → aligned ✓

    mov     ebx, ecx               ; EBX = entity_id
    mov     rsi, rdx               ; RSI = property string
    mov     rdi, r8                ; RDI = value

    ; Bounds check
    test    ebx, ebx
    js      .hspi_err
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     ebx, [rax]
    jge     .hspi_err

    ; Compute entity base
    movsxd  rax, ebx
    imul    rax, SIZEOF_ENTITY
    lea     r12, [g_graph]
    add     r12, rax               ; R12 = &entities[entity_id]

    ; intern(property) → EAX = key
    mov     rcx, rsi
    call    intern
    mov     esi, eax               ; ESI = key (reuse register)

    ; Linear scan prop_keys for key
    mov     r8d, [r12 + ENT_PROP_COUNT]
    xor     ecx, ecx               ; ECX = loop counter
.hspi_scan:
    cmp     ecx, r8d
    jge     .hspi_append

    cmp     esi, [r12 + ENT_PROP_KEYS + rcx*4]
    je      .hspi_update

    inc     ecx
    jmp     .hspi_scan

.hspi_update:
    ; prop_vals[i] = pv_int(value)
    mov     eax, ecx
    shl     eax, 4                 ; i * 16
    mov     dword [r12 + ENT_PROP_VALS + rax + PV_TYPE], PV_INT_T
    mov     dword [r12 + ENT_PROP_VALS + rax + 4], 0       ; padding
    mov     [r12 + ENT_PROP_VALS + rax + PV_VALUE], rdi     ; value
    xor     eax, eax               ; return 0
    jmp     .hspi_done

.hspi_append:
    ; Check prop_count < MAX_PROPERTIES
    cmp     r8d, MAX_PROPERTIES
    jge     .hspi_err

    ; prop_keys[prop_count] = key
    mov     [r12 + ENT_PROP_KEYS + r8*4], esi

    ; prop_vals[prop_count] = pv_int(value)
    mov     eax, r8d
    shl     eax, 4                 ; prop_count * 16
    mov     dword [r12 + ENT_PROP_VALS + rax + PV_TYPE], PV_INT_T
    mov     dword [r12 + ENT_PROP_VALS + rax + 4], 0
    mov     [r12 + ENT_PROP_VALS + rax + PV_VALUE], rdi

    ; prop_count++
    inc     r8d
    mov     [r12 + ENT_PROP_COUNT], r8d

    xor     eax, eax               ; return 0
    jmp     .hspi_done

.hspi_err:
    mov     eax, -1
    jmp     .hspi_ret
.hspi_done:
    ; Session 79: Mark entity's container dirty on successful property set
    movsxd  rax, ebx                    ; entity_id (callee-saved)
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     ecx, [rcx + rax*4]
    test    ecx, ecx
    js      .hspi_no_dirty
    push    rax                         ; preserve return value (xor eax,eax = 0)
    call    ham_dirty_mark
    pop     rax
.hspi_no_dirty:
    xor     eax, eax                    ; return 0 (success)
.hspi_ret:
    add     rsp, 48
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret


; ============================================================
; Phase 4e — Container/State Functions
; ============================================================


; ============================================================
; herb_create_container(const char* name, int kind) -> int
;
; Allocates a new container in g_graph.
; Returns container index, or -1 if full.
;
; RCX = name string pointer
; EDX = kind (ContainerKind)
; Returns EAX = container index (or -1)
; ============================================================
herb_create_container:
    push    rbp
    mov     rbp, rsp
    push    rbx                    ; EBX = kind
    sub     rsp, 40                ; 32 shadow + 8 pad

    mov     ebx, edx               ; EBX = kind

    ; Check container_count < MAX_CONTAINERS
    lea     rax, [g_graph + GRAPH_CONTAINER_COUNT]
    mov     edx, [rax]
    cmp     edx, MAX_CONTAINERS
    jge     .hcrc_full

    ; ci = container_count++
    mov     r8d, edx               ; R8D = ci
    inc     edx
    mov     [rax], edx             ; store incremented count

    ; intern(name) → EAX = name_id
    ; RCX already = name
    push    r8                     ; save ci (caller-saved)
    call    intern
    pop     r8                     ; restore ci
    mov     edx, eax               ; EDX = name_id

    ; Compute container base: &containers[ci]
    movsxd  rax, r8d
    imul    rax, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    add     rcx, rax               ; RCX = &containers[ci]

    ; c->id = ci
    mov     [rcx + CNT_ID], r8d
    ; c->name_id = name_id
    mov     [rcx + CNT_NAME_ID], edx
    ; c->kind = kind
    mov     [rcx + CNT_KIND], ebx
    ; c->entity_type = -1
    mov     dword [rcx + CNT_ENTITY_TYPE], -1
    ; Session 76: entity_count = 0 in parallel array
    movsxd  rax, r8d
    lea     rdx, [g_container_entity_counts]
    mov     dword [rdx + rax*4], 0
    ; c->owner = -1
    mov     dword [rcx + CNT_OWNER], -1

    mov     eax, r8d               ; return ci
    jmp     .hcrc_done

.hcrc_full:
    mov     eax, -1
.hcrc_done:
    add     rsp, 40
    pop     rbx
    pop     rbp
    ret


; ============================================================
; is_property_pooled(int prop_id) -> int
;
; Scans pools[0..pool_count-1] for prop_id.
; Returns 1 if found, 0 if not.
;
; ECX = prop_id
; Returns EAX = 1 (pooled) or 0 (not pooled)
; ============================================================
is_property_pooled:
    lea     r9, [g_graph + GRAPH_POOL_COUNT]
    mov     r9d, [r9]              ; R9D = pool_count
    xor     eax, eax               ; EAX = loop counter i = 0
    lea     r10, [g_graph + GRAPH_POOLS]

.ipp_loop:
    cmp     eax, r9d
    jge     .ipp_not_found
    movsxd  rdx, eax
    imul    rdx, SIZEOF_POOL
    cmp     ecx, [r10 + rdx + POOL_PROPERTY_ID]
    je      .ipp_found
    inc     eax
    jmp     .ipp_loop

.ipp_found:
    mov     eax, 1
    ret

.ipp_not_found:
    xor     eax, eax
    ret


; ============================================================
; herb_state(char* buf, int buf_size) -> int
;
; Serializes entity state to JSON buffer. Returns chars written.
; Format: {"entity_name": {"location": "container", "prop": val, ...}, ...}
;
; RCX = buf pointer
; EDX = buf_size
; Returns EAX = number of characters written
;
; Callee-saved register assignments:
;   RBX = buf pointer
;   ESI = buf_size
;   EDI = pos (write position)
;   R12 = entity loop counter i
;   R13 = first_entity flag
;   R14 = entity base pointer (current iteration)
;   R15 = prop loop counter j
;
; Stack: push rbp + 7 pushes (56) + sub rsp = aligned
;   Entry: 16n-8. Push rbp: 16n-16. 7 pushes: 16n-72.
;   Sub 96: 16n-168 = 16(n-11)+8 → not aligned.
;   Sub 104: 16n-176 = 16(n-11) → aligned ✓
;   Stack space: 32 (shadow) + 32 (snprintf tmp) + 8 (local) + 32 (pad) = 104
; ============================================================
herb_state:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 104               ; 32 shadow + 32 snprintf tmp + 40 pad

    mov     rbx, rcx               ; RBX = buf
    mov     esi, edx               ; ESI = buf_size
    xor     edi, edi               ; EDI = pos = 0

    ; --- EMIT helper: writes char to buf[pos] if pos < buf_size-1, always increments pos
    ; --- We use inline macros via jumps to helper labels at bottom

    ; EMITS("{\n")
    lea     rcx, [str_open_brace]
    call    .hs_emits

    mov     r13d, 1                ; first_entity = 1
    xor     r12d, r12d             ; i = 0

.hs_entity_loop:
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    cmp     r12d, [rax]
    jge     .hs_entity_done

    ; Compute entity base: R14 = &entities[i]
    movsxd  rax, r12d
    imul    rax, SIZEOF_ENTITY
    lea     r14, [g_graph]
    add     r14, rax

    ; if (!first_entity) EMITS(",\n")
    test    r13d, r13d
    jnz     .hs_skip_comma
    lea     rcx, [str_comma_nl]
    call    .hs_emits
.hs_skip_comma:
    xor     r13d, r13d             ; first_entity = 0

    ; EMITS("  \"")
    lea     rcx, [str_ent_pre]
    call    .hs_emits

    ; EMITS(str_of(e->name_id))
    mov     ecx, [r14 + ENT_NAME_ID]
    call    str_of
    mov     rcx, rax
    call    .hs_emits

    ; EMITS("\": {\"location\": \"")
    lea     rcx, [str_loc_mid]
    call    .hs_emits

    ; Get location name
    movsxd  rax, r12d
    lea     rcx, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     eax, [rcx + rax*4]     ; EAX = loc
    test    eax, eax
    js      .hs_loc_null

    ; loc >= 0: str_of(containers[loc].name_id)
    movsxd  rdx, eax
    imul    rdx, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    mov     ecx, [rcx + rdx + CNT_NAME_ID]
    call    str_of
    mov     rcx, rax
    jmp     .hs_loc_emit
.hs_loc_null:
    lea     rcx, [str_null]
.hs_loc_emit:
    call    .hs_emits

    ; EMIT('"')
    mov     cl, '"'
    call    .hs_emit_char

    ; Property loop
    xor     r15d, r15d             ; j = 0
.hs_prop_loop:
    cmp     r15d, [r14 + ENT_PROP_COUNT]
    jge     .hs_prop_done

    ; EMITS(", \"")
    lea     rcx, [str_prop_pre]
    call    .hs_emits

    ; EMITS(str_of(e->prop_keys[j]))
    mov     ecx, [r14 + ENT_PROP_KEYS + r15*4]
    call    str_of
    mov     rcx, rax
    call    .hs_emits

    ; EMITS("\": ")
    lea     rcx, [str_prop_mid]
    call    .hs_emits

    ; Dispatch on prop_vals[j].type
    mov     eax, r15d
    shl     eax, 4                 ; j * 16
    mov     r8d, [r14 + ENT_PROP_VALS + rax + PV_TYPE]

    cmp     r8d, PV_INT_T
    je      .hs_prop_int
    cmp     r8d, PV_FLOAT_T
    je      .hs_prop_float
    cmp     r8d, PV_STRING_T
    je      .hs_prop_string

    ; PV_NONE: EMITS("null")
    lea     rcx, [str_null]
    call    .hs_emits
    jmp     .hs_prop_next

.hs_prop_int:
    ; herb_snprintf(tmp, 24, "%lld", v.i)
    mov     eax, r15d
    shl     eax, 4
    mov     r9, [r14 + ENT_PROP_VALS + rax + PV_VALUE]  ; int64 value
    lea     rcx, [rbp - 136]       ; tmp buffer (at rbp - 7*8 - 32 - 32 = rbp-120... let me use a fixed offset)
    ; Actually, let's use stack space we allocated
    ; rbp - (7 pushes * 8) = rbp - 56. sub 104 more = rbp - 160 is RSP.
    ; shadow at RSP+0..31, tmp at RSP+32..63
    lea     rcx, [rsp + 32]        ; tmp buffer
    mov     edx, 24                ; size
    lea     r8, [str_lld_fmt]      ; "%lld"
    ; R9 already = value (4th arg)
    call    herb_snprintf
    lea     rcx, [rsp + 32]
    call    .hs_emits
    jmp     .hs_prop_next

.hs_prop_float:
    ; herb_snprintf(tmp, 32, "%g", v.f)
    mov     eax, r15d
    shl     eax, 4
    movsd   xmm0, [r14 + ENT_PROP_VALS + rax + PV_VALUE]  ; double value
    ; MS x64: float/double vararg passed in both XMM and integer reg
    movq    r9, xmm0              ; copy double bits to R9 for vararg
    lea     rcx, [rsp + 32]
    mov     edx, 32
    lea     r8, [str_g_fmt]
    ; For varargs, MS x64 requires double in BOTH xmm3 AND r9
    ; Actually for snprintf with varargs: fmt is 3rd arg (R8), value is 4th (R9/XMM3)
    ; But herb_snprintf is variadic: buf=RCX, size=RDX, fmt=R8, then ...
    ; The 4th actual parameter is the first variadic arg, goes in R9 for int or XMM3 for float
    ; For variadic functions in MS x64, floats must be in BOTH the integer reg AND the XMM reg
    movsd   xmm3, xmm0            ; XMM3 for the float path
    call    herb_snprintf
    lea     rcx, [rsp + 32]
    call    .hs_emits
    jmp     .hs_prop_next

.hs_prop_string:
    ; EMIT('"')
    mov     cl, '"'
    call    .hs_emit_char
    ; EMITS(str_of(v.s))
    mov     eax, r15d
    shl     eax, 4
    mov     ecx, [r14 + ENT_PROP_VALS + rax + PV_VALUE]
    call    str_of
    mov     rcx, rax
    call    .hs_emits
    ; EMIT('"')
    mov     cl, '"'
    call    .hs_emit_char

.hs_prop_next:
    inc     r15d
    jmp     .hs_prop_loop

.hs_prop_done:
    ; EMIT('}')
    mov     cl, '}'
    call    .hs_emit_char

    inc     r12d
    jmp     .hs_entity_loop

.hs_entity_done:
    ; EMITS("\n}\n")
    lea     rcx, [str_close_brace]
    call    .hs_emits

    ; Null-terminate
    cmp     edi, esi
    jge     .hs_trunc
    mov     byte [rbx + rdi], 0
    jmp     .hs_return
.hs_trunc:
    ; buf_size > 0 ? buf[buf_size-1] = '\0'
    test    esi, esi
    jz      .hs_return
    lea     eax, [esi - 1]
    mov     byte [rbx + rax], 0

.hs_return:
    mov     eax, edi               ; return pos
    add     rsp, 104
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; --- Helper: emit single char (CL = char) ---
; Preserves all callee-saved regs. Uses RBX=buf, ESI=buf_size, EDI=pos.
.hs_emit_char:
    lea     eax, [esi - 1]
    cmp     edi, eax
    jge     .hs_ec_skip
    mov     [rbx + rdi], cl
.hs_ec_skip:
    inc     edi
    ret

; --- Helper: emit string (RCX = null-terminated string) ---
; Preserves all callee-saved regs. Uses RBX=buf, ESI=buf_size, EDI=pos.
.hs_emits:
    push    r15                    ; save r15 temporarily (may be in use by caller)
    mov     r15, rcx               ; R15 = string pointer
.hs_es_loop:
    movzx   eax, byte [r15]
    test    al, al
    jz      .hs_es_done
    ; emit char
    lea     ecx, [esi - 1]
    cmp     edi, ecx
    jge     .hs_es_skip
    mov     [rbx + rdi], al
.hs_es_skip:
    inc     edi
    inc     r15
    jmp     .hs_es_loop
.hs_es_done:
    pop     r15
    ret

; ============================================================
; PHASE 4f: HAM RUNTIME GLUE
; ============================================================

; ============================================================
; ham_mark_dirty() -> void
; Sets g_ham_dirty = 1
; ============================================================
ham_mark_dirty:
    lea     rax, [g_ham_dirty]
    mov     dword [rax], 1
    ret

; ============================================================
; ham_ensure_compiled() -> void
; If g_ham_dirty, call ham_compile_all(g_ham_bytecode, HAM_BYTECODE_SIZE, &g_ham_compiled_count)
; Then clear g_ham_dirty.
; ============================================================
ham_ensure_compiled:
    lea     rax, [g_ham_dirty]
    cmp     dword [rax], 0
    je      .hec_done
    ; dirty — need to compile
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32                ; shadow space
    lea     rcx, [g_ham_bytecode]
    mov     edx, HAM_BYTECODE_SIZE
    lea     r8, [g_ham_compiled_count]
    call    ham_compile_all
    lea     rcx, [g_ham_bytecode_len]
    mov     [rcx], eax             ; g_ham_bytecode_len = result
    lea     rcx, [g_ham_dirty]
    mov     dword [rcx], 0         ; g_ham_dirty = 0
    add     rsp, 32
    pop     rbp
.hec_done:
    ret

; ============================================================
; ham_run_ham(int max_steps) -> int ops
; RCX = max_steps (unused — ham_run doesn't take it)
; Ensure compiled, then run if bytecode_len > 0
; ============================================================
ham_run_ham:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32                ; shadow space
    call    ham_ensure_compiled
    lea     rax, [g_ham_bytecode_len]
    mov     edx, [rax]
    test    edx, edx
    jle     .hrh_zero
    lea     rcx, [g_ham_bytecode]
    ; EDX already has bytecode_len
    call    ham_run
    jmp     .hrh_done
.hrh_zero:
    xor     eax, eax
.hrh_done:
    add     rsp, 32
    pop     rbp
    ret

; ============================================================
; ham_get_compiled_count() -> int
; ============================================================
ham_get_compiled_count:
    lea     rax, [g_ham_compiled_count]
    mov     eax, [rax]
    ret

; ============================================================
; ham_get_bytecode_len() -> int
; ============================================================
ham_get_bytecode_len:
    lea     rax, [g_ham_bytecode_len]
    mov     eax, [rax]
    ret

; ============================================================
; PHASE 4f: ENTITY CREATION
; ============================================================

; ============================================================
; create_entity(int type_name_id, int name_id, int container_idx) -> int ei
;
; RCX = type_name_id, RDX = name_id, R8D = container_idx
; Returns EAX = entity index
;
; Allocates entity, sets fields, calls container_add if container >= 0,
; then auto-creates scoped containers via get_type_scope_idx + snprintf loop.
;
; Stack: 296 bytes (32 shadow + 8 arg5 + 256 cname buffer)
; Callee-saved: RBX=ei, ESI=type_name_id→ci, EDI=name_id→st_ptr,
;               R12=container_idx→template_base, R13D=count, R14=ent_name, R15D=loop_i
; ============================================================
create_entity:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 296           ; 32 shadow + 8 (5th arg) + 256 (cname) = 296

    ; Save args to callee-saved regs
    mov     esi, ecx           ; ESI = type_name_id
    mov     edi, edx           ; EDI = name_id
    mov     r12d, r8d          ; R12D = container_idx

    ; ei = g_graph.entity_count++
    lea     rax, [g_graph + GRAPH_ENTITY_COUNT]
    mov     ebx, [rax]         ; EBX = ei
    lea     ecx, [ebx + 1]
    mov     [rax], ecx         ; entity_count++

    ; Entity setup: e = &g_graph.entities[ei]
    movsxd  rax, ebx
    imul    rax, SIZEOF_ENTITY
    lea     r13, [g_graph + rax]  ; R13 = &entities[ei] (temp use)
    mov     [r13 + ENT_ID], ebx
    mov     [r13 + ENT_TYPE_ID], esi
    mov     [r13 + ENT_NAME_ID], edi
    mov     dword [r13 + ENT_PROP_COUNT], 0

    ; g_graph.entity_location[ei] = container_idx
    movsxd  rcx, ebx
    lea     rax, [g_graph + GRAPH_ENTITY_LOCATION]
    mov     [rax + rcx*4], r12d

    ; g_graph.entity_scope_count[ei] = 0
    lea     rax, [g_graph + GRAPH_ENTITY_SCOPE_COUNT]
    mov     dword [rax + rcx*4], 0

    ; if (container_idx >= 0) container_add(container_idx, ei)
    test    r12d, r12d
    js      .ce_no_add
    mov     ecx, r12d
    mov     edx, ebx
    call    container_add
    ; Session 79: Mark dest container dirty
    mov     ecx, r12d         ; R12D = container_idx (callee-saved)
    call    ham_dirty_mark
.ce_no_add:

    ; tsi = get_type_scope_idx(type_name_id)
    mov     ecx, esi
    call    get_type_scope_idx
    test    eax, eax
    js      .ce_done           ; tsi < 0, no scoped containers

    ; Compute template base: &g_graph.type_scope_templates[tsi][0]
    ; Each type has 16 ScopeTemplates * 12 bytes = 192 bytes
    movsxd  rcx, eax
    imul    rcx, 192
    lea     r12, [g_graph + GRAPH_TYPE_SCOPE_TEMPLATES]
    add     r12, rcx           ; R12 = template base

    ; count = g_graph.type_scope_counts[tsi]
    movsxd  rcx, eax
    lea     rdx, [g_graph + GRAPH_TYPE_SCOPE_COUNTS]
    mov     r13d, [rdx + rcx*4] ; R13D = count

    ; ent_name = str_of(name_id)
    mov     ecx, edi
    call    str_of
    mov     r14, rax           ; R14 = ent_name

    ; Loop: i = 0..count-1
    xor     r15d, r15d

.ce_scope_loop:
    cmp     r15d, r13d
    jge     .ce_done

    ; st = &template_base[i] = R12 + i * SIZEOF_SCOPETEMPLATE
    movsxd  rax, r15d
    imul    rax, SIZEOF_SCOPETEMPLATE
    lea     rdi, [r12 + rax]   ; RDI = st pointer (callee-saved)

    ; str_of(st->name_id) for scope name
    mov     ecx, [rdi + ST_NAME_ID]
    call    str_of             ; RAX = scope name string

    ; herb_snprintf(cname, 256, "%s::%s", ent_name, scope_name)
    mov     [rsp + 32], rax    ; 5th arg = scope name
    lea     rcx, [rsp + 40]    ; buf = cname (at rsp+40)
    mov     edx, 256
    lea     r8, [str_scope_fmt]
    mov     r9, r14            ; ent_name
    call    herb_snprintf

    ; ci = g_graph.container_count++
    lea     rax, [g_graph + GRAPH_CONTAINER_COUNT]
    mov     esi, [rax]         ; ESI = ci (callee-saved)
    lea     ecx, [esi + 1]
    mov     [rax], ecx

    ; intern(cname) → container name_id
    lea     rcx, [rsp + 40]
    call    intern             ; EAX = interned name_id

    ; c = &g_graph.containers[ci]
    movsxd  rdx, esi
    imul    rdx, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS + rdx]

    ; Set container fields
    mov     [rcx + CNT_ID], esi
    mov     [rcx + CNT_NAME_ID], eax       ; intern result
    mov     eax, [rdi + ST_KIND]           ; st->kind
    mov     [rcx + CNT_KIND], eax
    mov     eax, [rdi + ST_ENTITY_TYPE]    ; st->entity_type
    mov     [rcx + CNT_ENTITY_TYPE], eax
    ; Session 76: entity_count = 0 in parallel array
    movsxd  rax, esi
    lea     rdx, [g_container_entity_counts]
    mov     dword [rdx + rax*4], 0
    mov     [rcx + CNT_OWNER], ebx         ; ei

    ; Track scope: si = entity_scope_count[ei]++
    movsxd  rax, ebx
    lea     rdx, [g_graph + GRAPH_ENTITY_SCOPE_COUNT]
    mov     ecx, [rdx + rax*4]            ; ECX = si
    lea     r8d, [ecx + 1]
    mov     [rdx + rax*4], r8d            ; scope_count++

    ; entity_scope_names[ei][si] = st->name_id
    movsxd  r8, ebx
    shl     r8, 6                          ; ei * 64 (16 ints * 4 bytes)
    lea     rdx, [g_graph + GRAPH_ENTITY_SCOPE_NAMES]
    add     rdx, r8
    movsxd  r8, ecx
    mov     eax, [rdi + ST_NAME_ID]
    mov     [rdx + r8*4], eax

    ; entity_scope_cids[ei][si] = ci
    movsxd  r8, ebx
    shl     r8, 6
    lea     rdx, [g_graph + GRAPH_ENTITY_SCOPE_CIDS]
    add     rdx, r8
    movsxd  r8, ecx
    mov     [rdx + r8*4], esi

    inc     r15d
    jmp     .ce_scope_loop

.ce_done:
    mov     eax, ebx           ; return ei
    add     rsp, 296
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
; herb_create(const char* name, const char* type, const char* container) -> int
;
; RCX = name, RDX = type, R8 = container
; Returns EAX = entity index, or -1 on error
; ============================================================
herb_create:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 32            ; shadow space

    mov     rsi, rcx           ; RSI = name
    mov     rdi, rdx           ; RDI = type
    mov     r12, r8            ; R12 = container

    ; intern(container) → find container by name
    mov     rcx, r12
    call    intern
    mov     ecx, eax
    call    graph_find_container_by_name
    test    eax, eax
    js      .hcr_fail
    mov     ebx, eax           ; EBX = ci

    ; intern(type)
    mov     rcx, rdi
    call    intern
    mov     r12d, eax          ; R12D = interned type

    ; intern(name)
    mov     rcx, rsi
    call    intern

    ; create_entity(intern_type, intern_name, ci)
    mov     ecx, r12d          ; type_name_id
    mov     edx, eax           ; name_id
    mov     r8d, ebx           ; container_idx
    call    create_entity
    jmp     .hcr_done

.hcr_fail:
    mov     eax, -1
.hcr_done:
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; PHASE 4f: TENSION REMOVE FUNCTIONS
; ============================================================

; ============================================================
; herb_remove_owner_tensions(int owner_entity) -> int removed
;
; RCX = owner_entity
; Compact loop: skip tensions with matching owner, copy rest with herb_memcpy.
; Returns count removed. Calls ham_mark_dirty if any removed.
; ============================================================
herb_remove_owner_tensions:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    sub     rsp, 40            ; 32 shadow + 8 align

    mov     ebx, ecx           ; EBX = owner_entity
    xor     esi, esi           ; ESI = write = 0
    xor     edi, edi           ; EDI = read = 0
    xor     r12d, r12d         ; R12D = removed = 0
    lea     rax, [g_tension_count]
    mov     r13d, [rax]        ; R13D = tension_count

.hrot_loop:
    cmp     edi, r13d
    jge     .hrot_done

    ; Check tensions[read].owner == owner_entity
    movsxd  rax, edi
    imul    rax, SIZEOF_TENSION
    cmp     dword [g_tensions + rax + TEN_OWNER], ebx
    jne     .hrot_keep

    ; Match — skip
    inc     r12d
    jmp     .hrot_next

.hrot_keep:
    cmp     esi, edi
    je      .hrot_no_copy

    ; memcpy(&tensions[write], &tensions[read], SIZEOF_TENSION)
    movsxd  rax, esi
    imul    rax, SIZEOF_TENSION
    lea     rcx, [g_tensions + rax]
    movsxd  rax, edi
    imul    rax, SIZEOF_TENSION
    lea     rdx, [g_tensions + rax]
    mov     r8, SIZEOF_TENSION
    call    herb_memcpy

    ; Compact tension_step_flags[write] = tension_step_flags[read]
    lea     rax, [tension_step_flags]
    mov     ecx, [rax + rdi*4]
    mov     [rax + rsi*4], ecx

.hrot_no_copy:
    inc     esi

.hrot_next:
    inc     edi
    jmp     .hrot_loop

.hrot_done:
    lea     rax, [g_tension_count]
    mov     [rax], esi
    test    r12d, r12d
    jz      .hrot_return
    call    ham_mark_dirty

.hrot_return:
    mov     eax, r12d
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; herb_remove_tension_by_name(const char* name) -> int (0 or 1)
;
; RCX = name string
; Same compact loop, matches by name_id. Removes first match only.
; ============================================================
herb_remove_tension_by_name:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    sub     rsp, 40

    ; intern(name) → name_id
    call    intern
    mov     ebx, eax           ; EBX = name_id
    xor     esi, esi           ; ESI = write = 0
    xor     edi, edi           ; EDI = read = 0
    xor     r12d, r12d         ; R12D = removed = 0
    lea     rax, [g_tension_count]
    mov     r13d, [rax]        ; R13D = tension_count

.hrtn_loop:
    cmp     edi, r13d
    jge     .hrtn_done

    movsxd  rax, edi
    imul    rax, SIZEOF_TENSION
    cmp     dword [g_tensions + rax + TEN_NAME_ID], ebx
    jne     .hrtn_keep
    test    r12d, r12d
    jnz     .hrtn_keep         ; already removed one

    ; First match — skip
    mov     r12d, 1
    jmp     .hrtn_next

.hrtn_keep:
    cmp     esi, edi
    je      .hrtn_no_copy

    movsxd  rax, esi
    imul    rax, SIZEOF_TENSION
    lea     rcx, [g_tensions + rax]
    movsxd  rax, edi
    imul    rax, SIZEOF_TENSION
    lea     rdx, [g_tensions + rax]
    mov     r8, SIZEOF_TENSION
    call    herb_memcpy

    ; Compact tension_step_flags[write] = tension_step_flags[read]
    lea     rax, [tension_step_flags]
    mov     ecx, [rax + rdi*4]
    mov     [rax + rsi*4], ecx

.hrtn_no_copy:
    inc     esi

.hrtn_next:
    inc     edi
    jmp     .hrtn_loop

.hrtn_done:
    lea     rax, [g_tension_count]
    mov     [rax], esi
    test    r12d, r12d
    jz      .hrtn_return
    call    ham_mark_dirty

.hrtn_return:
    mov     eax, r12d
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; PHASE 4f: TENSION CREATION API
; ============================================================

; ============================================================
; herb_tension_create(name, priority, owner_entity, run_container_name) -> int tidx
;
; RCX = name, EDX = priority, R8D = owner_entity, R9 = run_container_name
; Returns tension index, or -1 if full.
; ============================================================
herb_tension_create:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    sub     rsp, 32

    ; Save args
    mov     rbx, rcx           ; RBX = name
    mov     esi, edx           ; ESI = priority
    mov     edi, r8d           ; EDI = owner_entity
    mov     r12, r9            ; R12 = run_container_name

    ; Check capacity
    lea     rax, [g_tension_count]
    mov     r13d, [rax]        ; R13D = ti
    cmp     r13d, MAX_TENSIONS
    jge     .htc_fail
    lea     ecx, [r13d + 1]
    mov     [rax], ecx         ; tension_count++

    ; t = &g_graph.tensions[ti]
    movsxd  rax, r13d
    imul    rax, SIZEOF_TENSION
    lea     r14, [g_tensions + rax]  ; R14 = t

    ; herb_memset(t, 0, sizeof(Tension))
    mov     rcx, r14
    xor     edx, edx
    mov     r8, SIZEOF_TENSION
    call    herb_memset

    ; t->name_id = intern(name)
    mov     rcx, rbx
    call    intern
    mov     [r14 + TEN_NAME_ID], eax

    ; t->priority, enabled, owner
    mov     [r14 + TEN_PRIORITY], esi
    mov     dword [r14 + TEN_ENABLED], 1
    mov     [r14 + TEN_OWNER], edi

    ; Handle run_container_name
    test    r12, r12
    jz      .htc_no_run
    cmp     byte [r12], 0
    je      .htc_no_run
    mov     rcx, r12
    call    intern
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [r14 + TEN_OWNER_RUN_CNT], eax
    jmp     .htc_init_matches

.htc_no_run:
    mov     dword [r14 + TEN_OWNER_RUN_CNT], -1

.htc_init_matches:
    ; matches[i]: scope_bind_id=-1, channel_idx=-1, container_idx=-1
    xor     ecx, ecx
.htc_match_loop:
    cmp     ecx, MAX_MATCH_CLAUSES
    jge     .htc_init_emits
    movsxd  rax, ecx
    imul    rax, SIZEOF_MATCHCLAUSE
    mov     dword [r14 + TEN_MATCHES + rax + MC_SCOPE_BIND_ID], -1
    mov     dword [r14 + TEN_MATCHES + rax + MC_CHANNEL_IDX], -1
    mov     dword [r14 + TEN_MATCHES + rax + MC_CONTAINER_IDX], -1
    inc     ecx
    jmp     .htc_match_loop

.htc_init_emits:
    ; emits[i]: 6 fields = -1
    xor     ecx, ecx
.htc_emit_loop:
    cmp     ecx, MAX_EMIT_CLAUSES
    jge     .htc_dirty
    movsxd  rax, ecx
    imul    rax, SIZEOF_EMITCLAUSE
    mov     dword [r14 + TEN_EMITS + rax + EC_TO_REF], -1
    mov     dword [r14 + TEN_EMITS + rax + EC_TO_SCOPE_BIND_ID], -1
    mov     dword [r14 + TEN_EMITS + rax + EC_SEND_CHANNEL_IDX], -1
    mov     dword [r14 + TEN_EMITS + rax + EC_RECV_CHANNEL_IDX], -1
    mov     dword [r14 + TEN_EMITS + rax + EC_RECV_TO_SCOPE_BIND_ID], -1
    mov     dword [r14 + TEN_EMITS + rax + EC_DUP_IN_SCOPE_BIND_ID], -1
    inc     ecx
    jmp     .htc_emit_loop

.htc_dirty:
    call    ham_mark_dirty
    mov     eax, r13d          ; return ti
    jmp     .htc_done

.htc_fail:
    mov     eax, -1
.htc_done:
    add     rsp, 32
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; herb_tension_match_in(tidx, bind_name, container, select_mode) -> int
;
; RCX = tidx, RDX = bind_name, R8 = container, R9D = select_mode
; Returns 0 on success, -1 on error.
; ============================================================
herb_tension_match_in:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    sub     rsp, 40

    ; Save args
    mov     rbx, rdx           ; RBX = bind_name
    mov     rdi, r8            ; RDI = container
    mov     esi, r9d           ; ESI = select_mode

    ; Validate tidx
    test    ecx, ecx
    js      .htmi_fail
    lea     rax, [g_tension_count]
    cmp     ecx, [rax]
    jge     .htmi_fail

    ; t = &g_graph.tensions[tidx]
    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     r12, [g_tensions + rax]

    ; Check & increment match_count
    mov     eax, [r12 + TEN_MATCH_COUNT]
    cmp     eax, MAX_MATCH_CLAUSES
    jge     .htmi_fail
    lea     ecx, [eax + 1]
    mov     [r12 + TEN_MATCH_COUNT], ecx

    ; mc = &t->matches[old_match_count]
    movsxd  rcx, eax
    imul    rcx, SIZEOF_MATCHCLAUSE
    lea     r13, [r12 + TEN_MATCHES + rcx]  ; R13 = mc

    ; herb_memset(mc, 0, sizeof(MatchClause))
    mov     rcx, r13
    xor     edx, edx
    mov     r8, SIZEOF_MATCHCLAUSE
    call    herb_memset

    ; mc->kind = MC_ENTITY_IN (0)
    mov     dword [r13 + MC_KIND], MC_ENTITY_IN_V

    ; mc->bind_id = intern(bind_name)
    mov     rcx, rbx
    call    intern
    mov     [r13 + MC_BIND_ID], eax

    ; mc->container_idx = graph_find_container_by_name(intern(container))
    mov     rcx, rdi
    call    intern
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [r13 + MC_CONTAINER_IDX], eax

    ; mc->select, required, scope_bind_id, channel_idx
    mov     [r13 + MC_SELECT], esi
    mov     dword [r13 + MC_REQUIRED], 1
    mov     dword [r13 + MC_SCOPE_BIND_ID], -1
    mov     dword [r13 + MC_CHANNEL_IDX], -1

    xor     eax, eax
    jmp     .htmi_done

.htmi_fail:
    mov     eax, -1
.htmi_done:
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; herb_tension_match_in_where(tidx, bind_name, container, select_mode, where_expr) -> int
;
; RCX = tidx, RDX = bind_name, R8 = container, R9D = select_mode
; 5th arg: where_expr at [RBP + 48]
; Calls herb_tension_match_in, then sets where_expr on last match.
; ============================================================
herb_tension_match_in_where:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    sub     rsp, 40            ; 32 shadow + 8 align

    mov     ebx, ecx           ; save tidx
    mov     rsi, [rbp + 48]    ; RSI = where_expr (5th arg)

    ; Call herb_tension_match_in(tidx, bind_name, container, select_mode)
    ; RCX = tidx, RDX/R8/R9 still intact from caller
    mov     ecx, ebx
    call    herb_tension_match_in
    test    eax, eax
    js      .htmiw_done        ; rc < 0, return it

    ; t->matches[match_count - 1].where_expr = where_expr
    movsxd  rax, ebx
    imul    rax, SIZEOF_TENSION
    lea     rcx, [g_tensions + rax]
    mov     eax, [rcx + TEN_MATCH_COUNT]
    dec     eax
    movsxd  rax, eax
    imul    rax, SIZEOF_MATCHCLAUSE
    mov     [rcx + TEN_MATCHES + rax + MC_WHERE_EXPR], rsi

    xor     eax, eax
.htmiw_done:
    add     rsp, 40
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; herb_tension_emit_set(tidx, entity_bind, property, value_expr) -> int
;
; RCX = tidx, RDX = entity_bind, R8 = property, R9 = value_expr
; Returns 0 on success, -1 on error.
; ============================================================
herb_tension_emit_set:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 32

    mov     rbx, rdx           ; RBX = entity_bind
    mov     rsi, r8            ; RSI = property
    mov     rdi, r9            ; RDI = value_expr

    ; Validate tidx
    test    ecx, ecx
    js      .htes_fail
    lea     rax, [g_tension_count]
    cmp     ecx, [rax]
    jge     .htes_fail

    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     r12, [g_tensions + rax]

    ; Check emit_count
    mov     eax, [r12 + TEN_EMIT_COUNT]
    cmp     eax, MAX_EMIT_CLAUSES
    jge     .htes_fail
    lea     ecx, [eax + 1]
    mov     [r12 + TEN_EMIT_COUNT], ecx

    ; ec = &t->emits[emit_count]
    movsxd  rcx, eax
    imul    rcx, SIZEOF_EMITCLAUSE
    lea     r12, [r12 + TEN_EMITS + rcx]  ; R12 = ec

    ; herb_memset(ec, 0, sizeof(EmitClause))
    mov     rcx, r12
    xor     edx, edx
    mov     r8, SIZEOF_EMITCLAUSE
    call    herb_memset

    ; ec->kind = EC_SET
    mov     dword [r12 + EC_KIND], EC_SET_V

    ; ec->set_entity_ref = intern(entity_bind)
    mov     rcx, rbx
    call    intern
    mov     [r12 + EC_SET_ENTITY_REF], eax

    ; ec->set_prop_id = intern(property)
    mov     rcx, rsi
    call    intern
    mov     [r12 + EC_SET_PROP_ID], eax

    ; ec->value_expr = value_expr
    mov     [r12 + EC_VALUE_EXPR], rdi

    ; Defaults = -1
    mov     dword [r12 + EC_TO_REF], -1
    mov     dword [r12 + EC_TO_SCOPE_BIND_ID], -1
    mov     dword [r12 + EC_SEND_CHANNEL_IDX], -1
    mov     dword [r12 + EC_RECV_CHANNEL_IDX], -1
    mov     dword [r12 + EC_RECV_TO_SCOPE_BIND_ID], -1
    mov     dword [r12 + EC_DUP_IN_SCOPE_BIND_ID], -1

    xor     eax, eax
    jmp     .htes_done

.htes_fail:
    mov     eax, -1
.htes_done:
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; herb_tension_emit_move(tidx, move_type, entity_bind, to_container) -> int
;
; RCX = tidx, RDX = move_type, R8 = entity_bind, R9 = to_container
; Returns 0 on success, -1 on error.
; ============================================================
herb_tension_emit_move:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 32

    mov     rbx, rdx           ; RBX = move_type
    mov     rsi, r8            ; RSI = entity_bind
    mov     rdi, r9            ; RDI = to_container

    ; Validate tidx
    test    ecx, ecx
    js      .htem_fail
    lea     rax, [g_tension_count]
    cmp     ecx, [rax]
    jge     .htem_fail

    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     r12, [g_tensions + rax]

    mov     eax, [r12 + TEN_EMIT_COUNT]
    cmp     eax, MAX_EMIT_CLAUSES
    jge     .htem_fail
    lea     ecx, [eax + 1]
    mov     [r12 + TEN_EMIT_COUNT], ecx

    movsxd  rcx, eax
    imul    rcx, SIZEOF_EMITCLAUSE
    lea     r12, [r12 + TEN_EMITS + rcx]  ; R12 = ec

    mov     rcx, r12
    xor     edx, edx
    mov     r8, SIZEOF_EMITCLAUSE
    call    herb_memset

    ; ec->kind = EC_MOVE
    mov     dword [r12 + EC_KIND], EC_MOVE_V

    ; ec->move_type_idx = graph_find_move_type_by_name(intern(move_type))
    mov     rcx, rbx
    call    intern
    mov     ecx, eax
    call    graph_find_move_type_by_name
    mov     [r12 + EC_MOVE_TYPE_IDX], eax

    ; ec->entity_ref = intern(entity_bind)
    mov     rcx, rsi
    call    intern
    mov     [r12 + EC_ENTITY_REF], eax

    ; ec->to_ref = graph_find_container_by_name(intern(to_container))
    mov     rcx, rdi
    call    intern
    mov     ecx, eax
    call    graph_find_container_by_name
    mov     [r12 + EC_TO_REF], eax

    ; Defaults = -1
    mov     dword [r12 + EC_TO_SCOPE_BIND_ID], -1
    mov     dword [r12 + EC_SEND_CHANNEL_IDX], -1
    mov     dword [r12 + EC_RECV_CHANNEL_IDX], -1
    mov     dword [r12 + EC_RECV_TO_SCOPE_BIND_ID], -1
    mov     dword [r12 + EC_DUP_IN_SCOPE_BIND_ID], -1

    xor     eax, eax
    jmp     .htem_done

.htem_fail:
    mov     eax, -1
.htem_done:
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; PHASE 4f: EXPRESSION BUILDERS
; ============================================================

; ============================================================
; herb_expr_int(int64_t val) -> void* (Expr*)
;
; RCX = val (int64_t)
; Allocates from expr pool, sets kind=EX_INT, int_val=val.
; Returns Expr* or NULL.
; ============================================================
herb_expr_int:
    push    rbp
    mov     rbp, rsp
    push    rbx
    sub     rsp, 40            ; shadow + align

    mov     rbx, rcx           ; RBX = val
    call    alloc_expr
    test    rax, rax
    jz      .hei_done
    mov     dword [rax + EX_KIND], EX_INT_T
    mov     [rax + EX_INT_VAL], rbx

.hei_done:
    add     rsp, 40
    pop     rbx
    pop     rbp
    ret

; ============================================================
; herb_expr_prop(const char* prop_name, const char* of_bind) -> void*
;
; RCX = prop_name, RDX = of_bind
; Allocates expr, sets kind=EX_PROP, interns both strings.
; ============================================================
herb_expr_prop:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    sub     rsp, 40

    mov     rbx, rcx           ; RBX = prop_name
    mov     rsi, rdx           ; RSI = of_bind
    call    alloc_expr
    test    rax, rax
    jz      .hep_done
    mov     rdi, rax           ; RDI = e pointer
    mov     dword [rdi + EX_KIND], EX_PROP_T

    ; intern(prop_name)
    mov     rcx, rbx
    call    intern
    mov     [rdi + EX_PROP_ID], eax

    ; intern(of_bind)
    mov     rcx, rsi
    call    intern
    mov     [rdi + EX_OF_ID], eax

    mov     rax, rdi           ; return e

.hep_done:
    add     rsp, 40
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; herb_expr_binary(const char* op, void* left, void* right) -> void*
;
; RCX = op, RDX = left, R8 = right
; Allocates expr, sets kind=EX_BINARY, interns op, stores left/right pointers.
; ============================================================
herb_expr_binary:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 32

    mov     rbx, rcx           ; RBX = op
    mov     rsi, rdx           ; RSI = left
    mov     rdi, r8            ; RDI = right
    call    alloc_expr
    test    rax, rax
    jz      .heb_done
    mov     r12, rax           ; R12 = e
    mov     dword [r12 + EX_KIND], EX_BINARY_T

    ; intern(op)
    mov     rcx, rbx
    call    intern
    mov     [r12 + EX_BINARY_OP_ID], eax
    mov     [r12 + EX_BINARY_LEFT], rsi
    mov     [r12 + EX_BINARY_RIGHT], rdi

    mov     rax, r12           ; return e

.heb_done:
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; PHASE 4i: ARENA QUERIES
; ============================================================

; ============================================================
; herb_arena_usage() -> herb_size_t
;
; Returns g_arena_ptr->offset (current arena usage in bytes).
; Returns 0 if g_arena_ptr is NULL.
; ============================================================
herb_arena_usage:
    lea     rax, [g_arena_ptr]
    mov     rax, [rax]         ; RAX = g_arena_ptr value
    test    rax, rax
    jz      .hau_zero
    mov     rax, [rax + ARENA_OFFSET]
    ret
.hau_zero:
    xor     eax, eax
    ret

; ============================================================
; herb_arena_total() -> herb_size_t
;
; Returns g_arena_ptr->size (total arena capacity in bytes).
; Returns 0 if g_arena_ptr is NULL.
; ============================================================
herb_arena_total:
    lea     rax, [g_arena_ptr]
    mov     rax, [rax]         ; RAX = g_arena_ptr value
    test    rax, rax
    jz      .hat_zero
    mov     rax, [rax + ARENA_SIZE]
    ret
.hat_zero:
    xor     eax, eax
    ret
