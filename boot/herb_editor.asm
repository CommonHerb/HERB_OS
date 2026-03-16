; boot/herb_editor.asm — HERB OS Text Editor
;
; Gap-buffer text editor that runs in a window manager window.
; Assembly handles mechanism (gap buffer, cursor, rendering, key dispatch).
;
; Architecture:
;   - 64KB gap buffer for text storage
;   - Line index array for fast line-based navigation
;   - Renders into WM client area via draw_fn callback
;
; Assembled with: nasm -f win64 herb_editor.asm
; MS x64 ABI: RCX/RDX/R8/R9 args, 32-byte shadow, RAX return
; Callee-saved: RBX, RSI, RDI, R12-R15, RBP

[bits 64]
default rel

; ============================================================
; EXTERNS
; ============================================================

; Framebuffer drawing primitives (from herb_hw.asm)
extern fb_fill_rect
extern fb_draw_char
extern fb_draw_string

; Utility (from herb_freestanding.asm)
extern herb_snprintf
extern herb_memset

; Window manager (from herb_wm.asm)
extern wm_create_window
extern wm_window_ptr
extern wm_destroy_window

; ============================================================
; CONSTANTS
; ============================================================

ED_BUF_SIZE         equ 65536       ; 64KB gap buffer
ED_MAX_LINES        equ 4096        ; max lines we index
ED_FONT_W           equ 12          ; char width in pixels
ED_FONT_H           equ 24          ; char height in pixels
ED_STATUS_H         equ 24          ; status line height

; Window struct field offsets (must match herb_wm.asm)
WIN_ID              equ 0
WIN_FLAGS           equ 4
WIN_X               equ 8
WIN_Y               equ 12
WIN_W               equ 16
WIN_H               equ 20
WIN_CONTENT_TYPE    equ 32
WIN_CONTENT_ID      equ 36
WIN_BORDER_COLOR    equ 40
WIN_FILL_COLOR      equ 44
WIN_TITLE_BG        equ 48
WIN_DRAW_FN         equ 80
WIN_DIRTY           equ 92

; Window flags
WF_CLOSABLE         equ 5
WF_RESIZABLE        equ 6

; Content type
WCT_CUSTOM          equ 3

; Colors
COL_ED_BG           equ 0x001A1A2E  ; dark blue background
COL_ED_TEXT          equ 0x00C0C0C0  ; light gray text
COL_ED_CURSOR_BG    equ 0x00FFFFFF  ; white cursor block
COL_ED_CURSOR_FG    equ 0x00000000  ; black text on cursor
COL_ED_STATUS_BG    equ 0x00252540  ; slightly lighter status bar
COL_ED_STATUS_FG    equ 0x00808090  ; dim status text
COL_ED_BORDER       equ 0x004A90D9  ; blue border
COL_ED_TITLE        equ 0x002D5F8B  ; title bar

; ============================================================
; GLOBALS
; ============================================================

global editor_init
global editor_open
global editor_close
global editor_handle_key
global editor_draw_content
global editor_activate
global editor_deactivate
global editor_toggle_blink
global ed_active
global ed_win_id

; ============================================================
; BSS — Editor state
; ============================================================

section .bss

alignb 16
ed_buffer:          resb ED_BUF_SIZE    ; 64KB gap buffer
ed_line_starts:     resd ED_MAX_LINES   ; line start offsets (logical)
alignb 4
ed_gap_start:       resd 1              ; gap start offset
ed_gap_end:         resd 1              ; gap end offset
ed_line_count:      resd 1              ; total lines
ed_cursor_line:     resd 1              ; current line (0-based)
ed_cursor_col:      resd 1              ; current column (0-based)
ed_scroll_y:        resd 1              ; first visible line
ed_cursor_blink:    resd 1              ; blink frame counter
ed_cursor_vis:      resd 1              ; 1=show cursor block, 0=hidden
ed_active:          resd 1              ; 1=editor has input focus
ed_dirty:           resd 1              ; 1=content changed
ed_win_id:          resd 1              ; window slot ID (-1 if not open)
ed_target_col:      resd 1              ; sticky column for up/down
ed_status_buf:      resb 64             ; status line format buffer

; ============================================================
; RDATA — String constants
; ============================================================

section .rdata

ed_welcome_text:
    db "# Welcome to HERB Editor", 10
    db "# Press ESC to return to OS", 10, 10
    db "tension hello priority 1", 10
    db "  match sig in SIGNALS", 10
    db "  emit move consume sig to DONE", 10, 0
ed_welcome_text_len equ $ - ed_welcome_text - 1

ed_title_str:       db "Editor", 0
ed_status_fmt:      db "Ln %d, Col %d | %d chars", 0

; ============================================================
; CODE
; ============================================================

section .text

