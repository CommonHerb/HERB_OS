; boot/herb_graph.asm — HERB Graph Primitives in Assembly
;
; Phase 4b, Part 1 (Session 70): 6 core graph functions ported from C to x86-64:
;   intern, str_of, entity_get_prop_raw, entity_set_prop, container_add, container_remove
;
; Phase 4b, Part 2 (Session 71): 5 graph functions ported + 1 deferred:
;   graph_find_container_by_name, graph_find_entity_by_name, get_scoped_container,
;   do_channel_send, do_channel_receive
;   try_move: written but NOT linked (Discovery 48 — GCC tail-call interaction)
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
; global try_move          ; DEFERRED — Discovery 48 (GCC tail-call interaction)
global do_channel_send
global do_channel_receive

section .rdata
    str_question:   db "?", 0
    str_table_full: db "string table full", 0

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
