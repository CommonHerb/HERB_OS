; boot/herb_ham.asm — HERB Abstract Machine (HAM)
;
; Token-threaded bytecode interpreter for HERB tensions.
; Replaces the C runtime's hot path (herb_step) for compiled
; tension programs. Pre-sorted bytecode eliminates O(n²) sorting.
;
; Session 64 — Phase 3a: Core engine + 19 instruction handlers
; Session 65 — Phase 3b Part 1: +7 expression instructions (26 total)
; Session 66 — Phase 3b Part 2: +6 instructions, 41/41 system tensions
; Session 67 — Phase 3c: THDR owner scheduling, all tensions on HAM
;
; Register allocation (persistent across C calls via MS x64 ABI):
;   RBX = bytecode start pointer (for fixpoint loop reset)
;   RSI = bytecode PC (current instruction pointer)
;   RDI = expression stack pointer (grows upward from expr_stack)
;   R12 = binding register B0 (entity index)
;   R13 = binding register B1
;   R14 = binding register B2
;   R15 = binding register B3
;   RBP = stack frame base
;   [changed_flag] = fixpoint changed flag (BSS, was R15 before Session 66)
;
; Dispatch: comparison chain. Avoids 256-entry relocation table
; that crashes the PE linker.
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
extern ham_resolve_scope
extern ham_try_channel_send
extern ham_try_channel_recv

; Export entry point and debug counters
global ham_run
global ham_dbg_thdr
global ham_dbg_fail
global ham_dbg_tend
global ham_dbg_action
global ham_dbg_scan_nz
global ham_dbg_require
global ham_dbg_guard
global ham_dbg_skip

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
changed_flag:    resd 1        ; fixpoint changed flag (was R15, freed for B3)
fixpoint_iters:  resd 1        ; safety: count fixpoint iterations
each_mode:       resd 1        ; 0 = normal, 1 = in each-mode iteration
each_start:      resq 1        ; PC to jump back to after each iteration
each_buf:        resd 64       ; copy of scan_buf at SEL_EACH time
each_total:      resd 1        ; total entities in each_buf
each_idx:        resd 1        ; current iteration index
each_bind:       resd 1        ; which binding register (0-3) to update
thdr_owner:      resd 1        ; saved owner entity index from THDR (Phase 3c)
thdr_run_ctnr:   resd 1        ; saved run_container from THDR (Phase 3c)
; Debug counters (read by C after ham_run returns)
ham_dbg_thdr:    resd 1        ; number of THDR entries
ham_dbg_fail:    resd 1        ; number of FAILs
ham_dbg_tend:    resd 1        ; number of TENDs with actions
ham_dbg_action:  resd 1        ; number of actions attempted
ham_dbg_scan_nz: resd 1        ; number of SCANs returning >0 entities
ham_dbg_require: resd 1        ; number of REQUIREs reached
ham_dbg_guard:   resd 1        ; number of GUARDs reached
ham_dbg_skip:    resd 1        ; number of THDR owner-check skips (Phase 3c)

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
    cmp  al, 0x02
    je   ham_op_scan_scoped
    cmp  al, 0x03
    je   ham_op_sel_first
    cmp  al, 0x04
    je   ham_op_sel_max
    cmp  al, 0x05
    je   ham_op_sel_min
    cmp  al, 0x06
    je   ham_op_sel_each

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
    cmp  al, 0x31
    je   ham_op_emov_s
    cmp  al, 0x32
    je   ham_op_eset
    cmp  al, 0x33
    je   ham_op_esend
    cmp  al, 0x35
    je   ham_op_erecv_s

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
    xor  r15d, r15d                 ; B3 = 0
    mov  dword [changed_flag], 0    ; changed = 0
    mov  dword [each_mode], 0      ; not in each-mode
    mov  dword [fixpoint_iters], 0 ; safety counter

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
    mov  dword [ham_dbg_skip], 0

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
; THDR (0x40): Tension header
; Format: THDR pri(1) owner(2) run_ctnr(2) tension_len(2) = 7 bytes after opcode
; Phase 3c: owner scheduling — system/daemon/process three-way check
ham_op_thdr:
    inc  dword [ham_dbg_thdr]
    movzx eax, byte [rsi]          ; pri (1 byte)
    inc  rsi

    movzx eax, word [rsi]          ; owner (2 bytes, u16)
    add  rsi, 2
    mov  [thdr_owner], eax          ; save to BSS

    movzx eax, word [rsi]          ; run_container (2 bytes, u16)
    add  rsi, 2
    mov  [thdr_run_ctnr], eax       ; save to BSS

    movzx ecx, word [rsi]          ; tension_len (2 bytes)
    add  rsi, 2

    ; Compute tension_end = THDR_opcode_pos + tension_len
    mov  rdx, rsi
    sub  rdx, 8                     ; back to THDR opcode
    add  rdx, rcx                   ; + tension_len
    mov  [tension_end_p], rdx

    ; === Owner scheduling decision ===
    cmp  word [thdr_owner], 0xFFFF
    je   .thdr_proceed              ; system tension (owner == -1) → always run

    ; Owned tension: check run_container
    cmp  word [thdr_run_ctnr], 0xFFFF
    je   .thdr_proceed              ; daemon (run_container == -1) → always run

    ; Process tension: verify owner is in run_container
    push rsi                        ; save PC (volatile across call)
    movzx ecx, word [thdr_owner]    ; arg1: entity_idx = owner
    call ham_entity_loc              ; returns container_idx in EAX
    pop  rsi                        ; restore PC
    cmp  eax, [thdr_run_ctnr]
    jne  .thdr_skip                  ; not in run container → skip
    jmp  .thdr_proceed