; ============================================================
; editor_init — Initialize editor state
; void editor_init(void)
; ============================================================
editor_init:
    push rbp
    mov rbp, rsp
    sub rsp, 32                         ; shadow space
    ; 1 push + sub 32 = 8 + 8 + 32 = 48. 48 % 16 = 0. ✓

    ; Zero the gap buffer
    lea rcx, [rel ed_buffer]
    xor edx, edx
    mov r8d, ED_BUF_SIZE
    call herb_memset

    ; Set gap to cover entire buffer (empty document)
    mov dword [rel ed_gap_start], 0
    mov dword [rel ed_gap_end], ED_BUF_SIZE

    ; Reset cursor
    mov dword [rel ed_cursor_line], 0
    mov dword [rel ed_cursor_col], 0
    mov dword [rel ed_scroll_y], 0
    mov dword [rel ed_target_col], 0

    ; Reset state
    mov dword [rel ed_cursor_blink], 0
    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_active], 0
    mov dword [rel ed_dirty], 0
    mov dword [rel ed_win_id], -1

    ; Initialize line index (one line at offset 0)
    mov dword [rel ed_line_starts], 0
    mov dword [rel ed_line_count], 1

    add rsp, 32
    pop rbp
    ret

; ============================================================
; editor_load_text — Load text into gap buffer
; void editor_load_text(const char* ptr, int len)
; MS x64: RCX=ptr, EDX=len
; ============================================================
editor_load_text:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40
    ; 4 pushes (32) + sub 40 = 8 + 32 + 40 = 80. 80 % 16 = 0. ✓

    mov rsi, rcx                        ; rsi = source ptr
    mov edi, edx                        ; edi = len

    ; Clamp len to buffer size
    cmp edi, ED_BUF_SIZE
    jle .elt_len_ok
    mov edi, ED_BUF_SIZE
.elt_len_ok:

    ; Copy text into buffer[0..len-1]
    lea rbx, [rel ed_buffer]
    xor ecx, ecx                        ; i = 0
.elt_copy:
    cmp ecx, edi
    jge .elt_copy_done
    movzx eax, byte [rsi + rcx]
    mov byte [rbx + rcx], al
    inc ecx
    jmp .elt_copy
.elt_copy_done:

    ; Set gap after text
    mov dword [rel ed_gap_start], edi
    mov dword [rel ed_gap_end], ED_BUF_SIZE

    ; Reset cursor to start
    mov dword [rel ed_cursor_line], 0
    mov dword [rel ed_cursor_col], 0
    mov dword [rel ed_scroll_y], 0

    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_text_length — Get logical text length
; int editor_text_length(void)
; Returns: EAX = buf_size - gap_size
; ============================================================
editor_text_length:
    mov eax, ED_BUF_SIZE
    mov ecx, dword [rel ed_gap_end]
    sub ecx, dword [rel ed_gap_start]
    sub eax, ecx
    ret

; ============================================================
; editor_char_at — Read character at logical offset
; int editor_char_at(int offset)
; MS x64: ECX=logical_offset
; Returns: EAX = character (or 0 if out of range)
; ============================================================
editor_char_at:
    ; Translate logical offset to physical:
    ; if offset < gap_start: physical = offset
    ; else: physical = offset + (gap_end - gap_start)
    cmp ecx, dword [rel ed_gap_start]
    jge .eca_after_gap
    ; Before gap — direct access
    lea rax, [rel ed_buffer]
    movzx eax, byte [rax + rcx]
    ret
.eca_after_gap:
    mov eax, dword [rel ed_gap_end]
    sub eax, dword [rel ed_gap_start]
    add ecx, eax                        ; physical = offset + gap_size
    cmp ecx, ED_BUF_SIZE
    jge .eca_out
    lea rax, [rel ed_buffer]
    movsxd rcx, ecx
    movzx eax, byte [rax + rcx]
    ret
.eca_out:
    xor eax, eax
    ret

; ============================================================
; editor_rebuild_lines — Rebuild line index from buffer content
; void editor_rebuild_lines(void)
; Scans logical text for '\n', populates ed_line_starts/ed_line_count
; ============================================================
editor_rebuild_lines:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 32
    ; 5 pushes + sub 32 = 8 + 40 + 32 = 80. 80 % 16 = 0. ✓

    ; Get text length
    call editor_text_length
    mov r12d, eax                       ; r12d = text_len

    ; Line 0 always starts at offset 0
    lea rbx, [rel ed_line_starts]
    mov dword [rbx], 0
    mov esi, 1                          ; line_count = 1
    xor edi, edi                        ; i = 0

.erl_scan:
    cmp edi, r12d
    jge .erl_done
    cmp esi, ED_MAX_LINES
    jge .erl_done

    ; Read char at logical offset i
    mov ecx, edi
    call editor_char_at
    cmp al, 10                          ; '\n'?
    jne .erl_next

    ; Found newline — next line starts at i+1
    lea eax, [edi + 1]
    mov dword [rbx + rsi*4], eax
    inc esi

.erl_next:
    inc edi
    jmp .erl_scan

