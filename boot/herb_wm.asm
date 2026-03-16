; boot/herb_wm.asm — HERB OS Window Manager
;
; Provides overlapping, draggable, resizable windows for the HERB OS desktop.
; Assembly handles data structures, rendering, hit testing, drag/resize.
; HERB tensions handle policy (focus rules, placement) in later phases.
;
; Architecture:
;   - Flat array of 16 window structs (128 bytes each) in BSS
;   - Separate z_order array for painter's algorithm compositing
;   - Content draw functions called via function pointer per window
;
; Assembled with: nasm -f win64 herb_wm.asm
; MS x64 ABI: RCX/RDX/R8/R9 args, 32-byte shadow, RAX return
; Callee-saved: RBX, RSI, RDI, R12-R15, RBP

[bits 64]
default rel

; ============================================================
; EXTERNS
; ============================================================

; Framebuffer drawing primitives (from herb_hw.asm)
extern fb_fill_rect
extern fb_draw_rect
extern fb_draw_rect2
extern fb_draw_string
extern fb_draw_char
extern fb_draw_container

; Utility (from herb_freestanding.asm)
extern herb_snprintf
extern herb_memset
%ifdef GRAPHICS_MODE
extern wm_write_window_geometry_to_herb
extern wm_write_all_z_order_to_herb
%endif

; ============================================================
; CONSTANTS
; ============================================================

; Screen dimensions (must match herb_hw.asm FB_WIDTH/FB_HEIGHT)
WM_SCREEN_W         equ 1280
WM_SCREEN_H         equ 800

; Window array limits
WM_MAX_WINDOWS      equ 16
WM_WIN_SIZE         equ 128

; Window struct field offsets
WIN_ID              equ 0       ; dd — -1=free, 0..15=active
WIN_FLAGS           equ 4       ; dd — bitfield
WIN_X               equ 8       ; dd — top-left X
WIN_Y               equ 12      ; dd — top-left Y
WIN_W               equ 16      ; dd — total width (incl borders)
WIN_H               equ 20      ; dd — total height (incl titlebar+borders)
WIN_MIN_W           equ 24      ; dd — minimum resize width
WIN_MIN_H           equ 28      ; dd — minimum resize height
WIN_CONTENT_TYPE    equ 32      ; dd — REGION=0, TENSIONS=1, STATS=2, CUSTOM=3
WIN_CONTENT_ID      equ 36      ; dd — region_id or future identifier
WIN_BORDER_COLOR    equ 40      ; dd — 32-bit color
WIN_FILL_COLOR      equ 44      ; dd — client area background
WIN_TITLE_BG        equ 48      ; dd — title bar color
WIN_ENTITY_ID       equ 52      ; dd — HERB wm.Window entity ID (-1 if none)
WIN_TITLE_PTR       equ 56      ; dq — pointer to title string
WIN_RESTORE_X       equ 64      ; dd — saved X before maximize
WIN_RESTORE_Y       equ 68      ; dd — saved Y before maximize
WIN_RESTORE_W       equ 72      ; dd — saved W before maximize
WIN_RESTORE_H       equ 76      ; dd — saved H before maximize
WIN_DRAW_FN         equ 80      ; dq — content draw function pointer
WIN_SCROLL_Y        equ 88      ; dd — vertical scroll offset
WIN_DIRTY           equ 92      ; dd — 1 = needs content redraw
; 96..127 = reserved

; Window flags (bit positions)
WF_VISIBLE          equ 0
WF_FOCUSED          equ 1
WF_MAXIMIZED        equ 2
WF_DRAGGING         equ 3
WF_RESIZING         equ 4
WF_CLOSABLE         equ 5
WF_RESIZABLE        equ 6

; Content types
WCT_REGION          equ 0
WCT_TENSIONS        equ 1
WCT_STATS           equ 2
WCT_CUSTOM          equ 3

; Visual constants
WM_TITLEBAR_H       equ 22      ; title bar height in pixels
WM_BORDER           equ 2       ; border thickness in pixels
WM_BTN_SIZE         equ 18      ; close/maximize button size
WM_RESIZE_HANDLE    equ 12      ; resize handle size
WM_SHADOW_OFFSET    equ 2       ; shadow offset in pixels

; Hit test regions
HIT_NONE            equ 0
HIT_CLOSE           equ 1
HIT_MAXIMIZE        equ 2
HIT_TITLEBAR        equ 3
HIT_RESIZE          equ 4
HIT_CLIENT          equ 5

; Drag modes
DRAG_NONE           equ 0
DRAG_MOVE           equ 1
DRAG_RESIZE         equ 2

; Colors
COL_WM_SHADOW       equ 0x00080808
COL_WM_FOCUS_RING   equ 0x0066CCFF
COL_WM_TITLE_TEXT   equ 0x00FFFFFF
COL_WM_BTN_CLOSE    equ 0x00CC4444
COL_WM_BTN_MAX      equ 0x0044AA44
COL_WM_BTN_BG       equ 0x00222222

; ============================================================
; GLOBALS
; ============================================================

global wm_init
global wm_create_window
global wm_destroy_window
global wm_window_ptr
global wm_draw_all
global wm_draw_window_frame
global wm_hit_test
global wm_bring_to_front
global wm_set_focus
global wm_begin_drag
global wm_update_drag
global wm_end_drag
global wm_init_default_windows

; Expose BSS state for herb_kernel.asm
global wm_windows
global wm_z_order
global wm_window_count
global wm_focused_id
global wm_drag_mode
global wm_drag_win_id
global wm_drag_offset_x
global wm_drag_offset_y

; ============================================================
; BSS — Window manager state
; ============================================================

section .bss

alignb 16
wm_windows:         resb WM_MAX_WINDOWS * WM_WIN_SIZE  ; 2048 bytes
wm_z_order:         resb WM_MAX_WINDOWS                 ; 16 bytes
alignb 4
wm_window_count:    resd 1          ; number of active windows
wm_focused_id:      resd 1          ; id of focused window (-1 = none)
wm_drag_mode:       resd 1          ; DRAG_NONE / DRAG_MOVE / DRAG_RESIZE
wm_drag_win_id:     resd 1          ; window being dragged (-1 = none)
wm_drag_offset_x:   resd 1          ; mouse offset from window origin at drag start
wm_drag_offset_y:   resd 1          ; mouse offset from window origin at drag start
wm_drag_start_w:    resd 1          ; window width at resize start
wm_drag_start_h:    resd 1          ; window height at resize start
wm_drag_start_mx:   resd 1          ; mouse X at resize start
wm_drag_start_my:   resd 1          ; mouse Y at resize start

; ============================================================
; RDATA — String constants
; ============================================================

section .rdata

str_wm_close_x:     db "X", 0
str_wm_max:         db "+", 0

; ============================================================
; CODE
; ============================================================

section .text

; ============================================================
; wm_init — Initialize window manager state
; void wm_init(void)
;
; Zeros all window structs, sets all IDs to -1, clears z_order,
; resets counters and drag state.
; ============================================================
wm_init:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 32                         ; shadow space
    ; 3 pushes + sub 32 = 8 + 24 + 32 = 64. 64 % 16 = 0. ✓

    ; Zero the entire wm_windows array (2048 bytes)
    lea rcx, [rel wm_windows]
    xor edx, edx                        ; fill = 0
    mov r8d, WM_MAX_WINDOWS * WM_WIN_SIZE ; 2048
    call herb_memset

    ; Set all window IDs to -1 (marks as free)
    lea rbx, [rel wm_windows]
    xor esi, esi                        ; i = 0
.init_id_loop:
    cmp esi, WM_MAX_WINDOWS
    jge .init_id_done
    mov dword [rbx + WIN_ID], -1
    add rbx, WM_WIN_SIZE
    inc esi
    jmp .init_id_loop
.init_id_done:

    ; Zero z_order array
    lea rcx, [rel wm_z_order]
    xor edx, edx
    mov r8d, WM_MAX_WINDOWS
    call herb_memset

    ; Reset counters
    mov dword [rel wm_window_count], 0
    mov dword [rel wm_focused_id], -1

    ; Reset drag state
    mov dword [rel wm_drag_mode], DRAG_NONE
    mov dword [rel wm_drag_win_id], -1
    mov dword [rel wm_drag_offset_x], 0
    mov dword [rel wm_drag_offset_y], 0
    mov dword [rel wm_drag_start_w], 0
    mov dword [rel wm_drag_start_h], 0
    mov dword [rel wm_drag_start_mx], 0
    mov dword [rel wm_drag_start_my], 0

    add rsp, 32
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; wm_window_ptr — Get pointer to window struct by ID
; void* wm_window_ptr(int win_id)
; MS x64: ECX=win_id
; Returns: RAX = pointer to wm_windows[win_id], or 0 if invalid
; ============================================================
wm_window_ptr:
    ; No stack frame needed — leaf, no calls
    cmp ecx, 0
    jl .wptr_invalid
    cmp ecx, WM_MAX_WINDOWS
    jge .wptr_invalid

    movsxd rax, ecx
    imul rax, WM_WIN_SIZE               ; offset = win_id * 128
    lea rcx, [rel wm_windows]
    add rax, rcx
    ret

.wptr_invalid:
    xor eax, eax
    ret

; ============================================================
; wm_create_window — Create a new window
; int wm_create_window(int x, int y, int w, int h,
;                      int type, int content_id,
;                      const char* title, int flags)
; MS x64: ECX=x, EDX=y, R8D=w, R9D=h
;         [rbp+48]=type, [rbp+56]=content_id
;         [rbp+64]=title, [rbp+72]=flags
; Returns: EAX = window id (0..15), or -1 if full
; ============================================================
wm_create_window:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40                         ; shadow(32) + 8(align)
    ; 8 pushes + sub 40 = 8 + 64 + 40 = 112. 112 % 16 = 0. ✓

    ; Save args
    mov r12d, ecx                       ; x
    mov r13d, edx                       ; y
    mov r14d, r8d                       ; w
    mov r15d, r9d                       ; h

    ; Find first free slot
    lea rbx, [rel wm_windows]
    xor esi, esi                        ; i = 0
.cw_find_loop:
    cmp esi, WM_MAX_WINDOWS
    jge .cw_full
    cmp dword [rbx + WIN_ID], -1
    je .cw_found
    add rbx, WM_WIN_SIZE
    inc esi
    jmp .cw_find_loop

.cw_full:
    mov eax, -1
    jmp .cw_done

.cw_found:
    ; rbx = pointer to free slot, esi = slot index (= win_id)
    mov dword [rbx + WIN_ID], esi
    mov eax, dword [rbp + 72]           ; flags
    or eax, (1 << WF_VISIBLE)           ; always start visible
    mov dword [rbx + WIN_FLAGS], eax
    mov dword [rbx + WIN_X], r12d
    mov dword [rbx + WIN_Y], r13d
    mov dword [rbx + WIN_W], r14d
    mov dword [rbx + WIN_H], r15d
    mov dword [rbx + WIN_MIN_W], 120
    mov dword [rbx + WIN_MIN_H], 80
    mov eax, dword [rbp + 48]           ; type
    mov dword [rbx + WIN_CONTENT_TYPE], eax
    mov eax, dword [rbp + 56]           ; content_id
    mov dword [rbx + WIN_CONTENT_ID], eax
    ; Default: border_color = title_bg_color = 0x336688, fill_color = 0x0C1018
    mov dword [rbx + WIN_BORDER_COLOR], 0x00336688
    mov dword [rbx + WIN_FILL_COLOR], 0x000C1018
    mov dword [rbx + WIN_TITLE_BG], 0x00336688
    mov dword [rbx + WIN_ENTITY_ID], -1
    mov rax, [rbp + 64]                 ; title pointer
    mov [rbx + WIN_TITLE_PTR], rax
    mov dword [rbx + WIN_RESTORE_X], 0
    mov dword [rbx + WIN_RESTORE_Y], 0
    mov dword [rbx + WIN_RESTORE_W], 0
    mov dword [rbx + WIN_RESTORE_H], 0
    mov qword [rbx + WIN_DRAW_FN], 0
    mov dword [rbx + WIN_SCROLL_Y], 0
    mov dword [rbx + WIN_DIRTY], 1

    ; Add to z_order (append at top = index wm_window_count)
    mov eax, dword [rel wm_window_count]
    cmp eax, WM_MAX_WINDOWS
    jge .cw_full                        ; safety
    lea rcx, [rel wm_z_order]
    mov byte [rcx + rax], sil           ; z_order[count] = win_id
    inc eax
    mov dword [rel wm_window_count], eax

    mov eax, esi                        ; return win_id

.cw_done:
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
; wm_destroy_window — Destroy a window by ID
; void wm_destroy_window(int win_id)
; MS x64: ECX=win_id
; ============================================================
wm_destroy_window:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40                         ; shadow(32) + 8(align)
    ; 4 pushes + sub 40 = 8 + 32 + 40 = 80. 80 % 16 = 0. ✓

    mov edi, ecx                        ; save win_id

    ; Get window pointer
    call wm_window_ptr
    test rax, rax
    jz .dw_done
    mov rbx, rax

    ; Check it's active
    cmp dword [rbx + WIN_ID], -1
    je .dw_done

    ; Mark as free
    mov dword [rbx + WIN_ID], -1
    mov dword [rbx + WIN_FLAGS], 0

    ; Remove from z_order array (shift elements down)
    lea rsi, [rel wm_z_order]
    mov ecx, dword [rel wm_window_count]
    test ecx, ecx
    jz .dw_done

    ; Find this win_id in z_order
    xor edx, edx                        ; i = 0
.dw_z_find:
    cmp edx, ecx
    jge .dw_z_not_found
    movzx eax, byte [rsi + rdx]
    cmp eax, edi
    je .dw_z_found
    inc edx
    jmp .dw_z_find

.dw_z_found:
    ; Shift everything after index edx down by 1
    dec ecx                             ; new count
    mov dword [rel wm_window_count], ecx