.thdr_skip:
    inc  dword [ham_dbg_skip]
    jmp  ham_op_fail                 ; skip this tension

.thdr_proceed:
    ; Reset expression stack
    lea  rdi, [expr_stack]

    ; Reset action buffer and each-mode
    mov  dword [action_count], 0
    mov  dword [each_mode], 0

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
    cmp  eax, 2
    je   .do_send
    cmp  eax, 3
    je   .do_recv
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
    mov  dword [changed_flag], 1
    inc  dword [total_ops]
    jmp  .next_action

.do_set:
    ; Action SET: field1=entity_idx, field2=prop_id, field3=value(i64)
    ; Call ham_eset(entity_idx, prop_id, value) -> returns 1 if changed
    inc  dword [ham_dbg_action]
    push r8
    push r9

    mov  ecx, [r8 + 4]             ; entity_idx
    mov  edx, [r8 + 8]             ; prop_id
    mov  r8, [r8 + 16]             ; value (i64)
    call ham_eset

    pop  r9
    pop  r8

    ; Only mark changed if value actually changed (EAX=1)
    test eax, eax
    jz   .next_action
    mov  dword [changed_flag], 1
    inc  dword [total_ops]
    jmp  .next_action

.do_send:
    ; Action SEND: field1=channel_idx, field2=entity_idx
    ; Call ham_try_channel_send(channel_idx, entity_idx)
    inc  dword [ham_dbg_action]
    push r8
    push r9

    mov  ecx, [r8 + 4]             ; channel_idx
    mov  edx, [r8 + 8]             ; entity_idx
    call ham_try_channel_send

    pop  r9
    pop  r8

    ; If successful (EAX=1), set changed flag and count op
    test eax, eax
    jz   .next_action
    mov  dword [changed_flag], 1
    inc  dword [total_ops]
    jmp  .next_action

.do_recv:
    ; Action RECV: field1=channel_idx, field2=entity_idx, field3=to_container
    ; Call ham_try_channel_recv(channel_idx, entity_idx, to_container_idx)
    inc  dword [ham_dbg_action]
    push r8
    push r9

    mov  ecx, [r8 + 4]             ; channel_idx
    mov  edx, [r8 + 8]             ; entity_idx
    mov  r8d, [r8 + 16]            ; to_container_idx (from field3, low 32 bits)
    call ham_try_channel_recv

    pop  r9
    pop  r8

    ; If successful (EAX=1), set changed flag and count op
    test eax, eax
    jz   .next_action
    mov  dword [changed_flag], 1
    inc  dword [total_ops]
    jmp  .next_action

.next_action:
    add  r8, 24                     ; advance to next action entry
    inc  r9d
    jmp  .action_loop