.erl_done:
    mov dword [rel ed_line_count], esi

    add rsp, 32
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_gap_to_cursor — Move gap to current cursor position
; Internal helper. Moves gap so gap_start = logical cursor offset.
; ============================================================
editor_gap_to_cursor:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 32
    ; 3 pushes + sub 32 = 8 + 24 + 32 = 64. 64 % 16 = 0. ✓

    ; Compute logical cursor offset from line/col
    ; offset = ed_line_starts[ed_cursor_line] + ed_cursor_col
    mov eax, dword [rel ed_cursor_line]
    lea rbx, [rel ed_line_starts]
    mov ecx, dword [rbx + rax*4]        ; line start
    add ecx, dword [rel ed_cursor_col]  ; + col
    ; ecx = target logical offset

    mov esi, dword [rel ed_gap_start]   ; esi = current gap_start

    ; If gap_start == target, nothing to do
    cmp esi, ecx
    je .egtc_done

    lea rbx, [rel ed_buffer]
    mov edx, dword [rel ed_gap_end]     ; edx = gap_end

    cmp esi, ecx
    jg .egtc_move_left

    ; Move gap right: copy chars from gap_end to gap_start
.egtc_move_right:
    cmp esi, ecx
    jge .egtc_update
    ; buffer[gap_start] = buffer[gap_end]
    movsxd rax, edx
    movzx eax, byte [rbx + rax]
    movsxd r8, esi
    mov byte [rbx + r8], al
    inc esi                             ; gap_start++
    inc edx                             ; gap_end++
    jmp .egtc_move_right

.egtc_move_left:
    ; Move gap left: copy chars from gap_start-1 to gap_end-1
    cmp esi, ecx
    jle .egtc_update
    dec esi                             ; gap_start--
    dec edx                             ; gap_end--
    movsxd rax, esi
    movzx eax, byte [rbx + rax]
    movsxd r8, edx
    mov byte [rbx + r8], al
    jmp .egtc_move_left

.egtc_update:
    mov dword [rel ed_gap_start], esi
    mov dword [rel ed_gap_end], edx

.egtc_done:
    add rsp, 32
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_insert_char — Insert character at cursor position
; void editor_insert_char(int ch)
; MS x64: ECX=char
; ============================================================
editor_insert_char:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40
    ; 4 pushes + sub 40 = 8 + 32 + 40 = 80. 80 % 16 = 0. ✓

    mov edi, ecx                        ; save char

    ; Check buffer not full
    mov eax, dword [rel ed_gap_start]
    cmp eax, dword [rel ed_gap_end]
    jge .eic_done                       ; gap is empty — buffer full

    ; Move gap to cursor position
    call editor_gap_to_cursor

    ; Write char at gap_start
    mov eax, dword [rel ed_gap_start]
    lea rbx, [rel ed_buffer]
    movsxd rax, eax
    mov byte [rbx + rax], dil
    inc dword [rel ed_gap_start]

    ; Update cursor position
    cmp dil, 10                         ; newline?
    je .eic_newline

    ; Regular char: col++
    inc dword [rel ed_cursor_col]
    mov eax, dword [rel ed_cursor_col]
    mov dword [rel ed_target_col], eax
    jmp .eic_rebuild

.eic_newline:
    ; Newline: line++, col=0
    inc dword [rel ed_cursor_line]
    mov dword [rel ed_cursor_col], 0
    mov dword [rel ed_target_col], 0

.eic_rebuild:
    ; Rebuild lines and mark dirty
    call editor_rebuild_lines
    mov dword [rel ed_dirty], 1

    ; Reset cursor blink to visible
    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_cursor_blink], 0

    ; Auto-scroll
    call editor_auto_scroll

.eic_done:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_delete_back — Delete character before cursor (backspace)
; void editor_delete_back(void)
; ============================================================
editor_delete_back:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 32
    ; 3 pushes + sub 32 = 8 + 24 + 32 = 64. 64 % 16 = 0. ✓

    ; Check cursor is not at start
    mov eax, dword [rel ed_cursor_line]
    or eax, dword [rel ed_cursor_col]
    jz .edb_done                        ; at 0,0 — nothing to delete

    ; Move gap to cursor
    call editor_gap_to_cursor

    ; Check gap_start > 0
    mov eax, dword [rel ed_gap_start]
    test eax, eax
    jz .edb_done

    ; Read the char we're about to delete
    dec eax
    lea rbx, [rel ed_buffer]
    movsxd rcx, eax
    movzx esi, byte [rbx + rcx]        ; esi = deleted char
    mov dword [rel ed_gap_start], eax   ; gap_start--

    ; Update cursor
    cmp sil, 10                         ; was it a newline?
    je .edb_prev_line

    ; Regular char: col--
    dec dword [rel ed_cursor_col]
    mov eax, dword [rel ed_cursor_col]
    mov dword [rel ed_target_col], eax
    jmp .edb_rebuild

