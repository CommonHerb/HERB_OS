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

%include "herb_graph_layout.inc"

; C bridge function imports (Category B/C — ported to assembly in Phase 4d)
extern ham_scan
extern ham_eprop
extern ham_ecnt
extern ham_entity_loc
extern ham_eset
; Category A — rewired to assembly functions directly (Phase 4d)
extern try_move
extern get_scoped_container
extern do_channel_send
extern do_channel_receive
; Parallel arrays (from herb_graph.asm)
extern container_order_keys
extern tension_step_flags
; Session 74: standalone tension data (from herb_graph.asm)
extern g_tensions
extern g_tension_count
; Phase 4i — HAM compiler externs
extern g_graph
extern intern
extern graph_find_entity_by_name
extern graph_find_container_by_name
extern str_of
extern serial_print
extern herb_snprintf

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
global fixpoint_iters
; Phase 4i — HAM compiler exports
global ham_compile_all
; Phase D Step 7d — HAM data exports (migrated from C)
global g_ham_bytecode, g_ham_bytecode_len, g_ham_compiled_count, g_ham_dirty

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
scan_last_ctnr:  resd 1        ; last scanned container index (for ordered sort)
ham_pass_mode:   resd 1        ; 0 = step pass, 1 = converge pass
thdr_flags:      resd 1        ; flags byte from current THDR
; Debug counters (read by C after ham_run returns)
ham_dbg_thdr:    resd 1        ; number of THDR entries
ham_dbg_fail:    resd 1        ; number of FAILs
ham_dbg_tend:    resd 1        ; number of TENDs with actions
ham_dbg_action:  resd 1        ; number of actions attempted
ham_dbg_scan_nz: resd 1        ; number of SCANs returning >0 entities
ham_dbg_require: resd 1        ; number of REQUIREs reached
ham_dbg_guard:   resd 1        ; number of GUARDs reached
ham_dbg_skip:    resd 1        ; number of THDR owner-check skips (Phase 3c)
ham_dbg_emov:    resd 1        ; number of EMOV instructions executed

; Phase D Step 7d — HAM data (migrated from C)
g_ham_bytecode:  resb 8192     ; uint8_t[8192] — compiled bytecode buffer

; Phase 4i — HAM compiler BSS
ham_op_ids_init: resd 1        ; lazy init flag
ham_id_add:      resd 1
ham_id_sub:      resd 1
ham_id_mul:      resd 1
ham_id_gt:       resd 1
ham_id_lt:       resd 1
ham_id_gte:      resd 1
ham_id_lte:      resd 1
ham_id_eq:       resd 1
ham_id_neq:      resd 1
ham_id_and:      resd 1
ham_id_or:       resd 1

; ============================================================
; DATA — HAM counters (Phase D Step 7d: migrated from C)
; ============================================================

section .data

align 4
g_ham_bytecode_len:   dd 0     ; int — compiled bytecode length
g_ham_compiled_count: dd 0     ; int — number of compiled tensions
g_ham_dirty:          dd 1     ; int — dirty flag (1 = needs recompile)

; ============================================================
; RDATA — HAM compiler string constants (Phase 4i)
; ============================================================

section .rdata

hc_str_plus:      db "+", 0
hc_str_minus:     db "-", 0
hc_str_star:      db "*", 0
hc_str_gt:        db ">", 0
hc_str_lt:        db "<", 0
hc_str_gte:       db ">=", 0
hc_str_lte:       db "<=", 0
hc_str_eq:        db "==", 0
hc_str_neq:       db "!=", 0
hc_str_and:       db "and", 0
hc_str_or:        db "or", 0
hc_comp_pfx:      db "  [COMP] ", 0
hc_comp_ok:       db " OK len=%d", 10, 0
hc_comp_fail:     db " FAIL", 10, 0
hc_ham_diag:      db "  [HAM] Compiling ", 0
hc_ham_mc:        db " mc[", 0
hc_ham_eq2:       db "]=cidx ", 0
hc_ham_lp:        db "(", 0
hc_ham_rp:        db ")", 0
hc_newline:       db 10, 0
hc_intfmt:        db "%d", 0
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
    mov  dword [ham_pass_mode], 0  ; start with step pass

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
; Format: THDR pri(1) flags(1) owner(2) run_ctnr(2) tension_len(2) = 8 bytes after opcode
; Phase 3c: owner scheduling — system/daemon/process three-way check
ham_op_thdr:
    inc  dword [ham_dbg_thdr]
    movzx eax, byte [rsi]          ; pri (1 byte)
    inc  rsi

    movzx eax, byte [rsi]          ; flags (1 byte)
    inc  rsi
    mov  [thdr_flags], eax          ; save to BSS

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
    sub  rdx, 9                     ; back to THDR opcode (1+1+1+2+2+2=9 bytes)
    add  rdx, rcx                   ; + tension_len
    mov  [tension_end_p], rdx

    ; === Pass-mode filtering ===
    mov  eax, [ham_pass_mode]
    mov  ecx, [thdr_flags]
    and  ecx, 1                     ; step_flag
    test eax, eax
    jz   .thdr_step_pass
    ; converge pass: skip step tensions
    test ecx, ecx
    jnz  .thdr_skip                 ; step tension in converge pass → skip
    jmp  .thdr_owner_check
.thdr_step_pass:
    ; step pass: skip converge tensions
    test ecx, ecx
    jz   .thdr_skip                 ; converge tension in step pass → skip

.thdr_owner_check:
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
    inc  dword [ham_dbg_action]
    push r8
    push r9
    sub  rsp, 32                    ; shadow space (MS x64 ABI)

    mov  ecx, [r8 + 4]             ; mt_idx
    mov  edx, [r8 + 8]             ; entity_idx
    mov  r8d, [r8 + 16]            ; to_container (from field3, low 32 bits)
    call try_move

    add  rsp, 32
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
    sub  rsp, 32                    ; shadow space (MS x64 ABI)

    mov  ecx, [r8 + 4]             ; entity_idx
    mov  edx, [r8 + 8]             ; prop_id
    mov  r8, [r8 + 16]             ; value (i64)
    call ham_eset

    add  rsp, 32
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
    sub  rsp, 32                    ; shadow space (MS x64 ABI)

    mov  ecx, [r8 + 4]             ; channel_idx
    mov  edx, [r8 + 8]             ; entity_idx
    call do_channel_send

    add  rsp, 32
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
    sub  rsp, 32                    ; shadow space (MS x64 ABI)

    mov  ecx, [r8 + 4]             ; channel_idx
    mov  edx, [r8 + 8]             ; entity_idx
    mov  r8d, [r8 + 16]            ; to_container_idx (from field3, low 32 bits)
    call do_channel_receive

    add  rsp, 32
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

    ; Two-pass fixpoint: step pass → converge pass
    cmp  dword [ham_pass_mode], 0
    je   .switch_to_converge        ; step pass done → switch to converge

    ; Converge pass: normal fixpoint loop
    cmp  dword [changed_flag], 0
    je   ham_run.done               ; no changes → equilibrium, return

    inc  dword [fixpoint_iters]
    cmp  dword [fixpoint_iters], 100
    jge  ham_run.done               ; safety limit
    mov  rsi, rbx                   ; PC = bytecode start
    mov  dword [changed_flag], 0
    jmp  .not_end                   ; continue converge pass

.switch_to_converge:
    mov  dword [ham_pass_mode], 1   ; enter converge pass
    mov  rsi, rbx                   ; reset PC to bytecode start
    mov  dword [changed_flag], 0    ; clear changed flag for converge pass

.not_end:
    DISPATCH

; FAIL (0x42): Tension failed — clear actions, skip to tension_end
; Discovery 51 fix: in each-mode, advance to next entity instead of aborting.
; Only abort the entire tension when all each entities are exhausted.
ham_op_fail:
    inc  dword [ham_dbg_fail]
    mov  dword [action_count], 0

    ; If in each-mode, advance to next entity instead of aborting
    cmp  dword [each_mode], 0
    je   .fail_abort

    ; --- Each-mode advance (mirrors TEND each-advance at lines 498-529) ---
    inc  dword [each_idx]
    mov  ecx, [each_idx]
    cmp  ecx, [each_total]
    jge  .fail_each_done

    ; Set B[each_bind] = each_buf[each_idx]
    lea  rdx, [each_buf]
    mov  edx, [rdx + rcx*4]        ; entity_idx = each_buf[each_idx]
    mov  eax, [each_bind]
    cmp  al, 0
    je   .fail_sb0
    cmp  al, 1
    je   .fail_sb1
    cmp  al, 2
    je   .fail_sb2
    mov  r15d, edx                  ; B3
    jmp  .fail_continue