.actions_done:
    mov  dword [action_count], 0

    ; Check each-mode: if iterating, advance to next entity
    cmp  dword [each_mode], 0
    je   .no_actions

    ; Advance to next entity in each_buf
    inc  dword [each_idx]
    mov  ecx, [each_idx]
    cmp  ecx, [each_total]
    jge  .each_done

    ; Set B[each_bind] = each_buf[each_idx]
    lea  rdx, [each_buf]
    mov  edx, [rdx + rcx*4]        ; entity_idx = each_buf[each_idx]
    mov  eax, [each_bind]
    cmp  al, 0
    je   .each_sb0
    cmp  al, 1
    je   .each_sb1
    cmp  al, 2
    je   .each_sb2
    mov  r15d, edx                  ; B3
    jmp  .each_continue
.each_sb0:
    mov  r12d, edx
    jmp  .each_continue
.each_sb1:
    mov  r13d, edx
    jmp  .each_continue
.each_sb2:
    mov  r14d, edx

.each_continue:
    ; Reset expression stack for next iteration
    lea  rdi, [expr_stack]
    ; Jump back to each_start (after SEL_EACH, before emit clauses)
    mov  rsi, [each_start]
    DISPATCH

.each_done:
    mov  dword [each_mode], 0       ; exit each-mode

.no_actions:
    ; Fixpoint check: are we at the end of all bytecode?
    cmp  rsi, [bytecode_end_p]
    jl   .not_end

    ; At end of bytecode — check if anything changed
    cmp  dword [changed_flag], 0
    je   ham_run.done               ; no changes → equilibrium, return

    ; Changes occurred — reset for another fixpoint cycle
    inc  dword [fixpoint_iters]
    cmp  dword [fixpoint_iters], 100
    jge  ham_run.done               ; safety: max 100 fixpoint iterations
    mov  rsi, rbx                   ; PC = bytecode start
    mov  dword [changed_flag], 0    ; clear changed flag
    ; Fall through to dispatch

.not_end:
    DISPATCH

; FAIL (0x42): Tension failed — clear actions, skip to tension_end
ham_op_fail:
    inc  dword [ham_dbg_fail]
    mov  dword [action_count], 0
    mov  dword [each_mode], 0       ; exit each-mode on fail
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

; SCAN_SCOPED (0x02): Scan a scoped container
; Format: SCAN_SCOPED bind(1) scope_name(2) = 3 bytes after opcode
; Resolves B[bind]::scope_name to a container, then scans it.
ham_op_scan_scoped:
    movzx eax, byte [rsi]          ; bind register index
    inc  rsi
    movzx r10d, word [rsi]         ; scope_name_id
    add  rsi, 2

    ; Get entity index from binding register
    cmp  al, 0
    je   .ss_b0
    cmp  al, 1
    je   .ss_b1
    cmp  al, 2
    je   .ss_b2
    mov  ecx, r15d                  ; B3
    jmp  .ss_resolve
.ss_b0:
    mov  ecx, r12d
    jmp  .ss_resolve
.ss_b1:
    mov  ecx, r13d
    jmp  .ss_resolve
.ss_b2:
    mov  ecx, r14d

.ss_resolve:
    ; Call ham_resolve_scope(entity_idx, scope_name_id)
    ; RCX = entity_idx (set above), RDX = scope_name_id
    mov  edx, r10d
    call ham_resolve_scope

    ; EAX = container_idx (-1 if not found)
    test eax, eax
    js   .ss_empty                  ; negative → no scoped container

    ; Call ham_scan(container_idx, scan_buf, 64)
    mov  ecx, eax                   ; container_idx
    lea  rdx, [scan_buf]
    mov  r8d, 64
    call ham_scan

    mov  [scan_count], eax
    test eax, eax
    jz   .ss_zero
    inc  dword [ham_dbg_scan_nz]
.ss_zero:
    DISPATCH

.ss_empty:
    mov  dword [scan_count], 0
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
    cmp  al, 2
    je   .sf_b2
    mov  r15d, ecx                  ; B3
    jmp  .sf_done
.sf_b0:
    mov  r12d, ecx
    jmp  .sf_done
.sf_b1:
    mov  r13d, ecx
    jmp  .sf_done
.sf_b2:
    mov  r14d, ecx
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
    cmp  r10b, 2
    je   .sm_b2
    mov  r15d, eax                  ; B3
    jmp  .sm_done
.sm_b0:
    mov  r12d, eax
    jmp  .sm_done
.sm_b1:
    mov  r13d, eax
    jmp  .sm_done
.sm_b2:
    mov  r14d, eax

.sm_done:
    DISPATCH

; SEL_MIN (0x05): Select entity with minimum property value
; Format: SEL_MIN bind(1) prop(2) = 3 bytes after opcode
; Mirror of SEL_MAX with comparison flipped (jge → keep min)
ham_op_sel_min:
    movzx r10d, byte [rsi]         ; bind register index
    inc  rsi
    movzx r11d, word [rsi]         ; prop_id
    add  rsi, 2

    ; Iterate scan_buf to find entity with min prop value
    mov  ecx, [scan_count]
    test ecx, ecx
    jz   .smin_done                 ; no entities

    ; Stack layout (same as SEL_MAX):
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

.smin_loop:
    mov  eax, [where_read_idx]
    cmp  eax, [scan_count]
    jge  .smin_found

    ; Get entity at scan_buf[i]
    lea  rcx, [scan_buf]
    mov  ecx, [rcx + rax*4]        ; entity_idx = scan_buf[i]
    push rcx                        ; save entity_idx

    mov  edx, [rsp + 24]           ; prop_id from saved stack slot
                                    ; (rsp+0=eid, +8=best_val, +16=best_ent,
                                    ;  +24=prop_id, +32=bind_idx, +40=PC)
    call ham_eprop                  ; RAX = prop value

    pop  rcx                        ; restore entity_idx

    ; Compare with best_value — keep MINIMUM (jge = not better)
    cmp  rax, [rsp]                 ; compare with best_value at [rsp]
    jge  .smin_not_better

    ; New best (lower value)
    mov  [rsp], rax                 ; update best_value
    mov  [rsp + 8], rcx             ; update best_entity (use 64-bit write)

.smin_not_better:
    inc  dword [where_read_idx]
    jmp  .smin_loop

.smin_found:
    pop  rax                        ; discard best_value
    pop  rax                        ; best_entity (result)
    pop  r11                        ; restore prop_id (discard)
    pop  r10                        ; restore bind_idx
    pop  rsi                        ; restore PC

    ; Store in binding register
    cmp  r10b, 0
    je   .smin_b0
    cmp  r10b, 1
    je   .smin_b1
    cmp  r10b, 2
    je   .smin_b2
    mov  r15d, eax                  ; B3
    jmp  .smin_done
.smin_b0:
    mov  r12d, eax
    jmp  .smin_done
.smin_b1:
    mov  r13d, eax
    jmp  .smin_done
.smin_b2:
    mov  r14d, eax

.smin_done:
    DISPATCH

; SEL_EACH (0x06): Iterate over all entities in scan buffer
; Format: SEL_EACH bind(1) = 1 byte after opcode
; Copies scan_buf, sets B[bind] to first entity, saves PC for TEND loop.
ham_op_sel_each:
    movzx eax, byte [rsi]          ; bind register index
    inc  rsi

    ; Copy scan_buf → each_buf (scan_count * 4 bytes)
    mov  ecx, [scan_count]
    test ecx, ecx
    jz   ham_op_fail                ; no entities → FAIL

    mov  [each_total], ecx
    mov  [each_bind], eax

    ; Copy scan_buf to each_buf
    lea  r8, [scan_buf]
    lea  r9, [each_buf]
    xor  edx, edx
.se_copy:
    cmp  edx, ecx
    jge  .se_copy_done
    mov  r10d, [r8 + rdx*4]
    mov  [r9 + rdx*4], r10d
    inc  edx
    jmp  .se_copy
.se_copy_done:

    ; Set each_idx = 0
    mov  dword [each_idx], 0

    ; Set B[bind] = each_buf[0]
    mov  ecx, [each_buf]
    mov  eax, [each_bind]
    cmp  al, 0
    je   .se_b0
    cmp  al, 1
    je   .se_b1
    cmp  al, 2
    je   .se_b2
    mov  r15d, ecx                  ; B3
    jmp  .se_start
.se_b0:
    mov  r12d, ecx
    jmp  .se_start
.se_b1:
    mov  r13d, ecx
    jmp  .se_start
.se_b2:
    mov  r14d, ecx

.se_start:
    ; Save PC (right after SEL_EACH, before emit clauses)
    mov  [each_start], rsi
    ; Enter each-mode
    mov  dword [each_mode], 1
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
    cmp  al, 2
    je   .wb2
    mov  r15d, ecx                  ; B3
    jmp  .wdone
.wb0:
    mov  r12d, ecx
    jmp  .wdone
.wb1:
    mov  r13d, ecx
    jmp  .wdone
.wb2:
    mov  r14d, ecx
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
    cmp  al, 2
    je   .ewb2
    mov  r15d, ecx                  ; B3
    jmp  .ew_restart
.ewb0:
    mov  r12d, ecx
    jmp  .ew_restart
.ewb1:
    mov  r13d, ecx
    jmp  .ew_restart
.ewb2:
    mov  r14d, ecx

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
    cmp  al, 2
    je   .ep_b2
    mov  ecx, r15d                  ; B3
    jmp  .ep_call
.ep_b0:
    mov  ecx, r12d
    jmp  .ep_call
.ep_b1:
    mov  ecx, r13d
    jmp  .ep_call
.ep_b2:
    mov  ecx, r14d

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
    cmp  al, 2
    je   .emov_b2
    mov  ecx, r15d                  ; B3
    jmp  .emov_store
.emov_b0:
    mov  ecx, r12d
    jmp  .emov_store
.emov_b1:
    mov  ecx, r13d
    jmp  .emov_store
.emov_b2:
    mov  ecx, r14d

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

; EMOV_S (0x31): Buffer a scoped MOVE action
; Format: EMOV_S mt(2) entity_bind(1) owner_bind(1) scope(2) = 6 bytes after opcode
; Resolves B[owner]::scope to container, then buffers MOVE action.
ham_op_emov_s:
    movzx r10d, word [rsi]         ; mt_idx
    add  rsi, 2
    movzx eax, byte [rsi]          ; entity_bind index
    inc  rsi
    movzx ecx, byte [rsi]          ; owner_bind index
    inc  rsi
    movzx r11d, word [rsi]         ; scope_name_id
    add  rsi, 2

    ; Get entity index from entity_bind register
    cmp  al, 0
    je   .ems_eb0
    cmp  al, 1
    je   .ems_eb1
    cmp  al, 2
    je   .ems_eb2
    push r15                        ; B3 entity
    jmp  .ems_get_owner
.ems_eb0:
    push r12                        ; B0 entity
    jmp  .ems_get_owner
.ems_eb1:
    push r13                        ; B1 entity
    jmp  .ems_get_owner
.ems_eb2:
    push r14                        ; B2 entity

.ems_get_owner:
    ; Get owner entity index from owner_bind register
    ; ECX still holds owner_bind index
    cmp  cl, 0
    je   .ems_ob0
    cmp  cl, 1
    je   .ems_ob1
    cmp  cl, 2
    je   .ems_ob2
    mov  ecx, r15d                  ; B3
    jmp  .ems_resolve
.ems_ob0:
    mov  ecx, r12d
    jmp  .ems_resolve
.ems_ob1:
    mov  ecx, r13d
    jmp  .ems_resolve
.ems_ob2:
    mov  ecx, r14d

.ems_resolve:
    ; Save mt_idx and RSI across call
    push r10                        ; save mt_idx
    push rsi                        ; save PC

    ; Call ham_resolve_scope(owner_entity, scope_name_id)
    ; RCX = owner_entity (set above), RDX = scope_name_id
    mov  edx, r11d
    call ham_resolve_scope

    pop  rsi                        ; restore PC
    pop  r10                        ; restore mt_idx

    ; EAX = to_container_idx (-1 if not found)
    test eax, eax
    js   .ems_skip                  ; negative → skip this emit

    ; Pop entity_idx from stack
    pop  rcx                        ; entity_idx (was pushed earlier)

    ; Append MOVE action to buffer
    mov  edx, [action_count]
    cmp  edx, 40
    jge  .ems_done

    imul edx, 24
    lea  r8, [action_buf]
    add  r8, rdx

    mov  dword [r8], 0              ; kind = MOVE
    mov  [r8 + 4], r10d             ; mt_idx
    mov  [r8 + 8], ecx              ; entity_idx
    mov  dword [r8 + 12], 0         ; padding
    movsxd rdx, eax                 ; to_container sign-extended
    mov  [r8 + 16], rdx             ; to_container_idx

    inc  dword [action_count]
    jmp  .ems_done

.ems_skip:
    ; Pop entity_idx (discard)
    pop  rcx

.ems_done:
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
    cmp  al, 2
    je   .eset_b2
    mov  ecx, r15d                  ; B3
    jmp  .eset_pop
.eset_b0:
    mov  ecx, r12d
    jmp  .eset_pop
.eset_b1:
    mov  ecx, r13d
    jmp  .eset_pop
.eset_b2:
    mov  ecx, r14d

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