.edb_prev_line:
    ; Deleted a newline: go to end of previous line
    dec dword [rel ed_cursor_line]
    ; Need to figure out column = length of previous line
    ; Rebuild lines first, then compute
    call editor_rebuild_lines
    ; col = line_end - line_start (where line_end is start of next line - 1, or text_len)
    mov eax, dword [rel ed_cursor_line]
    lea rbx, [rel ed_line_starts]
    mov ecx, dword [rbx + rax*4]        ; start of current (now previous) line
    ; Get end: either line_starts[line+1]-1 or text_len
    inc eax
    cmp eax, dword [rel ed_line_count]
    jge .edb_last_line
    mov edx, dword [rbx + rax*4]        ; start of next line
    dec edx                             ; -1 for the newline char
    sub edx, ecx                        ; col = next_start - 1 - current_start
    mov dword [rel ed_cursor_col], edx
    mov dword [rel ed_target_col], edx
    jmp .edb_dirty

.edb_last_line:
    ; Last line: col = text_len - line_start
    ; ecx = line_start — save to stack before call (ecx is caller-saved)
    mov [rsp+32], ecx
    call editor_text_length
    sub eax, dword [rsp+32]
    mov dword [rel ed_cursor_col], eax
    mov dword [rel ed_target_col], eax
    jmp .edb_dirty

.edb_rebuild:
    call editor_rebuild_lines
.edb_dirty:
    mov dword [rel ed_dirty], 1
    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_cursor_blink], 0
    call editor_auto_scroll

.edb_done:
    add rsp, 32
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_delete_fwd — Delete character at cursor (delete key)
; void editor_delete_fwd(void)
; ============================================================
editor_delete_fwd:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40
    ; 2 pushes + sub 40 = 8 + 16 + 40 = 64. 64 % 16 = 0. ✓

    ; Move gap to cursor
    call editor_gap_to_cursor

    ; Check gap_end < buf_size
    mov eax, dword [rel ed_gap_end]
    cmp eax, ED_BUF_SIZE
    jge .edf_done

    ; Simply advance gap_end (eat the char after the gap)
    inc dword [rel ed_gap_end]

    ; Rebuild + dirty
    call editor_rebuild_lines
    mov dword [rel ed_dirty], 1
    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_cursor_blink], 0

.edf_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_move_left — Move cursor one position left
; void editor_move_left(void)
; ============================================================
editor_move_left:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40
    ; 2 pushes + sub 40 = 8 + 16 + 40 = 64. 64 % 16 = 0. ✓

    mov eax, dword [rel ed_cursor_col]
    test eax, eax
    jnz .eml_same_line

    ; col==0: wrap to end of previous line
    mov eax, dword [rel ed_cursor_line]
    test eax, eax
    jz .eml_done                        ; already at 0,0
    dec dword [rel ed_cursor_line]
    ; Compute end col of previous line
    call editor_line_length
    mov dword [rel ed_cursor_col], eax
    jmp .eml_update

.eml_same_line:
    dec dword [rel ed_cursor_col]

.eml_update:
    mov eax, dword [rel ed_cursor_col]
    mov dword [rel ed_target_col], eax
    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_cursor_blink], 0
    call editor_auto_scroll

.eml_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_move_right — Move cursor one position right
; void editor_move_right(void)
; ============================================================
editor_move_right:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40
    ; 2 pushes + sub 40 = 64 aligned

    ; Get current line length
    call editor_line_length
    mov ebx, eax                        ; ebx = line_len

    mov eax, dword [rel ed_cursor_col]
    cmp eax, ebx
    jl .emr_same_line

    ; At end of line: wrap to start of next line
    mov eax, dword [rel ed_cursor_line]
    inc eax
    cmp eax, dword [rel ed_line_count]
    jge .emr_done                       ; already at last line end
    mov dword [rel ed_cursor_line], eax
    mov dword [rel ed_cursor_col], 0
    jmp .emr_update

.emr_same_line:
    inc dword [rel ed_cursor_col]

.emr_update:
    mov eax, dword [rel ed_cursor_col]
    mov dword [rel ed_target_col], eax
    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_cursor_blink], 0
    call editor_auto_scroll

.emr_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_move_up — Move cursor up one line
; void editor_move_up(void)
; ============================================================
editor_move_up:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    mov eax, dword [rel ed_cursor_line]
    test eax, eax
    jz .emu_done                        ; already on line 0

    dec dword [rel ed_cursor_line]

    ; Clamp col to new line length
    call editor_line_length
    mov ebx, eax                        ; ebx = new line length
    mov eax, dword [rel ed_target_col]
    cmp eax, ebx
    jle .emu_set_col
    mov eax, ebx                        ; clamp to line length
.emu_set_col:
    mov dword [rel ed_cursor_col], eax

    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_cursor_blink], 0
    call editor_auto_scroll

