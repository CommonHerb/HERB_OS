; boot/herb_ham.asm — HERB Abstract Machine (HAM)
;
; Token-threaded bytecode interpreter for HERB tensions.
; Replaces the C runtime's hot path (herb_step) for compiled
; tension programs. Pre-sorted bytecode eliminates O(n²) sorting.
;
; Session 64 — Phase 3a: Core engine + 19 instruction handlers
; Session 65 — Phase 3b Part 1: +7 expression instructions (26 total)
;
; Register allocation (persistent across C calls via MS x64 ABI):
;   RBX = bytecode start pointer (for fixpoint loop reset)
;   RSI = bytecode PC (current instruction pointer)
;   RDI = expression stack pointer (grows upward from expr_stack)
;   R12 = binding register B0 (entity index)
;   R13 = binding register B1
;   R14 = binding register B2
;   R15 = changed flag (0 = no mutations this cycle)
;   RBP = stack frame base
;
; Dispatch: comparison chain (19 valid opcodes). Avoids 256-entry
; relocation table that crashes the PE linker.
;
; C bridge functions (from herb_runtime_freestanding.c):
;   ham_scan(container_idx, buf, max_count) -> count
;   ham_eprop(entity_idx, prop_id) -> int64_t
;   ham_ecnt(container_idx) -> count
;   ham_entity_loc(entity_idx) -> container_idx
;   ham_try_move(mt_idx, entity_idx, to_container_idx) -> success
;   ham_eset(entity_idx, prop_id, value) -> void
;
; Assembled with: nasm -f win64 herb_ham.asm -o herb_ham.o

[bits 64]
default rel

; C bridge function imports
extern ham_scan
extern ham_eprop
extern ham_ecnt
extern ham_entity_loc
extern ham_try_move
extern ham_eset

; Export entry point and debug counters
global ham_run
global ham_dbg_thdr
global ham_dbg_fail
global ham_dbg_tend
global ham_dbg_action
global ham_dbg_scan_nz
global ham_dbg_require
global ham_dbg_guard

; ============================================================
; BSS — Static data for HAM execution
; ============================================================

section .bss

expr_stack:      resq 16       ; 16-slot expression stack (128 bytes)
scan_buf:        resd 64       ; scan results: up to 64 entity indices (256 bytes)
scan_count:      resd 1        ; number of entities in scan buffer
action_buf:      resb 960      ; action buffer: 40 actions × 24 bytes each
action_count:    resd 1        ; number of buffered actions
bytecode_end_p:  resq 1        ; end pointer for bytecode
tension_end_p:   resq 1        ; end of current tension (for FAIL/GUARD skip)
where_pc:        resq 1        ; saved PC for WHERE loop restart
where_bind:      resd 1        ; which binding register WHERE uses
where_read_idx:  resd 1        ; current read position in WHERE iteration
where_write_idx: resd 1        ; current write position in WHERE iteration
where_orig_cnt:  resd 1        ; original scan_count before WHERE filtering
total_ops:       resd 1        ; total operations executed (returned to caller)
; Debug counters (read by C after ham_run returns)
ham_dbg_thdr:    resd 1        ; number of THDR entries
ham_dbg_fail:    resd 1        ; number of FAILs
ham_dbg_tend:    resd 1        ; number of TENDs with actions
ham_dbg_action:  resd 1        ; number of actions attempted
ham_dbg_scan_nz: resd 1        ; number of SCANs returning >0 entities
ham_dbg_require: resd 1        ; number of REQUIREs reached
ham_dbg_guard:   resd 1        ; number of GUARDs reached

; ============================================================
; TEXT — HAM engine code
; ============================================================

section .text

; ============================================================
; ham_dispatch — Comparison chain dispatch
;
; Entry: AL = opcode (already consumed from bytecode)
;        RSI points past the opcode byte
; Jumps to the appropriate handler.
; ============================================================