.dw_z_shift:
    cmp edx, ecx
    jge .dw_z_shift_done
    movzx eax, byte [rsi + rdx + 1]
    mov byte [rsi + rdx], al
    inc edx
    jmp .dw_z_shift
.dw_z_shift_done:
    mov byte [rsi + rcx], 0             ; clear trailing byte

    ; If focused window was destroyed, clear focus
    cmp dword [rel wm_focused_id], edi
    jne .dw_done
    mov dword [rel wm_focused_id], -1

.dw_z_not_found:
.dw_done:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; wm_draw_window_frame — Draw a single window's frame (border, title bar, buttons)
; void wm_draw_window_frame(void* win_ptr)
; MS x64: RCX=win_ptr
;
; Draws: shadow, fill, border, title bar, title text, close/max buttons
; Does NOT draw content — that's done by draw_fn
; ============================================================
wm_draw_window_frame:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56                         ; shadow(32) + 3 stack args(24)
    ; 8 pushes + sub 56 = 8 + 64 + 56 = 128. 128 % 16 = 0. ✓

    mov rbx, rcx                        ; rbx = win_ptr

    ; Load window geometry into registers
    mov r12d, dword [rbx + WIN_X]       ; x
    mov r13d, dword [rbx + WIN_Y]       ; y
    mov r14d, dword [rbx + WIN_W]       ; w
    mov r15d, dword [rbx + WIN_H]       ; h
    mov esi, dword [rbx + WIN_BORDER_COLOR]
    mov edi, dword [rbx + WIN_FILL_COLOR]

    ; 0. Draw shadow (offset by 2px right and down)
    lea ecx, [r12d + WM_SHADOW_OFFSET]  ; x + 2
    lea edx, [r13d + WM_SHADOW_OFFSET]  ; y + 2
    mov r8d, r14d
    mov r9d, r15d
    mov dword [rsp + 32], COL_WM_SHADOW
    call fb_fill_rect

    ; 1. Fill client area background
    ;    fb_fill_rect(x, y, w, h, fill_color)
    mov ecx, r12d
    mov edx, r13d
    mov r8d, r14d
    mov r9d, r15d
    mov dword [rsp + 32], edi           ; fill_color
    call fb_fill_rect

    ; 2. Draw 2px border
    ;    fb_draw_rect2(x, y, w, h, border_color)
    mov ecx, r12d
    mov edx, r13d
    mov r8d, r14d
    mov r9d, r15d
    mov dword [rsp + 32], esi           ; border_color
    call fb_draw_rect2

    ; 3. Fill title bar
    ;    Title bar: inside the border, at (x+2, y+2, w-4, WM_TITLEBAR_H-2)
    ;    Using border_color as title bar background (matching existing container style)
    mov eax, dword [rbx + WIN_TITLE_BG]
    lea ecx, [r12d + WM_BORDER]         ; x + 2
    lea edx, [r13d + WM_BORDER]         ; y + 2
    mov r8d, r14d
    sub r8d, WM_BORDER * 2              ; w - 4
    mov r9d, WM_TITLEBAR_H - WM_BORDER  ; 20
    mov dword [rsp + 32], eax           ; title_bg color
    call fb_fill_rect

    ; 4. Draw title text
    ;    fb_draw_string(x+6, y+3, title, COL_WM_TITLE_TEXT, title_bg)
    mov rax, [rbx + WIN_TITLE_PTR]
    test rax, rax
    jz .wf_no_title
    lea ecx, [r12d + 6]                 ; x + 6
    lea edx, [r13d + 3]                 ; y + 3
    mov r8, rax                         ; title string
    mov r9d, COL_WM_TITLE_TEXT
    mov eax, dword [rbx + WIN_TITLE_BG]
    mov dword [rsp + 32], eax           ; bg color
    call fb_draw_string
.wf_no_title:

    ; 5. Draw close button (if WF_CLOSABLE)
    mov eax, dword [rbx + WIN_FLAGS]
    test eax, (1 << WF_CLOSABLE)
    jz .wf_no_close

    ; Close button: top-right corner of title bar
    ; Position: (x + w - border - btn_size - 2, y + 2, btn_size, btn_size)
    mov ecx, r12d
    add ecx, r14d
    sub ecx, WM_BORDER
    sub ecx, WM_BTN_SIZE
    sub ecx, 2                          ; x + w - 2 - 18 - 2
    lea edx, [r13d + WM_BORDER]         ; y + 2
    mov r8d, WM_BTN_SIZE
    mov r9d, WM_BTN_SIZE
    mov dword [rsp + 32], COL_WM_BTN_CLOSE
    call fb_fill_rect

    ; Draw "X" in the close button
    mov ecx, r12d
    add ecx, r14d
    sub ecx, WM_BORDER
    sub ecx, WM_BTN_SIZE
    add ecx, 3                          ; center the X
    lea edx, [r13d + WM_BORDER + 1]
    lea r8, [rel str_wm_close_x]
    mov r9d, COL_WM_TITLE_TEXT
    mov dword [rsp + 32], COL_WM_BTN_CLOSE
    call fb_draw_string

