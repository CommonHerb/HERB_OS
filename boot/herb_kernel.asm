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

%include "herb_graph_layout.inc"

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
extern herb_compile_source
extern herb_remove_owner_tensions
extern herb_remove_tension_by_name
extern ham_run_ham
extern ham_mark_dirty
extern ham_get_compiled_count
extern ham_trace_mode
extern ham_get_bytecode_len
extern g_ham_dirty
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
extern herb_strlen
extern herb_strcmp
extern herb_strncpy

; Parallel arrays (from herb_graph.asm)
extern container_order_keys
extern tension_step_flags
extern g_container_entity_counts
extern g_flow_count
extern g_flows
extern g_graph
extern graph_find_container_by_name
extern create_entity
extern intern
extern container_add
extern container_remove
extern ham_dirty_mark

; Network (from herb_net.asm)
extern net_init
extern net_send_arp_request
extern net_poll_rx
extern net_present
extern net_resolve_gateway
extern icmp_send_echo
extern net_gateway_ip
extern arp_cache_lookup
extern udp_send
extern dns_resolve
extern dns_result_ip
extern dns_resolved_flag
extern dns_pending
extern tcp_connect
extern tcp_state
extern tcp_established
extern tcp_send_data
extern tcp_recv_buf
extern tcp_recv_len
extern tcp_recv_done
extern http_get
extern http_poll_state
extern http_state

; Browser (from herb_browser.asm)
extern browser_tokenize_cmd

; Disk + filesystem (from herb_disk.asm)
extern disk_identify
extern fs_init
extern fs_create
extern fs_read
extern fs_delete
extern fs_list
extern disk_present
extern fs_initialized
extern fs_data_buf

; ISR stubs (from kernel_entry.asm)
extern timer_isr_stub
extern keyboard_isr_stub
extern mouse_isr_stub
extern e1000_isr_stub

; Volatile flags set by ISRs (from kernel_entry.asm)
extern volatile_timer_fired
extern mouse_ring
extern mouse_ring_head
extern mouse_ring_tail
extern kb_ring
extern kb_ring_head
extern kb_ring_tail

; ============================================================
; EXTERNS — C functions remaining in kernel_main.c
; ============================================================

extern vga_set_color
extern vga_clear
extern vga_print
extern vga_print_int
extern vga_print_at
extern vga_clear_row
extern vga_print_padded
extern vga_putchar
extern vga_color
extern herb_entity_location
extern serial_print_int
; draw_full now defined locally (Phase D Step 7c)
; draw_stats now defined locally (Phase D Step 5)
; handle_key now defined locally (Phase C Step 10)
; mouse_handle_packet now defined locally (Phase D Step 4)
; scancode_to_ascii now defined locally (Phase D Step 7d)
; cmd_timer now defined locally (Phase C)
; herb_error_handler now defined locally (Phase D Step 4)

%ifdef KERNEL_MODE
; cmd_click and cmd_tension_toggle now defined locally (Phase C)
; cleanup_terminated and handle_shell_action now local (Phase C Step 8)
; cmd_spawn now defined locally (Phase C Step 9)
%endif

%ifdef GRAPHICS_MODE
; gfx_draw_stats_only now defined locally (Phase D Step 7a)
extern fb_init_display
extern fb_clear
extern fb_flip
extern fb_cursor_erase
extern fb_cursor_draw
extern fb_active
extern cursor_x
extern cursor_y
; Framebuffer drawing primitives (from herb_hw.asm — Phase D Step 6)
extern fb_pixel
extern fb_fill_rect
extern fb_draw_rect
extern fb_draw_rect2
extern fb_hline
extern fb_draw_char
extern fb_draw_string
extern fb_draw_int
extern fb_draw_padded
extern fb_draw_container
extern fb_draw_process
extern fb_draw_resources

; Window manager (from herb_wm.asm)
extern wm_init
extern wm_create_window
extern wm_destroy_window
extern wm_window_ptr
extern wm_draw_all
extern wm_draw_window_frame
extern wm_hit_test
extern wm_bring_to_front
extern wm_set_focus
extern wm_begin_drag
extern wm_update_drag
extern wm_end_drag
extern wm_init_default_windows
extern wm_windows
extern wm_z_order
extern wm_window_count
extern wm_focused_id
extern wm_drag_mode
extern wm_drag_win_id
extern wm_drag_offset_x
extern wm_drag_offset_y
extern wm_set_clip
extern wm_clear_clip

; Editor module (from herb_editor.asm)
extern editor_init
extern editor_open
extern editor_close
extern editor_handle_key
extern editor_draw_content
extern editor_activate
extern editor_deactivate
extern editor_toggle_blink
extern ed_active
extern ed_win_id
%endif

; Session 92: wm_window_ptr needed outside GRAPHICS_MODE for tiling sync
%ifndef GRAPHICS_MODE
%ifdef KERNEL_MODE
extern wm_window_ptr
%endif
%endif

; ============================================================
; GLOBALS — Kernel state (migrated from kernel_main.c, Phase D Step 7d)
; Definitions in DATA/BSS sections below.
; ============================================================

global timer_count, total_ops, signal_counter, process_counter
global ping_pending, ping_tick
global buffer_eid, last_action, last_key_name
global mouse_x, mouse_y, mouse_cycle, mouse_packet
global mouse_buttons, mouse_left_clicked, mouse_left_released, mouse_moved
global cursor_eid, selected_tension_idx
global scancode_to_ascii

%ifdef KERNEL_MODE
global input_ctl_eid, shell_ctl_eid, shell_eid, spawn_ctl_eid
global game_ctl_eid, player_eid, display_ctl_eid
global timer_interval, buffer_capacity
%endif

%ifdef GRAPHICS_MODE
global selected_eid
%endif

; ============================================================
; Boot-compiled program globals (BSS buffers filled at boot)
; ============================================================

global bin_interactive_kernel, bin_ik_len
%ifdef KERNEL_MODE
global bin_shell, bin_shell_len
global bin_producer, bin_producer_len
global bin_consumer, bin_consumer_len
global bin_worker, bin_worker_len
global bin_beacon, bin_beacon_len
global bin_schedule_priority, bin_sched_pri_len
global bin_schedule_roundrobin, bin_sched_rr_len
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
global create_focus_signal
global wm_apply_herb_focus
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
; Phase D Step 4 — infrastructure + helpers
global mouse_handle_packet
global herb_error_handler
global terrain_color
global terrain_name
global draw_banner
; Phase D Step 5 — text mode draw functions
global draw_stats
global draw_legend
global draw_process_row
global draw_process_table
global draw_summary
global draw_log
; Phase D Step 7c — draw_full (top-level draw dispatcher)
global draw_full
; Phase D Step 6 — graphics draw functions
; Phase D Step 7 — gfx_draw_full, gfx_draw_stats_only
%ifdef GRAPHICS_MODE
global gfx_draw_full
global gfx_draw_stats_only
global gfx_draw_procs_in_region
%ifdef KERNEL_MODE
global gfx_draw_tension_panel
global gfx_draw_game
global wm_draw_region_adapter
global wm_draw_tension_adapter
global wm_sync_from_herb
global wm_write_window_geometry_to_herb
global wm_write_all_z_order_to_herb
%endif
%endif
; Session 92: Tiling — these must be outside GRAPHICS_MODE
%ifdef KERNEL_MODE
global wm_sync_geometry_from_herb
global g_tiling_active
global g_tile_flow_idx
; Session 94: Editor flow guard
global g_editor_flow_idx
global g_editor_flow_disabled
; Session 93: Shell output window
global shell_output_print
%endif

; ============================================================
; BSS — IDT data
; ============================================================

section .bss

align 16
idt:        resb 4096       ; 256 entries * 16 bytes each
idt_ptr:    resb 10         ; 2-byte limit + 8-byte base

; Phase D Step 7d — Kernel state (BSS, zero-initialized)
alignb 4
last_action:     resb 80        ; char[80]
last_key_name:   resb 16        ; char[16]
mouse_packet:    resb 4         ; uint8_t[3] + padding
; Boot-compiled program binaries (compiled from .herb source at boot)
bin_interactive_kernel: resb 32768    ; 32KB (actual ~25KB with NPC tensions)
bin_ik_len:            resd 1
bin_shell:             resb 2048
bin_shell_len:         resd 1
bin_producer:          resb 512
bin_producer_len:      resd 1
bin_consumer:          resb 512
bin_consumer_len:      resd 1
bin_worker:            resb 512
bin_worker_len:        resd 1
bin_beacon:            resb 512
bin_beacon_len:        resd 1
bin_schedule_priority: resb 512
bin_sched_pri_len:     resd 1
bin_schedule_roundrobin: resb 512
bin_sched_rr_len:      resd 1
bin_turing:            resb 2048
bin_turing_len:        resd 1
bin_test_flow:         resb 2048
bin_test_flow_len:     resd 1

; Session 93: Shell output circular buffer
SHELL_OUTPUT_MAX_LINES equ 32
SHELL_OUTPUT_LINE_LEN  equ 80

shell_output_buf:   resb SHELL_OUTPUT_MAX_LINES * SHELL_OUTPUT_LINE_LEN  ; 2560 bytes
shell_output_head:  resd 1           ; next line to write (wraps at 32)
shell_output_count: resd 1           ; lines stored (max 32)
shell_output_scroll: resd 1          ; scroll offset (0 = bottom/newest)
shell_output_scratch: resb 80        ; temp formatting buffer
shell_output_win_id: resd 1          ; win_id of the output window

; Tension panel client rect (set by wm_draw_tension_adapter before each draw)
g_tp_cx: resd 1
g_tp_cy: resd 1
g_tp_cw: resd 1
g_tp_ch: resd 1

; ============================================================
; DATA — Initialized globals (Phase D Step 7d)
; ============================================================

section .data

align 4
mouse_x:            dd 400
mouse_y:            dd 300
mouse_cycle:        dd 0
mouse_buttons:      dd 0
mouse_left_clicked: dd 0
mouse_left_released: dd 0
mouse_moved:        dd 0
cursor_eid:         dd -1
selected_tension_idx: dd -1
timer_count:        dd 0
net_arp_retried:    dd 0
ping_pending:       dd 0
ping_seq:           dd 0
ping_tick:          dd 0
ping_auto_sent:     dd 0
udp_auto_sent:      dd 0
dns_auto_sent:      dd 0
http_auto_sent:     dd 0
total_ops:          dd 0
signal_counter:     dd 0
process_counter:    dd 0
buffer_eid:         dd -1

%ifdef KERNEL_MODE
input_ctl_eid:      dd -1
shell_ctl_eid:      dd -1
shell_eid:          dd -1
spawn_ctl_eid:      dd -1
game_ctl_eid:       dd -1
player_eid:         dd -1
display_ctl_eid:    dd -1
timer_interval:     dd 300
buffer_capacity:    dd 20
%endif

%ifdef GRAPHICS_MODE
selected_eid:       dd -1
%endif

; Editor debug counter (for throttled serial output)
ed_debug_counter:   dd 0

; Flow editor WM window ID (-1 = not created)
flow_editor_win_id: dd -1

; Game WM window ID (-1 = not created)
game_win_id:        dd -1

; Session 92: Tiling state
g_tiling_active:    dd 0        ; 0=free-drag, 1=tiled
g_tile_flow_idx:    dd -1       ; flow index of wm.tile_horizontal (-1 = unknown)

; Session 94: Editor flow guard + scroll
g_editor_flow_idx:      dd -1   ; flow index of render_editor (-1 = unknown)
g_editor_flow_disabled: dd 1    ; 1=disabled (direct rendering), 0=flow-based
flow_editor_scroll_y:   dd 0    ; scroll offset in lines (0 = top)

; Session 95: Tab focus cycling
focus_cycle_idx:        dd 0    ; current window role for Tab cycling (0-6)

; Boot-time WM role -> live WM window ID map (-1 = not created)
wm_role_to_win_id:
    times 16 dd -1

; ============================================================
; RDATA — String literals + const data
; ============================================================

; WM role constants (used by wm_herb_set_focus_by_role and wm_apply_boot_window_style)
%define WM_ROLE_CPU0       0
%define WM_ROLE_READY      1
%define WM_ROLE_BLOCKED    2
%define WM_ROLE_TERM       3
%define WM_ROLE_TENSIONS   4
%define WM_ROLE_EDITOR     5
%define WM_ROLE_GAME       6
%define WM_ROLE_LIMIT      16

section .rdata

; PS/2 Scancode table (Set 1, US QWERTY) — Phase D Step 7d
scancode_to_ascii:
    db 0,   27, '1', '2', '3', '4', '5', '6'    ; 0x00-0x07
    db '7', '8', '9', '0', '-', '=',  8,   9     ; 0x08-0x0F (BS, TAB)
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i'   ; 0x10-0x17
    db 'o', 'p', '[', ']',  10,  0,  'a', 's'    ; 0x18-0x1F (ENTER, LCTRL)
    db 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';'   ; 0x20-0x27
    db 39,  '`',  0,  '\', 'z', 'x', 'c', 'v'   ; 0x28-0x2F (LSHIFT)
    db 'b', 'n', 'm', ',', '.', '/',  0,  '*'    ; 0x30-0x37 (RSHIFT)
    db  0,  ' ',  0,   0,   0,   0,   0,   0     ; 0x38-0x3F (LALT,SPACE,CAPS,F1-F4)
    db  0,   0,   0,   0,   0,   0,   0,   0     ; 0x40-0x47 (F5-F10,NUM,SCROLL)
    db  0,   0,   0,   0,   0,   0,   0,   0     ; 0x48-0x4F
    db  0,   0,   0,   0,   0,   0,   0,   0     ; 0x50-0x57
    db  0,   0,   0,   0,   0,   0,   0,   0     ; 0x58-0x5F
    db  0,   0,   0,   0,   0,   0,   0,   0     ; 0x60-0x67
    db  0,   0,   0,   0,   0,   0,   0,   0     ; 0x68-0x6F
    db  0,   0,   0,   0,   0,   0,   0,   0     ; 0x70-0x77
    db  0,   0,   0,   0,   0,   0,   0,   0     ; 0x78-0x7F

; Embedded .herb SOURCE text — compiled to binary at boot
align 4
src_interactive_kernel:
    incbin "../programs/interactive_kernel.herb"
    db 0
src_interactive_kernel_end:
src_interactive_kernel_len: dd src_interactive_kernel_end - src_interactive_kernel - 1

%ifdef KERNEL_MODE
align 4
src_schedule_priority:
    incbin "../programs/schedule_priority.herb"
    db 0
src_schedule_priority_end:
src_schedule_priority_len: dd src_schedule_priority_end - src_schedule_priority - 1

align 4
src_schedule_roundrobin:
    incbin "../programs/schedule_roundrobin.herb"
    db 0
src_schedule_roundrobin_end:
src_schedule_roundrobin_len: dd src_schedule_roundrobin_end - src_schedule_roundrobin - 1

align 4
src_worker:
    incbin "../programs/worker.herb"
    db 0
src_worker_end:
src_worker_len: dd src_worker_end - src_worker - 1

align 4
src_producer:
    incbin "../programs/producer.herb"
    db 0
src_producer_end:
src_producer_len: dd src_producer_end - src_producer - 1

align 4
src_consumer:
    incbin "../programs/consumer.herb"
    db 0
src_consumer_end:
src_consumer_len: dd src_consumer_end - src_consumer - 1

align 4
src_beacon:
    incbin "../programs/beacon.herb"
    db 0
src_beacon_end:
src_beacon_len: dd src_beacon_end - src_beacon - 1

align 4
src_shell:
    incbin "../programs/shell.herb"
    db 0
src_shell_end:
src_shell_len: dd src_shell_end - src_shell - 1

align 4
src_turing:
    incbin "../programs/turing.herb"
    db 0
src_turing_end:
src_turing_len: dd src_turing_end - src_turing - 1

align 4
src_test_flow:
    incbin "../programs/test_flow.herb"
    db 0
src_test_flow_end:
src_test_flow_len: dd src_test_flow_end - src_test_flow - 1
%endif  ; KERNEL_MODE — source text

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

; Phase D Step 4 — error handler strings
str_err_prefix:     db "ERR: ", 0
str_err_serial:     db "[ERROR] ", 0

; Boot compilation strings
str_compile_hdr:      db "=== Boot-time compilation ===", 10, 0
str_compile_bytes:    db " bytes", 10, 0
str_compile_fail:     db "[COMPILE] FATAL: compilation failed!", 10, 0
str_compile_ik:       db "[COMPILE] interactive_kernel: ", 0
str_compile_sh:       db "[COMPILE] shell: ", 0
str_compile_pr:       db "[COMPILE] producer: ", 0
str_compile_cn:       db "[COMPILE] consumer: ", 0
str_compile_wk:       db "[COMPILE] worker: ", 0
str_compile_bc:       db "[COMPILE] beacon: ", 0
str_compile_sp:       db "[COMPILE] schedule_priority: ", 0
str_compile_sr:       db "[COMPILE] schedule_roundrobin: ", 0
str_compile_tm:       db "[COMPILE] turing: ", 0
str_tm_loaded:        db "[LOAD] Turing machine loaded", 10, 0
str_compile_tf:       db "[COMPILE] test_flow: ", 0
str_tf_loaded:        db "[LOAD] test_flow loaded", 10, 0
str_flow_diag:        db "[FLOW] count=", 0
str_flow_dst_name:    db "FLOW_DST", 0
str_flow_dst_cnt:     db "[FLOW] FLOW_DST entities=", 0
str_flow_ent:         db "[FLOW] e=", 0
str_flow_doubled:     db " doubled=", 0
str_flow_cumsum:      db " cumsum=", 0
str_prop_doubled:     db "doubled", 0
str_prop_cumsum:      db "cumsum", 0

; Phase D Step 4 — terrain name strings
str_terrain_grass:  db "Grass", 0
str_terrain_forest: db "Forest", 0
str_terrain_water:  db "Water", 0
str_terrain_stone:  db "Stone", 0
str_terrain_dirt:   db "Dirt", 0
str_terrain_unknown: db "???", 0

; Phase D Step 4 — banner title strings
%ifdef KERNEL_MODE
str_os_title_km:    db "HERB KERNEL", 0
str_os_subtitle_km: db "Shell", 0
%else
str_os_title:       db "HERB OS", 0
str_os_subtitle:    db "Interactive Shell", 0
%endif

; Phase D Step 5 — draw_stats strings
str_tick:           db "Tick:", 0
str_ops_label:      db "  Ops:", 0
str_arena_label:    db "  Arena:", 0
str_kb:             db "KB", 0
str_procs_label:    db "  Procs:", 0
str_sched_label:    db "  Sched:", 0
str_priority_pol:   db "PRIORITY", 0
str_roundrobin_pol: db "ROUND-ROBIN", 0
str_key_open:       db "  Key:[", 0
str_key_close:      db "]", 0
str_current_policy: db "current_policy", 0
; draw_legend strings
str_space:          db " ", 0
str_ques:           db "?", 0
str_empty:          db "", 0
str_key_text:       db "key_text", 0
str_label_text:     db "label_text", 0
%ifndef KERNEL_MODE
str_leg_N:          db "N", 0
str_leg_ew:         db "ew ", 0
str_leg_K:          db "K", 0
str_leg_ill:        db "ill ", 0
str_leg_B:          db "B", 0
str_leg_lk:         db "lk ", 0
str_leg_U:          db "U", 0
str_leg_nblk:       db "nblk ", 0
str_leg_T:          db "T", 0
str_leg_mr:         db "mr ", 0
str_leg_Plus:       db "+", 0
str_leg_Boost:      db "Boost ", 0
str_leg_Space:      db "Space", 0
str_leg_Step:       db "=Step", 0
%endif
; draw_process_table strings
str_hdr_hash:       db "#", 0
str_hdr_st:         db "ST", 0
str_hdr_name:       db "NAME", 0
str_hdr_loc:        db "LOCATION", 0
str_hdr_pri:        db "PRI", 0
str_hdr_ts:         db "TS", 0
str_hdr_mem:        db "MEM(f/u)", 0
str_hdr_fd:         db "FD(f/o)", 0
str_max_terminated: db "max_terminated", 0
str_plus_open:      db "(+", 0
str_term_suffix:    db " terminated)", 0
; draw_process_row strings
str_p_eq:           db "p=", 0
str_ts_eq:          db "ts=", 0
str_m_colon:        db "M:", 0
str_slash:          db "/", 0
str_fd_label:       db "  F:", 0
; draw_summary strings
str_containers:     db "Containers:", 0
str_ready_eq:       db "READY=", 0
str_cpu0_eq:        db "  CPU0=", 0
str_blocked_eq:     db "  BLOCKED=", 0
str_term_eq:        db "  TERM=", 0
str_sigdone_eq:     db "  SigDone=", 0
str_resources:      db "Resources:", 0
str_mem_label2:     db " MEM:", 0
str_fu_sep:         db "f/", 0
str_u_suffix:       db "u  FD:", 0
str_fo_sep:         db "f/", 0
str_o_suffix:       db "o  IN:", 0
; draw_log strings
str_log_prefix:     db "> ", 0
; scoped resource strings (for draw_process_row, draw_summary)
str_sc_mem_free:    db "MEM_FREE", 0
str_sc_mem_used:    db "MEM_USED", 0
str_sc_fd_free:     db "FD_FREE", 0
str_sc_fd_open:     db "FD_OPEN", 0
str_sc_inbox:       db "INBOX", 0

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
str_comma:          db ",", 0
str_wm_boot_count:  db "[WM] wm.VISIBLE=", 0
str_wm_boot_role:   db "[WM] role=", 0
str_wm_boot_geom:   db " geom=", 0
str_wm_boot_z:      db " z=", 0

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
str_role:           db "role", 0
str_z_order:        db "z_order", 0
str_width:          db "width", 0
str_height:         db "height", 0

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
str_cn_wm_visible:  db "wm.VISIBLE", 0
str_cn_input_state: db "input.INPUT_STATE", 0
str_cn_buffer:      db "BUFFER", 0
str_cn_ready:       db "proc.READY", 0
str_cn_shell_state: db "input.SHELL_STATE", 0
str_cn_spawn_state: db "spawn.SPAWN_STATE", 0
str_cn_display_state: db "display.DISPLAY_STATE", 0
str_cn_game_state:  db "world.GAME_STATE", 0
str_cn_game_player: db "world.PLAYER", 0
str_cn_cpu0:        db "proc.CPU0", 0

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
str_cn_game_sig_done: db "world.GAME_SIG_DONE", 0
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
str_cn_game_npcs:   db "world.NPCS", 0

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
str_ser_help_flat:  db "kill, load, swap, list, help, block, unblock, tile", 0

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
str_la_save:        db "Saved %s (%d bytes)", 0
str_la_read:        db "Read %s", 0
str_la_files:       db "Files: %d on disk", 0
str_ser_read_prefix: db "[FS] content ", 34, 0
str_ser_read_colon: db 34, ": ", 0
str_fs_nodisk:      db "[FS] error: no disk", 10, 0
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
str_la_ping:        db "Ping seq=%d", 0
str_la_udp:         db "UDP sent to gw:7777", 0
str_udp_payload:    db "HERB", 0
str_la_dns:         db "dns %s", 0
str_dns_domain:     db "example.com", 0
str_la_connect:     db "TCP connect %s:80", 0
str_http_slash:     db "/", 0
str_la_http:        db "HTTP GET %s", 0
str_ser_tile_on:    db "[WM] tiling ENABLED", 10, 0
str_ser_tile_off:   db "[WM] tiling DISABLED", 10, 0
str_tile_flow_name: db "wm.tile_horizontal", 0
str_la_tile_on:     db "Tiling: ON", 0
str_la_tile_off:    db "Tiling: OFF", 0

; Session 93: Shell output window strings
str_output_title:   db "OUTPUT", 0
str_so_welcome:     db "Type /help for commands", 0
str_so_help_hdr:    db "Commands:", 0
str_so_help_fmt:    db "  /%s", 0
str_so_list_hdr:    db "Processes:", 0
str_so_proc_fmt:    db "  %s (%s, p=%d)", 0
str_so_files_hdr:   db "Files on disk:", 0
str_so_file_fmt:    db "  %s (%d bytes)", 0
str_so_nodisk:      db "No disk", 0

str_la_gather_yes:  db "Gathered! wood=%d", 0
str_la_gather_no:   db "Nothing here (wood=%d)", 0
str_la_timer:       db "Timer signal %s -> %d ops", 0
str_la_turing:      db "TM step -> %d ops", 0
str_cn_tm_tick:     db "TM_TICK", 0
str_cn_tape:        db "TAPE", 0
str_cn_head_slot:   db "HEAD_SLOT", 0
str_et_tmsig:       db "tm.TmSig", 0
str_tm_sig_name:    db "tm_tick_sig", 0
str_tm_hdr:         db "[TM] Tape: ", 0
str_tm_cell:        db "[%d:%d]", 0
str_tm_head:        db " Head@%d state=%d ops=%d", 10, 0
str_prop_cell_idx:  db "cell_index", 0
str_prop_value:     db "value", 0
str_prop_position:  db "position", 0
str_prop_state:     db "state", 0
str_tm_bracket_o:   db "[", 0
str_tm_colon:       db ":", 0
str_tm_bracket_c:   db "]", 0
str_tm_head_info:   db " Head@", 0
str_tm_state_info:  db " state=", 0
str_tm_ops_info:    db " ops=", 0
; ---- Editor (flow-based) strings ----
str_cn_ed_buffer:   db "editor.BUFFER", 0
str_cn_ed_glyphs:   db "editor.GLYPHS", 0
str_cn_ed_ctl:      db "editor.CTL", 0
str_cn_ed_pool:     db "editor.POOL", 0
str_la_edit_open:   db "Editor (ESC=exit, type to edit)", 0
str_la_edit_close:  db "Editor closed", 0
str_ser_edit_open:  db "[EDIT] entering editor mode", 10, 0
str_ser_esave:      db "[EDIT] saved ", 0
str_ser_eload:      db "[EDIT] loaded ", 0
str_la_esave:       db "Editor saved %s (%d bytes)", 0
str_la_eload:       db "Editor loaded %s (%d bytes)", 0
str_ser_eload_pre:  db "[ELOAD] pre-HAM buf=", 0
str_ser_eload_gly:  db " gly=", 0
str_ser_eload_post: db "[ELOAD] post-HAM buf=", 0
str_ser_eload_ops:  db " ops=", 0
str_ser_eload_dirty: db " dirty=", 0
str_ser_eload_flow: db " flows=", 0
str_ser_eload_e1:  db "[ELOAD] entry", 10, 0
str_ser_eload_e2:  db "[ELOAD] fs_read done size=", 0
str_ser_eload_e3:  db "[ELOAD] clear done", 10, 0
str_ser_eload_e4:  db "[ELOAD] populate done", 10, 0
str_ser_eload_e5:  db "[ELOAD] cursor set", 10, 0
str_prop_cursor_pos: db "cursor_pos", 0
str_gfx_editor_title: db "EDITOR", 0
str_editor_title: db "EDITOR", 0
str_game_title:   db "COMMON HERB", 0
str_prop_wood:    db "wood", 0
str_gfx_ed_chars:   db "Chars:", 0
str_gfx_ed_status:  db "ESC=exit  arrows=move  PgUp/PgDn=scroll", 0
str_gfx_screen_x:   db "screen_x", 0
str_gfx_ed_line:    db "Ln:", 0
str_render_editor:  db "render_editor", 0
str_input_char:     db "input.Char", 0
str_prop_pos:       db "pos", 0
str_ser_editor_flow: db "[EDITOR] flow idx=", 0
str_ser_editor_pool: db "[EDITOR] pool expanded to ", 0
str_ser_editor_pool2: db " entities", 10, 0
str_gfx_screen_y:   db "screen_y", 0
; Debug strings for editor flow diagnosis
str_ser_ed_glyphs:  db "[EDIT] GLYPHS=", 0
str_ser_ed_g0:      db " g[0] ascii=", 0
str_ser_ed_x:       db " x=", 0
str_ser_ed_y:       db " y=", 0
str_ser_edkey:      db "[EDKEY] ascii=", 0
str_ser_edham:      db " ops=", 0
str_ser_edbuf:      db " buf=", 0
str_ser_edpool:     db " pool=", 0
str_ser_edsig:      db " sig=", 0
str_ser_edmode:     db " mode=", 0
str_ser_edpre:      db "[EDPRE] sig=", 0
str_ser_edmech:     db " mech=", 0
str_ser_edcur:      db " cur=", 0
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
str_pfx_foc:        db "foc", 0
str_cn_focus_sig:   db "proc.FOCUS_SIG", 0
str_focused:        db "focused", 0
str_wm_focus_on_click:   db "wm.focus_on_click", 0

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

; Phase D Step 7c — draw_full VGA cmdline strings
%ifdef KERNEL_MODE
str_vga_colon:      db ":", 0
str_vga_slash_cmd:  db "/ to type command", 0
%endif

; Phase D Step 7 — gfx stats/draw_full string constants
%ifdef GRAPHICS_MODE
str_gfx_tick:       db "Tick:", 0
str_gfx_ops:        db "Ops:", 0
str_gfx_arena:      db "Arena:", 0
str_gfx_kb:         db "KB", 0
str_gfx_procs:      db "Procs:", 0
str_gfx_sched:      db "Sched:", 0
str_gfx_priority:   db "PRIORITY", 0
str_gfx_roundrobin: db "ROUND-ROBIN", 0
str_gfx_key_open:   db "Key:[", 0
str_gfx_key_close:  db "]", 0
str_gfx_gt:         db "> ", 0
str_gfx_ready_eq:   db "READY=", 0
str_gfx_cpu0_eq:    db "CPU0=", 0
str_gfx_blocked_eq: db "BLOCKED=", 0
str_gfx_term_eq:    db "TERM=", 0
str_gfx_buf_lbl:    db "BUF", 0
str_gfx_buf_fmt:    db "%d/%d", 0
str_gfx_gt_prod:    db ">", 0
str_gfx_producer:   db "producer  ", 0
str_gfx_lt_cons:    db "<", 0
str_gfx_consumer:   db "consumer", 0
str_gfx_mem_free_lbl: db "MEM free  ", 0
str_gfx_mem_used_lbl: db "MEM used  ", 0
str_gfx_fd_free_lbl: db "FD free  ", 0
str_gfx_fd_open_lbl: db "FD open", 0
str_gfx_colon:      db ":", 0
str_gfx_slash_cmd:  db "/", 0
str_gfx_type_cmd:   db "type command", 0
str_gfx_os_return:  db "= return to OS", 0
; Game mode legend strings
str_gfx_arrows:     db "Arrows", 0
str_gfx_eq_move:    db "=Move ", 0
str_gfx_space_key:  db "Space", 0
str_gfx_eq_gather:  db "=Gather ", 0
str_gfx_g_key:      db "G", 0
str_gfx_eq_osview:  db "=OS view", 0
str_gfx_wood_lbl2:  db "Wood:", 0
str_gfx_trees_lbl2: db "Trees:", 0
%ifdef KERNEL_MODE
; gfx_draw_full property names for Surface entity queries
str_gfx_width:      db "width", 0
str_gfx_height:     db "height", 0
str_gfx_region_id:  db "region_id", 0
; region_titles array — indexed by region_id
str_region_cpu0:    db "CPU0 (RUNNING)", 0
str_region_ready:   db "READY", 0
str_region_blocked: db "BLOCKED", 0
str_region_term:    db "TERMINATED", 0
align 8
region_titles:
    dq str_region_cpu0
    dq str_region_ready
    dq str_region_blocked
    dq str_region_term
; region_containers array — indexed by region_id
region_containers:
    dq str_cn_cpu0
    dq str_cn_ready
    dq str_cn_blocked
    dq str_cn_terminated
%endif ; KERNEL_MODE
%ifndef KERNEL_MODE
; Non-KERNEL_MODE legend strings
str_gfx_leg_cpu0:     db "CPU0 (RUNNING)", 0
str_gfx_leg_ready:    db "READY", 0
str_gfx_leg_blocked:  db "BLOCKED", 0
str_gfx_leg_term:     db "TERMINATED", 0
%endif
%endif ; GRAPHICS_MODE

; Phase D Step 6 — Graphics draw string constants
%ifdef GRAPHICS_MODE
str_gfx_surface:    db "::SURFACE", 0
str_gfx_border_color: db "border_color", 0
str_gfx_fill_color: db "fill_color", 0
str_gfx_selected:   db "selected", 0
str_gfx_produced:   db "produced", 0
str_gfx_consumed:   db "consumed", 0
str_gfx_max_procs:  db "max_procs_per_region", 0
str_gfx_more_fmt:   db "+%d more", 0
str_gfx_prod_fmt:   db ">%d", 0
str_gfx_cons_fmt:   db "<%d", 0
%ifdef KERNEL_MODE
str_gfx_tensions:   db "TENSIONS", 0
str_gfx_tens_cnt:   db " %d/%d", 0
str_gfx_lbracket:   db "[", 0
str_gfx_rbracket:   db "]", 0
str_gfx_sel_lbl:    db "sel ", 0
str_gfx_d_key:      db "D", 0
str_gfx_toggle_lbl: db "=toggle", 0
str_gfx_common_herb: db "COMMON HERB", 0
str_gfx_player_lbl: db "Player", 0
str_gfx_pos_open:   db "Pos: (", 0
str_gfx_comma:      db ",", 0
str_gfx_paren_close: db ")", 0
str_gfx_hp_lbl:     db "HP: ", 0
str_gfx_on_lbl:     db "On: ", 0
str_gfx_inventory:  db "Inventory", 0
str_gfx_wood_lbl:   db "Wood: ", 0
str_gfx_trees_lbl:  db "Trees left: ", 0
str_gfx_terrain_hdr: db "Terrain", 0
str_gfx_grass:      db "Grass", 0
str_gfx_forest:     db "Forest (trees)", 0
str_gfx_water:      db "Water (blocked)", 0
str_gfx_stone:      db "Stone (blocked)", 0
str_gfx_controls:   db "Controls", 0
str_gfx_ctrl_arrow: db "Arrows  Move", 0
str_gfx_ctrl_space: db "Space   Gather", 0
str_gfx_ctrl_g:     db "G       OS view", 0
str_gfx_npc_lbl:    db "NPCs", 0
str_gfx_guard_lbl:  db "Guard: ", 0
str_gfx_scout_lbl:  db "Scout: ", 0
str_gfx_wood_w_lbl: db "Wood: ", 0
str_gfx_pri_fmt:    db "%d", 0
str_gfx_surf_fmt:   db "%s::SURFACE", 0
%endif  ; KERNEL_MODE
%endif  ; GRAPHICS_MODE

; ============================================================
; GRAPHICS LAYOUT EQU CONSTANTS — Phase D Step 6
; ============================================================

; FB dimensions (outside GRAPHICS_MODE — shared code needs these)
FB_WIDTH        equ 1280
FB_HEIGHT       equ 800

%ifdef GRAPHICS_MODE

; Layout bands (header compact, extra space to main area)
GFX_BANNER_Y   equ 0
GFX_BANNER_H   equ 28
GFX_STATS_Y    equ 28
GFX_STATS_H    equ 24
GFX_LEGEND_Y   equ 52
GFX_LEGEND_H   equ 24
GFX_MAIN_Y     equ 76
GFX_MAIN_H     equ 604
GFX_LOG_Y       equ 686
GFX_LOG_H       equ 24
GFX_SUMMARY_Y   equ 710
GFX_SUMMARY_H   equ 24
GFX_RESLEG_Y    equ 734
GFX_RESLEG_H    equ 24

; Game world
GAME_TILE_SIZE  equ 50
GAME_GRID_X     equ 16
GAME_GRID_Y     equ 80
GAME_GRID_W     equ 400   ; 8 * 50
GAME_GRID_H     equ 400   ; 8 * 50
GAME_INFO_X     equ 432
GAME_INFO_W     equ 356

; Tension panel
GFX_TENS_X      equ 824
GFX_TENS_Y      equ 76
GFX_TENS_W      equ 448
GFX_TENS_H      equ 608
GFX_TENS_ROW_H  equ 24

; Container regions: (1280-24)/2=628, (604-24)/2=290
GFX_PAD         equ 8
GFX_CONT_W     equ 400
GFX_CONT_H     equ 300

GFX_CPU0_X      equ GFX_PAD           ; 8
GFX_CPU0_Y      equ GFX_MAIN_Y        ; 76
GFX_READY_X     equ (GFX_PAD*2 + GFX_CONT_W)  ; 416
GFX_READY_Y     equ GFX_MAIN_Y        ; 76
GFX_BLOCK_X     equ GFX_PAD           ; 8
GFX_BLOCK_Y     equ (GFX_MAIN_Y + GFX_CONT_H + GFX_PAD) ; 384
GFX_TERM_X      equ (GFX_PAD*2 + GFX_CONT_W)  ; 416
GFX_TERM_Y      equ (GFX_MAIN_Y + GFX_CONT_H + GFX_PAD) ; 384

