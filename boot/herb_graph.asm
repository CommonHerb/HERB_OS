; boot/herb_graph.asm — HERB Graph Primitives in Assembly
;
; These are the lowest-level functions everything else depends on:
;   intern, str_of, entity_get_prop, entity_set_prop, container_add, container_remove
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

; Export our functions
global intern
global str_of
global entity_get_prop_raw
global entity_set_prop
global container_add
global container_remove

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
; ABI issue with 16-byte struct returns.
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
