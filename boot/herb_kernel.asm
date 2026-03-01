; boot/herb_kernel.asm — HERB OS Kernel Entry (Phase A)
;
; Assembly implementation of kernel_main(): the OS entry point and main loop.
; All ~60 remaining C functions in kernel_main.c are called as leaves from here.
;
; This file contains:
;   - kernel_main (global, called by kernel_entry.asm)
;   - idt_set_gate (local subroutine)
;   - idt_install (local subroutine)
;
; Assembly controls the top of the call graph.
; C functions (draw_full, handle_key, cmd_timer, etc.) are leaf callees.
;
; Assembled with: nasm -f win64 [-DKERNEL_MODE] [-DGRAPHICS_MODE] herb_kernel.asm
;
; MS x64 ABI: RCX/RDX/R8/R9 args, 32-byte shadow, RAX return
; Callee-saved: RBX, RSI, RDI, R12-R15, RBP

[bits 64]
default rel

; ============================================================
; EXTERNS — Assembly runtime functions
; ============================================================

; HERB runtime API (from assembly files)
extern herb_init
extern herb_load
extern herb_create
extern herb_set_prop_int
extern herb_container_count
extern herb_container_entity
extern herb_entity_prop_int
extern herb_entity_name
extern herb_arena_usage
extern herb_arena_total
extern herb_tension_count
extern herb_create_container
extern herb_load_program
extern ham_run_ham

; Hardware functions (from herb_hw.asm)
extern serial_init
extern serial_print
extern pic_remap
extern pit_init
extern mouse_init
extern hw_lidt
extern hw_sti
extern hw_hlt

; Utility (from herb_freestanding.asm)
extern herb_snprintf
extern herb_memset

; ISR stubs (from kernel_entry.asm)
extern timer_isr_stub
extern keyboard_isr_stub
extern mouse_isr_stub

; Volatile flags set by ISRs (from kernel_entry.asm)
extern volatile_timer_fired
extern volatile_key_scancode
extern volatile_key_pressed
extern mouse_ring
extern mouse_ring_head
extern mouse_ring_tail

; ============================================================
; EXTERNS — C functions remaining in kernel_main.c
; ============================================================

extern vga_set_color
extern vga_clear
extern vga_print
extern vga_print_int
extern serial_print_int
extern draw_full
extern draw_stats
extern handle_key
extern mouse_handle_packet
extern cmd_timer
extern herb_error_handler

%ifdef KERNEL_MODE
extern cmd_click
extern cmd_tension_toggle
%endif

%ifdef GRAPHICS_MODE
extern gfx_draw_stats_only
extern km_fb_init
extern km_fb_clear_bg
extern km_fb_flip
extern km_fb_cursor_erase
extern km_fb_cursor_draw
extern km_fb_get_active
extern km_set_cursor
%endif

; ============================================================
; EXTERNS — Globals from kernel_main.c
; ============================================================

extern timer_count
extern total_ops
extern signal_counter
extern process_counter
extern buffer_eid
extern last_action
extern last_key_name
extern mouse_x
extern mouse_y
extern mouse_cycle
extern mouse_packet
extern mouse_buttons
extern mouse_left_clicked
extern mouse_moved
extern cursor_eid
extern selected_tension_idx

%ifdef KERNEL_MODE
extern input_ctl_eid
extern shell_ctl_eid
extern shell_eid
extern spawn_ctl_eid
extern game_ctl_eid
extern player_eid
extern display_ctl_eid
extern timer_interval
extern buffer_capacity
%endif

%ifdef GRAPHICS_MODE
extern selected_eid
%endif

; ============================================================
; EXTERNS — Program data (from generated headers, linked from C)
; ============================================================

extern program_data
extern program_data_len

%ifdef KERNEL_MODE
extern program_shell
extern program_shell_len
extern program_producer
extern program_producer_len
extern program_consumer
extern program_consumer_len
%endif

; ============================================================
; GLOBAL
; ============================================================

global kernel_main

; ============================================================
; BSS — IDT data
; ============================================================

section .bss

align 16
idt:        resb 4096       ; 256 entries * 16 bytes each
idt_ptr:    resb 10         ; 2-byte limit + 8-byte base

; ============================================================
; RDATA — String literals
; ============================================================

section .rdata

%ifdef KERNEL_MODE
str_boot_banner:    db "HERB OS v3 - Four-Module Kernel", 10, 0
str_vga_banner:     db "HERB OS - Four-Module Kernel (proc+mem+fs+ipc)", 10, 0
%else
str_boot_banner:    db "HERB OS v2 - Interactive", 10, 0
str_vga_banner:     db "HERB OS - Interactive Bare Metal Runtime", 10, 0
%endif