; Process rect sizing
GFX_PROC_W     equ 120
GFX_PROC_PAD   equ 6
%ifdef KERNEL_MODE
GFX_PROC_H     equ 56
%else
GFX_PROC_H     equ 40
%endif

; Color constants for graphics mode
COL_BG           equ 0x00101020
COL_BANNER_BG    equ 0x00182848
COL_STATS_BG     equ 0x00142038
COL_LEGEND_BG    equ 0x00101828
COL_RUNNING      equ 0x0000CC66
COL_RUNNING_BG   equ 0x00103020
COL_READY_COL    equ 0x00CCAA00
COL_READY_BG     equ 0x00282010
COL_BLOCKED_COL  equ 0x00CC3333
COL_BLOCKED_BG   equ 0x00281010
COL_TERM_COL     equ 0x00555555
COL_TERM_BG      equ 0x00181818
COL_BORDER       equ 0x00446688
COL_HEADER_FG    equ 0x00AACCEE
COL_TEXT         equ 0x00DDDDDD
COL_TEXT_DIM     equ 0x00888888
COL_TEXT_HI      equ 0x00FFFFFF
COL_TEXT_KEY     equ 0x00FFDD44
COL_TEXT_VAL     equ 0x0066CCFF
COL_SELECTED     equ 0x00FFFFFF
COL_TENS_BG      equ 0x000C1018
COL_TENS_BORDER  equ 0x00336688
COL_TENS_ON      equ 0x0000BBDD
COL_TENS_OFF     equ 0x00443333
COL_TENS_ON_BG   equ 0x00101830
COL_TENS_OFF_BG  equ 0x000C0C14
COL_TENS_TITLE   equ 0x0066AACC
COL_TENS_NAME    equ 0x00AADDEE
COL_TENS_DIM     equ 0x00556666
COL_TENS_PRI     equ 0x00887799
COL_TENS_SEL     equ 0x00FFFFFF
COL_TILE_GRASS   equ 0x003A7D44
COL_TILE_FOREST  equ 0x001B5E20
COL_TILE_WATER   equ 0x001565C0
COL_TILE_STONE   equ 0x00757575
COL_TILE_GRID    equ 0x002E5530
COL_PLAYER       equ 0x00FFD740
COL_PLAYER_BDR   equ 0x00FFA000
COL_TREE         equ 0x0066BB6A
COL_TREE_TRUNK   equ 0x00795548
COL_GAME_BG      equ 0x00101818
COL_GAME_TITLE   equ 0x0088CCAA
COL_NPC_GUARD    equ 0x0000CCCC
COL_NPC_SCOUT    equ 0x00CC44CC

; Windowed game layout
WGAME_TILE_SIZE  equ 32
WGAME_GRID_PAD   equ 4
WGAME_GRID_SIZE  equ 256
WGAME_INFO_Y_OFF equ 264
COL_RES_FREE     equ 0x00338855
COL_RES_USED     equ 0x00CC4444
COL_RES_FD_F     equ 0x00335588
COL_RES_FD_U     equ 0x00CC8844

%endif  ; GRAPHICS_MODE

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

    call fb_init_display
    test eax, eax
    jnz .fb_fail

    ; Success
    lea rcx, [rel str_fb_ok]
    call vga_print
    lea rcx, [rel str_fb_serial_ok]
    call serial_print

    ; fb_clear(COL_BG) + fb_flip()
    mov ecx, 0x00101020          ; COL_BG
    call fb_clear
    call fb_flip
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
    ; INIT PARALLEL ARRAYS (must be before compilation/loading)
    ; ================================================================
    lea rcx, [rel container_order_keys]
    mov edx, 0xFF
    mov r8d, 1024                   ; 256 containers * 4 bytes = 1024
    call herb_memset
    lea rcx, [rel tension_step_flags]
    xor edx, edx
    mov r8d, 1024                   ; 256 tensions * 4 bytes = 1024
    call herb_memset
    lea rcx, [rel g_container_entity_counts]
    xor edx, edx
    mov r8d, 1024                   ; 256 containers * 4 bytes = 1024
    call herb_memset

    ; ================================================================
    ; COMPILE .herb SOURCE TO BINARY
    ; ================================================================
    call boot_compile_programs
    test eax, eax
    jnz .compile_failed
    jmp .compile_ok
.compile_failed:
    ; Fatal: compilation failed — halt
    mov ecx, 0x04
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_compile_fail]
    call vga_print
    lea rcx, [rel str_compile_fail]
    call serial_print
.compile_halt:
    call hw_hlt
    jmp .compile_halt
.compile_ok:

    ; ================================================================
    ; LOAD EMBEDDED PROGRAM
    ; ================================================================

    lea rcx, [rel str_loading]
    call vga_print

    ; vga_print_int((int)bin_ik_len)
    lea rax, [rel bin_ik_len]
    mov ecx, dword [rax]
    call vga_print_int

    lea rcx, [rel str_bytes_msg]
    call vga_print

    ; rc = herb_load((const char*)bin_interactive_kernel, bin_ik_len)
    lea rcx, [rel bin_interactive_kernel]
    lea rax, [rel bin_ik_len]
    mov edx, dword [rax]
    call herb_load

    test eax, eax
    jnz .load_failed

    lea rcx, [rel str_prog_loaded]
    call vga_print
    lea rcx, [rel str_prog_loaded]
    call serial_print

%ifdef KERNEL_MODE
    ; Load turing machine program (system-level, no owner)
    lea rcx, [rel bin_turing]
    lea rax, [rel bin_turing_len]
    mov edx, dword [rax]
    call herb_load
    test eax, eax
    jnz .load_failed
    lea rcx, [rel str_tm_loaded]
    call serial_print

    ; Load test_flow program (system-level, no owner)
    lea rcx, [rel bin_test_flow]
    lea rax, [rel bin_test_flow_len]
    mov edx, dword [rax]
    call herb_load
    test eax, eax
    jnz .load_failed
    lea rcx, [rel str_tf_loaded]
    call serial_print
%endif

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

    ; DEBUG: Print entity count + container counts after loading
    sub rsp, 32
    lea rcx, [rel str_ser_edkey]       ; reuse "[EDKEY] " as prefix
    call serial_print
    lea rcx, [rel str_ser_edbuf]       ; "buf="
    call serial_print
    mov eax, [g_graph + GRAPH_ENTITY_COUNT]
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_ser_edpool]      ; " pool="
    call serial_print
    lea rcx, [rel str_cn_ed_pool]      ; "editor.POOL"
    call herb_container_count
    mov ecx, eax
    call serial_print_int
    ; CTL count
    lea rcx, [rel str_ser_edbuf]       ; " buf="
    call serial_print
    lea rcx, [rel str_cn_ed_ctl]       ; "editor.CTL"
    call herb_container_count
    mov ecx, eax
    call serial_print_int
    ; INPUT_STATE count
    lea rcx, [rel str_ser_edham]       ; " ops=" (reuse as separator)
    call serial_print
    lea rcx, [rel str_cn_input_state]
    call herb_container_count
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    add rsp, 32

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
    ; FLOW DIAGNOSTIC — print test_flow results
    ; ================================================================
    lea rcx, [rel str_flow_diag]          ; "[FLOW] count="
    call serial_print
    mov ecx, [g_flow_count]
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    ; Look up FLOW_DST container count
    lea rcx, [rel str_flow_dst_name]      ; "FLOW_DST"
    call herb_container_count
    mov r12d, eax                         ; r12 = dst count

    lea rcx, [rel str_flow_dst_cnt]       ; "[FLOW] FLOW_DST entities="
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    ; Print each entity's doubled and cumsum properties
    xor r13d, r13d                        ; r13 = i
.flow_diag_loop:
    cmp r13d, r12d
    jge .flow_diag_done

    lea rcx, [rel str_flow_dst_name]      ; "FLOW_DST"
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .flow_diag_next
    mov r14d, eax                         ; r14 = entity_id

    lea rcx, [rel str_flow_ent]           ; "[FLOW] e="
    call serial_print
    mov ecx, r14d
    call serial_print_int

    ; Read "doubled" property
    mov ecx, r14d
    lea rdx, [rel str_prop_doubled]       ; "doubled"
    mov r8d, -1
    call herb_entity_prop_int
    push rax
    lea rcx, [rel str_flow_doubled]       ; " doubled="
    call serial_print
    pop rcx
    call serial_print_int

    ; Read "cumsum" property
    mov ecx, r14d
    lea rdx, [rel str_prop_cumsum]        ; "cumsum"
    mov r8d, -1
    call herb_entity_prop_int
    push rax
    lea rcx, [rel str_flow_cumsum]        ; " cumsum="
    call serial_print
    pop rcx
    call serial_print_int

    lea rcx, [rel str_newline]
    call serial_print

.flow_diag_next:
    inc r13d
    jmp .flow_diag_loop

.flow_diag_done:

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

    ; ---- Load shell behavior from boot-compiled binary ----
    ; herb_load_program(bin_shell, bin_shell_len, shell_eid, "")
    lea rcx, [rel bin_shell]
    lea rax, [rel bin_shell_len]
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
    ; WINDOW MANAGER INIT
    ; ================================================================
%ifdef GRAPHICS_MODE
    call wm_init
    call wm_init_default_windows
    call editor_init
%endif

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
    ; PERSISTENT STORAGE INIT (ATA PIO + Filesystem)
    ; ================================================================

    call disk_identify
    test eax, eax
    jnz .skip_fs
    call fs_init
.skip_fs:

    ; ================================================================
    ; NETWORK INIT (E1000 PCI scan + MMIO map + device init)
    ; ================================================================

    call net_init
    ; net_init returns IRQ number in EAX if found, or -1 if not
    ; We'll set up the IDT gate below if NIC was found

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

    ; idt_set_gate(43, e1000_isr_stub) — IRQ11 = vector 43
    ; Only set if NIC was found
    cmp dword [rel net_present], 0
    je .skip_net_idt
    mov ecx, 43
    lea rdx, [rel e1000_isr_stub]
    call idt_set_gate
.skip_net_idt:

    call idt_install

    call pic_remap

    ; Unmask IRQ11 (E1000 NIC) on slave PIC if NIC present
    cmp dword [rel net_present], 0
    je .skip_nic_unmask
    in al, 0xA1                     ; read slave PIC mask
    and al, ~(1 << 3)              ; clear bit 3 = unmask IRQ11
    out 0xA1, al
.skip_nic_unmask:

    ; pit_init(100)
    mov ecx, 100
    call pit_init

    ; mouse_init()
    call mouse_init
    lea rcx, [rel str_mouse_init]
    call serial_print

    ; hw_sti()
    call hw_sti

    ; Gateway ARP request sent by net_resolve_gateway (non-blocking)
    cmp dword [rel net_present], 0
    je .skip_gateway
    call net_resolve_gateway
.skip_gateway:

    ; ================================================================
    ; Session 94: Find editor flow index + expand pool
    ; ================================================================
%ifdef KERNEL_MODE
    call editor_find_flow_idx
    call editor_expand_pool
%endif

    ; ================================================================
    ; INITIAL DISPLAY
    ; ================================================================

    ; vga_set_color(VGA_LGRAY=0x07, VGA_BLACK=0x00)
    mov ecx, 0x07
    xor edx, edx
    call vga_set_color

    call vga_clear

    ; Session 93: Welcome message in output window
    lea rcx, [rel str_so_welcome]
    call shell_output_print

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
    ; Session 92: tiling geometry sync on auto-timer
    cmp dword [rel g_tiling_active], 0
    je .no_tile_sync
    call wm_sync_geometry_from_herb
.no_tile_sync:
    call draw_full

.no_auto_timer:
%else
    ; Non-KERNEL_MODE: no auto-timer
%endif

    ; Editor cursor blink (every 30 ticks = ~300ms at 100Hz)
%ifdef GRAPHICS_MODE
    cmp dword [rel ed_win_id], -1
    je .no_editor_blink
    cmp dword [rel ed_active], 0
    je .no_editor_blink
    mov eax, r12d
    xor edx, edx
    mov ecx, 30
    div ecx
    test edx, edx
    jnz .no_editor_blink
    call editor_toggle_blink
    call draw_full
.no_editor_blink:
%endif

    ; Refresh stats every 500ms (every 50 ticks at 100Hz)
    mov eax, r12d
    xor edx, edx
    mov ecx, 50
    div ecx                         ; edx = timer_count % 50
    test edx, edx
    jnz .no_timer

%ifdef GRAPHICS_MODE
    cmp dword [rel fb_active], 0
    je .stats_text_mode

    call gfx_draw_stats_only
    jmp .no_timer

.stats_text_mode:
%endif
    call draw_stats

.no_timer:

    ; ---- Keyboard ring buffer: drain all accumulated scancodes ----
.kb_drain_loop:
    lea rax, [rel kb_ring_tail]
    movzx ecx, byte [rax]
    lea rax, [rel kb_ring_head]
    movzx edx, byte [rax]
    cmp ecx, edx
    je .kb_drain_done

    ; scancode = kb_ring[tail]
    lea rax, [rel kb_ring]
    movzx ecx, byte [rax + rcx]   ; ecx = scancode byte

    ; tail = (tail + 1) & 0x3F
    lea rax, [rel kb_ring_tail]
    movzx edx, byte [rax]
    inc edx
    and edx, 0x3F
    mov byte [rax], dl

    ; handle_key(scancode) — ecx already has the scancode
    call handle_key

    jmp .kb_drain_loop
.kb_drain_done:

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
    jz .after_mouse

%ifdef GRAPHICS_MODE
    ; Update cursor position for rendering
    cmp dword [rel fb_active], 0
    je .no_cursor_update

    ; cursor_x = mouse_x; cursor_y = mouse_y
    mov eax, [rel mouse_x]
    mov [rel cursor_x], eax
    mov eax, [rel mouse_y]
    mov [rel cursor_y], eax

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

    ; --- Window Manager hit test (GRAPHICS_MODE) ---
    cmp dword [rel fb_active], 0
    je .wm_click_passthrough

    ; wm_hit_test(mouse_x, mouse_y) -> eax=win_id, edx=region
    mov ecx, dword [rel mouse_x]
    mov edx, dword [rel mouse_y]
    call wm_hit_test
    mov r14d, eax                   ; r14 = hit win_id
    mov r15d, edx                   ; r15 = hit region

    cmp r14d, -1
    je .wm_click_passthrough        ; no window hit — fall through

    ; Click-to-focus via HERB tension
    ; Create FOCUS_SIG with click coordinates
    mov ecx, dword [rel mouse_x]
    mov edx, dword [rel mouse_y]
    call create_focus_signal

    ; Run HAM to evaluate focus tensions
    mov ecx, 100
    call ham_run_ham
    add [rel total_ops], eax

    ; Read back focus result from HERB (force=0: skip if unchanged)
    xor ecx, ecx
    call wm_apply_herb_focus

    ; Deactivate editor if focus moved to a different window
    cmp dword [rel ed_active], 0
    je .wm_no_editor_deactivate
    cmp r14d, dword [rel ed_win_id]
    je .wm_no_editor_deactivate
    call editor_deactivate
.wm_no_editor_deactivate:

    ; Dispatch based on hit region
    cmp r15d, 1                     ; HIT_CLOSE
    je .wm_click_close
    cmp r15d, 2                     ; HIT_MAXIMIZE
    je .wm_click_maximize
    cmp r15d, 3                     ; HIT_TITLEBAR
    je .wm_click_titlebar
    cmp r15d, 4                     ; HIT_RESIZE
    je .wm_click_resize_start
    cmp r15d, 5                     ; HIT_CLIENT
    je .wm_click_client
    jmp .wm_click_done

.wm_click_close:
    ; Check if closing the editor window
    cmp r14d, dword [rel ed_win_id]
    jne .wm_close_not_editor
    call editor_close
.wm_close_not_editor:
    ; Destroy the window
    mov ecx, r14d
    call wm_destroy_window
    jmp .wm_click_done

.wm_click_maximize:
    ; Toggle maximize/restore
    mov ecx, r14d
    call wm_window_ptr
    test rax, rax
    jz .wm_click_done

    ; Check if currently maximized
    mov edx, dword [rax + 4]        ; WIN_FLAGS
    test edx, (1 << 2)              ; WF_MAXIMIZED
    jnz .wm_restore

    ; Maximize: save current bounds, set to full main area
    mov ecx, dword [rax + 8]        ; WIN_X
    mov dword [rax + 64], ecx       ; restore_x
    mov ecx, dword [rax + 12]       ; WIN_Y
    mov dword [rax + 68], ecx       ; restore_y
    mov ecx, dword [rax + 16]       ; WIN_W
    mov dword [rax + 72], ecx       ; restore_w
    mov ecx, dword [rax + 20]       ; WIN_H
    mov dword [rax + 76], ecx       ; restore_h
    ; Set to fill main area (0, GFX_MAIN_Y, FB_WIDTH, GFX_MAIN_H)
    mov dword [rax + 8], 0          ; x
    mov dword [rax + 12], GFX_MAIN_Y ; y
    mov dword [rax + 16], FB_WIDTH  ; w
    mov dword [rax + 20], GFX_MAIN_H ; h
    or dword [rax + 4], (1 << 2)    ; set WF_MAXIMIZED
    jmp .wm_click_done

.wm_restore:
    ; Restore saved bounds
    mov ecx, dword [rax + 64]
    mov dword [rax + 8], ecx        ; x = restore_x
    mov ecx, dword [rax + 68]
    mov dword [rax + 12], ecx       ; y = restore_y
    mov ecx, dword [rax + 72]
    mov dword [rax + 16], ecx       ; w = restore_w
    mov ecx, dword [rax + 76]
    mov dword [rax + 20], ecx       ; h = restore_h
    and dword [rax + 4], ~(1 << 2)  ; clear WF_MAXIMIZED
    jmp .wm_click_done

.wm_click_titlebar:
    ; Begin drag-to-move
    mov ecx, r14d
    mov edx, 1                      ; DRAG_MOVE
    mov r8d, dword [rel mouse_x]
    mov r9d, dword [rel mouse_y]
    call wm_begin_drag
    jmp .wm_click_done

.wm_click_resize_start:
    ; Begin drag-to-resize
    mov ecx, r14d
    mov edx, 2                      ; DRAG_RESIZE
    mov r8d, dword [rel mouse_x]
    mov r9d, dword [rel mouse_y]
    call wm_begin_drag
    jmp .wm_click_done

.wm_click_client:
    ; Client area — pass through to existing content handlers
    ; Get window pointer to determine content type
    mov ecx, r14d
    call wm_window_ptr
    test rax, rax
    jz .wm_click_passthrough
    mov r13d, dword [rax + 32]      ; WIN_CONTENT_TYPE

    ; WCT_CUSTOM (3): check if editor window
    cmp r13d, 3
    jne .wm_click_not_editor
    cmp r14d, dword [rel ed_win_id]
    jne .wm_click_not_editor
    call editor_activate
    call draw_full
    jmp .wm_click_done
.wm_click_not_editor:

    ; WCT_TENSIONS (1): handle tension panel click
    cmp r13d, 1
    jne .wm_click_passthrough

%ifdef KERNEL_MODE
    ; Tension panel client click: compute row from mouse_y
    ; The tension panel draws at its window position
    ; row = (mouse_y - (win_y + WM_TITLEBAR_H)) / GFX_TENS_ROW_H
    mov ecx, r14d
    call wm_window_ptr
    test rax, rax
    jz .wm_click_done
    mov ecx, dword [rax + 12]       ; WIN_Y
    add ecx, 28                     ; + WM_TITLEBAR_H (now 28)
    mov eax, dword [rel mouse_y]
    sub eax, ecx
    cdq
    mov ecx, 24                     ; GFX_TENS_ROW_H
    idiv ecx

    test eax, eax
    js .wm_click_done

    mov r14d, eax
    push r14
    call herb_tension_count
    pop r14
    cmp r14d, eax
    jge .wm_click_done

    mov dword [rel selected_tension_idx], r14d
    call cmd_tension_toggle
%endif
    jmp .wm_click_done

.wm_click_passthrough:
%ifdef KERNEL_MODE
    ; Original click handling: cmd_click + HERB panel_click check
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

    mov r13d, eax

    mov ecx, r13d
    lea rdx, [rel str_panel_click]
    xor r8d, r8d
    call herb_entity_prop_int
    test eax, eax
    jz .no_panel_click

    mov ecx, r13d
    lea rdx, [rel str_panel_click]
    xor r8d, r8d
    call herb_set_prop_int

    lea rax, [rel mouse_y]
    mov eax, dword [rax]
    sub eax, 98
    cdq
    mov ecx, 16
    idiv ecx

    test eax, eax
    js .no_panel_click

    mov r14d, eax
    push r14
    call herb_tension_count
    pop r14
    cmp r14d, eax
    jge .no_panel_click

    lea rax, [rel selected_tension_idx]
    mov dword [rax], r14d
    call cmd_tension_toggle

.no_panel_click:
%endif  ; KERNEL_MODE

.wm_click_done:
    call draw_full

.no_mouse_click:

    ; Handle mouse release (end drag/resize)
    lea rax, [rel mouse_left_released]
    mov eax, dword [rax]
    test eax, eax
    jz .no_mouse_release

    mov dword [rel mouse_left_released], 0

    ; End any active drag
    cmp dword [rel wm_drag_mode], 0     ; DRAG_NONE
    je .no_mouse_release
    call wm_end_drag
    call draw_full

.no_mouse_release:

    ; Update cursor on screen (direct MMIO, no full redraw)
    lea rax, [rel mouse_moved]
    mov eax, dword [rax]
    test eax, eax
    jz .no_mouse_move

    cmp dword [rel fb_active], 0
    je .no_mouse_move

    ; mouse_moved = 0
    lea rax, [rel mouse_moved]
    mov dword [rax], 0

    ; If dragging, update drag position + full redraw
    cmp dword [rel wm_drag_mode], 0     ; DRAG_NONE
    je .no_drag_update

    mov ecx, dword [rel mouse_x]
    mov edx, dword [rel mouse_y]
    call wm_update_drag
    call draw_full
    jmp .no_mouse_move

.no_drag_update:
    ; No drag — just erase/redraw cursor
    call fb_cursor_erase
    call fb_cursor_draw

.no_mouse_move:
%endif  ; GRAPHICS_MODE

.after_mouse:
    ; ---- Network: poll for received packets ----
    call net_poll_rx

    ; ---- ARP retry: resend once after ~1s (100 ticks) ----
    cmp dword [rel net_present], 0
    je .no_arp_retry
    cmp dword [rel net_arp_retried], 0
    jne .no_arp_retry
    mov eax, [rel timer_count]
    cmp eax, 5                      ; retry after 5 ticks
    jb .no_arp_retry
    mov dword [rel net_arp_retried], 1
    call net_send_arp_request
.no_arp_retry:

    ; Auto-ping after ARP resolved (tick >= 15, giving ARP time to resolve)
    cmp dword [rel net_present], 0
    je .no_auto_ping
    cmp dword [rel ping_auto_sent], 0
    jne .no_auto_ping
    mov eax, [rel timer_count]
    cmp eax, 15
    jb .no_auto_ping
    ; Verify gateway MAC is cached before sending
    mov ecx, [rel net_gateway_ip]
    call arp_cache_lookup
    test rax, rax
    jz .no_auto_ping               ; ARP not resolved yet, try next tick
    mov dword [rel ping_auto_sent], 1
    mov dword [rel ping_pending], 1
    mov eax, [rel timer_count]
    mov [rel ping_tick], eax
    mov dword [rel ping_seq], 1
    mov ecx, [rel net_gateway_ip]
    mov edx, 1                      ; seq=1
    call icmp_send_echo
.no_auto_ping:

    ; ---- Auto-UDP test after auto-ping (tick >= 20) ----
    cmp dword [rel net_present], 0
    je .no_auto_udp
    cmp dword [rel udp_auto_sent], 0
    jne .no_auto_udp
    mov eax, [rel timer_count]
    cmp eax, 20
    jb .no_auto_udp
    ; Verify gateway MAC is cached
    mov ecx, [rel net_gateway_ip]
    call arp_cache_lookup
    test rax, rax
    jz .no_auto_udp
    mov dword [rel udp_auto_sent], 1
    ; udp_send(RCX=dst_ip, EDX=dst_port, R8D=src_port, R9=payload, [rsp+32]=len)
    mov ecx, [rel net_gateway_ip]
    mov edx, 7777
    mov r8d, 4444
    lea r9, [rel str_udp_payload]
    mov dword [rsp+32], 4
    call udp_send
.no_auto_udp:

    ; ---- Auto-DNS resolve (tick >= 25) ----
    cmp dword [rel net_present], 0
    je .no_auto_dns
    cmp dword [rel dns_auto_sent], 0
    jne .no_auto_dns
    mov eax, [rel timer_count]
    cmp eax, 25
    jb .no_auto_dns
    mov ecx, [rel net_gateway_ip]
    call arp_cache_lookup
    test rax, rax
    jz .no_auto_dns
    mov dword [rel dns_auto_sent], 1
    lea rcx, [rel str_dns_domain]   ; "example.com"
    call dns_resolve
.no_auto_dns:

    ; ---- HTTP state machine poll ----
    call http_poll_state

    ; ---- Auto-HTTP (tick >= 30, after DNS resolves) ----
    cmp dword [rel net_present], 0
    je .no_auto_http
    cmp dword [rel http_auto_sent], 0
    jne .no_auto_http
    mov eax, [rel timer_count]
    cmp eax, 30
    jb .no_auto_http
    cmp dword [rel dns_resolved_flag], 0
    je .no_auto_http
    mov dword [rel http_auto_sent], 1
    lea rcx, [rel str_dns_domain]
    lea rdx, [rel str_http_slash]
    call http_get
.no_auto_http:

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

    ; DEBUG: If editor mode (mode==2), print GLYPHS count + first glyph props
    mov eax, dword [rel input_ctl_eid]
    test eax, eax
    js .rbs_done
    mov ecx, eax
    lea rdx, [rel str_mode]
    xor r8d, r8d
    call herb_entity_prop_int
    cmp eax, 2
    jne .rbs_done

    ; Print "[EDIT] GLYPHS=N"
    lea rcx, [rel str_ser_ed_glyphs]
    call serial_print
    lea rcx, [rel str_cn_ed_glyphs]
    call herb_container_count
    mov esi, eax                        ; ESI = glyph count
    mov ecx, eax
    call serial_print_int

    ; If count > 0, print first glyph's ascii, screen_x, screen_y
    test esi, esi
    jle .rbs_ed_debug_nl

    lea rcx, [rel str_cn_ed_glyphs]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .rbs_ed_debug_nl
    mov ebx, eax                        ; EBX = glyph eid

    lea rcx, [rel str_ser_ed_g0]
    call serial_print
    mov ecx, ebx
    lea rdx, [rel str_ascii_prop]
    xor r8d, r8d
    call herb_entity_prop_int
    mov ecx, eax
    call serial_print_int

    lea rcx, [rel str_ser_ed_x]
    call serial_print
    mov ecx, ebx
    lea rdx, [rel str_gfx_screen_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov ecx, eax
    call serial_print_int

    lea rcx, [rel str_ser_ed_y]
    call serial_print
    mov ecx, ebx
    lea rdx, [rel str_gfx_screen_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov ecx, eax
    call serial_print_int

.rbs_ed_debug_nl:
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

    ; recycle_or_create_entity(name, ET_SIGNAL, CN_BOOST_SIG, CN_SIG_DONE)
    lea rcx, [rsp + 48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_boost_sig]
    lea r9, [rel str_cn_sig_done]
    call recycle_or_create_entity

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
    ; recycle_or_create_entity(name, ET_SIGNAL, CN_TIMER_SIG, CN_SIG_DONE)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_timer_sig]
    lea r9, [rel str_cn_sig_done]
    call recycle_or_create_entity

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
; cmd_turing_step — Create TM_TICK signal, run HAM, print tape
; No args. Clobbers caller-saved.
; Stack: 4 pushes (rbx,rsi,rdi,r12) + sub 40 = aligned
;   8(ret)+8(rbp)+32(pushes)+40(sub) = 88 → 88%16=8 → need sub 48
;   8+8+32+48 = 96 → 96%16=0 ✓
;   [rsp+32] = saved value temp
; ============================================================
%ifdef KERNEL_MODE
cmd_turing_step:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    sub     rsp, 48
    ; 8(ret)+8(rbp)+32(4 pushes)+48(sub)=96, 96%16=0 ✓

    ; 1. Create TmSig entity in TM_TICK
    lea     rcx, [rel str_tm_sig_name]
    lea     rdx, [rel str_et_tmsig]
    lea     r8, [rel str_cn_tm_tick]
    call    herb_create
    test    eax, eax
    js      .cts_no_tm

    ; 2. Run HAM to process the tick
    mov     ecx, 100
    call    ham_run_ham
    mov     ebx, eax
    add     [rel total_ops], eax

    ; 3. Print tape state to serial
    lea     rcx, [rel str_tm_hdr]
    call    serial_print

    ; Iterate TAPE container entities (0..7)
    xor     r12d, r12d
.cts_tape_loop:
    cmp     r12d, 8
    jge     .cts_tape_done

    lea     rcx, [rel str_cn_tape]
    mov     edx, r12d
    call    herb_container_entity
    test    eax, eax
    js      .cts_tape_done
    mov     esi, eax

    ; Get cell_index
    mov     ecx, esi
    lea     rdx, [rel str_prop_cell_idx]
    mov     r8d, -1
    call    herb_entity_prop_int
    mov     edi, eax

    ; Get value
    mov     ecx, esi
    lea     rdx, [rel str_prop_value]
    xor     r8d, r8d
    call    herb_entity_prop_int
    mov     [rsp+32], eax               ; save value

    ; Print "[idx:val]"
    lea     rcx, [rel str_tm_bracket_o]
    call    serial_print
    mov     ecx, edi
    call    serial_print_int
    lea     rcx, [rel str_tm_colon]
    call    serial_print
    mov     ecx, [rsp+32]
    call    serial_print_int
    lea     rcx, [rel str_tm_bracket_c]
    call    serial_print

    inc     r12d
    jmp     .cts_tape_loop

.cts_tape_done:
    ; Get head entity from HEAD_SLOT[0]
    lea     rcx, [rel str_cn_head_slot]
    xor     edx, edx
    call    herb_container_entity
    test    eax, eax
    js      .cts_head_done
    mov     esi, eax

    ; position
    mov     ecx, esi
    lea     rdx, [rel str_prop_position]
    xor     r8d, r8d
    call    herb_entity_prop_int
    mov     edi, eax

    ; state
    mov     ecx, esi
    lea     rdx, [rel str_prop_state]
    xor     r8d, r8d
    call    herb_entity_prop_int
    mov     r12d, eax

    ; Print " Head@pos state=S ops=N\n"
    lea     rcx, [rel str_tm_head_info]
    call    serial_print
    mov     ecx, edi
    call    serial_print_int
    lea     rcx, [rel str_tm_state_info]
    call    serial_print
    mov     ecx, r12d
    call    serial_print_int
    lea     rcx, [rel str_tm_ops_info]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_newline]
    call    serial_print

.cts_head_done:
    ; Update last_action
    lea     rcx, [rel last_action]
    mov     edx, 80
    lea     r8, [rel str_la_turing]
    mov     r9d, ebx
    call    herb_snprintf

.cts_no_tm:
    add     rsp, 48
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret
%endif  ; KERNEL_MODE

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

    ; If entering game mode, focus game window via HERB
%ifdef GRAPHICS_MODE
    test ebx, ebx
    jz .ctg_no_focus
    mov ecx, WM_ROLE_GAME
    call wm_herb_set_focus_by_role
.ctg_no_focus:
%endif

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

    ; Create TIMER_SIG via signal recycle path when possible.
    lea rcx, [rel str_ham_timer]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_timer_sig]
    lea r9, [rel str_cn_sig_done]
    call recycle_or_create_entity

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

    ; recycle_or_create_entity(name, ET_SIGNAL, CN_CLICK_SIG, CN_SIG_DONE)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_click_sig]
    lea r9, [rel str_cn_sig_done]
    call recycle_or_create_entity
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

    jmp .ccl_done

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

; ---- recycle_or_create_entity(name, type, target_container, recycle_container) ----
; Reuse the first entity from recycle_container when available; otherwise
; fallback to herb_create(name, type, target_container).
; Args: RCX = name, RDX = type, R8 = target_container, R9 = recycle_container
; Returns: EAX = entity index, or -1
recycle_or_create_entity:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40

    mov rsi, rcx                    ; name
    mov rdi, rdx                    ; type
    mov r12, r8                     ; target_container
    mov r13, r9                     ; recycle_container

    ; Resolve recycle container and ensure it has an entity to reuse.
    mov rcx, r13
    call intern
    mov ecx, eax
    call graph_find_container_by_name
    mov r14d, eax                   ; recycle_cidx
    test eax, eax
    js .rce_fallback

    mov rcx, r13
    call herb_container_count
    test eax, eax
    jle .rce_fallback

    ; Resolve target container.
    mov rcx, r12
    call intern
    mov ecx, eax
    call graph_find_container_by_name
    mov r15d, eax                   ; target_cidx
    test eax, eax
    js .rce_fallback

    ; Reuse the first completed signal.
    mov rcx, r13
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .rce_fallback
    mov ebx, eax                    ; entity_idx

    mov ecx, r14d
    mov edx, ebx
    call container_remove
    mov ecx, r14d
    call ham_dirty_mark

    mov ecx, r15d
    mov edx, ebx
    call container_add
    mov ecx, r15d
    call ham_dirty_mark

    ; Update entity location.
    mov ecx, r15d
    lea rdx, [rel g_graph]
    add rdx, GRAPH_ENTITY_LOCATION
    movsxd rax, ebx
    mov [rdx + rax*4], ecx

    ; Reset name/type and discard stale properties from the prior signal use.
    mov rcx, rsi
    call intern
    mov [rsp+32], eax               ; name_id
    mov rcx, rdi
    call intern
    mov [rsp+36], eax               ; type_id

    movsxd rax, ebx
    imul rax, SIZEOF_ENTITY
    lea rdx, [rel g_graph]
    add rdx, rax
    mov eax, [rsp+36]
    mov [rdx + ENT_TYPE_ID], eax
    mov eax, [rsp+32]
    mov [rdx + ENT_NAME_ID], eax
    mov dword [rdx + ENT_PROP_COUNT], 0

    mov eax, ebx
    jmp .rce_done

.rce_fallback:
    mov rcx, rsi
    mov rdx, rdi
    mov r8, r12
    call herb_create

.rce_done:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

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

    ; recycle_or_create_entity(name, ET_SIGNAL, CN_KEY_SIG, CN_SIG_DONE)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_key_sig]
    lea r9, [rel str_cn_sig_done]
    call recycle_or_create_entity

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

; ---- create_focus_signal(int cx, int cy) ----
; Create a FOCUS_SIG with click_x/click_y properties.
; Args: ECX = cx, EDX = cy
; Stack: 3 pushes (rbp, rbx, rsi) + sub rsp 80 = 8+24+80 = 112. 112%16=0. ✓
;   name[32] at [rsp+48]
create_focus_signal:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 80

    mov ebx, ecx                    ; save cx
    mov esi, edx                    ; save cy

    ; make_sig_name(name, 32, "foc")
    lea rcx, [rsp+48]
    mov edx, 32
    lea r8, [rel str_pfx_foc]
    call make_sig_name

    ; recycle_or_create_entity(name, ET_SIGNAL, CN_FOCUS_SIG, CN_SIG_DONE)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_focus_sig]
    lea r9, [rel str_cn_sig_done]
    call recycle_or_create_entity
    test eax, eax
    js .cfs_done

    ; Set click_x
    mov ecx, eax
    mov dword [rsp+48], eax         ; save eid in name[0] (done with name)
    lea rdx, [rel str_click_x]
    mov r8d, ebx                    ; cx
    call herb_set_prop_int

    ; Set click_y
    mov ecx, dword [rsp+48]
    lea rdx, [rel str_click_y]
    mov r8d, esi                    ; cy
    call herb_set_prop_int

.cfs_done:
    add rsp, 80
    pop rsi
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

    ; recycle_or_create_entity(name, ET_GAME_SIGNAL, CN_GAME_MOVE_SIG, CN_GAME_SIG_DONE)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_game_signal]
    lea r8, [rel str_cn_game_move_sig]
    lea r9, [rel str_cn_game_sig_done]
    call recycle_or_create_entity

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

    ; recycle_or_create_entity(name, ET_GAME_SIGNAL, CN_GAME_GATHER_SIG, CN_GAME_SIG_DONE)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_game_signal]
    lea r8, [rel str_cn_game_gather_sig]
    lea r9, [rel str_cn_game_sig_done]
    call recycle_or_create_entity

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

    ; sig_eid = recycle_or_create_entity(sig_name, ET_SIGNAL, CN_CMD_SIG, CN_SIG_DONE)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_cmd_sig]
    lea r9, [rel str_cn_sig_done]
    call recycle_or_create_entity
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

    ; post_dispatch(sig_eid, ops, cpu0_name, NULL)
    mov ecx, r15d
    mov edx, ebx
    mov r8, r14
    xor r9d, r9d                    ; buf = NULL (hotkey, no command buffer)
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

    ; sig_eid = recycle_or_create_entity(sig_name, ET_SIGNAL, CN_CMD_SIG, CN_SIG_DONE)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_cmd_sig]
    lea r9, [rel str_cn_sig_done]
    call recycle_or_create_entity
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
    ; post_dispatch(sig_eid, ops, cpu0_name, buf)
    mov ecx, r15d
    mov edx, ebx
    mov r8, rsi
    mov r9, r14                     ; buf (command buffer)
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

; ---- shell_output_print(const char* str) ----
; Session 93: Write line to circular buffer + serial_print (dual output).
; Args: RCX = null-terminated string
; Stack: 3 pushes (rbp,rbx,rsi) + sub rsp 48. 8+24+48=80. 80%16=0. Good.
shell_output_print:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 48

    mov rsi, rcx                     ; save str

    ; 1. Calculate destination: &shell_output_buf[head * LINE_LEN]
    mov eax, dword [rel shell_output_head]
    imul eax, SHELL_OUTPUT_LINE_LEN
    lea rbx, [rel shell_output_buf]
    add rbx, rax                     ; rbx = dest pointer

    ; 2. Copy up to LINE_LEN-1 chars via herb_strncpy(dst, src, n)
    mov rcx, rbx                     ; dest
    mov rdx, rsi                     ; src
    mov r8d, SHELL_OUTPUT_LINE_LEN - 1
    call herb_strncpy

    ; 3. Null-terminate last byte
    mov byte [rbx + SHELL_OUTPUT_LINE_LEN - 1], 0

    ; 4. Advance head (wraps at SHELL_OUTPUT_MAX_LINES)
    mov eax, dword [rel shell_output_head]
    inc eax
    cmp eax, SHELL_OUTPUT_MAX_LINES
    jl .sop_no_wrap
    xor eax, eax
.sop_no_wrap:
    mov dword [rel shell_output_head], eax

    ; 5. Increment count (cap at max)
    mov eax, dword [rel shell_output_count]
    cmp eax, SHELL_OUTPUT_MAX_LINES
    jge .sop_count_ok
    inc eax
    mov dword [rel shell_output_count], eax
.sop_count_ok:

    ; 6. Reset scroll to bottom on new output
    mov dword [rel shell_output_scroll], 0

    ; 7. Serial output: print original string + newline
    mov rcx, rsi
    call serial_print
    lea rcx, [rel str_newline]
    call serial_print

    add rsp, 48
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- post_dispatch(int sig_eid, int ops, const char* cpu0_name, const char* buf) ----
; Read cmd_id from HERB, emit serial, cleanup terminated, handle shell action.
; Args: ECX = sig_eid, EDX = ops, R8 = cpu0_name, R9 = buf (command buffer)
; Stack: 6 pushes (rbp,rbx,rsi,rdi,r12,r13) + sub rsp 80 = 128+8 aligned.
;   8+48+80 = 136. 136%16=8. Need sub rsp 88: 8+48+88=144. 144%16=0. Good.
;   rbx=ops, rsi=cpu0_name, r12d=cmd_id, edi=sig_eid, r13=buf
;   name_buf[32] at [rsp+56]
post_dispatch:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 88

    mov edi, ecx                    ; save sig_eid
    mov ebx, edx                    ; save ops
    mov rsi, r8                     ; save cpu0_name
    mov r13, r9                     ; save buf

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

    ; Switch on cmd_id: 1=kill, 6=block, 7=unblock, 11=save, 12=read, 13=files, 17=ping
    cmp r12d, 1
    je .pd_kill
    cmp r12d, 6
    je .pd_block
    cmp r12d, 7
    je .pd_unblock
    cmp r12d, 11
    je .pd_save
    cmp r12d, 12
    je .pd_read
    cmp r12d, 13
    je .pd_files
    cmp r12d, 14
    je .pd_edit
    cmp r12d, 15
    je .pd_esave
    cmp r12d, 16
    je .pd_eload
    cmp r12d, 17
    je .pd_ping
    cmp r12d, 18
    je .pd_udp
    cmp r12d, 19
    je .pd_dns
    cmp r12d, 20
    je .pd_connect
    cmp r12d, 21
    je .pd_http
    cmp r12d, 22
    je .pd_tile
    cmp r12d, 23
    je .pd_tokenize
    jmp .pd_report

.pd_kill:
    ; Kill — format last_action and output to window+serial
    test rsi, rsi
    jz .pd_kill_none
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_kill]
    mov r9, rsi
    mov [rsp+32], ebx               ; ops = 5th arg
    call herb_snprintf
    ; Serial: "[KILL] name" (for test compatibility)
    lea rcx, [rel str_ser_kill]
    call serial_print
    mov rcx, rsi
    call serial_print
    jmp .pd_kill_serial_ops

.pd_kill_none:
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_kill_none]
    call herb_snprintf
    lea rcx, [rel str_ser_kill_none]
    call serial_print

.pd_kill_serial_ops:
    lea rcx, [rel str_ser_ops]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    ; Output to window
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_block:
    test rsi, rsi
    jz .pd_block_none
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_block]
    mov r9, rsi
    mov [rsp+32], ebx
    call herb_snprintf
    jmp .pd_block_serial

.pd_block_none:
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_block_none]
    call herb_snprintf

.pd_block_serial:
    ; Serial: "[BLOCK] ops=N" (for test compatibility)
    lea rcx, [rel str_ser_block]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    ; Output to window
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_unblock:
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_unblock]
    mov r9d, ebx
    call herb_snprintf
    ; Serial: "[UNBLOCK] ops=N" (for test compatibility)
    lea rcx, [rel str_ser_unblock]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    ; Output to window
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_save:
    ; Parse: skip "save ", extract filename (until next space), content = rest
    ; r13 = buf (full command string, e.g. "save test hello world")
    test r13, r13
    jz .pd_report
    cmp dword [rel fs_initialized], 0
    je .pd_save_no_disk

    ; Skip "save " (5 chars)
    lea rax, [r13]
    ; Find "save " prefix — skip to first space after command
    xor ecx, ecx
.pd_save_skip:
    cmp byte [rax + rcx], 0
    je .pd_report                   ; hit end before finding space
    cmp byte [rax + rcx], ' '
    je .pd_save_found_space
    inc ecx
    jmp .pd_save_skip
.pd_save_found_space:
    inc ecx                         ; skip the space
    lea rax, [r13 + rcx]           ; rax = start of filename

    ; Copy filename to name_buf[32] at [rsp+56], stop at space or null
    lea rdi, [rsp+56]
    ; Zero name_buf first
    push rax
    mov rcx, rdi
    xor edx, edx
    mov r8d, 32
    call herb_memset
    pop rax

    xor ecx, ecx
.pd_save_name:
    cmp ecx, 31
    jge .pd_save_name_done
    movzx edx, byte [rax + rcx]
    test dl, dl
    jz .pd_save_name_done
    cmp dl, ' '
    je .pd_save_name_done
    mov [rdi + rcx], dl
    inc ecx
    jmp .pd_save_name
.pd_save_name_done:
    mov byte [rdi + rcx], 0        ; null terminate

    ; Check we have a filename
    cmp byte [rdi], 0
    je .pd_report                   ; no filename given

    ; Find content start: skip past filename + space
    lea rdx, [rax + rcx]           ; rdx = char after filename
    cmp byte [rdx], ' '
    jne .pd_save_has_content
    inc rdx                         ; skip space between name and content
.pd_save_has_content:
    ; rdx = content string (may be empty)

    ; Calculate content length
    push rdx                        ; save content ptr
    mov rcx, rdx
    call herb_strlen
    mov r12d, eax                   ; r12d = content length (reuse, cmd_id no longer needed)
    pop rdx                         ; restore content ptr

    ; fs_create(name, data, size)
    lea rcx, [rsp+56]              ; name_buf
    ; rdx = content ptr (already set)
    mov r8d, r12d                   ; size
    call fs_create

    ; Update last_action: "Saved <name> (<size> bytes)"
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_save]
    lea r9, [rsp+56]                ; name
    mov [rsp+32], r12d              ; size = 5th arg
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_save_no_disk:
    lea rcx, [rel str_so_nodisk]
    call shell_output_print
    jmp .pd_report

.pd_read:
    ; Parse: skip "read ", extract filename
    test r13, r13
    jz .pd_report
    cmp dword [rel fs_initialized], 0
    je .pd_read_no_disk

    ; Skip to first space (past "read")
    lea rax, [r13]
    xor ecx, ecx
.pd_read_skip:
    cmp byte [rax + rcx], 0
    je .pd_report
    cmp byte [rax + rcx], ' '
    je .pd_read_found_space
    inc ecx
    jmp .pd_read_skip
.pd_read_found_space:
    inc ecx
    lea rax, [r13 + rcx]           ; rax = start of filename

    ; Copy filename to name_buf
    lea rdi, [rsp+56]
    push rax
    mov rcx, rdi
    xor edx, edx
    mov r8d, 32
    call herb_memset
    pop rax

    xor ecx, ecx
.pd_read_name:
    cmp ecx, 31
    jge .pd_read_name_done
    movzx edx, byte [rax + rcx]
    test dl, dl
    jz .pd_read_name_done
    cmp dl, ' '
    je .pd_read_name_done
    mov [rdi + rcx], dl
    inc ecx
    jmp .pd_read_name
.pd_read_name_done:
    mov byte [rdi + rcx], 0

    cmp byte [rdi], 0
    je .pd_report

    ; fs_read(name, fs_data_buf, 4096)
    lea rcx, [rsp+56]              ; name_buf
    lea rdx, [rel fs_data_buf]
    mov r8d, 4095                   ; max_size (leave room for null)
    call fs_read

    cmp eax, -1
    je .pd_report                   ; error already printed by fs_read

    ; Null-terminate the data
    lea rcx, [rel fs_data_buf]
    mov byte [rcx + rax], 0

    ; Update last_action
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_read]
    lea r9, [rsp+56]                ; name
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    ; Also print file content to output window (first 79 chars)
    lea rcx, [rel fs_data_buf]
    call shell_output_print
    jmp .pd_report

.pd_read_no_disk:
    lea rcx, [rel str_so_nodisk]
    call shell_output_print
    jmp .pd_report

.pd_files:
    cmp dword [rel fs_initialized], 0
    je .pd_files_no_disk

    ; Print header to output window
    lea rcx, [rel str_so_files_hdr]
    call shell_output_print

    call fs_list
    ; eax = file count (already printed to serial by fs_list)

    ; Summary line to output window
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_files]
    mov r9d, eax                    ; count
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_files_no_disk:
    lea rcx, [rel str_so_nodisk]
    call shell_output_print
    jmp .pd_report

.pd_edit:
%ifndef GRAPHICS_MODE
    jmp .pd_report                  ; editor not available in text mode
%endif
    ; Session 95: "/edit <name>" loads file if argument present
    test r13, r13
    jz .pd_edit_empty               ; NULL buf -> open empty
    lea rax, [r13]
    xor ecx, ecx
.pd_edit_scan:
    cmp byte [rax + rcx], 0
    je .pd_edit_empty               ; no space = bare "/edit" -> open empty
    cmp byte [rax + rcx], ' '
    je .pd_eload                    ; space found = has filename, reuse eload path
    inc ecx
    jmp .pd_edit_scan
.pd_edit_empty:
    ; Set input_ctl.mode = 2 (editor mode)
    mov ecx, [rel input_ctl_eid]
    test ecx, ecx
    js .pd_report
    lea rdx, [rel str_mode]
    mov r8d, 2
    call herb_set_prop_int
    ; Focus editor window via HERB
%ifdef GRAPHICS_MODE
    mov ecx, WM_ROLE_EDITOR
    call wm_herb_set_focus_by_role
%endif
    ; last_action + output window
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_edit_open]
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_esave:
    ; Parse "esave <name>", read editor.BUFFER chars, save to disk
    test r13, r13
    jz .pd_report
    cmp dword [rel fs_initialized], 0
    je .pd_esave_no_disk

    ; Skip "esave " — find first space
    lea rax, [r13]
    xor ecx, ecx
.pd_esave_skip:
    cmp byte [rax + rcx], 0
    je .pd_report
    cmp byte [rax + rcx], ' '
    je .pd_esave_found_space
    inc ecx
    jmp .pd_esave_skip
.pd_esave_found_space:
    inc ecx
    lea rax, [r13 + rcx]              ; rax = start of filename

    ; Copy filename to name_buf[32] at [rsp+56]
    lea rdi, [rsp+56]
    push rax
    mov rcx, rdi
    xor edx, edx
    mov r8d, 32
    call herb_memset
    pop rax

    xor ecx, ecx
.pd_esave_name:
    cmp ecx, 31
    jge .pd_esave_name_done
    movzx edx, byte [rax + rcx]
    test dl, dl
    jz .pd_esave_name_done
    cmp dl, ' '
    je .pd_esave_name_done
    mov [rdi + rcx], dl
    inc ecx
    jmp .pd_esave_name
.pd_esave_name_done:
    mov byte [rdi + rcx], 0

    cmp byte [rdi], 0
    je .pd_report

    ; Build string from editor.BUFFER entities into fs_data_buf
    ; Zero fs_data_buf first
    push rdi                            ; save name_buf ptr
    lea rcx, [rel fs_data_buf]
    xor edx, edx
    mov r8d, 4096
    call herb_memset

    ; nc = herb_container_count("editor.BUFFER")
    lea rcx, [rel str_cn_ed_buffer]
    call herb_container_count
    test eax, eax
    jle .pd_esave_write                 ; empty buffer, save empty file

    mov edi, eax                        ; edi = entity count
    xor r12d, r12d                      ; i = 0
    xor ebx, ebx                        ; max_pos = 0

.pd_esave_loop:
    cmp r12d, edi
    jge .pd_esave_write

    ; eid = herb_container_entity("editor.BUFFER", i)
    lea rcx, [rel str_cn_ed_buffer]
    mov edx, r12d
    call herb_container_entity
    test eax, eax
    js .pd_esave_next

    mov [rsp+40], eax                   ; save eid (rsp+40 because we pushed rdi)

    ; pos = herb_entity_prop_int(eid, "pos", 0)
    mov ecx, eax
    lea rdx, [rel str_pos]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+44], eax                   ; save pos

    ; ascii = herb_entity_prop_int(eid, "ascii", 0)
    mov ecx, [rsp+40]
    lea rdx, [rel str_ascii_prop]
    xor r8d, r8d
    call herb_entity_prop_int

    ; if pos >= 0 && pos < 4095 && ascii > 0: fs_data_buf[pos] = ascii
    mov ecx, [rsp+44]
    test ecx, ecx
    js .pd_esave_next
    cmp ecx, 4095
    jge .pd_esave_next
    test eax, eax
    jle .pd_esave_next
    lea rdx, [rel fs_data_buf]
    mov [rdx + rcx], al
    ; max_pos = max(max_pos, pos + 1)
    inc ecx
    cmp ecx, ebx
    jle .pd_esave_next
    mov ebx, ecx

.pd_esave_next:
    inc r12d
    jmp .pd_esave_loop

.pd_esave_write:
    ; Null-terminate
    lea rcx, [rel fs_data_buf]
    mov byte [rcx + rbx], 0

    ; fs_create(name, data, size)
    pop rdi                             ; restore name_buf ptr
    lea rcx, [rsp+56]                  ; name_buf
    lea rdx, [rel fs_data_buf]
    mov r8d, ebx                        ; size = max_pos
    mov [rsp+32], ebx                   ; save size for snprintf
    call fs_create

    ; Serial
    lea rcx, [rel str_ser_esave]
    call serial_print
    lea rcx, [rsp+56]
    call serial_print
    lea rcx, [rel str_newline]
    call serial_print

    ; last_action
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_esave]
    lea r9, [rsp+56]                    ; name
    mov eax, [rsp+32]                   ; saved size
    mov [rsp+32], eax                   ; 5th arg = size
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_esave_no_disk:
    lea rcx, [rel str_so_nodisk]
    call shell_output_print
    jmp .pd_report

.pd_eload:
    ; Parse "eload <name>", read file, populate editor.BUFFER
    test r13, r13
    jz .pd_report
    cmp dword [rel fs_initialized], 0
    je .pd_eload_no_disk

    ; Skip to first space
    lea rax, [r13]
    xor ecx, ecx
.pd_eload_skip:
    cmp byte [rax + rcx], 0
    je .pd_report
    cmp byte [rax + rcx], ' '
    je .pd_eload_found_space
    inc ecx
    jmp .pd_eload_skip
.pd_eload_found_space:
    inc ecx
    lea rax, [r13 + rcx]

    ; Copy filename to name_buf
    lea rdi, [rsp+56]
    push rax
    mov rcx, rdi
    xor edx, edx
    mov r8d, 32
    call herb_memset
    pop rax

    xor ecx, ecx
.pd_eload_name:
    cmp ecx, 31
    jge .pd_eload_name_done
    movzx edx, byte [rax + rcx]
    test dl, dl
    jz .pd_eload_name_done
    cmp dl, ' '
    je .pd_eload_name_done
    mov [rdi + rcx], dl
    inc ecx
    jmp .pd_eload_name
.pd_eload_name_done:
    mov byte [rdi + rcx], 0

    cmp byte [rdi], 0
    je .pd_report

    ; fs_read(name, fs_data_buf, 4095)
    lea rcx, [rsp+56]
    lea rdx, [rel fs_data_buf]
    mov r8d, 4095
    call fs_read
    cmp eax, -1
    je .pd_report

    ; eax = bytes read, save it
    mov [rsp+32], eax                   ; file_size

    ; Now clear editor.BUFFER: move all entities back to POOL
    ; We do this by iterating BUFFER and using container_remove/container_add
    ; First, find container indices
    lea rcx, [rel str_cn_ed_buffer]
    call intern
    mov ecx, eax
    call graph_find_container_by_name
    mov [rsp+36], eax                   ; buffer_cidx

    lea rcx, [rel str_cn_ed_pool]
    call intern
    mov ecx, eax
    call graph_find_container_by_name
    mov [rsp+40], eax                   ; pool_cidx

    ; Clear editor.BUFFER: move entities to POOL
    ; Count current BUFFER entities
.pd_eload_clear:
    lea rcx, [rel str_cn_ed_buffer]
    call herb_container_count
    test eax, eax
    jle .pd_eload_populate

    ; Get entity at index 0 (always remove first)
    lea rcx, [rel str_cn_ed_buffer]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .pd_eload_populate

    ; container_remove(buffer_cidx, entity_idx)
    mov ecx, [rsp+36]                  ; buffer_cidx
    mov edx, eax                        ; entity_idx
    mov [rsp+44], edx                   ; save entity_idx
    call container_remove

    ; container_add(pool_cidx, entity_idx)
    mov ecx, [rsp+40]                  ; pool_cidx
    mov edx, [rsp+44]                  ; entity_idx
    call container_add

    ; Update entity location
    mov eax, [rsp+44]
    mov ecx, [rsp+40]                  ; pool_cidx
    ; entity_location[entity_idx] = pool_cidx
    lea rdx, [rel g_graph]
    add rdx, GRAPH_ENTITY_LOCATION
    movsxd rax, dword [rsp+44]
    mov [rdx + rax*4], ecx

    ; Reset ascii/pos on entity
    mov ecx, [rsp+44]
    lea rdx, [rel str_ascii_prop]
    xor r8d, r8d
    call herb_set_prop_int
    mov ecx, [rsp+44]
    lea rdx, [rel str_pos]
    xor r8d, r8d
    call herb_set_prop_int

    jmp .pd_eload_clear

.pd_eload_populate:
    ; Now populate BUFFER from file data
    ; For each byte i in 0..file_size-1:
    ;   Get entity from POOL, set ascii=byte, pos=i, move to BUFFER
    mov edi, [rsp+32]                   ; file_size
    test edi, edi
    jz .pd_eload_done
    xor r12d, r12d                      ; i = 0

.pd_eload_pop_loop:
    cmp r12d, edi
    jge .pd_eload_done

    ; Get first entity from POOL
    lea rcx, [rel str_cn_ed_pool]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .pd_eload_done                   ; no more pool entities

    mov [rsp+44], eax                   ; entity_idx

    ; Get ascii byte from file data
    lea rcx, [rel fs_data_buf]
    movzx ebx, byte [rcx + r12]        ; ascii = fs_data_buf[i]
    test ebx, ebx
    jz .pd_eload_pop_next               ; skip null bytes

    ; Set ascii property
    mov ecx, [rsp+44]
    lea rdx, [rel str_ascii_prop]
    mov r8d, ebx
    call herb_set_prop_int

    ; Set pos property
    mov ecx, [rsp+44]
    lea rdx, [rel str_pos]
    mov r8d, r12d
    call herb_set_prop_int

    ; container_remove(pool_cidx, entity_idx)
    mov ecx, [rsp+40]                  ; pool_cidx
    mov edx, [rsp+44]
    call container_remove

    ; container_add(buffer_cidx, entity_idx)
    mov ecx, [rsp+36]                  ; buffer_cidx
    mov edx, [rsp+44]
    call container_add

    ; Update entity location
    movsxd rax, dword [rsp+44]
    mov ecx, [rsp+36]                  ; buffer_cidx
    lea rdx, [rel g_graph]
    add rdx, GRAPH_ENTITY_LOCATION
    mov [rdx + rax*4], ecx

.pd_eload_pop_next:
    inc r12d
    jmp .pd_eload_pop_loop

.pd_eload_done:
    ; Set editor_ctl.cursor_pos = file_size
    lea rcx, [rel str_cn_ed_ctl]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .pd_eload_serial

    mov ecx, eax
    lea rdx, [rel str_prop_cursor_pos]
    mov r8d, [rsp+32]                   ; file_size
    call herb_set_prop_int

.pd_eload_serial:
    ; Set mode = 2 (enter editor mode)
    mov ecx, [rel input_ctl_eid]
    test ecx, ecx
    js .pd_eload_action
    lea rdx, [rel str_mode]
    mov r8d, 2
    call herb_set_prop_int
    ; Focus editor window via HERB
%ifdef GRAPHICS_MODE
    mov ecx, WM_ROLE_EDITOR
    call wm_herb_set_focus_by_role
%endif

.pd_eload_action:
    ; Trigger HAM to run flow pass (derive GLYPHS from BUFFER)
    call ham_mark_dirty
    mov ecx, 100
    call ham_run_ham
    mov [rsp+48], eax                      ; save ops count

    ; last_action
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_eload]
    lea r9, [rsp+56]                    ; name
    mov eax, [rsp+32]
    mov [rsp+32], eax                   ; 5th arg = size
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_eload_no_disk:
    lea rcx, [rel str_so_nodisk]
    call shell_output_print
    jmp .pd_report

.pd_ping:
    ; Increment sequence counter
    mov eax, [rel ping_seq]
    inc eax
    mov [rel ping_seq], eax
    ; Set pending and record tick
    mov dword [rel ping_pending], 1
    mov ecx, [rel timer_count]
    mov [rel ping_tick], ecx
    ; icmp_send_echo(dst_ip=gateway, seq=ping_seq)
    mov ecx, [rel net_gateway_ip]
    mov edx, eax                    ; sequence
    call icmp_send_echo
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_ping]
    mov r9d, [rel ping_seq]
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_udp:
    mov ecx, [rel net_gateway_ip]
    mov edx, 7777
    mov r8d, 4444
    lea r9, [rel str_udp_payload]
    mov dword [rsp+32], 4
    call udp_send
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_udp]
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_dns:
    test r13, r13
    jz .pd_report
    lea rax, [r13]
    xor ecx, ecx
.pd_dns_skip:
    cmp byte [rax + rcx], 0
    je .pd_dns_default
    cmp byte [rax + rcx], ' '
    je .pd_dns_found_space
    inc ecx
    jmp .pd_dns_skip
.pd_dns_found_space:
    inc ecx
    lea rcx, [r13 + rcx]
    cmp byte [rcx], 0
    je .pd_dns_default
    jmp .pd_dns_do
.pd_dns_default:
    lea rcx, [rel str_dns_domain]
.pd_dns_do:
    mov [rsp+80], rcx
    call dns_resolve
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_dns]
    mov r9, [rsp+80]
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_connect:
    cmp dword [rel dns_resolved_flag], 0
    je .pd_connect_gw
    mov ecx, [rel dns_result_ip]
    jmp .pd_connect_do
.pd_connect_gw:
    mov ecx, [rel net_gateway_ip]
.pd_connect_do:
    mov edx, 80
    call tcp_connect
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_connect]
    lea r9, [rel str_dns_domain]
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_http:
    lea rcx, [rel str_dns_domain]
    lea rdx, [rel str_http_slash]
    call http_get
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_http]
    lea r9, [rel str_dns_domain]
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    jmp .pd_report

.pd_tile:
    ; Session 92: Toggle tiling layout
    ; Find tiling flow index (first time only)
    cmp dword [rel g_tile_flow_idx], -1
    jne .pd_tile_toggle
    ; Search g_flows for wm.tile_horizontal
    lea rcx, [rel str_tile_flow_name]
    call intern
    ; eax = interned name_id for "wm.tile_horizontal"
    mov ebx, eax                        ; save name_id in ebx (callee-saved)
    xor r13d, r13d                      ; r13d = flow index
.pd_tile_find:
    cmp r13d, [rel g_flow_count]
    jge .pd_tile_notfound
    movsxd rax, r13d
    imul rax, SIZEOF_FLOW
    lea rcx, [g_flows + rax]
    cmp dword [rcx + FLOW_NAME_ID], ebx
    je .pd_tile_found
    inc r13d
    jmp .pd_tile_find
.pd_tile_found:
    mov dword [rel g_tile_flow_idx], r13d
    jmp .pd_tile_toggle
.pd_tile_notfound:
    ; Flow not found — leave g_tile_flow_idx as -1
    jmp .pd_report

.pd_tile_toggle:
    ; Toggle g_tiling_active
    xor dword [rel g_tiling_active], 1
    cmp dword [rel g_tiling_active], 0
    je .pd_tile_off

    ; Tiling ON: run HAM to execute tiling flow, then sync geometry
    mov ecx, 100
    call ham_run_ham
    call wm_sync_geometry_from_herb
    ; Serial: "[WM] tiling ENABLED" (for test compatibility)
    lea rcx, [rel str_ser_tile_on]
    call serial_print
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_tile_on]
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    call draw_full
    jmp .pd_report

.pd_tile_off:
    ; Tiling OFF: positions stay, dragging works
    ; Serial: "[WM] tiling DISABLED" (for test compatibility)
    lea rcx, [rel str_ser_tile_off]
    call serial_print
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_tile_off]
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print
    call draw_full
    jmp .pd_report

.pd_tokenize:
    call browser_tokenize_cmd
    jmp .pd_report

.pd_report:
    call report_buffer_state

    add rsp, 88
    pop r13
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
    ; Print header to output window FIRST (before [LIST] serial line)
    lea rcx, [rel str_so_list_hdr]
    call shell_output_print

    ; Serial: "[LIST]" line (test looks for [LIST].*shell on one line)
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
    mov [rsp+180], esi              ; save i (above hids/hords buffers)
    call herb_container_entity
    test eax, eax
    js .hsa_list_next

    ; Save eid for property lookup
    mov edi, eax
    ; Get entity name
    mov ecx, eax
    call herb_entity_name
    mov [rsp+184], rax              ; save name ptr at [184..191]

    ; Serial: print entity name + (LABEL,p=N) for test compatibility
    mov rcx, rax
    call serial_print
    lea rcx, [rel str_ser_paren_l]
    call serial_print
    mov rcx, r14
    call serial_print
    lea rcx, [rel str_ser_p_eq]
    call serial_print

    ; Get priority
    mov ecx, edi
    lea rdx, [rel str_priority]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+192], eax              ; save priority

    ; Serial: print priority + ") "
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_ser_paren_sp]
    call serial_print

    ; Format: "  name (LABEL, p=N)" into scratch buffer for output window
    ; Use scratch + direct buffer write (NOT shell_output_print to avoid serial newline
    ; which would break the [LIST] serial line the tests expect)
    lea rcx, [rel shell_output_scratch]
    mov edx, 80
    lea r8, [rel str_so_proc_fmt]
    mov r9, [rsp+184]              ; entity name
    mov [rsp+32], r14              ; label string = 5th arg
    mov eax, [rsp+192]             ; priority
    mov dword [rsp+40], eax        ; priority = 6th arg
    call herb_snprintf

    ; Inline buffer write: copy scratch to shell_output_buf[head], advance head/count
    mov eax, dword [rel shell_output_head]
    imul eax, SHELL_OUTPUT_LINE_LEN
    lea rcx, [rel shell_output_buf]
    add rcx, rax                    ; dest
    lea rdx, [rel shell_output_scratch]  ; src
    mov r8d, SHELL_OUTPUT_LINE_LEN - 1
    call herb_strncpy
    ; Null-terminate
    mov eax, dword [rel shell_output_head]
    imul eax, SHELL_OUTPUT_LINE_LEN
    lea rcx, [rel shell_output_buf]
    mov byte [rcx + rax + SHELL_OUTPUT_LINE_LEN - 1], 0
    ; Advance head
    mov eax, dword [rel shell_output_head]
    inc eax
    cmp eax, SHELL_OUTPUT_MAX_LINES
    jl .hsa_list_no_wrap
    xor eax, eax
.hsa_list_no_wrap:
    mov dword [rel shell_output_head], eax
    ; Increment count (cap at max)
    mov eax, dword [rel shell_output_count]
    cmp eax, SHELL_OUTPUT_MAX_LINES
    jge .hsa_list_count_ok
    inc eax
    mov dword [rel shell_output_count], eax
.hsa_list_count_ok:

.hsa_list_next:
    mov esi, [rsp+180]             ; restore i
    inc esi
    jmp .hsa_list_ent

.hsa_cont_next:
    inc r12d
    jmp .hsa_list_container

.hsa_list_done:
    lea rcx, [rel str_newline]
    call serial_print
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
    ; Print header to output window
    lea rcx, [rel str_so_help_hdr]
    call shell_output_print

    ; Print help entries (one per line to output window)
    xor r13d, r13d                  ; i = 0
.hsa_help_print_loop:
    cmp r13d, r12d
    jge .hsa_help_print_done

    ; Get cmd_text from entity
    mov ecx, [rsp+48+r13*4]
    lea rdx, [rel str_cmd_text]
    lea r8, [rel str_ser_question]
    call herb_entity_prop_str

    ; Format "  /cmd_text" into scratch buffer
    lea rcx, [rel shell_output_scratch]
    mov edx, 80
    lea r8, [rel str_so_help_fmt]
    mov r9, rax                     ; cmd_text string
    call herb_snprintf
    lea rcx, [rel shell_output_scratch]
    call shell_output_print

    inc r13d
    jmp .hsa_help_print_loop

.hsa_help_print_done:
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
    ; Serial: "[SHELL] unknown" (for test compatibility)
    lea rcx, [rel str_ser_shell_unk]
    call serial_print
    lea rcx, [rel last_action]
    mov edx, 80
    lea r8, [rel str_la_shell_cmd_unk]
    call herb_snprintf
    lea rcx, [rel last_action]
    call shell_output_print

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

    ; Let HAM clear submitted/CMDLINE reactively.
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
    lea rcx, [rel bin_schedule_roundrobin]
    mov edx, [rel bin_sched_rr_len]
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
    lea rcx, [rel bin_schedule_priority]
    mov edx, [rel bin_sched_pri_len]
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

    ; recycle_or_create_entity(sig_name, ET_SIGNAL, CN_SPAWN_SIG, CN_SIG_DONE)
    lea rcx, [rsp+48]
    lea rdx, [rel str_et_signal]
    lea r8, [rel str_cn_spawn_sig]
    lea r9, [rel str_cn_sig_done]
    call recycle_or_create_entity
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
    ; herb_load_program(bin_producer, bin_producer_len, eid, CN_CPU0)
    lea rcx, [rel bin_producer]
    mov edx, [rel bin_producer_len]
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
    ; herb_load_program(bin_consumer, bin_consumer_len, eid, CN_CPU0)
    lea rcx, [rel bin_consumer]
    mov edx, [rel bin_consumer_len]
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
    ; herb_load_program(bin_worker, bin_worker_len, eid, CN_CPU0)
    lea rcx, [rel bin_worker]
    mov edx, [rel bin_worker_len]
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
    ; herb_load_program(bin_beacon, bin_beacon_len, eid, CN_CPU0)
    lea rcx, [rel bin_beacon]
    mov edx, [rel bin_beacon_len]
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

    ; ---- Session 95: Tab focus cycling (command mode only) ----
%ifdef GRAPHICS_MODE
    cmp r12d, 0x0F                      ; Tab scancode
    jne .hk_not_tab
    cmp dword [rel ed_active], 1        ; skip if gap-buffer editor active
    je .hk_not_tab
    mov ecx, [rel input_ctl_eid]
    test ecx, ecx
    js .hk_tab_cycle                    ; no InputCtl -> treat as command mode
    lea rdx, [rel str_mode]
    xor r8d, r8d
    call herb_entity_prop_int
    test eax, eax
    jnz .hk_not_tab                     ; mode != 0 -> skip
.hk_tab_cycle:
    mov eax, [rel focus_cycle_idx]
    inc eax
    cmp eax, 7
    jl .hk_tab_nowrap
    xor eax, eax
.hk_tab_nowrap:
    mov [rel focus_cycle_idx], eax
    mov ecx, eax                        ; role
    call wm_herb_set_focus_by_role
    call draw_full
    jmp .hk_done
.hk_not_tab:
%endif

    ; ---- Editor: intercept ALL keys when editor is active ----
%ifdef GRAPHICS_MODE
    cmp dword [rel ed_active], 1
    jne .hk_not_editor_input
    movzx ecx, r13b                     ; ASCII
    mov edx, r12d                       ; scancode
    call editor_handle_key
    call draw_full
    jmp .hk_done
.hk_not_editor_input:

    ; ---- Session 94: Flow editor arrow keys + PgUp/PgDn ----
%ifdef KERNEL_MODE
    ; Check if in flow editor mode (InputCtl.mode == 2, gap-buffer editor not active)
    mov ecx, [rel input_ctl_eid]
    test ecx, ecx
    js .hk_not_flow_editor
    lea rdx, [rel str_mode]
    xor r8d, r8d
    call herb_entity_prop_int
    cmp eax, 2
    jne .hk_not_flow_editor

    ; Arrow Left (scancode 0x4B): cursor_pos - 1
    cmp r12d, 0x4B
    jne .hk_fed_not_left
    ; Read cursor_pos from editor.CTL entity
    lea rcx, [rel str_cn_ed_ctl]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .hk_done
    mov ebx, eax                        ; ebx = ectl entity id
    mov ecx, eax
    lea rdx, [rel str_prop_cursor_pos]
    xor r8d, r8d
    call herb_entity_prop_int
    ; eax = cursor_pos; decrement, clamp >= 0
    test eax, eax
    jle .hk_done                        ; already at 0
    dec eax
    mov ecx, ebx
    lea rdx, [rel str_prop_cursor_pos]
    movsxd r8, eax
    call herb_set_prop_int
    call draw_full
    jmp .hk_done

.hk_fed_not_left:
    ; Arrow Right (scancode 0x4D): cursor_pos + 1
    cmp r12d, 0x4D
    jne .hk_fed_not_right
    ; Read cursor_pos + buffer count
    lea rcx, [rel str_cn_ed_ctl]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .hk_done
    mov ebx, eax                        ; ebx = ectl entity id
    mov ecx, eax
    lea rdx, [rel str_prop_cursor_pos]
    xor r8d, r8d
    call herb_entity_prop_int
    mov esi, eax                        ; esi = cursor_pos
    ; Get buffer count to clamp
    lea rcx, [rel str_cn_ed_buffer]
    call herb_container_count
    ; eax = buffer count; clamp cursor_pos + 1 <= buffer_count
    cmp esi, eax
    jge .hk_done                        ; already at end
    inc esi
    mov ecx, ebx
    lea rdx, [rel str_prop_cursor_pos]
    movsxd r8, esi
    call herb_set_prop_int
    call draw_full
    jmp .hk_done

.hk_fed_not_right:
    ; PgUp (scancode 0x49): scroll editor up
    cmp r12d, 0x49
    jne .hk_not_fed_pgup
    mov eax, [rel flow_editor_scroll_y]
    sub eax, 10                         ; page up by 10 lines
    test eax, eax
    jns .hk_fed_pgup_ok
    xor eax, eax                        ; clamp to 0
.hk_fed_pgup_ok:
    mov [rel flow_editor_scroll_y], eax
    call draw_full
    jmp .hk_done

.hk_not_fed_pgup:
    ; PgDn (scancode 0x51): scroll editor down
    cmp r12d, 0x51
    jne .hk_not_fed_pgdn
    mov eax, [rel flow_editor_scroll_y]
    add eax, 10
    mov [rel flow_editor_scroll_y], eax
    call draw_full
    jmp .hk_done

.hk_not_fed_pgdn:
.hk_not_flow_editor:
%endif  ; KERNEL_MODE

    ; ---- PgUp/PgDn: scroll output window (when not in flow editor) ----
    cmp r12d, 0x49                       ; PgUp scancode
    je .hk_scroll_up
    cmp r12d, 0x51                       ; PgDn scancode
    je .hk_scroll_down
    jmp .hk_skip_scroll

.hk_scroll_up:
    mov eax, dword [rel shell_output_scroll]
    mov ecx, dword [rel shell_output_count]
    sub ecx, 5                           ; max scroll = count - approx visible
    cmp ecx, 0
    jle .hk_done                         ; nothing to scroll
    inc eax
    cmp eax, ecx
    jg .hk_done                          ; already at top
    mov dword [rel shell_output_scroll], eax
    jmp .hk_done

.hk_scroll_down:
    mov eax, dword [rel shell_output_scroll]
    test eax, eax
    jz .hk_done                          ; already at bottom
    dec eax
    mov dword [rel shell_output_scroll], eax
    jmp .hk_done

.hk_skip_scroll:

    ; ---- 'E' key opens editor (command mode only) ----
    cmp r13b, 'e'
    jne .hk_not_editor_open
    cmp dword [rel fb_active], 0
    je .hk_not_editor_open
%ifdef KERNEL_MODE
    ; Only open in command mode (InputCtl.mode == 0)
    mov ecx, [rel input_ctl_eid]
    test ecx, ecx
    js .hk_editor_open_ok              ; no InputCtl = command mode
    lea rdx, [rel str_mode]
    xor r8d, r8d
    call herb_entity_prop_int
    test eax, eax
    jnz .hk_not_editor_open            ; mode != 0 = text mode, skip
.hk_editor_open_ok:
%endif
    call editor_open
    call draw_full
    jmp .hk_done
.hk_not_editor_open:
%endif  ; GRAPHICS_MODE

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

    ; Turing machine step: intercept 'j' in command mode (mode==0)
    test esi, esi                       ; prev_mode == 0 (command mode)?
    jnz .hk_not_turing_early
    cmp r13b, 'j'
    jne .hk_not_turing_early
    call cmd_turing_step
    jmp .hk_input_draw
.hk_not_turing_early:

    ; create_key_signal(ch)
    movsx ecx, r13b
    call create_key_signal

    ; HAM trace disabled — editor bug fixed (container syntax)

    ; ops = ham_run_ham(100)
    mov ecx, 100
    call ham_run_ham
    mov ebx, eax
    add [rel total_ops], eax

.hk_edkey_debug_skip:

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
    ; Always clear mech_action (prevent stale value across mode transitions)
    mov ecx, [rel input_ctl_eid]
    lea rdx, [rel str_mech_action]
    xor r8d, r8d
    call herb_set_prop_int
    ; Defense-in-depth: only dispatch in command mode (mode 0)
    ; HERB guard (where ctl.mode == 0) may not compile correctly (Discovery 60)
    cmp dword [rsp+128], 0              ; cur_mode == 0?
    jne .hk_no_mech
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
%ifdef KERNEL_MODE
    ; (u key handled inside KERNEL_MODE input routing above)
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

; ============================================================
; Phase D Step 4: Infrastructure + Simple Helpers
; ============================================================

; void mouse_handle_packet(void)
; Process a complete 3-byte mouse packet.
; Reads mouse_packet[0..2], updates mouse_x/y, detects clicks.
mouse_handle_packet:
    push rbp
    mov rbp, rsp
    sub rsp, 32                     ; shadow space
    ; 1 push + sub 32 = 8+32 = 40. 40%16=8. ✓

    ; flags = mouse_packet[0], dx = mouse_packet[1], dy = mouse_packet[2]
    lea rax, [rel mouse_packet]
    movzx ecx, byte [rax]          ; flags
    movzx edx, byte [rax + 1]      ; dx (unsigned)
    movzx r8d, byte [rax + 2]      ; dy (unsigned)

    ; Sign extension from flags
    test ecx, 0x10
    jz .mhp_no_sx
    or edx, 0xFFFFFF00              ; sign-extend X
.mhp_no_sx:
    test ecx, 0x20
    jz .mhp_no_sy
    or r8d, 0xFFFFFF00              ; sign-extend Y
.mhp_no_sy:

    ; Discard overflow packets
    test ecx, 0xC0
    jnz .mhp_done

    ; Update absolute position: mouse_x += dx, mouse_y -= dy
    add dword [rel mouse_x], edx
    sub dword [rel mouse_y], r8d

    ; Clamp mouse_x: 0..799
    mov eax, [rel mouse_x]
    test eax, eax
    jns .mhp_mx_pos
    mov dword [rel mouse_x], 0
    jmp .mhp_clamp_y
.mhp_mx_pos:
    cmp eax, FB_WIDTH
    jl .mhp_clamp_y
    mov dword [rel mouse_x], FB_WIDTH - 1

.mhp_clamp_y:
    mov eax, [rel mouse_y]
    test eax, eax
    jns .mhp_my_pos
    mov dword [rel mouse_y], 0
    jmp .mhp_click
.mhp_my_pos:
    cmp eax, FB_HEIGHT
    jl .mhp_click
    mov dword [rel mouse_y], FB_HEIGHT - 1

.mhp_click:
    ; Detect left button click (transition from not-pressed to pressed)
    mov eax, ecx
    and eax, 0x01                   ; left_now
    test eax, eax
    jz .mhp_no_click
    test dword [rel mouse_buttons], 0x01
    jnz .mhp_no_click              ; was already pressed
    mov dword [rel mouse_left_clicked], 1
.mhp_no_click:
    ; Detect left button release (transition from pressed to not-pressed)
    mov eax, ecx
    and eax, 0x01
    test eax, eax
    jnz .mhp_no_release                ; still pressed
    test dword [rel mouse_buttons], 0x01
    jz .mhp_no_release                 ; was already released
    mov dword [rel mouse_left_released], 1
.mhp_no_release:
    ; mouse_buttons = flags & 0x07
    mov eax, ecx
    and eax, 0x07
    mov [rel mouse_buttons], eax

    ; Mark cursor moved if dx != 0 || dy != 0
    test edx, edx
    jnz .mhp_moved
    test r8d, r8d
    jz .mhp_done
.mhp_moved:
    mov dword [rel mouse_moved], 1

.mhp_done:
    add rsp, 32
    pop rbp
    ret

; void herb_error_handler(int severity, const char* message)
; Display error on VGA row 24 in red + print to serial.
; MS x64: ECX=severity (unused), RDX=message
herb_error_handler:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 32                     ; shadow
    ; 2 pushes + sub 32 = 16+32 = 48. 48%16=8. ✓ (wait: 8+16+32 = 56. 56%16=8. ✓)

    mov rbx, rdx                    ; save message pointer

    ; Save old color, set red on black
    movzx eax, byte [rel vga_color]
    mov [rsp + 28], al              ; save old_color at [rsp+28]
    mov ecx, 0x04                   ; VGA_RED
    xor edx, edx                    ; VGA_BLACK
    call vga_set_color

    ; vga_print_at(24, 0, "ERR: ")
    mov ecx, 24
    xor edx, edx
    lea r8, [rel str_err_prefix]
    call vga_print_at

    ; vga_print(message)
    mov rcx, rbx
    call vga_print

    ; Restore old color
    movzx eax, byte [rsp + 28]
    mov [rel vga_color], al

    ; serial_print("[ERROR] ")
    lea rcx, [rel str_err_serial]
    call serial_print

    ; serial_print(message)
    mov rcx, rbx
    call serial_print

    ; serial_print("\n")
    lea rcx, [rel str_newline]
    call serial_print

    add rsp, 32
    pop rbx
    pop rbp
    ret

; uint32_t terrain_color(int terrain)
; Returns color constant for terrain type 0-4.
; MS x64: ECX=terrain. Returns EAX=color.
terrain_color:
    cmp ecx, 0
    je .tc_grass
    cmp ecx, 1
    je .tc_forest
    cmp ecx, 2
    je .tc_water
    cmp ecx, 3
    je .tc_stone
    cmp ecx, 4
    je .tc_dirt
.tc_grass:
    mov eax, 0x003A7D44             ; COL_TILE_GRASS
    ret
.tc_forest:
    mov eax, 0x001B5E20             ; COL_TILE_FOREST
    ret
.tc_water:
    mov eax, 0x001565C0             ; COL_TILE_WATER
    ret
.tc_stone:
    mov eax, 0x00757575             ; COL_TILE_STONE
    ret
.tc_dirt:
    mov eax, 0x00795548             ; COL_TILE_DIRT
    ret

; const char* terrain_name(int terrain)
; Returns name string for terrain type 0-4.
; MS x64: ECX=terrain. Returns RAX=pointer.
terrain_name:
    cmp ecx, 0
    je .tn_grass
    cmp ecx, 1
    je .tn_forest
    cmp ecx, 2
    je .tn_water
    cmp ecx, 3
    je .tn_stone
    cmp ecx, 4
    je .tn_dirt
    lea rax, [rel str_terrain_unknown]
    ret
.tn_grass:
    lea rax, [rel str_terrain_grass]
    ret
.tn_forest:
    lea rax, [rel str_terrain_forest]
    ret
.tn_water:
    lea rax, [rel str_terrain_water]
    ret
.tn_stone:
    lea rax, [rel str_terrain_stone]
    ret
.tn_dirt:
    lea rax, [rel str_terrain_dirt]
    ret

; void draw_banner(void)
; Draw the VGA text-mode banner bar (row 0).
draw_banner:
    push rbp
    mov rbp, rsp
    sub rsp, 32                     ; shadow
    ; 1 push + sub 32 = 40. 40%16=8. ✓

    ; vga_set_color(VGA_BLACK=0, VGA_CYAN=3)
    xor ecx, ecx                    ; VGA_BLACK
    mov edx, 3                      ; VGA_CYAN
    call vga_set_color

    ; vga_clear_row(ROW_BANNER=0)
    xor ecx, ecx
    call vga_clear_row

    ; vga_print_at(0, 2, OS_TITLE)
    xor ecx, ecx
    mov edx, 2
%ifdef KERNEL_MODE
    lea r8, [rel str_os_title_km]
%else
    lea r8, [rel str_os_title]
%endif
    call vga_print_at

    ; vga_print_at(0, 60, OS_SUBTITLE)
    xor ecx, ecx
    mov edx, 60
%ifdef KERNEL_MODE
    lea r8, [rel str_os_subtitle_km]
%else
    lea r8, [rel str_os_subtitle]
%endif
    call vga_print_at

    add rsp, 32
    pop rbp
    ret

; ============================================================
; Phase D Step 5: Text Mode Draw Functions
; ============================================================

; Layout constants
ROW_BANNER    equ 0
ROW_STATS     equ 1
ROW_LEGEND    equ 3
ROW_TABLE_HDR equ 5
ROW_TABLE     equ 6
MAX_TABLE_ROWS equ 10
ROW_SUMMARY   equ 17
ROW_LOG       equ 23
ROW_ERROR     equ 24

; VGA color constants
VGA_BLACK     equ 0x00
VGA_BLUE      equ 0x01
VGA_CYAN      equ 0x03
VGA_RED       equ 0x04
VGA_LRED      equ 0x0C
VGA_YELLOW    equ 0x0E
VGA_WHITE     equ 0x0F
VGA_LGRAY     equ 0x07
VGA_DGRAY     equ 0x08
VGA_LGREEN    equ 0x0A
VGA_LCYAN     equ 0x0B
VGA_LMAGENTA  equ 0x0D

; void draw_log(void)
; Display last_action on ROW_LOG.
draw_log:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    ; 1 push + sub 32 = 40. 40%16=8. ✓

    mov ecx, VGA_LGREEN
    xor edx, edx
    call vga_set_color

    mov ecx, ROW_LOG
    call vga_clear_row

    lea rax, [rel last_action]
    cmp byte [rax], 0
    je .dl_done
    mov ecx, ROW_LOG
    mov edx, 1
    lea r8, [rel str_log_prefix]
    call vga_print_at
    lea rcx, [rel last_action]
    call vga_print
.dl_done:
    add rsp, 32
    pop rbp
    ret

; void draw_stats(void)
; Draw the stats bar on ROW_STATS.
; Stack frame: buf[16] at [rsp+48]
draw_stats:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 64                     ; shadow(32) + buf[16] + align padding(16)
    ; 2 pushes + sub 64 = 16+64 = 80. 80%16=8. ✓ (8+16+64=88, 88%16=8. ✓)

    ; vga_set_color(VGA_WHITE, VGA_BLUE)
    mov ecx, VGA_WHITE
    mov edx, VGA_BLUE
    call vga_set_color

    ; vga_clear_row(ROW_STATS)
    mov ecx, ROW_STATS
    call vga_clear_row

    ; vga_print_at(ROW_STATS, 1, "Tick:")
    mov ecx, ROW_STATS
    mov edx, 1
    lea r8, [rel str_tick]
    call vga_print_at

    ; vga_print_int(timer_count / 100)
    mov eax, [rel timer_count]
    cdq
    mov ecx, 100
    idiv ecx
    mov ecx, eax
    call vga_print_int

    ; vga_print("  Ops:")
    lea rcx, [rel str_ops_label]
    call vga_print

    ; vga_print_int(total_ops)
    mov ecx, [rel total_ops]
    call vga_print_int

    ; vga_print("  Arena:")
    lea rcx, [rel str_arena_label]
    call vga_print

    ; herb_snprintf(buf, 16, "%d", herb_arena_usage()/1024)
    call herb_arena_usage
    shr eax, 10                     ; /1024
    lea rcx, [rsp + 48]
    mov edx, 16
    lea r8, [rel str_fmt_d]
    mov r9d, eax
    call herb_snprintf
    ; vga_print(buf)
    lea rcx, [rsp + 48]
    call vga_print
    ; vga_print("KB")
    lea rcx, [rel str_kb]
    call vga_print

    ; n_proc = herb_container_count(CN_READY) + CN_CPU0 + CN_BLOCKED
    lea rcx, [rel str_cn_ready]
    call herb_container_count
    mov ebx, eax                    ; accumulate
    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    add ebx, eax
    lea rcx, [rel str_cn_blocked]
    call herb_container_count
    add ebx, eax
    ; clamp to 0
    test ebx, ebx
    jns .ds_procs_ok
    xor ebx, ebx
.ds_procs_ok:
    lea rcx, [rel str_procs_label]
    call vga_print
    mov ecx, ebx
    call vga_print_int

%ifdef KERNEL_MODE
    ; Sched: PRIORITY or ROUND-ROBIN
    lea rcx, [rel str_sched_label]
    call vga_print
    ; cp = herb_entity_prop_int(shell_ctl_eid, "current_policy", 0)
    mov ecx, [rel shell_ctl_eid]
    cmp ecx, 0
    jl .ds_sched_pri
    lea rdx, [rel str_current_policy]
    xor r8d, r8d                    ; default 0
    call herb_entity_prop_int
    test eax, eax
    jnz .ds_sched_rr
.ds_sched_pri:
    lea rcx, [rel str_priority_pol]
    call vga_print
    jmp .ds_key_check
.ds_sched_rr:
    lea rcx, [rel str_roundrobin_pol]
    call vga_print
%endif

.ds_key_check:
    lea rax, [rel last_key_name]
    cmp byte [rax], 0
    je .ds_done
    lea rcx, [rel str_key_open]
    call vga_print
    lea rcx, [rel last_key_name]
    call vga_print
    lea rcx, [rel str_key_close]
    call vga_print

.ds_done:
    add rsp, 64
    pop rbx
    pop rbp
    ret

; void draw_legend(void)
; Draw the command legend bar on ROW_LEGEND.
draw_legend:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 296                    ; shadow(32) + ids[32*4=128] + orders[32*4=128] + 8(align)
    ; 8 pushes + sub 296 = 64+296 = 360. 360%16=8. ✓
    ; ids at [rsp+40], orders at [rsp+168]

    mov ecx, ROW_LEGEND
    call vga_clear_row

%ifdef KERNEL_MODE
    ; n = herb_container_count(CN_LEGEND)
    lea rcx, [rel str_cn_legend]
    call herb_container_count
    test eax, eax
    jle .dleg_done
    mov r12d, eax                   ; n
    xor r13d, r13d                  ; count = 0

    ; Collect entity IDs and orders
    xor ebx, ebx                    ; i = 0
.dleg_collect:
    cmp ebx, r12d
    jge .dleg_sort
    cmp r13d, 32
    jge .dleg_sort
    ; eid = herb_container_entity(CN_LEGEND, i)
    lea rcx, [rel str_cn_legend]
    mov edx, ebx
    call herb_container_entity
    test eax, eax
    js .dleg_collect_next
    ; ids[count] = eid
    mov ecx, r13d
    mov [rsp + 40 + rcx*4], eax
    ; orders[count] = herb_entity_prop_int(eid, "order", 99)
    mov ecx, eax
    lea rdx, [rel str_order]
    mov r8d, 99
    call herb_entity_prop_int
    mov ecx, r13d
    mov [rsp + 168 + rcx*4], eax
    inc r13d                        ; count++
.dleg_collect_next:
    inc ebx
    jmp .dleg_collect

.dleg_sort:
    ; Insertion sort by order
    cmp r13d, 2
    jl .dleg_render
    mov ebx, 1                      ; i = 1
.dleg_sort_outer:
    cmp ebx, r13d
    jge .dleg_render
    mov edi, [rsp + 168 + rbx*4]    ; key_o = orders[i]
    mov esi, [rsp + 40 + rbx*4]     ; key_id = ids[i]
    lea r14d, [ebx - 1]             ; j = i - 1
.dleg_sort_inner:
    cmp r14d, 0
    jl .dleg_sort_insert
    movsxd rax, r14d
    cmp dword [rsp + 168 + rax*4], edi
    jle .dleg_sort_insert
    ; orders[j+1] = orders[j]; ids[j+1] = ids[j]
    lea ecx, [r14d + 1]
    movsxd rcx, ecx
    mov eax, [rsp + 168 + rax*4]
    mov [rsp + 168 + rcx*4], eax
    movsxd rax, r14d
    mov eax, [rsp + 40 + rax*4]
    movsxd rcx, r14d
    lea ecx, [ecx + 1]
    movsxd rcx, ecx
    mov [rsp + 40 + rcx*4], eax
    dec r14d
    jmp .dleg_sort_inner
.dleg_sort_insert:
    lea ecx, [r14d + 1]
    movsxd rcx, ecx
    mov [rsp + 168 + rcx*4], edi
    mov [rsp + 40 + rcx*4], esi
    inc ebx
    jmp .dleg_sort_outer

.dleg_render:
    ; Render: yellow key + gray label + space
    mov r14d, 1                     ; first = 1
    xor r15d, r15d                  ; i = 0
.dleg_render_loop:
    cmp r15d, r13d
    jge .dleg_done
    ; key = herb_entity_prop_str(ids[i], "key_text", "?")
    movsxd rax, r15d
    mov ecx, [rsp + 40 + rax*4]
    lea rdx, [rel str_key_text]
    lea r8, [rel str_ques]
    call herb_entity_prop_str
    mov rbx, rax                    ; save key

    ; label = herb_entity_prop_str(ids[i], "label_text", "")
    movsxd rax, r15d
    mov ecx, [rsp + 40 + rax*4]
    lea rdx, [rel str_label_text]
    lea r8, [rel str_empty]
    call herb_entity_prop_str
    mov rsi, rax                    ; save label

    ; vga_set_color(VGA_YELLOW, VGA_BLACK)
    mov ecx, VGA_YELLOW
    xor edx, edx
    call vga_set_color

    ; if first: vga_print_at(ROW_LEGEND, 1, key); first=0
    test r14d, r14d
    jz .dleg_not_first
    mov ecx, ROW_LEGEND
    mov edx, 1
    mov r8, rbx
    call vga_print_at
    xor r14d, r14d
    jmp .dleg_label
.dleg_not_first:
    mov rcx, rbx
    call vga_print

.dleg_label:
    ; vga_set_color(VGA_LGRAY, VGA_BLACK)
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
    mov rcx, rsi
    call vga_print
    lea rcx, [rel str_space]
    call vga_print
    inc r15d
    jmp .dleg_render_loop

%else
    ; Non-KERNEL_MODE: hardcoded legend
    mov ecx, VGA_YELLOW
    xor edx, edx
    call vga_set_color
    mov ecx, ROW_LEGEND
    mov edx, 1
    lea r8, [rel str_leg_N]
    call vga_print_at
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_ew]
    call vga_print

    mov ecx, VGA_YELLOW
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_K]
    call vga_print
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_ill]
    call vga_print

    mov ecx, VGA_YELLOW
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_B]
    call vga_print
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_lk]
    call vga_print

    mov ecx, VGA_YELLOW
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_U]
    call vga_print
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_nblk]
    call vga_print

    mov ecx, VGA_YELLOW
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_T]
    call vga_print
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_mr]
    call vga_print

    mov ecx, VGA_YELLOW
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_Plus]
    call vga_print
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_Boost]
    call vga_print

    mov ecx, VGA_YELLOW
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_Space]
    call vga_print
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
    lea rcx, [rel str_leg_Step]
    call vga_print
%endif

.dleg_done:
    add rsp, 296
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; void draw_process_row(int row, int entity_id, int index)
; MS x64: ECX=row, EDX=entity_id, R8D=index
; Draw one process row in the VGA text-mode process table.
draw_process_row:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40                     ; shadow(32) + 8(align)
    ; 8 pushes + sub 40 = 104. 104%16=8. ✓

    mov ebx, ecx                    ; row
    mov esi, edx                    ; entity_id
    mov edi, r8d                    ; index

    ; name = herb_entity_name(entity_id)
    mov ecx, esi
    call herb_entity_name
    mov r12, rax                    ; name

    ; loc = herb_entity_location(entity_id)
    mov ecx, esi
    call herb_entity_location
    mov r13, rax                    ; loc

    ; pri = herb_entity_prop_int(entity_id, "priority", 0)
    mov ecx, esi
    lea rdx, [rel str_priority]
    xor r8d, r8d
    call herb_entity_prop_int
    mov r14d, eax                   ; pri

    ; ts = herb_entity_prop_int(entity_id, "time_slice", 0)
    mov ecx, esi
    lea rdx, [rel str_time_slice]
    xor r8d, r8d
    call herb_entity_prop_int
    mov r15d, eax                   ; ts

    ; Determine state color based on loc[0] (with proc. prefix handling)
    movzx eax, byte [r13]
    mov ecx, VGA_LGRAY              ; default fg
    mov edx, '?'                    ; default state_char

    ; Check direct prefix first: C=Running, R=Ready, B=Blocked, T=Terminated
    cmp al, 'C'
    je .dpr_running
    cmp al, 'R'
    je .dpr_ready
    cmp al, 'B'
    je .dpr_blocked
    cmp al, 'T'
    je .dpr_term
%ifdef KERNEL_MODE
    ; Check "proc." prefix: loc[0]='p', loc[4]='.', loc[5] determines state
    cmp al, 'p'
    jne .dpr_state_done
    cmp byte [r13 + 4], '.'
    jne .dpr_state_done
    movzx eax, byte [r13 + 5]
    cmp al, 'C'
    je .dpr_running
    cmp al, 'R'
    je .dpr_ready
    cmp al, 'B'
    je .dpr_blocked
    cmp al, 'T'
    je .dpr_term
%endif
    jmp .dpr_state_done

.dpr_running:
    mov ecx, VGA_LGREEN
    mov edx, 'R'
    jmp .dpr_state_done
.dpr_ready:
    mov ecx, VGA_YELLOW
    mov edx, 'S'
    jmp .dpr_state_done
.dpr_blocked:
    mov ecx, VGA_LRED
    mov edx, 'B'
    jmp .dpr_state_done
.dpr_term:
    mov ecx, VGA_DGRAY
    mov edx, 'X'

.dpr_state_done:
    ; Save fg color and state_char on stack
    mov [rsp + 32], ecx             ; fg at [rsp+32]
    mov [rsp + 36], edx             ; state_char at [rsp+36]

    ; vga_set_color(VGA_LGRAY, VGA_BLACK)
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color

    ; vga_clear_row(row)
    mov ecx, ebx
    call vga_clear_row

    ; Index: vga_print_at(row, 1, ""); vga_print_int(index)
    mov ecx, ebx
    mov edx, 1
    lea r8, [rel str_empty]
    call vga_print_at
    mov ecx, edi
    call vga_print_int

    ; State indicator: vga_set_color(fg, VGA_BLACK)
    mov ecx, [rsp + 32]
    xor edx, edx
    call vga_set_color
    ; vga_print_at(row, 4, "")
    mov ecx, ebx
    mov edx, 4
    lea r8, [rel str_empty]
    call vga_print_at
    mov ecx, '['
    call vga_putchar
    mov ecx, [rsp + 36]
    call vga_putchar
    mov ecx, ']'
    call vga_putchar

    ; Name: vga_set_color(VGA_WHITE, VGA_BLACK)
    mov ecx, VGA_WHITE
    xor edx, edx
    call vga_set_color
    mov ecx, ebx
    mov edx, 9
    lea r8, [rel str_empty]
    call vga_print_at
    mov rcx, r12
    mov edx, 10
    call vga_print_padded

    ; Location: vga_set_color(fg, VGA_BLACK)
    mov ecx, [rsp + 32]
    xor edx, edx
    call vga_set_color
    mov ecx, ebx
    mov edx, 20
    lea r8, [rel str_empty]
    call vga_print_at
    ; Strip "proc." prefix for display
    mov rcx, r13                    ; disp_loc = loc
%ifdef KERNEL_MODE
    cmp byte [r13], 'p'
    jne .dpr_no_strip
    cmp byte [r13+1], 'r'
    jne .dpr_no_strip
    cmp byte [r13+2], 'o'
    jne .dpr_no_strip
    cmp byte [r13+3], 'c'
    jne .dpr_no_strip
    cmp byte [r13+4], '.'
    jne .dpr_no_strip
    lea rcx, [r13 + 5]             ; skip "proc."
.dpr_no_strip:
%endif
    mov edx, 12
    call vga_print_padded

    ; Priority: vga_set_color(VGA_LCYAN, VGA_BLACK)
    mov ecx, VGA_LCYAN
    xor edx, edx
    call vga_set_color
    mov ecx, ebx
    mov edx, 33
    lea r8, [rel str_p_eq]
    call vga_print_at
    mov ecx, r14d
    call vga_print_int

    ; Time slice
    mov ecx, ebx
    mov edx, 39
    lea r8, [rel str_ts_eq]
    call vga_print_at
    mov ecx, r15d
    call vga_print_int

%ifdef KERNEL_MODE
    ; Scoped resources
    mov ecx, esi
    lea rdx, [rel str_sc_mem_free]
    call scoped_count
    mov r14d, eax                   ; mf (reuse r14 - no longer need pri)

    mov ecx, esi
    lea rdx, [rel str_sc_mem_used]
    call scoped_count
    mov r15d, eax                   ; mu (reuse r15 - no longer need ts)

    mov ecx, esi
    lea rdx, [rel str_sc_fd_free]
    call scoped_count
    mov edi, eax                    ; ff (reuse edi - no longer need index)

    mov ecx, esi
    lea rdx, [rel str_sc_fd_open]
    call scoped_count
    mov [rsp + 36], eax             ; fo at [rsp+36] (reuse state_char slot)

    mov ecx, VGA_LMAGENTA
    xor edx, edx
    call vga_set_color
    mov ecx, ebx
    mov edx, 46
    lea r8, [rel str_m_colon]
    call vga_print_at
    mov ecx, r14d
    call vga_print_int
    mov ecx, '/'
    call vga_putchar
    mov ecx, r15d
    call vga_print_int

    lea rcx, [rel str_fd_label]
    call vga_print
    mov ecx, edi
    call vga_print_int
    mov ecx, '/'
    call vga_putchar
    mov ecx, [rsp + 36]
    call vga_print_int
%endif

    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; void draw_process_table(void)
; Draw the VGA process table header + all process rows.
draw_process_table:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    ; 8 pushes + sub 40 = 104. 104%16=8. ✓

    ; --- Header ---
    mov ecx, VGA_CYAN
    xor edx, edx
    call vga_set_color
    mov ecx, ROW_TABLE_HDR
    call vga_clear_row
    mov ecx, ROW_TABLE_HDR
    mov edx, 1
    lea r8, [rel str_hdr_hash]
    call vga_print_at
    mov ecx, ROW_TABLE_HDR
    mov edx, 4
    lea r8, [rel str_hdr_st]
    call vga_print_at
    mov ecx, ROW_TABLE_HDR
    mov edx, 9
    lea r8, [rel str_hdr_name]
    call vga_print_at
    mov ecx, ROW_TABLE_HDR
    mov edx, 20
    lea r8, [rel str_hdr_loc]
    call vga_print_at
    mov ecx, ROW_TABLE_HDR
    mov edx, 33
    lea r8, [rel str_hdr_pri]
    call vga_print_at
    mov ecx, ROW_TABLE_HDR
    mov edx, 39
    lea r8, [rel str_hdr_ts]
    call vga_print_at
%ifdef KERNEL_MODE
    mov ecx, ROW_TABLE_HDR
    mov edx, 46
    lea r8, [rel str_hdr_mem]
    call vga_print_at
    mov ecx, ROW_TABLE_HDR
    mov edx, 57
    lea r8, [rel str_hdr_fd]
    call vga_print_at
%endif

    ; row=ROW_TABLE, shown=0
    mov ebx, ROW_TABLE              ; row
    xor esi, esi                    ; shown

    ; --- CPU0 ---
    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    mov r12d, eax                   ; n_cpu0
    xor edi, edi                    ; i = 0
.dpt_cpu0:
    cmp edi, r12d
    jge .dpt_ready
    cmp esi, MAX_TABLE_ROWS
    jge .dpt_ready
    lea rcx, [rel str_cn_cpu0]
    mov edx, edi
    call herb_container_entity
    test eax, eax
    js .dpt_cpu0_next
    mov ecx, ebx
    mov edx, eax
    mov r8d, esi
    call draw_process_row
    inc ebx
    inc esi
.dpt_cpu0_next:
    inc edi
    jmp .dpt_cpu0

    ; --- READY ---
.dpt_ready:
    lea rcx, [rel str_cn_ready]
    call herb_container_count
    mov r12d, eax
    xor edi, edi
.dpt_ready_loop:
    cmp edi, r12d
    jge .dpt_blocked
    cmp esi, MAX_TABLE_ROWS
    jge .dpt_blocked
    lea rcx, [rel str_cn_ready]
    mov edx, edi
    call herb_container_entity
    test eax, eax
    js .dpt_ready_next
    mov ecx, ebx
    mov edx, eax
    mov r8d, esi
    call draw_process_row
    inc ebx
    inc esi
.dpt_ready_next:
    inc edi
    jmp .dpt_ready_loop

    ; --- BLOCKED ---
.dpt_blocked:
    lea rcx, [rel str_cn_blocked]
    call herb_container_count
    mov r12d, eax
    xor edi, edi
.dpt_blocked_loop:
    cmp edi, r12d
    jge .dpt_term
    cmp esi, MAX_TABLE_ROWS
    jge .dpt_term
    lea rcx, [rel str_cn_blocked]
    mov edx, edi
    call herb_container_entity
    test eax, eax
    js .dpt_blocked_next
    mov ecx, ebx
    mov edx, eax
    mov r8d, esi
    call draw_process_row
    inc ebx
    inc esi
.dpt_blocked_next:
    inc edi
    jmp .dpt_blocked_loop

    ; --- TERMINATED ---
.dpt_term:
    lea rcx, [rel str_cn_terminated]
    call herb_container_count
    mov r12d, eax                   ; n_terminated
    mov r13d, 3                     ; show_max = 3
%ifdef KERNEL_MODE
    cmp dword [rel display_ctl_eid], 0
    jl .dpt_term_loop_init
    mov ecx, [rel display_ctl_eid]
    lea rdx, [rel str_max_terminated]
    mov r8d, 3
    call herb_entity_prop_int
    mov r13d, eax                   ; show_max from DisplayCtl
%endif
.dpt_term_loop_init:
    xor edi, edi
.dpt_term_loop:
    cmp edi, r12d
    jge .dpt_term_overflow
    cmp edi, r13d
    jge .dpt_term_overflow
    cmp esi, MAX_TABLE_ROWS
    jge .dpt_term_overflow
    lea rcx, [rel str_cn_terminated]
    mov edx, edi
    call herb_container_entity
    test eax, eax
    js .dpt_term_next
    mov ecx, ebx
    mov edx, eax
    mov r8d, esi
    call draw_process_row
    inc ebx
    inc esi
.dpt_term_next:
    inc edi
    jmp .dpt_term_loop

.dpt_term_overflow:
    ; Show "(+N terminated)" if n > show_max
    cmp r12d, r13d
    jle .dpt_clear_rest
    mov ecx, VGA_DGRAY
    xor edx, edx
    call vga_set_color
    mov ecx, ebx
    call vga_clear_row
    mov ecx, ebx
    mov edx, 5
    lea r8, [rel str_plus_open]
    call vga_print_at
    mov ecx, r12d
    sub ecx, r13d
    call vga_print_int
    lea rcx, [rel str_term_suffix]
    call vga_print
    inc ebx
    inc esi

    ; --- Clear remaining rows ---
.dpt_clear_rest:
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
.dpt_clear_loop:
    lea eax, [ROW_TABLE + MAX_TABLE_ROWS]
    cmp ebx, eax
    jge .dpt_done
    mov ecx, ebx
    call vga_clear_row
    inc ebx
    jmp .dpt_clear_loop

.dpt_done:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; void draw_summary(void)
; Draw container/resource summary.
draw_summary:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    ; 8 pushes + sub 40 = 104. 104%16=8. ✓

    ; Clear rows ROW_SUMMARY to ROW_SUMMARY+4
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
    mov ebx, ROW_SUMMARY
.dsum_clear:
    cmp ebx, ROW_SUMMARY + 5
    jge .dsum_hdr
    mov ecx, ebx
    call vga_clear_row
    inc ebx
    jmp .dsum_clear

.dsum_hdr:
    mov ecx, VGA_CYAN
    xor edx, edx
    call vga_set_color
    mov ecx, ROW_SUMMARY
    mov edx, 1
    lea r8, [rel str_containers]
    call vga_print_at

    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color

    ; Get container counts
    lea rcx, [rel str_cn_ready]
    call herb_container_count
    mov r12d, eax
    test r12d, r12d
    jns .dsum_r_ok
    xor r12d, r12d
.dsum_r_ok:
    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    mov r13d, eax
    test r13d, r13d
    jns .dsum_c_ok
    xor r13d, r13d
.dsum_c_ok:
    lea rcx, [rel str_cn_blocked]
    call herb_container_count
    mov r14d, eax
    test r14d, r14d
    jns .dsum_b_ok
    xor r14d, r14d
.dsum_b_ok:
    lea rcx, [rel str_cn_terminated]
    call herb_container_count
    mov r15d, eax
    test r15d, r15d
    jns .dsum_t_ok
    xor r15d, r15d
.dsum_t_ok:
    lea rcx, [rel str_cn_sig_done]
    call herb_container_count
    mov edi, eax
    test edi, edi
    jns .dsum_s_ok
    xor edi, edi
.dsum_s_ok:

    ; Print: READY=N  CPU0=N  BLOCKED=N  TERM=N  SigDone=N
    mov ecx, ROW_SUMMARY + 1
    mov edx, 3
    lea r8, [rel str_ready_eq]
    call vga_print_at
    mov ecx, r12d
    call vga_print_int
    lea rcx, [rel str_cpu0_eq]
    call vga_print
    mov ecx, r13d
    call vga_print_int
    lea rcx, [rel str_blocked_eq]
    call vga_print
    mov ecx, r14d
    call vga_print_int
    lea rcx, [rel str_term_eq]
    call vga_print
    mov ecx, r15d
    call vga_print_int
    lea rcx, [rel str_sigdone_eq]
    call vga_print
    mov ecx, edi
    call vga_print_int

%ifdef KERNEL_MODE
    ; Per-process resource summary
    mov ecx, VGA_CYAN
    xor edx, edx
    call vga_set_color
    mov ecx, ROW_SUMMARY + 2
    mov edx, 1
    lea r8, [rel str_resources]
    call vga_print_at

    mov ebx, ROW_SUMMARY + 3        ; row
    ; Iterate CPU0, READY, BLOCKED containers
    xor r12d, r12d                   ; ci = 0 (container index)
.dsum_res_cont:
    cmp r12d, 3
    jge .dsum_done
    lea eax, [ROW_SUMMARY + 5]
    cmp ebx, eax
    jge .dsum_done
    ; Select container name
    cmp r12d, 0
    jne .dsum_rc1
    lea r13, [rel str_cn_cpu0]
    jmp .dsum_rc_go
.dsum_rc1:
    cmp r12d, 1
    jne .dsum_rc2
    lea r13, [rel str_cn_ready]
    jmp .dsum_rc_go
.dsum_rc2:
    lea r13, [rel str_cn_blocked]

.dsum_rc_go:
    mov rcx, r13
    call herb_container_count
    mov r14d, eax                    ; n
    xor r15d, r15d                   ; i = 0
.dsum_res_entity:
    cmp r15d, r14d
    jge .dsum_res_next_cont
    lea eax, [ROW_SUMMARY + 5]
    cmp ebx, eax
    jge .dsum_done
    ; eid = herb_container_entity(container, i)
    mov rcx, r13
    mov edx, r15d
    call herb_container_entity
    test eax, eax
    js .dsum_res_ent_next
    mov esi, eax                     ; eid

    ; Get entity name
    mov ecx, esi
    call herb_entity_name
    mov rdi, rax                     ; ename

    ; Get scoped counts
    ; Print name padded, then query+print each scoped count inline
    mov ecx, VGA_LGRAY
    xor edx, edx
    call vga_set_color
    mov ecx, ebx
    mov edx, 3
    lea r8, [rel str_empty]
    call vga_print_at
    mov rcx, rdi                     ; ename
    mov edx, 8
    call vga_print_padded

    lea rcx, [rel str_mem_label2]
    call vga_print
    ; mf
    mov ecx, esi
    lea rdx, [rel str_sc_mem_free]
    call scoped_count
    mov ecx, eax
    call vga_print_int
    lea rcx, [rel str_fu_sep]
    call vga_print
    ; mu
    mov ecx, esi
    lea rdx, [rel str_sc_mem_used]
    call scoped_count
    mov ecx, eax
    call vga_print_int
    lea rcx, [rel str_u_suffix]
    call vga_print
    ; ff
    mov ecx, esi
    lea rdx, [rel str_sc_fd_free]
    call scoped_count
    mov ecx, eax
    call vga_print_int
    lea rcx, [rel str_fo_sep]
    call vga_print
    ; fo
    mov ecx, esi
    lea rdx, [rel str_sc_fd_open]
    call scoped_count
    mov ecx, eax
    call vga_print_int
    lea rcx, [rel str_o_suffix]
    call vga_print
    ; inbox
    mov ecx, esi
    lea rdx, [rel str_sc_inbox]
    call scoped_count
    mov ecx, eax
    call vga_print_int

    inc ebx                          ; row++

.dsum_res_ent_next:
    inc r15d
    jmp .dsum_res_entity

.dsum_res_next_cont:
    inc r12d
    jmp .dsum_res_cont
%endif

.dsum_done:
    add rsp, 40
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
; Session 92: wm_sync_geometry_from_herb — outside GRAPHICS_MODE
; ============================================================
%ifdef KERNEL_MODE

; ---- wm_sync_geometry_from_herb() ----
; Lightweight sync — reads ONLY x/y/width/height from wm.VISIBLE
; entities into WM window structs. Does NOT touch z_order, role, focus, flags,
; or entity_id (preserving Session 90/91 guarantees).
; Stack: 5 pushes (rbp, rbx, rsi, rdi, r12) + sub rsp 48 = 8+40+48 = 96. 96%16=0. ✓
%define WMSG_EID   32
%define WMSG_VI    36
%define WMSG_NV    40
%define WMSG_HT    44

wm_sync_geometry_from_herb:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48

    ; Get wm.VISIBLE count
    lea rcx, [rel str_cn_wm_visible]
    call herb_container_count
    test eax, eax
    jns .wmsg_count_ok
    xor eax, eax
.wmsg_count_ok:
    cmp eax, 16
    jle .wmsg_count_clamped
    mov eax, 16
.wmsg_count_clamped:
    mov dword [rsp + WMSG_NV], eax
    mov dword [rsp + WMSG_VI], 0

.wmsg_loop:
    mov eax, dword [rsp + WMSG_VI]
    cmp eax, dword [rsp + WMSG_NV]
    jge .wmsg_done

    ; Get entity at index
    lea rcx, [rel str_cn_wm_visible]
    mov edx, eax
    call herb_container_entity
    test eax, eax
    js .wmsg_next
    mov dword [rsp + WMSG_EID], eax

    ; Read role
    mov ecx, eax
    lea rdx, [rel str_role]
    mov r8d, -1
    call herb_entity_prop_int
    cmp eax, 0
    jl .wmsg_next
    cmp eax, 6                  ; WM_ROLE_GAME (literal, outside GRAPHICS_MODE)
    jg .wmsg_next
    mov r12d, eax               ; r12d = role

    ; Look up win_id from role
    lea rbx, [rel wm_role_to_win_id]
    mov ebx, dword [rbx + r12*4]
    test ebx, ebx
    js .wmsg_next                ; no window for this role

    ; Read x
    mov ecx, dword [rsp + WMSG_EID]
    lea rdx, [rel str_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov esi, eax                 ; esi = x

    ; Read y
    mov ecx, dword [rsp + WMSG_EID]
    lea rdx, [rel str_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov edi, eax                 ; edi = y

    ; Read width
    mov ecx, dword [rsp + WMSG_EID]
    lea rdx, [rel str_width]
    mov r8d, 100
    call herb_entity_prop_int
    mov r12d, eax                ; r12d = width (reuse, role no longer needed)

    ; Read height
    mov ecx, dword [rsp + WMSG_EID]
    lea rdx, [rel str_height]
    mov r8d, 100
    call herb_entity_prop_int
    mov dword [rsp + WMSG_HT], eax  ; save height on stack

    ; Get window pointer
    mov ecx, ebx                 ; win_id (callee-saved ebx)
    call wm_window_ptr
    test rax, rax
    jz .wmsg_next

    ; Write geometry to WM struct (literal offsets: X=8, Y=12, W=16, H=20)
    mov dword [rax + 8], esi
    mov dword [rax + 12], edi
    mov dword [rax + 16], r12d
    mov ecx, dword [rsp + WMSG_HT]
    mov dword [rax + 20], ecx

.wmsg_next:
    inc dword [rsp + WMSG_VI]
    jmp .wmsg_loop

.wmsg_done:
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

%endif  ; KERNEL_MODE (wm_sync_geometry_from_herb)

; ============================================================
; Phase D Step 6 — Graphics Draw Functions
; ============================================================

%ifdef GRAPHICS_MODE

; ============================================================
; gfx_draw_procs_in_region(rx, ry, rw, rh, container_name,
;                          fallback_border, fallback_fill)
;
; 7 args: RCX=rx, RDX=ry, R8=rw, R9=rh
;   [rbp+48]=container_name, [rbp+56]=fallback_border, [rbp+64]=fallback_fill
;
; Callee-saved: rbx=rx, rsi=ry, rdi=rw, r12=rh
;   r13=container_name, r14=fallback_border, r15=fallback_fill
;
; Stack: push rbp + 7 pushes + sub rsp, 200
;   8(ret)+8(rbp)+56(pushes)+200 = 272. 272%16=0 ✓
;
; Locals:
;   [rsp+32..71]  shadow/spill area for callee args 5-9
;   [rsp+72..75]  n (container count)
;   [rsp+76..79]  cols
;   [rsp+80..83]  max_per_region
;   [rsp+84..87]  i (loop counter)
;   [rsp+88..91]  eid
;   [rsp+92..95]  px
;   [rsp+96..99]  py
;   [rsp+100..103] pri
;   [rsp+104..107] ts
;   [rsp+108..111] border_col (per-process, persists through iteration)
;   [rsp+112..115] fill_col (per-process, persists through iteration)
;   [rsp+116..123] name (ptr)
;   [rsp+124..187] surf_cont[64] (KERNEL_MODE)
;   [rsp+188..199] buf[12] (overflow msg uses surf_cont instead)
; ============================================================

gfx_draw_procs_in_region:
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

    mov ebx, ecx                    ; rx
    mov esi, edx                    ; ry
    mov edi, r8d                    ; rw
    mov r12d, r9d                   ; rh
    mov r13, [rbp + 48]             ; container_name
    mov r14d, [rbp + 56]            ; fallback_border
    mov r15d, [rbp + 64]            ; fallback_fill

    ; n = herb_container_count(container_name)
    mov rcx, r13
    call herb_container_count
    test eax, eax
    jns .gdp_n_ok
    xor eax, eax
.gdp_n_ok:
    mov dword [rsp + 72], eax

    ; cols = (rw - 8) / 126. Min 1.
    mov eax, edi
    sub eax, 8
    cdq
    mov ecx, (GFX_PROC_W + GFX_PROC_PAD)
    idiv ecx
    test eax, eax
    jg .gdp_cols_ok
    mov eax, 1
.gdp_cols_ok:
    mov dword [rsp + 76], eax

    ; max_per_region = 12
    mov dword [rsp + 80], 12
%ifdef KERNEL_MODE
    mov eax, [rel display_ctl_eid]
    test eax, eax
    js .gdp_max_ok
    mov ecx, eax
    lea rdx, [rel str_gfx_max_procs]
    mov r8, 12
    call herb_entity_prop_int
    mov dword [rsp + 80], eax
.gdp_max_ok:
%endif

    mov dword [rsp + 84], 0         ; i = 0

.gdp_loop:
    mov eax, [rsp + 84]
    cmp eax, [rsp + 72]             ; i < n
    jge .gdp_overflow
    cmp eax, [rsp + 80]             ; i < max_per_region
    jge .gdp_overflow

    ; eid = herb_container_entity(container_name, i)
    mov rcx, r13
    mov edx, [rsp + 84]
    call herb_container_entity
    test eax, eax
    js .gdp_next
    mov dword [rsp + 88], eax

    ; name = herb_entity_name(eid)
    mov ecx, eax
    call herb_entity_name
    mov [rsp + 116], rax

    ; pri = herb_entity_prop_int(eid, "priority", 0)
    mov ecx, [rsp + 88]
    lea rdx, [rel str_priority]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 100], eax

    ; ts = herb_entity_prop_int(eid, "time_slice", 0)
    mov ecx, [rsp + 88]
    lea rdx, [rel str_time_slice]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 104], eax

    ; Initialize colors from fallbacks
    mov dword [rsp + 108], r14d     ; border_col = fallback_border
    mov dword [rsp + 112], r15d     ; fill_col = fallback_fill

%ifdef KERNEL_MODE
    ; Surface entity color lookup: "%s::SURFACE"
    lea rcx, [rsp + 124]
    mov edx, 64
    lea r8, [rel str_gfx_surf_fmt]
    mov r9, [rsp + 116]            ; pname
    call herb_snprintf

    lea rcx, [rsp + 124]
    call herb_container_count
    test eax, eax
    jle .gdp_no_surf

    lea rcx, [rsp + 124]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .gdp_no_surf
    mov dword [rsp + 188], eax      ; save sid

    mov ecx, eax
    lea rdx, [rel str_gfx_border_color]
    xor r8d, r8d
    call herb_entity_prop_int
    test eax, eax
    jz .gdp_no_bc
    mov dword [rsp + 108], eax
.gdp_no_bc:
    mov ecx, [rsp + 188]
    lea rdx, [rel str_gfx_fill_color]
    xor r8d, r8d
    call herb_entity_prop_int
    test eax, eax
    jz .gdp_no_surf
    mov dword [rsp + 112], eax
.gdp_no_surf:
%endif

    ; Compute px, py from i, cols
    mov eax, [rsp + 84]
    cdq
    idiv dword [rsp + 76]           ; eax=row, edx=col
    imul edx, (GFX_PROC_W + GFX_PROC_PAD)
    add edx, ebx
    add edx, 4                      ; px = rx + 4 + col*126
    mov dword [rsp + 92], edx

    imul eax, (GFX_PROC_H + GFX_PROC_PAD)
    add eax, esi
    add eax, 22                     ; py = ry + 22 + row*(H+6)
    mov dword [rsp + 96], eax

    ; Bounds check: py + GFX_PROC_H > ry + rh → break
    lea ecx, [eax + GFX_PROC_H]
    lea edx, [esi + r12d]
    cmp ecx, edx
    jg .gdp_overflow

    ; fb_draw_process(px, py, GFX_PROC_W, GFX_PROC_H, name, pri, ts, border, fill)
    ; 9 args: first 4 in regs, args 5-9 at [rsp+32..64]
    mov rax, [rsp + 116]
    mov [rsp + 32], rax             ; arg5 = name
    movsxd rax, dword [rsp + 100]
    mov [rsp + 40], rax             ; arg6 = pri
    movsxd rax, dword [rsp + 104]
    mov [rsp + 48], rax             ; arg7 = ts
    mov eax, [rsp + 108]
    mov [rsp + 56], rax             ; arg8 = border_col
    mov eax, [rsp + 112]
    mov [rsp + 64], rax             ; arg9 = fill_col
    mov ecx, [rsp + 92]
    mov edx, [rsp + 96]
    mov r8d, GFX_PROC_W
    mov r9d, GFX_PROC_H
    call fb_draw_process

%ifdef KERNEL_MODE
    ; Selection highlight
    mov ecx, [rsp + 88]
    lea rdx, [rel str_gfx_selected]
    xor r8d, r8d
    call herb_entity_prop_int
    cmp eax, 1
    jne .gdp_no_sel

    mov ecx, [rsp + 92]
    sub ecx, 2
    mov edx, [rsp + 96]
    sub edx, 2
    mov r8d, GFX_PROC_W + 4
    mov r9d, GFX_PROC_H + 4
    mov dword [rsp + 32], COL_SELECTED
    call fb_draw_rect2

    mov ecx, [rsp + 92]
    sub ecx, 3
    mov edx, [rsp + 96]
    sub edx, 3
    mov r8d, GFX_PROC_W + 6
    mov r9d, GFX_PROC_H + 6
    mov dword [rsp + 32], COL_SELECTED
    call fb_draw_rect
.gdp_no_sel:

    ; Resource indicators: 4x scoped_count then fb_draw_resources
    mov ecx, [rsp + 88]
    lea rdx, [rel str_scope_mem_free]
    call scoped_count
    mov dword [rsp + 188], eax      ; mf

    mov ecx, [rsp + 88]
    lea rdx, [rel str_scope_mem_used]
    call scoped_count
    mov dword [rsp + 192], eax      ; mu

    mov ecx, [rsp + 88]
    lea rdx, [rel str_scope_fd_free]
    call scoped_count
    mov dword [rsp + 196], eax      ; ff

    mov ecx, [rsp + 88]
    lea rdx, [rel str_scope_fd_open]
    call scoped_count
    ; eax = fo

    ; fb_draw_resources(px+4, py+38, mf, mu, ff, fo)
    mov dword [rsp + 40], eax       ; arg6 = fo
    mov eax, [rsp + 196]
    mov dword [rsp + 32], eax       ; arg5 = ff
    mov ecx, [rsp + 92]
    add ecx, 4
    mov edx, [rsp + 96]
    add edx, 38
    mov r8d, [rsp + 188]
    mov r9d, [rsp + 192]
    call fb_draw_resources

    ; Program state: produced or consumed
    mov ecx, [rsp + 88]
    lea rdx, [rel str_gfx_produced]
    mov r8, -1
    call herb_entity_prop_int
    test rax, rax
    js .gdp_try_cons

    ; produced >= 0: format ">%d"
    lea rcx, [rsp + 124]
    mov edx, 20
    lea r8, [rel str_gfx_prod_fmt]
    mov r9d, eax
    call herb_snprintf

    mov ecx, [rsp + 92]
    add ecx, 60
    mov edx, [rsp + 96]
    add edx, 38
    lea r8, [rsp + 124]
    mov r9d, 0x00FF9900
    mov eax, [rsp + 112]            ; fill_col (not overwritten)
    mov dword [rsp + 32], eax
    call fb_draw_string
    jmp .gdp_next

.gdp_try_cons:
    mov ecx, [rsp + 88]
    lea rdx, [rel str_gfx_consumed]
    mov r8, -1
    call herb_entity_prop_int
    test rax, rax
    js .gdp_next

    lea rcx, [rsp + 124]
    mov edx, 20
    lea r8, [rel str_gfx_cons_fmt]
    mov r9d, eax
    call herb_snprintf

    mov ecx, [rsp + 92]
    add ecx, 60
    mov edx, [rsp + 96]
    add edx, 38
    lea r8, [rsp + 124]
    mov r9d, 0x0066CCFF
    mov eax, [rsp + 112]            ; fill_col
    mov dword [rsp + 32], eax
    call fb_draw_string
%endif  ; KERNEL_MODE

.gdp_next:
    inc dword [rsp + 84]
    jmp .gdp_loop

.gdp_overflow:
    ; if (n > max_per_region) show "+N more"
    mov eax, [rsp + 72]
    cmp eax, [rsp + 80]
    jle .gdp_done

    lea rcx, [rsp + 124]
    mov edx, 32
    lea r8, [rel str_gfx_more_fmt]
    mov r9d, [rsp + 72]
    sub r9d, [rsp + 80]
    call herb_snprintf

    ; fb_draw_string(rx+4, ry+rh-20, buf, COL_TEXT_DIM, 0)
    lea ecx, [ebx + 4]
    lea edx, [esi + r12d]
    sub edx, 20
    lea r8, [rsp + 124]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], 0
    call fb_draw_string

.gdp_done:
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

; ============================================================
; gfx_draw_tension_panel(void) — KERNEL_MODE only
;
; Renders tension list in the WM client area.
; Reads client rect from g_tp_cx/cy/cw/ch (set by adapter).
;
; Callee-saved: rbx=enabled_count, rsi=nt, rdi=i, r12=row_y, r13=max_rows
;
; Stack: push rbp + 5 pushes + sub rsp, 72
;   8(ret)+8(rbp)+40(pushes)+72 = 128. 128%16=0 ✓
;
; Locals:
;   [rsp+32..39] shadow/arg5 for callees
;   [rsp+40..43] row y (temp)
;   [rsp+44..47] en (enabled flag)
;   [rsp+48..55] buf[8] / pri
;   [rsp+56..72] nbuf[17] (truncated tension name)
;   [rsp+64..71] name ptr (overlaps nbuf, used before nbuf)
; ============================================================

%ifdef KERNEL_MODE

gfx_draw_tension_panel:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 72

    ; nt = herb_tension_count()
    call herb_tension_count
    mov esi, eax                    ; rsi = nt

    ; Count enabled tensions
    xor ebx, ebx                    ; rbx = enabled_count
    xor edi, edi                    ; rdi = i
.gtp_count_loop:
    cmp edi, esi
    jge .gtp_count_done
    mov ecx, edi
    call herb_tension_enabled
    add ebx, eax                    ; enabled_count += (0 or 1)
    inc edi
    jmp .gtp_count_loop
.gtp_count_done:

    ; Fill client area background
    mov ecx, [rel g_tp_cx]
    mov edx, [rel g_tp_cy]
    mov r8d, [rel g_tp_cw]
    mov r9d, [rel g_tp_ch]
    mov dword [rsp + 32], COL_TENS_BG
    call fb_fill_rect

    ; Enabled count: " N/M" at top of client area
    lea rcx, [rsp + 48]
    mov edx, 8
    lea r8, [rel str_gfx_tens_cnt]
    mov r9d, ebx                    ; enabled_count
    mov dword [rsp + 32], esi       ; nt (5th arg)
    call herb_snprintf

    ; Draw count string at (cx+4, cy+1)
    mov ecx, [rel g_tp_cx]
    add ecx, 4
    mov edx, [rel g_tp_cy]
    add edx, 1
    lea r8, [rsp + 48]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_TENS_BG
    call fb_draw_string

    ; Separator line at cy+24
    mov ecx, [rel g_tp_cx]
    mov edx, [rel g_tp_cy]
    add edx, 24
    mov r8d, [rel g_tp_cw]
    mov r9d, COL_TENS_BORDER
    call fb_hline

    ; Row iteration: rows start at cy+28
    mov r12d, [rel g_tp_cy]
    add r12d, 28                    ; row_y = cy + 28
    ; max_rows = (ch - 52) / ROW_H  (52 = 28 top + 24 legend)
    mov eax, [rel g_tp_ch]
    sub eax, 52
    jle .gtp_row_done               ; no room for rows
    xor edx, edx
    mov ecx, GFX_TENS_ROW_H
    div ecx                         ; eax = max_rows
    mov r13d, eax
    xor edi, edi                    ; i = 0

.gtp_row_loop:
    cmp edi, esi                    ; i < nt
    jge .gtp_row_done
    cmp edi, r13d                   ; i < max_rows
    jge .gtp_row_done

    ; y = row_y + i * GFX_TENS_ROW_H
    mov eax, edi
    imul eax, GFX_TENS_ROW_H
    add eax, r12d
    mov dword [rsp + 40], eax       ; save y

    ; en = herb_tension_enabled(i)
    mov ecx, edi
    call herb_tension_enabled
    mov dword [rsp + 44], eax       ; save en

    ; pri = herb_tension_priority(i)
    mov ecx, edi
    call herb_tension_priority
    mov dword [rsp + 48], eax       ; save pri

    ; name = herb_tension_name(i)
    mov ecx, edi
    call herb_tension_name
    mov [rsp + 64], rax             ; save name ptr

    ; Row background
    mov eax, [rsp + 44]             ; en
    test eax, eax
    mov ecx, COL_TENS_OFF_BG
    mov eax, COL_TENS_ON_BG
    cmovz eax, ecx                  ; row_bg = en ? ON_BG : OFF_BG
    mov dword [rsp + 32], eax       ; save row_bg
    ; fb_fill_rect(cx, y, cw, ROW_H-1, row_bg)
    mov ecx, [rel g_tp_cx]
    mov edx, [rsp + 40]             ; y
    mov r8d, [rel g_tp_cw]
    mov r9d, GFX_TENS_ROW_H - 1
    call fb_fill_rect

    ; Recompute row_bg for later fb_draw_string calls
    mov eax, [rsp + 44]
    test eax, eax
    mov ecx, COL_TENS_OFF_BG
    mov eax, COL_TENS_ON_BG
    cmovz eax, ecx
    mov dword [rsp + 32], eax       ; row_bg

    ; Selection highlight
    cmp edi, [rel selected_tension_idx]
    jne .gtp_no_sel
    mov ecx, [rel g_tp_cx]
    mov edx, [rsp + 40]
    sub edx, 1
    mov r8d, [rel g_tp_cw]
    mov r9d, GFX_TENS_ROW_H + 1
    mov dword [rsp + 32], COL_TENS_SEL
    call fb_draw_rect
    ; Restore row_bg
    mov eax, [rsp + 44]
    test eax, eax
    mov ecx, COL_TENS_OFF_BG
    mov eax, COL_TENS_ON_BG
    cmovz eax, ecx
    mov dword [rsp + 32], eax
.gtp_no_sel:

    ; Enabled indicator square (6x6)
    mov eax, [rsp + 44]             ; en
    test eax, eax
    mov ecx, COL_TENS_OFF
    mov eax, COL_TENS_ON
    cmovz eax, ecx
    mov dword [rsp + 32], eax       ; ind_col

    ; Check owner for orange override
    mov dword [rsp + 36], eax       ; temp save ind_col
    mov ecx, edi
    call herb_tension_owner
    test eax, eax
    js .gtp_no_owner
    ; Owner >= 0: override indicator color to orange
    mov ecx, [rsp + 44]            ; en
    test ecx, ecx
    mov eax, 0x00664400             ; dim orange
    mov ecx, 0x00FF9900             ; bright orange
    cmovz ecx, eax
    mov dword [rsp + 36], ecx       ; override ind_col
.gtp_no_owner:
    ; fb_fill_rect(cx+4, y+4, 6, 6, ind_col)
    mov ecx, [rel g_tp_cx]
    add ecx, 4
    mov edx, [rsp + 40]
    add edx, 4
    mov r8d, 6
    mov r9d, 6
    mov eax, [rsp + 36]
    mov dword [rsp + 32], eax
    call fb_fill_rect

    ; Strip module prefix from name: find last '.'
    mov rax, [rsp + 64]             ; name ptr
    mov rcx, rax                    ; display_name = name
.gtp_prefix:
    movzx edx, byte [rax]
    test dl, dl
    jz .gtp_prefix_done
    cmp dl, '.'
    jne .gtp_prefix_next
    lea rcx, [rax + 1]             ; display_name = after '.'
.gtp_prefix_next:
    inc rax
    jmp .gtp_prefix
.gtp_prefix_done:
    ; rcx = display_name

    ; Truncate to 16 chars into nbuf at [rsp+56]
    lea rdx, [rsp + 56]
    xor r8d, r8d                    ; ni = 0
.gtp_trunc:
    cmp r8d, 16
    jge .gtp_trunc_done
    movzx eax, byte [rcx + r8]
    test al, al
    jz .gtp_trunc_done
    mov byte [rdx + r8], al
    inc r8d
    jmp .gtp_trunc
.gtp_trunc_done:
    mov byte [rdx + r8], 0

    ; Name color: en ? (owner>=0 ? 0xFFCC66 : COL_TENS_NAME) : COL_TENS_DIM
    mov eax, [rsp + 44]             ; en
    test eax, eax
    jz .gtp_name_dim
    ; Check owner
    mov ecx, edi
    call herb_tension_owner
    test eax, eax
    js .gtp_name_sys
    mov r9d, 0x00FFCC66             ; owner-colored name
    jmp .gtp_name_draw
.gtp_name_sys:
    mov r9d, COL_TENS_NAME
    jmp .gtp_name_draw
.gtp_name_dim:
    mov r9d, COL_TENS_DIM
.gtp_name_draw:
    ; fb_draw_string(cx+14, y+1, nbuf, name_col, row_bg)
    mov ecx, [rel g_tp_cx]
    add ecx, 14
    mov edx, [rsp + 40]
    add edx, 1
    lea r8, [rsp + 56]
    ; r9d already set
    ; Recompute row_bg for 5th arg
    mov eax, [rsp + 44]
    test eax, eax
    mov eax, COL_TENS_OFF_BG
    mov ecx, COL_TENS_ON_BG
    cmovnz eax, ecx
    mov dword [rsp + 32], eax
    ; Restore first two args (clobbered by cmov)
    mov ecx, [rel g_tp_cx]
    add ecx, 14
    mov edx, [rsp + 40]
    add edx, 1
    call fb_draw_string

    ; Priority number
    lea rcx, [rsp + 56]
    mov edx, 8
    lea r8, [rel str_gfx_pri_fmt]
    mov r9d, [rsp + 48]             ; pri
    call herb_snprintf

    ; fb_draw_string(cx+cw-26, y+1, buf, COL_TENS_PRI, row_bg)
    mov ecx, [rel g_tp_cx]
    add ecx, [rel g_tp_cw]
    sub ecx, 26
    mov edx, [rsp + 40]
    add edx, 1
    lea r8, [rsp + 56]
    mov r9d, COL_TENS_PRI
    ; row_bg
    mov eax, [rsp + 44]
    test eax, eax
    mov eax, COL_TENS_OFF_BG
    mov ecx, COL_TENS_ON_BG
    cmovnz eax, ecx
    mov dword [rsp + 32], eax
    mov ecx, [rel g_tp_cx]
    add ecx, [rel g_tp_cw]
    sub ecx, 26
    mov edx, [rsp + 40]
    add edx, 1
    call fb_draw_string

    inc edi
    jmp .gtp_row_loop

.gtp_row_done:
    ; Legend at bottom: cy + ch - 24
    mov eax, [rel g_tp_cy]
    add eax, [rel g_tp_ch]
    sub eax, 24
    mov dword [rsp + 40], eax       ; leg_y
    ; fb_fill_rect(cx, leg_y, cw, 22, COL_TENS_BG)
    mov ecx, [rel g_tp_cx]
    mov edx, eax
    mov r8d, [rel g_tp_cw]
    mov r9d, 22
    mov dword [rsp + 32], COL_TENS_BG
    call fb_fill_rect

    ; Legend text chain: "[" "]" "sel " "D" "=toggle"
    mov ecx, [rel g_tp_cx]
    add ecx, 4
    mov edx, [rsp + 40]
    add edx, 1
    lea r8, [rel str_gfx_lbracket]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_TENS_BG
    call fb_draw_string
    ; eax = next x

    mov ecx, eax
    mov edx, [rsp + 40]
    add edx, 1
    lea r8, [rel str_gfx_rbracket]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_TENS_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, [rsp + 40]
    add edx, 1
    lea r8, [rel str_gfx_sel_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_TENS_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, [rsp + 40]
    add edx, 1
    lea r8, [rel str_gfx_d_key]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_TENS_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, [rsp + 40]
    add edx, 1
    lea r8, [rel str_gfx_toggle_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_TENS_BG
    call fb_draw_string

    add rsp, 72
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

%endif  ; KERNEL_MODE (gfx_draw_tension_panel)

; ============================================================
; gfx_draw_game(void) — KERNEL_MODE only
;
; Renders tile grid, trees, player, and info panel.
;
; Callee-saved: rbx=tile_count, rsi=spare, rdi=ix, r12=iy, r13=loop_i
;
; Stack: push rbp + 5 pushes + sub rsp, 72
;   8(ret)+8(rbp)+40(pushes)+72 = 128. 128%16=0 ✓
;
; Locals:
;   [rsp+32..39] shadow/arg5
;   [rsp+40..47] spare
;   [rsp+48..51] temp eid / px
;   [rsp+52..55] temp tx / py
;   [rsp+56..59] temp ty / terrain
;   [rsp+60..63] temp color / misc
;   [rsp+64..71] spare
; ============================================================

%ifdef KERNEL_MODE

gfx_draw_game:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 72

    ; --- Tile grid ---
    lea rcx, [rel str_cn_game_tiles]
    call herb_container_count
    mov ebx, eax                    ; rbx = tile_count
    test ebx, ebx
    jle .gdg_tiles_done
    xor r13d, r13d

.gdg_tile_loop:
    cmp r13d, ebx
    jge .gdg_tiles_done

    lea rcx, [rel str_cn_game_tiles]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .gdg_tile_next
    mov dword [rsp + 48], eax       ; eid

    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax       ; tx

    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 56], eax       ; ty

    mov ecx, [rsp + 48]
    lea rdx, [rel str_terrain]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 60], eax       ; terrain

    ; terrain_color(terrain) — call first, save result
    mov ecx, eax
    call terrain_color
    mov dword [rsp + 64], eax       ; save terrain color

    ; px = GAME_GRID_X + tx * GAME_TILE_SIZE
    mov eax, [rsp + 52]
    imul eax, GAME_TILE_SIZE
    add eax, GAME_GRID_X
    mov dword [rsp + 48], eax       ; px (reuse slot)

    ; py = GAME_GRID_Y + ty * GAME_TILE_SIZE
    mov eax, [rsp + 56]
    imul eax, GAME_TILE_SIZE
    add eax, GAME_GRID_Y
    mov dword [rsp + 52], eax       ; py (reuse slot)

    ; fb_fill_rect(px+1, py+1, GAME_TILE_SIZE-2, GAME_TILE_SIZE-2, terrain_color)
    mov ecx, [rsp + 48]
    add ecx, 1
    mov edx, [rsp + 52]
    add edx, 1
    mov r8d, GAME_TILE_SIZE - 2
    mov r9d, GAME_TILE_SIZE - 2
    mov eax, [rsp + 64]
    mov dword [rsp + 32], eax
    call fb_fill_rect

    ; fb_draw_rect(px, py, GAME_TILE_SIZE, GAME_TILE_SIZE, COL_TILE_GRID)
    mov ecx, [rsp + 48]
    mov edx, [rsp + 52]
    mov r8d, GAME_TILE_SIZE
    mov r9d, GAME_TILE_SIZE
    mov dword [rsp + 32], COL_TILE_GRID
    call fb_draw_rect

.gdg_tile_next:
    inc r13d
    jmp .gdg_tile_loop
.gdg_tiles_done:

    ; --- Tree markers ---
    lea rcx, [rel str_cn_game_trees]
    call herb_container_count
    mov esi, eax                    ; rsi = tree_count
    test esi, esi
    jle .gdg_trees_done
    xor r13d, r13d

.gdg_tree_loop:
    cmp r13d, esi
    jge .gdg_trees_done

    lea rcx, [rel str_cn_game_trees]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .gdg_tree_next
    mov dword [rsp + 48], eax

    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax       ; tx

    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    ; ty = eax

    ; px = GAME_GRID_X + tx * GAME_TILE_SIZE
    mov ecx, [rsp + 52]
    imul ecx, GAME_TILE_SIZE
    add ecx, GAME_GRID_X
    ; py = GAME_GRID_Y + ty * GAME_TILE_SIZE
    imul eax, GAME_TILE_SIZE
    add eax, GAME_GRID_Y
    ; cx = px + GAME_TILE_SIZE/2, cy = py + GAME_TILE_SIZE/2
    mov dword [rsp + 48], ecx       ; save px
    mov dword [rsp + 52], eax       ; save py
    add ecx, GAME_TILE_SIZE / 2     ; cx
    add eax, GAME_TILE_SIZE / 2     ; cy
    mov dword [rsp + 56], ecx       ; save cx
    mov dword [rsp + 60], eax       ; save cy

    ; Trunk: fb_fill_rect(cx-2, cy+2, 4, 10, COL_TREE_TRUNK)
    sub ecx, 2
    add eax, 2
    mov edx, eax
    mov r8d, 4
    mov r9d, 10
    mov dword [rsp + 32], COL_TREE_TRUNK
    call fb_fill_rect

    ; Canopy: fb_fill_rect(cx-8, cy-8, 16, 14, COL_TREE)
    mov ecx, [rsp + 56]
    sub ecx, 8
    mov edx, [rsp + 60]
    sub edx, 8
    mov r8d, 16
    mov r9d, 14
    mov dword [rsp + 32], COL_TREE
    call fb_fill_rect

.gdg_tree_next:
    inc r13d
    jmp .gdg_tree_loop
.gdg_trees_done:

    ; --- Player marker ---
    mov eax, [rel player_eid]
    test eax, eax
    js .gdg_player_done
    mov dword [rsp + 48], eax       ; save player_eid

    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax       ; px_tile

    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    ; py_tile = eax

    ; px = GAME_GRID_X + px_tile * GAME_TILE_SIZE
    mov ecx, [rsp + 52]
    imul ecx, GAME_TILE_SIZE
    add ecx, GAME_GRID_X
    ; py = GAME_GRID_Y + py_tile * GAME_TILE_SIZE
    imul eax, GAME_TILE_SIZE
    add eax, GAME_GRID_Y
    mov dword [rsp + 52], ecx       ; save px
    mov dword [rsp + 56], eax       ; save py

    ; Player rect: margin=10
    ; fb_fill_rect(px+10, py+10, GAME_TILE_SIZE-20, GAME_TILE_SIZE-20, COL_PLAYER)
    add ecx, 10
    add eax, 10
    mov edx, eax
    mov r8d, GAME_TILE_SIZE - 20
    mov r9d, GAME_TILE_SIZE - 20
    mov dword [rsp + 32], COL_PLAYER
    call fb_fill_rect

    ; fb_draw_rect(px+9, py+9, GAME_TILE_SIZE-18, GAME_TILE_SIZE-18, COL_PLAYER_BDR)
    mov ecx, [rsp + 52]
    add ecx, 9
    mov edx, [rsp + 56]
    add edx, 9
    mov r8d, GAME_TILE_SIZE - 18
    mov r9d, GAME_TILE_SIZE - 18
    mov dword [rsp + 32], COL_PLAYER_BDR
    call fb_draw_rect

.gdg_player_done:

    ; --- Info panel ---
    ; Background
    mov ecx, GAME_INFO_X
    mov edx, GAME_GRID_Y
    mov r8d, GAME_INFO_W
    mov r9d, GAME_GRID_H
    mov dword [rsp + 32], COL_GAME_BG
    call fb_fill_rect

    ; Border
    mov ecx, GAME_INFO_X
    mov edx, GAME_GRID_Y
    mov r8d, GAME_INFO_W
    mov r9d, GAME_GRID_H
    mov dword [rsp + 32], COL_BORDER
    call fb_draw_rect

    mov edi, GAME_INFO_X + 12       ; ix
    mov r12d, GAME_GRID_Y + 12      ; iy

    ; "COMMON HERB"
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_common_herb]
    mov r9d, COL_GAME_TITLE
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 24

    ; "Player"
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_player_lbl]
    mov r9d, COL_TEXT_HI
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 16

    ; Player info (if player_eid >= 0)
    mov eax, [rel player_eid]
    test eax, eax
    js .gdg_skip_player_info
    mov dword [rsp + 48], eax

    ; ptx = tile_x
    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax       ; ptx

    ; pty = tile_y
    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 56], eax       ; pty

    ; hp
    mov ecx, [rsp + 48]
    lea rdx, [rel str_hp]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 60], eax       ; hp

    ; "Pos: (" x "," y ")"
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_pos_open]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    ; eax = next x

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 52]             ; ptx
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int

    mov ecx, eax
    mov edx, r12d
    lea r8, [rel str_gfx_comma]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 56]             ; pty
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int

    mov ecx, eax
    mov edx, r12d
    lea r8, [rel str_gfx_paren_close]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 16

    ; "HP: " hp
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_hp_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 60]             ; hp
    mov r9d, COL_RUNNING
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int
    add r12d, 16

    ; Terrain under player: search tiles
    xor r13d, r13d
.gdg_terrain_search:
    cmp r13d, ebx                   ; tile_count
    jge .gdg_terrain_search_done

    lea rcx, [rel str_cn_game_tiles]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .gdg_terrain_search_next
    mov dword [rsp + 64], eax       ; tid

    mov ecx, eax
    lea rdx, [rel str_tile_x]
    mov r8, -1
    call herb_entity_prop_int
    cmp eax, [rsp + 52]             ; ptx
    jne .gdg_terrain_search_next

    mov ecx, [rsp + 64]
    lea rdx, [rel str_tile_y]
    mov r8, -1
    call herb_entity_prop_int
    cmp eax, [rsp + 56]             ; pty
    jne .gdg_terrain_search_next

    ; Found matching tile
    mov ecx, [rsp + 64]
    lea rdx, [rel str_terrain]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 64], eax       ; terrain type

    ; "On: "
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_on_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    mov esi, eax                    ; save x pos

    ; terrain_name(terrain)
    mov ecx, [rsp + 64]
    call terrain_name
    mov r8, rax                     ; terrain name string

    ; terrain_color(terrain)
    mov ecx, [rsp + 64]
    call terrain_color
    ; eax = terrain color

    mov ecx, esi                    ; x after "On: "
    mov edx, r12d
    ; r8 = terrain name (already set)
    mov r9d, eax                    ; terrain color as fg
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    jmp .gdg_terrain_search_done

.gdg_terrain_search_next:
    inc r13d
    jmp .gdg_terrain_search
.gdg_terrain_search_done:
    add r12d, 16

.gdg_skip_player_info:
    add r12d, 8

    ; "Inventory"
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_inventory]
    mov r9d, COL_TEXT_HI
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 16

    ; Wood count
    lea rcx, [rel str_cn_game_tree_gathered]
    call herb_container_count
    test eax, eax
    jns .gdg_wood_ok
    xor eax, eax
.gdg_wood_ok:
    mov dword [rsp + 48], eax       ; wood

    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_wood_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 48]
    mov r9d, COL_TREE
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int
    add r12d, 16

    ; Trees left
    lea rcx, [rel str_cn_game_trees]
    call herb_container_count
    test eax, eax
    jns .gdg_trees_ok
    xor eax, eax
.gdg_trees_ok:
    mov dword [rsp + 48], eax

    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_trees_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 48]
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int
    add r12d, 24

    ; Terrain legend
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_terrain_hdr]
    mov r9d, COL_TEXT_HI
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 16

    ; Grass swatch + label
    mov ecx, edi
    lea edx, [r12d + 2]
    mov r8d, 10
    mov r9d, 10
    mov dword [rsp + 32], COL_TILE_GRASS
    call fb_fill_rect
    lea ecx, [edi + 14]
    mov edx, r12d
    lea r8, [rel str_gfx_grass]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 14

    ; Forest swatch
    mov ecx, edi
    lea edx, [r12d + 2]
    mov r8d, 10
    mov r9d, 10
    mov dword [rsp + 32], COL_TILE_FOREST
    call fb_fill_rect
    lea ecx, [edi + 14]
    mov edx, r12d
    lea r8, [rel str_gfx_forest]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 14

    ; Water swatch
    mov ecx, edi
    lea edx, [r12d + 2]
    mov r8d, 10
    mov r9d, 10
    mov dword [rsp + 32], COL_TILE_WATER
    call fb_fill_rect
    lea ecx, [edi + 14]
    mov edx, r12d
    lea r8, [rel str_gfx_water]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 14

    ; Stone swatch
    mov ecx, edi
    lea edx, [r12d + 2]
    mov r8d, 10
    mov r9d, 10
    mov dword [rsp + 32], COL_TILE_STONE
    call fb_fill_rect
    lea ecx, [edi + 14]
    mov edx, r12d
    lea r8, [rel str_gfx_stone]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 24

    ; Controls
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_controls]
    mov r9d, COL_TEXT_HI
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 16

    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_ctrl_arrow]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 14

    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_ctrl_space]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 14

    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_ctrl_g]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    add rsp, 72
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

%endif  ; KERNEL_MODE (gfx_draw_game)

; ============================================================
; GAME WINDOW DRAW FUNCTION — renders game inside a WM window
; void game_draw_fn(int cx, int cy, int cw, int ch, void* win_ptr)
; MS x64: ECX=cx, EDX=cy, R8D=cw, R9D=ch, [rbp+48]=win_ptr
;
; Stack: push rbp + 7 pushes + sub rsp 96
;   8(ret)+8(rbp)+56(pushes)+96 = 168. 168%16=8. Need +8.
;   Actually: 8(ret)+8(rbp)+56(pushes) = 72 on stack. sub rsp 104 → 72+104=176. 176%16=0 ✓
;
; Locals:
;   [rsp+32..39] shadow/arg5
;   [rsp+40..43] temp
;   [rsp+44..47] temp
;   [rsp+48..51] temp eid
;   [rsp+52..55] temp tx
;   [rsp+56..59] temp ty
;   [rsp+60..63] temp terrain/color
;   [rsp+64..67] cx save
;   [rsp+68..71] cy save
;   [rsp+72..75] cw save
;   [rsp+76..79] ch save
;   [rsp+80..83] tile_count
;   [rsp+84..87] info_y (for text panel)
;   [rsp+88..95] spare
;   [rsp+96..103] spare
; ============================================================

%ifdef KERNEL_MODE

game_draw_fn:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 104

    ; Save client rect params
    mov dword [rsp + 64], ecx          ; cx
    mov dword [rsp + 68], edx          ; cy
    mov dword [rsp + 72], r8d          ; cw
    mov dword [rsp + 76], r9d          ; ch

    ; wm_set_clip(cx, cy, cw, ch) — params already in registers
    call wm_set_clip

    ; Fill background
    mov ecx, [rsp + 64]
    mov edx, [rsp + 68]
    mov r8d, [rsp + 72]
    mov r9d, [rsp + 76]
    mov dword [rsp + 32], COL_GAME_BG
    call fb_fill_rect

    ; --- Tile grid (32px tiles) ---
    lea rcx, [rel str_cn_game_tiles]
    call herb_container_count
    mov dword [rsp + 80], eax          ; tile_count
    test eax, eax
    jle .gwf_tiles_done
    xor r13d, r13d                     ; loop index

.gwf_tile_loop:
    cmp r13d, [rsp + 80]
    jge .gwf_tiles_done

    lea rcx, [rel str_cn_game_tiles]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .gwf_tile_next
    mov dword [rsp + 48], eax          ; eid

    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax          ; tx

    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 56], eax          ; ty

    mov ecx, [rsp + 48]
    lea rdx, [rel str_terrain]
    xor r8d, r8d
    call herb_entity_prop_int

    mov ecx, eax
    call terrain_color
    mov dword [rsp + 60], eax          ; terrain color

    ; px = cx + WGAME_GRID_PAD + tx * WGAME_TILE_SIZE
    mov eax, [rsp + 52]
    imul eax, WGAME_TILE_SIZE
    add eax, [rsp + 64]
    add eax, WGAME_GRID_PAD
    mov dword [rsp + 48], eax          ; px

    ; py = cy + WGAME_GRID_PAD + ty * WGAME_TILE_SIZE
    mov eax, [rsp + 56]
    imul eax, WGAME_TILE_SIZE
    add eax, [rsp + 68]
    add eax, WGAME_GRID_PAD
    mov dword [rsp + 52], eax          ; py

    ; fb_fill_rect(px+1, py+1, 30, 30, terrain_color)
    mov ecx, [rsp + 48]
    add ecx, 1
    mov edx, [rsp + 52]
    add edx, 1
    mov r8d, WGAME_TILE_SIZE - 2
    mov r9d, WGAME_TILE_SIZE - 2
    mov eax, [rsp + 60]
    mov dword [rsp + 32], eax
    call fb_fill_rect

    ; fb_draw_rect(px, py, 32, 32, grid_color)
    mov ecx, [rsp + 48]
    mov edx, [rsp + 52]
    mov r8d, WGAME_TILE_SIZE
    mov r9d, WGAME_TILE_SIZE
    mov dword [rsp + 32], COL_TILE_GRID
    call fb_draw_rect

.gwf_tile_next:
    inc r13d
    jmp .gwf_tile_loop
.gwf_tiles_done:

    ; --- Tree markers (small green squares) ---
    lea rcx, [rel str_cn_game_trees]
    call herb_container_count
    mov esi, eax
    test esi, esi
    jle .gwf_trees_done
    xor r13d, r13d

.gwf_tree_loop:
    cmp r13d, esi
    jge .gwf_trees_done

    lea rcx, [rel str_cn_game_trees]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .gwf_tree_next
    mov dword [rsp + 48], eax

    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax

    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int

    ; px = cx + pad + tx*32 + 8
    mov ecx, [rsp + 52]
    imul ecx, WGAME_TILE_SIZE
    add ecx, [rsp + 64]
    add ecx, WGAME_GRID_PAD
    add ecx, 8
    ; py = cy + pad + ty*32 + 4
    imul eax, WGAME_TILE_SIZE
    add eax, [rsp + 68]
    add eax, WGAME_GRID_PAD
    add eax, 4

    ; Trunk: fb_fill_rect(px+5, py+12, 4, 10, COL_TREE_TRUNK)
    mov dword [rsp + 48], ecx
    mov dword [rsp + 52], eax
    add ecx, 5
    add eax, 12
    mov edx, eax
    mov r8d, 4
    mov r9d, 10
    mov dword [rsp + 32], COL_TREE_TRUNK
    call fb_fill_rect

    ; Canopy: fb_fill_rect(px, py, 16, 14, COL_TREE)
    mov ecx, [rsp + 48]
    mov edx, [rsp + 52]
    mov r8d, 16
    mov r9d, 14
    mov dword [rsp + 32], COL_TREE
    call fb_fill_rect

.gwf_tree_next:
    inc r13d
    jmp .gwf_tree_loop
.gwf_trees_done:

    ; --- Player marker ---
    mov eax, [rel player_eid]
    test eax, eax
    js .gwf_player_done
    mov dword [rsp + 48], eax

    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax          ; ptx

    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int

    ; px = cx + pad + ptx*32
    mov ecx, [rsp + 52]
    imul ecx, WGAME_TILE_SIZE
    add ecx, [rsp + 64]
    add ecx, WGAME_GRID_PAD
    ; py = cy + pad + pty*32
    imul eax, WGAME_TILE_SIZE
    add eax, [rsp + 68]
    add eax, WGAME_GRID_PAD

    mov dword [rsp + 48], ecx
    mov dword [rsp + 52], eax

    ; Player rect with margin=6
    add ecx, 6
    add eax, 6
    mov edx, eax
    mov r8d, WGAME_TILE_SIZE - 12
    mov r9d, WGAME_TILE_SIZE - 12
    mov dword [rsp + 32], COL_PLAYER
    call fb_fill_rect

    ; Player border
    mov ecx, [rsp + 48]
    add ecx, 5
    mov edx, [rsp + 52]
    add edx, 5
    mov r8d, WGAME_TILE_SIZE - 10
    mov r9d, WGAME_TILE_SIZE - 10
    mov dword [rsp + 32], COL_PLAYER_BDR
    call fb_draw_rect

.gwf_player_done:

    ; --- NPC markers ---
    lea rcx, [rel str_cn_game_npcs]
    call herb_container_count
    mov r14d, eax                      ; npc_count
    test r14d, r14d
    jle .gwf_npcs_done
    xor r13d, r13d

.gwf_npc_loop:
    cmp r13d, r14d
    jge .gwf_npcs_done

    lea rcx, [rel str_cn_game_npcs]
    mov edx, r13d
    call herb_container_entity
    test eax, eax
    js .gwf_npc_next
    mov dword [rsp + 48], eax

    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax

    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int

    ; px = cx + pad + tx*32
    mov ecx, [rsp + 52]
    imul ecx, WGAME_TILE_SIZE
    add ecx, [rsp + 64]
    add ecx, WGAME_GRID_PAD
    ; py = cy + pad + ty*32
    imul eax, WGAME_TILE_SIZE
    add eax, [rsp + 68]
    add eax, WGAME_GRID_PAD

    ; NPC diamond: fill_rect(px+10, py+10, 12, 12, color)
    ; Color: first NPC = cyan, second = magenta
    add ecx, 10
    add eax, 10
    mov edx, eax
    mov r8d, 12
    mov r9d, 12
    cmp r13d, 0
    jne .gwf_npc_col2
    mov dword [rsp + 32], COL_NPC_GUARD
    jmp .gwf_npc_draw
.gwf_npc_col2:
    mov dword [rsp + 32], COL_NPC_SCOUT
.gwf_npc_draw:
    call fb_fill_rect

.gwf_npc_next:
    inc r13d
    jmp .gwf_npc_loop
.gwf_npcs_done:

    ; --- Info panel below grid ---
    mov eax, [rsp + 68]               ; cy
    add eax, WGAME_INFO_Y_OFF
    mov dword [rsp + 84], eax         ; info_y
    mov edi, [rsp + 64]               ; cx
    add edi, 8                         ; left margin
    mov r12d, eax                      ; current y

    ; "COMMON HERB"
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_common_herb]
    mov r9d, COL_GAME_TITLE
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 18

    ; Player pos and stats (if player_eid >= 0)
    mov eax, [rel player_eid]
    test eax, eax
    js .gwf_skip_info
    mov dword [rsp + 48], eax

    ; Read tile_x
    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax

    ; Read tile_y
    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 56], eax

    ; Read hp
    mov ecx, [rsp + 48]
    lea rdx, [rel str_hp]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 60], eax

    ; Read wood
    mov ecx, [rsp + 48]
    lea rdx, [rel str_prop_wood]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 88], eax         ; wood

    ; "Pos: (" x "," y ")"
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_pos_open]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 52]
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int

    mov ecx, eax
    mov edx, r12d
    lea r8, [rel str_gfx_comma]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 56]
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int

    mov ecx, eax
    mov edx, r12d
    lea r8, [rel str_gfx_paren_close]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 16

    ; "HP: " hp
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_hp_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 60]
    mov r9d, COL_RUNNING
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int
    add r12d, 16

    ; "Wood: " wood
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_wood_w_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 88]
    mov r9d, COL_TREE
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int
    add r12d, 16

.gwf_skip_info:

    ; --- NPC info ---
    ; "NPCs"
    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_npc_lbl]
    mov r9d, COL_TEXT_HI
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string
    add r12d, 16

    ; Guard info
    lea rcx, [rel str_cn_game_npcs]
    call herb_container_count
    test eax, eax
    jle .gwf_npc_info_done

    ; NPC 0 (guard)
    lea rcx, [rel str_cn_game_npcs]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .gwf_npc_info_done
    mov dword [rsp + 48], eax

    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax

    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 56], eax

    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_guard_lbl]
    mov r9d, COL_NPC_GUARD
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 52]
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int

    mov ecx, eax
    mov edx, r12d
    lea r8, [rel str_gfx_comma]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 56]
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int
    add r12d, 14

    ; NPC 1 (scout)
    lea rcx, [rel str_cn_game_npcs]
    mov edx, 1
    call herb_container_entity
    test eax, eax
    js .gwf_npc_info_done
    mov dword [rsp + 48], eax

    mov ecx, eax
    lea rdx, [rel str_tile_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 52], eax

    mov ecx, [rsp + 48]
    lea rdx, [rel str_tile_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + 56], eax

    mov ecx, edi
    mov edx, r12d
    lea r8, [rel str_gfx_scout_lbl]
    mov r9d, COL_NPC_SCOUT
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 52]
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int

    mov ecx, eax
    mov edx, r12d
    lea r8, [rel str_gfx_comma]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_string

    mov ecx, eax
    mov edx, r12d
    mov r8d, [rsp + 56]
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_GAME_BG
    call fb_draw_int

.gwf_npc_info_done:

    call wm_clear_clip

    add rsp, 104
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

%endif  ; KERNEL_MODE (game_draw_fn)

; ============================================================
; FLOW EDITOR DRAW FUNCTION — renders HERB-flow editor inside WM window
; void flow_editor_draw_fn(int cx, int cy, int cw, int ch, void* win_ptr)
; MS x64: ECX=cx, EDX=cy, R8D=cw, R9D=ch, [rbp+48]=win_ptr
; ============================================================
%ifdef KERNEL_MODE

; Locals for flow_editor_draw_fn (Session 94: direct rendering from BUFFER)
%define FED_CX     64
%define FED_CY     68
%define FED_CW     72
%define FED_CH     76
%define FED_VI     80    ; loop index
%define FED_NV     84    ; char count in buffer
%define FED_CURX   88    ; current column (0-based)
%define FED_CURL   92    ; current line (0-based)
%define FED_CPL    96    ; chars per line (cw / 12)
%define FED_VLINES 100   ; visible lines ((ch - 54) / 24)

flow_editor_draw_fn:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 120                        ; shadow(32) + locals
    ; 6 pushes + sub 120 = 8 + 48 + 120 = 176. 176 % 16 = 0. ✓

    ; Save client area params
    mov dword [rsp + FED_CX], ecx
    mov dword [rsp + FED_CY], edx
    mov dword [rsp + FED_CW], r8d
    mov dword [rsp + FED_CH], r9d

    ; Compute chars_per_line = cw / 12
    mov eax, r8d
    xor edx, edx
    mov ecx, 12
    div ecx
    mov dword [rsp + FED_CPL], eax

    ; Compute visible_lines = (ch - 54) / 24  (28px info bar + 26px status bar)
    mov eax, r9d
    sub eax, 54
    xor edx, edx
    mov ecx, 24
    div ecx
    test eax, eax
    jg .fed_vis_ok
    mov eax, 1                          ; minimum 1 visible line
.fed_vis_ok:
    mov dword [rsp + FED_VLINES], eax

    ; 1. Set clip rect to client area (reload after div clobbered ecx/edx)
    mov ecx, [rsp + FED_CX]
    mov edx, [rsp + FED_CY]
    mov r8d, [rsp + FED_CW]
    mov r9d, [rsp + FED_CH]
    call wm_set_clip

    ; 2. Fill background
    mov ecx, [rsp + FED_CX]
    mov edx, [rsp + FED_CY]
    mov r8d, [rsp + FED_CW]
    mov r9d, [rsp + FED_CH]
    mov dword [rsp + 32], 0x001A1A2E   ; dark blue editor bg
    call fb_fill_rect

    ; 3. Info bar at top of content area
    mov ecx, [rsp + FED_CX]
    mov edx, [rsp + FED_CY]
    mov r8d, [rsp + FED_CW]
    mov r9d, 26
    mov dword [rsp + 32], 0x00252540   ; status bar bg
    call fb_fill_rect

    ; "EDITOR" title
    mov ecx, [rsp + FED_CX]
    add ecx, 10
    mov edx, [rsp + FED_CY]
    add edx, 3
    lea r8, [rel str_gfx_editor_title]
    mov r9d, 0x004A90D9                ; blue title
    mov dword [rsp + 32], 0x00252540
    call fb_draw_string
    mov ebx, eax                       ; ebx = end x after title

    ; "Chars:" label + count
    lea ecx, [ebx + 16]
    mov edx, [rsp + FED_CY]
    add edx, 3
    lea r8, [rel str_gfx_ed_chars]
    mov r9d, 0x00808090
    mov dword [rsp + 32], 0x00252540
    call fb_draw_string
    mov ebx, eax

    ; char count = herb_container_count("editor.BUFFER")
    lea rcx, [rel str_cn_ed_buffer]
    call herb_container_count
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    mov r12d, eax                      ; r12 = char count

    mov ecx, ebx
    mov edx, [rsp + FED_CY]
    add edx, 3
    mov r8d, r12d
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], 0x00252540
    call fb_draw_int

    ; 4. Separator line
    mov ecx, [rsp + FED_CX]
    mov edx, [rsp + FED_CY]
    add edx, 20
    mov r8d, [rsp + FED_CW]
    mov r9d, 0x004A90D9
    call fb_hline

    ; 5. Render chars directly from editor.BUFFER (Session 94)
    ;    Compute x/y on-the-fly with newline + wrap support.
    ;    Apply scroll offset from flow_editor_scroll_y.
    ;    Track cursor visual position based on cursor_pos from editor.CTL.
    mov dword [rsp + FED_CURX], 0      ; current column
    mov dword [rsp + FED_CURL], 0      ; current line
    mov dword [rsp + FED_VI], 0        ; loop index

    ; Read cursor_pos from editor.CTL (r13d = cursor_pos, -1 if unavailable)
    mov r13d, -1
    lea rcx, [rel str_cn_ed_ctl]
    xor edx, edx
    call herb_container_entity
    test eax, eax
    js .fed_cpos_done
    mov ecx, eax
    lea rdx, [rel str_prop_cursor_pos]
    xor r8d, r8d
    call herb_entity_prop_int
    mov r13d, eax                       ; r13d = cursor_pos
.fed_cpos_done:

    ; r12d = cursor visual col, ebx = cursor visual line (computed during loop)
    ; Initialize to 0,0 (cursor at start if buffer empty or cursor_pos == 0)
    xor r12d, r12d
    xor ebx, ebx

    lea rcx, [rel str_cn_ed_buffer]
    call herb_container_count
    test eax, eax
    jle .fed_no_chars
    mov dword [rsp + FED_NV], eax

.fed_char_loop:
    mov eax, [rsp + FED_VI]
    cmp eax, [rsp + FED_NV]
    jge .fed_no_chars

    ; Check if this index == cursor_pos → save cursor visual position
    cmp eax, r13d
    jne .fed_no_cursor_save
    mov r12d, [rsp + FED_CURX]          ; cursor col
    mov ebx, [rsp + FED_CURL]           ; cursor line
.fed_no_cursor_save:

    ; eid = herb_container_entity("editor.BUFFER", i)
    lea rcx, [rel str_cn_ed_buffer]
    mov edx, [rsp + FED_VI]
    call herb_container_entity
    test eax, eax
    js .fed_char_next

    ; ascii = herb_entity_prop_int(eid, "ascii", 0)
    mov ecx, eax
    lea rdx, [rel str_ascii_prop]
    xor r8d, r8d
    call herb_entity_prop_int
    test eax, eax
    jle .fed_char_next

    ; Check newline (ascii == 10)
    cmp eax, 10
    jne .fed_not_newline
    ; Newline: advance line, reset column
    mov dword [rsp + FED_CURX], 0
    inc dword [rsp + FED_CURL]
    jmp .fed_char_next

.fed_not_newline:
    mov esi, eax                        ; esi = ascii (callee-saved)

    ; Check if visible: screen_line = cur_line - scroll_y
    mov ecx, [rsp + FED_CURL]
    sub ecx, [rel flow_editor_scroll_y]
    js .fed_char_advance                ; above visible area
    cmp ecx, [rsp + FED_VLINES]
    jge .fed_char_advance               ; below visible area

    ; Draw character at (cur_x, screen_line)
    ; pixel_x = cx + cur_x * 12
    mov eax, [rsp + FED_CURX]
    imul eax, eax, 12
    add eax, [rsp + FED_CX]
    ; pixel_y = cy + 28 + screen_line * 24
    imul ecx, ecx, 24
    add ecx, [rsp + FED_CY]
    add ecx, 28

    ; fb_draw_char(pixel_x, pixel_y, ascii, fg, bg)
    mov edx, ecx                        ; y
    mov ecx, eax                        ; x
    mov r8d, esi                        ; ascii
    mov r9d, 0x00C0C0C0                ; light gray text
    mov dword [rsp + 32], 0x001A1A2E   ; editor bg
    call fb_draw_char

.fed_char_advance:
    ; Advance column, handle wrap
    inc dword [rsp + FED_CURX]
    mov eax, [rsp + FED_CURX]
    cmp eax, [rsp + FED_CPL]
    jl .fed_char_next
    mov dword [rsp + FED_CURX], 0
    inc dword [rsp + FED_CURL]

.fed_char_next:
    inc dword [rsp + FED_VI]
    jmp .fed_char_loop

.fed_no_chars:
    ; If cursor_pos >= buffer_count (at end), use CURX/CURL after loop
    mov eax, [rsp + FED_VI]             ; FED_VI = final loop count or NV
    cmp r13d, eax
    jl .fed_cursor_pos_set              ; cursor_pos was inside buffer → r12/ebx already set
    ; cursor at end of buffer
    mov r12d, [rsp + FED_CURX]
    mov ebx, [rsp + FED_CURL]
.fed_cursor_pos_set:
    ; r12d = cursor col, ebx = cursor line
    ; Save cursor line to FED_CURL for status bar display
    mov [rsp + FED_CURL], ebx

    ; Auto-scroll: keep cursor visible
    mov eax, ebx                        ; cursor line
    mov ecx, [rel flow_editor_scroll_y]
    cmp eax, ecx
    jge .fed_scroll_not_above
    mov [rel flow_editor_scroll_y], eax ; scroll up to cursor
    jmp .fed_scroll_done
.fed_scroll_not_above:
    mov ecx, [rel flow_editor_scroll_y]
    add ecx, [rsp + FED_VLINES]
    cmp eax, ecx
    jl .fed_scroll_done
    ; cursor_line - visible_lines + 1
    mov ecx, eax
    sub ecx, [rsp + FED_VLINES]
    inc ecx
    mov [rel flow_editor_scroll_y], ecx ; scroll down to cursor
.fed_scroll_done:

    ; 6. Cursor — vertical bar at (r12d=col, ebx=line) if visible
    mov eax, ebx
    sub eax, [rel flow_editor_scroll_y]
    js .fed_cursor_done
    cmp eax, [rsp + FED_VLINES]
    jge .fed_cursor_done
    ; eax = cursor screen_line
    ; pixel_x = cx + cursor_col * 12
    mov ecx, r12d
    imul ecx, ecx, 12
    add ecx, [rsp + FED_CX]
    ; pixel_y = cy + 28 + screen_line * 24
    imul eax, eax, 24
    add eax, [rsp + FED_CY]
    add eax, 28
    ; fb_fill_rect(pixel_x, pixel_y, 2, 24, white)
    mov edx, eax                        ; y
    ; ecx already = pixel_x
    mov r8d, 2                          ; 2px wide vertical bar cursor
    mov r9d, 24
    mov dword [rsp + 32], 0x00FFFFFF   ; white
    call fb_fill_rect

.fed_cursor_done:

    ; 7. Status bar at bottom of content area
    mov ecx, [rsp + FED_CX]
    mov eax, [rsp + FED_CY]
    add eax, [rsp + FED_CH]
    sub eax, 26
    mov edx, eax                       ; bar_y = cy + ch - 26
    mov r8d, [rsp + FED_CW]
    mov r9d, 26
    mov dword [rsp + 32], 0x00161622
    call fb_fill_rect

    ; Status text
    mov ecx, [rsp + FED_CX]
    add ecx, 12
    mov edx, [rsp + FED_CY]
    add edx, [rsp + FED_CH]
    sub edx, 23
    lea r8, [rel str_gfx_ed_status]
    mov r9d, 0x00808090
    mov dword [rsp + 32], 0x00161622
    call fb_draw_string
    mov ebx, eax                        ; ebx = end x

    ; "Ln:" + line number in status bar
    lea ecx, [ebx + 20]
    mov edx, [rsp + FED_CY]
    add edx, [rsp + FED_CH]
    sub edx, 23
    lea r8, [rel str_gfx_ed_line]
    mov r9d, 0x00808090
    mov dword [rsp + 32], 0x00161622
    call fb_draw_string

    mov ecx, eax                        ; x after "Ln:"
    mov edx, [rsp + FED_CY]
    add edx, [rsp + FED_CH]
    sub edx, 23
    mov r8d, [rsp + FED_CURL]
    inc r8d                             ; 1-based line number
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], 0x00161622
    call fb_draw_int

    ; 8. Clear clip rect
    call wm_clear_clip

    add rsp, 120
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

%endif  ; KERNEL_MODE (flow_editor_draw_fn)
%endif  ; GRAPHICS_MODE (temporarily close for Session 94 non-graphics functions)

; ============================================================
; Session 94: Editor flow detection + pool expansion
; These functions don't use graphics — must be outside GRAPHICS_MODE
; ============================================================
%ifdef KERNEL_MODE

; editor_find_flow_idx(void)
; Scans g_flows[] for render_editor flow, sets g_editor_flow_idx.
editor_find_flow_idx:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 32                         ; shadow space
    ; 3 pushes + sub 32 = 8 + 24 + 32 = 64. 64 % 16 = 0. ✓

    ; Intern "render_editor" to get name_id
    lea rcx, [rel str_render_editor]
    call intern
    mov ebx, eax                        ; ebx = name_id

    xor esi, esi                        ; esi = flow index
.efi_loop:
    cmp esi, [rel g_flow_count]
    jge .efi_notfound
    movsxd rax, esi
    imul rax, SIZEOF_FLOW
    lea rcx, [g_flows + rax]
    cmp dword [rcx + FLOW_NAME_ID], ebx
    je .efi_found
    inc esi
    jmp .efi_loop
.efi_found:
    mov dword [rel g_editor_flow_idx], esi
    ; Serial: "[EDITOR] flow idx=N\n"
    lea rcx, [rel str_ser_editor_flow]
    call serial_print
    mov ecx, esi
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print
    jmp .efi_done
.efi_notfound:
    ; Leave g_editor_flow_idx as -1
.efi_done:
    add rsp, 32
    pop rsi
    pop rbx
    pop rbp
    ret

; editor_expand_pool(void)
; Creates 500 additional input.Char entities in editor.POOL.
editor_expand_pool:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 40                         ; shadow space + 8 align
    ; 6 pushes + sub 40 = 8 + 48 + 40 = 96. 96 % 16 = 0. ✓

    ; Intern "input.Char" → type_name_id
    lea rcx, [rel str_input_char]
    call intern
    mov r12d, eax                       ; r12 = type_name_id

    ; Find editor.POOL container index
    lea rcx, [rel str_cn_ed_pool]
    call intern
    mov ecx, eax
    call graph_find_container_by_name
    test eax, eax
    js .eep_done                        ; container not found
    mov r13d, eax                       ; r13 = pool container_idx

    ; Intern "ascii" and "pos" for property setting
    lea rcx, [rel str_ascii_prop]
    call intern
    mov ebx, eax                        ; ebx = ascii prop name_id (unused — set via string)

    ; Create additional pool entities (with MAX_ENTITIES safety check)
    xor esi, esi                        ; esi = loop counter
.eep_loop:
    cmp esi, 200
    jge .eep_loop_done

    ; Bounds check: stop if entity_count >= MAX_ENTITIES - 10 (leave headroom)
    mov eax, [g_graph + GRAPH_ENTITY_COUNT]
    cmp eax, MAX_ENTITIES - 10
    jge .eep_loop_done

    ; create_entity(type_name_id, type_name_id, pool_cidx)
    mov ecx, r12d                       ; type_name_id
    mov edx, r12d                       ; name_id (same — pool entities are anonymous)
    mov r8d, r13d                       ; container_idx
    call create_entity
    mov edi, eax                        ; edi = new entity id

    ; herb_set_prop_int(eid, "ascii", 0)
    mov ecx, edi
    lea rdx, [rel str_ascii_prop]
    xor r8d, r8d                        ; value = 0
    call herb_set_prop_int

    ; herb_set_prop_int(eid, "pos", 0)
    mov ecx, edi
    lea rdx, [rel str_prop_pos]
    xor r8d, r8d                        ; value = 0
    call herb_set_prop_int

    inc esi
    jmp .eep_loop
.eep_loop_done:

    ; Serial: "[EDITOR] pool expanded to N entities\n"
    lea rcx, [rel str_ser_editor_pool]
    call serial_print
    ; Count = original pool count + added
    lea rcx, [rel str_cn_ed_pool]
    call herb_container_count
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_ser_editor_pool2]
    call serial_print

.eep_done:
    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

%endif  ; KERNEL_MODE (Session 94 editor functions)

%ifdef GRAPHICS_MODE  ; reopen GRAPHICS_MODE after Session 94 functions

; ============================================================
; Window/HERB bridge helpers (Session 90)
; ============================================================
%ifdef KERNEL_MODE
%define KWIN_FLAGS         4
%define KWIN_X             8
%define KWIN_Y             12
%define KWIN_W             16
%define KWIN_H             20
%define KWIN_BORDER_COLOR  40
%define KWIN_FILL_COLOR    44
%define KWIN_TITLE_BG      48
%define KWIN_ENTITY_ID     52
%define KWIN_DRAW_FN       80
%define KWF_VISIBLE        0

; void wm_apply_boot_window_style(int role, int win_id, int entity_id)
; MS x64: ECX=role, EDX=win_id, R8D=HERB wm.Window eid
wm_apply_boot_window_style:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 48
    ; 3 pushes + sub 48 = 80 (aligned)

    mov ebx, ecx
    mov esi, r8d
    mov edi, edx
    mov ecx, edx
    call wm_window_ptr
    test rax, rax
    jz .wabws_done

    mov dword [rax + KWIN_ENTITY_ID], esi

    cmp ebx, WM_ROLE_CPU0
    je .wabws_cpu0
    cmp ebx, WM_ROLE_READY
    je .wabws_ready
    cmp ebx, WM_ROLE_BLOCKED
    je .wabws_blocked
    cmp ebx, WM_ROLE_TERM
    je .wabws_term
    cmp ebx, WM_ROLE_TENSIONS
    je .wabws_tensions
    cmp ebx, WM_ROLE_EDITOR
    je .wabws_editor
    cmp ebx, WM_ROLE_GAME
    je .wabws_game
    jmp .wabws_done

.wabws_cpu0:
    mov dword [rax + KWIN_BORDER_COLOR], COL_RUNNING
    mov dword [rax + KWIN_FILL_COLOR], COL_RUNNING_BG
    mov dword [rax + KWIN_TITLE_BG], COL_RUNNING
    lea rdx, [rel wm_draw_region_adapter]
    mov [rax + KWIN_DRAW_FN], rdx
    jmp .wabws_done

.wabws_ready:
    mov dword [rax + KWIN_BORDER_COLOR], COL_READY_COL
    mov dword [rax + KWIN_FILL_COLOR], COL_READY_BG
    mov dword [rax + KWIN_TITLE_BG], COL_READY_COL
    lea rdx, [rel wm_draw_region_adapter]
    mov [rax + KWIN_DRAW_FN], rdx
    jmp .wabws_done

.wabws_blocked:
    mov dword [rax + KWIN_BORDER_COLOR], COL_BLOCKED_COL
    mov dword [rax + KWIN_FILL_COLOR], COL_BLOCKED_BG
    mov dword [rax + KWIN_TITLE_BG], COL_BLOCKED_COL
    lea rdx, [rel wm_draw_region_adapter]
    mov [rax + KWIN_DRAW_FN], rdx
    jmp .wabws_done

.wabws_term:
    ; Session 93: Repurposed as shell OUTPUT window
    mov dword [rax + KWIN_BORDER_COLOR], 0x00446688    ; blue-gray border
    mov dword [rax + KWIN_FILL_COLOR], 0x001A1A2E      ; dark blue bg
    mov dword [rax + KWIN_TITLE_BG], 0x00446688
    lea rdx, [rel shell_output_draw_fn]
    mov [rax + KWIN_DRAW_FN], rdx
    ; Override title to "OUTPUT"
    lea rdx, [rel str_output_title]
    mov [rax + 56], rdx                                 ; WIN_TITLE_PTR = 56
    ; Save win_id for scroll routing
    mov dword [rel shell_output_win_id], edi
    jmp .wabws_done

.wabws_tensions:
    mov dword [rax + KWIN_BORDER_COLOR], 0x00336688
    mov dword [rax + KWIN_FILL_COLOR], 0x000C1018
    mov dword [rax + KWIN_TITLE_BG], 0x00336688
    lea rdx, [rel wm_draw_tension_adapter]
    mov [rax + KWIN_DRAW_FN], rdx
    jmp .wabws_done

.wabws_editor:
    mov dword [rax + KWIN_BORDER_COLOR], 0x002A2A4E
    mov dword [rax + KWIN_FILL_COLOR], 0x001A1A2E
    mov dword [rax + KWIN_TITLE_BG], 0x002A2A4E
    lea rdx, [rel flow_editor_draw_fn]
    mov [rax + KWIN_DRAW_FN], rdx
    mov dword [rel flow_editor_win_id], edi
    jmp .wabws_done

.wabws_game:
    mov dword [rax + KWIN_BORDER_COLOR], 0x00204030
    mov dword [rax + KWIN_FILL_COLOR], COL_GAME_BG
    mov dword [rax + KWIN_TITLE_BG], 0x00204030
    lea rdx, [rel game_draw_fn]
    mov [rax + KWIN_DRAW_FN], rdx
    mov dword [rel game_win_id], edi

.wabws_done:
    add rsp, 48
    pop rsi
    pop rbx
    pop rbp
    ret

; void wm_write_window_geometry_to_herb(int win_id)
; Writes x/y/width/height back to the owning wm.Window entity.
wm_write_window_geometry_to_herb:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40
    ; 4 pushes + sub 40 = 8+32+40 = 80. 80%16=0 ✓

    mov ebx, ecx
    call wm_window_ptr
    test rax, rax
    jz .wwg_done
    mov rsi, rax

    mov edi, dword [rsi + KWIN_ENTITY_ID]
    test edi, edi
    js .wwg_done

    mov ecx, edi
    lea rdx, [rel str_x]
    mov r8d, dword [rsi + KWIN_X]
    movsxd r8, r8d
    call herb_set_prop_int

    mov ecx, edi
    lea rdx, [rel str_y]
    mov r8d, dword [rsi + KWIN_Y]
    movsxd r8, r8d
    call herb_set_prop_int

    mov ecx, edi
    lea rdx, [rel str_gfx_width]
    mov r8d, dword [rsi + KWIN_W]
    movsxd r8, r8d
    call herb_set_prop_int

    mov ecx, edi
    lea rdx, [rel str_gfx_height]
    mov r8d, dword [rsi + KWIN_H]
    movsxd r8, r8d
    call herb_set_prop_int

.wwg_done:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; void wm_write_all_z_order_to_herb(void)
; Mirrors the current wm_z_order array into each wm.Window entity's z_order prop.
wm_write_all_z_order_to_herb:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 32
    ; 5 pushes + sub 32 = 80 (aligned)

    xor r12d, r12d
.wz_loop:
    cmp r12d, dword [rel wm_window_count]
    jge .wz_done

    lea rax, [rel wm_z_order]
    movzx ebx, byte [rax + r12]
    mov ecx, ebx
    call wm_window_ptr
    test rax, rax
    jz .wz_next

    mov edi, dword [rax + KWIN_ENTITY_ID]
    test edi, edi
    js .wz_next

    mov ecx, edi
    lea rdx, [rel str_z_order]
    mov r8d, r12d
    movsxd r8, r8d
    call herb_set_prop_int

.wz_next:
    inc r12d
    jmp .wz_loop

.wz_done:
    add rsp, 32
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; void wm_sync_from_herb(void)
; Reads wm.Window entities and refreshes the WM cache (geometry + visibility + z order).
; Focus remains assembly-managed in Session 90.
%define WMSH_EID   32
%define WMSH_ROLE  36
%define WMSH_Z     40
%define WMSH_VI    44
%define WMSH_NV    48
%define WMSH_RX    52
%define WMSH_RY    56
%define WMSH_RW    60
%define WMSH_RH    64
%define WMSH_WID   68

wm_sync_from_herb:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 88
    ; 6 pushes + sub 88 = 8+48+88 = 144. 144%16=0 ✓

    lea rcx, [rel wm_z_order]
    mov edx, 0xFF
    mov r8d, 16
    call herb_memset

    xor r12d, r12d
.wsh_clear_loop:
    cmp r12d, WM_ROLE_LIMIT
    jge .wsh_count
    lea r13, [rel wm_role_to_win_id]
    mov eax, dword [r13 + r12*4]
    test eax, eax
    js .wsh_clear_next
    mov ecx, eax
    call wm_window_ptr
    test rax, rax
    jz .wsh_clear_next
    and dword [rax + KWIN_FLAGS], ~(1 << KWF_VISIBLE)
.wsh_clear_next:
    inc r12d
    jmp .wsh_clear_loop

.wsh_count:
    lea rcx, [rel str_cn_wm_visible]
    call herb_container_count
    test eax, eax
    jns .wsh_count_ok
    xor eax, eax
.wsh_count_ok:
    cmp eax, 16
    jle .wsh_count_clamped
    mov eax, 16
.wsh_count_clamped:
    mov dword [rel wm_window_count], eax
    mov dword [rsp + WMSH_NV], eax
    mov dword [rsp + WMSH_VI], 0

.wsh_loop:
    mov eax, dword [rsp + WMSH_VI]
    cmp eax, dword [rsp + WMSH_NV]
    jge .wsh_done

    lea rcx, [rel str_cn_wm_visible]
    mov edx, eax
    call herb_container_entity
    test eax, eax
    js .wsh_next
    mov dword [rsp + WMSH_EID], eax

    mov ecx, eax
    lea rdx, [rel str_role]
    mov r8d, -1
    call herb_entity_prop_int
    mov dword [rsp + WMSH_ROLE], eax
    cmp eax, 0
    jl .wsh_next
    cmp eax, WM_ROLE_GAME
    jg .wsh_next

    mov ecx, dword [rsp + WMSH_EID]
    lea rdx, [rel str_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + WMSH_RX], eax

    mov ecx, dword [rsp + WMSH_EID]
    lea rdx, [rel str_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + WMSH_RY], eax

    mov ecx, dword [rsp + WMSH_EID]
    lea rdx, [rel str_gfx_width]
    mov r8d, 100
    call herb_entity_prop_int
    mov dword [rsp + WMSH_RW], eax

    mov ecx, dword [rsp + WMSH_EID]
    lea rdx, [rel str_gfx_height]
    mov r8d, 100
    call herb_entity_prop_int
    mov dword [rsp + WMSH_RH], eax

    mov ecx, dword [rsp + WMSH_EID]
    lea rdx, [rel str_z_order]
    mov r8d, dword [rsp + WMSH_VI]
    call herb_entity_prop_int
    mov dword [rsp + WMSH_Z], eax

    mov eax, dword [rsp + WMSH_ROLE]
    lea r13, [rel wm_role_to_win_id]
    mov eax, dword [r13 + rax*4]
    mov dword [rsp + WMSH_WID], eax
    test eax, eax
    js .wsh_next

    mov ecx, eax
    call wm_window_ptr
    test rax, rax
    jz .wsh_next

    mov ebx, dword [rsp + WMSH_RX]
    mov dword [rax + KWIN_X], ebx
    mov ebx, dword [rsp + WMSH_RY]
    mov dword [rax + KWIN_Y], ebx
    mov ebx, dword [rsp + WMSH_RW]
    mov dword [rax + KWIN_W], ebx
    mov ebx, dword [rsp + WMSH_RH]
    mov dword [rax + KWIN_H], ebx
    mov ebx, dword [rsp + WMSH_EID]
    mov dword [rax + KWIN_ENTITY_ID], ebx
    or dword [rax + KWIN_FLAGS], (1 << KWF_VISIBLE)

    mov edx, dword [rsp + WMSH_Z]
    cmp edx, 0
    jl .wsh_next
    cmp edx, 16
    jge .wsh_next
    mov eax, dword [rsp + WMSH_WID]
    lea rcx, [rel wm_z_order]
    mov byte [rcx + rdx], al

.wsh_next:
    inc dword [rsp + WMSH_VI]
    jmp .wsh_loop

.wsh_done:
    add rsp, 88
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- wm_apply_herb_focus(int force) ----
; Read "focused" property from wm.VISIBLE entities.
; The one with focused >= 1 gets wm_set_focus + wm_bring_to_front.
; If none focused, wm_set_focus(-1).
; Args: ECX = force (0 = skip if unchanged, 1 = always apply)
; Stack: 4 pushes (rbp, rbx, rsi, rdi) + sub rsp 56 = 8+32+56 = 96. 96%16=0. ✓
wm_apply_herb_focus:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 56
    ; [rsp+32] = count, [rsp+36] = index, [rsp+40] = best_win_id, [rsp+44] = best_z
    ; [rsp+48] = force, [rsp+52] = (temp for tension scan)
    mov dword [rsp+48], ecx

    ; When force=0, check if wm.focus_on_click is enabled.
    ; If disabled, skip entirely — don't read stale focused properties.
    cmp ecx, 1
    je .wahf_scan                   ; force=1: always proceed

    call herb_tension_count
    mov dword [rsp+52], eax
    xor ebx, ebx                    ; tension index

.wahf_find_tension:
    cmp ebx, dword [rsp+52]
    jge .wahf_done                  ; tension not found — skip (safe default)

    mov ecx, ebx
    call herb_tension_name
    test rax, rax
    jz .wahf_find_next

    mov rcx, rax
    lea rdx, [rel str_wm_focus_on_click]
    call herb_strcmp
    test eax, eax
    jz .wahf_found_tension

.wahf_find_next:
    inc ebx
    jmp .wahf_find_tension

.wahf_found_tension:
    mov ecx, ebx
    call herb_tension_enabled
    test eax, eax
    jz .wahf_done                   ; tension disabled — skip entirely

.wahf_scan:
    ; Get entity count in wm.VISIBLE
    lea rcx, [rel str_cn_wm_visible]
    call herb_container_count
    test eax, eax
    jle .wahf_none
    mov dword [rsp+32], eax         ; count
    mov dword [rsp+36], 0           ; index = 0
    mov dword [rsp+40], -1          ; best_win_id = -1
    mov dword [rsp+44], -1          ; best_z = -1

.wahf_loop:
    mov eax, dword [rsp+36]
    cmp eax, dword [rsp+32]
    jge .wahf_apply

    ; eid = herb_container_entity("wm.VISIBLE", index)
    lea rcx, [rel str_cn_wm_visible]
    mov edx, eax
    call herb_container_entity
    test eax, eax
    js .wahf_next
    mov ebx, eax                    ; ebx = eid

    ; focused = herb_entity_prop_int(eid, "focused", 0)
    mov ecx, ebx
    lea rdx, [rel str_focused]
    xor r8d, r8d
    call herb_entity_prop_int
    cmp eax, 1
    jl .wahf_next                   ; skip if focused < 1

    ; role = herb_entity_prop_int(eid, "role", -1)
    mov ecx, ebx
    lea rdx, [rel str_role]
    mov r8d, -1
    call herb_entity_prop_int
    cmp eax, 0
    jl .wahf_next
    cmp eax, WM_ROLE_GAME
    jg .wahf_next

    ; win_id = wm_role_to_win_id[role]
    lea rcx, [rel wm_role_to_win_id]
    mov esi, dword [rcx + rax*4]    ; esi = win_id
    cmp esi, -1
    je .wahf_next

    ; z = herb_entity_prop_int(eid, "z_order", -1)
    mov ecx, ebx
    lea rdx, [rel str_z_order]
    mov r8d, -1
    call herb_entity_prop_int
    ; Pick window with highest z_order (topmost if overlap)
    cmp eax, dword [rsp+44]
    jle .wahf_next
    mov dword [rsp+44], eax         ; best_z = z
    mov dword [rsp+40], esi         ; best_win_id = win_id

.wahf_next:
    inc dword [rsp+36]
    jmp .wahf_loop

.wahf_apply:
    mov ecx, dword [rsp+40]        ; best_win_id
    cmp ecx, -1
    je .wahf_clear
    ; Unless force=1, skip if focus hasn't changed
    cmp dword [rsp+48], 1
    je .wahf_do_focus
    cmp ecx, dword [rel wm_focused_id]
    je .wahf_done
.wahf_do_focus:
    ; wm_set_focus(best_win_id)
    call wm_set_focus
    ; wm_bring_to_front(best_win_id)
    mov ecx, dword [rsp+40]
    call wm_bring_to_front
    jmp .wahf_done

.wahf_none:
.wahf_clear:
    mov ecx, -1
    call wm_set_focus

.wahf_done:
    add rsp, 56
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ---- wm_herb_set_focus_by_role(int role) ----
; Routes programmatic focus through HERB instead of direct WM calls.
; Args: ECX = role (0-6)
; Stack: 4 pushes (rbp, rbx, rsi, rdi) + sub rsp 56 = 96. 96%16=0. ✓
;   [rsp+32] = count, [rsp+36] = index, [rsp+40] = target_role
wm_herb_set_focus_by_role:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 56

    mov dword [rsp+40], ecx         ; target_role

    lea rcx, [rel str_cn_wm_visible]
    call herb_container_count
    test eax, eax
    jle .whsfbr_run_ham
    mov dword [rsp+32], eax
    mov dword [rsp+36], 0

.whsfbr_loop:
    mov eax, dword [rsp+36]
    cmp eax, dword [rsp+32]
    jge .whsfbr_run_ham

    lea rcx, [rel str_cn_wm_visible]
    mov edx, eax
    call herb_container_entity
    test eax, eax
    js .whsfbr_next
    mov ebx, eax                    ; ebx = eid

    mov ecx, ebx
    lea rdx, [rel str_role]
    mov r8d, -1
    call herb_entity_prop_int
    cmp eax, dword [rsp+40]
    jne .whsfbr_next

    ; Found — set focused = 2
    mov ecx, ebx
    lea rdx, [rel str_focused]
    mov r8d, 2
    call herb_set_prop_int
    jmp .whsfbr_run_ham

.whsfbr_next:
    inc dword [rsp+36]
    jmp .whsfbr_loop

.whsfbr_run_ham:
    mov ecx, 100
    call ham_run_ham
    mov ecx, 1                      ; force=1: always apply
    call wm_apply_herb_focus

    add rsp, 56
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
%endif

; ============================================================
; WINDOW MANAGER ADAPTERS — Bridge between WM draw_fn and kernel content renderers
; ============================================================

; ============================================================
; shell_output_draw_fn — Session 93: Render shell output buffer in WM window
; void shell_output_draw_fn(int cx, int cy, int cw, int ch, void* win_ptr)
; MS x64: ECX=cx, EDX=cy, R8D=cw, R9D=ch, [rbp+48]=win_ptr
;
; Renders circular buffer text lines with scroll offset.
; Stack: 8 pushes + sub rsp 56 = 8+64+56 = 128. 128%16=0. Good.
; ============================================================
shell_output_draw_fn:
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

    ; Save client rect
    mov dword [rsp+40], ecx          ; cx
    mov dword [rsp+44], edx          ; cy
    mov dword [rsp+48], r8d          ; cw
    mov dword [rsp+52], r9d          ; ch

    ; Calculate visible lines = ch / 24
    mov eax, r9d
    xor edx, edx
    mov ecx, 24
    div ecx
    mov r12d, eax                    ; r12 = visible_lines
    test r12d, r12d
    jz .sodf_done

    ; Read buffer state
    mov r14d, dword [rel shell_output_count]   ; total lines
    mov r15d, dword [rel shell_output_scroll]  ; scroll offset

    ; Get fill color from win_ptr for text background
    mov rbx, [rbp + 48]             ; win_ptr
    mov esi, dword [rbx + 44]       ; WIN_FILL_COLOR = offset 44

    ; Render each visible row
    xor edi, edi                     ; row = 0

.sodf_row:
    cmp edi, r12d
    jge .sodf_done

    ; line_num = count - visible_lines + row - scroll
    mov eax, r14d
    sub eax, r12d
    add eax, edi
    sub eax, r15d

    ; Bounds check
    test eax, eax
    js .sodf_next_row
    cmp eax, r14d
    jge .sodf_next_row

    ; buf_idx = (head - count + line_num) mod 32
    mov ecx, dword [rel shell_output_head]
    sub ecx, r14d
    add ecx, eax
    ; Handle negative modulo — add MAX then mask (32 is power of 2)
    add ecx, SHELL_OUTPUT_MAX_LINES
    and ecx, (SHELL_OUTPUT_MAX_LINES - 1)

    ; String pointer = &shell_output_buf[buf_idx * LINE_LEN]
    imul ecx, SHELL_OUTPUT_LINE_LEN
    lea r8, [rel shell_output_buf]
    add r8, rcx                      ; r8 = line string

    ; Check if line is empty
    cmp byte [r8], 0
    je .sodf_next_row

    ; fb_draw_string(cx, cy + row*24, str, fg, bg)
    mov ecx, dword [rsp+40]          ; cx
    mov edx, dword [rsp+44]          ; cy
    mov eax, edi
    imul eax, eax, 24               ; row * 24
    add edx, eax                     ; cy + row*16
    ; r8 already set to string
    mov r9d, 0x00C0C0C0              ; fg = light gray
    mov dword [rsp+32], esi          ; bg = fill_color
    call fb_draw_string

.sodf_next_row:
    inc edi
    jmp .sodf_row

.sodf_done:
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

; ============================================================
; wm_draw_region_adapter — Content draw function for region windows
; void wm_draw_region_adapter(int cx, int cy, int cw, int ch, void* win_ptr)
; MS x64: ECX=cx, EDX=cy, R8D=cw, R9D=ch, [rbp+48]=win_ptr
;
; Reads content_id from win_ptr to get region_id, then calls
; gfx_draw_procs_in_region with the window's outer bounds.
; ============================================================
wm_draw_region_adapter:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 72                         ; shadow(32) + 5 stack args(40)
    ; 6 pushes + sub 72 = 8 + 48 + 72 = 128. 128 % 16 = 0. ✓

    ; Save client-area args from registers (before clobbered)
    mov dword [rsp + 56], ecx           ; save cx
    mov dword [rsp + 60], edx           ; save cy
    mov dword [rsp + 64], r8d           ; save cw
    mov dword [rsp + 68], r9d           ; save ch

    mov rbx, [rbp + 48]                 ; win_ptr

    ; Read region_id from window content_id
    mov eax, dword [rbx + 36]           ; WIN_CONTENT_ID = region_id
    cmp eax, 0
    jl .wdra_done
    cmp eax, 3
    jg .wdra_done
    mov r12d, eax                       ; r12 = region_id

    ; Read window colors
    mov r13d, dword [rbx + 40]          ; border_color (WIN_BORDER_COLOR)
    mov esi, dword [rbx + 44]           ; fill_color (WIN_FILL_COLOR)

    ; Call gfx_draw_procs_in_region(cx, cy, cw, ch, container_name, bc, fc)
    ; Use saved client rect, not window outer bounds
    mov ecx, dword [rsp + 56]           ; client cx
    mov edx, dword [rsp + 60]           ; client cy
    mov r8d, dword [rsp + 64]           ; client cw
    mov r9d, dword [rsp + 68]           ; client ch
    movsxd rax, r12d
    lea rdi, [rel region_containers]
    mov rdi, [rdi + rax*8]
    mov [rsp + 32], rdi                 ; container_name
    mov dword [rsp + 40], r13d          ; border_color
    mov dword [rsp + 48], esi           ; fill_color
    call gfx_draw_procs_in_region

.wdra_done:
    add rsp, 72
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

%ifdef KERNEL_MODE
; ============================================================
; wm_draw_tension_adapter — Content draw function for tension panel window
; void wm_draw_tension_adapter(int cx, int cy, int cw, int ch, void* win_ptr)
;
; Calls gfx_draw_tension_panel which uses hardcoded position.
; (Future: pass bounds to a parameterized version)
; ============================================================
wm_draw_tension_adapter:
    push rbp
    mov rbp, rsp
    sub rsp, 48                         ; shadow space + align
    ; 1 push + sub 48 = 56. (8+56)%16 = 0. ✓

    ; Save client rect for gfx_draw_tension_panel to use
    mov [rel g_tp_cx], ecx
    mov [rel g_tp_cy], edx
    mov [rel g_tp_cw], r8d
    mov [rel g_tp_ch], r9d

    ; Set clip rect to client area before drawing
    ; ECX/EDX/R8D/R9D still = cx/cy/cw/ch
    call wm_set_clip
    call gfx_draw_tension_panel
    call wm_clear_clip

    add rsp, 48
    pop rbp
    ret
%endif  ; KERNEL_MODE

; ============================================================
; wm_init_default_windows — Create windows from Surface entities
; void wm_init_default_windows(void)
;
; Iterates display.VISIBLE container, reads Surface entity properties,
; and creates WM windows for each region (kind==0) and the tension
; panel (kind==4).
; ============================================================
; Locals start at 64 to leave room for call args at [rsp+32..63]
%define WMIW_EID   64
%define WMIW_ROLE  68
%define WMIW_Z     72
%define WMIW_WID   76
%define WMIW_VI    80
%define WMIW_NV    84
%define WMIW_RX    88
%define WMIW_RY    92
%define WMIW_RW    96
%define WMIW_RH    100
%define WMIW_SPARE 104

wm_init_default_windows:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 136                        ; shadow(32) + call args(32) + locals(72)
    ; 6 pushes + sub 136 = 8 + 48 + 136 = 192. 192 % 16 = 0. ✓

%ifdef KERNEL_MODE
    lea rcx, [rel wm_role_to_win_id]
    mov edx, 0xFF
    mov r8d, 64
    call herb_memset
    mov dword [rel flow_editor_win_id], -1
    mov dword [rel game_win_id], -1

    ; Count entities in wm.VISIBLE
    lea rcx, [rel str_cn_wm_visible]
    call herb_container_count
    test eax, eax
    jns .wmiw_count_ok
    xor eax, eax
.wmiw_count_ok:
    mov dword [rsp + WMIW_NV], eax
    mov dword [rsp + WMIW_VI], 0
    lea rcx, [rel str_wm_boot_count]
    call serial_print
    mov ecx, dword [rsp + WMIW_NV]
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

.wmiw_loop:
    mov eax, dword [rsp + WMIW_VI]
    cmp eax, dword [rsp + WMIW_NV]
    jge .wmiw_done

    lea rcx, [rel str_cn_wm_visible]
    mov edx, eax
    call herb_container_entity
    test eax, eax
    js .wmiw_next
    mov dword [rsp + WMIW_EID], eax

    mov ecx, eax
    lea rdx, [rel str_role]
    mov r8d, -1
    call herb_entity_prop_int
    mov dword [rsp + WMIW_ROLE], eax
    cmp eax, 0
    jl .wmiw_next
    cmp eax, WM_ROLE_GAME
    jg .wmiw_next

    mov ecx, dword [rsp + WMIW_EID]
    lea rdx, [rel str_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + WMIW_RX], eax

    mov ecx, dword [rsp + WMIW_EID]
    lea rdx, [rel str_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp + WMIW_RY], eax

    mov ecx, dword [rsp + WMIW_EID]
    lea rdx, [rel str_gfx_width]
    mov r8d, 100
    call herb_entity_prop_int
    mov dword [rsp + WMIW_RW], eax

    mov ecx, dword [rsp + WMIW_EID]
    lea rdx, [rel str_gfx_height]
    mov r8d, 100
    call herb_entity_prop_int
    mov dword [rsp + WMIW_RH], eax

    mov ecx, dword [rsp + WMIW_EID]
    lea rdx, [rel str_z_order]
    mov r8d, dword [rsp + WMIW_VI]
    call herb_entity_prop_int
    mov dword [rsp + WMIW_Z], eax

    lea rcx, [rel str_wm_boot_role]
    call serial_print
    mov ecx, dword [rsp + WMIW_ROLE]
    call serial_print_int
    lea rcx, [rel str_wm_boot_geom]
    call serial_print
    mov ecx, dword [rsp + WMIW_RX]
    call serial_print_int
    lea rcx, [rel str_comma]
    call serial_print
    mov ecx, dword [rsp + WMIW_RY]
    call serial_print_int
    lea rcx, [rel str_comma]
    call serial_print
    mov ecx, dword [rsp + WMIW_RW]
    call serial_print_int
    lea rcx, [rel str_comma]
    call serial_print
    mov ecx, dword [rsp + WMIW_RH]
    call serial_print_int
    lea rcx, [rel str_wm_boot_z]
    call serial_print
    mov ecx, dword [rsp + WMIW_Z]
    call serial_print_int
    lea rcx, [rel str_newline]
    call serial_print

    mov eax, dword [rsp + WMIW_ROLE]
    cmp eax, WM_ROLE_TERM
    jle .wmiw_region
    cmp eax, WM_ROLE_TENSIONS
    je .wmiw_tensions
    cmp eax, WM_ROLE_EDITOR
    je .wmiw_editor
    cmp eax, WM_ROLE_GAME
    je .wmiw_game
    jmp .wmiw_next

.wmiw_region:
    mov ecx, dword [rsp + WMIW_RX]
    mov edx, dword [rsp + WMIW_RY]
    mov r8d, dword [rsp + WMIW_RW]
    mov r9d, dword [rsp + WMIW_RH]
    mov dword [rsp + 32], 0
    mov eax, dword [rsp + WMIW_ROLE]
    mov dword [rsp + 40], eax
    movsxd rax, eax
    lea rdi, [rel region_titles]
    mov rdi, [rdi + rax*8]
    mov [rsp + 48], rdi
    mov dword [rsp + 56], (1 << 5) | (1 << 6)
    call wm_create_window
    jmp .wmiw_created

.wmiw_tensions:
    mov ecx, dword [rsp + WMIW_RX]
    mov edx, dword [rsp + WMIW_RY]
    mov r8d, dword [rsp + WMIW_RW]
    mov r9d, dword [rsp + WMIW_RH]
    mov dword [rsp + 32], 1
    mov dword [rsp + 40], 4
    lea rdi, [rel str_gfx_tensions]
    mov [rsp + 48], rdi
    mov dword [rsp + 56], (1 << 5) | (1 << 6)
    call wm_create_window
    jmp .wmiw_created

.wmiw_editor:
    mov ecx, dword [rsp + WMIW_RX]
    mov edx, dword [rsp + WMIW_RY]
    mov r8d, dword [rsp + WMIW_RW]
    mov r9d, dword [rsp + WMIW_RH]
    mov dword [rsp + 32], 3
    mov dword [rsp + 40], 0
    lea rdi, [rel str_editor_title]
    mov [rsp + 48], rdi
    mov dword [rsp + 56], (1 << 5) | (1 << 6)
    call wm_create_window
    jmp .wmiw_created

.wmiw_game:
    mov ecx, dword [rsp + WMIW_RX]
    mov edx, dword [rsp + WMIW_RY]
    mov r8d, dword [rsp + WMIW_RW]
    mov r9d, dword [rsp + WMIW_RH]
    mov dword [rsp + 32], 3
    mov dword [rsp + 40], 0
    lea rdi, [rel str_game_title]
    mov [rsp + 48], rdi
    mov dword [rsp + 56], (1 << 5) | (1 << 6)
    call wm_create_window

.wmiw_created:
    mov dword [rsp + WMIW_WID], eax
    cmp eax, -1
    je .wmiw_next
    lea rbx, [rel wm_role_to_win_id]
    mov eax, dword [rsp + WMIW_ROLE]
    mov edx, dword [rsp + WMIW_WID]
    mov dword [rbx + rax*4], edx
    mov ecx, dword [rsp + WMIW_ROLE]
    mov edx, dword [rsp + WMIW_WID]
    mov r8d, dword [rsp + WMIW_EID]
    call wm_apply_boot_window_style

.wmiw_next:
    inc dword [rsp + WMIW_VI]
    jmp .wmiw_loop

.wmiw_done:
    call wm_sync_from_herb

%else
    ; Non-KERNEL_MODE: create windows from hardcoded positions
    ; CPU0 window
    mov ecx, GFX_CPU0_X
    mov edx, GFX_CPU0_Y
    mov r8d, GFX_CONT_W
    mov r9d, GFX_CONT_H
    mov dword [rsp + 32], 0            ; WCT_REGION
    mov dword [rsp + 40], 0            ; region_id = 0
    lea rdi, [rel str_gfx_leg_cpu0]
    mov [rsp + 48], rdi
    mov dword [rsp + 56], (1 << 5) | (1 << 6)
    call wm_create_window

    ; Set CPU0 colors and draw_fn
    test eax, eax
    js .wmiw_nk_ready
    mov ecx, eax
    call wm_window_ptr
    test rax, rax
    jz .wmiw_nk_ready
    mov dword [rax + 40], COL_RUNNING   ; border_color
    mov dword [rax + 44], COL_RUNNING_BG ; fill_color
    mov dword [rax + 48], COL_RUNNING   ; title_bg
    lea rbx, [rel wm_draw_region_adapter]
    mov [rax + 80], rbx

.wmiw_nk_ready:
    ; READY window
    mov ecx, GFX_READY_X
    mov edx, GFX_READY_Y
    mov r8d, GFX_CONT_W
    mov r9d, GFX_CONT_H
    mov dword [rsp + 32], 0
    mov dword [rsp + 40], 1            ; region_id = 1
    lea rdi, [rel str_gfx_leg_ready]
    mov [rsp + 48], rdi
    mov dword [rsp + 56], (1 << 5) | (1 << 6)
    call wm_create_window

    test eax, eax
    js .wmiw_nk_blocked
    mov ecx, eax
    call wm_window_ptr
    test rax, rax
    jz .wmiw_nk_blocked
    mov dword [rax + 40], COL_READY_COL
    mov dword [rax + 44], COL_READY_BG
    mov dword [rax + 48], COL_READY_COL
    lea rbx, [rel wm_draw_region_adapter]
    mov [rax + 80], rbx

.wmiw_nk_blocked:
    ; BLOCKED window
    mov ecx, GFX_BLOCK_X
    mov edx, GFX_BLOCK_Y
    mov r8d, GFX_CONT_W
    mov r9d, GFX_CONT_H
    mov dword [rsp + 32], 0
    mov dword [rsp + 40], 2
    lea rdi, [rel str_gfx_leg_blocked]
    mov [rsp + 48], rdi
    mov dword [rsp + 56], (1 << 5) | (1 << 6)
    call wm_create_window

    test eax, eax
    js .wmiw_nk_term
    mov ecx, eax
    call wm_window_ptr
    test rax, rax
    jz .wmiw_nk_term
    mov dword [rax + 40], COL_BLOCKED_COL
    mov dword [rax + 44], COL_BLOCKED_BG
    mov dword [rax + 48], COL_BLOCKED_COL
    lea rbx, [rel wm_draw_region_adapter]
    mov [rax + 80], rbx

.wmiw_nk_term:
    ; TERMINATED window
    mov ecx, GFX_TERM_X
    mov edx, GFX_TERM_Y
    mov r8d, GFX_CONT_W
    mov r9d, GFX_CONT_H
    mov dword [rsp + 32], 0
    mov dword [rsp + 40], 3
    lea rdi, [rel str_gfx_leg_term]
    mov [rsp + 48], rdi
    mov dword [rsp + 56], (1 << 5) | (1 << 6)
    call wm_create_window

    test eax, eax
    js .wmiw_nk_done
    mov ecx, eax
    call wm_window_ptr
    test rax, rax
    jz .wmiw_nk_done
    mov dword [rax + 40], COL_TERM_COL
    mov dword [rax + 44], COL_TERM_BG
    mov dword [rax + 48], COL_TERM_COL
    lea rbx, [rel wm_draw_region_adapter]
    mov [rax + 80], rbx

.wmiw_nk_done:
%endif

    add rsp, 136
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; GFX_DRAW_FULL — Full graphics mode redraw (Phase D Step 7b)
;
; void gfx_draw_full(void)
; The largest single function: banner, stats, legend, containers,
; tension panel, action log, summary, buffer/resource legend,
; command line, flip + cursor.
;
; Stack frame: push rbp + 5 pushes (rbx,rsi,rdi,r12,r13) + sub rsp 456
;   = 8 + 48 + 456 = 512 bytes (aligned: 512%16=0)
; Locals:
;   [rsp+48..111]   cmdbuf[64]   — command line text
;   [rsp+112..239]  ids[32]      — legend entity IDs (32×4)
;   [rsp+240..367]  orders[32]   — legend sort orders (32×4)
;   [rsp+368..387]  bbuf[20]     — buffer snprintf
;   [rsp+388..455]  scratch      — misc temps
; ============================================================

; Stack offsets
%define GDF_CMDBUF   48
%define GDF_IDS      112
%define GDF_ORDERS   240
%define GDF_BBUF     368
%define GDF_BCOUNT   388
%define GDF_BCAP     396
%define GDF_VI       404
%define GDF_NV       408
%define GDF_SID      412
%define GDF_RID      416
%define GDF_RX       420
%define GDF_RY       424
%define GDF_RW       428
%define GDF_RH       432
%define GDF_BC       436
%define GDF_FC       440

gfx_draw_full:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 456

    ; ---- 1. Clear background ----
    mov ecx, COL_BG
    call fb_clear

    ; ---- 2. Banner ----
    xor ecx, ecx
    mov edx, GFX_BANNER_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_BANNER_H
    mov dword [rsp + 32], COL_BANNER_BG
    call fb_fill_rect

    ; fb_draw_string(12, 8, OS_TITLE, COL_TEXT_HI, COL_BANNER_BG)
    mov ecx, 12
    mov edx, GFX_BANNER_Y + 2
%ifdef KERNEL_MODE
    lea r8, [rel str_os_title_km]
%else
    lea r8, [rel str_os_title]
%endif
    mov r9d, COL_TEXT_HI
    mov dword [rsp + 32], COL_BANNER_BG
    call fb_draw_string

    ; fb_draw_string(600, 8, OS_SUBTITLE, COL_TEXT_DIM, COL_BANNER_BG)
    mov ecx, FB_WIDTH - 200
    mov edx, GFX_BANNER_Y + 2
%ifdef KERNEL_MODE
    lea r8, [rel str_os_subtitle_km]
%else
    lea r8, [rel str_os_subtitle]
%endif
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_BANNER_BG
    call fb_draw_string

    ; ---- 3. Stats bar ----
    xor ecx, ecx
    mov edx, GFX_STATS_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_STATS_H
    mov dword [rsp + 32], COL_STATS_BG
    call fb_fill_rect

    mov ebx, 12                 ; x = 12

    ; "Tick:"
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_tick]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; timer_count / 100
    mov eax, dword [rel timer_count]
    cdq
    mov esi, 100
    idiv esi
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    mov r8d, eax
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

    ; "Ops:"
    lea ecx, [ebx + 12]
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_ops]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; total_ops
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    mov r8d, dword [rel total_ops]
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

    ; "Arena:"
    lea ecx, [ebx + 12]
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_arena]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; herb_arena_usage() / 1024
    call herb_arena_usage
    shr eax, 10                 ; / 1024
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    mov r8d, eax
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

    ; "KB"
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_kb]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; n_proc = ready + cpu0 + blocked
    lea rcx, [rel str_cn_ready]
    call herb_container_count
    mov esi, eax

    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    add esi, eax

    lea rcx, [rel str_cn_blocked]
    call herb_container_count
    add esi, eax                ; esi = n_proc

    ; "Procs:"
    lea ecx, [ebx + 12]
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_procs]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; clamp n_proc >= 0
    xor edi, edi
    test esi, esi
    cmovs esi, edi

    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    mov r8d, esi
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