ham_dispatch:
    ; Control (most likely at tension boundaries)
    cmp  al, 0x40
    je   ham_op_thdr
    cmp  al, 0x41
    je   ham_op_tend
    cmp  al, 0x42
    je   ham_op_fail

    ; Expression stack (most frequent in bodies)
    cmp  al, 0x20
    je   ham_op_ipush
    cmp  al, 0x21
    je   ham_op_eprop
    cmp  al, 0x22
    je   ham_op_ecnt
    cmp  al, 0x24
    je   ham_op_add
    cmp  al, 0x25
    je   ham_op_sub
    cmp  al, 0x27
    je   ham_op_gt
    cmp  al, 0x28
    je   ham_op_lt
    cmp  al, 0x29
    je   ham_op_gte
    cmp  al, 0x2A
    je   ham_op_lte
    cmp  al, 0x2B
    je   ham_op_eq
    cmp  al, 0x2C
    je   ham_op_neq
    cmp  al, 0x2D
    je   ham_op_and
    cmp  al, 0x2F
    je   ham_op_not

    ; Scanning
    cmp  al, 0x01
    je   ham_op_scan
    cmp  al, 0x03
    je   ham_op_sel_first
    cmp  al, 0x04
    je   ham_op_sel_max

    ; Filtering
    cmp  al, 0x10
    je   ham_op_where
    cmp  al, 0x11
    je   ham_op_endwhere
    cmp  al, 0x12
    je   ham_op_guard
    cmp  al, 0x13
    je   ham_op_endguard
    cmp  al, 0x14
    je   ham_op_require

    ; Emit
    cmp  al, 0x30
    je   ham_op_emov
    cmp  al, 0x32
    je   ham_op_eset

    ; Unknown opcode — skip to tension end
    jmp  ham_invalid

; ============================================================
; DISPATCH TAIL MACRO — used at end of every handler
; Fetches next opcode and jumps to dispatch chain
; ============================================================

%macro DISPATCH 0
    cmp  rsi, [bytecode_end_p]
    jge  ham_run.done
    movzx eax, byte [rsi]
    inc  rsi
    jmp  ham_dispatch
%endmacro

; ============================================================
; ham_run(uint8_t* bytecode_ptr, int bytecode_len) -> int ops
;
; Entry point. Runs the fixpoint loop over all compiled tensions.
; MS x64 ABI: RCX = bytecode_ptr, EDX = bytecode_len
; Returns total operations executed in EAX.
; ============================================================

ham_run:
    ; Save all callee-saved registers
    push rbp
    mov  rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    ; Allocate shadow space (32 bytes) + alignment (8 bytes) = 40
    ; After 7 pushes + push rbp + return addr = 9 * 8 = 72 bytes
    ; 72 + 40 = 112, 112 % 16 = 0 → aligned
    sub  rsp, 40

    ; Set up persistent register allocation
    mov  rbx, rcx                   ; RBX = bytecode start
    mov  rsi, rcx                   ; RSI = PC (start at beginning)
    lea  rdi, [expr_stack]          ; RDI = expression stack base
    xor  r12d, r12d                 ; B0 = 0
    xor  r13d, r13d                 ; B1 = 0
    xor  r14d, r14d                 ; B2 = 0
    xor  r15d, r15d                 ; changed = 0

    ; Save bytecode bounds
    mov  [bytecode_end_p], rcx
    movsx rax, edx                  ; sign-extend len
    add  [bytecode_end_p], rax      ; bytecode_end = start + len

    ; Clear counters
    mov  dword [total_ops], 0
    mov  dword [action_count], 0
    mov  dword [scan_count], 0
    mov  dword [ham_dbg_thdr], 0
    mov  dword [ham_dbg_fail], 0
    mov  dword [ham_dbg_tend], 0
    mov  dword [ham_dbg_action], 0
    mov  dword [ham_dbg_scan_nz], 0
    mov  dword [ham_dbg_require], 0
    mov  dword [ham_dbg_guard], 0

    ; Begin dispatch: fetch first opcode
    cmp  rsi, [bytecode_end_p]
    jge  .done
    movzx eax, byte [rsi]
    inc  rsi
    jmp  ham_dispatch

.done:
    ; Return total_ops in EAX
    mov  eax, [total_ops]

    ; Restore
    add  rsp, 40
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rdi
    pop  rsi
    pop  rbx
    pop  rbp
    ret

; ============================================================
; ham_invalid — handler for invalid/unimplemented opcodes
; Safety: skip to tension_end if set, else stop
; ============================================================

ham_invalid:
    mov  rsi, [tension_end_p]
    cmp  rsi, [bytecode_end_p]
    jge  ham_run.done
    movzx eax, byte [rsi]
    inc  rsi
    jmp  ham_dispatch