.wf_no_close:

    ; 6. Draw maximize button (if WF_RESIZABLE, next to close)
    mov eax, dword [rbx + WIN_FLAGS]
    test eax, (1 << WF_RESIZABLE)
    jz .wf_no_max

    ; Maximize button: left of close button
    mov ecx, r12d
    add ecx, r14d
    sub ecx, WM_BORDER
    sub ecx, WM_BTN_SIZE
    sub ecx, WM_BTN_SIZE
    sub ecx, 4                          ; 2 gap before close + 2 border
    lea edx, [r13d + WM_BORDER]
    mov r8d, WM_BTN_SIZE
    mov r9d, WM_BTN_SIZE
    mov dword [rsp + 32], COL_WM_BTN_MAX
    call fb_fill_rect

.wf_no_max:

    ; 6b. Draw resize handle (bottom-right corner, if WF_RESIZABLE)
    ;     Three short diagonal lines as grip indicator
    mov eax, dword [rbx + WIN_FLAGS]
    test eax, (1 << WF_RESIZABLE)
    jz .wf_no_grip

    ; Draw 3 small diagonal dots/lines in bottom-right
    ; Line 1: (x+w-4, y+h-4) to (x+w-4, y+h-4) — single pixel area
    mov ecx, r12d
    add ecx, r14d
    sub ecx, 5                          ; x + w - 5
    mov edx, r13d
    add edx, r15d
    sub edx, 5                          ; y + h - 5
    mov r8d, 3                          ; small rect
    mov r9d, 1
    mov dword [rsp + 32], 0x00666666
    call fb_fill_rect

    ; Line 2
    mov ecx, r12d
    add ecx, r14d
    sub ecx, 9
    mov edx, r13d
    add edx, r15d
    sub edx, 5
    mov r8d, 3
    mov r9d, 1
    mov dword [rsp + 32], 0x00666666
    call fb_fill_rect

    mov ecx, r12d
    add ecx, r14d
    sub ecx, 5
    mov edx, r13d
    add edx, r15d
    sub edx, 9
    mov r8d, 3
    mov r9d, 1
    mov dword [rsp + 32], 0x00666666
    call fb_fill_rect

.wf_no_grip:

    ; 7. Draw focus ring if focused
    mov eax, dword [rbx + WIN_ID]
    cmp eax, dword [rel wm_focused_id]
    jne .wf_no_focus

    ; Draw bright 1px outline just outside the border
    ; fb_draw_rect(x-1, y-1, w+2, h+2, COL_WM_FOCUS_RING)
    lea ecx, [r12d - 1]
    lea edx, [r13d - 1]
    lea r8d, [r14d + 2]
    lea r9d, [r15d + 2]
    mov dword [rsp + 32], COL_WM_FOCUS_RING
    call fb_draw_rect

.wf_no_focus:

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
; wm_draw_all — Draw all windows (painter's algorithm, back to front)
; void wm_draw_all(void)
;
; Walks wm_z_order from index 0 (bottommost) to wm_window_count-1 (topmost).
; For each visible window: draws frame, then calls draw_fn for content.
;
; draw_fn signature: void draw_fn(int cx, int cy, int cw, int ch, void* win_ptr)
; MS x64: ECX=cx, EDX=cy, R8D=cw, R9D=ch, [rsp+32]=win_ptr
; ============================================================
wm_draw_all:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 56                         ; shadow(32) + 3 stack args(24)
    ; 6 pushes + sub 56 = 8 + 48 + 56 = 112. 112 % 16 = 0. ✓

    mov dword [rsp + 48], 0             ; z_index = 0 (stored in stack)

.da_loop:
    mov eax, dword [rsp + 48]           ; z_index
    cmp eax, dword [rel wm_window_count]
    jge .da_done

    ; Get win_id from z_order
    lea rcx, [rel wm_z_order]
    movzx edi, byte [rcx + rax]         ; win_id

    ; Get window pointer
    mov ecx, edi
    call wm_window_ptr
    test rax, rax
    jz .da_next
    mov rbx, rax                        ; rbx = win_ptr

    ; Check window is active and visible
    cmp dword [rbx + WIN_ID], -1
    je .da_next
    mov eax, dword [rbx + WIN_FLAGS]
    test eax, (1 << WF_VISIBLE)
    jz .da_next

    ; Draw the window frame
    mov rcx, rbx
    call wm_draw_window_frame

    ; Call content draw function if set
    mov rax, [rbx + WIN_DRAW_FN]
    test rax, rax
    jz .da_next

    ; Compute client area: cx = x + border, cy = y + titlebar_h, cw = w - 2*border, ch = h - titlebar_h - border
    mov r12d, dword [rbx + WIN_X]
    mov r13d, dword [rbx + WIN_Y]
    mov ecx, r12d
    add ecx, WM_BORDER                  ; cx = x + 2
    mov edx, r13d
    add edx, WM_TITLEBAR_H              ; cy = y + 22
    mov r8d, dword [rbx + WIN_W]
    sub r8d, WM_BORDER * 2              ; cw = w - 4
    mov r9d, dword [rbx + WIN_H]
    sub r9d, WM_TITLEBAR_H
    sub r9d, WM_BORDER                  ; ch = h - 22 - 2
    mov [rsp + 32], rbx                 ; 5th arg = win_ptr
    call rax                            ; call draw_fn

.da_next:
    inc dword [rsp + 48]
    jmp .da_loop

.da_done:
    add rsp, 56
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; wm_bring_to_front — Move window to top of z-order
; void wm_bring_to_front(int win_id)
; MS x64: ECX=win_id
; ============================================================
wm_bring_to_front:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 32
    ; 3 pushes + sub 32 = 8 + 24 + 32 = 64. 64 % 16 = 0. ✓

    mov ebx, ecx                        ; save win_id

    ; Find win_id in z_order
    lea rsi, [rel wm_z_order]
    mov ecx, dword [rel wm_window_count]
    test ecx, ecx
    jz .btf_done

    xor edx, edx                        ; i = 0
.btf_find:
    cmp edx, ecx
    jge .btf_done                       ; not found
    movzx eax, byte [rsi + rdx]
    cmp eax, ebx
    je .btf_found
    inc edx
    jmp .btf_find

.btf_found:
    ; Already at top?
    lea eax, [ecx - 1]
    cmp edx, eax
    je .btf_done

    ; Shift everything from edx+1..count-1 down by 1
    mov eax, edx
.btf_shift:
    lea r8d, [eax + 1]
    cmp r8d, ecx
    jge .btf_shift_done
    movzx r9d, byte [rsi + r8]
    mov byte [rsi + rax], r9b
    inc eax
    jmp .btf_shift
.btf_shift_done:
    ; Place win_id at top (index count-1)
    lea eax, [ecx - 1]
    mov byte [rsi + rax], bl
%ifdef GRAPHICS_MODE
    call wm_write_all_z_order_to_herb
%endif

.btf_done:
    add rsp, 32
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; wm_set_focus — Set focused window ID
; void wm_set_focus(int win_id)
; MS x64: ECX=win_id
;
; Clears WF_FOCUSED on old window, sets it on new window.
; ============================================================
wm_set_focus:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 32
    ; 3 pushes + sub 32 = 64. ✓

    mov ebx, ecx                        ; new_id

    ; Clear focus on old window
    mov ecx, dword [rel wm_focused_id]
    cmp ecx, -1
    je .sf_set_new
    call wm_window_ptr
    test rax, rax
    jz .sf_set_new
    mov edx, dword [rax + WIN_FLAGS]
    and edx, ~(1 << WF_FOCUSED)
    mov dword [rax + WIN_FLAGS], edx

.sf_set_new:
    ; Set focus on new window
    mov dword [rel wm_focused_id], ebx
    cmp ebx, -1
    je .sf_done

    mov ecx, ebx
    call wm_window_ptr
    test rax, rax
    jz .sf_done
    mov edx, dword [rax + WIN_FLAGS]
    or edx, (1 << WF_FOCUSED)
    mov dword [rax + WIN_FLAGS], edx

.sf_done:
    add rsp, 32
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; wm_hit_test — Determine what part of what window a point hits
; int wm_hit_test(int mx, int my)
; MS x64: ECX=mx, EDX=my
; Returns: EAX = win_id (or -1 if no hit)
;          EDX = hit region (HIT_NONE/CLOSE/MAXIMIZE/TITLEBAR/RESIZE/CLIENT)
;
; Scans z_order from front to back (topmost first).
; ============================================================
wm_hit_test:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 32
    ; 7 pushes + sub 32 = 8 + 56 + 32 = 96. 96 % 16 = 0. ✓

    mov r12d, ecx                       ; mx
    mov r13d, edx                       ; my

    ; Scan from front (count-1) to back (0)
    mov r14d, dword [rel wm_window_count]
    dec r14d                            ; start at count-1

.ht_loop:
    cmp r14d, 0
    jl .ht_miss

    ; Get win_id from z_order[r14d]
    lea rsi, [rel wm_z_order]
    movzx edi, byte [rsi + r14]         ; win_id

    ; Get window pointer
    mov ecx, edi
    call wm_window_ptr
    test rax, rax
    jz .ht_next
    mov rbx, rax                        ; rbx = win_ptr

    ; Check visible
    mov eax, dword [rbx + WIN_FLAGS]
    test eax, (1 << WF_VISIBLE)
    jz .ht_next

    ; Check if point is within window bounds
    mov eax, dword [rbx + WIN_X]        ; wx
    cmp r12d, eax
    jl .ht_next
    mov ecx, dword [rbx + WIN_W]
    add ecx, eax                        ; wx + ww
    cmp r12d, ecx
    jge .ht_next
    mov eax, dword [rbx + WIN_Y]        ; wy
    cmp r13d, eax
    jl .ht_next
    mov ecx, dword [rbx + WIN_H]
    add ecx, eax                        ; wy + wh
    cmp r13d, ecx
    jge .ht_next

    ; Point is inside this window — determine region
    ; Check close button (top-right of title bar, if WF_CLOSABLE)
    mov eax, dword [rbx + WIN_FLAGS]
    test eax, (1 << WF_CLOSABLE)
    jz .ht_no_close

    ; Close button: x range = [wx+ww-border-btn-2, wx+ww-border]
    mov eax, dword [rbx + WIN_X]
    add eax, dword [rbx + WIN_W]
    sub eax, WM_BORDER
    mov ecx, eax                        ; right edge
    sub eax, WM_BTN_SIZE
    sub eax, 2                          ; left edge of close btn
    cmp r12d, eax
    jl .ht_no_close
    cmp r12d, ecx
    jge .ht_no_close
    ; Y range: [wy+border, wy+border+btn_size]
    mov eax, dword [rbx + WIN_Y]
    add eax, WM_BORDER
    cmp r13d, eax
    jl .ht_no_close
    add eax, WM_BTN_SIZE
    cmp r13d, eax
    jge .ht_no_close
    ; Hit close button
    mov eax, edi
    mov edx, HIT_CLOSE
    jmp .ht_done

.ht_no_close:
    ; Check maximize button (if WF_RESIZABLE, left of close)
    mov eax, dword [rbx + WIN_FLAGS]
    test eax, (1 << WF_RESIZABLE)
    jz .ht_no_max

    mov eax, dword [rbx + WIN_X]
    add eax, dword [rbx + WIN_W]
    sub eax, WM_BORDER
    sub eax, WM_BTN_SIZE
    sub eax, WM_BTN_SIZE
    sub eax, 4                          ; left edge of max btn
    mov ecx, eax
    add ecx, WM_BTN_SIZE                ; right edge
    cmp r12d, eax
    jl .ht_no_max
    cmp r12d, ecx
    jge .ht_no_max
    mov eax, dword [rbx + WIN_Y]
    add eax, WM_BORDER
    cmp r13d, eax
    jl .ht_no_max
    add eax, WM_BTN_SIZE
    cmp r13d, eax
    jge .ht_no_max
    mov eax, edi
    mov edx, HIT_MAXIMIZE
    jmp .ht_done

.ht_no_max:
    ; Check resize handle (bottom-right corner, if WF_RESIZABLE)
    mov eax, dword [rbx + WIN_FLAGS]
    test eax, (1 << WF_RESIZABLE)
    jz .ht_no_resize

    mov eax, dword [rbx + WIN_X]
    add eax, dword [rbx + WIN_W]
    sub eax, WM_RESIZE_HANDLE           ; left edge of resize zone
    cmp r12d, eax
    jl .ht_no_resize
    mov eax, dword [rbx + WIN_Y]
    add eax, dword [rbx + WIN_H]
    sub eax, WM_RESIZE_HANDLE           ; top edge of resize zone
    cmp r13d, eax
    jl .ht_no_resize
    mov eax, edi
    mov edx, HIT_RESIZE
    jmp .ht_done

.ht_no_resize:
    ; Check title bar (y in [wy, wy + titlebar_h])
    mov eax, dword [rbx + WIN_Y]
    cmp r13d, eax
    jl .ht_client                       ; shouldn't happen (already checked bounds)
    add eax, WM_TITLEBAR_H
    cmp r13d, eax
    jl .ht_titlebar

.ht_client:
    ; Client area
    mov eax, edi
    mov edx, HIT_CLIENT
    jmp .ht_done

.ht_titlebar:
    mov eax, edi
    mov edx, HIT_TITLEBAR
    jmp .ht_done

.ht_next:
    dec r14d
    jmp .ht_loop

.ht_miss:
    mov eax, -1
    mov edx, HIT_NONE

.ht_done:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; wm_begin_drag — Start dragging/resizing a window
; void wm_begin_drag(int win_id, int mode, int mx, int my)
; MS x64: ECX=win_id, EDX=mode, R8D=mx, R9D=my
; ============================================================
wm_begin_drag:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 32
    ; 2 pushes + sub 32 = 8 + 16 + 32 = 56. 56 % 16 = 8. ✓

    mov dword [rel wm_drag_win_id], ecx
    mov dword [rel wm_drag_mode], edx

    ; Get window pointer
    mov ebx, ecx
    call wm_window_ptr
    test rax, rax
    jz .bd_done

    ; Store offset = mouse - window origin
    mov ecx, r8d
    sub ecx, dword [rax + WIN_X]
    mov dword [rel wm_drag_offset_x], ecx
    mov ecx, r9d
    sub ecx, dword [rax + WIN_Y]
    mov dword [rel wm_drag_offset_y], ecx

    ; Store initial size for resize
    mov ecx, dword [rax + WIN_W]
    mov dword [rel wm_drag_start_w], ecx
    mov ecx, dword [rax + WIN_H]
    mov dword [rel wm_drag_start_h], ecx
    mov dword [rel wm_drag_start_mx], r8d
    mov dword [rel wm_drag_start_my], r9d

.bd_done:
    add rsp, 32
    pop rbx
    pop rbp
    ret

; ============================================================
; wm_update_drag — Update window position/size during drag
; void wm_update_drag(int mx, int my)
; MS x64: ECX=mx, EDX=my
; ============================================================
wm_update_drag:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 32
    ; 3 pushes + sub 32 = 64. ✓

    mov esi, ecx                        ; mx
    mov ebx, edx                        ; my

    ; Get dragged window
    mov ecx, dword [rel wm_drag_win_id]
    cmp ecx, -1
    je .ud_done
    call wm_window_ptr
    test rax, rax
    jz .ud_done

    cmp dword [rel wm_drag_mode], DRAG_MOVE
    je .ud_move
    cmp dword [rel wm_drag_mode], DRAG_RESIZE
    je .ud_resize
    jmp .ud_done

.ud_move:
    ; new_x = mx - offset_x
    mov ecx, esi
    sub ecx, dword [rel wm_drag_offset_x]
    ; Edge clamp X: keep at least 50px of window on screen
    ; x >= -(w - 50)
    mov edx, dword [rax + WIN_W]
    sub edx, 50
    neg edx                             ; -(w - 50)
    cmp ecx, edx
    jge .ud_x_min_ok
    mov ecx, edx
.ud_x_min_ok:
    ; x <= screen_w - 50
    cmp ecx, WM_SCREEN_W - 50
    jle .ud_x_max_ok
    mov ecx, WM_SCREEN_W - 50
.ud_x_max_ok:
    mov dword [rax + WIN_X], ecx

    ; new_y = my - offset_y
    mov ecx, ebx
    sub ecx, dword [rel wm_drag_offset_y]
    ; Edge clamp Y: keep title bar accessible (y >= 0, y <= screen_h - titlebar)
    test ecx, ecx
    jns .ud_y_min_ok
    xor ecx, ecx
.ud_y_min_ok:
    cmp ecx, WM_SCREEN_H - WM_TITLEBAR_H
    jle .ud_y_max_ok
    mov ecx, WM_SCREEN_H - WM_TITLEBAR_H
.ud_y_max_ok:
    mov dword [rax + WIN_Y], ecx
%ifdef GRAPHICS_MODE
    mov ecx, dword [rel wm_drag_win_id]
    call wm_write_window_geometry_to_herb
%endif
    jmp .ud_done

.ud_resize:
    ; new_w = start_w + (mx - start_mx)
    mov ecx, esi
    sub ecx, dword [rel wm_drag_start_mx]
    add ecx, dword [rel wm_drag_start_w]
    ; Clamp to min_width
    cmp ecx, dword [rax + WIN_MIN_W]
    jge .ud_w_ok
    mov ecx, dword [rax + WIN_MIN_W]
.ud_w_ok:
    mov dword [rax + WIN_W], ecx

    ; new_h = start_h + (my - start_my)
    mov ecx, ebx
    sub ecx, dword [rel wm_drag_start_my]
    add ecx, dword [rel wm_drag_start_h]
    ; Clamp to min_height
    cmp ecx, dword [rax + WIN_MIN_H]
    jge .ud_h_ok
    mov ecx, dword [rax + WIN_MIN_H]
.ud_h_ok:
    mov dword [rax + WIN_H], ecx
%ifdef GRAPHICS_MODE
    mov ecx, dword [rel wm_drag_win_id]
    call wm_write_window_geometry_to_herb
%endif

.ud_done:
    add rsp, 32
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; wm_end_drag — End drag/resize operation
; void wm_end_drag(void)
; ============================================================
wm_end_drag:
    mov dword [rel wm_drag_mode], DRAG_NONE
    mov dword [rel wm_drag_win_id], -1
    ret