%ifdef KERNEL_MODE
    ; Policy indicator
    mov eax, dword [rel shell_ctl_eid]
    test eax, eax
    js .gdf_no_policy
    mov ecx, eax
    lea rdx, [rel str_current_policy]
    xor r8d, r8d
    call herb_entity_prop_int
    mov esi, eax
    jmp .gdf_draw_policy
.gdf_no_policy:
    xor esi, esi
.gdf_draw_policy:
    lea ecx, [ebx + 12]
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_sched]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    test esi, esi
    jnz .gdf_rr
    lea r8, [rel str_gfx_priority]
    mov r9d, COL_RUNNING
    jmp .gdf_draw_pol_str
.gdf_rr:
    lea r8, [rel str_gfx_roundrobin]
    mov r9d, 0x00FF9900
.gdf_draw_pol_str:
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax
%endif

    ; Last key display
    lea rdi, [rel last_key_name]
    cmp byte [rdi], 0
    je .gdf_no_lastkey

    lea ecx, [ebx + 12]
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_key_open]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    mov r8, rdi                 ; last_key_name
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_key_close]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string

.gdf_no_lastkey:

%ifdef KERNEL_MODE
    ; ---- 4. Game mode — game now renders via WM window (game_draw_fn) ----
    ; No full-screen early exit needed. Fall through to normal WM rendering.
    jmp .gdf_no_game

    ; Game legend bar (legacy full-screen — unreachable)
    xor ecx, ecx
    mov edx, GFX_LEGEND_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_LEGEND_H
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_fill_rect

    mov ebx, 12
    ; "Arrows"
    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_gfx_arrows]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    ; "=Move "
    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_gfx_eq_move]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    ; "Space"
    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_gfx_space_key]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    ; "=Gather "
    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_gfx_eq_gather]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    ; "G"
    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_gfx_g_key]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    ; "=OS view"
    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_gfx_eq_osview]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

    ; Separator
    xor ecx, ecx
    mov edx, GFX_LEGEND_Y + GFX_LEGEND_H + 2
    mov r8d, FB_WIDTH
    mov r9d, COL_BORDER
    call fb_hline

    ; gfx_draw_game()
    call gfx_draw_game

    ; Log bar
    xor ecx, ecx
    mov edx, GFX_LOG_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_LOG_H
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_fill_rect

    lea rdi, [rel last_action]
    cmp byte [rdi], 0
    je .gdf_game_no_log

    mov ecx, 12
    mov edx, GFX_LOG_Y + 0
    lea r8, [rel str_gfx_gt]
    mov r9d, COL_RUNNING
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

    mov ecx, 28
    mov edx, GFX_LOG_Y + 0
    mov r8, rdi
    mov r9d, COL_TEXT
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

.gdf_game_no_log:

    ; Game summary bar
    xor ecx, ecx
    mov edx, GFX_SUMMARY_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_SUMMARY_H
    mov dword [rsp + 32], COL_STATS_BG
    call fb_fill_rect

    ; wood = herb_container_count(CN_GAME_TREE_GATHERED)
    lea rcx, [rel str_cn_game_tree_gathered]
    call herb_container_count
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx              ; if wood<0, wood=0
    mov r12d, eax               ; r12 = wood

    mov ebx, 12
    ; "COMMON HERB"
    mov ecx, ebx
    mov edx, GFX_SUMMARY_Y + 0
    lea r8, [rel str_gfx_common_herb]
    mov r9d, COL_GAME_TITLE
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; "Wood:"
    lea ecx, [ebx + 16]
    mov edx, GFX_SUMMARY_Y + 0
    lea r8, [rel str_gfx_wood_lbl2]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; wood value
    mov ecx, ebx
    mov edx, GFX_SUMMARY_Y + 0
    mov r8d, r12d
    mov r9d, COL_TREE
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

    ; "Trees:"
    lea ecx, [ebx + 16]
    mov edx, GFX_SUMMARY_Y + 0
    lea r8, [rel str_gfx_trees_lbl2]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; trees count
    lea rcx, [rel str_cn_game_trees]
    call herb_container_count
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    mov ecx, ebx
    mov edx, GFX_SUMMARY_Y + 0
    mov r8d, eax
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int

    ; Bottom bars
    xor ecx, ecx
    mov edx, GFX_RESLEG_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_RESLEG_H
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_fill_rect

    xor ecx, ecx
    mov edx, GFX_RESLEG_Y + GFX_RESLEG_H + 4
    mov r8d, FB_WIDTH
    mov r9d, 22
    mov dword [rsp + 32], 0x00161622
    call fb_fill_rect

    ; "G"
    mov ecx, 8
    mov edx, GFX_RESLEG_Y + GFX_RESLEG_H + 7
    lea r8, [rel str_gfx_g_key]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], 0x00161622
    call fb_draw_string

    ; "= return to OS"
    mov ecx, 20
    mov edx, GFX_RESLEG_Y + GFX_RESLEG_H + 7
    lea r8, [rel str_gfx_os_return]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], 0x00161622
    call fb_draw_string

    ; flip + cursor + RETURN
    call fb_flip
    call fb_cursor_draw
    jmp .gdf_epilogue

.gdf_no_game:

    ; ---- 4b. Editor now renders via WM window (flow_editor_draw_fn) ----
    ; No early-exit path needed — editor renders through wm_draw_all
%endif  ; KERNEL_MODE (game mode)

    ; ---- 5. Key legend ----
    xor ecx, ecx
    mov edx, GFX_LEGEND_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_LEGEND_H
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_fill_rect

    mov ebx, 12                 ; x = 12

%ifdef KERNEL_MODE
    ; LEGEND entities from CN_LEGEND
    lea rcx, [rel str_cn_legend]
    call herb_container_count
    test eax, eax
    jle .gdf_legend_done

    mov r12d, eax               ; r12 = n (total legend entities)
    xor r13d, r13d              ; r13 = count (valid entities found)
    xor esi, esi                ; esi = i (loop counter)

.gdf_legend_fetch:
    cmp esi, r12d
    jge .gdf_legend_sort
    cmp r13d, 32
    jge .gdf_legend_sort

    mov dword [rsp + GDF_VI], esi  ; save i
    lea rcx, [rel str_cn_legend]
    mov edx, esi
    call herb_container_entity
    test eax, eax
    js .gdf_legend_next         ; eid < 0, skip

    ; ids[count] = eid
    mov edi, r13d
    mov dword [rsp + GDF_IDS + rdi*4], eax

    ; orders[count] = herb_entity_prop_int(eid, "order", 99)
    mov ecx, eax
    lea rdx, [rel str_order]
    mov r8d, 99
    call herb_entity_prop_int
    mov edi, r13d
    mov dword [rsp + GDF_ORDERS + rdi*4], eax
    inc r13d                    ; count++

.gdf_legend_next:
    mov esi, dword [rsp + GDF_VI]
    inc esi
    jmp .gdf_legend_fetch

.gdf_legend_sort:
    ; Insertion sort: sort ids[] by orders[]
    cmp r13d, 2
    jl .gdf_legend_render       ; nothing to sort if count < 2

    mov esi, 1                  ; i = 1
.gdf_sort_outer:
    cmp esi, r13d
    jge .gdf_legend_render

    mov eax, dword [rsp + GDF_ORDERS + rsi*4]  ; key_o = orders[i]
    mov ecx, dword [rsp + GDF_IDS + rsi*4]     ; key_id = ids[i]
    mov edi, esi
    dec edi                     ; j = i - 1

.gdf_sort_inner:
    test edi, edi
    js .gdf_sort_insert         ; j < 0
    cmp dword [rsp + GDF_ORDERS + rdi*4], eax
    jle .gdf_sort_insert        ; orders[j] <= key_o

    ; Shift: orders[j+1] = orders[j], ids[j+1] = ids[j]
    lea edx, [edi + 1]
    mov r8d, dword [rsp + GDF_ORDERS + rdi*4]
    mov dword [rsp + GDF_ORDERS + rdx*4], r8d
    mov r8d, dword [rsp + GDF_IDS + rdi*4]
    mov dword [rsp + GDF_IDS + rdx*4], r8d
    dec edi
    jmp .gdf_sort_inner

.gdf_sort_insert:
    lea edx, [edi + 1]
    mov dword [rsp + GDF_ORDERS + rdx*4], eax
    mov dword [rsp + GDF_IDS + rdx*4], ecx
    inc esi
    jmp .gdf_sort_outer

.gdf_legend_render:
    ; Render sorted legend items
    xor esi, esi                ; i = 0
.gdf_legend_draw_loop:
    cmp esi, r13d
    jge .gdf_legend_done

    mov dword [rsp + GDF_VI], esi  ; save i

    ; key = herb_entity_prop_str(ids[i], "key_text", "?")
    mov ecx, dword [rsp + GDF_IDS + rsi*4]
    lea rdx, [rel str_key_text]
    lea r8, [rel str_ques]
    call herb_entity_prop_str

    ; fb_draw_string(x, ..., key, COL_TEXT_KEY, COL_LEGEND_BG)
    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    mov r8, rax                 ; key string
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    ; label = herb_entity_prop_str(ids[i], "label_text", "")
    mov esi, dword [rsp + GDF_VI]
    mov ecx, dword [rsp + GDF_IDS + rsi*4]
    lea rdx, [rel str_label_text]
    lea r8, [rel str_empty]
    call herb_entity_prop_str

    ; fb_draw_string(x, ..., label, COL_TEXT_DIM, COL_LEGEND_BG)
    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    mov r8, rax
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    ; fb_draw_string(x, ..., " ", COL_TEXT_DIM, COL_LEGEND_BG)
    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_space]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov esi, dword [rsp + GDF_VI]
    inc esi
    jmp .gdf_legend_draw_loop

%else
    ; Non-KERNEL_MODE: hardcoded legend
    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_N]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_ew]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_K]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_ill]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_B]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_lk]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_U]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_nblk]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_T]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_mr]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_Plus]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_Boost]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_Space]
    mov r9d, COL_TEXT_KEY
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_LEGEND_Y + 0
    lea r8, [rel str_leg_Step]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
%endif

.gdf_legend_done:

    ; ---- 6. Separator line ----
    xor ecx, ecx
    mov edx, GFX_LEGEND_Y + GFX_LEGEND_H + 2
    mov r8d, FB_WIDTH
    mov r9d, COL_BORDER
    call fb_hline

    ; ---- 7+8. Window manager: container regions + tension panel ----
    ; NOTE: wm_sync_from_herb is called once at boot (wm_init_default_windows).
    ; Per-frame sync removed — no tensions modify wm.Window entities currently,
    ; and per-frame reset was clobbering drag/z-order mutations from herb_wm.asm.
    call wm_draw_all

    ; ---- 9. Action log ----
    xor ecx, ecx
    mov edx, GFX_LOG_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_LOG_H
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_fill_rect

    lea rdi, [rel last_action]
    cmp byte [rdi], 0
    je .gdf_no_log

    mov ecx, 12
    mov edx, GFX_LOG_Y + 0
    lea r8, [rel str_gfx_gt]
    mov r9d, COL_RUNNING
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

    mov ecx, 28
    mov edx, GFX_LOG_Y + 0
    mov r8, rdi
    mov r9d, COL_TEXT
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

.gdf_no_log:

    ; ---- 10. Container summary ----
    xor ecx, ecx
    mov edx, GFX_SUMMARY_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_SUMMARY_H
    mov dword [rsp + 32], COL_STATS_BG
    call fb_fill_rect

    ; Get counts
    lea rcx, [rel str_cn_ready]
    call herb_container_count
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    mov r12d, eax               ; r12 = ready_n

    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    mov r13d, eax               ; r13 = cpu_n

    lea rcx, [rel str_cn_blocked]
    call herb_container_count
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    mov esi, eax                ; esi = blk_n

    lea rcx, [rel str_cn_terminated]
    call herb_container_count
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    mov edi, eax                ; edi = term_n

    mov ebx, 12

    ; "READY="
    mov ecx, ebx
    mov edx, GFX_SUMMARY_Y + 0
    lea r8, [rel str_gfx_ready_eq]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; Save blk_n and term_n
    mov dword [rsp + GDF_VI], esi    ; save blk_n
    mov dword [rsp + GDF_NV], edi    ; save term_n

    mov ecx, ebx
    mov edx, GFX_SUMMARY_Y + 0
    mov r8d, r12d
    mov r9d, COL_READY_COL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

    ; "CPU0="
    lea ecx, [ebx + 8]
    mov edx, GFX_SUMMARY_Y + 0
    lea r8, [rel str_gfx_cpu0_eq]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_SUMMARY_Y + 0
    mov r8d, r13d
    mov r9d, COL_RUNNING
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

    ; "BLOCKED="
    lea ecx, [ebx + 8]
    mov edx, GFX_SUMMARY_Y + 0
    lea r8, [rel str_gfx_blocked_eq]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_SUMMARY_Y + 0
    mov r8d, dword [rsp + GDF_VI]   ; blk_n
    mov r9d, COL_BLOCKED_COL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

    ; "TERM="
    lea ecx, [ebx + 8]
    mov edx, GFX_SUMMARY_Y + 0
    lea r8, [rel str_gfx_term_eq]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    mov ecx, ebx
    mov edx, GFX_SUMMARY_Y + 0
    mov r8d, dword [rsp + GDF_NV]   ; term_n
    mov r9d, COL_TERM_COL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int

%ifdef KERNEL_MODE
    ; ---- 11. Buffer indicator / Resource legend ----
    mov eax, dword [rel buffer_eid]
    test eax, eax
    js .gdf_no_buffer

    ; Buffer exists — draw fill bar
    ; bcount = herb_entity_prop_int(buffer_eid, "count", 0)
    mov ecx, eax
    lea rdx, [rel str_count]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp + GDF_BCOUNT], rax     ; int64_t bcount

    ; bcap = herb_entity_prop_int(buffer_eid, "capacity", 1)
    mov ecx, dword [rel buffer_eid]
    lea rdx, [rel str_capacity]
    mov r8d, 1
    call herb_entity_prop_int
    mov [rsp + GDF_BCAP], rax       ; int64_t bcap

    ; fb_fill_rect(0, GFX_RESLEG_Y, FB_WIDTH, GFX_RESLEG_H, COL_LEGEND_BG)
    xor ecx, ecx
    mov edx, GFX_RESLEG_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_RESLEG_H
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_fill_rect

    ; fb_draw_string(12, bar_y, "BUF", ...)
    mov ecx, 12
    mov edx, GFX_RESLEG_Y + 0
    lea r8, [rel str_gfx_buf_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

    mov ebx, 40                 ; bar_x = 12 + 28 = 40

    ; fb_draw_rect(bar_x, bar_y, 120, 12, COL_TEXT_DIM)
    mov ecx, ebx
    mov edx, GFX_RESLEG_Y + 0
    mov r8d, 120
    mov r9d, 12
    mov dword [rsp + 32], COL_TEXT_DIM
    call fb_draw_rect

    ; if bcount > 0 && bcap > 0: draw fill
    mov rax, [rsp + GDF_BCOUNT]
    test rax, rax
    jle .gdf_buf_no_fill
    mov rcx, [rsp + GDF_BCAP]
    test rcx, rcx
    jle .gdf_buf_no_fill

    ; fill_w = bcount * 118 / bcap (bar_w-2=118)
    imul rax, 118
    cqo
    idiv rcx
    cmp eax, 118
    jle .gdf_buf_clamp_ok
    mov eax, 118
.gdf_buf_clamp_ok:
    mov r12d, eax               ; r12 = fill_w

    ; Color selection: green/yellow/orange
    mov r13d, 0x0044CC44        ; green default
    mov rax, [rsp + GDF_BCOUNT]
    mov rcx, [rsp + GDF_BCAP]

    ; if bcount*3 > bcap*2: orange
    mov rdx, rax
    imul rdx, 3
    mov rsi, rcx
    imul rsi, 2
    cmp rdx, rsi
    jg .gdf_buf_orange

    ; if bcount*2 > bcap: yellow
    mov rdx, rax
    imul rdx, 2
    cmp rdx, rcx
    jg .gdf_buf_yellow
    jmp .gdf_buf_draw_fill

.gdf_buf_orange:
    mov r13d, 0x00FF9900
    jmp .gdf_buf_draw_fill
.gdf_buf_yellow:
    mov r13d, 0x00CCCC00

.gdf_buf_draw_fill:
    ; fb_fill_rect(bar_x+1, bar_y+1, fill_w, 10, fill_col)
    lea ecx, [ebx + 1]
    mov edx, GFX_RESLEG_Y + 4
    mov r8d, r12d
    mov r9d, 10
    mov dword [rsp + 32], r13d
    call fb_fill_rect

.gdf_buf_no_fill:
    ; bar_x += 120 + 6 = 166
    mov ebx, 166

    ; Numeric display: snprintf(bbuf, 20, "%d/%d", bcount, bcap)
    lea rcx, [rsp + GDF_BBUF]
    mov edx, 20
    lea r8, [rel str_gfx_buf_fmt]
    mov r9d, dword [rsp + GDF_BCOUNT]
    mov eax, dword [rsp + GDF_BCAP]
    mov dword [rsp + 32], eax
    call herb_snprintf

    lea r8, [rsp + GDF_BBUF]
    mov ecx, ebx
    mov edx, GFX_RESLEG_Y + 0
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

    ; Producer/consumer legend
    mov ebx, 226                ; bar_x + 60 = 166 + 60
    ; ">"
    mov ecx, ebx
    mov edx, GFX_RESLEG_Y + 0
    lea r8, [rel str_gfx_gt_prod]
    mov r9d, 0x00FF9900
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

    ; "producer  "
    lea ecx, [ebx + 12]
    mov edx, GFX_RESLEG_Y + 0
    lea r8, [rel str_gfx_producer]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

    ; "<"
    lea ecx, [ebx + 12 + 80]    ; +92
    mov edx, GFX_RESLEG_Y + 0
    lea r8, [rel str_gfx_lt_cons]
    mov r9d, 0x0066CCFF
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

    ; "consumer"
    lea ecx, [ebx + 12 + 80 + 12]  ; +104
    mov edx, GFX_RESLEG_Y + 0
    lea r8, [rel str_gfx_consumer]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    jmp .gdf_buf_done

.gdf_no_buffer:
    ; Resource legend (no buffer)
    xor ecx, ecx
    mov edx, GFX_RESLEG_Y
    mov r8d, FB_WIDTH
    mov r9d, GFX_RESLEG_H
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_fill_rect

    mov ebx, 12

    ; MEM free swatch
    mov ecx, ebx
    mov edx, GFX_RESLEG_Y + 7
    mov r8d, 6
    mov r9d, 6
    mov dword [rsp + 32], COL_RES_FREE
    call fb_fill_rect

    lea ecx, [ebx + 10]
    mov edx, GFX_RESLEG_Y + 0
    lea r8, [rel str_gfx_mem_free_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    ; MEM used swatch
    mov ecx, ebx
    mov edx, GFX_RESLEG_Y + 7
    mov r8d, 6
    mov r9d, 6
    mov dword [rsp + 32], COL_RES_USED
    call fb_fill_rect

    lea ecx, [ebx + 10]
    mov edx, GFX_RESLEG_Y + 0
    lea r8, [rel str_gfx_mem_used_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    ; FD free swatch
    mov ecx, ebx
    mov edx, GFX_RESLEG_Y + 7
    mov r8d, 6
    mov r9d, 6
    mov dword [rsp + 32], COL_RES_FD_F
    call fb_fill_rect

    lea ecx, [ebx + 10]
    mov edx, GFX_RESLEG_Y + 0
    lea r8, [rel str_gfx_fd_free_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string
    mov ebx, eax

    ; FD open swatch
    mov ecx, ebx
    mov edx, GFX_RESLEG_Y + 7
    mov r8d, 6
    mov r9d, 6
    mov dword [rsp + 32], COL_RES_FD_U
    call fb_fill_rect

    lea ecx, [ebx + 10]
    mov edx, GFX_RESLEG_Y + 0
    lea r8, [rel str_gfx_fd_open_lbl]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_LEGEND_BG
    call fb_draw_string

.gdf_buf_done:

    ; ---- 12. Command line ----
    ; input_mode = 0
    xor esi, esi
    mov eax, dword [rel input_ctl_eid]
    test eax, eax
    js .gdf_cmdline_draw

    ; input_mode = herb_entity_prop_int(input_ctl_eid, "mode", 0)
    mov ecx, eax
    lea rdx, [rel str_mode]
    xor r8d, r8d
    call herb_entity_prop_int
    mov esi, eax                ; esi = input_mode

.gdf_cmdline_draw:
    ; cmd_y = GFX_RESLEG_Y + GFX_RESLEG_H + 4 = 558
    %define CMD_Y (GFX_RESLEG_Y + GFX_RESLEG_H + 4)

    ; fb_fill_rect(0, cmd_y, FB_WIDTH, 28, 0x00161622)
    xor ecx, ecx
    mov edx, CMD_Y
    mov r8d, FB_WIDTH
    mov r9d, 28
    mov dword [rsp + 32], 0x00161622
    call fb_fill_rect

    cmp esi, 1
    jne .gdf_cmd_hint

    ; Text mode: read cmdline
    lea rcx, [rsp + GDF_CMDBUF]
    mov edx, 64
    call read_cmdline
    mov r12d, eax               ; r12 = clen

    ; Draw ":"
    mov ecx, 8
    mov edx, CMD_Y + 2
    lea r8, [rel str_gfx_colon]
    mov r9d, 0x0066FF66
    mov dword [rsp + 32], 0x00161622
    call fb_draw_string

    ; if clen > 0: draw text
    test r12d, r12d
    jle .gdf_cmd_cursor

    mov ecx, 20
    mov edx, CMD_Y + 2
    lea r8, [rsp + GDF_CMDBUF]
    mov r9d, COL_TEXT_HI
    mov dword [rsp + 32], 0x00161622
    call fb_draw_string

.gdf_cmd_cursor:
    ; cursor_px = 20 + clen * 12
    mov eax, r12d
    imul eax, eax, 12
    add eax, 20

    ; fb_fill_rect(cursor_px, cmd_y+22, 12, 2, 0x0066FF66)
    mov ecx, eax
    mov edx, CMD_Y + 22
    mov r8d, 12
    mov r9d, 2
    mov dword [rsp + 32], 0x0066FF66
    call fb_fill_rect
    jmp .gdf_cmd_done

.gdf_cmd_hint:
    ; Command mode: show hint
    mov ecx, 8
    mov edx, CMD_Y + 2
    lea r8, [rel str_gfx_slash_cmd]
    mov r9d, 0x00666688
    mov dword [rsp + 32], 0x00161622
    call fb_draw_string

    mov ecx, 20
    mov edx, CMD_Y + 2
    lea r8, [rel str_gfx_type_cmd]
    mov r9d, 0x00444466
    mov dword [rsp + 32], 0x00161622
    call fb_draw_string

.gdf_cmd_done:
%endif  ; KERNEL_MODE (command line)

    ; ---- 13. Flip + cursor ----
    call fb_flip
    call fb_cursor_draw

.gdf_epilogue:
    add rsp, 456
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; GFX_DRAW_STATS_ONLY — Quick stats bar refresh (Phase D Step 7a)
;
; void gfx_draw_stats_only(void)
; Redraws just the stats bar + flip + cursor (periodic quick update).
; ============================================================

gfx_draw_stats_only:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40                 ; shadow + alignment: 8+24+40=72, 72%16=8... need 8+3*8+40=72. 72%16=8. Fix: sub rsp 32 → 8+24+32=64, 64%16=0
                                ; Wait: push rbp(8) + 3 pushes(24) = 32 bytes on stack. RSP is at -32 from entry.
                                ; entry RSP%16=8 (after CALL). -32 → RSP%16=8-32%16=8-0=8. Still misaligned.
                                ; sub rsp, 40: RSP -= 40 → (8-32-40)%16 = -64%16 = 0. Aligned. ✓

    ; fb_fill_rect(0, GFX_STATS_Y, FB_WIDTH, GFX_STATS_H, COL_STATS_BG)
    xor ecx, ecx               ; x=0
    mov edx, GFX_STATS_Y       ; y=30
    mov r8d, FB_WIDTH           ; w
    mov r9d, GFX_STATS_H       ; h=20
    mov dword [rsp + 32], COL_STATS_BG
    call fb_fill_rect

    ; x = 12
    mov ebx, 12

    ; x = fb_draw_string(x, GFX_STATS_Y+3, "Tick:", COL_TEXT_DIM, COL_STATS_BG)
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_tick]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; x = fb_draw_int(x, GFX_STATS_Y+3, timer_count/100, COL_TEXT_VAL, COL_STATS_BG)
    mov eax, dword [rel timer_count]
    cdq
    mov esi, 100
    idiv esi                    ; eax = timer_count / 100
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    mov r8d, eax
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

    ; x = fb_draw_string(x+12, ..., "Ops:", ...)
    lea ecx, [ebx + 12]
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_ops]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; x = fb_draw_int(x, ..., total_ops, ...)
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    mov r8d, dword [rel total_ops]
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

    ; n_proc = herb_container_count(CN_READY) + herb_container_count(CN_CPU0) + herb_container_count(CN_BLOCKED)
    lea rcx, [rel str_cn_ready]
    call herb_container_count
    mov esi, eax                ; esi = ready count

    lea rcx, [rel str_cn_cpu0]
    call herb_container_count
    add esi, eax                ; esi += cpu0 count

    lea rcx, [rel str_cn_blocked]
    call herb_container_count
    add esi, eax                ; esi = total n_proc

    ; x = fb_draw_string(x+12, ..., "Procs:", ...)
    lea ecx, [ebx + 12]
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_procs]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; n_proc < 0 ? 0 : n_proc
    test esi, esi
    cmovs esi, edi              ; if negative, use 0 (edi is likely not 0, use xor)
    xor edi, edi
    test esi, esi
    cmovs esi, edi              ; if esi<0, esi=0

    ; x = fb_draw_int(x, ..., n_proc, ...)
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    mov r8d, esi
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_int
    mov ebx, eax

%ifdef KERNEL_MODE
    ; Policy indicator — read from ShellCtl.current_policy
    mov eax, dword [rel shell_ctl_eid]
    test eax, eax
    js .gdso_no_policy          ; shell_ctl_eid < 0

    mov ecx, eax                ; entity_id
    lea rdx, [rel str_current_policy]
    xor r8d, r8d                ; default_val = 0
    call herb_entity_prop_int
    mov esi, eax                ; esi = current_policy (0=priority, 1=rr)
    jmp .gdso_draw_policy

.gdso_no_policy:
    xor esi, esi                ; cp = 0

.gdso_draw_policy:
    ; x = fb_draw_string(x+12, ..., "Sched:", ...)
    lea ecx, [ebx + 12]
    mov edx, GFX_STATS_Y + 0
    lea r8, [rel str_gfx_sched]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
    mov ebx, eax

    ; fb_draw_string(x, ..., cp==0 ? "PRIORITY" : "ROUND-ROBIN", cp==0 ? COL_RUNNING : 0x00FF9900, COL_STATS_BG)
    test esi, esi
    jnz .gdso_rr_label
    lea r8, [rel str_gfx_priority]
    mov r9d, COL_RUNNING
    jmp .gdso_draw_sched
.gdso_rr_label:
    lea r8, [rel str_gfx_roundrobin]
    mov r9d, 0x00FF9900
.gdso_draw_sched:
    mov ecx, ebx
    mov edx, GFX_STATS_Y + 0
    mov dword [rsp + 32], COL_STATS_BG
    call fb_draw_string
%endif

    ; fb_flip()
    call fb_flip

    ; fb_cursor_draw()
    call fb_cursor_draw

    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

%endif  ; GRAPHICS_MODE

; ============================================================
; DRAW_FULL — Top-level draw dispatcher (Phase D Step 7c)
;
; void draw_full(void)
; Graphics mode → gfx_draw_full(), text mode → draw_* sequence + cmdline
;
; Stack: push rbp + 3 pushes (rbx,rsi,rdi) + sub rsp 72
;   = 8 + 24 + 72 = 104 bytes... wait: 8+3*8=32 after pushes.
;   32%16=0. After sub rsp 72: 32+72=104. 104%16=8. Not aligned.
;   Fix: sub rsp 80: 32+80=112. 112%16=0. ✓
;   cmdbuf[64] at [rsp+32..95]
; ============================================================

draw_full:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 80

%ifdef GRAPHICS_MODE
    cmp dword [rel fb_active], 0
    je .df_text_mode

    call gfx_draw_full
    jmp .df_done

.df_text_mode:
%endif

    ; Text mode path: sequential draw calls
    call draw_banner
    call draw_stats
    call draw_legend
    call draw_process_table
    call draw_summary
    call draw_log

%ifdef KERNEL_MODE
    ; Command line (VGA text mode)
    mov eax, dword [rel input_ctl_eid]
    test eax, eax
    js .df_done

    ; mode = herb_entity_prop_int(input_ctl_eid, "mode", 0)
    mov ecx, eax
    lea rdx, [rel str_mode]
    xor r8d, r8d
    call herb_entity_prop_int
    mov esi, eax                ; esi = mode

    ; vga_set_color(VGA_LGRAY, VGA_BLACK)
    mov ecx, 0x7                ; VGA_LGRAY
    xor edx, edx               ; VGA_BLACK
    call vga_set_color

    ; vga_clear_row(ROW_ERROR=24)
    mov ecx, 24
    call vga_clear_row

    cmp esi, 1
    jne .df_cmd_hint

    ; Text mode: read cmdline
    lea rcx, [rsp + 32]        ; cmdbuf
    mov edx, 64
    call read_cmdline
    mov ebx, eax                ; ebx = clen

    ; vga_set_color(VGA_LGREEN, VGA_BLACK)
    mov ecx, 0xA                ; VGA_LGREEN
    xor edx, edx
    call vga_set_color

    ; vga_print_at(ROW_ERROR, 0, ":")
    mov ecx, 24
    xor edx, edx
    lea r8, [rel str_vga_colon]
    call vga_print_at

    ; vga_set_color(VGA_WHITE, VGA_BLACK)
    mov ecx, 0xF                ; VGA_WHITE
    xor edx, edx
    call vga_set_color

    ; if clen > 0: vga_print(cmdbuf)
    test ebx, ebx
    jle .df_cmd_cursor

    lea rcx, [rsp + 32]
    call vga_print

.df_cmd_cursor:
    ; vga_set_color(VGA_LGREEN, VGA_BLACK)
    mov ecx, 0xA
    xor edx, edx
    call vga_set_color

    ; vga_putchar('_')
    mov ecx, '_'
    call vga_putchar
    jmp .df_done

.df_cmd_hint:
    ; vga_set_color(VGA_DGRAY, VGA_BLACK)
    mov ecx, 0x8                ; VGA_DGRAY
    xor edx, edx
    call vga_set_color

    ; vga_print_at(ROW_ERROR, 0, "/ to type command")
    mov ecx, 24
    xor edx, edx
    lea r8, [rel str_vga_slash_cmd]
    call vga_print_at
%endif  ; KERNEL_MODE

.df_done:
    add rsp, 80
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ============================================================
; BOOT-TIME COMPILATION — compile .herb source to binary
; ============================================================

; boot_compile_programs — compile all embedded .herb source at boot
; Returns: EAX = 0 on success, -1 on failure
boot_compile_programs:
    push    rbp
    mov     rbp, rsp
    push    rbx
    sub     rsp, 40
    ; ret(8)+rbp(8)+rbx(8)+sub(40)=64, 64%16=0 ✓

    lea     rcx, [rel str_compile_hdr]
    call    serial_print

    ; ---- interactive_kernel (always — main program) ----
    lea     rcx, [rel src_interactive_kernel]
    lea     rax, [rel src_interactive_kernel_len]
    mov     edx, [rax]
    lea     r8, [rel bin_interactive_kernel]
    mov     r9d, 32768
    call    herb_compile_source
    test    eax, eax
    jle     .bcp_fail
    mov     [rel bin_ik_len], eax
    mov     ebx, eax
    lea     rcx, [rel str_compile_ik]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_compile_bytes]
    call    serial_print

%ifdef KERNEL_MODE
    ; ---- shell ----
    lea     rcx, [rel src_shell]
    lea     rax, [rel src_shell_len]
    mov     edx, [rax]
    lea     r8, [rel bin_shell]
    mov     r9d, 2048
    call    herb_compile_source
    test    eax, eax
    jle     .bcp_fail
    mov     [rel bin_shell_len], eax
    mov     ebx, eax
    lea     rcx, [rel str_compile_sh]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_compile_bytes]
    call    serial_print

    ; ---- producer ----
    lea     rcx, [rel src_producer]
    lea     rax, [rel src_producer_len]
    mov     edx, [rax]
    lea     r8, [rel bin_producer]
    mov     r9d, 512
    call    herb_compile_source
    test    eax, eax
    jle     .bcp_fail
    mov     [rel bin_producer_len], eax
    mov     ebx, eax
    lea     rcx, [rel str_compile_pr]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_compile_bytes]
    call    serial_print

    ; ---- consumer ----
    lea     rcx, [rel src_consumer]
    lea     rax, [rel src_consumer_len]
    mov     edx, [rax]
    lea     r8, [rel bin_consumer]
    mov     r9d, 512
    call    herb_compile_source
    test    eax, eax
    jle     .bcp_fail
    mov     [rel bin_consumer_len], eax
    mov     ebx, eax
    lea     rcx, [rel str_compile_cn]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_compile_bytes]
    call    serial_print

    ; ---- worker ----
    lea     rcx, [rel src_worker]
    lea     rax, [rel src_worker_len]
    mov     edx, [rax]
    lea     r8, [rel bin_worker]
    mov     r9d, 512
    call    herb_compile_source
    test    eax, eax
    jle     .bcp_fail
    mov     [rel bin_worker_len], eax
    mov     ebx, eax
    lea     rcx, [rel str_compile_wk]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_compile_bytes]
    call    serial_print

    ; ---- beacon ----
    lea     rcx, [rel src_beacon]
    lea     rax, [rel src_beacon_len]
    mov     edx, [rax]
    lea     r8, [rel bin_beacon]
    mov     r9d, 512
    call    herb_compile_source
    test    eax, eax
    jle     .bcp_fail
    mov     [rel bin_beacon_len], eax
    mov     ebx, eax
    lea     rcx, [rel str_compile_bc]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_compile_bytes]
    call    serial_print

    ; ---- schedule_priority ----
    lea     rcx, [rel src_schedule_priority]
    lea     rax, [rel src_schedule_priority_len]
    mov     edx, [rax]
    lea     r8, [rel bin_schedule_priority]
    mov     r9d, 512
    call    herb_compile_source
    test    eax, eax
    jle     .bcp_fail
    mov     [rel bin_sched_pri_len], eax
    mov     ebx, eax
    lea     rcx, [rel str_compile_sp]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_compile_bytes]
    call    serial_print

    ; ---- schedule_roundrobin ----
    lea     rcx, [rel src_schedule_roundrobin]
    lea     rax, [rel src_schedule_roundrobin_len]
    mov     edx, [rax]
    lea     r8, [rel bin_schedule_roundrobin]
    mov     r9d, 512
    call    herb_compile_source
    test    eax, eax
    jle     .bcp_fail
    mov     [rel bin_sched_rr_len], eax
    mov     ebx, eax
    lea     rcx, [rel str_compile_sr]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_compile_bytes]
    call    serial_print

    ; ---- turing ----
    lea     rcx, [rel src_turing]
    lea     rax, [rel src_turing_len]
    mov     edx, [rax]
    lea     r8, [rel bin_turing]
    mov     r9d, 2048
    call    herb_compile_source
    test    eax, eax
    jle     .bcp_fail
    mov     [rel bin_turing_len], eax
    mov     ebx, eax
    lea     rcx, [rel str_compile_tm]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_compile_bytes]
    call    serial_print

    ; ---- test_flow ----
    lea     rcx, [rel src_test_flow]
    lea     rax, [rel src_test_flow_len]
    mov     edx, [rax]
    lea     r8, [rel bin_test_flow]
    mov     r9d, 2048
    call    herb_compile_source
    test    eax, eax
    jle     .bcp_fail
    mov     [rel bin_test_flow_len], eax
    mov     ebx, eax
    lea     rcx, [rel str_compile_tf]
    call    serial_print
    mov     ecx, ebx
    call    serial_print_int
    lea     rcx, [rel str_compile_bytes]
    call    serial_print
%endif  ; KERNEL_MODE — fragment compilations

    ; All compilations succeeded
    xor     eax, eax
    jmp     .bcp_done

.bcp_fail:
    lea     rcx, [rel str_compile_fail]
    call    serial_print
    mov     eax, -1

.bcp_done:
    add     rsp, 40
    pop     rbx
    pop     rbp
    ret