; ============================================================
; CONTROL INSTRUCTIONS
; ============================================================

; THDR (0x40): Tension header
; Format: THDR pri(1) owner(2) run_ctnr(2) tension_len(2) = 7 bytes after opcode
; Sets up tension_end, resets expression stack and action buffer.
; For Phase 3a: only system tensions (owner == -1) are executed.
ham_op_thdr:
    inc  dword [ham_dbg_thdr]
    movzx eax, byte [rsi]          ; pri (1 byte) — not used in dispatch yet
    inc  rsi

    movzx eax, word [rsi]          ; owner (2 bytes, u16)
    add  rsi, 2

    ; Skip run_container (2 bytes)
    add  rsi, 2

    ; Read tension_len (2 bytes, u16)
    movzx ecx, word [rsi]
    add  rsi, 2

    ; Compute tension_end = tension_start + tension_len
    ; tension_start is the THDR opcode position = RSI - 8 (opcode + 7 operand bytes)
    mov  rdx, rsi
    sub  rdx, 8                     ; back to THDR opcode
    add  rdx, rcx                   ; + tension_len
    mov  [tension_end_p], rdx

    ; Check owner: 0xFFFF means system (-1). Skip non-system for Phase 3a.
    cmp  ax, 0xFFFF
    jne  ham_op_fail                ; skip non-system tensions

    ; Reset expression stack
    lea  rdi, [expr_stack]

    ; Reset action buffer
    mov  dword [action_count], 0

    DISPATCH

; TEND (0x41): Tension end — execute buffered actions, check fixpoint
ham_op_tend:
    ; Execute all buffered actions
    mov  ecx, [action_count]
    test ecx, ecx
    jz   .no_actions
    inc  dword [ham_dbg_tend]       ; count TENDs with actions

    ; Iterate action buffer
    lea  r8, [action_buf]
    xor  r9d, r9d                   ; action index

.action_loop:
    cmp  r9d, [action_count]
    jge  .actions_done

    ; Load action kind (offset 0, 4 bytes)
    mov  eax, [r8]
    cmp  eax, 0
    je   .do_move
    cmp  eax, 1
    je   .do_set
    jmp  .next_action

.do_move:
    ; Action MOVE: field1=mt_idx, field2=entity_idx, field3(lo32)=to_container
    ; Call ham_try_move(mt_idx, entity_idx, to_container_idx)
    ; Save volatile state
    inc  dword [ham_dbg_action]
    push r8
    push r9

    mov  ecx, [r8 + 4]             ; mt_idx
    mov  edx, [r8 + 8]             ; entity_idx
    mov  r8d, [r8 + 16]            ; to_container (from field3, low 32 bits)
    call ham_try_move

    pop  r9
    pop  r8

    ; If successful (EAX=1), set changed flag and count op
    test eax, eax
    jz   .next_action
    mov  r15d, 1
    inc  dword [total_ops]
    jmp  .next_action

.do_set:
    ; Action SET: field1=entity_idx, field2=prop_id, field3=value(i64)
    ; Call ham_eset(entity_idx, prop_id, value)
    inc  dword [ham_dbg_action]
    push r8
    push r9

    mov  ecx, [r8 + 4]             ; entity_idx
    mov  edx, [r8 + 8]             ; prop_id
    mov  r8, [r8 + 16]             ; value (i64)
    call ham_eset

    pop  r9
    pop  r8

    ; SET always succeeds — mark changed and count
    mov  r15d, 1
    inc  dword [total_ops]
    jmp  .next_action

.next_action:
    add  r8, 24                     ; advance to next action entry
    inc  r9d
    jmp  .action_loop

.actions_done:
    mov  dword [action_count], 0

.no_actions:
    ; Fixpoint check: are we at the end of all bytecode?
    cmp  rsi, [bytecode_end_p]
    jl   .not_end

    ; At end of bytecode — check if anything changed
    test r15d, r15d
    jz   ham_run.done               ; no changes → equilibrium, return

    ; Changes occurred — reset for another fixpoint cycle
    mov  rsi, rbx                   ; PC = bytecode start
    xor  r15d, r15d                 ; clear changed flag
    ; Fall through to dispatch

.not_end:
    DISPATCH

