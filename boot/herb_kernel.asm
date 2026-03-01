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
extern herb_entity_prop_str
extern herb_arena_usage
extern herb_arena_total
extern herb_tension_count
extern herb_tension_name
extern herb_tension_priority
extern herb_tension_enabled
extern herb_tension_set_enabled
extern herb_tension_owner
extern herb_create_container
extern herb_load_program
extern herb_remove_owner_tensions
extern herb_remove_tension_by_name
extern ham_run_ham
extern ham_mark_dirty
extern ham_get_compiled_count
extern ham_get_bytecode_len
extern ham_dbg_thdr
extern ham_dbg_fail
extern ham_dbg_tend
extern ham_dbg_skip

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
; handle_key now defined locally (Phase C Step 10)
extern mouse_handle_packet
extern scancode_to_ascii
; cmd_timer now defined locally (Phase C)
extern herb_error_handler

%ifdef KERNEL_MODE
; cmd_click and cmd_tension_toggle now defined locally (Phase C)
; cleanup_terminated and handle_shell_action now local (Phase C Step 8)
; cmd_spawn now defined locally (Phase C Step 9)
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
extern program_worker
extern program_worker_len
extern program_beacon
extern program_beacon_len
extern program_schedule_priority
extern program_schedule_priority_len
extern program_schedule_roundrobin
extern program_schedule_roundrobin_len
%endif

; ============================================================
; GLOBAL
; ============================================================

global kernel_main

; Phase C — functions exported to C
%ifdef KERNEL_MODE
global scoped_count
global report_buffer_state
global cmd_alloc_page
global cmd_open_fd
global cmd_free_page
global cmd_close_fd
global cmd_toggle_game
global cmd_send_msg
global cmd_tension_next
global cmd_tension_prev
global cmd_tension_toggle
global cmd_ham_test
%endif
global make_sig_name
global compute_text_key
global compute_arg_key
global cmd_step
global cmd_boost
global cmd_timer
%ifdef KERNEL_MODE
global cmd_click
; Phase C Step 7 — signal factories + dispatch
global create_key_signal
global create_move_signal
global create_gather_signal
global dispatch_mech_action
global dispatch_cmd_from_route
global dispatch_text_command
global post_dispatch
; Phase C Step 8 — shell handling
global read_cmdline
global cleanup_terminated
global handle_shell_action
global handle_submission
global cmd_swap_policy_from_herb
; Phase C Step 9 — process creation
global cmd_spawn
%endif
%ifndef KERNEL_MODE
global cmd_new_process
%endif
; Phase C Step 10 — handle_key (final function)
global handle_key

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
str_et_signal:      db "proc.Signal", 0
str_et_msg:         db "ipc.Message", 0
str_et_game_signal: db "world.GameSignal", 0
str_et_shellctl:    db "input.ShellCtl", 0
str_et_spawnctl:    db "spawn.SpawnCtl", 0

; Container names — Phase C (signal containers)
str_cn_blocked:     db "proc.BLOCKED", 0
str_cn_terminated:  db "proc.TERMINATED", 0
str_cn_timer_sig:   db "proc.TIMER_SIG", 0
str_cn_kill_sig:    db "proc.KILL_SIG", 0
str_cn_block_sig:   db "proc.BLOCK_SIG", 0
str_cn_unblock_sig: db "proc.UNBLOCK_SIG", 0
str_cn_boost_sig:   db "proc.BOOST_SIG", 0
str_cn_alloc_sig:   db "proc.ALLOC_SIG", 0
str_cn_free_sig:    db "proc.FREE_SIG", 0
str_cn_open_sig:    db "proc.OPEN_SIG", 0
str_cn_close_sig:   db "proc.CLOSE_SIG", 0
str_cn_send_sig:    db "proc.SEND_SIG", 0
str_cn_click_sig:   db "proc.CLICK_SIG", 0
str_cn_key_sig:     db "proc.KEY_SIG", 0
str_cn_sig_done:    db "proc.SIG_DONE", 0
str_cn_cmd_sig:     db "proc.CMD_SIG", 0
str_cn_spawn_sig:   db "proc.SPAWN_SIG", 0
str_cn_cmdline:     db "input.CMDLINE", 0
str_cn_keybind:     db "input.KEYBIND", 0
str_cn_textcmd:     db "input.TEXTCMD", 0
str_cn_textarg:     db "input.TEXTARG", 0
str_cn_mechbind:    db "input.MECHBIND", 0
str_cn_legend:      db "display.LEGEND", 0
str_cn_help_text:   db "display.HELP_TEXT", 0
str_cn_game_tiles:  db "world.TILES", 0
str_cn_game_trees:  db "world.TREES", 0
str_cn_game_move_sig: db "world.MOVE_SIG", 0
str_cn_game_gather_sig: db "world.GATHER_SIG", 0
str_cn_game_tree_gathered: db "world.TREE_GATHERED", 0

; Property names — Phase C (new)
str_cmd_id:         db "cmd_id", 0
str_arg_id:         db "arg_id", 0
str_text_key:       db "text_key", 0
str_arg_key:        db "arg_key", 0
str_next_priority:  db "next_priority", 0
str_program_type:   db "program_type", 0
str_requested_type: db "requested_type", 0
str_produced:       db "produced", 0
str_produce_limit:  db "produce_limit", 0
str_consumed:       db "consumed", 0
str_work:           db "work", 0
str_pulses:         db "pulses", 0
str_limit:          db "limit", 0
str_seq:            db "seq", 0
str_direction:      db "direction", 0
str_cleanup_pending: db "cleanup_pending", 0
str_click_x:        db "click_x", 0
str_click_y:        db "click_y", 0
str_submitted:      db "submitted", 0
str_mode:           db "mode", 0
str_mech_action:    db "mech_action", 0
str_pending_cmd:    db "pending_cmd", 0
str_pending_arg:    db "pending_arg", 0
str_pos:            db "pos", 0
str_load_policy:    db "load_policy", 0
str_key_ascii:      db "key_ascii", 0
str_ascii_prop:     db "ascii", 0
str_current_policy: db "current_policy", 0
str_order:          db "order", 0
str_cmd_text:       db "cmd_text", 0
str_tile_x:         db "tile_x", 0
str_tile_y:         db "tile_y", 0
str_terrain:        db "terrain", 0
str_hp:             db "hp", 0

; Tension names for policy swap
str_tn_schedule_ready: db "proc.schedule_ready", 0
str_tn_schedule_pri: db "proc.schedule_pri", 0
str_tn_schedule_rr: db "proc.schedule_rr", 0

; Serial output — Phase C (KERNEL_MODE)
str_ser_shell_dispatch: db "[SHELL DISPATCH] cmd_id=", 0
str_ser_arg_id:     db " arg_id=", 0
str_ser_sig_eid:    db " sig_eid=", 0
str_ser_game_mode:  db "[GAME] mode=", 0
str_ser_kill:       db "[KILL] ", 0
str_ser_kill_none:  db "[KILL] no running process", 0
str_ser_block:      db "[BLOCK] ops=", 0
str_ser_unblock:    db "[UNBLOCK] ops=", 0
str_ser_alloc:      db "[ALLOC] ", 0
str_ser_alloc_none: db "[ALLOC] no running process", 10, 0
str_ser_open:       db "[OPEN] ", 0
str_ser_open_none:  db "[OPEN] no running process", 10, 0
str_ser_free:       db "[FREE] ", 0
str_ser_free_none:  db "[FREE] no running process", 10, 0
str_ser_close:      db "[CLOSE] ", 0
str_ser_close_none: db "[CLOSE] no running process", 10, 0
str_ser_msg:        db "[MSG] ", 0
str_ser_msg_none:   db "[MSG] no running process", 10, 0
str_ser_msg_fail:   db "[MSG] failed to create message", 10, 0
str_ser_click_sel:  db "[CLICK] selected ", 0
str_ser_click_miss: db "[CLICK] miss", 0
str_ser_click_at:   db " at ", 0
str_ser_tension_sel: db "[TENSION SELECT] idx=", 0
str_ser_tension_none: db "[TENSION] no selection", 10, 0
str_ser_tension:    db "[TENSION] ", 0
str_ser_ham:        db "[HAM] tensions=", 0
str_ser_bytes:      db " bytes=", 0
str_ser_ready:      db " ready=", 0
str_ser_arrow:      db "->", 0
str_ser_cpu0:       db " cpu0=", 0
str_ser_ts:         db " ts=", 0
str_ser_thdr:       db " thdr=", 0
str_ser_fail:       db " fail=", 0
str_ser_tend:       db " tend=", 0
str_ser_skip:       db " skip=", 0
str_ser_policy_rem: db "[POLICY] Removed ", 0
str_ser_policy_rr:  db "[POLICY] Loaded round-robin (", 0
str_ser_policy_pri: db "[POLICY] Loaded priority (", 0
str_ser_tensions_paren: db " tensions)", 10, 0
str_ser_policy_settled: db "[POLICY] Settled: ", 0
str_ser_program:    db "[PROGRAM] ", 0
str_ser_loaded_for: db " loaded for ", 0
str_ser_tensions_eq: db " tensions=", 0
str_ser_new:        db "[NEW] ", 0
str_ser_pri:        db " pri=", 0
str_ser_2pg2fd_ops: db " (2pg 2fd) ops=", 0
str_ser_proc:       db "[PROC] ", 0
str_ser_produced:   db " produced=", 0
str_ser_consumed:   db " consumed=", 0
str_ser_spawn_fail: db "[SPAWN] failed - no action from HERB", 10, 0
str_ser_prog_rem:   db "[PROGRAM] removed ", 0
str_ser_tens_for:   db " tensions for ", 0
str_ser_shell_clean: db "[SHELL] cleaned ", 0
str_ser_cmd:        db "[CMD] ", 0
str_ser_empty_cmd:  db "(empty)", 0
str_ser_shell_load: db "[SHELL] load ", 0
str_ser_shell_list: db "[SHELL] list", 10, 0
str_ser_shell_help: db "[SHELL] help", 10, 0
str_ser_shell_spawn: db "[SHELL] spawn auto", 10, 0
str_ser_shell_unk:  db "[SHELL] unknown command", 10, 0
str_ser_shell_swap: db "[SHELL] swap policy", 10, 0
str_ser_input_mode: db "[INPUT] mode=", 0
str_ser_len:        db " len=", 0
str_ser_buf:        db " buf=", 0
str_ser_text_enter: db "[INPUT] mode=1 (text mode entered)", 10, 0
str_ser_text_key:   db "[SHELL DISPATCH] text_key=", 0
str_ser_arg_key:    db " arg_key=", 0
str_ser_cmd_remaining: db " cmd_remaining=", 0
str_ser_game_move:  db "[GAME] move ", 0
str_ser_game_blocked: db " BLOCKED", 0
str_ser_game_gather: db "[GAME] gather", 0
str_ser_game_fail:  db " FAIL", 0
str_ser_game_wood:  db " wood=", 0
str_ser_pos:        db " pos=", 0
str_ser_list:       db "[LIST] ", 0
str_ser_help_cmds:  db "[HELP] Commands: ", 0
str_ser_shell:      db "[SHELL] ", 0
str_ser_help_flat:  db "kill, load <producer|consumer|worker|beacon>, swap, list, help, block, unblock", 0

; Last action format strings — Phase C
str_la_kill:        db "Kill %s -> %d ops", 0
str_la_kill_none:   db "Kill: no running process", 0
str_la_block:       db "Block %s -> %d ops", 0
str_la_block_none:  db "Block: no running process", 0
str_la_unblock:     db "Unblock -> %d ops", 0
str_la_boost_none:  db "Boost: no running process", 0
str_la_boost:       db "Boost -> pri now %d, %d ops", 0
str_la_step:        db "Step -> %d ops", 0
str_la_alloc_none:  db "Alloc: no running process", 0
str_la_alloc:       db "Alloc %s: %df/%du -> %d ops", 0
str_la_open_none:   db "Open: no running process", 0
str_la_open:        db "Open %s: %df/%do -> %d ops", 0
str_la_free_none:   db "Free: no running process", 0
str_la_free:        db "Free %s: %df/%du -> %d ops", 0
str_la_close_none:  db "Close: no running process", 0
str_la_close:       db "Close %s: %df/%do -> %d ops", 0
str_la_msg_none:    db "Msg: no running process", 0
str_la_msg_fail:    db "Msg: failed to create message", 0
str_la_msg:         db "Msg from %s -> %d ops", 0
str_la_click_fail:  db "Click: failed to create signal", 0
str_la_click_sel:   db "Click (%d,%d) -> selected %s, %d ops", 0
str_la_click_miss:  db "Click (%d,%d) -> no process hit, %d ops", 0
str_la_tension_sel: db "Selected tension %d: %s (pri=%d) %s", 0
str_la_tension_none: db "No tension selected (use [ ] to select)", 0
str_la_tension_tog: db "Tension %s %s", 0
str_la_game_on:     db "Game view (G=back, Arrows=move, Space=gather)", 0
str_la_game_off:    db "OS view", 0
str_la_ham:         db "HAM: %d tensions %d bytes %d ops, ready %d->%d, cpu0 %d->%d", 0
str_la_policy:      db "Policy: %s (%d ops)", 0
str_la_create_fail: db "Failed to create process (entity limit?)", 0
str_la_created:     db "Created %s (pri=%d) -> %d ops", 0
str_la_created_prog: db "Created %s (pri=%d) %s -> %d ops", 0
str_la_spawn_fail:  db "Spawn failed (no action)", 0
str_la_shell_unk:   db "Shell: unknown '%s'", 0
str_la_shell_list:  db "Shell: list (see serial)", 0
str_la_shell_help:  db "Shell: help", 0
str_la_shell_cmd_unk: db "Shell: unknown command", 0
str_la_shell_empty: db "Shell: (empty)", 0
str_la_text_mode:   db "Text mode (/ to type, Enter to submit, ESC to cancel)", 0
str_la_unknown_key: db "Unknown key (scan=0x%d)", 0
str_la_move:        db "Move %s -> (%d,%d)", 0
str_la_move_block:  db "Blocked %s at (%d,%d)", 0
str_la_gather_yes:  db "Gathered! wood=%d", 0
str_la_gather_no:   db "Nothing here (wood=%d)", 0
str_la_timer:       db "Timer signal %s -> %d ops", 0
%endif  ; KERNEL_MODE

; ---- Non-KERNEL_MODE container/type names ----
%ifndef KERNEL_MODE
str_cn_timer_sig:   db "TIMER_EXPIRED", 0
str_cn_kill_sig:    db "KILL_SIG", 0
str_cn_block_sig:   db "BLOCK_SIG", 0
str_cn_unblock_sig: db "UNBLOCK_SIG", 0
str_cn_boost_sig:   db "BOOST_SIG", 0
str_cn_sig_done:    db "SIG_DONE", 0
str_cn_blocked:     db "BLOCKED", 0
str_cn_terminated:  db "TERMINATED", 0
str_cn_cpu0:        db "CPU0", 0
str_cn_ready:       db "READY", 0
str_et_process:     db "Process", 0
str_et_signal:      db "Signal", 0
str_empty:          db 0
str_newline:        db 10, 0
%endif

; ---- Unconditional strings (both modes) ----

; Signal name prefixes
str_pfx_t:          db "t", 0
str_pfx_spawn:      db "spawn", 0
str_pfx_bst:        db "bst", 0
str_pfx_alloc:      db "alloc", 0
str_pfx_open:       db "open", 0
str_pfx_free:       db "free", 0
str_pfx_close:      db "close", 0
str_pfx_send:       db "send", 0
str_pfx_key:        db "key", 0
str_pfx_mv:         db "mv", 0
str_pfx_ga:         db "ga", 0
str_pfx_cmd:        db "cmd", 0
str_pfx_clk:        db "clk", 0

; Format strings
str_fmt_sd:         db "%s%d", 0
str_fmt_scoped:     db "%s::%s", 0
str_fmt_pname:      db "p%d", 0
str_fmt_d:          db "%d", 0
str_fmt_s:          db "%s", 0
str_fmt_outbox:     db "%s::OUTBOX", 0
str_fmt_msg:        db "msg%d", 0
str_fmt_pg0:        db "pg0_%s", 0
str_fmt_pg1:        db "pg1_%s", 0
str_fmt_fd0:        db "fd0_%s", 0
str_fmt_fd1:        db "fd1_%s", 0
str_fmt_surf:       db "surf_%s", 0
str_fmt_mem_free:   db "%s::MEM_FREE", 0
str_fmt_fd_free:    db "%s::FD_FREE", 0
str_fmt_surface:    db "%s::SURFACE", 0
str_fmt_x_d:        db "x%d", 0

; Scoped container suffixes
str_scope_mem_free: db "MEM_FREE", 0
str_scope_mem_used: db "MEM_USED", 0
str_scope_fd_free:  db "FD_FREE", 0
str_scope_fd_open:  db "FD_OPEN", 0