.emu_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_move_down — Move cursor down one line
; void editor_move_down(void)
; ============================================================
editor_move_down:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    mov eax, dword [rel ed_cursor_line]
    inc eax
    cmp eax, dword [rel ed_line_count]
    jge .emd_done                       ; already on last line

    mov dword [rel ed_cursor_line], eax

    ; Clamp col to new line length
    call editor_line_length
    mov ebx, eax
    mov eax, dword [rel ed_target_col]
    cmp eax, ebx
    jle .emd_set_col
    mov eax, ebx
.emd_set_col:
    mov dword [rel ed_cursor_col], eax

    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_cursor_blink], 0
    call editor_auto_scroll

.emd_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_move_home — Move cursor to start of current line
; void editor_move_home(void)
; ============================================================
editor_move_home:
    mov dword [rel ed_cursor_col], 0
    mov dword [rel ed_target_col], 0
    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_cursor_blink], 0
    ret

; ============================================================
; editor_move_end — Move cursor to end of current line
; void editor_move_end(void)
; ============================================================
editor_move_end:
    push rbp
    mov rbp, rsp
    sub rsp, 32

    call editor_line_length
    mov dword [rel ed_cursor_col], eax
    mov dword [rel ed_target_col], eax
    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_cursor_blink], 0

    add rsp, 32
    pop rbp
    ret

; ============================================================
; editor_line_length — Get length of current cursor line
; int editor_line_length(void)
; Returns: EAX = length of ed_cursor_line (not counting newline)
; ============================================================
editor_line_length:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    mov eax, dword [rel ed_cursor_line]
    lea rbx, [rel ed_line_starts]
    mov ecx, dword [rbx + rax*4]        ; start of current line

    ; End = start of next line - 1, or text_len
    inc eax
    cmp eax, dword [rel ed_line_count]
    jge .ell_last_line
    mov eax, dword [rbx + rax*4]        ; start of next line
    dec eax                             ; subtract newline
    sub eax, ecx                        ; length = next_start - 1 - start
    jmp .ell_done

.ell_last_line:
    ; Last line: len = text_len - start
    mov [rsp+32], ecx                   ; save start to stack
    call editor_text_length
    sub eax, dword [rsp+32]

.ell_done:
    ; Clamp to >= 0
    test eax, eax
    jns .ell_ret
    xor eax, eax
.ell_ret:
    add rsp, 40
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_auto_scroll — Adjust scroll to keep cursor visible
; void editor_auto_scroll(void)
; Assumes a default visible_lines of 20 if we can't compute it.
; ============================================================
editor_auto_scroll:
    ; Use a fixed estimate of visible lines (will be correct at render time)
    ; This is a simple implementation: just keep cursor in view
    mov eax, dword [rel ed_cursor_line]
    cmp eax, dword [rel ed_scroll_y]
    jge .eas_check_bottom
    ; Cursor above viewport
    mov dword [rel ed_scroll_y], eax
    ret

.eas_check_bottom:
    ; Assume ~20 visible lines (conservative for 400px window)
    mov ecx, dword [rel ed_scroll_y]
    add ecx, 20                         ; approximate visible_lines
    cmp eax, ecx
    jl .eas_ok
    ; Cursor below viewport
    sub eax, 19                         ; scroll_y = cursor_line - visible + 1
    test eax, eax
    jns .eas_set
    xor eax, eax
.eas_set:
    mov dword [rel ed_scroll_y], eax
.eas_ok:
    ret

; ============================================================
; editor_open — Open the editor window
; void editor_open(void)
; ============================================================
editor_open:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 80
    ; 5 pushes + sub 80 = 8 + 40 + 80 = 128. 128 % 16 = 0. ✓

    ; If already open, just activate
    cmp dword [rel ed_win_id], -1
    jne .eo_activate

    ; Initialize editor state
    call editor_init

    ; Load welcome text
    lea rcx, [rel ed_welcome_text]
    mov edx, ed_welcome_text_len
    call editor_load_text

    ; Rebuild lines
    call editor_rebuild_lines

    ; Create window: wm_create_window(50, 80, 500, 400, WCT_CUSTOM, 0, "Editor", WF_CLOSABLE|WF_RESIZABLE)
    mov ecx, 50                         ; x
    mov edx, 80                         ; y
    mov r8d, 500                        ; w
    mov r9d, 400                        ; h
    mov dword [rsp+32], WCT_CUSTOM      ; type = 3
    mov dword [rsp+40], 0               ; content_id = 0
    lea rax, [rel ed_title_str]
    mov [rsp+48], rax                   ; title = "Editor"
    mov dword [rsp+56], (1 << WF_CLOSABLE) | (1 << WF_RESIZABLE)
    call wm_create_window
    cmp eax, -1
    je .eo_done                         ; window creation failed

    mov dword [rel ed_win_id], eax
    mov r12d, eax                       ; save win_id

    ; Set draw function and colors
    mov ecx, r12d
    call wm_window_ptr
    test rax, rax
    jz .eo_done
    mov rbx, rax

    ; Set draw_fn = editor_draw_content
    lea rax, [rel editor_draw_content]
    mov [rbx + WIN_DRAW_FN], rax

    ; Set colors
    mov dword [rbx + WIN_FILL_COLOR], COL_ED_BG
    mov dword [rbx + WIN_BORDER_COLOR], COL_ED_BORDER
    mov dword [rbx + WIN_TITLE_BG], COL_ED_TITLE