.fail_sb0:
    mov  r12d, edx
    jmp  .fail_continue
.fail_sb1:
    mov  r13d, edx
    jmp  .fail_continue
.fail_sb2:
    mov  r14d, edx

.fail_continue:
    ; Reset expression stack and jump back to each_start
    lea  rdi, [expr_stack]
    mov  rsi, [each_start]
    DISPATCH

.fail_each_done:
    ; All each entities exhausted — exit each-mode, fall through to abort
    mov  dword [each_mode], 0

.fail_abort:
    mov  rsi, [tension_end_p]

    ; Check if we've passed the end
    cmp  rsi, [bytecode_end_p]
    jge  ham_op_tend.no_actions      ; treat as TEND at end (for fixpoint)

    DISPATCH

; ============================================================
; ham_sort_scan_buf(container_idx)
; Insertion sort scan_buf by ascending order_key property value.
; If container is unordered or scan_count < 2, returns immediately.
; ECX = container_idx
; Clobbers: caller-saved registers
; ============================================================
ham_sort_scan_buf:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 48
    ; ret(8)+rbp(8)+4*push(32)+sub(48)=96, 96%16=0 ✓
    ; [rsp+32]=key_value, [rsp+40]=key_entity

    ; Check if container is ordered
    lea     rax, [container_order_keys]
    mov     ebx, [rax + rcx*4]         ; EBX = order_key prop_id
    cmp     ebx, -1
    je      .hsb_done                  ; unordered → return

    ; Check if scan_count >= 2
    mov     eax, [scan_count]
    cmp     eax, 2
    jl      .hsb_done                  ; 0 or 1 elements → no sort needed

    ; Insertion sort: i = 1 .. scan_count-1
    mov     r12d, 1                    ; R12 = i (outer loop)
.hsb_outer:
    cmp     r12d, [scan_count]
    jge     .hsb_done

    ; key_entity = scan_buf[i]
    lea     rax, [scan_buf]
    mov     r13d, [rax + r12*4]        ; R13 = key_entity
    mov     [rsp+40], r13d

    ; key_value = ham_eprop(key_entity, order_key)
    mov     ecx, r13d
    mov     edx, ebx                   ; prop_id
    call    ham_eprop
    mov     [rsp+32], rax              ; key_value (int64)

    ; j = i - 1
    lea     r14d, [r12d - 1]           ; R14 = j
.hsb_inner:
    cmp     r14d, 0
    jl      .hsb_insert

    ; val_j = ham_eprop(scan_buf[j], order_key)
    lea     rax, [scan_buf]
    mov     ecx, [rax + r14*4]         ; entity at scan_buf[j]
    mov     edx, ebx
    call    ham_eprop

    ; Compare: if val_j <= key_value, stop shifting
    cmp     rax, [rsp+32]
    jle     .hsb_insert

    ; Shift: scan_buf[j+1] = scan_buf[j]
    lea     rax, [scan_buf]
    lea     ecx, [r14d + 1]
    mov     edx, [rax + r14*4]
    mov     [rax + rcx*4], edx

    dec     r14d
    jmp     .hsb_inner

.hsb_insert:
    ; scan_buf[j+1] = key_entity
    lea     rax, [scan_buf]
    lea     ecx, [r14d + 1]
    mov     edx, [rsp+40]
    mov     [rax + rcx*4], edx

    inc     r12d
    jmp     .hsb_outer

.hsb_done:
    add     rsp, 48
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; ============================================================
; SCANNING INSTRUCTIONS
; ============================================================

; SCAN (0x01): Scan container for entities
; Format: SCAN ctnr(2) = 2 bytes after opcode
ham_op_scan:
    movzx ecx, word [rsi]          ; container_idx
    add  rsi, 2
    mov  [scan_last_ctnr], ecx     ; save for sort

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

    ; Sort scan_buf if container is ordered
    mov  ecx, [scan_last_ctnr]
    call ham_sort_scan_buf

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
    call get_scoped_container

    ; EAX = container_idx (-1 if not found)
    test eax, eax
    js   .ss_empty                  ; negative → no scoped container

    ; Call ham_scan(container_idx, scan_buf, 64)
    mov  ecx, eax                   ; container_idx
    mov  [scan_last_ctnr], ecx      ; save for sort
    lea  rdx, [scan_buf]
    mov  r8d, 64
    call ham_scan

    mov  [scan_count], eax
    test eax, eax
    jz   .ss_zero
    inc  dword [ham_dbg_scan_nz]

    ; Sort scan_buf if container is ordered
    mov  ecx, [scan_last_ctnr]
    call ham_sort_scan_buf

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
    ; scan_count=0: skip WHERE body entirely by scanning forward for ENDWHERE (0x11)
    ; Bug fix (Session 72c): previously fell through to WHERE body, which evaluated
    ; expressions on stale B0 and could write truthy result, causing ENDWHERE to
    ; set scan_count=1 for an empty container — infinite fixpoint oscillation.
    mov  dword [scan_count], 0
.where_skip_loop:
    cmp  rsi, [bytecode_end_p]
    jge  .where_skip_done
    movzx eax, byte [rsi]
    inc  rsi
    cmp  al, 0x11              ; ENDWHERE opcode
    jne  .where_skip_loop
.where_skip_done:
    ; RSI now points past the ENDWHERE opcode. scan_count stays 0.
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
    inc  dword [ham_dbg_emov]
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
    call get_scoped_container

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
    call get_scoped_container

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

; ============================================================
; PHASE 4i: HAM BYTECODE COMPILER (Assembly)
;
; Replaces the C HAM compiler from herb_runtime_freestanding.c.
; Functions: ham_init_op_ids, ham_bind_lookup, ham_bind_alloc,
;            ham_expr_compilable, ham_tension_compilable,
;            ham_compile_expr, ham_compile_tension, ham_compile_all
; ============================================================

; ============================================================
; ham_init_op_ids — Intern operator strings, cache IDs to BSS
;
; No args. Idempotent (checks ham_op_ids_init flag).
; Clobbers: RCX, RDX, R8-R11, RAX
; ============================================================
ham_init_op_ids:
    cmp     dword [ham_op_ids_init], 0
    jne     .hioi_done
    push    rbp
    mov     rbp, rsp
    push    rbx
    sub     rsp, 32             ; shadow space

    lea     rcx, [hc_str_plus]
    call    intern
    mov     [ham_id_add], eax

    lea     rcx, [hc_str_minus]
    call    intern
    mov     [ham_id_sub], eax

    lea     rcx, [hc_str_star]
    call    intern
    mov     [ham_id_mul], eax

    lea     rcx, [hc_str_gt]
    call    intern
    mov     [ham_id_gt], eax

    lea     rcx, [hc_str_lt]
    call    intern
    mov     [ham_id_lt], eax

    lea     rcx, [hc_str_gte]
    call    intern
    mov     [ham_id_gte], eax

    lea     rcx, [hc_str_lte]
    call    intern
    mov     [ham_id_lte], eax

    lea     rcx, [hc_str_eq]
    call    intern
    mov     [ham_id_eq], eax

    lea     rcx, [hc_str_neq]
    call    intern
    mov     [ham_id_neq], eax

    lea     rcx, [hc_str_and]
    call    intern
    mov     [ham_id_and], eax

    lea     rcx, [hc_str_or]
    call    intern
    mov     [ham_id_or], eax

    mov     dword [ham_op_ids_init], 1

    add     rsp, 32
    pop     rbx
    pop     rbp
.hioi_done:
    ret

; ============================================================
; ham_bind_lookup(HamBindMap* m, int bind_id) -> int reg (-1 if not found)
;
; RCX = m (HamBindMap*), EDX = bind_id
; Returns register index in EAX, or -1 if not found.
; Leaf function — no frame needed.
; ============================================================
ham_bind_lookup:
    mov     r8d, [rcx + HBM_COUNT]
    xor     eax, eax            ; i = 0
.hbl_loop:
    cmp     eax, r8d
    jge     .hbl_notfound
    cmp     edx, [rcx + HBM_IDS + rax*4]
    je      .hbl_found
    inc     eax
    jmp     .hbl_loop