; Serial output — shared
str_ser_timer:      db "[TIMER] ", 0
str_ser_ops:        db " ops=", 0
str_ser_bracket_l:  db " [", 0
str_ser_arrow_bracket: db "]->[", 0
str_ser_bracket_close_nl: db "]", 10, 0
str_ser_buffer:     db "[BUFFER] count=", 0
str_ser_slash:      db "/", 0
str_ser_space:      db " ", 0
str_ser_comma:      db ",", 0
str_ser_comma_space: db ", ", 0
str_ser_name:       db " name=", 0
str_ser_boost:      db "[BOOST] ops=", 0
str_ser_paren_l:    db "(", 0
str_ser_paren_r_nl: db ")", 10, 0
str_ser_p_eq:       db ",p=", 0
str_ser_paren_sp:   db ") ", 0
str_ser_f_slash:    db "f/", 0
str_ser_u_ops:      db "u ops=", 0
str_ser_o_ops:      db "o ops=", 0
str_ser_question:   db "?", 0

; Program type names
str_prog_unknown:   db "unknown", 0
str_prog_producer:  db "producer", 0
str_prog_consumer:  db "consumer", 0
str_prog_worker:    db "worker", 0
str_prog_beacon:    db "beacon", 0

; Direction names
str_dir_n:          db "N", 0
str_dir_s:          db "S", 0
str_dir_e:          db "E", 0
str_dir_w:          db "W", 0

; Process state labels
str_lbl_run:        db "RUN", 0
str_lbl_rdy:        db "RDY", 0
str_lbl_blk:        db "BLK", 0
str_lbl_trm:        db "TRM", 0

; Toggle state strings
str_on:             db "ON", 0
str_off:            db "OFF", 0
str_enabled:        db "ENABLED", 0
str_disabled:       db "DISABLED", 0

; Policy labels
str_round_robin:    db "ROUND-ROBIN", 0
str_priority_label: db "PRIORITY", 0

; Misc
str_empty_name:     db "EMPTY", 0
str_ham_timer:      db "ham_timer", 0
str_space:          db " ", 0

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

; ============================================================
; Phase C: Shell, Command, Input Dispatch Functions
; ============================================================

; ============================================================
; scoped_count — Count entities in a scoped container
;
; int scoped_count(int entity_id, const char* scope_name)
;   Build "entity_name::scope_name" → herb_container_count
;   Returns count, clamped to 0 if negative.
;
; Args: ECX = entity_id, RDX = scope_name (pointer)
; Returns: EAX = count (>= 0)
; ============================================================

%ifdef KERNEL_MODE
scoped_count:
    push rbp
    mov rbp, rsp
    push rbx                        ; rbp-8: save callee-saved
    push rsi                        ; rbp-16: save callee-saved
    sub rsp, 176                    ; 128-byte buf + 48 (shadow+5th+align)
    ; Stack: 8(ret)+8(rbp)+8(rbx)+8(rsi)+176 = 208, 208%16=0 ✓
    ; buf at [rsp+48] = [rbp-192+48] .. = [rbp-144]
    ; shadow at [rsp+0..31], 5th arg at [rsp+32]

    mov esi, ecx                    ; esi = entity_id (preserved)
    mov rbx, rdx                    ; rbx = scope_name (preserved)

    ; const char* ent_name = herb_entity_name(entity_id)
    ; ecx already has entity_id
    call herb_entity_name
    ; rax = ent_name

    ; herb_snprintf(buf, 128, "%s::%s", ent_name, scope_name)
    lea rcx, [rsp + 48]            ; buf on stack
    mov edx, 128                   ; size
    lea r8, [rel str_fmt_scoped]   ; "%s::%s"
    mov r9, rax                    ; ent_name
    mov qword [rsp + 32], rbx     ; 5th arg: scope_name
    call herb_snprintf

    ; int n = herb_container_count(buf)
    lea rcx, [rsp + 48]
    call herb_container_count

    ; return n < 0 ? 0 : n
    test eax, eax
    jns .sc_done
    xor eax, eax
.sc_done:
    add rsp, 176
    pop rsi
    pop rbx
    pop rbp
    ret
%endif

; ============================================================
; make_sig_name — Generate unique signal name "prefix<counter>"
;
; void make_sig_name(char* buf, int bufsz, const char* prefix)
;   Increments signal_counter, writes "prefix<N>" into buf.
;
; Args: RCX = buf, EDX = bufsz, R8 = prefix
; ============================================================

make_sig_name:
    push rbp
    mov rbp, rsp
    sub rsp, 48                     ; shadow(32) + 5th arg(8) + align(8)
    ; Stack: 8(ret)+8(rbp)+48 = 64, 64%16=0 ✓

    ; Save original args before shuffling
    mov rax, r8                     ; rax = prefix

    ; signal_counter++
    lea r8, [rel signal_counter]
    mov r9d, dword [r8]
    inc r9d
    mov dword [r8], r9d

    ; herb_snprintf(buf, bufsz, "%s%d", prefix, signal_counter)
    ; rcx = buf (already set by caller)
    ; edx = bufsz (already set by caller)
    lea r8, [rel str_fmt_sd]        ; r8 = fmt "%s%d"
    mov r9, rax                     ; r9 = prefix (4th arg)
    mov dword [rsp + 32], r9d       ; 5th arg: signal_counter value
    ; Oops, r9d is now the prefix pointer low bits. Need the counter.
    lea rax, [rel signal_counter]
    mov eax, dword [rax]
    mov dword [rsp + 32], eax       ; 5th arg: signal_counter
    call herb_snprintf

    leave
    ret

; ============================================================
; report_buffer_state — Print buffer count/capacity to serial
;
; void report_buffer_state(void)
;   KERNEL_MODE only. Checks buffer_eid >= 0.
; ============================================================

%ifdef KERNEL_MODE
report_buffer_state:
    push rbp
    mov rbp, rsp
    push rbx                        ; rbp-8: callee-saved
    push rsi                        ; rbp-16: callee-saved
    sub rsp, 32                     ; shadow space
    ; Stack: 8(ret)+8(rbp)+8(rbx)+8(rsi)+32 = 64, 64%16=0 ✓

    ; if (buffer_eid < 0) return
    lea rax, [rel buffer_eid]
    mov eax, dword [rax]
    test eax, eax
    js .rbs_done

    mov ebx, eax                    ; ebx = buffer_eid

    ; bcount = herb_entity_prop_int(buffer_eid, "count", 0)
    mov ecx, ebx
    lea rdx, [rel str_count]
    xor r8d, r8d                    ; default = 0
    call herb_entity_prop_int
    mov esi, eax                    ; esi = bcount

    ; bcap = herb_entity_prop_int(buffer_eid, "capacity", 0)
    mov ecx, ebx
    lea rdx, [rel str_capacity]
    xor r8d, r8d
    call herb_entity_prop_int
    mov ebx, eax                    ; ebx = bcap

    ; serial_print("[BUFFER] count=")
    lea rcx, [rel str_ser_buffer]
    call serial_print

    ; serial_print_int(bcount)
    mov ecx, esi
    call serial_print_int

    ; serial_print("/")
    lea rcx, [rel str_ser_slash]
    call serial_print

    ; serial_print_int(bcap)
    mov ecx, ebx
    call serial_print_int

    ; serial_print("\n")
    lea rcx, [rel str_newline]
    call serial_print

.rbs_done:
    add rsp, 32
    pop rsi
    pop rbx
    pop rbp
    ret
%endif

; ============================================================
; compute_text_key — Compute key from first 2 chars: buf[0]*256 + buf[1]
;
; int compute_text_key(const char* buf)
;
; Args: RCX = buf
; Returns: EAX = key value
; ============================================================

compute_text_key:
    ; No frame needed — pure arithmetic, no calls
    xor eax, eax
    test rcx, rcx
    jz .ctk_done
    movzx edx, byte [rcx]          ; buf[0]
    test edx, edx
    jz .ctk_done
    shl edx, 8                     ; buf[0] * 256
    movzx eax, byte [rcx + 1]      ; buf[1]
    test eax, eax
    jz .ctk_no_second
    add eax, edx                   ; buf[0]*256 + buf[1]
    ret
.ctk_no_second:
    mov eax, edx                   ; buf[0]*256
.ctk_done:
    ret

; ============================================================
; compute_arg_key — Compute key from first 2 chars of second word
;
; int compute_arg_key(const char* buf)
;
; Args: RCX = buf
; Returns: EAX = key value
; ============================================================

compute_arg_key:
    ; No frame needed — pure arithmetic, no calls
    xor eax, eax
    test rcx, rcx
    jz .cak_done

    ; Find first space
    xor edx, edx                   ; i = 0
.cak_find_space:
    movzx eax, byte [rcx + rdx]
    test eax, eax
    jz .cak_zero                   ; end of string, no second word
    cmp eax, ' '
    je .cak_skip_spaces
    inc edx
    jmp .cak_find_space

.cak_skip_spaces:
    ; Skip spaces
    movzx eax, byte [rcx + rdx]
    cmp eax, ' '
    jne .cak_got_word
    inc edx
    jmp .cak_skip_spaces

.cak_got_word:
    ; buf[i] is first char of second word
    test eax, eax
    jz .cak_zero                   ; end of string after spaces
    shl eax, 8                     ; buf[i] * 256
    movzx r8d, byte [rcx + rdx + 1]  ; buf[i+1]
    test r8d, r8d
    jz .cak_done2                  ; only one char
    add eax, r8d                   ; buf[i]*256 + buf[i+1]
    ret
.cak_done2:
    ret
.cak_zero:
    xor eax, eax
.cak_done:
    ret

; ============================================================
; cmd_step — Run one tension cycle manually
;
; void cmd_step(void)
; ============================================================

cmd_step:
    push rbp
    mov rbp, rsp
    push rbx                        ; rbp-8
    sub rsp, 40                     ; shadow(32) + align(8)
    ; 8(ret)+8(rbp)+8(rbx)+40 = 64, 64%16=0 ✓

    ; ops = ham_run_ham(1)
    mov ecx, 1
    call ham_run_ham
    mov ebx, eax                    ; ebx = ops

    ; total_ops += ops
    lea rax, [rel total_ops]
    add dword [rax], ebx

    ; herb_snprintf(last_action, 80, "Step -> %d ops", ops)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_step]
    mov r9d, ebx
    call herb_snprintf

    ; report_buffer_state()
    call report_buffer_state

    add rsp, 40
    pop rbx
    pop rbp
    ret

; ============================================================
; cmd_boost — Create BOOST_SIG, tension increments priority
;
; void cmd_boost(void)
; ============================================================

cmd_boost:
    push rbp
    mov rbp, rsp
    push rbx                        ; rbp-8
    push rsi                        ; rbp-16
    sub rsp, 80                     ; 32-byte name buf + 48 (shadow+5th+align)
    ; 8+8+8+8+80 = 112, 112%16=0 ✓
    ; name buf at [rsp+48]

    ; cpu_n = herb_container_count(CN_CPU0)
    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    test eax, eax
    jle .cb_no_cpu

    ; make_sig_name(name, 32, "bst")
    lea rcx, [rsp + 48]
    mov edx, 32
    lea r8, [rel str_pfx_bst]
    call make_sig_name

    ; herb_create(name, ET_SIGNAL, CN_BOOST_SIG)
    lea rcx, [rsp + 48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_boost_sig]
    call herb_create

    ; ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov ebx, eax                    ; ebx = ops

    ; total_ops += ops
    lea rax, [rel total_ops]
    add dword [rax], ebx

    ; eid = herb_container_entity(CN_CPU0, 0)
    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity

    ; pri = herb_entity_prop_int(eid, "priority", 0)
    mov ecx, eax
    lea rdx, [rel str_priority]
    xor r8d, r8d
    call herb_entity_prop_int
    mov esi, eax                    ; esi = pri

    ; herb_snprintf(last_action, 80, "Boost -> pri now %d, %d ops", pri, ops)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_boost]
    mov r9d, esi                    ; pri
    mov dword [rsp + 32], ebx      ; ops (5th arg)
    call herb_snprintf

    ; serial_print("[BOOST] ops=")
    lea rcx, [rel str_ser_boost]
    call serial_print

    ; serial_print_int(ops)
    mov ecx, ebx
    call serial_print_int

    ; serial_print("\n")
    lea rcx, [rel str_newline]
    call serial_print

    jmp .cb_done

.cb_no_cpu:
    ; herb_snprintf(last_action, 80, "Boost: no running process")
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_boost_none]
    call herb_snprintf

.cb_done:
    add rsp, 80
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; Phase C Step 6: cmd_timer + cmd_click
; ============================================================

; ---- cmd_timer ----
; Create timer signal, run HAM, report CPU0 context switch.
; Works in both KERNEL_MODE and non-KERNEL_MODE.
; Stack: push rbp/rbx/rsi/rdi (4 saves) + sub rsp 104 = 144 total, 16-aligned
; Check: 8 + 32 + 104 = 144. 144%16=0. Good.
;   [rsp+48..79] = name[32]
;   [rsp+32..39] = 5th arg slot for herb_snprintf
;   [rsp+0..31]  = shadow space
;   rbx = before_name, rsi = ops, rdi = after_name
cmd_timer:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 104

    ; make_sig_name(name, 32, "t")
    lea rcx, [rsp+48]
    mov edx, 32
    lea r8, [rel str_pfx_t]
    call make_sig_name

    ; Who's in CPU0 before timer?
    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    test eax, eax
    jle .ctm_before_empty
    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    mov ecx, eax
    call herb_entity_name
    mov rbx, rax                    ; rbx = before_name
    jmp .ctm_create_sig
.ctm_before_empty:
    lea rbx, [rel str_empty_name]   ; "EMPTY"

.ctm_create_sig:
    ; herb_create(name, ET_SIGNAL, CN_TIMER_SIG)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_timer_sig]
    call herb_create

    ; ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov esi, eax                    ; rsi = ops
    add [rel total_ops], eax

    ; Who's in CPU0 after timer?
    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    test eax, eax
    jle .ctm_after_empty
    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    mov ecx, eax
    call herb_entity_name
    mov rdi, rax                    ; rdi = after_name
    jmp .ctm_serial
.ctm_after_empty:
    lea rdi, [rel str_empty_name]

.ctm_serial:
    ; Serial: "[TIMER] " name " ops=" ops " [" before "]->[" after "]\n"
    lea rcx, [rel str_ser_timer]
    call serial_print
    lea rcx, [rsp+48]              ; name
    call serial_print
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, esi                   ; ops
    call serial_print_int
    lea rcx, [rel str_ser_bracket_l]
    call serial_print
    mov rcx, rbx                   ; before_name
    call serial_print
    lea rcx, [rel str_ser_arrow_bracket]
    call serial_print
    mov rcx, rdi                   ; after_name
    call serial_print
    lea rcx, [rel str_ser_bracket_close_nl]
    call serial_print

    ; report_buffer_state (KERNEL_MODE only, else just skip)
%ifdef KERNEL_MODE
    call report_buffer_state
%endif

    ; herb_snprintf(last_action, 80, "Timer signal %s -> %d ops", name, ops)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_timer]
    lea r9, [rsp+48]               ; name (4th arg = pointer to name buf)
    mov [rsp+32], esi              ; ops (5th arg) — safely below name buf
    call herb_snprintf

    add rsp, 104
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; cmd_toggle_game — Toggle game/OS display mode
;
; void cmd_toggle_game(void)
; KERNEL_MODE only.
; ============================================================

%ifdef KERNEL_MODE
cmd_toggle_game:
    push rbp
    mov rbp, rsp
    push rbx                        ; rbp-8
    sub rsp, 40                     ; shadow(32) + align(8)
    ; 8+8+8+40 = 64, 64%16=0 ✓

    ; if (game_ctl_eid < 0) return
    lea rax, [rel game_ctl_eid]
    mov eax, dword [rax]
    test eax, eax
    js .ctg_done

    mov ebx, eax                    ; ebx = game_ctl_eid

    ; cur = herb_entity_prop_int(game_ctl_eid, "display_mode", 0)
    mov ecx, ebx
    lea rdx, [rel str_display_mode]
    xor r8d, r8d
    call herb_entity_prop_int

    ; next = cur ? 0 : 1
    test eax, eax
    jz .ctg_set1
    xor eax, eax
    jmp .ctg_set
.ctg_set1:
    mov eax, 1
.ctg_set:
    mov r12d, eax                   ; r12d = next (use a callee-saved we haven't pushed...
    ; Actually r12 is callee-saved but not pushed. Let me use ebx.
    ; Wait, ebx holds game_ctl_eid. Let me push r12.
    ; Actually, I can just save next on the stack.
    ; Let me rethink: ebx = game_ctl_eid, I need to preserve next across calls.
    ; Since game_ctl_eid isn't needed after set_prop_int, repurpose ebx.
    mov ebx, eax                    ; ebx = next

    ; herb_set_prop_int(game_ctl_eid, "display_mode", next)
    lea rax, [rel game_ctl_eid]
    mov ecx, dword [rax]
    lea rdx, [rel str_display_mode]
    movsxd r8, ebx                  ; next as int64
    call herb_set_prop_int

    ; serial_print("[GAME] mode=")
    lea rcx, [rel str_ser_game_mode]
    call serial_print

    ; serial_print_int(next)
    mov ecx, ebx
    call serial_print_int

    ; serial_print("\n")
    lea rcx, [rel str_newline]
    call serial_print

    ; herb_snprintf(last_action, 80, next ? "Game view..." : "OS view")
    lea rcx, [rel last_action]
    mov edx, 80
    test ebx, ebx
    jz .ctg_os_view
    lea r8, [rel str_la_game_on]
    jmp .ctg_fmt
.ctg_os_view:
    lea r8, [rel str_la_game_off]
.ctg_fmt:
    call herb_snprintf

.ctg_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret
%endif

; ============================================================
; Resource signal commands — all follow the same template:
;   1. Check CPU0 has a process (early return if not)
;   2. Get process name
;   3. make_sig_name → herb_create → ham_run_ham
;   4. scoped_count × 2 for reporting
;   5. herb_snprintf(last_action) + serial output
;
; cmd_alloc_page, cmd_open_fd, cmd_free_page, cmd_close_fd
; All KERNEL_MODE only.
; ============================================================

%ifdef KERNEL_MODE

; ---- cmd_alloc_page ----
; Registers: rbx=ops, rsi=mf, rdi=pname, r12=eid→mu
cmd_alloc_page:
    push rbp
    mov rbp, rsp
    push rbx                        ; rbp-8
    push rsi                        ; rbp-16
    push rdi                        ; rbp-24
    push r12                        ; rbp-32
    sub rsp, 96                     ; 32 name buf + 64 (shadow+5th+6th+7th)
    ; 8+8+8+8+8+8+96 = 144, 144%16=0 ✓
    ; name buf at [rsp+64]

    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    test eax, eax
    jle .cap_no_cpu

    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    mov r12d, eax                   ; r12 = eid

    mov ecx, eax
    call herb_entity_name
    mov rdi, rax                    ; rdi = pname

    lea rcx, [rsp + 64]
    mov edx, 32
    lea r8, [rel str_pfx_alloc]
    call make_sig_name

    lea rcx, [rsp + 64]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_alloc_sig]
    call herb_create

    mov ecx, 100
    call ham_run_ham
    mov ebx, eax                    ; ebx = ops

    lea rax, [rel total_ops]
    add dword [rax], ebx

    mov ecx, r12d
    lea rdx, [rel str_scope_mem_free]
    call scoped_count
    mov esi, eax                    ; esi = mf

    mov ecx, r12d
    lea rdx, [rel str_scope_mem_used]
    call scoped_count
    mov r12d, eax                   ; r12 = mu (eid no longer needed)

    ; herb_snprintf(last_action, 80, fmt, pname, mf, mu, ops)
    mov dword [rsp + 48], ebx      ; ops (7th)
    mov dword [rsp + 40], r12d     ; mu (6th)
    mov dword [rsp + 32], esi      ; mf (5th)
    mov r9, rdi                    ; pname (4th)
    lea r8, [rel str_la_alloc]
    mov edx, 80
    lea rcx, [rel last_action]
    call herb_snprintf

    ; Serial output
    lea rcx, [rel str_ser_alloc]
    call serial_print
    mov rcx, rdi
    call serial_print
    lea rcx, [rel str_ser_space]
    call serial_print
    mov ecx, esi
    call serial_print_int
    lea rcx, [rel str_ser_f_slash]
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_ser_u_ops]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    jmp .cap_done

.cap_no_cpu:
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_alloc_none]
    call herb_snprintf
    lea rcx, [rel str_ser_alloc_none]
    call serial_print

.cap_done:
    add rsp, 96
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- cmd_open_fd ----
; Registers: rbx=ops, rsi=ff, rdi=pname, r12=eid→fo
cmd_open_fd:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 96
    ; 8+8+8+8+8+8+96 = 144, 144%16=0 ✓

    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    test eax, eax
    jle .cof_no_cpu

    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    mov r12d, eax

    mov ecx, eax
    call herb_entity_name
    mov rdi, rax

    lea rcx, [rsp + 64]
    mov edx, 32
    lea r8, [rel str_pfx_open]
    call make_sig_name

    lea rcx, [rsp + 64]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_open_sig]
    call herb_create

    mov ecx, 100
    call ham_run_ham
    mov ebx, eax

    lea rax, [rel total_ops]
    add dword [rax], ebx

    mov ecx, r12d
    lea rdx, [rel str_scope_fd_free]
    call scoped_count
    mov esi, eax                    ; esi = ff

    mov ecx, r12d
    lea rdx, [rel str_scope_fd_open]
    call scoped_count
    mov r12d, eax                   ; r12 = fo

    ; herb_snprintf(last_action, 80, "Open %s: %df/%do -> %d ops", pname, ff, fo, ops)
    mov dword [rsp + 48], ebx
    mov dword [rsp + 40], r12d
    mov dword [rsp + 32], esi
    mov r9, rdi
    lea r8, [rel str_la_open]
    mov edx, 80
    lea rcx, [rel last_action]
    call herb_snprintf

    lea rcx, [rel str_ser_open]
    call serial_print
    mov rcx, rdi
    call serial_print
    lea rcx, [rel str_ser_space]
    call serial_print
    mov ecx, esi
    call serial_print_int
    lea rcx, [rel str_ser_f_slash]
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_ser_o_ops]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    jmp .cof_done

.cof_no_cpu:
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_open_none]
    call herb_snprintf
    lea rcx, [rel str_ser_open_none]
    call serial_print

.cof_done:
    add rsp, 96
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- cmd_free_page ----
; Registers: rbx=ops, rsi=mf, rdi=pname, r12=eid→mu
cmd_free_page:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 96

    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    test eax, eax
    jle .cfp_no_cpu

    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    mov r12d, eax

    mov ecx, eax
    call herb_entity_name
    mov rdi, rax

    lea rcx, [rsp + 64]
    mov edx, 32
    lea r8, [rel str_pfx_free]
    call make_sig_name

    lea rcx, [rsp + 64]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_free_sig]
    call herb_create

    mov ecx, 100
    call ham_run_ham
    mov ebx, eax

    lea rax, [rel total_ops]
    add dword [rax], ebx

    mov ecx, r12d
    lea rdx, [rel str_scope_mem_free]
    call scoped_count
    mov esi, eax

    mov ecx, r12d
    lea rdx, [rel str_scope_mem_used]
    call scoped_count
    mov r12d, eax

    mov dword [rsp + 48], ebx
    mov dword [rsp + 40], r12d
    mov dword [rsp + 32], esi
    mov r9, rdi
    lea r8, [rel str_la_free]
    mov edx, 80
    lea rcx, [rel last_action]
    call herb_snprintf

    lea rcx, [rel str_ser_free]
    call serial_print
    mov rcx, rdi
    call serial_print
    lea rcx, [rel str_ser_space]
    call serial_print
    mov ecx, esi
    call serial_print_int
    lea rcx, [rel str_ser_f_slash]
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_ser_u_ops]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    jmp .cfp_done

.cfp_no_cpu:
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_free_none]
    call herb_snprintf
    lea rcx, [rel str_ser_free_none]
    call serial_print

.cfp_done:
    add rsp, 96
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- cmd_close_fd ----
; Registers: rbx=ops, rsi=ff, rdi=pname, r12=eid→fo
cmd_close_fd:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 96

    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    test eax, eax
    jle .ccd_no_cpu

    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    mov r12d, eax

    mov ecx, eax
    call herb_entity_name
    mov rdi, rax

    lea rcx, [rsp + 64]
    mov edx, 32
    lea r8, [rel str_pfx_close]
    call make_sig_name

    lea rcx, [rsp + 64]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_close_sig]
    call herb_create

    mov ecx, 100
    call ham_run_ham
    mov ebx, eax

    lea rax, [rel total_ops]
    add dword [rax], ebx

    mov ecx, r12d
    lea rdx, [rel str_scope_fd_free]
    call scoped_count
    mov esi, eax

    mov ecx, r12d
    lea rdx, [rel str_scope_fd_open]
    call scoped_count
    mov r12d, eax

    mov dword [rsp + 48], ebx
    mov dword [rsp + 40], r12d
    mov dword [rsp + 32], esi
    mov r9, rdi
    lea r8, [rel str_la_close]
    mov edx, 80
    lea rcx, [rel last_action]
    call herb_snprintf

    lea rcx, [rel str_ser_close]
    call serial_print
    mov rcx, rdi
    call serial_print
    lea rcx, [rel str_ser_space]
    call serial_print
    mov ecx, esi
    call serial_print_int
    lea rcx, [rel str_ser_f_slash]
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_ser_o_ops]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    jmp .ccd_done

.ccd_no_cpu:
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_close_none]
    call herb_snprintf
    lea rcx, [rel str_ser_close_none]
    call serial_print

.ccd_done:
    add rsp, 96
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; Phase C Step 5: Tier 4 — Messaging + Tension UI (5 functions)
; ============================================================

; ---- cmd_send_msg ----
; Create Message entity in running proc's OUTBOX, then SEND_SIG.
; Stack: push rbp/rbx/rsi/rdi (4 saves) + sub rsp 200 = 240 total, 16-aligned
;   [rsp+128..191] = outbox[64]
;   [rsp+96..127]  = mname[32]
;   [rsp+64..95]   = sname[32]
;   [rsp+0..31]    = shadow space
;   rbx = pname, rsi = eid/mid, rdi = ops
cmd_send_msg:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 200

    ; Check CPU0 has a process
    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    test eax, eax
    jle .csm_no_cpu

    ; Get running process name
    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    mov esi, eax                    ; rsi = eid
    mov ecx, eax
    call herb_entity_name
    mov rbx, rax                    ; rbx = pname

    ; Build outbox name: "%s::OUTBOX"
    lea rcx, [rsp+128]             ; outbox buf
    mov edx, 64
    lea r8, [rel str_fmt_outbox]
    mov r9, rbx                    ; pname
    call herb_snprintf

    ; Build message name: "msg%d"
    inc dword [rel signal_counter]
    lea rcx, [rsp+96]             ; mname buf
    mov edx, 32
    lea r8, [rel str_fmt_msg]
    mov r9d, [rel signal_counter]
    call herb_snprintf

    ; Create message entity in outbox
    lea rcx, [rsp+96]             ; mname
    lea rdx, [rel str_et_msg]
    lea r8, [rsp+128]             ; outbox
    call herb_create
    test eax, eax
    js .csm_fail
    mov esi, eax                   ; rsi = mid

    ; Set seq property
    mov ecx, esi
    lea rdx, [rel str_seq]
    mov r8d, [rel signal_counter]
    call herb_set_prop_int

    ; Create SEND_SIG
    lea rcx, [rsp+64]             ; sname buf
    mov edx, 32
    lea r8, [rel str_pfx_send]
    call make_sig_name

    lea rcx, [rsp+64]             ; sname
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_send_sig]
    call herb_create

    ; Run HAM
    mov ecx, 100
    call ham_run_ham
    mov edi, eax                   ; rdi = ops
    add [rel total_ops], eax

    ; last_action: "Msg from %s -> %d ops"
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_msg]
    mov r9, rbx                    ; pname
    mov [rsp+32], edi              ; ops (5th arg)
    call herb_snprintf

    ; Serial: "[MSG] " pname " ops=" ops "\n"
    lea rcx, [rel str_ser_msg]
    call serial_print
    mov rcx, rbx
    call serial_print
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, edi
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    jmp .csm_done

.csm_no_cpu:
    ; last_action: "Msg: no running process"
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_msg_none]
    call herb_snprintf
    lea rcx, [rel str_ser_msg_none]
    call serial_print
    jmp .csm_done

.csm_fail:
    ; last_action: "Msg: failed to create message"
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_msg_fail]
    call herb_snprintf
    lea rcx, [rel str_ser_msg_fail]
    call serial_print

.csm_done:
    add rsp, 200
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ---- cmd_tension_next ----
; Increment selected_tension_idx, wrap, report.
; herb_snprintf with 7 args: buf, sz, fmt, idx, name, pri, state
; Stack: push rbp/rbx/rsi (3 saves) + sub rsp 72 = 96 total, 16-aligned
;   rbx = name, rsi = nt/priority
cmd_tension_next:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 72

    call herb_tension_count
    test eax, eax
    jle .ctn_done
    mov esi, eax                   ; rsi = nt

    ; Increment and wrap
    mov eax, [rel selected_tension_idx]
    inc eax
    cmp eax, esi
    jl .ctn_nowrap
    xor eax, eax
.ctn_nowrap:
    mov [rel selected_tension_idx], eax

    ; Get tension name
    mov ecx, eax
    call herb_tension_name
    mov rbx, rax                   ; rbx = name

    ; Get priority
    mov ecx, [rel selected_tension_idx]
    call herb_tension_priority
    mov esi, eax                   ; rsi = priority (reuse, no longer need nt)

    ; Get enabled state
    mov ecx, [rel selected_tension_idx]
    call herb_tension_enabled
    ; eax = enabled: pick "ON" or "OFF"
    test eax, eax
    jz .ctn_off
    lea rax, [rel str_on]
    jmp .ctn_fmt
.ctn_off:
    lea rax, [rel str_off]
.ctn_fmt:
    ; herb_snprintf(last_action, 80, fmt, idx, name, pri, state)
    ; args: RCX=buf, RDX=80, R8=fmt, R9=idx, [rsp+32]=name, [rsp+40]=pri, [rsp+48]=state
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_tension_sel]
    mov r9d, [rel selected_tension_idx]
    mov [rsp+32], rbx              ; name (5th arg)
    mov [rsp+40], rsi              ; priority (6th arg)
    mov [rsp+48], rax              ; state string (7th arg)
    call herb_snprintf

    ; Serial: "[TENSION SELECT] idx=" idx " name=" name "\n"
    lea rcx, [rel str_ser_tension_sel]
    call serial_print
    mov ecx, [rel selected_tension_idx]
    call serial_print_int
    lea rcx, [rel str_ser_name]
    call serial_print
    mov rcx, rbx
    call serial_print
    lea rcx, [rel str_newline]
    call serial_print

.ctn_done:
    add rsp, 72
    pop rsi
    pop rbx
    pop rbp
    ret


; ---- cmd_tension_prev ----
; Decrement selected_tension_idx, wrap, report.
; Same frame as cmd_tension_next.
cmd_tension_prev:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 72

    call herb_tension_count
    test eax, eax
    jle .ctp_done
    mov esi, eax                   ; rsi = nt

    ; Decrement and wrap
    mov eax, [rel selected_tension_idx]
    dec eax
    test eax, eax
    jge .ctp_nowrap
    lea eax, [esi-1]               ; wrap to nt-1
.ctp_nowrap:
    mov [rel selected_tension_idx], eax

    ; Get tension name
    mov ecx, eax
    call herb_tension_name
    mov rbx, rax                   ; rbx = name

    ; Get priority
    mov ecx, [rel selected_tension_idx]
    call herb_tension_priority
    mov esi, eax                   ; rsi = priority

    ; Get enabled state
    mov ecx, [rel selected_tension_idx]
    call herb_tension_enabled
    test eax, eax
    jz .ctp_off
    lea rax, [rel str_on]
    jmp .ctp_fmt
.ctp_off:
    lea rax, [rel str_off]
.ctp_fmt:
    ; herb_snprintf(last_action, 80, fmt, idx, name, pri, state)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_tension_sel]
    mov r9d, [rel selected_tension_idx]
    mov [rsp+32], rbx              ; name
    mov [rsp+40], rsi              ; priority
    mov [rsp+48], rax              ; state string
    call herb_snprintf

    ; Serial: "[TENSION SELECT] idx=" idx " name=" name "\n"
    lea rcx, [rel str_ser_tension_sel]
    call serial_print
    mov ecx, [rel selected_tension_idx]
    call serial_print_int
    lea rcx, [rel str_ser_name]
    call serial_print
    mov rcx, rbx
    call serial_print
    lea rcx, [rel str_newline]
    call serial_print

.ctp_done:
    add rsp, 72
    pop rsi
    pop rbx
    pop rbp
    ret


; ---- cmd_tension_toggle ----
; Toggle selected tension enabled/disabled.
; Stack: push rbp/rbx/rsi (3 saves) + sub rsp 56 = 80 total, 16-aligned
;   rbx = name, esi = was_enabled
cmd_tension_toggle:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 56

    ; Validate selected_tension_idx
    mov eax, [rel selected_tension_idx]
    test eax, eax
    js .ctt_none
    mov esi, eax                   ; rsi = idx (temp)
    call herb_tension_count
    cmp esi, eax
    jge .ctt_none

    ; Get current enabled state
    mov ecx, esi
    call herb_tension_enabled
    mov esi, eax                   ; rsi = was_enabled

    ; Toggle: set_enabled(idx, !was_enabled)
    mov ecx, [rel selected_tension_idx]
    xor edx, edx
    test esi, esi
    setz dl                        ; dl = !was_enabled
    call herb_tension_set_enabled

    ; Get name
    mov ecx, [rel selected_tension_idx]
    call herb_tension_name
    mov rbx, rax                   ; rbx = name

    ; Pick state string: was_enabled ? "DISABLED" : "ENABLED"
    test esi, esi
    jz .ctt_enabled
    lea rax, [rel str_disabled]
    jmp .ctt_fmt
.ctt_enabled:
    lea rax, [rel str_enabled]
.ctt_fmt:
    ; herb_snprintf(last_action, 80, "Tension %s %s", name, state)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_tension_tog]
    mov r9, rbx                    ; name
    mov [rsp+32], rax              ; state (5th arg)
    call herb_snprintf

    ; Serial: "[TENSION] " name " " state "\n"
    lea rcx, [rel str_ser_tension]
    call serial_print
    mov rcx, rbx
    call serial_print
    lea rcx, [rel str_space]
    call serial_print
    ; Recompute state string
    test esi, esi
    jz .ctt_ser_en
    lea rcx, [rel str_disabled]
    jmp .ctt_ser_state
.ctt_ser_en:
    lea rcx, [rel str_enabled]
.ctt_ser_state:
    call serial_print
    lea rcx, [rel str_newline]
    call serial_print
    jmp .ctt_done

.ctt_none:
    ; "No tension selected (use [ ] to select)"
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_tension_none]
    call herb_snprintf
    lea rcx, [rel str_ser_tension_none]
    call serial_print

.ctt_done:
    add rsp, 56
    pop rsi
    pop rbx
    pop rbp
    ret


; ---- cmd_ham_test ----
; Force recompile all tensions, run HAM, report diagnostics.
; Stack: push rbp/rbx/rsi/rdi/r12/r13/r14/r15 (8 saves) + sub rsp 136 = 200 total
; Check alignment: 8(ret) + 64(8 pushes) + 136 = 208. 208%16=0. Good.
; Callee-saved regs:
;   rbx = pre_ready, esi = pre_cpu0, edi = pre_ts
;   r12 = ops, r13 = ham_tension_cnt, r14 = ham_bc_len
;   r15 = post_ready
; Stack locals:
;   [rsp+80] = post_cpu0, [rsp+84] = post_ts
cmd_ham_test:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 136

    ; Force recompile
    call ham_mark_dirty

    ; Create TIMER_SIG: herb_create("ham_timer", ET_SIGNAL, CN_TIMER_SIG)
    lea rcx, [rel str_ham_timer]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_timer_sig]
    call herb_create

    ; Record pre-state
    lea rcx, [rel str_cn_ready]
    call herb_container_count
    mov ebx, eax                   ; rbx = pre_ready

    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    mov esi, eax                   ; rsi = pre_cpu0

    ; Get first CPU0 entity's time_slice
    mov edi, -1                    ; rdi = pre_ts = -1
    test esi, esi
    jle .cht_no_pre_ts
    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    mov ecx, eax
    lea rdx, [rel str_time_slice]
    mov r8d, -1
    call herb_entity_prop_int
    mov edi, eax                   ; rdi = pre_ts
.cht_no_pre_ts:

    ; Run HAM
    mov ecx, 100
    call ham_run_ham
    mov r12d, eax                  ; r12 = ops

    ; Get HAM stats
    call ham_get_compiled_count
    mov r13d, eax                  ; r13 = ham_tension_cnt
    call ham_get_bytecode_len
    mov r14d, eax                  ; r14 = ham_bc_len

    ; Record post-state
    lea rcx, [rel str_cn_ready]
    call herb_container_count
    mov r15d, eax                  ; r15 = post_ready

    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    mov [rsp+80], eax              ; [rsp+80] = post_cpu0

    ; Get post time_slice
    mov dword [rsp+84], -1         ; [rsp+84] = post_ts = -1
    test eax, eax
    jle .cht_no_post_ts
    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    mov ecx, eax
    lea rdx, [rel str_time_slice]
    mov r8d, -1
    call herb_entity_prop_int
    mov [rsp+84], eax              ; post_ts
.cht_no_post_ts:

    ; === Serial output ===
    ; "[HAM] tensions=" cnt " bytes=" bclen " ops=" ops
    ;   " ready=" pre "->" post " cpu0=" pre "->" post
    ;   " ts=" pre "->" post " thdr=" " fail=" " tend=" " skip="
    lea rcx, [rel str_ser_ham]
    call serial_print
    mov ecx, r13d                  ; ham_tension_cnt
    call serial_print_int
    lea rcx, [rel str_ser_bytes]
    call serial_print
    mov ecx, r14d                  ; ham_bc_len
    call serial_print_int
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, r12d                  ; ops
    call serial_print_int
    lea rcx, [rel str_ser_ready]
    call serial_print
    mov ecx, ebx                   ; pre_ready
    call serial_print_int
    lea rcx, [rel str_ser_arrow]
    call serial_print
    mov ecx, r15d                  ; post_ready
    call serial_print_int
    lea rcx, [rel str_ser_cpu0]
    call serial_print
    mov ecx, esi                   ; pre_cpu0
    call serial_print_int
    lea rcx, [rel str_ser_arrow]
    call serial_print
    mov ecx, [rsp+80]             ; post_cpu0
    call serial_print_int
    lea rcx, [rel str_ser_ts]
    call serial_print
    mov ecx, edi                   ; pre_ts
    call serial_print_int
    lea rcx, [rel str_ser_arrow]
    call serial_print
    mov ecx, [rsp+84]             ; post_ts
    call serial_print_int
    lea rcx, [rel str_ser_thdr]
    call serial_print
    mov ecx, [rel ham_dbg_thdr]
    call serial_print_int
    lea rcx, [rel str_ser_fail]
    call serial_print
    mov ecx, [rel ham_dbg_fail]
    call serial_print_int
    lea rcx, [rel str_ser_tend]
    call serial_print
    mov ecx, [rel ham_dbg_tend]
    call serial_print_int
    lea rcx, [rel str_ser_skip]
    call serial_print
    mov ecx, [rel ham_dbg_skip]
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    ; === last_action via herb_snprintf ===
    ; "HAM: %d tensions %d bytes %d ops, ready %d->%d, cpu0 %d->%d"
    ; 10 args: RCX=buf, RDX=80, R8=fmt, R9=ham_tension_cnt
    ; [rsp+32]=ham_bc_len, [rsp+40]=ops, [rsp+48]=pre_ready
    ; [rsp+56]=post_ready, [rsp+64]=pre_cpu0, [rsp+72]=post_cpu0
    ; Save post_cpu0 before we overwrite [rsp+64]
    mov eax, [rsp+80]             ; post_cpu0
    mov [rsp+88], eax              ; save to safe slot

    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_ham]
    mov r9d, r13d                  ; ham_tension_cnt (4th)
    mov [rsp+32], r14d             ; ham_bc_len (5th)
    mov [rsp+40], r12d             ; ops (6th)
    mov [rsp+48], ebx              ; pre_ready (7th)
    mov [rsp+56], r15d             ; post_ready (8th)
    mov [rsp+64], esi              ; pre_cpu0 (9th)
    mov eax, [rsp+88]
    mov [rsp+72], eax              ; post_cpu0 (10th)
    call herb_snprintf

.cht_done:
    add rsp, 136
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; Phase C Step 6: cmd_click
; ============================================================

; ---- cmd_click ----
; Create CLICK_SIG with click_x/click_y, run HAM, scan for selected entity.
; GRAPHICS_MODE only (text mode = immediate ret).
; void cmd_click(int cx, int cy)
; Args: ECX = cx, EDX = cy
;
; Stack: push rbp/rbx/rsi/rdi/r12/r13 (6 saves) + sub rsp 88 = 136 total, 16-aligned
; Check: 8 + 48 + 88 = 144. 144%16=0. Good.
;   [rsp+48..79] = name[32]
;   [rsp+32..39] = 5th arg slot
;   [rsp+0..31]  = shadow space
;   rbx = ops, rsi = cx, rdi = cy, r12 = click_eid, r13 = sel_name
cmd_click:
%ifndef GRAPHICS_MODE
    ret
%else
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 88

    mov esi, ecx                    ; rsi = cx
    mov edi, edx                    ; rdi = cy

    ; Clear previous selection
    mov eax, [rel selected_eid]
    test eax, eax
    js .ccl_no_clear
    mov ecx, eax
    lea rdx, [rel str_selected]
    xor r8d, r8d                   ; 0
    call herb_set_prop_int
    mov dword [rel selected_eid], -1
.ccl_no_clear:

    ; Create click signal: make_sig_name(name, 32, "clk")
    lea rcx, [rsp+48]
    mov edx, 32
    lea r8, [rel str_pfx_clk]
    call make_sig_name

    ; herb_create(name, ET_SIGNAL, CN_CLICK_SIG)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_click_sig]
    call herb_create
    test eax, eax
    js .ccl_fail
    mov r12d, eax                   ; r12 = click_eid

    ; Set click_x
    mov ecx, r12d
    lea rdx, [rel str_click_x]
    mov r8d, esi                   ; cx
    call herb_set_prop_int

    ; Set click_y
    mov ecx, r12d
    lea rdx, [rel str_click_y]
    mov r8d, edi                   ; cy
    call herb_set_prop_int

    ; Run HAM
    mov ecx, 100
    call ham_run_ham
    mov ebx, eax                    ; rbx = ops
    add [rel total_ops], eax

    ; Scan 4 containers for selected entity
    ; containers = { CN_CPU0, CN_READY, CN_BLOCKED, CN_TERMINATED }
    xor r13d, r13d                  ; r13 = sel_name = NULL
    mov dword [rel selected_eid], -1

    ; Container 0: CPU0
    lea rcx, [rel str_cn_cpu0]
    call .ccl_scan_container
    test r13, r13
    jnz .ccl_report

    ; Container 1: READY
    lea rcx, [rel str_cn_ready]
    call .ccl_scan_container
    test r13, r13
    jnz .ccl_report

    ; Container 2: BLOCKED
    lea rcx, [rel str_cn_blocked]
    call .ccl_scan_container
    test r13, r13
    jnz .ccl_report

    ; Container 3: TERMINATED
    lea rcx, [rel str_cn_terminated]
    call .ccl_scan_container

.ccl_report:
    test r13, r13
    jz .ccl_miss

    ; Selected: herb_snprintf(last_action, 80, "Click (%d,%d) -> selected %s, %d ops", cx, cy, sel_name, ops)
    ; 8 args: RCX=buf, RDX=80, R8=fmt, R9=cx, [rsp+32]=cy, [rsp+40]=sel_name, [rsp+48]=ops
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_click_sel]
    mov r9d, esi                   ; cx
    mov [rsp+32], edi              ; cy (5th)
    mov [rsp+40], r13              ; sel_name (6th)
    mov [rsp+48], ebx              ; ops (7th)
    call herb_snprintf

    ; Serial: "[CLICK] selected " sel_name
    lea rcx, [rel str_ser_click_sel]
    call serial_print
    mov rcx, r13
    call serial_print
    jmp .ccl_serial_tail

.ccl_miss:
    ; herb_snprintf(last_action, 80, "Click (%d,%d) -> no process hit, %d ops", cx, cy, ops)
    ; 6 args: RCX=buf, RDX=80, R8=fmt, R9=cx, [rsp+32]=cy, [rsp+40]=ops
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_click_miss]
    mov r9d, esi                   ; cx
    mov [rsp+32], edi              ; cy (5th)
    mov [rsp+40], ebx              ; ops (6th)
    call herb_snprintf

    ; Serial: "[CLICK] miss"
    lea rcx, [rel str_ser_click_miss]
    call serial_print

.ccl_serial_tail:
    ; " at " cx "," cy " ops=" ops "\n"
    lea rcx, [rel str_ser_click_at]
    call serial_print
    mov ecx, esi
    call serial_print_int
    lea rcx, [rel str_ser_comma]
    call serial_print
    mov ecx, edi
    call serial_print_int
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    jmp .ccl_done

.ccl_fail:
    ; "Click: failed to create signal"
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_click_fail]
    call herb_snprintf

.ccl_done:
    add rsp, 88
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- cmd_click local subroutine: scan one container ----
; Called with RCX = container name.
; Scans all entities for "selected" == 1.
; Sets r13 = entity name and selected_eid if found.
; Uses r12 as temp (clobbered), preserves rbx/rsi/rdi.
; This is a local call within cmd_click's frame.
.ccl_scan_container:
    ; Save return address manually since we use call/ret
    push r14                        ; save container_name
    push r15                        ; save loop counter
    mov r14, rcx                    ; r14 = container_name

    ; Get count
    ; rcx already = container name
    sub rsp, 32                     ; shadow for calls within subroutine
    call herb_container_count
    test eax, eax
    jle .ccl_scan_done
    mov r15d, eax                   ; r15 = count

    xor r12d, r12d                 ; r12 = i = 0
.ccl_scan_loop:
    cmp r12d, r15d
    jge .ccl_scan_done

    mov rcx, r14
    mov edx, r12d
    call herb_container_entity
    test eax, eax
    js .ccl_scan_next

    ; Check selected property
    mov ecx, eax
    mov [rsp+0], eax               ; save eid in shadow space (we own it)
    lea rdx, [rel str_selected]
    xor r8d, r8d                   ; default 0
    call herb_entity_prop_int
    cmp eax, 1
    jne .ccl_scan_next

    ; Found selected entity
    mov eax, [rsp+0]               ; reload eid
    mov [rel selected_eid], eax
    mov ecx, eax
    call herb_entity_name
    mov r13, rax                   ; r13 = sel_name
    jmp .ccl_scan_done

.ccl_scan_next:
    inc r12d
    jmp .ccl_scan_loop

.ccl_scan_done:
    add rsp, 32
    pop r15
    pop r14
    ret

%endif  ; GRAPHICS_MODE

; ============================================================
; Phase C Step 7: Signal Factories + Dispatch
; ============================================================

; ---- create_key_signal(int ascii_code) ----
; Create a KEY_SIG signal with an "ascii" property.
; Args: ECX = ascii_code
; Stack: 1 push (rbx) + sub rsp 72 = 80 aligned. name[32] at [rsp+48].
;   8+8+72 = 88. 88%16 != 0. Need sub rsp 80: 8+8+80 = 96. 96%16=0. Good.
create_key_signal:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 72

    mov ebx, ecx                    ; save ascii_code

    ; make_sig_name(name, 32, "key")
    lea rcx, [rsp+48]
    mov edx, 32
    lea r8, [rel str_pfx_key]
    call make_sig_name

    ; herb_create(name, ET_SIGNAL, CN_KEY_SIG)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_key_sig]
    call herb_create

    ; if (eid >= 0) herb_set_prop_int(eid, "ascii", ascii_code)
    test eax, eax
    js .cks_done
    mov ecx, eax
    lea rdx, [rel str_ascii_prop]
    movsxd r8, ebx                  ; ascii_code (sign-extend to 64-bit)
    call herb_set_prop_int

.cks_done:
    add rsp, 72
    pop rbx
    pop rbp
    ret

; ---- create_move_signal(int direction) ----
; Create a MOVE_SIG game signal with a "direction" property.
; Args: ECX = direction
; Stack: 1 push (rbx) + sub rsp 72 = 80 aligned. name[32] at [rsp+48].
create_move_signal:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 72

    mov ebx, ecx                    ; save direction

    ; make_sig_name(name, 32, "mv")
    lea rcx, [rsp+48]
    mov edx, 32
    lea r8, [rel str_pfx_mv]
    call make_sig_name

    ; herb_create(name, ET_GAME_SIGNAL, CN_GAME_MOVE_SIG)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_game_signal]
    lea r8, [rel str_cn_game_move_sig]
    call herb_create

    ; if (eid >= 0) herb_set_prop_int(eid, "direction", direction)
    test eax, eax
    js .cms_done
    mov ecx, eax
    lea rdx, [rel str_direction]
    movsxd r8, ebx
    call herb_set_prop_int

.cms_done:
    add rsp, 72
    pop rbx
    pop rbp
    ret

; ---- create_gather_signal() ----
; Create a GATHER_SIG game signal (no properties).
; Stack: 1 push (rbp) + sub rsp 80 = 88 aligned.
;   8+8+80 = 96. 96%16=0. Good. name[32] at [rsp+48].
create_gather_signal:
    push rbp
    mov rbp, rsp
    sub rsp, 80

    ; make_sig_name(name, 32, "ga")
    lea rcx, [rsp+48]
    mov edx, 32
    lea r8, [rel str_pfx_ga]
    call make_sig_name

    ; herb_create(name, ET_GAME_SIGNAL, CN_GAME_GATHER_SIG)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_game_signal]
    lea r8, [rel str_cn_game_gather_sig]
    call herb_create

    add rsp, 80
    pop rbp
    ret

; ---- dispatch_mech_action(int action) ----
; Switch on action (1-13) → call cmd_* function, then return.
; Args: ECX = action
; No stack frame needed — each case is call+ret.
dispatch_mech_action:
    cmp ecx, 1
    je .dma_case1
    cmp ecx, 2
    je .dma_case2
    cmp ecx, 3
    je .dma_case3
    cmp ecx, 4
    je .dma_case4
    cmp ecx, 5
    je .dma_case5
    cmp ecx, 6
    je .dma_case6
    cmp ecx, 7
    je .dma_case7
    cmp ecx, 8
    je .dma_case8
    cmp ecx, 9
    je .dma_case9
    cmp ecx, 10
    je .dma_case10
    cmp ecx, 11
    je .dma_case11
    cmp ecx, 12
    je .dma_case12
    cmp ecx, 13
    je .dma_case13
    ret
.dma_case1:
    jmp cmd_timer
.dma_case2:
    jmp cmd_boost
.dma_case3:
    jmp cmd_step
.dma_case4:
    jmp cmd_alloc_page
.dma_case5:
    jmp cmd_open_fd
.dma_case6:
    jmp cmd_free_page
.dma_case7:
    jmp cmd_close_fd
.dma_case8:
    jmp cmd_send_msg
.dma_case9:
    jmp cmd_tension_prev
.dma_case10:
    jmp cmd_tension_next
.dma_case11:
    jmp cmd_tension_toggle
.dma_case12:
    jmp cmd_ham_test
.dma_case13:
    jmp cmd_toggle_game

; ---- dispatch_cmd_from_route(int cmd_id, int arg_id) ----
; Create CMD_SIG with cmd_id/arg_id, run HAM, post_dispatch.
; Args: ECX = cmd_id, EDX = arg_id
; Stack: 8 pushes (rbp,rbx,rsi,rdi,r12,r13,r14,r15) + sub rsp 56 = 120 aligned.
;   8+64+56 = 128. 128%16=0. Good.
;   sig_name[32] at [rsp+48].
;   r12=cmd_id, r13=arg_id, r14=cpu0_name, r15=sig_eid, rbx=ops
dispatch_cmd_from_route:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56

    mov r12d, ecx                   ; save cmd_id
    mov r13d, edx                   ; save arg_id

    ; Look up cpu0_name
    xor r14d, r14d                  ; cpu0_name = NULL
    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    test eax, eax
    jle .dcr_no_cpu0
    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .dcr_no_cpu0
    mov ecx, eax
    call herb_entity_name
    mov r14, rax                    ; r14 = cpu0_name
.dcr_no_cpu0:

    ; make_sig_name(sig_name, 32, "cmd")
    lea rcx, [rsp+48]
    mov edx, 32
    lea r8, [rel str_pfx_cmd]
    call make_sig_name

    ; sig_eid = herb_create(sig_name, ET_SIGNAL, CN_CMD_SIG)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_cmd_sig]
    call herb_create
    mov r15d, eax                   ; r15 = sig_eid

    ; Serial: "[SHELL DISPATCH] cmd_id=" cmd_id " arg_id=" arg_id " sig_eid=" sig_eid
    lea rcx, [rel str_ser_shell_dispatch]
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_ser_arg_id]
    call serial_print
    mov ecx, r13d
    call serial_print_int
    lea rcx, [rel str_ser_sig_eid]
    call serial_print
    mov ecx, r15d
    call serial_print_int

    ; if sig_eid >= 0: set 5 properties
    test r15d, r15d
    js .dcr_run_ham

    ; herb_set_prop_int(sig_eid, "cmd_id", cmd_id)
    mov ecx, r15d
    lea rdx, [rel str_cmd_id]
    movsxd r8, r12d
    call herb_set_prop_int

    ; herb_set_prop_int(sig_eid, "arg_id", arg_id)
    mov ecx, r15d
    lea rdx, [rel str_arg_id]
    movsxd r8, r13d
    call herb_set_prop_int

    ; herb_set_prop_int(sig_eid, "key_ascii", 0)
    mov ecx, r15d
    lea rdx, [rel str_key_ascii]
    xor r8d, r8d
    call herb_set_prop_int

    ; herb_set_prop_int(sig_eid, "text_key", 0)
    mov ecx, r15d
    lea rdx, [rel str_text_key]
    xor r8d, r8d
    call herb_set_prop_int

    ; herb_set_prop_int(sig_eid, "arg_key", 0)
    mov ecx, r15d
    lea rdx, [rel str_arg_key]
    xor r8d, r8d
    call herb_set_prop_int

.dcr_run_ham:
    ; ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov ebx, eax                    ; rbx = ops
    add [rel total_ops], eax

    ; post_dispatch(sig_eid, ops, cpu0_name)
    mov ecx, r15d
    mov edx, ebx
    mov r8, r14
    call post_dispatch

    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- dispatch_text_command(int text_key, int arg_key, const char* buf) ----
; Create CMD_SIG with text_key/arg_key, run HAM, check cmd_id, post_dispatch.
; Args: ECX = text_key, EDX = arg_key, R8 = buf
; Stack: 7 pushes (rbp,rbx,rsi,r12,r13,r14,r15) + sub rsp 80 = 136 aligned.
;   8+56+80 = 144. 144%16=0. Good.
;   sig_name[32] at [rsp+48].
;   r12=text_key, r13=arg_key, r14=buf, r15=sig_eid, rbx=ops, rsi=cpu0_name
dispatch_text_command:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80

    mov r12d, ecx                   ; save text_key
    mov r13d, edx                   ; save arg_key
    mov r14, r8                     ; save buf

    ; Look up cpu0_name
    xor esi, esi                    ; cpu0_name = NULL
    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    test eax, eax
    jle .dtc_no_cpu0
    lea rcx, [rel str_cn_cpu0]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .dtc_no_cpu0
    mov ecx, eax
    call herb_entity_name
    mov rsi, rax                    ; rsi = cpu0_name
.dtc_no_cpu0:

    ; make_sig_name(sig_name, 32, "cmd")
    lea rcx, [rsp+48]
    mov edx, 32
    lea r8, [rel str_pfx_cmd]
    call make_sig_name

    ; sig_eid = herb_create(sig_name, ET_SIGNAL, CN_CMD_SIG)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_cmd_sig]
    call herb_create
    mov r15d, eax                   ; r15 = sig_eid

    ; Serial: "[SHELL DISPATCH] text_key=" text_key " arg_key=" arg_key " sig_eid=" sig_eid
    lea rcx, [rel str_ser_text_key]
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_ser_arg_key]
    call serial_print
    mov ecx, r13d
    call serial_print_int
    lea rcx, [rel str_ser_sig_eid]
    call serial_print
    mov ecx, r15d
    call serial_print_int

    ; if sig_eid >= 0: set 5 properties
    test r15d, r15d
    js .dtc_run_ham

    ; herb_set_prop_int(sig_eid, "key_ascii", 0)
    mov ecx, r15d
    lea rdx, [rel str_key_ascii]
    xor r8d, r8d
    call herb_set_prop_int

    ; herb_set_prop_int(sig_eid, "cmd_id", 0)
    mov ecx, r15d
    lea rdx, [rel str_cmd_id]
    xor r8d, r8d
    call herb_set_prop_int

    ; herb_set_prop_int(sig_eid, "arg_id", 0)
    mov ecx, r15d
    lea rdx, [rel str_arg_id]
    xor r8d, r8d
    call herb_set_prop_int

    ; herb_set_prop_int(sig_eid, "text_key", text_key)
    mov ecx, r15d
    lea rdx, [rel str_text_key]
    movsxd r8, r12d
    call herb_set_prop_int

    ; herb_set_prop_int(sig_eid, "arg_key", arg_key)
    mov ecx, r15d
    lea rdx, [rel str_arg_key]
    movsxd r8, r13d
    call herb_set_prop_int

.dtc_run_ham:
    ; ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov ebx, eax                    ; rbx = ops
    add [rel total_ops], eax

    ; Read cmd_id from sig entity
    xor r12d, r12d                  ; reuse r12 for cmd_id (text_key no longer needed)
    test r15d, r15d
    js .dtc_post
    mov ecx, r15d
    lea rdx, [rel str_cmd_id]
    xor r8d, r8d
    call herb_entity_prop_int
    mov r12d, eax                   ; r12 = cmd_id

.dtc_post:
    ; post_dispatch(sig_eid, ops, cpu0_name)
    mov ecx, r15d
    mov edx, ebx
    mov r8, rsi
    call post_dispatch

    ; If cmd_id == 0 && buf != NULL: override last_action
    test r12d, r12d
    jnz .dtc_done
    test r14, r14
    jz .dtc_done

    ; herb_snprintf(last_action, 80, "Shell: unknown '%s'", buf)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_shell_unk]
    mov r9, r14                     ; buf
    call herb_snprintf

.dtc_done:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- post_dispatch(int sig_eid, int ops, const char* cpu0_name) ----
; Read cmd_id from HERB, emit serial, cleanup terminated, handle shell action.
; Args: ECX = sig_eid, EDX = ops, R8 = cpu0_name
; Stack: 5 pushes (rbp,rbx,rsi,rdi,r12) + sub rsp 80 = 120 aligned.
;   8+40+80 = 128. 128%16=0. Good.
;   rbx=ops, rsi=cpu0_name, r12d=cmd_id, edi=sig_eid
post_dispatch:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 80

    mov edi, ecx                    ; save sig_eid
    mov ebx, edx                    ; save ops
    mov rsi, r8                     ; save cpu0_name

    ; Read cmd_id from sig_eid if >= 0
    xor r12d, r12d                  ; cmd_id = 0
    test edi, edi
    js .pd_serial_ops
    mov ecx, edi
    lea rdx, [rel str_cmd_id]
    xor r8d, r8d
    call herb_entity_prop_int
    mov r12d, eax                   ; r12 = cmd_id

.pd_serial_ops:
    ; serial_print(" ops="); serial_print_int(ops);
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, ebx
    call serial_print_int

    ; cmd_remaining = herb_container_count(CN_CMD_SIG)
    lea rcx, [rel str_cn_cmd_sig]
    call herb_container_count
    ; serial_print(" cmd_remaining="); serial_print_int(cmd_remaining);
    lea rcx, [rel str_ser_cmd_remaining]
    call serial_print
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    ; Clean up terminated processes — check cleanup_pending
    mov eax, [rel shell_ctl_eid]
    test eax, eax
    js .pd_shell_action
    mov ecx, eax
    lea rdx, [rel str_cleanup_pending]
    xor r8d, r8d
    call herb_entity_prop_int
    test eax, eax
    jz .pd_shell_action
    ; Reset cleanup_pending = 0
    mov ecx, [rel shell_ctl_eid]
    lea rdx, [rel str_cleanup_pending]
    xor r8d, r8d
    call herb_set_prop_int
    call cleanup_terminated

.pd_shell_action:
    call handle_shell_action

    ; Switch on cmd_id: 1=kill, 6=block, 7=unblock
    cmp r12d, 1
    je .pd_kill
    cmp r12d, 6
    je .pd_block
    cmp r12d, 7
    je .pd_unblock
    jmp .pd_report

.pd_kill:
    ; Kill serial + last_action
    test rsi, rsi
    jz .pd_kill_none
    ; herb_snprintf(last_action, 80, "Kill %s -> %d ops", cpu0_name, ops)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_kill]
    mov r9, rsi
    mov [rsp+32], ebx               ; ops = 5th arg
    call herb_snprintf
    ; serial: "[KILL] " cpu0_name
    lea rcx, [rel str_ser_kill]
    call serial_print
    mov rcx, rsi
    call serial_print
    jmp .pd_kill_serial_ops

.pd_kill_none:
    ; herb_snprintf(last_action, 80, "Kill: no running process")
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_kill_none]
    call herb_snprintf
    ; serial: "[KILL] no running process"
    lea rcx, [rel str_ser_kill_none]
    call serial_print

.pd_kill_serial_ops:
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    jmp .pd_report

.pd_block:
    test rsi, rsi
    jz .pd_block_none
    ; herb_snprintf(last_action, 80, "Block %s -> %d ops", cpu0_name, ops)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_block]
    mov r9, rsi
    mov [rsp+32], ebx
    call herb_snprintf
    jmp .pd_block_serial

.pd_block_none:
    ; herb_snprintf(last_action, 80, "Block: no running process")
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_block_none]
    call herb_snprintf

.pd_block_serial:
    lea rcx, [rel str_ser_block]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    jmp .pd_report

.pd_unblock:
    ; herb_snprintf(last_action, 80, "Unblock -> %d ops", ops)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_unblock]
    mov r9d, ebx                    ; ops as 4th arg (it's an int format)
    call herb_snprintf
    ; serial
    lea rcx, [rel str_ser_unblock]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

.pd_report:
    call report_buffer_state

    add rsp, 80
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; Phase C Step 8: Shell Handling
; ============================================================

; ---- read_cmdline(char* buf, int bufsz) ----
; Assemble CMDLINE container chars into a string buffer.
; Args: RCX = buf, EDX = bufsz
; Returns: EAX = max_pos (string length)
; Stack: 6 pushes (rbp,rbx,rsi,rdi,r12,r13) + sub rsp 48 = 96 aligned.
;   8+48+48 = 104. 104%16 = 8. Need sub rsp 56: 8+48+56=112. 112%16=0. Good.
;   rbx=buf, esi=bufsz, edi=nc, r12=i, r13=max_pos
read_cmdline:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 56

    mov rbx, rcx                    ; save buf
    mov esi, edx                    ; save bufsz

    ; nc = herb_container_count(CN_CMDLINE)
    lea rcx, [rel str_cn_cmdline]
    call herb_container_count
    test eax, eax
    jle .rc_empty

    mov edi, eax                    ; nc = count
    ; Clamp nc to bufsz-1
    mov ecx, esi
    dec ecx                         ; bufsz-1
    cmp edi, ecx
    jle .rc_no_clamp
    mov edi, ecx
.rc_no_clamp:

    ; Zero the buffer: memset(buf, 0, bufsz)
    mov rcx, rbx
    xor edx, edx
    mov r8d, esi
    call herb_memset

    ; Loop i=0..nc-1
    xor r12d, r12d                  ; i = 0
    xor r13d, r13d                  ; max_pos = 0

.rc_loop:
    cmp r12d, edi
    jge .rc_done

    ; cid = herb_container_entity(CN_CMDLINE, i)
    lea rcx, [rel str_cn_cmdline]
    mov edx, r12d
    call herb_container_entity
    test eax, eax
    js .rc_next

    ; Save cid
    mov [rsp+32], eax               ; save cid in local

    ; pos = herb_entity_prop_int(cid, "pos", 0)
    mov ecx, eax
    lea rdx, [rel str_pos]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+36], eax               ; save pos

    ; ascii = herb_entity_prop_int(cid, "ascii", 0)
    mov ecx, [rsp+32]              ; reload cid
    lea rdx, [rel str_ascii_prop]
    xor r8d, r8d
    call herb_entity_prop_int

    ; if pos >= 0 && pos < bufsz-1 && ascii > 0: buf[pos] = ascii
    mov ecx, [rsp+36]              ; pos
    test ecx, ecx
    js .rc_next
    mov edx, esi
    dec edx                         ; bufsz-1
    cmp ecx, edx
    jge .rc_next
    test eax, eax
    jle .rc_next

    ; buf[pos] = (char)ascii
    mov [rbx + rcx], al

    ; if (pos + 1 > max_pos) max_pos = pos + 1
    inc ecx                         ; pos + 1
    cmp ecx, r13d
    jle .rc_next
    mov r13d, ecx

.rc_next:
    inc r12d
    jmp .rc_loop

.rc_done:
    ; buf[max_pos] = 0
    mov byte [rbx + r13], 0
    mov eax, r13d                   ; return max_pos

    add rsp, 56
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

.rc_empty:
    mov byte [rbx], 0
    xor eax, eax                    ; return 0
    add rsp, 56
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- cleanup_terminated() ----
; Remove owner tensions for terminated processes.
; Stack: 6 pushes (rbp,rbx,rsi,rdi,r12,r13) + sub rsp 48 = 96 aligned.
;   8+48+48 = 104. 104%16=8. Need sub rsp 56: 8+48+56=112. 112%16=0. Good.
;   rbx=n, rsi=i, rdi=eid, r12=removed, r13=pname
cleanup_terminated:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 56

    ; n = herb_container_count(CN_TERMINATED)
    lea rcx, [rel str_cn_terminated]
    call herb_container_count
    mov ebx, eax                    ; rbx = n
    test eax, eax
    jle .clt_done

    xor esi, esi                    ; i = 0
.clt_loop:
    cmp esi, ebx
    jge .clt_done

    ; eid = herb_container_entity(CN_TERMINATED, i)
    lea rcx, [rel str_cn_terminated]
    mov edx, esi
    call herb_container_entity
    test eax, eax
    js .clt_next
    mov edi, eax                    ; edi = eid

    ; Skip if eid == shell_eid (protected)
    cmp edi, [rel shell_eid]
    je .clt_next

    ; removed = herb_remove_owner_tensions(eid)
    mov ecx, edi
    call herb_remove_owner_tensions
    mov r12d, eax                   ; r12 = removed
    test eax, eax
    jle .clt_next

    ; pname = herb_entity_name(eid)
    mov ecx, edi
    call herb_entity_name
    mov r13, rax                    ; r13 = pname

    ; Serial: "[PROGRAM] removed N tensions for NAME\n"
    lea rcx, [rel str_ser_prog_rem]
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_ser_tens_for]
    call serial_print
    mov rcx, r13
    call serial_print
    lea rcx, [rel str_newline]
    call serial_print

    ; Serial: "[SHELL] cleaned N tensions for NAME\n"
    lea rcx, [rel str_ser_shell_clean]
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_ser_tens_for]
    call serial_print
    mov rcx, r13
    call serial_print
    lea rcx, [rel str_newline]
    call serial_print

    ; Clamp selected_tension_idx
    call herb_tension_count
    cmp [rel selected_tension_idx], eax
    jl .clt_next
    dec eax
    mov [rel selected_tension_idx], eax

.clt_next:
    inc esi
    jmp .clt_loop

.clt_done:
    add rsp, 56
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- handle_shell_action() ----
; Handle delegated shell actions (ShellCtl.action set by HERB tensions).
; Largest function in Step 8.
; Stack: 8 pushes (rbp,rbx,rsi,rdi,r12,r13,r14,r15) + sub rsp 200 = 264 aligned.
;   8+64+200 = 272. 272%16=0. Good.
;   hids[16] at [rsp+48] (64 bytes), hords[16] at [rsp+112] (64 bytes)
;   hcount at [rsp+176] (4 bytes)
;   rbx=action, r12=various, r13=various
handle_shell_action:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 200

    ; if (shell_ctl_eid < 0) return
    mov eax, [rel shell_ctl_eid]
    test eax, eax
    js .hsa_done

    ; action = herb_entity_prop_int(shell_ctl_eid, "action", 0)
    mov ecx, eax
    lea rdx, [rel str_action]
    xor r8d, r8d
    call herb_entity_prop_int
    mov ebx, eax                    ; ebx = action

    test ebx, ebx
    jz .hsa_check_policy

    ; Reset action immediately
    mov ecx, [rel shell_ctl_eid]
    lea rdx, [rel str_action]
    xor r8d, r8d
    call herb_set_prop_int

    ; if action >= 1 && action <= 4: load program
    cmp ebx, 1
    jl .hsa_check_20
    cmp ebx, 4
    jg .hsa_check_20

    ; Load program — action is arg_id (1-4)
    ; prog_names = {"", "producer", "consumer", "worker", "beacon"}
    ; serial_print("[SHELL] load "); serial_print(prog_names[action]); serial_print("\n");
    lea rcx, [rel str_ser_shell_load]
    call serial_print
    ; Lookup prog_name by action index
    cmp ebx, 1
    je .hsa_load_producer
    cmp ebx, 2
    je .hsa_load_consumer
    cmp ebx, 3
    je .hsa_load_worker
    lea rcx, [rel str_prog_beacon]
    jmp .hsa_load_name
.hsa_load_producer:
    lea rcx, [rel str_prog_producer]
    jmp .hsa_load_name
.hsa_load_consumer:
    lea rcx, [rel str_prog_consumer]
    jmp .hsa_load_name
.hsa_load_worker:
    lea rcx, [rel str_prog_worker]
.hsa_load_name:
    call serial_print
    lea rcx, [rel str_newline]
    call serial_print

    ; cmd_spawn(action)
    mov ecx, ebx
    call cmd_spawn
    jmp .hsa_check_policy

.hsa_check_20:
    cmp ebx, 20
    jne .hsa_check_30

    ; ---- action==20: List processes ----
    lea rcx, [rel str_ser_shell_list]
    call serial_print
    lea rcx, [rel str_ser_list]
    call serial_print

    ; Iterate 4 containers: CPU0, READY, BLOCKED, TERMINATED
    ; Use r12 as container index (0-3), r13 as container pointer, r14 as label pointer
    xor r12d, r12d                  ; ci = 0

.hsa_list_container:
    cmp r12d, 4
    jge .hsa_list_done

    ; Get container name and label
    cmp r12d, 0
    je .hsa_cont_cpu0
    cmp r12d, 1
    je .hsa_cont_ready
    cmp r12d, 2
    je .hsa_cont_blocked
    lea r13, [rel str_cn_terminated]
    lea r14, [rel str_lbl_trm]
    jmp .hsa_cont_iter
.hsa_cont_cpu0:
    lea r13, [rel str_cn_cpu0]
    lea r14, [rel str_lbl_run]
    jmp .hsa_cont_iter
.hsa_cont_ready:
    lea r13, [rel str_cn_ready]
    lea r14, [rel str_lbl_rdy]
    jmp .hsa_cont_iter
.hsa_cont_blocked:
    lea r13, [rel str_cn_blocked]
    lea r14, [rel str_lbl_blk]

.hsa_cont_iter:
    ; n = herb_container_count(container)
    mov rcx, r13
    call herb_container_count
    test eax, eax
    jle .hsa_cont_next
    mov r15d, eax                   ; r15 = n

    xor esi, esi                    ; i = 0
.hsa_list_ent:
    cmp esi, r15d
    jge .hsa_cont_next

    ; eid = herb_container_entity(container, i)
    mov rcx, r13
    mov edx, esi
    mov [rsp+44], esi               ; save i (below hids buffer)
    call herb_container_entity
    test eax, eax
    js .hsa_list_next

    ; Save eid for property lookup
    mov edi, eax
    ; Print entity name
    mov ecx, eax
    call herb_entity_name
    mov rcx, rax
    call serial_print
    ; Print "(LABEL,p="
    lea rcx, [rel str_ser_paren_l]
    call serial_print
    mov rcx, r14
    call serial_print
    lea rcx, [rel str_ser_p_eq]
    call serial_print
    ; Print priority
    mov ecx, edi
    lea rdx, [rel str_priority]
    xor r8d, r8d
    call herb_entity_prop_int
    mov ecx, eax
    call serial_print_int
    ; Print ") "
    lea rcx, [rel str_ser_paren_sp]
    call serial_print

.hsa_list_next:
    mov esi, [rsp+44]              ; restore i
    inc esi
    jmp .hsa_list_ent

.hsa_cont_next:
    inc r12d
    jmp .hsa_list_container

.hsa_list_done:
    lea rcx, [rel str_newline]
    call serial_print
    ; herb_snprintf(last_action, 80, "Shell: list (see serial)")
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_shell_list]
    call herb_snprintf
    jmp .hsa_check_policy

.hsa_check_30:
    cmp ebx, 30
    jne .hsa_check_40

    ; ---- action==30: Help ----
    lea rcx, [rel str_ser_shell_help]
    call serial_print
    lea rcx, [rel str_ser_help_cmds]
    call serial_print

    ; Iterate CN_HELP_TEXT entities, insertion sort by order
    lea rcx, [rel str_cn_help_text]
    call herb_container_count
    test eax, eax
    jle .hsa_help_print_done
    mov r12d, eax                   ; r12 = hn

    ; Build hids[] and hords[] arrays
    xor r13d, r13d                  ; i = 0
    mov dword [rsp+176], 0          ; hcount = 0

.hsa_help_build:
    cmp r13d, r12d
    jge .hsa_help_sort
    cmp dword [rsp+176], 16
    jge .hsa_help_sort

    lea rcx, [rel str_cn_help_text]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .hsa_help_build_next

    ; Save eid
    mov r14d, eax
    ; Get order
    mov ecx, eax
    lea rdx, [rel str_order]
    mov r8d, 99
    call herb_entity_prop_int

    ; Store hids[hcount] = eid, hords[hcount] = order
    mov ecx, [rsp+176]             ; hcount
    mov [rsp+48+rcx*4], r14d       ; hids[hcount] = eid
    mov [rsp+112+rcx*4], eax       ; hords[hcount] = order
    inc ecx
    mov [rsp+176], ecx             ; hcount++

.hsa_help_build_next:
    inc r13d
    jmp .hsa_help_build

.hsa_help_sort:
    ; Insertion sort by order
    mov r12d, [rsp+176]             ; hcount
    cmp r12d, 2
    jl .hsa_help_print              ; No need to sort if < 2 elements

    mov r13d, 1                     ; i = 1
.hsa_sort_outer:
    cmp r13d, r12d
    jge .hsa_help_print

    ; ko = hords[i], ki = hids[i]
    mov eax, [rsp+112+r13*4]       ; ko = hords[i]
    mov ecx, [rsp+48+r13*4]        ; ki = hids[i]
    mov r14d, eax                   ; save ko
    mov r15d, ecx                   ; save ki
    lea edi, [r13d-1]              ; j = i - 1

.hsa_sort_inner:
    test edi, edi
    js .hsa_sort_insert
    cmp [rsp+112+rdi*4], r14d
    jle .hsa_sort_insert

    ; hords[j+1] = hords[j]; hids[j+1] = hids[j]
    lea ecx, [edi+1]
    mov eax, [rsp+112+rdi*4]
    mov [rsp+112+rcx*4], eax
    mov eax, [rsp+48+rdi*4]
    mov [rsp+48+rcx*4], eax
    dec edi
    jmp .hsa_sort_inner

.hsa_sort_insert:
    lea ecx, [edi+1]
    mov [rsp+112+rcx*4], r14d      ; hords[j+1] = ko
    mov [rsp+48+rcx*4], r15d       ; hids[j+1] = ki

    inc r13d
    jmp .hsa_sort_outer

.hsa_help_print:
    ; Print help entries
    xor r13d, r13d                  ; i = 0
.hsa_help_print_loop:
    cmp r13d, r12d
    jge .hsa_help_print_done

    ; if (i > 0) print ", "
    test r13d, r13d
    jz .hsa_help_no_comma
    lea rcx, [rel str_ser_comma_space]
    call serial_print
.hsa_help_no_comma:

    ; Print herb_entity_prop_str(hids[i], "cmd_text", "?")
    mov ecx, [rsp+48+r13*4]
    lea rdx, [rel str_cmd_text]
    lea r8, [rel str_ser_question]
    call herb_entity_prop_str
    mov rcx, rax
    call serial_print

    inc r13d
    jmp .hsa_help_print_loop

.hsa_help_print_done:
    lea rcx, [rel str_newline]
    call serial_print
    ; herb_snprintf(last_action, 80, "Shell: help")
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_shell_help]
    call herb_snprintf
    jmp .hsa_check_policy

.hsa_check_40:
    cmp ebx, 40
    jne .hsa_check_unknown

    ; ---- action==40: Spawn auto ----
    lea rcx, [rel str_ser_shell_spawn]
    call serial_print
    xor ecx, ecx                   ; cmd_spawn(0)
    call cmd_spawn
    jmp .hsa_check_policy

.hsa_check_unknown:
    ; action == -1: unknown command
    lea rcx, [rel str_ser_shell_unk]
    call serial_print
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_shell_cmd_unk]
    call herb_snprintf

.hsa_check_policy:
    ; Check if HERB tensions requested a policy swap
    mov ecx, [rel shell_ctl_eid]
    test ecx, ecx
    js .hsa_done
    lea rdx, [rel str_load_policy]
    xor r8d, r8d
    call herb_entity_prop_int
    test eax, eax
    jle .hsa_done

    ; Reset load_policy = 0
    mov r12d, eax                   ; save load_pol
    mov ecx, [rel shell_ctl_eid]
    lea rdx, [rel str_load_policy]
    xor r8d, r8d
    call herb_set_prop_int
    ; Serial: "[SHELL] swap policy\n"
    lea rcx, [rel str_ser_shell_swap]
    call serial_print
    ; cmd_swap_policy_from_herb(load_pol)
    mov ecx, r12d
    call cmd_swap_policy_from_herb

.hsa_done:
    add rsp, 200
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- handle_submission() ----
; Read cmdline, dispatch text command.
; Stack: 4 pushes (rbp,rbx,rsi,rdi) + sub rsp 96 = 128 aligned.
;   8+32+96 = 136. 136%16=8. Need sub rsp 104: 8+32+104=144. 144%16=0. Good.
;   cmdbuf[64] at [rsp+48]
;   rbx=len, rsi=text_key, rdi=arg_key
handle_submission:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 104

    ; read_cmdline(cmdbuf, 64)
    lea rcx, [rsp+48]
    mov edx, 64
    call read_cmdline
    mov ebx, eax                    ; rbx = len

    ; Serial: "[CMD] " text_or_empty "\n"
    lea rcx, [rel str_ser_cmd]
    call serial_print
    test ebx, ebx
    jle .hs_empty_cmd
    lea rcx, [rsp+48]
    call serial_print
    jmp .hs_after_cmd
.hs_empty_cmd:
    lea rcx, [rel str_ser_empty_cmd]
    call serial_print
.hs_after_cmd:
    lea rcx, [rel str_newline]
    call serial_print

    ; herb_set_prop_int(input_ctl_eid, "submitted", 2)
    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_submitted]
    mov r8d, 2
    call herb_set_prop_int

    ; ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    add [rel total_ops], eax

    ; If len > 0: compute keys, dispatch
    test ebx, ebx
    jle .hs_empty_dispatch

    ; text_key = compute_text_key(cmdbuf)
    lea rcx, [rsp+48]
    call compute_text_key
    mov esi, eax                    ; rsi = text_key

    ; arg_key = compute_arg_key(cmdbuf)
    lea rcx, [rsp+48]
    call compute_arg_key
    mov edi, eax                    ; rdi = arg_key

    ; dispatch_text_command(text_key, arg_key, cmdbuf)
    mov ecx, esi
    mov edx, edi
    lea r8, [rsp+48]
    call dispatch_text_command
    jmp .hs_done

.hs_empty_dispatch:
    ; herb_snprintf(last_action, 80, "Shell: (empty)")
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_shell_empty]
    call herb_snprintf

.hs_done:
    add rsp, 104
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- cmd_swap_policy_from_herb(int which) ----
; Hot-swap scheduling policy. which: 1=round-robin, 2=priority.
; Stack: 4 pushes (rbp,rbx,rsi,rdi) + sub rsp 64 = 96 aligned.
;   8+32+64 = 104. 104%16=8. Need 4 pushes + sub rsp 72: 8+32+72=112. 112%16=0. Good.
;   rbx=which, rsi=old_name, rdi=label
cmd_swap_policy_from_herb:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 72

    mov ebx, ecx                    ; save which

    ; Remove old scheduling tension
    cmp ebx, 1
    jne .csp_remove_rr

    ; which==1: try remove "proc.schedule_ready", fallback to "proc.schedule_pri"
    lea rcx, [rel str_tn_schedule_ready]
    call herb_remove_tension_by_name
    test eax, eax
    jg .csp_removed_ready
    ; Fallback: remove proc.schedule_pri
    lea rcx, [rel str_tn_schedule_pri]
    call herb_remove_tension_by_name
    lea rsi, [rel str_tn_schedule_pri]
    jmp .csp_serial_removed

.csp_removed_ready:
    lea rsi, [rel str_tn_schedule_ready]
    jmp .csp_serial_removed

.csp_remove_rr:
    ; which==2: remove proc.schedule_rr
    lea rsi, [rel str_tn_schedule_rr]
    mov rcx, rsi
    call herb_remove_tension_by_name

.csp_serial_removed:
    ; saved removal result in eax
    mov edi, eax                    ; save removed count

    ; Serial: "[POLICY] Removed " old_name " (" removed ")\n"
    lea rcx, [rel str_ser_policy_rem]
    call serial_print
    mov rcx, rsi
    call serial_print
    lea rcx, [rel str_ser_space]
    call serial_print
    lea rcx, [rel str_ser_paren_l]
    call serial_print
    mov ecx, edi
    call serial_print_int
    lea rcx, [rel str_ser_paren_r_nl]
    call serial_print

    ; Load the requested policy
    cmp ebx, 1
    jne .csp_load_pri

    ; Load round-robin
    lea rcx, [rel program_schedule_roundrobin]
    mov edx, [rel program_schedule_roundrobin_len]
    mov r8d, -1
    lea r9, [rel str_empty]
    call herb_load_program
    ; Serial: "[POLICY] Loaded round-robin (" loaded " tensions)\n"
    lea rcx, [rel str_ser_policy_rr]
    call serial_print
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_ser_tensions_paren]
    call serial_print
    jmp .csp_clamp

.csp_load_pri:
    ; Load priority
    lea rcx, [rel program_schedule_priority]
    mov edx, [rel program_schedule_priority_len]
    mov r8d, -1
    lea r9, [rel str_empty]
    call herb_load_program
    ; Serial: "[POLICY] Loaded priority (" loaded " tensions)\n"
    lea rcx, [rel str_ser_policy_pri]
    call serial_print
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_ser_tensions_paren]
    call serial_print

.csp_clamp:
    ; Clamp selected_tension_idx
    call herb_tension_count
    cmp [rel selected_tension_idx], eax
    jl .csp_settle
    dec eax
    mov [rel selected_tension_idx], eax

.csp_settle:
    ; ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov edi, eax                    ; edi = ops
    add [rel total_ops], eax

    ; label = (which == 1) ? "ROUND-ROBIN" : "PRIORITY"
    cmp ebx, 1
    jne .csp_label_pri
    lea rsi, [rel str_round_robin]
    jmp .csp_format
.csp_label_pri:
    lea rsi, [rel str_priority_label]

.csp_format:
    ; herb_snprintf(last_action, 80, "Policy: %s (%d ops)", label, ops)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_policy]
    mov r9, rsi                     ; label
    mov [rsp+32], edi               ; ops = 5th arg
    call herb_snprintf

    ; Serial: "[POLICY] Settled: " label " ops=" ops "\n"
    lea rcx, [rel str_ser_policy_settled]
    call serial_print
    mov rcx, rsi
    call serial_print
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, edi
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    call report_buffer_state

    add rsp, 72
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; cmd_spawn(int requested_type) — Phase C Step 9
; 3 phases: HERB spawn signal -> create process -> load program
; Stack: 8 pushes (64) + sub rsp 248 = 320 aligned
;   sig_name[32] at [rsp+48], name[32] at [rsp+80]
;   rname[64] at [rsp+112], cname[64] at [rsp+176]
; Regs: r12=requested_type, r13=spawn_ops, r14=eid, r15=prog_type
;       rbx=pri, rsi=&name[rsp+80], rdi=prog_name_str
; ============================================================
cmd_spawn:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 248

    mov r12d, ecx               ; r12d = requested_type

    ; ---- Phase 1: HERB decides priority + program type ----

    ; make_sig_name(sig_name, 32, "spawn")
    lea rcx, [rsp+48]
    mov edx, 32
    lea r8, [rel str_pfx_spawn]
    call make_sig_name

    ; herb_create(sig_name, ET_SIGNAL, CN_SPAWN_SIG)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_spawn_sig]
    call herb_create
    test eax, eax
    js .cspn_skip_prop
    ; herb_set_prop_int(sig, "requested_type", requested_type)
    mov ecx, eax
    lea rdx, [rel str_requested_type]
    movsxd r8, r12d
    call herb_set_prop_int
.cspn_skip_prop:

    ; spawn_ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov r13d, eax               ; r13d = spawn_ops

    ; Read action = herb_entity_prop_int(spawn_ctl_eid, "action", 0)
    mov ecx, [rel spawn_ctl_eid]
    lea rdx, [rel str_action]
    xor r8d, r8d
    call herb_entity_prop_int
    cmp eax, 1
    je .cspn_action_ok

    ; action != 1: fail
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_spawn_fail]
    call herb_snprintf
    lea rcx, [rel str_ser_spawn_fail]
    call serial_print
    add [rel total_ops], r13d
    jmp .cspn_done

.cspn_action_ok:
    ; Read pri = herb_entity_prop_int(spawn_ctl_eid, "next_priority", 2)
    mov ecx, [rel spawn_ctl_eid]
    lea rdx, [rel str_next_priority]
    mov r8d, 2
    call herb_entity_prop_int
    mov ebx, eax                ; ebx = pri

    ; Read prog_type = herb_entity_prop_int(spawn_ctl_eid, "program_type", 1)
    mov ecx, [rel spawn_ctl_eid]
    lea rdx, [rel str_program_type]
    mov r8d, 1
    call herb_entity_prop_int
    mov r15d, eax               ; r15d = prog_type

    ; Reset action
    mov ecx, [rel spawn_ctl_eid]
    lea rdx, [rel str_action]
    xor r8d, r8d
    call herb_set_prop_int

    ; ---- Phase 2: Create process (mechanism) ----

    ; process_counter++
    lea rax, [rel process_counter]
    mov ecx, [rax]
    inc ecx
    mov [rax], ecx

    ; herb_snprintf(name, 32, "p%d", process_counter)
    lea rcx, [rsp+80]
    mov edx, 32
    lea r8, [rel str_fmt_pname]
    mov r9d, [rel process_counter]
    call herb_snprintf
    lea rsi, [rsp+80]           ; rsi = name ptr (kept for later)

    ; eid = herb_create(name, ET_PROCESS, CN_READY)
    lea rcx, [rsp+80]
    lea rdx, [rel str_et_process]
    lea r8, [rel str_cn_ready]
    call herb_create
    mov r14d, eax               ; r14d = eid
    test eax, eax
    jns .cspn_eid_ok

    ; eid < 0: fail
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_create_fail]
    call herb_snprintf
    add [rel total_ops], r13d
    jmp .cspn_done

.cspn_eid_ok:
    ; herb_set_prop_int(eid, "priority", pri)
    mov ecx, r14d
    lea rdx, [rel str_priority]
    movsxd r8, ebx
    call herb_set_prop_int

    ; herb_set_prop_int(eid, "time_slice", 3)
    mov ecx, r14d
    lea rdx, [rel str_time_slice]
    mov r8d, 3
    call herb_set_prop_int

    ; herb_set_prop_int(eid, "msgs_received", 0)
    mov ecx, r14d
    lea rdx, [rel str_msgs_received]
    xor r8d, r8d
    call herb_set_prop_int

    ; herb_set_prop_int(eid, "selected", 0)
    mov ecx, r14d
    lea rdx, [rel str_selected]
    xor r8d, r8d
    call herb_set_prop_int

    ; herb_set_prop_int(eid, "protected", 0)
    mov ecx, r14d
    lea rdx, [rel str_protected]
    xor r8d, r8d
    call herb_set_prop_int

    ; ---- Scoped resources: 2 pages + 2 FDs + 1 surface ----

    ; herb_snprintf(cname, 64, "%s::MEM_FREE", name)
    lea rcx, [rsp+176]
    mov edx, 64
    lea r8, [rel str_fmt_mem_free]
    lea r9, [rsp+80]
    call herb_snprintf

    ; herb_snprintf(rname, 64, "pg0_%s", name)
    lea rcx, [rsp+112]
    mov edx, 64
    lea r8, [rel str_fmt_pg0]
    lea r9, [rsp+80]
    call herb_snprintf

    ; herb_create(rname, ET_PAGE, cname)
    lea rcx, [rsp+112]
    lea rdx, [rel str_et_page]
    lea r8, [rsp+176]
    call herb_create

    ; herb_snprintf(rname, 64, "pg1_%s", name)
    lea rcx, [rsp+112]
    mov edx, 64
    lea r8, [rel str_fmt_pg1]
    lea r9, [rsp+80]
    call herb_snprintf

    ; herb_create(rname, ET_PAGE, cname)
    lea rcx, [rsp+112]
    lea rdx, [rel str_et_page]
    lea r8, [rsp+176]
    call herb_create

    ; herb_snprintf(cname, 64, "%s::FD_FREE", name)
    lea rcx, [rsp+176]
    mov edx, 64
    lea r8, [rel str_fmt_fd_free]
    lea r9, [rsp+80]
    call herb_snprintf

    ; herb_snprintf(rname, 64, "fd0_%s", name)
    lea rcx, [rsp+112]
    mov edx, 64
    lea r8, [rel str_fmt_fd0]
    lea r9, [rsp+80]
    call herb_snprintf

    ; herb_create(rname, ET_FD, cname)
    lea rcx, [rsp+112]
    lea rdx, [rel str_et_fd]
    lea r8, [rsp+176]
    call herb_create

    ; herb_snprintf(rname, 64, "fd1_%s", name)
    lea rcx, [rsp+112]
    mov edx, 64
    lea r8, [rel str_fmt_fd1]
    lea r9, [rsp+80]
    call herb_snprintf

    ; herb_create(rname, ET_FD, cname)
    lea rcx, [rsp+112]
    lea rdx, [rel str_et_fd]
    lea r8, [rsp+176]
    call herb_create

    ; herb_snprintf(cname, 64, "%s::SURFACE", name)
    lea rcx, [rsp+176]
    mov edx, 64
    lea r8, [rel str_fmt_surface]
    lea r9, [rsp+80]
    call herb_snprintf

    ; herb_snprintf(rname, 64, "surf_%s", name)
    lea rcx, [rsp+112]
    mov edx, 64
    lea r8, [rel str_fmt_surf]
    lea r9, [rsp+80]
    call herb_snprintf

    ; sid = herb_create(rname, ET_SURFACE, cname)
    lea rcx, [rsp+112]
    lea rdx, [rel str_et_surface]
    lea r8, [rsp+176]
    call herb_create
    test eax, eax
    js .cspn_no_surf
    ; herb_set_prop_int(sid, "kind", 1)
    mov ecx, eax
    mov edi, eax                ; save sid in edi temporarily
    lea rdx, [rel str_kind]
    mov r8d, 1
    call herb_set_prop_int
    ; herb_set_prop_int(sid, "state", 0)
    mov ecx, edi
    lea rdx, [rel str_state]
    xor r8d, r8d
    call herb_set_prop_int
    ; herb_set_prop_int(sid, "border_color", 0)
    mov ecx, edi
    lea rdx, [rel str_border_color]
    xor r8d, r8d
    call herb_set_prop_int
    ; herb_set_prop_int(sid, "fill_color", 0)
    mov ecx, edi
    lea rdx, [rel str_fill_color]
    xor r8d, r8d
    call herb_set_prop_int
.cspn_no_surf:

    ; ---- Load program based on HERB's decision (switch prog_type) ----
    lea rdi, [rel str_prog_unknown]     ; default prog_name

    cmp r15d, 1
    je .cspn_case1
    cmp r15d, 2
    je .cspn_case2
    cmp r15d, 3
    je .cspn_case3
    cmp r15d, 4
    je .cspn_case4
    jmp .cspn_after_load

.cspn_case1:
    ; Producer: set produced=0, produce_limit=1000
    mov ecx, r14d
    lea rdx, [rel str_produced]
    xor r8d, r8d
    call herb_set_prop_int
    mov ecx, r14d
    lea rdx, [rel str_produce_limit]
    mov r8d, 1000
    call herb_set_prop_int
    ; herb_load_program(program_producer, program_producer_len, eid, CN_CPU0)
    lea rcx, [rel program_producer]
    mov edx, [rel program_producer_len]
    mov r8d, r14d
    lea r9, [rel str_cn_cpu0]
    call herb_load_program
    lea rdi, [rel str_prog_producer]
    jmp .cspn_after_load

.cspn_case2:
    ; Consumer: set consumed=0
    mov ecx, r14d
    lea rdx, [rel str_consumed]
    xor r8d, r8d
    call herb_set_prop_int
    ; herb_load_program(program_consumer, program_consumer_len, eid, CN_CPU0)
    lea rcx, [rel program_consumer]
    mov edx, [rel program_consumer_len]
    mov r8d, r14d
    lea r9, [rel str_cn_cpu0]
    call herb_load_program
    lea rdi, [rel str_prog_consumer]
    jmp .cspn_after_load

.cspn_case3:
    ; Worker: set work=100
    mov ecx, r14d
    lea rdx, [rel str_work]
    mov r8d, 100
    call herb_set_prop_int
    ; herb_load_program(program_worker, program_worker_len, eid, CN_CPU0)
    lea rcx, [rel program_worker]
    mov edx, [rel program_worker_len]
    mov r8d, r14d
    lea r9, [rel str_cn_cpu0]
    call herb_load_program
    lea rdi, [rel str_prog_worker]
    jmp .cspn_after_load

.cspn_case4:
    ; Beacon: set pulses=0, limit=100
    mov ecx, r14d
    lea rdx, [rel str_pulses]
    xor r8d, r8d
    call herb_set_prop_int
    mov ecx, r14d
    lea rdx, [rel str_limit]
    mov r8d, 100
    call herb_set_prop_int
    ; herb_load_program(program_beacon, program_beacon_len, eid, CN_CPU0)
    lea rcx, [rel program_beacon]
    mov edx, [rel program_beacon_len]
    mov r8d, r14d
    lea r9, [rel str_cn_cpu0]
    call herb_load_program
    lea rdi, [rel str_prog_beacon]

.cspn_after_load:
    ; ---- Serial: "[PROGRAM] " prog_name " loaded for " name " tensions=" count ----
    lea rcx, [rel str_ser_program]
    call serial_print
    mov rcx, rdi
    call serial_print
    lea rcx, [rel str_ser_loaded_for]
    call serial_print
    lea rcx, [rsp+80]
    call serial_print
    lea rcx, [rel str_ser_tensions_eq]
    call serial_print
    call herb_tension_count
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    ; ---- Phase 3: Settle ----
    mov ecx, 100
    call ham_run_ham
    ; total_ops += spawn_ops + ops
    add eax, r13d
    add [rel total_ops], eax
    mov r13d, eax               ; r13d = total (spawn_ops + ops) for serial

    ; ---- Report ----
    ; Check produced (save to [rsp+240] temp slot)
    mov ecx, r14d
    lea rdx, [rel str_produced]
    mov r8, -1
    call herb_entity_prop_int
    test rax, rax
    js .cspn_no_produced
    mov [rsp+240], eax          ; save produced value
    lea rcx, [rel str_ser_proc]
    call serial_print
    lea rcx, [rsp+80]
    call serial_print
    lea rcx, [rel str_ser_produced]
    call serial_print
    mov ecx, [rsp+240]
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
.cspn_no_produced:

    ; Check consumed (save to [rsp+240] temp slot)
    mov ecx, r14d
    lea rdx, [rel str_consumed]
    mov r8, -1
    call herb_entity_prop_int
    test rax, rax
    js .cspn_no_consumed
    mov [rsp+240], eax          ; save consumed value
    lea rcx, [rel str_ser_proc]
    call serial_print
    lea rcx, [rsp+80]
    call serial_print
    lea rcx, [rel str_ser_consumed]
    call serial_print
    mov ecx, [rsp+240]
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
.cspn_no_consumed:

    ; herb_snprintf(last_action, 80, "Created %s (pri=%d) %s -> %d ops", name, pri, prog_name, total)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_created_prog]
    lea r9, [rsp+80]            ; name
    mov dword [rsp+32], ebx     ; pri (5th arg)
    mov [rsp+40], rdi           ; prog_name (6th arg)
    mov dword [rsp+48], r13d    ; total ops (7th arg)
    call herb_snprintf

    ; serial: "[NEW] " name " pri=" pri " (2pg 2fd) ops=" total
    lea rcx, [rel str_ser_new]
    call serial_print
    lea rcx, [rsp+80]
    call serial_print
    lea rcx, [rel str_ser_pri]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_ser_2pg2fd_ops]
    call serial_print
    mov ecx, r13d
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    call report_buffer_state

.cspn_done:
    add rsp, 248
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

%endif  ; KERNEL_MODE

%ifndef KERNEL_MODE
; ============================================================
; cmd_new_process() — Phase C Step 9 (non-KERNEL_MODE)
; Simple process creation for flat scheduler mode
; Stack: 4 pushes (32) + sub rsp 72 = 112 aligned
;   name[32] at [rsp+48]
; Regs: ebx=pri, esi=eid, edi=ops
; ============================================================
cmd_new_process:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 72

    ; process_counter++
    lea rax, [rel process_counter]
    mov ecx, [rax]
    inc ecx
    mov [rax], ecx

    ; herb_snprintf(name, 32, "p%d", process_counter)
    lea rcx, [rsp+48]
    mov edx, 32
    lea r8, [rel str_fmt_pname]
    mov r9d, [rel process_counter]
    call herb_snprintf

    ; pri = ((process_counter - 1) % 5 + 1) * 2
    mov eax, [rel process_counter]
    dec eax
    xor edx, edx
    mov ecx, 5
    div ecx
    lea ebx, [rdx+1]
    shl ebx, 1                 ; ebx = pri

    ; eid = herb_create(name, ET_PROCESS, CN_READY)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_process]
    lea r8, [rel str_cn_ready]
    call herb_create
    mov esi, eax                ; esi = eid
    test eax, eax
    jns .cnp_eid_ok

    ; eid < 0: fail
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_create_fail]
    call herb_snprintf
    jmp .cnp_done

.cnp_eid_ok:
    ; herb_set_prop_int(eid, "priority", pri)
    mov ecx, esi
    lea rdx, [rel str_priority]
    movsxd r8, ebx
    call herb_set_prop_int

    ; herb_set_prop_int(eid, "time_slice", 3)
    mov ecx, esi
    lea rdx, [rel str_time_slice]
    mov r8d, 3
    call herb_set_prop_int

    ; ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov edi, eax                ; edi = ops
    add [rel total_ops], eax

    ; herb_snprintf(last_action, 80, "Created %s (pri=%d) -> %d ops", name, pri, ops)
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_created]
    lea r9, [rsp+48]            ; name
    mov dword [rsp+32], ebx     ; pri (5th arg)
    mov dword [rsp+40], edi     ; ops (6th arg)
    call herb_snprintf

    ; serial: "[NEW] " name " pri=" pri " ops=" ops
    lea rcx, [rel str_ser_new]
    call serial_print
    lea rcx, [rsp+48]
    call serial_print
    lea rcx, [rel str_ser_pri]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, edi
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

.cnp_done:
    add rsp, 72
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
%endif  ; !KERNEL_MODE

; ============================================================
; handle_key(uint8_t scancode) — Phase C Step 10 (final function)
; Keyboard dispatch: scancode -> ASCII -> game/input/fallback routing
; Stack: 6 pushes (48) + sub rsp 136 = 192 aligned
;   cmdbuf[64] at [rsp+48], saved ints at [rsp+112..131]
; Regs: r12d=scancode, r13b=ch, ebx=ops, esi=prev_mode, rdi=temp
; ============================================================
handle_key:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 136

    ; ---- Key-up filter ----
    test cl, 0x80
    jnz .hk_done

    ; ---- Scancode -> ASCII ----
    movzx r12d, cl                      ; r12d = scancode (zero-extended)
    lea rax, [rel scancode_to_ascii]
    movzx r13d, byte [rax + r12]        ; r13b = ch

    ; ---- Set last_key_name ----
    lea rdi, [rel last_key_name]

    ; a-z?
    cmp r13b, 'a'
    jb .hk_not_letter
    cmp r13b, 'z'
    ja .hk_not_letter
    mov byte [rdi], r13b
    mov byte [rdi+1], 0
    jmp .hk_name_done

.hk_not_letter:
    cmp r13b, ' '
    jne .hk_not_space
    mov byte [rdi], 'S'
    mov byte [rdi+1], 'P'
    mov byte [rdi+2], 'C'
    mov byte [rdi+3], 0
    jmp .hk_name_done

.hk_not_space:
    cmp r13b, '+'
    je .hk_single_char
    cmp r13b, '='
    je .hk_plus_char
    cmp r13b, '['
    je .hk_single_char
    cmp r13b, ']'
    je .hk_single_char
    cmp r13b, '/'
    je .hk_single_char
    cmp r13b, 27                        ; ESC
    jne .hk_not_esc
    mov byte [rdi], 'E'
    mov byte [rdi+1], 'S'
    mov byte [rdi+2], 'C'
    mov byte [rdi+3], 0
    jmp .hk_name_done

.hk_not_esc:
    cmp r13b, 10                        ; newline / Enter
    jne .hk_not_enter
    mov byte [rdi], 'R'
    mov byte [rdi+1], 'E'
    mov byte [rdi+2], 'T'
    mov byte [rdi+3], 0
    jmp .hk_name_done

.hk_not_enter:
    cmp r13b, 8                         ; backspace
    jne .hk_other_key
    mov byte [rdi], 'B'
    mov byte [rdi+1], 'S'
    mov byte [rdi+2], 0
    jmp .hk_name_done

.hk_plus_char:
    mov r13b, '+'                       ; '=' maps to '+' for display
.hk_single_char:
    mov byte [rdi], r13b
    mov byte [rdi+1], 0
    jmp .hk_name_done

.hk_other_key:
    ; herb_snprintf(last_key_name, 16, "x%d", scancode)
    mov rcx, rdi
    mov edx, 16
    lea r8, [rel str_fmt_x_d]
    mov r9d, r12d
    call herb_snprintf

.hk_name_done:

    ; ---- Game mode: intercept arrow keys and space ----
%ifdef KERNEL_MODE
    mov ecx, [rel game_ctl_eid]
    test ecx, ecx
    js .hk_no_game
    ; herb_entity_prop_int(game_ctl_eid, "display_mode", 0)
    lea rdx, [rel str_display_mode]
    xor r8d, r8d
    call herb_entity_prop_int
    cmp eax, 1
    jne .hk_no_game

    ; Check arrow scancodes -> direction
    mov edi, -1                         ; direction = -1
    lea rsi, [rel str_empty]            ; dname = ""
    cmp r12d, 0x48                      ; Up
    jne .hk_not_up
    xor edi, edi                        ; direction = 0
    lea rsi, [rel str_dir_n]
    jmp .hk_check_dir
.hk_not_up:
    cmp r12d, 0x50                      ; Down
    jne .hk_not_down
    mov edi, 1
    lea rsi, [rel str_dir_s]
    jmp .hk_check_dir
.hk_not_down:
    cmp r12d, 0x4D                      ; Right
    jne .hk_not_right
    mov edi, 2
    lea rsi, [rel str_dir_e]
    jmp .hk_check_dir
.hk_not_right:
    cmp r12d, 0x4B                      ; Left
    jne .hk_check_space
    mov edi, 3
    lea rsi, [rel str_dir_w]

.hk_check_dir:
    test edi, edi
    js .hk_check_space
    cmp dword [rel player_eid], 0
    jl .hk_check_space

    ; Arrow key in game mode: move player
    ; herb_snprintf(last_key_name, 16, "%s", dname)
    lea rcx, [rel last_key_name]
    mov edx, 16
    lea r8, [rel str_fmt_s]
    mov r9, rsi                         ; dname
    call herb_snprintf

    ; Read old position
    mov ecx, [rel player_eid]
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+112], eax                  ; old px

    mov ecx, [rel player_eid]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+116], eax                  ; old py

    ; create_move_signal(direction)
    mov ecx, edi
    mov [rsp+120], edi                  ; save direction for later (edi clobbered)
    call create_move_signal

    ; ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov ebx, eax
    add [rel total_ops], eax

    ; Read new position
    mov ecx, [rel player_eid]
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+124], eax                  ; nx

    mov ecx, [rel player_eid]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+128], eax                  ; ny

    ; moved = (nx != px || ny != py)
    mov eax, [rsp+124]                  ; nx
    cmp eax, [rsp+112]                  ; px
    jne .hk_moved
    mov eax, [rsp+128]                  ; ny
    cmp eax, [rsp+116]                  ; py
    je .hk_not_moved
.hk_moved:
    mov edi, 1
    jmp .hk_move_serial
.hk_not_moved:
    xor edi, edi
.hk_move_serial:
    ; serial: "[GAME] move " + dname
    lea rcx, [rel str_ser_game_move]
    call serial_print
    mov rcx, rsi
    call serial_print
    ; if !moved: " BLOCKED"
    test edi, edi
    jnz .hk_move_no_block
    lea rcx, [rel str_ser_game_blocked]
    call serial_print
.hk_move_no_block:
    ; " pos=" + nx + "," + ny + " ops=" + ops
    lea rcx, [rel str_ser_pos]
    call serial_print
    mov ecx, [rsp+124]
    call serial_print_int
    lea rcx, [rel str_ser_comma]
    call serial_print
    mov ecx, [rsp+128]
    call serial_print_int
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    ; herb_snprintf(last_action, 80, moved ? "Move %s -> (%d,%d)" : "Blocked %s at (%d,%d)", dname, nx, ny)
    lea rcx, [rel last_action]
    mov edx, 80
    test edi, edi
    jz .hk_use_blocked_fmt
    lea r8, [rel str_la_move]
    jmp .hk_fmt_chosen
.hk_use_blocked_fmt:
    lea r8, [rel str_la_move_block]
.hk_fmt_chosen:
    mov r9, rsi                         ; dname
    mov eax, [rsp+124]
    mov dword [rsp+32], eax             ; nx (5th arg)
    mov eax, [rsp+128]
    mov dword [rsp+40], eax             ; ny (6th arg)
    call herb_snprintf

    call draw_full
    jmp .hk_done

.hk_check_space:
    ; Space key in game mode?
    cmp r13b, ' '
    jne .hk_no_game
    cmp dword [rel player_eid], 0
    jl .hk_no_game

    ; Gather action
    lea rdi, [rel last_key_name]
    mov byte [rdi], 'S'
    mov byte [rdi+1], 'P'
    mov byte [rdi+2], 'C'
    mov byte [rdi+3], 0

    ; prev_wood = herb_container_count(CN_GAME_TREE_GATHERED)
    lea rcx, [rel str_cn_game_tree_gathered]
    call herb_container_count
    test eax, eax
    jns .hk_prev_wood_ok
    xor eax, eax
.hk_prev_wood_ok:
    mov [rsp+112], eax                  ; prev_wood

    call create_gather_signal

    mov ecx, 100
    call ham_run_ham
    mov ebx, eax
    add [rel total_ops], eax

    ; new_wood = herb_container_count(CN_GAME_TREE_GATHERED)
    lea rcx, [rel str_cn_game_tree_gathered]
    call herb_container_count
    test eax, eax
    jns .hk_new_wood_ok
    xor eax, eax
.hk_new_wood_ok:
    mov [rsp+116], eax                  ; new_wood

    ; Read player pos
    mov ecx, [rel player_eid]
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+120], eax                  ; px

    mov ecx, [rel player_eid]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+124], eax                  ; py

    ; gathered = (new_wood > prev_wood)
    mov eax, [rsp+116]
    cmp eax, [rsp+112]
    jg .hk_did_gather
    xor edi, edi                        ; gathered = 0
    jmp .hk_gather_serial
.hk_did_gather:
    mov edi, 1
.hk_gather_serial:
    ; serial: "[GAME] gather"
    lea rcx, [rel str_ser_game_gather]
    call serial_print
    ; if !gathered: " FAIL"
    test edi, edi
    jnz .hk_gather_no_fail
    lea rcx, [rel str_ser_game_fail]
    call serial_print
.hk_gather_no_fail:
    ; " pos=" + px + "," + py + " wood=" + new_wood + " ops=" + ops
    lea rcx, [rel str_ser_pos]
    call serial_print
    mov ecx, [rsp+120]
    call serial_print_int
    lea rcx, [rel str_ser_comma]
    call serial_print
    mov ecx, [rsp+124]
    call serial_print_int
    lea rcx, [rel str_ser_game_wood]
    call serial_print
    mov ecx, [rsp+116]
    call serial_print_int
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    ; herb_snprintf(last_action, 80, gathered ? "Gathered! wood=%d" : "Nothing here (wood=%d)", new_wood)
    lea rcx, [rel last_action]
    mov edx, 80
    test edi, edi
    jz .hk_use_nothing_fmt
    lea r8, [rel str_la_gather_yes]
    jmp .hk_gather_fmt_chosen
.hk_use_nothing_fmt:
    lea r8, [rel str_la_gather_no]
.hk_gather_fmt_chosen:
    mov r9d, [rsp+116]                  ; new_wood
    call herb_snprintf

    call draw_full
    jmp .hk_done

.hk_no_game:
%endif  ; KERNEL_MODE

    ; ---- KERNEL_MODE input routing ----
%ifdef KERNEL_MODE
    mov ecx, [rel input_ctl_eid]
    test ecx, ecx
    js .hk_no_input

    ; prev_mode = herb_entity_prop_int(input_ctl_eid, "mode", 0)
    lea rdx, [rel str_mode]
    xor r8d, r8d
    call herb_entity_prop_int
    mov esi, eax                        ; esi = prev_mode

    ; create_key_signal(ch)
    movsx ecx, r13b
    call create_key_signal

    ; ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov ebx, eax
    add [rel total_ops], eax

    ; Read routing decisions
    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_pending_cmd]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+112], eax                  ; pending_cmd

    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_pending_arg]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+116], eax                  ; pending_arg

    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_mech_action]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+120], eax                  ; mech_action

    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_submitted]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+124], eax                  ; submitted

    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_mode]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+128], eax                  ; cur_mode

    ; Phase 2a: Command dispatch
    cmp dword [rsp+112], 0              ; pending_cmd > 0?
    jle .hk_no_cmd
    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_pending_cmd]
    xor r8d, r8d
    call herb_set_prop_int
    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_pending_arg]
    xor r8d, r8d
    call herb_set_prop_int
    mov ecx, [rsp+112]                  ; cmd_id
    mov edx, [rsp+116]                  ; arg_id
    call dispatch_cmd_from_route
.hk_no_cmd:

    ; Phase 2b: Mechanism dispatch
    cmp dword [rsp+120], 0              ; mech_action > 0?
    jle .hk_no_mech
    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_mech_action]
    xor r8d, r8d
    call herb_set_prop_int
    mov ecx, [rsp+120]
    call dispatch_mech_action
.hk_no_mech:

    ; Phase 2c: Text submission
    cmp dword [rsp+124], 1              ; submitted == 1?
    jne .hk_no_submit
    call handle_submission
.hk_no_submit:

    ; Serial output for text mode
    mov eax, [rsp+128]                  ; cur_mode
    cmp eax, 1
    je .hk_text_serial
    cmp esi, 1                          ; prev_mode == 1?
    jne .hk_no_text_serial
.hk_text_serial:
    ; read_cmdline(cmdbuf, 64)
    lea rcx, [rsp+48]
    mov edx, 64
    call read_cmdline
    mov edi, eax                        ; edi = clen

    ; Re-read cur_mode (may have changed during submission)
    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_mode]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+128], eax                  ; update cur_mode

    ; serial: "[INPUT] mode=" + cur_mode + " len=" + clen
    lea rcx, [rel str_ser_input_mode]
    call serial_print
    mov ecx, [rsp+128]
    call serial_print_int
    lea rcx, [rel str_ser_len]
    call serial_print
    mov ecx, edi
    call serial_print_int
    ; if clen > 0: " buf=" + cmdbuf
    test edi, edi
    jle .hk_no_buf_print
    lea rcx, [rel str_ser_buf]
    call serial_print
    lea rcx, [rsp+48]
    call serial_print
.hk_no_buf_print:
    lea rcx, [rel str_newline]
    call serial_print
.hk_no_text_serial:

    ; Mode transition messages
    test esi, esi                       ; prev_mode == 0?
    jnz .hk_no_enter_text
    cmp dword [rsp+128], 1             ; cur_mode == 1?
    jne .hk_no_enter_text
    ; Just entered text mode
    lea rcx, [rel str_ser_text_enter]
    call serial_print
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_text_mode]
    call herb_snprintf
    jmp .hk_input_draw

.hk_no_enter_text:
    ; Check: unknown key in command mode
    cmp dword [rsp+112], 0              ; pending_cmd == 0?
    jne .hk_input_draw
    cmp dword [rsp+120], 0              ; mech_action == 0?
    jne .hk_input_draw
    cmp dword [rsp+124], 0              ; submitted == 0?
    jne .hk_input_draw
    test esi, esi                       ; prev_mode == 0?
    jnz .hk_input_draw
    cmp dword [rsp+128], 0             ; cur_mode == 0?
    jne .hk_input_draw
    ; Unknown key in command mode
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_unknown_key]
    mov r9d, r12d                       ; scancode
    call herb_snprintf

.hk_input_draw:
    call draw_full
    jmp .hk_done

.hk_no_input:
%endif  ; KERNEL_MODE

    ; ---- Non-KERNEL_MODE fallback ----
%ifndef KERNEL_MODE
    cmp r13b, 'n'
    jne .hk_fb_not_n
    call cmd_new_process
    jmp .hk_fb_draw
.hk_fb_not_n:
%endif
    cmp r13b, 't'
    jne .hk_fb_not_t
    call cmd_timer
    jmp .hk_fb_draw
.hk_fb_not_t:
    cmp r13b, '+'
    je .hk_fb_boost
    cmp r13b, '='
    je .hk_fb_boost
    jmp .hk_fb_not_boost
.hk_fb_boost:
    call cmd_boost
    jmp .hk_fb_draw
.hk_fb_not_boost:
    cmp r13b, ' '
    jne .hk_fb_default
    call cmd_step
    jmp .hk_fb_draw
.hk_fb_default:
    ; Unknown key
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_unknown_key]
    mov r9d, r12d
    call herb_snprintf
.hk_fb_draw:
    call draw_full

.hk_done:
    add rsp, 136
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