; ESEND (0x33): Buffer a channel SEND action
; Format: ESEND chan(2) bind(1) = 3 bytes after opcode
ham_op_esend:
    movzx r10d, word [rsi]         ; channel_idx
    add  rsi, 2
    movzx eax, byte [rsi]          ; entity_bind index
    inc  rsi

    ; Get entity index from binding register
    cmp  al, 0
    je   .esnd_b0
    cmp  al, 1
    je   .esnd_b1
    cmp  al, 2
    je   .esnd_b2
    mov  ecx, r15d                  ; B3
    jmp  .esnd_store
.esnd_b0:
    mov  ecx, r12d
    jmp  .esnd_store
.esnd_b1:
    mov  ecx, r13d
    jmp  .esnd_store
.esnd_b2:
    mov  ecx, r14d

.esnd_store:
    ; Append SEND action to buffer
    mov  eax, [action_count]
    cmp  eax, 40
    jge  .esnd_skip

    imul eax, 24
    lea  r8, [action_buf]
    add  r8, rax

    mov  dword [r8], 2              ; kind = SEND
    mov  [r8 + 4], r10d             ; channel_idx
    mov  [r8 + 8], ecx              ; entity_idx
    mov  dword [r8 + 12], 0         ; padding
    mov  qword [r8 + 16], 0         ; field3 unused

    inc  dword [action_count]

.esnd_skip:
    DISPATCH

; ERECV_S (0x35): Buffer a scoped channel RECEIVE action
; Format: ERECV_S chan(2) entity_bind(1) owner_bind(1) scope(2) = 6 bytes after opcode
ham_op_erecv_s:
    movzx r10d, word [rsi]         ; channel_idx
    add  rsi, 2
    movzx eax, byte [rsi]          ; entity_bind index
    inc  rsi
    movzx ecx, byte [rsi]          ; owner_bind index
    inc  rsi
    movzx r11d, word [rsi]         ; scope_name_id
    add  rsi, 2

    ; Get entity index from entity_bind register
    cmp  al, 0
    je   .ercv_eb0
    cmp  al, 1
    je   .ercv_eb1
    cmp  al, 2
    je   .ercv_eb2
    push r15                        ; B3 entity
    jmp  .ercv_get_owner
.ercv_eb0:
    push r12                        ; B0 entity
    jmp  .ercv_get_owner
.ercv_eb1:
    push r13                        ; B1 entity
    jmp  .ercv_get_owner
.ercv_eb2:
    push r14                        ; B2 entity

.ercv_get_owner:
    ; Get owner entity index from owner_bind register
    cmp  cl, 0
    je   .ercv_ob0
    cmp  cl, 1
    je   .ercv_ob1
    cmp  cl, 2
    je   .ercv_ob2
    mov  ecx, r15d                  ; B3
    jmp  .ercv_resolve
.ercv_ob0:
    mov  ecx, r12d
    jmp  .ercv_resolve
.ercv_ob1:
    mov  ecx, r13d
    jmp  .ercv_resolve
.ercv_ob2:
    mov  ecx, r14d

.ercv_resolve:
    ; Save channel_idx and RSI across call
    push r10                        ; save channel_idx
    push rsi                        ; save PC

    ; Call ham_resolve_scope(owner_entity, scope_name_id)
    mov  edx, r11d
    call ham_resolve_scope

    pop  rsi                        ; restore PC
    pop  r10                        ; restore channel_idx

    ; EAX = to_container_idx (-1 if not found)
    test eax, eax
    js   .ercv_skip                 ; negative → skip this emit

    ; Pop entity_idx from stack
    pop  rcx                        ; entity_idx

    ; Append RECV action to buffer
    mov  edx, [action_count]
    cmp  edx, 40
    jge  .ercv_done

    imul edx, 24
    lea  r8, [action_buf]
    add  r8, rdx

    mov  dword [r8], 3              ; kind = RECV
    mov  [r8 + 4], r10d             ; channel_idx
    mov  [r8 + 8], ecx              ; entity_idx
    mov  dword [r8 + 12], 0         ; padding
    movsxd rdx, eax                 ; to_container sign-extended
    mov  [r8 + 16], rdx             ; to_container_idx

    inc  dword [action_count]
    jmp  .ercv_done

.ercv_skip:
    ; Pop entity_idx (discard)
    pop  rcx

.ercv_done:
    DISPATCH