.hbl_found:
    mov     eax, [rcx + HBM_REGS + rax*4]
    ret
.hbl_notfound:
    mov     eax, -1
    ret

; ============================================================
; ham_bind_alloc(HamBindMap* m, int bind_id) -> int reg (-1 if full)
;
; RCX = m (HamBindMap*), EDX = bind_id
; Looks up bind_id first; if found, returns existing reg.
; Otherwise allocates new slot (count as reg index).
; Returns register index in EAX, or -1 if full.
; ============================================================
ham_bind_alloc:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    sub     rsp, 32

    mov     rbx, rcx            ; RBX = m
    mov     esi, edx            ; ESI = bind_id

    ; Try lookup first
    call    ham_bind_lookup
    test    eax, eax
    jns     .hba_done           ; found (>= 0)

    ; Not found — allocate
    mov     eax, [rbx + HBM_COUNT]
    cmp     eax, HAM_MAX_BINDS
    jge     .hba_full

    ; m->ids[count] = bind_id
    movsxd  rcx, eax
    mov     [rbx + HBM_IDS + rcx*4], esi
    ; m->regs[count] = count (reg = slot index)
    mov     [rbx + HBM_REGS + rcx*4], eax
    ; m->count++
    inc     dword [rbx + HBM_COUNT]
    ; return reg (already in EAX)
    jmp     .hba_done

.hba_full:
    mov     eax, -1
.hba_done:
    add     rsp, 32
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; ham_expr_compilable(Expr* e) -> int (1=compilable, 0=not)
;
; RCX = e (Expr*)
; Recursive. Checks if expression tree can be compiled to HAM.
; ============================================================
ham_expr_compilable:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    sub     rsp, 32

    ; if (!e) return 0
    test    rcx, rcx
    jz      .hec_zero

    mov     ebx, [rcx + EX_KIND]  ; EBX = kind
    mov     rsi, rcx              ; RSI = e

    ; EX_INT (0) -> return 1
    cmp     ebx, EX_INT_T
    je      .hec_one

    ; EX_BOOL (3) -> return 1
    cmp     ebx, EX_BOOL_T
    je      .hec_one

    ; EX_PROP (4) -> return 1
    cmp     ebx, EX_PROP_T
    je      .hec_one

    ; EX_COUNT (5) -> check flags
    cmp     ebx, EX_COUNT_T
    je      .hec_count

    ; EX_BINARY (6) -> recurse
    cmp     ebx, EX_BINARY_T
    je      .hec_binary

    ; EX_UNARY (7) -> recurse on arg
    cmp     ebx, EX_UNARY_T
    je      .hec_unary

    ; default (EX_FLOAT, EX_STRING, EX_IN_OF) -> return 0
    jmp     .hec_zero

.hec_count:
    ; return !e->count.is_scoped && !e->count.is_channel && e->count.container_idx >= 0
    cmp     dword [rsi + EX_COUNT_SCOPED], 0
    jne     .hec_zero
    cmp     dword [rsi + EX_COUNT_ISCHAN], 0
    jne     .hec_zero
    cmp     dword [rsi + EX_COUNT_CIDX], 0
    jl      .hec_zero
    jmp     .hec_one

.hec_binary:
    ; init op IDs, check for unsupported ops (mul, or)
    call    ham_init_op_ids
    mov     eax, [rsi + EX_BINARY_OP_ID]
    cmp     eax, [ham_id_mul]
    je      .hec_zero
    cmp     eax, [ham_id_or]
    je      .hec_zero
    ; recurse left
    mov     rcx, [rsi + EX_BINARY_LEFT]
    call    ham_expr_compilable
    test    eax, eax
    jz      .hec_zero
    ; recurse right
    mov     rcx, [rsi + EX_BINARY_RIGHT]
    call    ham_expr_compilable
    jmp     .hec_done           ; return result of right

.hec_unary:
    mov     rcx, [rsi + EX_UNARY_ARG]
    call    ham_expr_compilable
    jmp     .hec_done           ; return result of arg

.hec_one:
    mov     eax, 1
    jmp     .hec_done
.hec_zero:
    xor     eax, eax
.hec_done:
    add     rsp, 32
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; ham_tension_compilable(Tension* t) -> int (1=compilable, 0=not)
;
; RCX = t (Tension*)
; Checks if all match/emit clauses are compilable.
; ============================================================
ham_tension_compilable:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 32

    mov     rbx, rcx            ; RBX = t

    ; if (!t->enabled) return 0
    cmp     dword [rbx + TEN_ENABLED], 0
    je      .htc_zero

    ; --- Check match clauses ---
    xor     esi, esi            ; ESI = i
    mov     r12d, [rbx + TEN_MATCH_COUNT]

.htc_mc_loop:
    cmp     esi, r12d
    jge     .htc_check_emits

    ; mc = &t->matches[i]
    movsxd  rax, esi
    imul    rax, SIZEOF_MATCHCLAUSE
    lea     rdi, [rbx + TEN_MATCHES + rax]  ; RDI = mc

    mov     eax, [rdi + MC_KIND]

    cmp     eax, MC_ENTITY_IN_V
    je      .htc_mc_entity_in

    cmp     eax, MC_EMPTY_IN_V
    je      .htc_mc_empty_in

    cmp     eax, MC_GUARD_V
    je      .htc_mc_guard

    cmp     eax, MC_CONTAINER_IS_V
    je      .htc_mc_next        ; always compilable

    ; unknown kind -> return 0
    jmp     .htc_zero

.htc_mc_entity_in:
    ; if (mc->where_expr && !ham_expr_compilable(mc->where_expr)) return 0
    mov     rcx, [rdi + MC_WHERE_EXPR]
    test    rcx, rcx
    jz      .htc_mc_next
    call    ham_expr_compilable
    test    eax, eax
    jz      .htc_zero
    jmp     .htc_mc_next

.htc_mc_empty_in:
    ; if (mc->container_count != 1) return 0
    cmp     dword [rdi + MC_CONTAINER_COUNT], 1
    jne     .htc_zero
    jmp     .htc_mc_next

.htc_mc_guard:
    ; if (!mc->guard_expr || !ham_expr_compilable(mc->guard_expr)) return 0
    mov     rcx, [rdi + MC_GUARD_EXPR]
    test    rcx, rcx
    jz      .htc_zero
    call    ham_expr_compilable
    test    eax, eax
    jz      .htc_zero

.htc_mc_next:
    inc     esi
    jmp     .htc_mc_loop

.htc_check_emits:
    ; --- Check emit clauses ---
    xor     esi, esi            ; ESI = i
    mov     r12d, [rbx + TEN_EMIT_COUNT]

.htc_ec_loop:
    cmp     esi, r12d
    jge     .htc_one

    ; ec = &t->emits[i]
    movsxd  rax, esi
    imul    rax, SIZEOF_EMITCLAUSE
    lea     rdi, [rbx + TEN_EMITS + rax]  ; RDI = ec

    mov     eax, [rdi + EC_KIND]

    cmp     eax, EC_MOVE_V
    je      .htc_ec_next        ; always compilable

    cmp     eax, EC_SET_V
    je      .htc_ec_set

    cmp     eax, EC_SEND_V
    je      .htc_ec_next        ; supported

    cmp     eax, EC_RECEIVE_V
    je      .htc_ec_next        ; supported (scoped target)

    ; EC_TRANSFER, EC_DUPLICATE -> return 0
    jmp     .htc_zero

.htc_ec_set:
    ; if (!ec->value_expr || !ham_expr_compilable(ec->value_expr)) return 0
    mov     rcx, [rdi + EC_VALUE_EXPR]
    test    rcx, rcx
    jz      .htc_zero
    call    ham_expr_compilable
    test    eax, eax
    jz      .htc_zero

.htc_ec_next:
    inc     esi
    jmp     .htc_ec_loop

.htc_one:
    mov     eax, 1
    jmp     .htc_done
.htc_zero:
    xor     eax, eax