.eo_activate:
    call editor_activate

.eo_done:
    add rsp, 80
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_close — Close editor and reset state
; void editor_close(void)
; ============================================================
editor_close:
    mov dword [rel ed_active], 0
    mov dword [rel ed_win_id], -1
    ret

; ============================================================
; editor_activate — Give editor input focus
; void editor_activate(void)
; ============================================================
editor_activate:
    mov dword [rel ed_active], 1
    mov dword [rel ed_cursor_vis], 1
    mov dword [rel ed_cursor_blink], 0
    ret

; ============================================================
; editor_deactivate — Remove editor input focus
; void editor_deactivate(void)
; ============================================================
editor_deactivate:
    mov dword [rel ed_active], 0
    ret

; ============================================================
; editor_handle_key — Process a keypress for the editor
; void editor_handle_key(int ascii, int scancode)
; MS x64: ECX=ascii, EDX=scancode
; ============================================================
editor_handle_key:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40
    ; 4 pushes + sub 40 = 8 + 32 + 40 = 80. 80 % 16 = 0. ✓

    mov esi, ecx                        ; esi = ascii
    mov edi, edx                        ; edi = scancode

    ; ---- Escape: deactivate editor ----
    cmp esi, 27
    je .ehk_escape

    ; ---- Arrow keys (by scancode) ----
    cmp edi, 0x48                       ; Up
    je .ehk_up
    cmp edi, 0x50                       ; Down
    je .ehk_down
    cmp edi, 0x4B                       ; Left
    je .ehk_left
    cmp edi, 0x4D                       ; Right
    je .ehk_right

    ; ---- Home / End ----
    cmp edi, 0x47                       ; Home
    je .ehk_home
    cmp edi, 0x4F                       ; End
    je .ehk_end

    ; ---- Page Up / Page Down ----
    cmp edi, 0x49                       ; Page Up
    je .ehk_pgup
    cmp edi, 0x51                       ; Page Down
    je .ehk_pgdn

    ; ---- Delete (scancode 0x53, ascii usually 0) ----
    cmp edi, 0x53
    je .ehk_delete

    ; ---- Backspace ----
    cmp esi, 8
    je .ehk_backspace

    ; ---- Enter ----
    cmp esi, 13
    je .ehk_enter
    cmp esi, 10
    je .ehk_enter

    ; ---- Tab ----
    cmp esi, 9
    je .ehk_tab

    ; ---- Printable ASCII (0x20-0x7E) ----
    cmp esi, 0x20
    jb .ehk_done
    cmp esi, 0x7E
    ja .ehk_done

    ; Insert printable character
    mov ecx, esi
    call editor_insert_char
    jmp .ehk_done

.ehk_escape:
    call editor_deactivate
    jmp .ehk_done

.ehk_up:
    call editor_move_up
    jmp .ehk_done

.ehk_down:
    call editor_move_down
    jmp .ehk_done

.ehk_left:
    call editor_move_left
    jmp .ehk_done

.ehk_right:
    call editor_move_right
    jmp .ehk_done

.ehk_home:
    call editor_move_home
    jmp .ehk_done

.ehk_end:
    call editor_move_end
    jmp .ehk_done

.ehk_pgup:
    ; Move up 20 lines
    mov ebx, 20
.ehk_pgup_loop:
    test ebx, ebx
    jz .ehk_done
    dec ebx
    call editor_move_up
    jmp .ehk_pgup_loop

.ehk_pgdn:
    ; Move down 20 lines
    mov ebx, 20
.ehk_pgdn_loop:
    test ebx, ebx
    jz .ehk_done
    dec ebx
    call editor_move_down
    jmp .ehk_pgdn_loop

.ehk_delete:
    call editor_delete_fwd
    jmp .ehk_done

.ehk_backspace:
    call editor_delete_back
    jmp .ehk_done

.ehk_enter:
    mov ecx, 10
    call editor_insert_char
    jmp .ehk_done

.ehk_tab:
    ; Insert 4 spaces (common tab width)
    mov ecx, ' '
    call editor_insert_char
    mov ecx, ' '
    call editor_insert_char
    mov ecx, ' '
    call editor_insert_char
    mov ecx, ' '
    call editor_insert_char
    jmp .ehk_done

.ehk_done:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; editor_draw_content — Render editor content into client area
; void editor_draw_content(int cx, int cy, int cw, int ch, void* win_ptr)
; MS x64: ECX=cx, EDX=cy, R8D=cw, R9D=ch, [RBP+48]=win_ptr
;
; Called by wm_draw_all as draw_fn callback.
; Must save/restore callee-saved registers.
; ============================================================
editor_draw_content:
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
    ; 8 pushes (64) + sub 104 = 8 + 64 + 104 = 176. 176 % 16 = 0. ✓

    ; Stack layout:
    ;   [rsp+32] = shadow space
    ;   [rsp+64] = cx (saved)
    ;   [rsp+68] = cy (saved)
    ;   [rsp+72] = cw (saved)
    ;   [rsp+76] = ch (saved)
    ;   [rsp+80] = visible_lines
    ;   [rsp+84] = visible_cols
    ;   [rsp+88] = status_y
    ;   [rsp+92] = text_area_h

    ; Save client area params to stack (caller-saved!)
    mov dword [rsp+64], ecx             ; cx
    mov dword [rsp+68], edx             ; cy
    mov dword [rsp+72], r8d             ; cw
    mov dword [rsp+76], r9d             ; ch

    ; Calculate text area (reserve bottom for status line)
    mov eax, r9d                        ; ch
    sub eax, ED_STATUS_H                ; text_area_h = ch - 16
    test eax, eax
    jg .edc_area_ok
    mov eax, r9d                        ; if too small, use full area
.edc_area_ok:
    mov dword [rsp+92], eax             ; text_area_h

    ; visible_lines = text_area_h / ED_FONT_H
    xor edx, edx
    mov ecx, ED_FONT_H
    div ecx
    mov dword [rsp+80], eax             ; visible_lines

    ; visible_cols = cw / ED_FONT_W
    mov eax, dword [rsp+72]             ; cw
    xor edx, edx
    mov ecx, ED_FONT_W
    div ecx
    mov dword [rsp+84], eax             ; visible_cols

    ; status_y = cy + text_area_h
    mov eax, dword [rsp+68]             ; cy
    add eax, dword [rsp+92]             ; + text_area_h
    mov dword [rsp+88], eax             ; status_y

    ; ---- Fill background ----
    mov ecx, dword [rsp+64]             ; cx
    mov edx, dword [rsp+68]             ; cy
    mov r8d, dword [rsp+72]             ; cw
    mov r9d, dword [rsp+76]             ; ch
    mov dword [rsp+32], COL_ED_BG
    call fb_fill_rect

    ; ---- Render text lines ----
    ; r12d = row counter, r13d = line_idx, r14d = col counter
    xor r12d, r12d                      ; row = 0

.edc_row_loop:
    cmp r12d, dword [rsp+80]            ; row < visible_lines?
    jge .edc_rows_done

    ; line_idx = ed_scroll_y + row
    mov r13d, dword [rel ed_scroll_y]
    add r13d, r12d
    cmp r13d, dword [rel ed_line_count]
    jge .edc_rows_done                  ; past end of text

    ; Get line start offset
    lea rax, [rel ed_line_starts]
    movsxd rcx, r13d
    mov ebx, dword [rax + rcx*4]        ; ebx = line_start offset

    ; Get line length
    mov eax, r13d
    inc eax
    cmp eax, dword [rel ed_line_count]
    jge .edc_last_line
    lea rcx, [rel ed_line_starts]
    movsxd rax, eax
    mov esi, dword [rcx + rax*4]        ; start of next line
    dec esi                             ; - newline char
    sub esi, ebx                        ; line_len = next_start - 1 - start
    jmp .edc_got_len
.edc_last_line:
    ; Last line: len = text_len - line_start
    ; r12, r13 are callee-saved — safe across call. ebx also callee-saved.
    call editor_text_length
    sub eax, ebx
    mov esi, eax                        ; esi = line_len
.edc_got_len:
    ; Clamp esi >= 0
    test esi, esi
    jns .edc_len_ok
    xor esi, esi
.edc_len_ok:

    ; Render each column
    xor r14d, r14d                      ; col = 0

.edc_col_loop:
    cmp r14d, dword [rsp+84]            ; col < visible_cols?
    jge .edc_col_done
    cmp r14d, esi                        ; col < line_len?
    jge .edc_col_blank

    ; Read character at logical offset = line_start + col
    mov ecx, ebx
    add ecx, r14d
    ; Save registers that will be clobbered by call
    mov [rsp+36], ebx                   ; save line_start
    mov [rsp+40], esi                   ; save line_len
    call editor_char_at
    mov ebx, [rsp+36]                   ; restore line_start
    mov esi, [rsp+40]                   ; restore line_len

    mov edi, eax                        ; edi = character
    jmp .edc_draw_char

.edc_col_blank:
    mov edi, ' '                        ; blank space past end of line

.edc_draw_char:
    ; Compute pixel position
    ; px = cx + col * ED_FONT_W
    mov eax, r14d
    imul eax, eax, ED_FONT_W           ; * 12
    add eax, dword [rsp+64]            ; + cx
    mov r15d, eax                       ; r15d = px

    ; py = cy + row * ED_FONT_H
    mov eax, r12d
    imul eax, eax, ED_FONT_H           ; * 24
    add eax, dword [rsp+68]            ; + cy

    ; Check if this is the cursor position
    cmp r13d, dword [rel ed_cursor_line]
    jne .edc_normal_char
    cmp r14d, dword [rel ed_cursor_col]
    jne .edc_normal_char

    ; Cursor position — check blink state
    cmp dword [rel ed_cursor_vis], 0
    je .edc_normal_char

    ; Draw with inverted colors (white bg, black text)
    mov ecx, r15d                       ; px
    mov edx, eax                        ; py
    mov r8d, edi                        ; char
    mov r9d, COL_ED_CURSOR_FG           ; fg = black
    mov dword [rsp+32], COL_ED_CURSOR_BG ; bg = white
    call fb_draw_char
    jmp .edc_col_next

.edc_normal_char:
    ; Draw normal character
    mov ecx, r15d                       ; px
    mov edx, eax                        ; py
    mov r8d, edi                        ; char
    mov r9d, COL_ED_TEXT                ; fg = light gray
    mov dword [rsp+32], COL_ED_BG      ; bg = dark blue
    call fb_draw_char

.edc_col_next:
    ; Restore registers that fb_draw_char may have clobbered
    ; (r12-r15 are callee-saved, so they're fine)
    ; ebx, esi need to be restored from stack
    mov ebx, [rsp+36]
    mov esi, [rsp+40]
    inc r14d
    jmp .edc_col_loop

.edc_col_done:
    ; If cursor is at end of line on this row, draw cursor block
    cmp r13d, dword [rel ed_cursor_line]
    jne .edc_row_next
    mov eax, dword [rel ed_cursor_col]
    cmp eax, r14d                        ; cursor_col >= last rendered col?
    jl .edc_row_next
    cmp eax, dword [rsp+84]             ; cursor_col < visible_cols?
    jge .edc_row_next
    cmp dword [rel ed_cursor_vis], 0
    je .edc_row_next

    ; Draw cursor at end of line
    mov ecx, eax
    imul ecx, ecx, ED_FONT_W
    add ecx, dword [rsp+64]             ; px = cx + cursor_col * ED_FONT_W
    mov edx, r12d
    imul edx, edx, ED_FONT_H
    add edx, dword [rsp+68]             ; py = cy + row * ED_FONT_H
    mov r8d, ' '                        ; space char
    mov r9d, COL_ED_CURSOR_FG
    mov dword [rsp+32], COL_ED_CURSOR_BG
    call fb_draw_char

.edc_row_next:
    inc r12d
    jmp .edc_row_loop

.edc_rows_done:

    ; ---- Draw status line ----
    ; Fill status bar background
    mov ecx, dword [rsp+64]             ; cx
    mov edx, dword [rsp+88]             ; status_y
    mov r8d, dword [rsp+72]             ; cw
    mov r9d, ED_STATUS_H
    mov dword [rsp+32], COL_ED_STATUS_BG
    call fb_fill_rect

    ; Format: "Ln X, Col Y | N chars"
    lea rcx, [rel ed_status_buf]
    mov edx, 64
    lea r8, [rel ed_status_fmt]
    mov r9d, dword [rel ed_cursor_line]
    inc r9d                             ; 1-based line number
    mov eax, dword [rel ed_cursor_col]
    inc eax                             ; 1-based col number
    mov dword [rsp+32], eax
    ; 6th arg: text length — need to call editor_text_length, but that clobbers regs
    ; Use a pre-computed or just show line/col for now
    ; Actually we need the 6th arg. Save what we need and call.
    mov [rsp+44], r9d                   ; save line# to temp
    call editor_text_length
    mov [rsp+48], eax                   ; save text_len

    ; Redo the snprintf call with all args
    lea rcx, [rel ed_status_buf]
    mov edx, 64
    lea r8, [rel ed_status_fmt]
    mov r9d, [rsp+44]                   ; line# (1-based)
    mov eax, dword [rel ed_cursor_col]
    inc eax
    mov dword [rsp+32], eax             ; col# (1-based)
    mov eax, [rsp+48]
    mov dword [rsp+40], eax             ; text_len
    call herb_snprintf

    ; Draw status text
    mov ecx, dword [rsp+64]             ; cx
    add ecx, 12                         ; small left margin (ED_FONT_W)
    mov edx, dword [rsp+88]             ; status_y
    lea r8, [rel ed_status_buf]
    mov r9d, COL_ED_STATUS_FG
    mov dword [rsp+32], COL_ED_STATUS_BG
    call fb_draw_string

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

; ============================================================
; editor_toggle_blink — Toggle cursor blink state
; void editor_toggle_blink(void)
; ============================================================
editor_toggle_blink:
    xor dword [rel ed_cursor_vis], 1
    ret
