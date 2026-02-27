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

; External C functions we call
extern herb_strcmp
extern herb_strncpy
extern herb_error
extern herb_snprintf

; External C data we access
extern g_strings        ; char[2048][128]
extern g_string_count   ; int
extern g_graph          ; Graph (720568 bytes)

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
    ; Compute container base: &g_graph.containers[ci]
    ; = &g_graph + GRAPH_CONTAINERS + ci * SIZEOF_CONTAINER
    movsxd  rax, ecx
    imul    rax, SIZEOF_CONTAINER
    lea     r9, [g_graph + GRAPH_CONTAINERS]
    add     r9, rax         ; R9 = &container

    ; Check entity_count < MAX_ENTITY_PER_CONTAINER
    mov     eax, [r9 + CNT_ENTITY_COUNT]
    cmp     eax, MAX_ENTITY_PER_CONTAINER
    jge     .ca_full

    ; entities[entity_count] = ei
    mov     [r9 + CNT_ENTITIES + rax*4], edx

    ; entity_count++
    inc     eax
    mov     [r9 + CNT_ENTITY_COUNT], eax

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
    ; Compute container base
    movsxd  rax, ecx
    imul    rax, SIZEOF_CONTAINER
    lea     r9, [g_graph + GRAPH_CONTAINERS]
    add     r9, rax         ; R9 = &container

    ; Load entity_count
    mov     r10d, [r9 + CNT_ENTITY_COUNT]
    xor     r11d, r11d      ; R11 = loop counter

.cr_loop:
    cmp     r11d, r10d
    jge     .cr_not_found

    ; Compare entities[i] with ei
    mov     eax, [r9 + CNT_ENTITIES + r11*4]
    cmp     eax, edx
    je      .cr_found

    inc     r11d
    jmp     .cr_loop

.cr_found:
    ; Swap with last: entities[i] = entities[--entity_count]
    dec     r10d
    mov     eax, [r9 + CNT_ENTITIES + r10*4]  ; last element
    mov     [r9 + CNT_ENTITIES + r11*4], eax   ; overwrite found slot
    mov     [r9 + CNT_ENTITY_COUNT], r10d      ; store decremented count

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
    cmp     dword [rcx + CNT_ENTITY_COUNT], 0
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
    cmp     dword [rcx + CNT_ENTITY_COUNT], 0
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
    cmp     dword [rcx + CNT_ENTITY_COUNT], 0
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

    ; return containers[container_idx].entity_count
    movsxd  rax, ecx
    imul    rax, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    mov     eax, [rcx + rax + CNT_ENTITY_COUNT]
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

    ; Compute container base
    movsxd  rax, ecx
    imul    rax, SIZEOF_CONTAINER
    lea     r9, [g_graph + GRAPH_CONTAINERS]
    add     r9, rax             ; R9 = &containers[container_idx]

    ; n = min(entity_count, max_count)
    mov     r10d, [r9 + CNT_ENTITY_COUNT]
    cmp     r10d, r8d
    cmovg   r10d, r8d           ; R10D = min(entity_count, max_count)

    ; Copy loop: buf[i] = entities[i] for i in 0..n-1
    xor     ecx, ecx            ; ECX = loop counter
.hscan_loop:
    cmp     ecx, r10d
    jge     .hscan_done
    mov     eax, [r9 + CNT_ENTITIES + rcx*4]
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

    ; return containers[ci].entity_count
    movsxd  rdx, eax
    imul    rdx, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    mov     eax, [rcx + rdx + CNT_ENTITY_COUNT]

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

    ; bounds check: idx < 0 || idx >= containers[ci].entity_count
    test    esi, esi
    js      .hce_fail
    movsxd  rdx, eax
    imul    rdx, SIZEOF_CONTAINER
    lea     rcx, [g_graph + GRAPH_CONTAINERS]
    add     rcx, rdx               ; RCX = &containers[ci]
    cmp     esi, [rcx + CNT_ENTITY_COUNT]
    jge     .hce_fail

    ; return containers[ci].entities[idx]
    movsxd  rax, esi
    mov     eax, [rcx + CNT_ENTITIES + rax*4]
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
    lea     rax, [g_graph + GRAPH_TENSION_COUNT]
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
    lea     rax, [g_graph + GRAPH_TENSION_COUNT]
    cmp     ecx, [rax]
    jge     .htn_bad

    ; return str_of(tensions[idx].name_id)
    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     rdx, [g_graph + GRAPH_TENSIONS]
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
    lea     rax, [g_graph + GRAPH_TENSION_COUNT]
    cmp     ecx, [rax]
    jge     .htp_zero

    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     rdx, [g_graph + GRAPH_TENSIONS]
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
    lea     rax, [g_graph + GRAPH_TENSION_COUNT]
    cmp     ecx, [rax]
    jge     .hte_zero

    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     rdx, [g_graph + GRAPH_TENSIONS]
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
    lea     rax, [g_graph + GRAPH_TENSION_COUNT]
    cmp     ecx, [rax]
    jge     .htse_done

    ; tensions[idx].enabled = enabled ? 1 : 0
    test    edx, edx
    setnz   dl                     ; DL = (enabled != 0) ? 1 : 0
    movzx   edx, dl

    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     rcx, [g_graph + GRAPH_TENSIONS]
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
    lea     rax, [g_graph + GRAPH_TENSION_COUNT]
    cmp     ecx, [rax]
    jge     .hto_bad

    movsxd  rax, ecx
    imul    rax, SIZEOF_TENSION
    lea     rdx, [g_graph + GRAPH_TENSIONS]
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
.hspi_done:
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
    ; c->entity_count = 0
    mov     dword [rcx + CNT_ENTITY_COUNT], 0
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