.htc_done:
    add     rsp, 32
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; ham_compile_expr(Expr* e, uint8_t* buf, int* pos, HamBindMap* bm, int buf_size) -> int
;
; RCX = e, RDX = buf, R8 = pos, R9 = bm, [RBP+48] = buf_size
; Returns 1 on success, 0 on failure.
;
; Register plan for recursive calls:
;   RBX = e, RSI = buf, RDI = pos_ptr, R12 = bm, R13d = buf_size
; ============================================================
ham_compile_expr:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    sub     rsp, 40             ; 32 shadow + 8 align (5 pushes + push rbp = 48 = 16-aligned, +40 = 88 total, need +8 for alignment)
    ; Stack: 6 pushes (48) + sub 40 = 88, RSP at call = 88 from entry... let me recalculate
    ; Entry: RSP is 16n+8 (after return addr push)
    ; push rbp: RSP = 16n
    ; push rbx,rsi,rdi,r12,r13: 5 pushes, RSP = 16n - 40 = 16(n-2) - 8
    ; Need sub rsp, X such that RSP - X is 16-aligned for calls
    ; Current RSP = 16(n-2) - 8, so sub 40: RSP = 16(n-2) - 48 = 16(n-5), 16-aligned. Good.

    ; Save args to callee-saved
    mov     rbx, rcx            ; RBX = e
    mov     rsi, rdx            ; RSI = buf
    mov     rdi, r8             ; RDI = pos_ptr
    mov     r12, r9             ; R12 = bm
    mov     r13d, [rbp + 48]    ; R13d = buf_size

    ; if (!e) return 0
    test    rbx, rbx
    jz      .hce_zero

    ; if (*pos >= buf_size - 10) return 0
    mov     eax, [rdi]
    mov     ecx, r13d
    sub     ecx, 10
    cmp     eax, ecx
    jge     .hce_zero

    mov     ecx, [rbx + EX_KIND]  ; ECX = kind

    cmp     ecx, EX_INT_T
    je      .hce_int

    cmp     ecx, EX_BOOL_T
    je      .hce_bool

    cmp     ecx, EX_PROP_T
    je      .hce_prop

    cmp     ecx, EX_COUNT_T
    je      .hce_count

    cmp     ecx, EX_BINARY_T
    je      .hce_binary

    cmp     ecx, EX_UNARY_T
    je      .hce_unary

    ; default -> return 0
    jmp     .hce_zero

.hce_int:
    ; buf[pos++] = 0x20 (IPUSH)
    mov     eax, [rdi]
    mov     byte [rsi + rax], 0x20
    inc     eax
    ; ham_put_i32 inline: write (int32_t)e->int_val as LE
    mov     ecx, [rbx + EX_INT_VAL]   ; low 32 bits of int64_t
    mov     [rsi + rax], ecx           ; x86 stores LE natively
    add     eax, 4
    mov     [rdi], eax
    jmp     .hce_one

.hce_bool:
    ; buf[pos++] = 0x20 (IPUSH)
    mov     eax, [rdi]
    mov     byte [rsi + rax], 0x20
    inc     eax
    ; value = bool_val ? 1 : 0
    mov     ecx, [rbx + EX_BOOL_VAL]
    test    ecx, ecx
    setnz   cl
    movzx   ecx, cl
    mov     [rsi + rax], ecx
    add     eax, 4
    mov     [rdi], eax
    jmp     .hce_one

.hce_prop:
    ; reg = ham_bind_lookup(bm, e->prop.of_id)
    mov     rcx, r12
    mov     edx, [rbx + EX_OF_ID]
    call    ham_bind_lookup
    test    eax, eax
    js      .hce_zero           ; reg < 0 -> fail

    ; buf[pos++] = 0x21 (EPROP), buf[pos++] = reg
    mov     ecx, [rdi]          ; pos
    mov     byte [rsi + rcx], 0x21
    inc     ecx
    mov     [rsi + rcx], al     ; reg byte
    inc     ecx
    ; ham_put_u16 inline: prop_id
    mov     edx, [rbx + EX_PROP_ID]
    mov     [rsi + rcx], dx     ; x86 stores u16 LE natively
    add     ecx, 2
    mov     [rdi], ecx
    jmp     .hce_one

.hce_count:
    ; buf[pos++] = 0x22 (ECNT)
    mov     eax, [rdi]
    mov     byte [rsi + rax], 0x22
    inc     eax
    ; ham_put_u16 inline: container_idx
    mov     ecx, [rbx + EX_COUNT_CIDX]
    mov     [rsi + rax], cx
    add     eax, 2
    mov     [rdi], eax
    jmp     .hce_one

.hce_binary:
    ; Recurse left: ham_compile_expr(e->binary.left, buf, pos, bm, buf_size)
    mov     rcx, [rbx + EX_BINARY_LEFT]
    mov     rdx, rsi
    mov     r8, rdi
    mov     r9, r12
    mov     dword [rsp + 32], r13d
    call    ham_compile_expr
    test    eax, eax
    jz      .hce_zero

    ; Recurse right: ham_compile_expr(e->binary.right, buf, pos, bm, buf_size)
    mov     rcx, [rbx + EX_BINARY_RIGHT]
    mov     rdx, rsi
    mov     r8, rdi
    mov     r9, r12
    mov     dword [rsp + 32], r13d
    call    ham_compile_expr
    test    eax, eax
    jz      .hce_zero

    ; Emit operator byte
    call    ham_init_op_ids
    mov     eax, [rbx + EX_BINARY_OP_ID]
    mov     ecx, [rdi]          ; pos

    cmp     eax, [ham_id_add]
    je      .hce_bin_add
    cmp     eax, [ham_id_sub]
    je      .hce_bin_sub
    cmp     eax, [ham_id_gt]
    je      .hce_bin_gt
    cmp     eax, [ham_id_lt]
    je      .hce_bin_lt
    cmp     eax, [ham_id_gte]
    je      .hce_bin_gte
    cmp     eax, [ham_id_lte]
    je      .hce_bin_lte
    cmp     eax, [ham_id_eq]
    je      .hce_bin_eq
    cmp     eax, [ham_id_neq]
    je      .hce_bin_neq
    cmp     eax, [ham_id_and]
    je      .hce_bin_and
    ; Unknown op -> fail
    jmp     .hce_zero

.hce_bin_add:
    mov     byte [rsi + rcx], 0x24
    jmp     .hce_bin_emit
.hce_bin_sub:
    mov     byte [rsi + rcx], 0x25
    jmp     .hce_bin_emit
.hce_bin_gt:
    mov     byte [rsi + rcx], 0x27
    jmp     .hce_bin_emit
.hce_bin_lt:
    mov     byte [rsi + rcx], 0x28
    jmp     .hce_bin_emit
.hce_bin_gte:
    mov     byte [rsi + rcx], 0x29
    jmp     .hce_bin_emit
.hce_bin_lte:
    mov     byte [rsi + rcx], 0x2A
    jmp     .hce_bin_emit
.hce_bin_eq:
    mov     byte [rsi + rcx], 0x2B
    jmp     .hce_bin_emit
.hce_bin_neq:
    mov     byte [rsi + rcx], 0x2C
    jmp     .hce_bin_emit
.hce_bin_and:
    mov     byte [rsi + rcx], 0x2D

.hce_bin_emit:
    inc     ecx
    mov     [rdi], ecx
    jmp     .hce_one

.hce_unary:
    ; Recurse arg: ham_compile_expr(e->unary.arg, buf, pos, bm, buf_size)
    mov     rcx, [rbx + EX_UNARY_ARG]
    mov     rdx, rsi
    mov     r8, rdi
    mov     r9, r12
    mov     dword [rsp + 32], r13d
    call    ham_compile_expr
    test    eax, eax
    jz      .hce_zero
    ; buf[pos++] = 0x2F (NOT)
    mov     eax, [rdi]
    mov     byte [rsi + rax], 0x2F
    inc     eax
    mov     [rdi], eax
    jmp     .hce_one

.hce_one:
    mov     eax, 1
    jmp     .hce_ret
.hce_zero:
    xor     eax, eax
.hce_ret:
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; ham_compile_tension(Tension* t, uint8_t* buf, int* pos, int buf_size) -> int
;
; RCX = t, RDX = buf, R8 = pos, R9d = buf_size
; Returns 1 on success, 0 on failure.
;
; Register plan:
;   RBX = t, RSI = buf, RDI = pos_ptr, R12d = buf_size
;   R13 = current clause pointer (mc/ec), R14 = scratch
;   R15d = loop counter i
;
; Stack locals (sub rsp, 88):
;   [rsp+32..35] = 5th arg slot for ham_compile_expr
;   [rsp+40..75] = HamBindMap (36 bytes)
;   [rsp+76..79] = len_pos
;   [rsp+80..83] = t_start
; ============================================================