str_init_msg:       db "Initializing...", 10, 10, 0
str_arena_msg:      db "  Arena: 4MB at 0x800000", 10, 0
str_runtime_init:   db "  Runtime initialized", 10, 0
str_loading:        db "  Loading program (", 0
str_bytes_msg:      db " bytes)...", 10, 0
str_prog_loaded:    db "  Program loaded", 10, 0
str_fatal_load:     db "  FATAL: Program load failed!", 10, 0
str_vga_fatal:      db 10, "  FATAL: Program load failed!", 10, 0
str_resolve_msg:    db "  Resolving initial tensions...", 10, 0
str_equil_msg:      db "  Equilibrium reached (", 0
str_equil_end:      db " ops)", 10, 0
str_boot_ops:       db "  Boot: ", 0
str_ops_nl:         db " ops", 10, 0
str_start_msg:      db 10, "Starting interactive mode...", 10, 0
str_serial_start:   db "Starting interactive mode", 10, 0
str_mouse_init:     db "  Mouse initialized (IRQ12)", 10, 0

%ifdef GRAPHICS_MODE
str_fb_detect:      db "  Framebuffer: detecting BGA...", 10, 0
str_fb_ok:          db "  Framebuffer: 800x600x32 OK", 10, 0
str_fb_serial_ok:   db "  Framebuffer: 800x600x32 initialized", 10, 0
str_fb_fail_fmt:    db "  Framebuffer: init failed (rc=%d), using text mode", 10, 0
%endif

; Boot message format for last_action
str_boot_action:    db "Booted with %d ops. Press / to type commands.", 0

%ifdef KERNEL_MODE
; Entity discovery messages
str_cursor_found:   db "  Cursor entity found (id=", 0
str_input_found:    db "  Input control entity found (id=", 0
str_shell_created:  db "  Shell process created (id=", 0
str_shell_tens:     db ", tensions=", 0
str_shellctl_found: db "  Shell control entity found (id=", 0
str_spawnctl_found: db "  Spawn control entity found (id=", 0
str_dispctl_found:  db "  Display control entity found (id=", 0
str_gamectl_found:  db "  Game control entity found (id=", 0
str_player_found:   db "  Player entity found (id=", 0
str_close_paren_nl: db ")", 10, 0
str_buf_created:    db "  Buffer created (capacity=", 0
str_timer_intv:     db "  timer_interval=", 0
str_buf_cap:        db " buffer_capacity=", 0
str_newline:        db 10, 0

; Property name strings
str_kind:           db "kind", 0
str_priority:       db "priority", 0
str_time_slice:     db "time_slice", 0
str_msgs_received:  db "msgs_received", 0
str_selected:       db "selected", 0
str_protected:      db "protected", 0
str_count:          db "count", 0
str_capacity:       db "capacity", 0
str_state:          db "state", 0
str_border_color:   db "border_color", 0
str_fill_color:     db "fill_color", 0
str_action:         db "action", 0
str_shell_protected: db "shell_protected", 0
str_timer_interval: db "timer_interval", 0
str_buffer_capacity: db "buffer_capacity", 0
str_display_mode:   db "display_mode", 0
str_panel_click:    db "panel_click", 0
str_x:              db "x", 0
str_y:              db "y", 0

; Entity/container name strings
str_shared_buffer:  db "shared_buffer", 0
str_shell:          db "shell", 0
str_pg0_shell:      db "pg0_shell", 0
str_fd0_shell:      db "fd0_shell", 0
str_surf_shell:     db "surf_shell", 0
str_shell_mem_free: db "shell::MEM_FREE", 0
str_shell_fd_free:  db "shell::FD_FREE", 0
str_shell_surface:  db "shell::SURFACE", 0

; Container name macros are string literals — replicate them here
str_cn_visible:     db "display.VISIBLE", 0
str_cn_input_state: db "input.INPUT_STATE", 0
str_cn_buffer:      db "BUFFER", 0
str_cn_ready:       db "proc.READY", 0
str_cn_shell_state: db "input.SHELL_STATE", 0
str_cn_spawn_state: db "spawn.SPAWN_STATE", 0
str_cn_display_state: db "display.DISPLAY_STATE", 0
str_cn_game_state:  db "world.GAME_STATE", 0
str_cn_game_player: db "world.PLAYER", 0
str_cn_cpu0:        db "proc.CPU0", 0

; Empty string for run_container=""
str_empty:          db 0

; Type name strings
str_et_buffer:      db "Buffer", 0
str_et_process:     db "proc.Process", 0
str_et_page:        db "mem.Page", 0
str_et_fd:          db "fs.FileDescriptor", 0
str_et_surface:     db "display.Surface", 0
%endif  ; KERNEL_MODE

; ============================================================
; TEXT — Code
; ============================================================

section .text

; ============================================================
; idt_set_gate — Set an IDT entry
;
; Args: ECX = vector number, RDX = handler address
; Clobbers: RAX, R8, R9
; ============================================================

idt_set_gate:
    ; IDTEntry is 16 bytes: offset_low(2) selector(2) ist(1) type_attr(1) offset_mid(2) offset_high(4) reserved(4)
    lea rax, [rel idt]
    shl ecx, 4                     ; ecx * 16 = byte offset
    add rax, rcx

    ; offset_low = handler & 0xFFFF
    mov word [rax], dx

    ; selector = 0x18 (64-bit code segment)
    mov word [rax + 2], 0x18

    ; ist = 0
    mov byte [rax + 4], 0

    ; type_attr = 0x8E (present, ring 0, 64-bit interrupt gate)
    mov byte [rax + 5], 0x8E

    ; offset_mid = (handler >> 16) & 0xFFFF
    mov r8, rdx
    shr r8, 16
    mov word [rax + 6], r8w

    ; offset_high = (handler >> 32) & 0xFFFFFFFF
    mov r8, rdx
    shr r8, 32
    mov dword [rax + 8], r8d

    ; reserved = 0
    mov dword [rax + 12], 0

    ret

; ============================================================
; idt_install — Load IDT register
;
; No args. Uses idt and idt_ptr BSS data.
; ============================================================

idt_install:
    push rbp
    mov rbp, rsp
    sub rsp, 32                     ; shadow space

    ; idt_ptr.limit = sizeof(idt) - 1 = 4095
    lea rax, [rel idt_ptr]
    mov word [rax], 4095

    ; idt_ptr.base = &idt
    lea rcx, [rel idt]
    mov qword [rax + 2], rcx

    ; hw_lidt(&idt_ptr)
    lea rcx, [rel idt_ptr]
    call hw_lidt

    leave
    ret

; ============================================================
; kernel_main — OS entry point
;
; Called by kernel_entry.asm after entering 64-bit long mode.
; Never returns.
;
; Stack frame layout (after push rbp + 7 callee-saved regs):
;   [RBP-0]   = saved RBP
;   Callee-saved: RBX, RSI, RDI, R12, R13, R14, R15 (56 bytes)
;   Return addr (8 bytes) + 8 pushes (64 bytes) = 72 bytes above RSP
;   sub rsp, 280 => (72 + 280) = 352, 352 % 16 = 0 ✓
;
; Local variable slots (offsets from RSP):
;   [RSP+0..31]    = shadow space for callees
;   [RSP+32..95]   = errbuf (64 bytes)
;   [RSP+96..159]  = cname (64 bytes)
;   [RSP+160..223] = rname (64 bytes)
;   [RSP+224..255] = sig_name (32 bytes)
;   [RSP+256..263] = boot_ops (8 bytes)
;   [RSP+264..271] = temp storage (8 bytes)
; ============================================================

%define LOCAL_SIZE  280
%define ERRBUF      32
%define CNAME       96
%define RNAME       160
%define SIGNAME     224
%define BOOT_OPS    256
%define TEMP1       264

kernel_main:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, LOCAL_SIZE

    ; ================================================================
    ; SERIAL INIT
    ; ================================================================

    call serial_init

    lea rcx, [rel str_boot_banner]
    call serial_print

    ; ================================================================
    ; VGA SETUP (always init for boot messages)
    ; ================================================================

    ; vga_set_color(VGA_WHITE=0x0F, VGA_BLACK=0x00)
    mov ecx, 0x0F
    xor edx, edx
    call vga_set_color

    call vga_clear

    ; vga_set_color(VGA_CYAN=0x03, VGA_BLACK=0x00)
    mov ecx, 0x03
    xor edx, edx
    call vga_set_color

    lea rcx, [rel str_vga_banner]
    call vga_print

    ; vga_set_color(VGA_LGRAY=0x07, VGA_BLACK=0x00)
    mov ecx, 0x07
    xor edx, edx
    call vga_set_color

    lea rcx, [rel str_init_msg]
    call vga_print

    ; ================================================================
    ; GRAPHICS MODE: Initialize BGA framebuffer
    ; ================================================================

%ifdef GRAPHICS_MODE
    lea rcx, [rel str_fb_detect]
    call vga_print
    lea rcx, [rel str_fb_detect]
    call serial_print

    call km_fb_init
    test eax, eax
    jnz .fb_fail

    ; Success
    lea rcx, [rel str_fb_ok]
    call vga_print
    lea rcx, [rel str_fb_serial_ok]
    call serial_print

    ; fb_clear(COL_BG) + fb_flip()
    call km_fb_clear_bg
    call km_fb_flip
    jmp .fb_done

.fb_fail:
    ; Format error message into errbuf
    lea rcx, [rsp + ERRBUF]
    mov edx, 64
    lea r8, [rel str_fb_fail_fmt]
    mov r9d, eax
    call herb_snprintf

    lea rcx, [rsp + ERRBUF]
    call vga_print
    lea rcx, [rsp + ERRBUF]
    call serial_print

.fb_done:
%endif  ; GRAPHICS_MODE

    ; ================================================================
    ; INITIALIZE HERB RUNTIME
    ; ================================================================

    lea rcx, [rel str_arena_msg]
    call vga_print

    ; herb_init((void*)0x800000, 4*1024*1024, herb_error_handler)
    mov ecx, 0x800000
    mov edx, 4 * 1024 * 1024
    lea r8, [rel herb_error_handler]
    call herb_init

    lea rcx, [rel str_runtime_init]
    call vga_print
    lea rcx, [rel str_runtime_init]
    call serial_print

    ; ================================================================
    ; LOAD EMBEDDED PROGRAM
    ; ================================================================

    lea rcx, [rel str_loading]
    call vga_print

    ; vga_print_int((int)program_data_len)
    lea rax, [rel program_data_len]
    mov ecx, dword [rax]
    call vga_print_int

    lea rcx, [rel str_bytes_msg]
    call vga_print

    ; rc = herb_load((const char*)program_data, program_data_len)
    lea rcx, [rel program_data]
    lea rax, [rel program_data_len]
    mov edx, dword [rax]
    call herb_load

    test eax, eax
    jnz .load_failed

    lea rcx, [rel str_prog_loaded]
    call vga_print
    lea rcx, [rel str_prog_loaded]
    call serial_print
    jmp .load_ok

.load_failed:
    mov ecx, 0x04                  ; VGA_RED
    xor edx, edx
    call vga_set_color

    lea rcx, [rel str_vga_fatal]
    call vga_print
    lea rcx, [rel str_fatal_load]
    call serial_print

.halt_forever:
    call hw_hlt
    jmp .halt_forever

.load_ok:

    ; ================================================================
    ; BOOT: RESOLVE INITIAL TENSIONS
    ; ================================================================

    lea rcx, [rel str_resolve_msg]
    call vga_print

    ; boot_ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov [rsp + BOOT_OPS], eax       ; save boot_ops
    mov rbx, rax                    ; also keep in RBX

    ; total_ops = boot_ops
    lea rax, [rel total_ops]
    mov dword [rax], ebx

    ; vga_print("  Equilibrium reached (")
    lea rcx, [rel str_equil_msg]
    call vga_print

    ; vga_print_int(boot_ops)
    mov ecx, ebx
    call vga_print_int

    ; vga_print(" ops)\n")
    lea rcx, [rel str_equil_end]
    call vga_print

    ; serial_print("  Boot: ")
    lea rcx, [rel str_boot_ops]
    call serial_print

    ; serial_print_int(boot_ops)
    mov ecx, ebx
    call serial_print_int

    ; serial_print(" ops\n")
    lea rcx, [rel str_ops_nl]
    call serial_print

    ; ================================================================
    ; KERNEL_MODE: Entity discovery + shell process creation
    ; ================================================================

%ifdef KERNEL_MODE

    ; ---- Find cursor Surface entity in display.VISIBLE (kind=2) ----
    lea rcx, [rel str_cn_visible]
    call herb_container_count
    mov r12d, eax                   ; r12 = nv
    xor r13d, r13d                  ; r13 = i = 0

.cursor_loop:
    cmp r13d, r12d
    jge .cursor_done

    lea rcx, [rel str_cn_visible]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .cursor_next

    mov r14d, eax                   ; r14 = sid

    ; herb_entity_prop_int(sid, "kind", -1)
    mov ecx, r14d
    lea rdx, [rel str_kind]
    mov r8, -1
    call herb_entity_prop_int
    cmp eax, 2
    jne .cursor_next

    ; Found cursor entity
    lea rcx, [rel cursor_eid]
    mov dword [rcx], r14d

    lea rcx, [rel str_cursor_found]
    call serial_print
    mov ecx, r14d
    call serial_print_int
    lea rcx, [rel str_close_paren_nl]
    call serial_print
    jmp .cursor_done

.cursor_next:
    inc r13d
    jmp .cursor_loop

.cursor_done:

    ; ---- Find InputCtl entity in input.INPUT_STATE ----
    lea rcx, [rel str_cn_input_state]
    call herb_container_count
    mov r12d, eax
    xor r13d, r13d

.input_loop:
    cmp r13d, r12d
    jge .input_done

    lea rcx, [rel str_cn_input_state]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .input_next

    lea rcx, [rel input_ctl_eid]
    mov dword [rcx], eax

    push rax
    lea rcx, [rel str_input_found]
    call serial_print
    pop rax
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_close_paren_nl]
    call serial_print
    jmp .input_done

.input_next:
    inc r13d
    jmp .input_loop

.input_done:

    ; ---- Create shared BUFFER container and entity ----
    lea rcx, [rel str_cn_buffer]
    xor edx, edx                    ; CK_SIMPLE = 0
    call herb_create_container

    lea rcx, [rel str_shared_buffer]
    lea rdx, [rel str_et_buffer]
    lea r8, [rel str_cn_buffer]
    call herb_create

    lea rcx, [rel buffer_eid]
    mov dword [rcx], eax

    test eax, eax
    js .buffer_done

    mov r12d, eax                   ; r12 = buffer_eid

    ; herb_set_prop_int(buffer_eid, "count", 0)
    mov ecx, r12d
    lea rdx, [rel str_count]
    xor r8d, r8d
    call herb_set_prop_int

    ; herb_set_prop_int(buffer_eid, "capacity", buffer_capacity)
    mov ecx, r12d
    lea rdx, [rel str_capacity]
    lea rax, [rel buffer_capacity]
    mov r8d, dword [rax]
    call herb_set_prop_int

    lea rcx, [rel str_buf_created]
    call serial_print
    lea rax, [rel buffer_capacity]
    mov ecx, dword [rax]
    call serial_print_int
    lea rcx, [rel str_close_paren_nl]
    call serial_print

.buffer_done:

    ; ---- Create Shell process ----
    lea rcx, [rel str_shell]
    lea rdx, [rel str_et_process]
    lea r8, [rel str_cn_ready]
    call herb_create

    lea rcx, [rel shell_eid]
    mov dword [rcx], eax
    test eax, eax
    js .shell_done

    mov r12d, eax                   ; r12 = shell_eid

    ; Set properties: priority=0, time_slice=3, msgs_received=0, selected=0
    mov ecx, r12d
    lea rdx, [rel str_priority]
    xor r8d, r8d
    call herb_set_prop_int

    mov ecx, r12d
    lea rdx, [rel str_time_slice]
    mov r8d, 3
    call herb_set_prop_int

    mov ecx, r12d
    lea rdx, [rel str_msgs_received]
    xor r8d, r8d
    call herb_set_prop_int

    mov ecx, r12d
    lea rdx, [rel str_selected]
    xor r8d, r8d
    call herb_set_prop_int

    ; ---- Shell scoped resources: MEM_FREE page, FD_FREE fd ----

    ; herb_create("pg0_shell", ET_PAGE, "shell::MEM_FREE")
    lea rcx, [rel str_pg0_shell]
    lea rdx, [rel str_et_page]
    lea r8, [rel str_shell_mem_free]
    call herb_create

    ; herb_create("fd0_shell", ET_FD, "shell::FD_FREE")
    lea rcx, [rel str_fd0_shell]
    lea rdx, [rel str_et_fd]
    lea r8, [rel str_shell_fd_free]
    call herb_create

    ; ---- Shell display Surface ----
    ; sid = herb_create("surf_shell", ET_SURFACE, "shell::SURFACE")
    lea rcx, [rel str_surf_shell]
    lea rdx, [rel str_et_surface]
    lea r8, [rel str_shell_surface]
    call herb_create

    test eax, eax
    js .shell_surf_done

    mov r13d, eax                   ; r13 = sid

    mov ecx, r13d
    lea rdx, [rel str_kind]
    mov r8d, 1
    call herb_set_prop_int

    mov ecx, r13d
    lea rdx, [rel str_state]
    xor r8d, r8d
    call herb_set_prop_int

    mov ecx, r13d
    lea rdx, [rel str_border_color]
    xor r8d, r8d
    call herb_set_prop_int

    mov ecx, r13d
    lea rdx, [rel str_fill_color]
    xor r8d, r8d
    call herb_set_prop_int

.shell_surf_done:

    ; ---- Load shell behavior from .herb binary ----
    ; herb_load_program(program_shell, program_shell_len, shell_eid, "")
    lea rcx, [rel program_shell]
    lea rax, [rel program_shell_len]
    mov edx, dword [rax]
    mov r8d, r12d                   ; shell_eid
    lea r9, [rel str_empty]         ; run_container = ""
    call herb_load_program
    mov r13d, eax                   ; r13 = loaded (tension count)

    ; serial_print("  Shell process created (id=")
    lea rcx, [rel str_shell_created]
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_shell_tens]
    call serial_print
    mov ecx, r13d
    call serial_print_int
    lea rcx, [rel str_close_paren_nl]
    call serial_print

    ; Settle: ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    lea rcx, [rel total_ops]
    add dword [rcx], eax

.shell_done:

    ; ---- Find ShellCtl entity in input.SHELL_STATE ----
    lea rcx, [rel str_cn_shell_state]
    call herb_container_count
    mov r12d, eax
    xor r13d, r13d

.shellctl_loop:
    cmp r13d, r12d
    jge .shellctl_done

    lea rcx, [rel str_cn_shell_state]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .shellctl_next

    lea rcx, [rel shell_ctl_eid]
    mov dword [rcx], eax
    mov r14d, eax                   ; r14 = sid

    push rax
    lea rcx, [rel str_shellctl_found]
    call serial_print
    mov ecx, r14d
    call serial_print_int
    lea rcx, [rel str_close_paren_nl]
    call serial_print
    pop rax

    ; Set shell protection from HERB state
    lea rax, [rel shell_eid]
    mov eax, dword [rax]
    test eax, eax
    js .shellctl_done

    mov r15d, eax                   ; r15 = shell_eid value

    ; int prot = herb_entity_prop_int(sid, "shell_protected", 1)
    mov ecx, r14d
    lea rdx, [rel str_shell_protected]
    mov r8d, 1
    call herb_entity_prop_int

    ; herb_set_prop_int(shell_eid, "protected", prot)
    mov r8d, eax
    mov ecx, r15d
    lea rdx, [rel str_protected]
    call herb_set_prop_int

    jmp .shellctl_done

.shellctl_next:
    inc r13d
    jmp .shellctl_loop

.shellctl_done:

    ; ---- Find SpawnCtl entity in spawn.SPAWN_STATE ----
    lea rcx, [rel str_cn_spawn_state]
    call herb_container_count
    mov r12d, eax
    xor r13d, r13d

.spawnctl_loop:
    cmp r13d, r12d
    jge .spawnctl_done

    lea rcx, [rel str_cn_spawn_state]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .spawnctl_next

    lea rcx, [rel spawn_ctl_eid]
    mov dword [rcx], eax

    push rax
    lea rcx, [rel str_spawnctl_found]
    call serial_print
    pop rax
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_close_paren_nl]
    call serial_print
    jmp .spawnctl_done

.spawnctl_next:
    inc r13d
    jmp .spawnctl_loop

.spawnctl_done:

    ; ---- Find DisplayCtl entity in display.DISPLAY_STATE ----
    lea rcx, [rel str_cn_display_state]
    call herb_container_count
    mov r12d, eax
    xor r13d, r13d

.dispctl_loop:
    cmp r13d, r12d
    jge .dispctl_done

    lea rcx, [rel str_cn_display_state]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .dispctl_next

    lea rcx, [rel display_ctl_eid]
    mov dword [rcx], eax
    mov r14d, eax                   ; r14 = sid

    push rax
    lea rcx, [rel str_dispctl_found]
    call serial_print
    mov ecx, r14d
    call serial_print_int
    lea rcx, [rel str_close_paren_nl]
    call serial_print
    pop rax

    ; timer_interval = herb_entity_prop_int(sid, "timer_interval", 300)
    mov ecx, r14d
    lea rdx, [rel str_timer_interval]
    mov r8d, 300
    call herb_entity_prop_int
    lea rcx, [rel timer_interval]
    mov dword [rcx], eax

    ; buffer_capacity = herb_entity_prop_int(sid, "buffer_capacity", 20)
    mov ecx, r14d
    lea rdx, [rel str_buffer_capacity]
    mov r8d, 20
    call herb_entity_prop_int
    lea rcx, [rel buffer_capacity]
    mov dword [rcx], eax

    ; Serial output
    lea rcx, [rel str_timer_intv]
    call serial_print
    lea rax, [rel timer_interval]
    mov ecx, dword [rax]
    call serial_print_int
    lea rcx, [rel str_buf_cap]
    call serial_print
    lea rax, [rel buffer_capacity]
    mov ecx, dword [rax]
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    jmp .dispctl_done

.dispctl_next:
    inc r13d
    jmp .dispctl_loop

.dispctl_done:

    ; ---- Find game world entities ----
    lea rcx, [rel str_cn_game_state]
    call herb_container_count
    test eax, eax
    jle .game_state_done

    lea rcx, [rel str_cn_game_state]
    xor edx, edx
    call herb_container_entity
    lea rcx, [rel game_ctl_eid]
    mov dword [rcx], eax

    push rax
    lea rcx, [rel str_gamectl_found]
    call serial_print
    pop rax
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_close_paren_nl]
    call serial_print

.game_state_done:
    lea rcx, [rel str_cn_game_player]
    call herb_container_count
    test eax, eax
    jle .game_player_done

    lea rcx, [rel str_cn_game_player]
    xor edx, edx
    call herb_container_entity
    lea rcx, [rel player_eid]
    mov dword [rcx], eax

    push rax
    lea rcx, [rel str_player_found]
    call serial_print
    pop rax
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_close_paren_nl]
    call serial_print

.game_player_done:
%endif  ; KERNEL_MODE

    ; ================================================================
    ; BOOT MESSAGE
    ; ================================================================

    ; herb_snprintf(last_action, 80, "Booted with %d ops. Press / to type commands.", boot_ops)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_boot_action]
    mov r9d, [rsp + BOOT_OPS]
    call herb_snprintf

    lea rcx, [rel str_start_msg]
    call vga_print
    lea rcx, [rel str_serial_start]
    call serial_print

    ; ================================================================
    ; BUSY-WAIT PAUSE (for boot messages to be visible)
    ; ================================================================

    mov ecx, 30000000
.pause_loop:
    dec ecx
    jnz .pause_loop

    ; ================================================================
    ; SET UP INTERRUPTS
    ; ================================================================

    ; herb_memset(idt, 0, 4096)
    lea rcx, [rel idt]
    xor edx, edx
    mov r8d, 4096
    call herb_memset

    ; idt_set_gate(32, timer_isr_stub)
    mov ecx, 32
    lea rdx, [rel timer_isr_stub]
    call idt_set_gate

    ; idt_set_gate(33, keyboard_isr_stub)
    mov ecx, 33
    lea rdx, [rel keyboard_isr_stub]
    call idt_set_gate

    ; idt_set_gate(44, mouse_isr_stub)
    mov ecx, 44
    lea rdx, [rel mouse_isr_stub]
    call idt_set_gate

    call idt_install

    call pic_remap

    ; pit_init(100)
    mov ecx, 100
    call pit_init

    ; mouse_init()
    call mouse_init
    lea rcx, [rel str_mouse_init]
    call serial_print

    ; hw_sti()
    call hw_sti

    ; ================================================================
    ; INITIAL DISPLAY
    ; ================================================================

    ; vga_set_color(VGA_LGRAY=0x07, VGA_BLACK=0x00)
    mov ecx, 0x07
    xor edx, edx
    call vga_set_color

    call vga_clear
    call draw_full

    ; ================================================================
    ; MAIN LOOP
    ; ================================================================

.mainloop:
    call hw_hlt

    ; ---- Timer interrupt ----
    lea rax, [rel volatile_timer_fired]
    movzx ecx, byte [rax]
    test ecx, ecx
    jz .no_timer

    ; volatile_timer_fired = 0
    mov byte [rax], 0

    ; timer_count++
    lea rax, [rel timer_count]
    mov ecx, dword [rax]
    inc ecx
    mov dword [rax], ecx
    mov r12d, ecx                   ; r12 = timer_count (saved for later)

    ; Auto-timer: if (timer_interval > 0 && timer_count % timer_interval == 0)
%ifdef KERNEL_MODE
    lea rax, [rel timer_interval]
    mov ecx, dword [rax]           ; ecx = timer_interval
    test ecx, ecx
    jle .no_auto_timer

    ; timer_count % timer_interval
    mov eax, r12d                  ; eax = timer_count
    xor edx, edx                   ; zero-extend (timer_count is always positive)
    div ecx                        ; edx = timer_count % timer_interval
    test edx, edx
    jnz .no_auto_timer

    call cmd_timer
    call draw_full

.no_auto_timer:
%else
    ; Non-KERNEL_MODE: no auto-timer
%endif

    ; Refresh stats every 500ms (every 50 ticks at 100Hz)
    mov eax, r12d
    xor edx, edx
    mov ecx, 50
    div ecx                         ; edx = timer_count % 50
    test edx, edx
    jnz .no_timer

%ifdef GRAPHICS_MODE
    call km_fb_get_active
    test eax, eax
    jz .stats_text_mode

    call gfx_draw_stats_only
    jmp .no_timer

.stats_text_mode:
%endif
    call draw_stats

.no_timer:

    ; ---- Keyboard interrupt ----
    lea rax, [rel volatile_key_pressed]
    movzx ecx, byte [rax]
    test ecx, ecx
    jz .no_keyboard

    mov byte [rax], 0

    ; handle_key(volatile_key_scancode)
    lea rax, [rel volatile_key_scancode]
    movzx ecx, byte [rax]
    call handle_key

.no_keyboard:

    ; ---- Mouse ring buffer: drain all accumulated bytes ----
    xor r12d, r12d                  ; r12 = mouse_packets_processed

.mouse_drain_loop:
    lea rax, [rel mouse_ring_tail]
    movzx ecx, byte [rax]          ; ecx = tail
    lea rax, [rel mouse_ring_head]
    movzx edx, byte [rax]          ; edx = head

    cmp ecx, edx
    je .mouse_drain_done

    ; byte = mouse_ring[tail]
    lea rax, [rel mouse_ring]
    movzx r13d, byte [rax + rcx]   ; r13d = byte

    ; tail = (tail + 1) & 0x3F
    inc ecx
    and ecx, 0x3F
    lea rax, [rel mouse_ring_tail]
    mov byte [rax], cl

    ; Check mouse_cycle
    lea rax, [rel mouse_cycle]
    mov eax, dword [rax]
    test eax, eax
    jnz .mouse_not_cycle0

    ; mouse_cycle == 0: check bit 3 of byte for sync
    test r13b, 0x08
    jz .mouse_drain_loop            ; Discard: not a valid first byte
    jmp .mouse_store_byte

.mouse_not_cycle0:
.mouse_store_byte:
    ; mouse_packet[mouse_cycle] = byte
    lea rcx, [rel mouse_packet]
    lea rax, [rel mouse_cycle]
    mov eax, dword [rax]
    mov byte [rcx + rax], r13b

    ; mouse_cycle++
    inc eax
    lea rcx, [rel mouse_cycle]
    mov dword [rcx], eax

    ; if (mouse_cycle >= 3)
    cmp eax, 3
    jl .mouse_drain_loop

    ; mouse_cycle = 0
    lea rcx, [rel mouse_cycle]
    mov dword [rcx], 0

    ; mouse_handle_packet()
    call mouse_handle_packet
    inc r12d

    jmp .mouse_drain_loop

.mouse_drain_done:

    ; if (mouse_packets_processed > 0)
    test r12d, r12d
    jz .mainloop

%ifdef GRAPHICS_MODE
    ; Update cursor position for rendering
    call km_fb_get_active
    test eax, eax
    jz .no_cursor_update

    ; cursor_x = mouse_x; cursor_y = mouse_y
    lea rax, [rel mouse_x]
    mov ecx, dword [rax]
    lea rax, [rel mouse_y]
    mov edx, dword [rax]
    call km_set_cursor

.no_cursor_update:

    ; Update cursor entity position in HERB state
%ifdef KERNEL_MODE
    lea rax, [rel cursor_eid]
    mov eax, dword [rax]
    test eax, eax
    js .no_cursor_entity

    mov r13d, eax                   ; r13 = cursor_eid

    mov ecx, r13d
    lea rdx, [rel str_x]
    lea rax, [rel mouse_x]
    mov r8d, dword [rax]
    movsxd r8, r8d
    call herb_set_prop_int

    mov ecx, r13d
    lea rdx, [rel str_y]
    lea rax, [rel mouse_y]
    mov r8d, dword [rax]
    movsxd r8, r8d
    call herb_set_prop_int

.no_cursor_entity:
%endif  ; KERNEL_MODE

    ; Handle left click
    lea rax, [rel mouse_left_clicked]
    mov eax, dword [rax]
    test eax, eax
    jz .no_mouse_click

    ; mouse_left_clicked = 0
    lea rax, [rel mouse_left_clicked]
    mov dword [rax], 0

%ifdef KERNEL_MODE
    ; cmd_click(mouse_x, mouse_y)
    lea rax, [rel mouse_x]
    mov ecx, dword [rax]
    lea rax, [rel mouse_y]
    mov edx, dword [rax]
    call cmd_click

    ; Check if HERB detected a panel click
    lea rax, [rel input_ctl_eid]
    mov eax, dword [rax]
    test eax, eax
    js .no_panel_click

    mov r13d, eax                   ; r13 = input_ctl_eid

    ; herb_entity_prop_int(input_ctl_eid, "panel_click", 0)
    mov ecx, r13d
    lea rdx, [rel str_panel_click]
    xor r8d, r8d
    call herb_entity_prop_int
    test eax, eax
    jz .no_panel_click

    ; herb_set_prop_int(input_ctl_eid, "panel_click", 0)
    mov ecx, r13d
    lea rdx, [rel str_panel_click]
    xor r8d, r8d
    call herb_set_prop_int

    ; row = (mouse_y - (GFX_TENS_Y + 22)) / GFX_TENS_ROW_H
    ; GFX_TENS_Y = 76, GFX_TENS_ROW_H = 16
    lea rax, [rel mouse_y]
    mov eax, dword [rax]
    sub eax, 98                     ; 76 + 22 = 98
    cdq
    mov ecx, 16
    idiv ecx                        ; eax = row

    test eax, eax
    js .no_panel_click

    ; if (row < herb_tension_count())
    mov r14d, eax                   ; r14 = row
    push r14
    call herb_tension_count
    pop r14
    cmp r14d, eax
    jge .no_panel_click

    ; selected_tension_idx = row
    lea rax, [rel selected_tension_idx]
    mov dword [rax], r14d

    call cmd_tension_toggle

.no_panel_click:
%endif  ; KERNEL_MODE

    call draw_full

.no_mouse_click:

    ; Update cursor on screen (direct MMIO, no full redraw)
    lea rax, [rel mouse_moved]
    mov eax, dword [rax]
    test eax, eax
    jz .no_mouse_move

    call km_fb_get_active
    test eax, eax
    jz .no_mouse_move

    ; mouse_moved = 0
    lea rax, [rel mouse_moved]
    mov dword [rax], 0

    call km_fb_cursor_erase
    call km_fb_cursor_draw

.no_mouse_move:
%endif  ; GRAPHICS_MODE

    jmp .mainloop

    ; kernel_main never returns