; FAIL (0x42): Tension failed — clear actions, skip to tension_end
ham_op_fail:
    inc  dword [ham_dbg_fail]
    mov  dword [action_count], 0
    mov  rsi, [tension_end_p]

    ; Check if we've passed the end
    cmp  rsi, [bytecode_end_p]
    jge  ham_op_tend.no_actions      ; treat as TEND at end (for fixpoint)

    DISPATCH

; ============================================================
; SCANNING INSTRUCTIONS
; ============================================================

; SCAN (0x01): Scan container for entities
; Format: SCAN ctnr(2) = 2 bytes after opcode
ham_op_scan:
    movzx ecx, word [rsi]          ; container_idx
    add  rsi, 2

    ; Call ham_scan(container_idx, scan_buf, 64)
    ; RCX = container_idx (already set)
    lea  rdx, [scan_buf]           ; buf
    mov  r8d, 64                    ; max_count
    call ham_scan

    ; EAX = count
    mov  [scan_count], eax
    test eax, eax
    jz   .scan_zero
    inc  dword [ham_dbg_scan_nz]
.scan_zero:
    DISPATCH

; SEL_FIRST (0x03): Select first entity from scan buffer
; Format: SEL_FIRST bind(1)
ham_op_sel_first:
    movzx eax, byte [rsi]          ; bind register index
    inc  rsi

    cmp  dword [scan_count], 0
    je   .sel_first_empty

    ; Load first entity from scan_buf
    mov  ecx, [scan_buf]

    ; Store in binding register
    cmp  al, 0
    je   .sf_b0
    cmp  al, 1
    je   .sf_b1
    mov  r14d, ecx                  ; B2
    jmp  .sf_done
.sf_b0:
    mov  r12d, ecx
    jmp  .sf_done
.sf_b1:
    mov  r13d, ecx
.sf_done:
.sel_first_empty:
    DISPATCH

; SEL_MAX (0x04): Select entity with maximum property value
; Format: SEL_MAX bind(1) prop(2) = 3 bytes after opcode
; Note: R10/R11 are volatile in MS x64 ABI, so we save bind_idx
; and prop_id on the stack across ham_eprop calls.
ham_op_sel_max:
    movzx r10d, byte [rsi]         ; bind register index
    inc  rsi
    movzx r11d, word [rsi]         ; prop_id
    add  rsi, 2

    ; Iterate scan_buf to find entity with max prop value
    mov  ecx, [scan_count]
    test ecx, ecx
    jz   .sm_done                   ; no entities

    ; Stack layout (bottom to top):
    ;   [rsp+32] = saved RSI (PC)
    ;   [rsp+24] = saved bind_idx (from r10)
    ;   [rsp+16] = saved prop_id (from r11)
    ;   [rsp+8]  = best_entity
    ;   [rsp]    = best_value
    push rsi                        ; save PC
    push r10                        ; save bind_idx (volatile across calls)
    push r11                        ; save prop_id (volatile across calls)

    ; best_entity = scan_buf[0]
    mov  eax, [scan_buf]
    push rax                        ; [rsp] = best_entity

    ; Get initial best value: ham_eprop(scan_buf[0], prop_id)
    mov  ecx, eax                   ; entity_idx
    mov  edx, r11d                  ; prop_id (still valid, haven't called yet)
    call ham_eprop
    push rax                        ; [rsp] = best_value, [rsp+8] = best_entity

    ; Loop from index 1
    mov  dword [where_read_idx], 1  ; reuse where_read_idx as temp loop counter

.sm_loop:
    mov  eax, [where_read_idx]
    cmp  eax, [scan_count]
    jge  .sm_found

    ; Get entity at scan_buf[i]
    lea  rcx, [scan_buf]
    mov  ecx, [rcx + rax*4]        ; entity_idx = scan_buf[i]
    push rcx                        ; save entity_idx

    mov  edx, [rsp + 24]           ; prop_id from saved stack slot
                                    ; (rsp+0=eid, +8=best_val, +16=best_ent,
                                    ;  +24=prop_id, +32=bind_idx, +40=PC)
    call ham_eprop                  ; RAX = prop value

    pop  rcx                        ; restore entity_idx

    ; Compare with best_value
    cmp  rax, [rsp]                 ; compare with best_value at [rsp]
    jle  .sm_not_better

    ; New best
    mov  [rsp], rax                 ; update best_value
    mov  [rsp + 8], rcx             ; update best_entity (use 64-bit write)

.sm_not_better:
    inc  dword [where_read_idx]
    jmp  .sm_loop

.sm_found:
    pop  rax                        ; discard best_value
    pop  rax                        ; best_entity (result)
    pop  r11                        ; restore prop_id (discard)
    pop  r10                        ; restore bind_idx
    pop  rsi                        ; restore PC

    ; Store in binding register
    cmp  r10b, 0
    je   .sm_b0
    cmp  r10b, 1
    je   .sm_b1
    mov  r14d, eax
    jmp  .sm_done
.sm_b0:
    mov  r12d, eax
    jmp  .sm_done
.sm_b1:
    mov  r13d, eax

.sm_done:
    DISPATCH

; ============================================================
; FILTERING INSTRUCTIONS
; ============================================================

; REQUIRE (0x14): If scan_count == 0, FAIL
ham_op_require:
    inc  dword [ham_dbg_require]
    cmp  dword [scan_count], 0
    je   ham_op_fail
    DISPATCH

; WHERE (0x10): Begin filter loop over scan buffer
; Format: WHERE bind(1)
; Saves PC for loop restart. Sets B[bind] to first entity.
ham_op_where:
    movzx eax, byte [rsi]          ; bind register index
    inc  rsi

    mov  [where_bind], eax
    mov  [where_pc], rsi            ; save PC (start of filter body)

    ; Save iteration state
    mov  ecx, [scan_count]
    mov  [where_orig_cnt], ecx
    mov  dword [where_read_idx], 0
    mov  dword [where_write_idx], 0

    ; If no entities, skip to ENDWHERE (we'll handle in ENDWHERE)
    test ecx, ecx
    jz   .where_empty

    ; Set B[bind] = scan_buf[0]
    mov  ecx, [scan_buf]
    mov  eax, [where_bind]
    cmp  al, 0
    je   .wb0
    cmp  al, 1
    je   .wb1
    mov  r14d, ecx
    jmp  .wdone
.wb0:
    mov  r12d, ecx
    jmp  .wdone
.wb1:
    mov  r13d, ecx
.wdone:
    ; Reset expression stack for this iteration
    lea  rdi, [expr_stack]
    DISPATCH

.where_empty:
    ; Set scan_count to 0, skip to ENDWHERE by scanning for opcode 0x11
    ; But we can just set orig_cnt=0 and fall through — ENDWHERE will see
    ; read_idx >= orig_cnt immediately
    DISPATCH

; ENDWHERE (0x11): End of WHERE filter body
; Pops expression stack result. If truthy, keeps entity. Loops or finishes.
ham_op_endwhere:
    ; Pop expression result
    sub  rdi, 8
    mov  rax, [rdi]                 ; filter result

    ; If truthy, keep this entity
    test rax, rax
    jz   .ew_skip

    ; Keep: scan_buf[write_idx] = scan_buf[read_idx]
    mov  ecx, [where_read_idx]
    lea  r8, [scan_buf]
    mov  ecx, [r8 + rcx*4]         ; entity at read_idx
    mov  edx, [where_write_idx]
    mov  [r8 + rdx*4], ecx         ; store at write_idx
    inc  dword [where_write_idx]

.ew_skip:
    ; Advance read index
    inc  dword [where_read_idx]

    ; More entities?
    mov  eax, [where_read_idx]
    cmp  eax, [where_orig_cnt]
    jge  .ew_done

    ; Set B[bind] = scan_buf[read_idx]
    lea  r8, [scan_buf]
    mov  ecx, [r8 + rax*4]
    mov  eax, [where_bind]
    cmp  al, 0
    je   .ewb0
    cmp  al, 1
    je   .ewb1
    mov  r14d, ecx
    jmp  .ew_restart
.ewb0:
    mov  r12d, ecx
    jmp  .ew_restart
.ewb1:
    mov  r13d, ecx

.ew_restart:
    ; Reset expression stack and jump back to WHERE body
    lea  rdi, [expr_stack]
    mov  rsi, [where_pc]
    DISPATCH

.ew_done:
    ; Update scan_count with number that passed the filter
    mov  eax, [where_write_idx]
    mov  [scan_count], eax

    DISPATCH

; GUARD (0x12): Pop expression stack. If falsy, jump to tension_end.
ham_op_guard:
    inc  dword [ham_dbg_guard]
    sub  rdi, 8
    mov  rax, [rdi]
    test rax, rax
    jz   ham_op_fail                ; falsy → FAIL this tension
    DISPATCH

; ENDGUARD (0x13): No-op, just dispatch next
ham_op_endguard:
    DISPATCH

; ============================================================
; EXPRESSION STACK INSTRUCTIONS
; ============================================================

; IPUSH (0x20): Push immediate 32-bit signed integer
; Format: IPUSH val(4)
ham_op_ipush:
    movsxd rax, dword [rsi]        ; read i32, sign-extend to i64
    add  rsi, 4
    mov  [rdi], rax                 ; push onto expression stack
    add  rdi, 8
    DISPATCH

; EPROP (0x21): Push entity property value
; Format: EPROP bind(1) prop(2)
ham_op_eprop:
    movzx eax, byte [rsi]          ; bind register index
    inc  rsi
    movzx edx, word [rsi]          ; prop_id
    add  rsi, 2

    ; Get entity index from binding register
    cmp  al, 0
    je   .ep_b0
    cmp  al, 1
    je   .ep_b1
    mov  ecx, r14d
    jmp  .ep_call
.ep_b0:
    mov  ecx, r12d
    jmp  .ep_call
.ep_b1:
    mov  ecx, r13d

.ep_call:
    ; Call ham_eprop(entity_idx, prop_id)
    ; RCX = entity_idx (set above), RDX = prop_id (set above)
    call ham_eprop

    ; Push result onto expression stack
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; ECNT (0x22): Push entity count of container
; Format: ECNT ctnr(2)
ham_op_ecnt:
    movzx ecx, word [rsi]          ; container_idx
    add  rsi, 2

    call ham_ecnt

    ; Push result
    movsxd rax, eax                 ; sign-extend count to i64
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; EQ (0x2B): Pop two, push (second == top ? 1 : 0)
ham_op_eq:
    sub  rdi, 8
    mov  rcx, [rdi]                 ; top
    sub  rdi, 8
    mov  rax, [rdi]                 ; second
    cmp  rax, rcx
    je   .eq_true
    xor  eax, eax
    jmp  .eq_push
.eq_true:
    mov  eax, 1
.eq_push:
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; GT (0x27): Pop two, push (second > top ? 1 : 0)
ham_op_gt:
    sub  rdi, 8
    mov  rcx, [rdi]                 ; top
    sub  rdi, 8
    mov  rax, [rdi]                 ; second
    cmp  rax, rcx
    jg   .gt_true
    xor  eax, eax
    jmp  .gt_push
.gt_true:
    mov  eax, 1
.gt_push:
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; SUB (0x25): Pop two, push (second - top)
ham_op_sub:
    sub  rdi, 8
    mov  rcx, [rdi]                 ; top
    sub  rdi, 8
    mov  rax, [rdi]                 ; second
    sub  rax, rcx                   ; second - top
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; ADD (0x24): Pop two, push (second + top)
ham_op_add:
    sub  rdi, 8
    mov  rcx, [rdi]                 ; top
    sub  rdi, 8
    mov  rax, [rdi]                 ; second
    add  rax, rcx                   ; second + top
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; LT (0x28): Pop two, push (second < top ? 1 : 0)
ham_op_lt:
    sub  rdi, 8
    mov  rcx, [rdi]                 ; top
    sub  rdi, 8
    mov  rax, [rdi]                 ; second
    cmp  rax, rcx
    jl   .lt_true
    xor  eax, eax
    jmp  .lt_push
.lt_true:
    mov  eax, 1
.lt_push:
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; GTE (0x29): Pop two, push (second >= top ? 1 : 0)
ham_op_gte:
    sub  rdi, 8
    mov  rcx, [rdi]                 ; top
    sub  rdi, 8
    mov  rax, [rdi]                 ; second
    cmp  rax, rcx
    jge  .gte_true
    xor  eax, eax
    jmp  .gte_push
.gte_true:
    mov  eax, 1
.gte_push:
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; LTE (0x2A): Pop two, push (second <= top ? 1 : 0)
ham_op_lte:
    sub  rdi, 8
    mov  rcx, [rdi]                 ; top
    sub  rdi, 8
    mov  rax, [rdi]                 ; second
    cmp  rax, rcx
    jle  .lte_true
    xor  eax, eax
    jmp  .lte_push
.lte_true:
    mov  eax, 1
.lte_push:
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; NEQ (0x2C): Pop two, push (second != top ? 1 : 0)
ham_op_neq:
    sub  rdi, 8
    mov  rcx, [rdi]                 ; top
    sub  rdi, 8
    mov  rax, [rdi]                 ; second
    cmp  rax, rcx
    jne  .neq_true
    xor  eax, eax
    jmp  .neq_push
.neq_true:
    mov  eax, 1
.neq_push:
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; AND (0x2D): Pop two, push (both truthy ? 1 : 0)
ham_op_and:
    sub  rdi, 8
    mov  rcx, [rdi]                 ; top
    sub  rdi, 8
    mov  rax, [rdi]                 ; second
    test rax, rax
    jz   .and_false
    test rcx, rcx
    jz   .and_false
    mov  eax, 1
    jmp  .and_push
.and_false:
    xor  eax, eax
.and_push:
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; NOT (0x2F): Pop one, push (!val ? 1 : 0)
ham_op_not:
    sub  rdi, 8
    mov  rax, [rdi]                 ; val
    test rax, rax
    setz al
    movzx eax, al                   ; EAX = 0 or 1
    mov  [rdi], rax
    add  rdi, 8
    DISPATCH

; ============================================================
; EMIT INSTRUCTIONS
; ============================================================

; EMOV (0x30): Buffer a MOVE action
; Format: EMOV mt(2) bind(1) to(2) = 5 bytes after opcode
ham_op_emov:
    movzx r10d, word [rsi]         ; mt_idx
    add  rsi, 2
    movzx eax, byte [rsi]          ; bind register index
    inc  rsi
    movzx r11d, word [rsi]         ; to_container_idx
    add  rsi, 2

    ; Get entity index from binding register
    cmp  al, 0
    je   .emov_b0
    cmp  al, 1
    je   .emov_b1
    mov  ecx, r14d
    jmp  .emov_store
.emov_b0:
    mov  ecx, r12d
    jmp  .emov_store
.emov_b1:
    mov  ecx, r13d

.emov_store:
    ; Append to action buffer
    mov  eax, [action_count]
    cmp  eax, 40                    ; max actions
    jge  .emov_skip

    ; Calculate action entry address: action_buf + index * 24
    imul eax, 24
    lea  r8, [action_buf]
    add  r8, rax

    mov  dword [r8], 0              ; kind = MOVE
    mov  [r8 + 4], r10d             ; mt_idx
    mov  [r8 + 8], ecx              ; entity_idx
    mov  dword [r8 + 12], 0         ; padding
    movsxd rax, r11d                ; to_container sign-extended
    mov  [r8 + 16], rax             ; to_container_idx in field3

    inc  dword [action_count]

.emov_skip:
    DISPATCH

; ESET (0x32): Buffer a SET action
; Format: ESET bind(1) prop(2) = 3 bytes after opcode
; Pops value from expression stack.
ham_op_eset:
    movzx eax, byte [rsi]          ; bind register index
    inc  rsi
    movzx r10d, word [rsi]         ; prop_id
    add  rsi, 2

    ; Get entity index from binding register
    cmp  al, 0
    je   .eset_b0
    cmp  al, 1
    je   .eset_b1
    mov  ecx, r14d
    jmp  .eset_pop
.eset_b0:
    mov  ecx, r12d
    jmp  .eset_pop
.eset_b1:
    mov  ecx, r13d

.eset_pop:
    ; Pop value from expression stack
    sub  rdi, 8
    mov  r11, [rdi]                 ; value (i64)

    ; Append to action buffer
    mov  eax, [action_count]
    cmp  eax, 40
    jge  .eset_skip

    imul eax, 24
    lea  r8, [action_buf]
    add  r8, rax

    mov  dword [r8], 1              ; kind = SET
    mov  [r8 + 4], ecx              ; entity_idx
    mov  [r8 + 8], r10d             ; prop_id
    mov  dword [r8 + 12], 0         ; padding
    mov  [r8 + 16], r11             ; value (i64)

    inc  dword [action_count]

.eset_skip:
    DISPATCH