%define HCT_5TH   32
%define HCT_BM    40
%define HCT_LEN   76
%define HCT_TST   80

ham_compile_tension:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 88

    ; Save args to callee-saved
    mov     rbx, rcx            ; RBX = t
    mov     rsi, rdx            ; RSI = buf
    mov     rdi, r8             ; RDI = pos_ptr
    mov     r12d, r9d           ; R12d = buf_size

    ; --- Initialize HamBindMap: bm.count = 0 ---
    mov     dword [rsp + HCT_BM + HBM_COUNT], 0

    ; --- Pre-allocate bindings by scanning match clauses ---
    xor     r15d, r15d          ; i = 0
    mov     r14d, [rbx + TEN_MATCH_COUNT]

.hct_prealloc_loop:
    cmp     r15d, r14d
    jge     .hct_prealloc_done

    ; mc = &t->matches[i]
    movsxd  rax, r15d
    imul    rax, SIZEOF_MATCHCLAUSE
    lea     r13, [rbx + TEN_MATCHES + rax]

    ; if (mc->bind_id >= 0) ham_bind_alloc(&bm, mc->bind_id)
    mov     edx, [r13 + MC_BIND_ID]
    test    edx, edx
    js      .hct_prealloc_next

    lea     rcx, [rsp + HCT_BM]
    call    ham_bind_alloc
    test    eax, eax
    js      .hct_fail           ; too many bindings

.hct_prealloc_next:
    inc     r15d
    jmp     .hct_prealloc_loop

.hct_prealloc_done:
    ; --- Save t_start = *pos ---
    mov     eax, [rdi]
    mov     [rsp + HCT_TST], eax

    ; --- Emit THDR: 0x40 + pri(1) + flags(1) + owner(2) + run_ctnr(2) + len_placeholder(2) ---
    mov     ecx, [rdi]          ; pos
    mov     byte [rsi + rcx], 0x40
    inc     ecx

    ; priority (clamped to 255)
    mov     eax, [rbx + TEN_PRIORITY]
    cmp     eax, 255
    jle     .hct_pri_ok
    mov     eax, 255
.hct_pri_ok:
    mov     [rsi + rcx], al
    inc     ecx

    ; flags byte: bit 0 = step_discipline
    mov     eax, [rbp + 48]             ; 5th arg = tension graph index
    lea     rdx, [tension_step_flags]
    mov     eax, [rdx + rax*4]          ; tension_step_flags[ti]
    and     eax, 0xFF
    mov     [rsi + rcx], al
    inc     ecx

    ; owner (u16, 0xFFFF if < 0)
    mov     eax, [rbx + TEN_OWNER]
    test    eax, eax
    jns     .hct_owner_ok
    mov     eax, 0xFFFF
.hct_owner_ok:
    mov     [rsi + rcx], ax     ; u16 LE
    add     ecx, 2

    ; run_container (u16, 0xFFFF if < 0)
    mov     eax, [rbx + TEN_OWNER_RUN_CNT]
    test    eax, eax
    jns     .hct_runcnt_ok
    mov     eax, 0xFFFF
.hct_runcnt_ok:
    mov     [rsi + rcx], ax
    add     ecx, 2

    ; Save len_pos, write placeholder 0
    mov     [rsp + HCT_LEN], ecx
    mov     word [rsi + rcx], 0
    add     ecx, 2
    mov     [rdi], ecx          ; update *pos

    ; ================================================================
    ; COMPILE MATCH CLAUSES
    ; ================================================================
    xor     r15d, r15d          ; i = 0

.hct_mc_loop:
    cmp     r15d, [rbx + TEN_MATCH_COUNT]
    jge     .hct_mc_done

    ; mc = &t->matches[i]
    movsxd  rax, r15d
    imul    rax, SIZEOF_MATCHCLAUSE
    lea     r13, [rbx + TEN_MATCHES + rax]  ; R13 = mc

    mov     eax, [r13 + MC_KIND]

    cmp     eax, MC_ENTITY_IN_V
    je      .hct_mc_entity_in

    cmp     eax, MC_EMPTY_IN_V
    je      .hct_mc_empty_in

    cmp     eax, MC_CONTAINER_IS_V
    je      .hct_mc_container_is

    cmp     eax, MC_GUARD_V
    je      .hct_mc_guard

    ; Unknown kind -> skip (shouldn't happen, compilable checked first)
    jmp     .hct_mc_next

    ; ---- MC_ENTITY_IN ----
.hct_mc_entity_in:
    ; Check scope_bind_id
    mov     eax, [r13 + MC_SCOPE_BIND_ID]
    test    eax, eax
    jns     .hct_mc_ei_scoped

    ; Check channel_idx
    mov     eax, [r13 + MC_CHANNEL_IDX]
    test    eax, eax
    jns     .hct_mc_ei_channel

    ; Normal SCAN: 0x01 + container_idx(u16)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x01
    inc     ecx
    mov     eax, [r13 + MC_CONTAINER_IDX]
    mov     [rsi + rcx], ax     ; u16 LE
    add     ecx, 2
    mov     [rdi], ecx
    jmp     .hct_mc_ei_where

.hct_mc_ei_scoped:
    ; scope_bind_id >= 0: try binding register lookup
    mov     edx, eax            ; scope_bind_id
    lea     rcx, [rsp + HCT_BM]
    call    ham_bind_lookup
    test    eax, eax
    jns     .hct_mc_ei_scoped_bound

    ; Not bound — resolve as global entity name at compile time
    mov     ecx, [r13 + MC_SCOPE_BIND_ID]
    call    graph_find_entity_by_name
    test    eax, eax
    js      .hct_fail
    mov     ecx, eax
    mov     edx, [r13 + MC_SCOPE_CNAME_ID]
    call    get_scoped_container
    test    eax, eax
    js      .hct_fail
    ; Emit SCAN (0x01) + resolved cidx
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x01
    inc     ecx
    mov     [rsi + rcx], ax     ; u16 LE
    add     ecx, 2
    mov     [rdi], ecx
    jmp     .hct_mc_ei_where

.hct_mc_ei_scoped_bound:
    ; Owner is bound — emit SCAN_SCOPED (0x02) + reg(1) + scope_cname_id(2)
    mov     r14d, eax           ; R14d = scope_reg
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x02
    inc     ecx
    mov     [rsi + rcx], r14b   ; reg byte
    inc     ecx
    mov     eax, [r13 + MC_SCOPE_CNAME_ID]
    mov     [rsi + rcx], ax     ; u16 LE
    add     ecx, 2
    mov     [rdi], ecx
    jmp     .hct_mc_ei_where

.hct_mc_ei_channel:
    ; Channel: resolve buffer container
    ; buffer_ctnr = g_graph.channels[channel_idx].buffer_container_idx
    movsxd  rcx, eax            ; channel_idx
    imul    rcx, SIZEOF_CHANNEL
    mov     eax, [g_graph + GRAPH_CHANNELS + rcx + CH_BUFFER]
    ; Emit SCAN (0x01) + buffer_ctnr(u16)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x01
    inc     ecx
    mov     [rsi + rcx], ax     ; u16 LE
    add     ecx, 2
    mov     [rdi], ecx

.hct_mc_ei_where:
    ; WHERE filter (if where_expr && bind_id >= 0)
    mov     rax, [r13 + MC_WHERE_EXPR]
    test    rax, rax
    jz      .hct_mc_ei_select
    mov     r14d, [r13 + MC_BIND_ID]
    test    r14d, r14d
    js      .hct_mc_ei_select

    ; reg = ham_bind_lookup(&bm, bind_id)
    lea     rcx, [rsp + HCT_BM]
    mov     edx, r14d
    call    ham_bind_lookup
    test    eax, eax
    js      .hct_fail

    ; Emit WHERE (0x10) + reg(1)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x10
    inc     ecx
    mov     [rsi + rcx], al     ; reg byte
    inc     ecx
    mov     [rdi], ecx

    ; ham_compile_expr(where_expr, buf, pos, &bm, buf_size)
    mov     rcx, [r13 + MC_WHERE_EXPR]
    mov     rdx, rsi
    mov     r8, rdi
    lea     r9, [rsp + HCT_BM]
    mov     [rsp + HCT_5TH], r12d
    call    ham_compile_expr
    test    eax, eax
    jz      .hct_fail

    ; Emit ENDWHERE (0x11)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x11
    inc     ecx
    mov     [rdi], ecx

.hct_mc_ei_select:
    ; Select mode (if bind_id >= 0)
    mov     eax, [r13 + MC_BIND_ID]
    test    eax, eax
    js      .hct_mc_ei_require

    ; reg = ham_bind_lookup(&bm, bind_id)
    lea     rcx, [rsp + HCT_BM]
    mov     edx, eax
    call    ham_bind_lookup
    test    eax, eax
    js      .hct_fail
    mov     r14d, eax           ; R14d = reg

    mov     eax, [r13 + MC_SELECT]

    cmp     eax, SEL_FIRST_V
    je      .hct_mc_ei_sel_first
    cmp     eax, SEL_MAX_BY_V
    je      .hct_mc_ei_sel_max
    cmp     eax, SEL_MIN_BY_V
    je      .hct_mc_ei_sel_min
    cmp     eax, SEL_EACH_V
    je      .hct_mc_ei_sel_each
    jmp     .hct_mc_ei_require

.hct_mc_ei_sel_first:
    ; SEL_FIRST (0x03) + reg(1)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x03
    inc     ecx
    mov     [rsi + rcx], r14b
    inc     ecx
    mov     [rdi], ecx
    jmp     .hct_mc_ei_require

.hct_mc_ei_sel_max:
    ; SEL_MAX (0x04) + reg(1) + key_prop_id(2)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x04
    inc     ecx
    mov     [rsi + rcx], r14b
    inc     ecx
    mov     eax, [r13 + MC_KEY_PROP_ID]
    mov     [rsi + rcx], ax
    add     ecx, 2
    mov     [rdi], ecx
    jmp     .hct_mc_ei_require

.hct_mc_ei_sel_min:
    ; SEL_MIN (0x05) + reg(1) + key_prop_id(2)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x05
    inc     ecx
    mov     [rsi + rcx], r14b
    inc     ecx
    mov     eax, [r13 + MC_KEY_PROP_ID]
    mov     [rsi + rcx], ax
    add     ecx, 2
    mov     [rdi], ecx
    jmp     .hct_mc_ei_require

.hct_mc_ei_sel_each:
    ; SEL_EACH (0x06) + reg(1)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x06
    inc     ecx
    mov     [rsi + rcx], r14b
    inc     ecx
    mov     [rdi], ecx

.hct_mc_ei_require:
    ; REQUIRE if needed
    cmp     dword [r13 + MC_REQUIRED], 0
    je      .hct_mc_next
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x14
    inc     ecx
    mov     [rdi], ecx
    jmp     .hct_mc_next

    ; ---- MC_EMPTY_IN ----
.hct_mc_empty_in:
    ; ECNT(0x22) + ctnr(u16) + IPUSH(0x20) + 0(i32) + EQ(0x2B) + GUARD(0x12) + ENDGUARD(0x13)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x22
    inc     ecx
    mov     eax, [r13 + MC_CONTAINERS]   ; containers[0]
    mov     [rsi + rcx], ax
    add     ecx, 2
    mov     byte [rsi + rcx], 0x20       ; IPUSH
    inc     ecx
    mov     dword [rsi + rcx], 0         ; i32 = 0
    add     ecx, 4
    mov     byte [rsi + rcx], 0x2B       ; EQ
    inc     ecx
    mov     byte [rsi + rcx], 0x12       ; GUARD
    inc     ecx
    mov     byte [rsi + rcx], 0x13       ; ENDGUARD
    inc     ecx
    mov     [rdi], ecx
    jmp     .hct_mc_next

    ; ---- MC_CONTAINER_IS ----
.hct_mc_container_is:
    ; ECNT(0x22) + guard_ctnr(u16) + IPUSH(0x20) + 0(i32) + [EQ or GT] + GUARD + ENDGUARD
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x22
    inc     ecx
    mov     eax, [r13 + MC_GUARD_CNT_IDX]
    mov     [rsi + rcx], ax
    add     ecx, 2
    mov     byte [rsi + rcx], 0x20       ; IPUSH
    inc     ecx
    mov     dword [rsi + rcx], 0
    add     ecx, 4
    ; is_empty -> EQ (0x2B), else GT (0x27)
    cmp     dword [r13 + MC_IS_EMPTY], 0
    je      .hct_mc_cis_gt
    mov     byte [rsi + rcx], 0x2B       ; EQ
    jmp     .hct_mc_cis_done
.hct_mc_cis_gt:
    mov     byte [rsi + rcx], 0x27       ; GT
.hct_mc_cis_done:
    inc     ecx
    mov     byte [rsi + rcx], 0x12       ; GUARD
    inc     ecx
    mov     byte [rsi + rcx], 0x13       ; ENDGUARD
    inc     ecx
    mov     [rdi], ecx
    jmp     .hct_mc_next

    ; ---- MC_GUARD ----
.hct_mc_guard:
    ; compile guard_expr + GUARD + ENDGUARD
    mov     rcx, [r13 + MC_GUARD_EXPR]
    mov     rdx, rsi
    mov     r8, rdi
    lea     r9, [rsp + HCT_BM]
    mov     [rsp + HCT_5TH], r12d
    call    ham_compile_expr
    test    eax, eax
    jz      .hct_fail

    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x12       ; GUARD
    inc     ecx
    mov     byte [rsi + rcx], 0x13       ; ENDGUARD
    inc     ecx
    mov     [rdi], ecx

.hct_mc_next:
    ; Buffer safety check: if (*pos >= buf_size - 20) return 0
    mov     eax, [rdi]
    mov     ecx, r12d
    sub     ecx, 20
    cmp     eax, ecx
    jge     .hct_fail

    inc     r15d
    jmp     .hct_mc_loop

.hct_mc_done:

    ; ================================================================
    ; COMPILE EMIT CLAUSES
    ; ================================================================
    xor     r15d, r15d          ; i = 0

.hct_ec_loop:
    cmp     r15d, [rbx + TEN_EMIT_COUNT]
    jge     .hct_ec_done

    ; ec = &t->emits[i]
    movsxd  rax, r15d
    imul    rax, SIZEOF_EMITCLAUSE
    lea     r13, [rbx + TEN_EMITS + rax]  ; R13 = ec

    mov     eax, [r13 + EC_KIND]

    cmp     eax, EC_MOVE_V
    je      .hct_ec_move

    cmp     eax, EC_SET_V
    je      .hct_ec_set

    cmp     eax, EC_SEND_V
    je      .hct_ec_send

    cmp     eax, EC_RECEIVE_V
    je      .hct_ec_recv

    ; Unknown kind -> skip
    jmp     .hct_ec_next

    ; ---- EC_MOVE ----
.hct_ec_move:
    ; reg = ham_bind_lookup(&bm, ec->entity_ref)
    lea     rcx, [rsp + HCT_BM]
    mov     edx, [r13 + EC_ENTITY_REF]
    call    ham_bind_lookup
    test    eax, eax
    js      .hct_fail
    mov     r14d, eax           ; R14d = entity reg

    ; Check to_scope_bind_id
    mov     eax, [r13 + EC_TO_SCOPE_BIND_ID]
    test    eax, eax
    jns     .hct_ec_move_scoped

    ; ---- Non-scoped move: resolve container by name ----
    mov     ecx, [r13 + EC_TO_REF]
    call    graph_find_container_by_name
    test    eax, eax
    jns     .hct_ec_move_emit_normal

    ; Not found by name — check match clauses for MC_EMPTY_IN with bind_id == to_ref
    mov     r8d, [r13 + EC_TO_REF]  ; R8d = to_ref
    xor     ecx, ecx               ; mi = 0
.hct_ec_move_search:
    cmp     ecx, [rbx + TEN_MATCH_COUNT]
    jge     .hct_fail               ; still not found -> fail
    ; mc2 = &t->matches[mi]
    movsxd  rax, ecx
    push    rcx                     ; save mi
    imul    rax, SIZEOF_MATCHCLAUSE
    lea     rdx, [rbx + TEN_MATCHES + rax]
    ; if (mc2->kind == MC_EMPTY_IN && mc2->bind_id == to_ref)
    cmp     dword [rdx + MC_KIND], MC_EMPTY_IN_V
    jne     .hct_ec_move_search_next
    cmp     r8d, [rdx + MC_BIND_ID]
    jne     .hct_ec_move_search_next
    ; Found: to_ctnr = mc2->containers[0]
    mov     eax, [rdx + MC_CONTAINERS]
    pop     rcx
    jmp     .hct_ec_move_emit_normal
.hct_ec_move_search_next:
    pop     rcx
    inc     ecx
    jmp     .hct_ec_move_search

.hct_ec_move_emit_normal:
    ; Emit EMOV (0x30) + mt(u16) + reg(1) + to_ctnr(u16)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x30
    inc     ecx
    mov     edx, [r13 + EC_MOVE_TYPE_IDX]
    mov     [rsi + rcx], dx     ; mt u16
    add     ecx, 2
    mov     [rsi + rcx], r14b   ; entity reg
    inc     ecx
    mov     [rsi + rcx], ax     ; to_ctnr u16 (already in EAX)
    add     ecx, 2
    mov     [rdi], ecx
    jmp     .hct_ec_next

.hct_ec_move_scoped:
    ; to_scope_bind_id >= 0: try binding lookup
    mov     edx, eax            ; to_scope_bind_id
    lea     rcx, [rsp + HCT_BM]
    call    ham_bind_lookup
    test    eax, eax
    jns     .hct_ec_move_scoped_bound

    ; Not bound — resolve as global entity at compile time
    mov     ecx, [r13 + EC_TO_SCOPE_BIND_ID]
    call    graph_find_entity_by_name
    test    eax, eax
    js      .hct_fail
    mov     ecx, eax
    mov     edx, [r13 + EC_TO_SCOPE_CNAME_ID]
    call    get_scoped_container
    test    eax, eax
    js      .hct_fail
    ; Emit EMOV (0x30) normal with resolved scoped target
    jmp     .hct_ec_move_emit_normal

.hct_ec_move_scoped_bound:
    ; Owner is bound — emit EMOV_S (0x31) + mt(u16) + entity_reg(1) + owner_reg(1) + scope_cname_id(u16)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x31
    inc     ecx
    mov     edx, [r13 + EC_MOVE_TYPE_IDX]
    mov     [rsi + rcx], dx     ; mt u16
    add     ecx, 2
    mov     [rsi + rcx], r14b   ; entity reg
    inc     ecx
    mov     [rsi + rcx], al     ; owner reg (from ham_bind_lookup result)
    inc     ecx
    mov     edx, [r13 + EC_TO_SCOPE_CNAME_ID]
    mov     [rsi + rcx], dx     ; scope_cname_id u16
    add     ecx, 2
    mov     [rdi], ecx
    jmp     .hct_ec_next

    ; ---- EC_SET ----
.hct_ec_set:
    ; reg = ham_bind_lookup(&bm, ec->set_entity_ref)
    lea     rcx, [rsp + HCT_BM]
    mov     edx, [r13 + EC_SET_ENTITY_REF]
    call    ham_bind_lookup
    test    eax, eax
    js      .hct_fail
    mov     r14d, eax           ; R14d = reg

    ; ham_compile_expr(ec->value_expr, buf, pos, &bm, buf_size)
    mov     rcx, [r13 + EC_VALUE_EXPR]
    mov     rdx, rsi
    mov     r8, rdi
    lea     r9, [rsp + HCT_BM]
    mov     [rsp + HCT_5TH], r12d
    call    ham_compile_expr
    test    eax, eax
    jz      .hct_fail

    ; Emit ESET (0x32) + reg(1) + prop_id(u16)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x32
    inc     ecx
    mov     [rsi + rcx], r14b   ; reg
    inc     ecx
    mov     eax, [r13 + EC_SET_PROP_ID]
    mov     [rsi + rcx], ax     ; prop_id u16
    add     ecx, 2
    mov     [rdi], ecx
    jmp     .hct_ec_next

    ; ---- EC_SEND ----
.hct_ec_send:
    ; reg = ham_bind_lookup(&bm, ec->send_entity_ref)
    lea     rcx, [rsp + HCT_BM]
    mov     edx, [r13 + EC_SEND_ENTITY_REF]
    call    ham_bind_lookup
    test    eax, eax
    js      .hct_fail
    mov     r14d, eax           ; R14d = reg

    ; Emit ESEND (0x33) + channel_idx(u16) + reg(1)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x33
    inc     ecx
    mov     eax, [r13 + EC_SEND_CHANNEL_IDX]
    mov     [rsi + rcx], ax     ; channel_idx u16
    add     ecx, 2
    mov     [rsi + rcx], r14b   ; reg
    inc     ecx
    mov     [rdi], ecx
    jmp     .hct_ec_next

    ; ---- EC_RECEIVE ----
.hct_ec_recv:
    ; entity_reg = ham_bind_lookup(&bm, ec->recv_entity_ref)
    lea     rcx, [rsp + HCT_BM]
    mov     edx, [r13 + EC_RECV_ENTITY_REF]
    call    ham_bind_lookup
    test    eax, eax
    js      .hct_fail
    mov     r14d, eax           ; R14d = entity_reg

    ; Check recv_to_scope_bind_id
    mov     eax, [r13 + EC_RECV_TO_SCOPE_BIND_ID]
    test    eax, eax
    js      .hct_fail           ; non-scoped receive not implemented

    ; owner_reg = ham_bind_lookup(&bm, recv_to_scope_bind_id)
    lea     rcx, [rsp + HCT_BM]
    mov     edx, eax
    call    ham_bind_lookup
    test    eax, eax
    js      .hct_fail           ; owner not bound -> fail

    ; Emit ERECV_S (0x35) + channel_idx(u16) + entity_reg(1) + owner_reg(1) + scope_cname_id(u16)
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x35
    inc     ecx
    mov     edx, [r13 + EC_RECV_CHANNEL_IDX]
    mov     [rsi + rcx], dx     ; channel_idx u16
    add     ecx, 2
    mov     [rsi + rcx], r14b   ; entity_reg
    inc     ecx
    mov     [rsi + rcx], al     ; owner_reg
    inc     ecx
    mov     edx, [r13 + EC_RECV_TO_SCOPE_CNAME_ID]
    mov     [rsi + rcx], dx     ; scope_cname_id u16
    add     ecx, 2
    mov     [rdi], ecx

.hct_ec_next:
    ; Buffer safety: if (*pos >= buf_size - 10) return 0
    mov     eax, [rdi]
    mov     ecx, r12d
    sub     ecx, 10
    cmp     eax, ecx
    jge     .hct_fail

    inc     r15d
    jmp     .hct_ec_loop

.hct_ec_done:

    ; --- Emit TEND (0x41) ---
    mov     ecx, [rdi]
    mov     byte [rsi + rcx], 0x41
    inc     ecx
    mov     [rdi], ecx

    ; --- Patch tension_len ---
    mov     eax, ecx            ; *pos (current)
    sub     eax, [rsp + HCT_TST]   ; t_len = *pos - t_start
    mov     ecx, [rsp + HCT_LEN]   ; len_pos
    mov     [rsi + rcx], ax         ; patch u16 LE

    ; Return 1 (success)
    mov     eax, 1
    jmp     .hct_ret

.hct_fail:
    xor     eax, eax
.hct_ret:
    add     rsp, 88
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
; ham_compile_all(uint8_t* buf, int buf_size, int* out_count) -> int
;
; RCX = buf, EDX = buf_size, R8 = out_count
; Returns total bytecode bytes written.
; *out_count is set to number of tensions compiled.
;
; Register plan:
;   RBX = buf, R12d = buf_size, R13d = compiled count
;   R14d = main loop i, R15d = n (tension_count)
;
; Stack locals (sub rsp, 1112):
;   [rsp+32..1055]   = int order[256] (1024 bytes)
;   [rsp+1056..1059] = pos (int, passed by pointer to ham_compile_tension)
;   [rsp+1060..1063] = save_pos (int)
;   [rsp+1064..1071] = out_count pointer (8 bytes, saved)
;   [rsp+1072..1075] = tmpcidx (spawn diagnostic temp)
;   [rsp+1076..1079] = tmpj (spawn diagnostic temp)
;   [rsp+1080..1103] = tmpbuf (24 bytes, snprintf scratch)
;   Alignment: 8 pushes=64, 8+64+1112=1184, 1184%16=0 ✓
; ============================================================

%define HCA_ORDER     32
%define HCA_POS       1056
%define HCA_SAVE_POS  1060
%define HCA_OUTCOUNT  1064
%define HCA_TMPCIDX   1072
%define HCA_TMPJ      1076
%define HCA_TMPBUF    1080
%define HCA_FRAME     1112

ham_compile_all:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, HCA_FRAME

    ; Save args
    mov     rbx, rcx            ; RBX = buf
    mov     r12d, edx           ; R12d = buf_size
    mov     [rsp + HCA_OUTCOUNT], r8  ; save out_count pointer

    ; --- ham_init_op_ids() ---
    call    ham_init_op_ids

    ; --- Build order[] array: order[i] = i ---
    mov     r15d, [g_tension_count]  ; R15d = n
    xor     ecx, ecx
.hca_init_order:
    cmp     ecx, r15d
    jge     .hca_sort
    mov     [rsp + HCA_ORDER + rcx*4], ecx
    inc     ecx
    jmp     .hca_init_order

.hca_sort:
    ; --- Bubble sort descending by priority ---
    xor     esi, esi            ; ESI = i

.hca_sort_i:
    lea     eax, [esi + 1]
    cmp     eax, r15d
    jge     .hca_sort_done

    mov     edi, esi
    inc     edi                 ; EDI = j = i+1

.hca_sort_j:
    cmp     edi, r15d
    jge     .hca_sort_i_next

    movsxd  rax, dword [rsp + HCA_ORDER + rsi*4]
    imul    rax, SIZEOF_TENSION
    mov     ecx, [g_tensions + rax + TEN_PRIORITY]

    movsxd  rax, dword [rsp + HCA_ORDER + rdi*4]
    imul    rax, SIZEOF_TENSION
    mov     edx, [g_tensions + rax + TEN_PRIORITY]

    cmp     ecx, edx
    jge     .hca_sort_j_next

    mov     eax, [rsp + HCA_ORDER + rsi*4]
    mov     ecx, [rsp + HCA_ORDER + rdi*4]
    mov     [rsp + HCA_ORDER + rsi*4], ecx
    mov     [rsp + HCA_ORDER + rdi*4], eax

.hca_sort_j_next:
    inc     edi
    jmp     .hca_sort_j

.hca_sort_i_next:
    inc     esi
    jmp     .hca_sort_i

.hca_sort_done:
    ; --- Initialize pos = 0, compiled = 0 ---
    mov     dword [rsp + HCA_POS], 0
    xor     r13d, r13d          ; compiled = 0
    xor     r14d, r14d          ; i = 0

    ; ================================================================
    ; MAIN COMPILE LOOP
    ; ================================================================
.hca_loop:
    cmp     r14d, r15d
    jge     .hca_done

    ; t = &g_graph.tensions[order[i]]
    movsxd  rax, dword [rsp + HCA_ORDER + r14*4]
    imul    rax, SIZEOF_TENSION
    lea     rdi, [g_tensions + rax]  ; RDI = t (callee-saved)

    ; if (!ham_tension_compilable(t)) continue
    mov     rcx, rdi
    call    ham_tension_compilable
    test    eax, eax
    jz      .hca_loop_next

    ; --- Spawn diagnostic: if name starts with "spa" ---
    mov     ecx, [rdi + TEN_NAME_ID]
    call    str_of
    cmp     byte [rax], 's'
    jne     .hca_no_spawn_diag
    cmp     byte [rax + 1], 'p'
    jne     .hca_no_spawn_diag
    cmp     byte [rax + 2], 'a'
    jne     .hca_no_spawn_diag

    ; Print "  [HAM] Compiling <name>"
    lea     rcx, [hc_ham_diag]
    call    serial_print
    mov     ecx, [rdi + TEN_NAME_ID]
    call    str_of
    mov     rcx, rax
    call    serial_print

    ; Print match clause container info (ESI = j, RDI = t preserved)
    xor     esi, esi
.hca_spawn_mc_loop:
    cmp     esi, [rdi + TEN_MATCH_COUNT]
    jge     .hca_spawn_mc_done

    movsxd  rax, esi
    imul    rax, SIZEOF_MATCHCLAUSE
    lea     rax, [rdi + TEN_MATCHES + rax]

    cmp     dword [rax + MC_KIND], MC_ENTITY_IN_V
    jne     .hca_spawn_mc_next2
    mov     ecx, [rax + MC_CONTAINER_IDX]
    test    ecx, ecx
    js      .hca_spawn_mc_next2

    ; Save cidx and j to dedicated temp slots
    mov     [rsp + HCA_TMPCIDX], ecx
    mov     [rsp + HCA_TMPJ], esi

    lea     rcx, [hc_ham_mc]
    call    serial_print

    ; Print j
    mov     esi, [rsp + HCA_TMPJ]
    lea     rcx, [rsp + HCA_TMPBUF]
    mov     edx, 24
    lea     r8, [hc_intfmt]
    mov     r9d, esi
    call    herb_snprintf
    lea     rcx, [rsp + HCA_TMPBUF]
    call    serial_print

    lea     rcx, [hc_ham_eq2]
    call    serial_print

    ; Print cidx
    mov     eax, [rsp + HCA_TMPCIDX]
    lea     rcx, [rsp + HCA_TMPBUF]
    mov     edx, 24
    lea     r8, [hc_intfmt]
    mov     r9d, eax
    call    herb_snprintf
    lea     rcx, [rsp + HCA_TMPBUF]
    call    serial_print

    lea     rcx, [hc_ham_lp]
    call    serial_print

    ; Print container name
    movsxd  rax, dword [rsp + HCA_TMPCIDX]
    imul    rax, SIZEOF_CONTAINER
    mov     ecx, [g_graph + GRAPH_CONTAINERS + rax + CNT_NAME_ID]
    call    str_of
    mov     rcx, rax
    call    serial_print

    lea     rcx, [hc_ham_rp]
    call    serial_print

    ; Restore j
    mov     esi, [rsp + HCA_TMPJ]

.hca_spawn_mc_next2:
    inc     esi
    jmp     .hca_spawn_mc_loop

.hca_spawn_mc_done:
    lea     rcx, [hc_newline]
    call    serial_print

.hca_no_spawn_diag:
    ; --- Print "  [COMP] <name>" ---
    lea     rcx, [hc_comp_pfx]
    call    serial_print
    mov     ecx, [rdi + TEN_NAME_ID]
    call    str_of
    mov     rcx, rax
    call    serial_print

    ; --- save_pos = pos ---
    mov     eax, [rsp + HCA_POS]
    mov     [rsp + HCA_SAVE_POS], eax

    ; --- ham_compile_tension(t, buf, &pos, buf_size, tension_idx) ---
    mov     rcx, rdi            ; t
    mov     rdx, rbx            ; buf
    lea     r8, [rsp + HCA_POS] ; &pos
    mov     r9d, r12d           ; buf_size
    mov     eax, [rsp + HCA_ORDER + r14*4]
    mov     [rsp + 32], eax     ; 5th arg = tension graph index
    call    ham_compile_tension
    test    eax, eax
    jz      .hca_compile_fail

    ; --- Success: compiled++, print " OK len=X\n" ---
    inc     r13d
    mov     eax, [rsp + HCA_POS]
    sub     eax, [rsp + HCA_SAVE_POS]

    lea     rcx, [rsp + HCA_TMPBUF]
    mov     edx, 24
    lea     r8, [hc_comp_ok]
    mov     r9d, eax
    call    herb_snprintf
    lea     rcx, [rsp + HCA_TMPBUF]
    call    serial_print
    jmp     .hca_loop_next

.hca_compile_fail:
    ; --- Failure: rollback pos, print " FAIL\n" ---
    mov     eax, [rsp + HCA_SAVE_POS]
    mov     [rsp + HCA_POS], eax
    lea     rcx, [hc_comp_fail]
    call    serial_print

.hca_loop_next:
    inc     r14d
    jmp     .hca_loop

.hca_done:
    ; --- Write *out_count = compiled ---
    mov     rax, [rsp + HCA_OUTCOUNT]
    test    rax, rax
    jz      .hca_no_outcount
    mov     [rax], r13d
.hca_no_outcount:

    ; --- Return pos ---
    mov     eax, [rsp + HCA_POS]

    add     rsp, HCA_FRAME
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret
