; boot/herb_browser.asm — HERB OS HTML Tokenizer
;
; Converts raw HTML bytes into a token stream.
; Batch tokenization: html_tokenize_all() fills token buffer in one call.
; All tokens use offset+length into the source — no string copies.
;
; Assembled with: nasm -f win64 herb_browser.asm -o herb_browser.o

[bits 64]
default rel

; ============================================================
; CONSTANTS
; ============================================================

; Token types
TOK_DOCTYPE     equ 0
TOK_START_TAG   equ 1
TOK_END_TAG     equ 2
TOK_TEXT        equ 3
TOK_SELF_CLOSE  equ 4
TOK_EOF         equ 5

; FSM states
STATE_DATA          equ 0
STATE_TAG_OPEN      equ 1
STATE_TAG_NAME      equ 2
STATE_END_TAG_NAME  equ 3
STATE_BEFORE_ATTR   equ 4
STATE_ATTR_NAME     equ 5
STATE_BEFORE_ATTR_VAL equ 6
STATE_ATTR_VAL_DQ   equ 7
STATE_ATTR_VAL_SQ   equ 8
STATE_ATTR_VAL_UQ   equ 9
STATE_SELF_CLOSE    equ 10
STATE_MARKUP_DECL   equ 11
STATE_COMMENT       equ 12
STATE_DOCTYPE       equ 13

; Limits
MAX_TOKENS      equ 1024
MAX_ATTRS       equ 256
TOKEN_SIZE      equ 32      ; bytes per token
ATTR_SIZE       equ 16      ; bytes per attribute

; DOM node types
DOM_NODE_ELEMENT   equ 1
DOM_NODE_TEXT      equ 3
DOM_NODE_DOCUMENT  equ 9

; DOM node struct offsets (32 bytes, all dword)
DOM_NODE_TYPE        equ 0    ; u32 — 1=element, 3=text, 9=document
DOM_NODE_TAG_START   equ 4    ; u32 — offset into source HTML
DOM_NODE_TAG_LEN     equ 8    ; u32 — tag name length (or text length)
DOM_NODE_PARENT      equ 12   ; i32 — parent node index (-1 = none)
DOM_NODE_FIRST_CHILD equ 16   ; i32 — first child index (-1 = none)
DOM_NODE_NEXT_SIB    equ 20   ; i32 — next sibling index (-1 = none)
DOM_NODE_ATTR_IDX    equ 24   ; u32 — index into html_attr_pool
DOM_NODE_ATTR_COUNT  equ 28   ; u32 — number of attributes

; DOM limits
DOM_MAX_NODES   equ 512
DOM_NODE_SIZE   equ 32
DOM_STACK_SIZE  equ 64

; ============================================================
; EXTERNS
; ============================================================
extern herb_snprintf
extern serial_print
extern tcp_recv_buf
extern tcp_recv_len
extern tcp_recv_done
extern http_body_offset
extern http_body_len
extern shell_output_print
extern intern
extern graph_find_container_by_name
extern create_entity
extern container_remove
extern herb_set_prop_int
extern herb_entity_prop_int
extern herb_container_count
extern herb_container_entity
extern g_container_entity_counts
extern g_container_entities

extern fb_fill_rect
extern fb_draw_char
extern fb_draw_string
extern wm_set_clip
extern wm_clear_clip
extern http_get
extern http_poll_state
extern net_poll_rx
extern net_present

; ============================================================
; GLOBALS
; ============================================================
global html_tokenize_all        ; (RCX=src, EDX=len) -> EAX=token_count
global html_tok_at              ; (ECX=index) -> RAX=token_ptr
global html_print_tokens        ; () -> void
global browser_tokenize_cmd     ; () -> void (shell command handler)
global html_tok_buf
global html_tok_count
global html_attr_pool
global html_attr_count
global browser_dom_cmd
global browser_layout_cmd
global browser_paint_cmd
global browser_draw_fn
global browser_browse_cmd

; ============================================================
; DATA
; ============================================================
section .data

; Embedded test HTML for /tokenize without a prior HTTP fetch
html_test_src:
    db '<!DOCTYPE html><html><head><title>Test</title></head>'
    db '<body><h1>Hello</h1><p>A <a href="http://x.com">link</a>.</p>'
    db '<br/></body></html>'
html_test_src_end:
HTML_TEST_LEN equ html_test_src_end - html_test_src

; Format strings
str_tok_doctype:    db "[HTML_TOK] DOCTYPE", 10, 0
str_tok_start:      db '[HTML_TOK] START_TAG "', 0
str_tok_end:        db '[HTML_TOK] END_TAG "', 0
str_tok_text:       db "[HTML_TOK] TEXT (%d bytes)", 10, 0
str_tok_self:       db '[HTML_TOK] SELF_CLOSE "', 0
str_tok_eof:        db "[HTML_TOK] EOF", 10, 0
str_tok_close:      db '"', 10, 0               ; closing quote + newline
str_tok_attr:       db ' %s="%s"', 0
str_tok_count:      db "[HTML_TOK] %d tokens, %d attrs", 10, 0
str_la_tokenize:    db "Tokenize: %d tokens", 0

; DOM format strings
str_dom_text:       db "TEXT (%d bytes)", 0
str_dom_count:      db "[DOM] %d nodes", 10, 0
str_la_dom:         db "DOM: %d nodes", 0

; Layout strings — container/type names
str_browser_nodes:  db "browser.NODES", 0
str_browser_node:   db "browser.Node", 0

; Layout property names
str_prop_display:    db "display", 0
str_prop_margin_top: db "margin_top", 0
str_prop_margin_bot: db "margin_bot", 0
str_prop_margin_left: db "margin_left", 0
str_prop_padding:    db "padding", 0
str_prop_node_idx:   db "node_idx", 0
str_prop_parent_idx: db "parent_idx", 0
str_prop_depth:      db "depth", 0
str_prop_is_text:    db "is_text", 0
str_prop_text_len:   db "text_len", 0
str_prop_layout_x:   db "layout_x", 0
str_prop_layout_y:   db "layout_y", 0
str_prop_layout_w:   db "layout_w", 0
str_prop_layout_h:   db "layout_h", 0

; Tag name strings for defaults lookup
str_tag_html:   db "html", 0
str_tag_body:   db "body", 0
str_tag_h1:     db "h1", 0
str_tag_h2:     db "h2", 0
str_tag_h3:     db "h3", 0
str_tag_p:      db "p", 0
str_tag_div:    db "div", 0
str_tag_ul:     db "ul", 0
str_tag_ol:     db "ol", 0
str_tag_li:     db "li", 0
str_tag_hr:     db "hr", 0
str_tag_br:     db "br", 0
str_tag_a:      db "a", 0
str_tag_span:   db "span", 0
str_tag_em:     db "em", 0
str_tag_strong: db "strong", 0
str_tag_b:      db "b", 0
str_tag_i:      db "i", 0
str_tag_u:      db "u", 0
str_tag_code:   db "code", 0
str_tag_img:    db "img", 0
str_tag_head:   db "head", 0
str_tag_title:  db "title", 0
str_tag_meta:   db "meta", 0
str_tag_link:   db "link", 0
str_tag_script: db "script", 0
str_tag_style:  db "style", 0

; Layout format strings
str_layout_hdr:     db "[LAYOUT] %d nodes, viewport=%dpx", 10, 0
str_layout_elem:    db "[LAYOUT] ", 0
str_layout_geom:    db " x=%d y=%d w=%d h=%d", 0
str_layout_disp:    db " BLOCK d=%d", 10, 0
str_layout_inline:  db " INLINE d=%d", 10, 0
str_layout_none:    db " NONE d=%d", 10, 0
str_layout_textfmt: db " len=%d", 0
str_la_layout:      db "Layout: %d nodes", 0

; Paint format strings
str_paint_hdr:      db "[PAINT] %d nodes, %d visible", 10, 0
str_la_paint:       db "Paint: %d visible", 0
str_paint_hint:     db "Type /paint", 0


; Browse format strings
str_browse_fetch:   db "[BROWSE] fetching ", 0
str_browse_dots:    db "...", 10, 0
str_browse_done:    db "[BROWSE] done", 10, 0
str_browse_fail:    db "[BROWSE] failed (timeout or no data)", 10, 0
str_browse_no_nic:  db "[BROWSE] no NIC available", 10, 0
str_browse_recv:    db "[BROWSE] received %d bytes body", 10, 0
str_browse_slash:   db "/", 0
str_browse_default: db "example.com", 0
str_la_browse:      db "Browse: fetching...", 0
str_la_browse_done: db "Browse: done", 0
str_la_browse_fail: db "Browse: failed", 0
str_la_browse_nonet: db "Browse: no NIC", 0

; Entity name prefix for layout nodes
str_node_prefix:    db "n", 0
str_node_fmt:       db "n%d", 0

; Layout temp buffer (256 bytes, larger than html_tmp_buf)
; Uses a second buffer to avoid conflicting with html_tmp_buf

; ============================================================
; BSS
; ============================================================
section .bss
alignb 16
html_tok_buf:       resb 32768      ; 1024 tokens x 32 bytes
html_attr_pool:     resb 4096       ; 256 attributes x 16 bytes
html_tok_count:     resd 1          ; tokens emitted
html_attr_count:    resd 1          ; attributes allocated
html_last_src:      resq 1          ; source pointer (for print_tokens)
html_last_len:      resd 1          ; source length
html_tmp_buf:       resb 128        ; temp buffer for snprintf/tag name extraction

; DOM tree buffers
alignb 16
dom_nodes:          resb 512 * 32   ; 16,384 bytes — node pool
dom_last_child:     resd 512        ; 2,048 bytes — parallel last_child array
dom_node_count:     resd 1          ; nodes allocated
dom_root:           resd 1          ; root node index (always 0)
dom_stack:          resd 64         ; open-element stack (node indices)
dom_stack_top:      resd 1          ; stack pointer

; Layout engine BSS
alignb 16
layout_entity_ids:  resd 512        ; maps node_idx -> entity_id
layout_node_count:  resd 1          ; number of layout entities created
layout_container_idx: resd 1        ; cached browser.NODES container index
layout_type_id:     resd 1          ; cached interned "browser.Node"
layout_tmp_buf:     resb 256        ; temp buffer for layout formatting
layout_name_buf:    resb 16         ; temp buffer for entity name ("n0", "n1", ...)

; Paint cache BSS
alignb 16
paint_cache:        resb 512 * 32   ; 16,384 bytes (32 bytes per entry x 512 max)
paint_cache_count:  resd 1          ; number of entries in paint cache
paint_ready:        resd 1          ; 1 = cache is valid, draw_fn should paint

; Browse BSS
browse_domain_buf:  resb 64         ; parsed domain string for /browse

; ============================================================
; TEXT
; ============================================================
section .text

; ============================================================
; html_tokenize_all(RCX=src, EDX=len) -> EAX=token_count
;
; Tokenizes HTML source into html_tok_buf.
; Register allocation:
;   RBX  = source base pointer
;   R12d = scan position (current byte index)
;   R13d = source length
;   R14d = current FSM state
;   R15d = token count
;   ESI  = attribute count
;
; Stack locals (8 pushes + sub rsp, 72):
;   [rsp+0..31]  = shadow space
;   [rsp+32]     = tag_start
;   [rsp+36]     = text_start (-1 = not accumulating)
;   [rsp+40]     = attr_name_start
;   [rsp+44]     = attr_name_len
;   [rsp+48]     = attr_val_start
;   [rsp+52]     = dash_count
;   [rsp+56]     = cur_tag_attr_idx
;   [rsp+60]     = cur_tag_attr_count
;   [rsp+64]     = saved RDI (temp)
; ============================================================
html_tokenize_all:
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72                     ; 8 pushes (64) + 8 (call) + 72 = 144, 144%16=0

    ; Save args
    mov rbx, rcx                    ; source base
    mov r13d, edx                   ; source length

    ; Save source pointer for print_tokens
    mov [rel html_last_src], rcx
    mov [rel html_last_len], edx

    ; Initialize
    xor r12d, r12d                  ; pos = 0
    xor r14d, r14d                  ; state = STATE_DATA
    xor r15d, r15d                  ; token_count = 0
    xor esi, esi                    ; attr_count = 0
    mov dword [rsp+36], -1          ; text_start = -1 (not accumulating)

.scan_loop:
    cmp r12d, r13d
    jge .scan_done

    movzx eax, byte [rbx + r12]    ; load current byte

    ; Dispatch on state
    cmp r14d, STATE_DATA
    je .state_data
    cmp r14d, STATE_TAG_OPEN
    je .state_tag_open
    cmp r14d, STATE_TAG_NAME
    je .state_tag_name
    cmp r14d, STATE_END_TAG_NAME
    je .state_end_tag_name
    cmp r14d, STATE_BEFORE_ATTR
    je .state_before_attr
    cmp r14d, STATE_ATTR_NAME
    je .state_attr_name
    cmp r14d, STATE_BEFORE_ATTR_VAL
    je .state_before_attr_val
    cmp r14d, STATE_ATTR_VAL_DQ
    je .state_attr_val_dq
    cmp r14d, STATE_ATTR_VAL_SQ
    je .state_attr_val_sq
    cmp r14d, STATE_ATTR_VAL_UQ
    je .state_attr_val_uq
    cmp r14d, STATE_SELF_CLOSE
    je .state_self_close
    cmp r14d, STATE_MARKUP_DECL
    je .state_markup_decl
    cmp r14d, STATE_COMMENT
    je .state_comment
    cmp r14d, STATE_DOCTYPE
    je .state_doctype
    ; Unknown state — reset to DATA
    xor r14d, r14d
    jmp .scan_loop

; ---- STATE_DATA ----
.state_data:
    cmp al, '<'
    je .data_tag_open
    ; Accumulating text — set text_start if not set
    cmp dword [rsp+36], -1
    jne .data_continue
    mov [rsp+36], r12d              ; text_start = pos
.data_continue:
    inc r12d
    jmp .scan_loop

.data_tag_open:
    ; Emit TEXT token if we were accumulating
    cmp dword [rsp+36], -1
    je .data_no_text
    ; Emit TEXT: start=text_start, length=pos-text_start
    cmp r15d, MAX_TOKENS
    jge .scan_done
    movsxd rax, r15d
    shl rax, 5
    lea rcx, [rel html_tok_buf]
    add rcx, rax
    mov dword [rcx], TOK_TEXT       ; type
    mov eax, [rsp+36]
    mov [rcx+4], eax                ; start
    mov eax, r12d
    sub eax, [rsp+36]
    mov [rcx+8], eax                ; length
    mov dword [rcx+12], 0           ; attr_count
    mov dword [rcx+16], 0           ; attr_idx
    mov dword [rcx+20], 0           ; reserved
    mov qword [rcx+24], 0
    inc r15d
    mov dword [rsp+36], -1          ; reset text_start
.data_no_text:
    mov r14d, STATE_TAG_OPEN
    inc r12d
    jmp .scan_loop

; ---- STATE_TAG_OPEN ----
; We just saw '<', now check next char
.state_tag_open:
    cmp al, '/'
    je .tag_open_end
    cmp al, '!'
    je .tag_open_markup
    ; Check if alpha (a-z, A-Z)
    cmp al, 'A'
    jb .tag_open_text
    cmp al, 'Z'
    jbe .tag_open_start
    cmp al, 'a'
    jb .tag_open_text
    cmp al, 'z'
    jbe .tag_open_start
    jmp .tag_open_text

.tag_open_start:
    ; Start of tag name — record tag_start (the char after '<')
    mov [rsp+32], r12d              ; tag_start = pos
    mov dword [rsp+60], 0           ; cur_tag_attr_count = 0
    mov [rsp+56], esi               ; cur_tag_attr_idx = current attr_count
    mov r14d, STATE_TAG_NAME
    inc r12d
    jmp .scan_loop

.tag_open_end:
    ; '</' — start of end tag
    mov r14d, STATE_END_TAG_NAME
    inc r12d                        ; skip the '/'
    ; Record tag_start as next position
    mov [rsp+32], r12d
    jmp .scan_loop

.tag_open_markup:
    ; '<!' — could be comment or DOCTYPE
    mov r14d, STATE_MARKUP_DECL
    inc r12d
    jmp .scan_loop

.tag_open_text:
    ; Not a valid tag — treat '<' as text
    ; Set text_start to pos-1 (the '<') if not already accumulating
    cmp dword [rsp+36], -1
    jne .tag_open_text_cont
    mov eax, r12d
    dec eax                         ; the '<' position
    mov [rsp+36], eax
.tag_open_text_cont:
    mov r14d, STATE_DATA
    jmp .scan_loop                  ; re-process current char in DATA state

; ---- STATE_TAG_NAME ----
; Accumulating start tag name
.state_tag_name:
    cmp al, ' '
    je .tag_name_to_attr
    cmp al, 9                       ; tab
    je .tag_name_to_attr
    cmp al, 10                      ; LF
    je .tag_name_to_attr
    cmp al, 13                      ; CR
    je .tag_name_to_attr
    cmp al, '>'
    je .tag_name_close
    cmp al, '/'
    je .tag_name_self_close
    ; Still in tag name
    inc r12d
    jmp .scan_loop

.tag_name_to_attr:
    ; Whitespace — done with tag name, now looking for attributes
    mov [rsp+64], r12d              ; tag_name_end = pos (before whitespace)
    mov r14d, STATE_BEFORE_ATTR
    inc r12d
    jmp .scan_loop

.tag_name_close:
    ; '>' — emit START_TAG token
    cmp r15d, MAX_TOKENS
    jge .scan_done
    movsxd rax, r15d
    shl rax, 5
    lea rcx, [rel html_tok_buf]
    add rcx, rax
    mov dword [rcx], TOK_START_TAG
    mov eax, [rsp+32]
    mov [rcx+4], eax                ; start = tag_start
    mov eax, r12d
    sub eax, [rsp+32]
    mov [rcx+8], eax                ; length = pos - tag_start
    mov eax, [rsp+60]
    mov [rcx+12], eax               ; attr_count
    mov eax, [rsp+56]
    mov [rcx+16], eax               ; attr_idx
    mov dword [rcx+20], 0
    mov qword [rcx+24], 0
    inc r15d
    mov r14d, STATE_DATA
    inc r12d
    jmp .scan_loop

.tag_name_self_close:
    ; '/' in tag name — potential self-close
    mov [rsp+64], r12d              ; tag_name_end = pos (before '/')
    mov r14d, STATE_SELF_CLOSE
    inc r12d
    jmp .scan_loop

; ---- STATE_END_TAG_NAME ----
.state_end_tag_name:
    cmp al, '>'
    je .end_tag_close
    cmp al, ' '
    je .end_tag_skip_ws
    cmp al, 9
    je .end_tag_skip_ws
    ; Still accumulating end tag name
    inc r12d
    jmp .scan_loop

.end_tag_skip_ws:
    ; Whitespace after end tag name — skip until '>'
    inc r12d
    jmp .scan_loop

.end_tag_close:
    ; '>' — emit END_TAG token
    cmp r15d, MAX_TOKENS
    jge .scan_done
    movsxd rax, r15d
    shl rax, 5
    lea rcx, [rel html_tok_buf]
    add rcx, rax
    mov dword [rcx], TOK_END_TAG
    mov eax, [rsp+32]
    mov [rcx+4], eax                ; start = tag_start
    mov eax, r12d
    sub eax, [rsp+32]
    mov [rcx+8], eax                ; length = pos - tag_start
    mov dword [rcx+12], 0
    mov dword [rcx+16], 0
    mov dword [rcx+20], 0
    mov qword [rcx+24], 0
    inc r15d
    mov r14d, STATE_DATA
    inc r12d
    jmp .scan_loop

; ---- STATE_BEFORE_ATTR ----
; After tag name or previous attribute, looking for attr name or '>' or '/'
.state_before_attr:
    cmp al, ' '
    je .before_attr_skip
    cmp al, 9
    je .before_attr_skip
    cmp al, 10
    je .before_attr_skip
    cmp al, 13
    je .before_attr_skip
    cmp al, '>'
    je .before_attr_close
    cmp al, '/'
    je .before_attr_self
    ; Start of attribute name
    mov [rsp+40], r12d              ; attr_name_start = pos
    mov dword [rsp+44], 0           ; attr_name_len = 0
    mov r14d, STATE_ATTR_NAME
    inc r12d
    jmp .scan_loop

.before_attr_skip:
    inc r12d
    jmp .scan_loop

.before_attr_close:
    ; '>' — emit START_TAG with collected attrs
    cmp r15d, MAX_TOKENS
    jge .scan_done
    movsxd rax, r15d
    shl rax, 5
    lea rcx, [rel html_tok_buf]
    add rcx, rax
    mov dword [rcx], TOK_START_TAG
    mov eax, [rsp+32]
    mov [rcx+4], eax                ; start = tag_start
    mov eax, [rsp+64]
    sub eax, [rsp+32]
    mov [rcx+8], eax                ; length = tag_name_end - tag_start
    mov eax, [rsp+60]
    mov [rcx+12], eax               ; attr_count
    mov eax, [rsp+56]
    mov [rcx+16], eax               ; attr_idx
    mov dword [rcx+20], 0
    mov qword [rcx+24], 0
    inc r15d
    mov r14d, STATE_DATA
    inc r12d
    jmp .scan_loop

.before_attr_self:
    mov r14d, STATE_SELF_CLOSE
    inc r12d
    jmp .scan_loop

; ---- STATE_ATTR_NAME ----
; Accumulating attribute name
.state_attr_name:
    cmp al, '='
    je .attr_name_eq
    cmp al, ' '
    je .attr_name_bool
    cmp al, 9
    je .attr_name_bool
    cmp al, '>'
    je .attr_name_bool_close
    cmp al, '/'
    je .attr_name_bool_self
    ; Still in attr name
    inc r12d
    jmp .scan_loop

.attr_name_eq:
    ; '=' — compute name_len, go to BEFORE_ATTR_VAL
    mov eax, r12d
    sub eax, [rsp+40]
    mov [rsp+44], eax               ; attr_name_len
    mov r14d, STATE_BEFORE_ATTR_VAL
    inc r12d                        ; skip '='
    jmp .scan_loop

.attr_name_bool:
    ; Whitespace — boolean attribute (no value)
    ; Emit attr with value_len=0
    cmp esi, MAX_ATTRS
    jge .attr_name_bool_skip
    movsxd rax, esi
    shl rax, 4                      ; * ATTR_SIZE
    lea rcx, [rel html_attr_pool]
    add rcx, rax
    mov eax, [rsp+40]
    mov [rcx], eax                  ; name_start
    mov eax, r12d
    sub eax, [rsp+40]
    mov [rcx+4], eax                ; name_len
    mov dword [rcx+8], 0            ; value_start = 0
    mov dword [rcx+12], 0           ; value_len = 0
    inc esi
    mov eax, [rsp+60]
    inc eax
    mov [rsp+60], eax               ; cur_tag_attr_count++
.attr_name_bool_skip:
    mov r14d, STATE_BEFORE_ATTR
    inc r12d
    jmp .scan_loop

.attr_name_bool_close:
    ; '>' with boolean attr pending — emit attr then emit tag
    cmp esi, MAX_ATTRS
    jge .attr_bool_close_skip
    movsxd rax, esi
    shl rax, 4
    lea rcx, [rel html_attr_pool]
    add rcx, rax
    mov eax, [rsp+40]
    mov [rcx], eax
    mov eax, r12d
    sub eax, [rsp+40]
    mov [rcx+4], eax
    mov dword [rcx+8], 0
    mov dword [rcx+12], 0
    inc esi
    mov eax, [rsp+60]
    inc eax
    mov [rsp+60], eax
.attr_bool_close_skip:
    jmp .before_attr_close          ; emit the tag

.attr_name_bool_self:
    ; '/' with boolean attr pending
    cmp esi, MAX_ATTRS
    jge .attr_bool_self_skip
    movsxd rax, esi
    shl rax, 4
    lea rcx, [rel html_attr_pool]
    add rcx, rax
    mov eax, [rsp+40]
    mov [rcx], eax
    mov eax, r12d
    sub eax, [rsp+40]
    mov [rcx+4], eax
    mov dword [rcx+8], 0
    mov dword [rcx+12], 0
    inc esi
    mov eax, [rsp+60]
    inc eax
    mov [rsp+60], eax
.attr_bool_self_skip:
    mov r14d, STATE_SELF_CLOSE
    inc r12d
    jmp .scan_loop

; ---- STATE_BEFORE_ATTR_VAL ----
; After '=' — expect quote or unquoted value
.state_before_attr_val:
    cmp al, '"'
    je .attr_val_dq_start
    cmp al, "'"
    je .attr_val_sq_start
    cmp al, ' '
    je .before_val_skip
    cmp al, 9
    je .before_val_skip
    ; Unquoted value — start immediately
    mov [rsp+48], r12d              ; attr_val_start = pos
    mov r14d, STATE_ATTR_VAL_UQ
    inc r12d
    jmp .scan_loop

.before_val_skip:
    inc r12d
    jmp .scan_loop

.attr_val_dq_start:
    ; Double-quoted value starts at next char
    inc r12d                        ; skip '"'
    mov [rsp+48], r12d              ; attr_val_start = pos after quote
    mov r14d, STATE_ATTR_VAL_DQ
    jmp .scan_loop

.attr_val_sq_start:
    ; Single-quoted value
    inc r12d
    mov [rsp+48], r12d
    mov r14d, STATE_ATTR_VAL_SQ
    jmp .scan_loop

; ---- STATE_ATTR_VAL_DQ ----
; Inside double-quoted attribute value
.state_attr_val_dq:
    cmp al, '"'
    je .attr_val_dq_end
    inc r12d
    jmp .scan_loop

.attr_val_dq_end:
    ; Closing '"' — emit attribute
    cmp esi, MAX_ATTRS
    jge .attr_val_dq_skip
    movsxd rax, esi
    shl rax, 4
    lea rcx, [rel html_attr_pool]
    add rcx, rax
    mov eax, [rsp+40]
    mov [rcx], eax                  ; name_start
    mov eax, [rsp+44]
    mov [rcx+4], eax                ; name_len
    mov eax, [rsp+48]
    mov [rcx+8], eax                ; value_start
    mov eax, r12d
    sub eax, [rsp+48]
    mov [rcx+12], eax               ; value_len
    inc esi
    mov eax, [rsp+60]
    inc eax
    mov [rsp+60], eax               ; cur_tag_attr_count++
.attr_val_dq_skip:
    mov r14d, STATE_BEFORE_ATTR
    inc r12d                        ; skip closing '"'
    jmp .scan_loop

; ---- STATE_ATTR_VAL_SQ ----
; Inside single-quoted attribute value
.state_attr_val_sq:
    cmp al, "'"
    je .attr_val_sq_end
    inc r12d
    jmp .scan_loop

.attr_val_sq_end:
    cmp esi, MAX_ATTRS
    jge .attr_val_sq_skip
    movsxd rax, esi
    shl rax, 4
    lea rcx, [rel html_attr_pool]
    add rcx, rax
    mov eax, [rsp+40]
    mov [rcx], eax
    mov eax, [rsp+44]
    mov [rcx+4], eax
    mov eax, [rsp+48]
    mov [rcx+8], eax
    mov eax, r12d
    sub eax, [rsp+48]
    mov [rcx+12], eax
    inc esi
    mov eax, [rsp+60]
    inc eax
    mov [rsp+60], eax
.attr_val_sq_skip:
    mov r14d, STATE_BEFORE_ATTR
    inc r12d
    jmp .scan_loop

; ---- STATE_ATTR_VAL_UQ ----
; Unquoted attribute value — ends on whitespace or '>'
.state_attr_val_uq:
    cmp al, ' '
    je .attr_val_uq_end
    cmp al, 9
    je .attr_val_uq_end
    cmp al, '>'
    je .attr_val_uq_close
    inc r12d
    jmp .scan_loop

.attr_val_uq_end:
    ; Emit attribute
    cmp esi, MAX_ATTRS
    jge .attr_val_uq_skip
    movsxd rax, esi
    shl rax, 4
    lea rcx, [rel html_attr_pool]
    add rcx, rax
    mov eax, [rsp+40]
    mov [rcx], eax
    mov eax, [rsp+44]
    mov [rcx+4], eax
    mov eax, [rsp+48]
    mov [rcx+8], eax
    mov eax, r12d
    sub eax, [rsp+48]
    mov [rcx+12], eax
    inc esi
    mov eax, [rsp+60]
    inc eax
    mov [rsp+60], eax
.attr_val_uq_skip:
    mov r14d, STATE_BEFORE_ATTR
    inc r12d
    jmp .scan_loop

.attr_val_uq_close:
    ; '>' after unquoted value — emit attr then emit tag
    cmp esi, MAX_ATTRS
    jge .attr_val_uq_close_skip
    movsxd rax, esi
    shl rax, 4
    lea rcx, [rel html_attr_pool]
    add rcx, rax
    mov eax, [rsp+40]
    mov [rcx], eax
    mov eax, [rsp+44]
    mov [rcx+4], eax
    mov eax, [rsp+48]
    mov [rcx+8], eax
    mov eax, r12d
    sub eax, [rsp+48]
    mov [rcx+12], eax
    inc esi
    mov eax, [rsp+60]
    inc eax
    mov [rsp+60], eax
.attr_val_uq_close_skip:
    jmp .before_attr_close

; ---- STATE_SELF_CLOSE ----
; After '/' inside a tag — expect '>'
.state_self_close:
    cmp al, '>'
    jne .self_close_not_gt
    ; Emit SELF_CLOSE token
    cmp r15d, MAX_TOKENS
    jge .scan_done
    movsxd rax, r15d
    shl rax, 5
    lea rcx, [rel html_tok_buf]
    add rcx, rax
    mov dword [rcx], TOK_SELF_CLOSE
    mov eax, [rsp+32]
    mov [rcx+4], eax                ; start = tag_start
    mov eax, [rsp+64]
    sub eax, [rsp+32]
    mov [rcx+8], eax                ; length = tag_name_end - tag_start
    mov eax, [rsp+60]
    mov [rcx+12], eax               ; attr_count
    mov eax, [rsp+56]
    mov [rcx+16], eax               ; attr_idx
    mov dword [rcx+20], 0
    mov qword [rcx+24], 0
    inc r15d
    mov r14d, STATE_DATA
    inc r12d
    jmp .scan_loop

.self_close_not_gt:
    ; Not '>' — treat '/' as part of tag, go back to BEFORE_ATTR
    mov r14d, STATE_BEFORE_ATTR
    jmp .scan_loop                  ; re-process current char

; ---- STATE_MARKUP_DECL ----
; After '<!' — check for '--' (comment) or DOCTYPE
.state_markup_decl:
    cmp al, '-'
    je .markup_maybe_comment
    ; Check for DOCTYPE (case-insensitive 'D' or 'd')
    cmp al, 'D'
    je .markup_doctype
    cmp al, 'd'
    je .markup_doctype
    ; Unknown markup — skip to '>'
    jmp .markup_skip_to_close

.markup_maybe_comment:
    ; Check if next char is also '-'
    mov edx, r12d
    inc edx
    cmp edx, r13d
    jge .markup_skip_to_close       ; end of input
    movzx eax, byte [rbx + rdx]
    cmp al, '-'
    jne .markup_skip_to_close
    ; '<!--' comment start
    add r12d, 2                     ; skip '--'
    mov dword [rsp+52], 0           ; dash_count = 0
    mov r14d, STATE_COMMENT
    jmp .scan_loop

.markup_doctype:
    ; DOCTYPE — record start, skip to '>'
    mov eax, r12d
    sub eax, 2                      ; back to '<' position
    mov [rsp+32], eax               ; tag_start = '<' position
    mov r14d, STATE_DOCTYPE
    inc r12d
    jmp .scan_loop

.markup_skip_to_close:
    ; Skip everything until '>'
    cmp al, '>'
    je .markup_skip_done
    inc r12d
    cmp r12d, r13d
    jge .scan_done
    movzx eax, byte [rbx + r12]
    jmp .markup_skip_to_close
.markup_skip_done:
    mov r14d, STATE_DATA
    inc r12d
    jmp .scan_loop

; ---- STATE_COMMENT ----
; Inside <!-- ... --> comment — scan for '-->'
.state_comment:
    cmp al, '-'
    je .comment_dash
    ; Not a dash — reset dash counter
    mov dword [rsp+52], 0
    inc r12d
    jmp .scan_loop

.comment_dash:
    mov eax, [rsp+52]
    inc eax
    mov [rsp+52], eax
    cmp eax, 2
    jb .comment_dash_cont
    ; We have 2+ dashes — check if next char is '>'
    mov edx, r12d
    inc edx
    cmp edx, r13d
    jge .comment_dash_cont
    movzx eax, byte [rbx + rdx]
    cmp al, '>'
    jne .comment_dash_cont
    ; '-->' found — end of comment
    add r12d, 2                     ; skip '->'
    mov dword [rsp+52], 0
    mov r14d, STATE_DATA
    jmp .scan_loop

.comment_dash_cont:
    inc r12d
    jmp .scan_loop

; ---- STATE_DOCTYPE ----
; Inside <!DOCTYPE ...> — scan to '>'
.state_doctype:
    cmp al, '>'
    je .doctype_close
    inc r12d
    jmp .scan_loop

.doctype_close:
    ; Emit DOCTYPE token
    cmp r15d, MAX_TOKENS
    jge .scan_done
    movsxd rax, r15d
    shl rax, 5
    lea rcx, [rel html_tok_buf]
    add rcx, rax
    mov dword [rcx], TOK_DOCTYPE
    mov eax, [rsp+32]
    mov [rcx+4], eax                ; start
    mov eax, r12d
    sub eax, [rsp+32]
    inc eax                         ; include the '>'
    mov [rcx+8], eax                ; length
    mov dword [rcx+12], 0
    mov dword [rcx+16], 0
    mov dword [rcx+20], 0
    mov qword [rcx+24], 0
    inc r15d
    mov r14d, STATE_DATA
    inc r12d
    jmp .scan_loop

; ---- End of scan ----
.scan_done:
    ; Emit trailing TEXT token if accumulating
    cmp dword [rsp+36], -1
    je .scan_no_trailing_text
    cmp r15d, MAX_TOKENS
    jge .scan_no_trailing_text
    movsxd rax, r15d
    shl rax, 5
    lea rcx, [rel html_tok_buf]
    add rcx, rax
    mov dword [rcx], TOK_TEXT
    mov eax, [rsp+36]
    mov [rcx+4], eax                ; start = text_start
    mov eax, r13d
    sub eax, [rsp+36]
    mov [rcx+8], eax                ; length = len - text_start
    mov dword [rcx+12], 0
    mov dword [rcx+16], 0
    mov dword [rcx+20], 0
    mov qword [rcx+24], 0
    inc r15d
.scan_no_trailing_text:

    ; Emit EOF token
    cmp r15d, MAX_TOKENS
    jge .scan_skip_eof
    movsxd rax, r15d
    shl rax, 5
    lea rcx, [rel html_tok_buf]
    add rcx, rax
    mov dword [rcx], TOK_EOF
    mov dword [rcx+4], 0
    mov dword [rcx+8], 0
    mov dword [rcx+12], 0
    mov dword [rcx+16], 0
    mov dword [rcx+20], 0
    mov qword [rcx+24], 0
    inc r15d
.scan_skip_eof:

    ; Save counts
    mov [rel html_tok_count], r15d
    mov [rel html_attr_count], esi

    mov eax, r15d                   ; return token count

    add rsp, 72
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
; html_tok_at(ECX=index) -> RAX=token_ptr
; ============================================================
html_tok_at:
    movsxd rax, ecx
    shl rax, 5                      ; * 32
    lea rcx, [rel html_tok_buf]
    add rax, rcx
    ret

; ============================================================
; html_print_tokens() -> void
;
; Iterates token buffer and prints each token to serial.
; ============================================================
html_print_tokens:
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72                     ; shadow + locals, 8*8+8+72=144, 144%16=0

    mov rbx, [rel html_last_src]    ; source pointer
    xor r12d, r12d                  ; token index
    mov r13d, [rel html_tok_count]  ; total tokens

.print_loop:
    cmp r12d, r13d
    jge .print_done

    ; Get token pointer
    movsxd rax, r12d
    shl rax, 5
    lea r14, [rel html_tok_buf]
    add r14, rax                    ; r14 = token ptr

    mov r15d, [r14]                 ; type

    cmp r15d, TOK_DOCTYPE
    je .print_doctype
    cmp r15d, TOK_START_TAG
    je .print_start
    cmp r15d, TOK_END_TAG
    je .print_end
    cmp r15d, TOK_TEXT
    je .print_text
    cmp r15d, TOK_SELF_CLOSE
    je .print_self
    cmp r15d, TOK_EOF
    je .print_eof
    jmp .print_next

.print_doctype:
    lea rcx, [rel str_tok_doctype]
    call serial_print
    jmp .print_next

.print_start:
    ; Print '[HTML_TOK] START_TAG "tagname"'
    lea rcx, [rel str_tok_start]
    call serial_print
    ; Extract tag name from source into tmp_buf
    mov edi, [r14+4]                ; start offset
    mov ecx, [r14+8]               ; length
    cmp ecx, 120
    jbe .ps_len_ok
    mov ecx, 120
.ps_len_ok:
    ; Copy tag name to tmp_buf (src = rbx + rdi)
    lea rax, [rel html_tmp_buf]
    lea r8, [rbx + rdi]            ; source base + offset
    xor edx, edx
.ps_copy:
    cmp edx, ecx
    jge .ps_copy_done
    movzx r9d, byte [r8 + rdx]
    mov [rax + rdx], r9b
    inc edx
    jmp .ps_copy
.ps_copy_done:
    mov byte [rax + rdx], 0         ; null-terminate
    lea rcx, [rel html_tmp_buf]
    call serial_print
    ; Print closing quote
    lea rcx, [rel str_tok_close]
    call serial_print
    ; Print attributes if any
    mov ecx, [r14+12]              ; attr_count
    test ecx, ecx
    jz .print_next
    mov esi, [r14+16]              ; attr_idx (first attr index)
    mov edi, ecx                   ; attr count
.ps_attr_loop:
    test edi, edi
    jz .print_next
    ; Get attr pointer
    movsxd rax, esi
    shl rax, 4
    lea r8, [rel html_attr_pool]
    add r8, rax
    ; Extract attr name
    mov eax, [r8]                  ; name_start
    mov ecx, [r8+4]               ; name_len
    cmp ecx, 60
    jbe .psa_nlen_ok
    mov ecx, 60
.psa_nlen_ok:
    lea rdx, [rel html_tmp_buf]
    lea r10, [rbx + rax]           ; source base + name_start
    xor r9d, r9d
.psa_ncopy:
    cmp r9d, ecx
    jge .psa_ncopy_done
    movzx r11d, byte [r10 + r9]
    mov [rdx + r9], r11b
    inc r9d
    jmp .psa_ncopy
.psa_ncopy_done:
    mov byte [rdx + r9], 0
    ; Print " attrname="
    lea rcx, [rel html_tmp_buf]
    call serial_print
    ; Now print "=" and value
    ; Reload attr pointer (registers may be clobbered)
    movsxd rax, esi
    shl rax, 4
    lea r8, [rel html_attr_pool]
    add r8, rax
    ; Extract attr value
    mov eax, [r8+8]               ; value_start
    mov ecx, [r8+12]              ; value_len
    cmp ecx, 60
    jbe .psa_vlen_ok
    mov ecx, 60
.psa_vlen_ok:
    lea rdx, [rel html_tmp_buf]
    lea r10, [rbx + rax]           ; source base + value_start
    ; Write '=' first
    mov byte [rdx], '='
    xor r9d, r9d
.psa_vcopy:
    cmp r9d, ecx
    jge .psa_vcopy_done
    movzx r11d, byte [r10 + r9]
    mov [rdx + r9 + 1], r11b
    inc r9d
    jmp .psa_vcopy
.psa_vcopy_done:
    mov byte [rdx + r9 + 1], 0
    lea rcx, [rel html_tmp_buf]
    call serial_print

    inc esi                        ; next attr
    dec edi
    jmp .ps_attr_loop

.print_end:
    lea rcx, [rel str_tok_end]
    call serial_print
    ; Extract tag name
    mov edi, [r14+4]
    mov ecx, [r14+8]
    cmp ecx, 120
    jbe .pe_len_ok
    mov ecx, 120
.pe_len_ok:
    lea rax, [rel html_tmp_buf]
    lea r8, [rbx + rdi]            ; source base + offset
    xor edx, edx
.pe_copy:
    cmp edx, ecx
    jge .pe_copy_done
    movzx r9d, byte [r8 + rdx]
    mov [rax + rdx], r9b
    inc edx
    jmp .pe_copy
.pe_copy_done:
    mov byte [rax + rdx], 0
    lea rcx, [rel html_tmp_buf]
    call serial_print
    lea rcx, [rel str_tok_close]
    call serial_print
    jmp .print_next

.print_text:
    ; Print TEXT (N bytes)
    lea rcx, [rel html_tmp_buf]
    mov edx, 128
    lea r8, [rel str_tok_text]
    mov r9d, [r14+8]               ; length
    call herb_snprintf
    lea rcx, [rel html_tmp_buf]
    call serial_print
    jmp .print_next

.print_self:
    lea rcx, [rel str_tok_self]
    call serial_print
    ; Extract tag name
    mov edi, [r14+4]
    mov ecx, [r14+8]
    cmp ecx, 120
    jbe .psc_len_ok
    mov ecx, 120
.psc_len_ok:
    lea rax, [rel html_tmp_buf]
    lea r8, [rbx + rdi]            ; source base + offset
    xor edx, edx
.psc_copy:
    cmp edx, ecx
    jge .psc_copy_done
    movzx r9d, byte [r8 + rdx]
    mov [rax + rdx], r9b
    inc edx
    jmp .psc_copy
.psc_copy_done:
    mov byte [rax + rdx], 0
    lea rcx, [rel html_tmp_buf]
    call serial_print
    lea rcx, [rel str_tok_close]
    call serial_print
    jmp .print_next

.print_eof:
    lea rcx, [rel str_tok_eof]
    call serial_print
    jmp .print_next

.print_next:
    inc r12d
    jmp .print_loop

.print_done:
    ; Print summary: N tokens, M attrs
    lea rcx, [rel html_tmp_buf]
    mov edx, 128
    lea r8, [rel str_tok_count]
    mov r9d, [rel html_tok_count]
    movsxd rax, dword [rel html_attr_count]
    mov [rsp+32], rax
    call herb_snprintf
    lea rcx, [rel html_tmp_buf]
    call serial_print

    add rsp, 72
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
; browser_tokenize_cmd() -> void
;
; Shell command handler for /tokenize.
; Uses HTTP body if available, otherwise embedded test HTML.
; ============================================================
browser_tokenize_cmd:
    push rbp
    push rbx
    push rsi
    sub rsp, 40                     ; shadow + align: 3*8+8+40=72, 72%16=0? 3 pushes=24, +8(call)=32, +40=72. 72%16=8. Need 48.
    ; Fix alignment: 3 pushes (24) + 8 (call) = 32. sub rsp, 48 => 32+48=80. 80%16=0.
    add rsp, 40                     ; undo wrong sub
    sub rsp, 48                     ; correct alignment

    ; Check if we have an HTTP response
    cmp dword [rel tcp_recv_done], 1
    jne .btc_use_test
    cmp dword [rel http_body_len], 0
    jle .btc_use_test

    ; Use HTTP body
    lea rcx, [rel tcp_recv_buf]
    movsxd rax, dword [rel http_body_offset]
    add rcx, rax                    ; src = tcp_recv_buf + body_offset
    mov edx, [rel http_body_len]    ; len = body_len
    jmp .btc_tokenize

.btc_use_test:
    ; Use embedded test HTML
    lea rcx, [rel html_test_src]
    mov edx, HTML_TEST_LEN

.btc_tokenize:
    call html_tokenize_all
    mov ebx, eax                    ; save token count

    call html_print_tokens

    ; Format summary for shell output window
    lea rcx, [rel html_tmp_buf]
    mov edx, 128
    lea r8, [rel str_la_tokenize]
    mov r9d, ebx
    call herb_snprintf
    lea rcx, [rel html_tmp_buf]
    call shell_output_print

    add rsp, 48
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; DOM Tree Builder
;
; Converts the flat token stream from html_tokenize_all() into
; a tree of DOM nodes with parent/child/sibling links.
;
; Node struct: 32 bytes (8 dwords), indexed with shl rax, 5.
; Iterative tree walk for printing — zero recursion.
; ============================================================

; ------------------------------------------------------------
; dom_alloc_node() -> EAX = new node index (-1 if full)
;
; Allocates a zeroed node with parent/first_child/next_sib = -1.
; Leaf function — no calls, no stack frame needed.
; ------------------------------------------------------------
dom_alloc_node:
    mov eax, [rel dom_node_count]
    cmp eax, DOM_MAX_NODES
    jge .da_full
    ; Compute node pointer
    movsxd rcx, eax
    shl rcx, 5
    lea rdx, [rel dom_nodes]
    add rdx, rcx
    ; Zero all fields, set link fields to -1
    mov dword [rdx + DOM_NODE_TYPE], 0
    mov dword [rdx + DOM_NODE_TAG_START], 0
    mov dword [rdx + DOM_NODE_TAG_LEN], 0
    mov dword [rdx + DOM_NODE_PARENT], -1
    mov dword [rdx + DOM_NODE_FIRST_CHILD], -1
    mov dword [rdx + DOM_NODE_NEXT_SIB], -1
    mov dword [rdx + DOM_NODE_ATTR_IDX], 0
    mov dword [rdx + DOM_NODE_ATTR_COUNT], 0
    ; Set last_child to -1
    lea rcx, [rel dom_last_child]
    movsxd rdx, eax
    mov dword [rcx + rdx*4], -1
    ; Increment count
    inc dword [rel dom_node_count]
    ret
.da_full:
    mov eax, -1
    ret

; ------------------------------------------------------------
; dom_append_child(ECX=parent_idx, EDX=child_idx)
;
; Sets child's parent link and appends to parent's child list.
; Uses dom_last_child[] for O(1) append.
; Leaf function — uses only volatile registers.
; ------------------------------------------------------------
dom_append_child:
    ; child.parent = parent_idx
    movsxd rax, edx
    shl rax, 5
    lea r8, [rel dom_nodes]
    add r8, rax                         ; r8 = child node ptr
    mov [r8 + DOM_NODE_PARENT], ecx
    mov dword [r8 + DOM_NODE_FIRST_CHILD], -1
    mov dword [r8 + DOM_NODE_NEXT_SIB], -1
    ; Get parent node ptr
    movsxd rax, ecx
    shl rax, 5
    lea r9, [rel dom_nodes]
    add r9, rax                         ; r9 = parent node ptr
    ; If parent has no children yet, set first_child
    cmp dword [r9 + DOM_NODE_FIRST_CHILD], -1
    jne .dac_has_children
    mov [r9 + DOM_NODE_FIRST_CHILD], edx
    jmp .dac_set_last
.dac_has_children:
    ; node[last_child[parent]].next_sibling = child_idx
    lea rax, [rel dom_last_child]
    movsxd r10, ecx
    mov r10d, [rax + r10*4]            ; r10d = last_child index
    movsxd r11, r10d
    shl r11, 5
    lea rax, [rel dom_nodes]
    add rax, r11                        ; rax = last_child node ptr
    mov [rax + DOM_NODE_NEXT_SIB], edx
.dac_set_last:
    ; dom_last_child[parent] = child_idx
    lea rax, [rel dom_last_child]
    movsxd r10, ecx
    mov [rax + r10*4], edx
    ret

; ------------------------------------------------------------
; dom_build_tree() -> EAX = node_count
;
; Reads from tokenizer globals (html_tok_buf, html_tok_count).
; Single-pass scan: START_TAG pushes stack, END_TAG pops,
; TEXT/SELF_CLOSE append without pushing.
;
; Register allocation:
;   RBX  = scratch (new node index)
;   R12d = token loop index
;   R13d = html_tok_count
;   R14  = current token pointer
;   R15  = (unused)
;   RSI  = (unused)
;   RDI  = (unused)
;
; Stack: 8 pushes (64) + 8 (call) + 40 = 112. 112%16=0
; ------------------------------------------------------------
dom_build_tree:
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40

    ; Initialize dom_node_count and stack
    mov dword [rel dom_node_count], 0
    mov dword [rel dom_stack_top], 0

    ; Initialize dom_last_child[] to -1
    lea rax, [rel dom_last_child]
    mov ecx, DOM_MAX_NODES
.dbt_init_lc:
    dec ecx
    js .dbt_init_done
    mov dword [rax + rcx*4], -1
    jmp .dbt_init_lc
.dbt_init_done:

    ; Allocate document root node (index 0)
    call dom_alloc_node
    mov ebx, eax
    ; Set type = DOCUMENT
    movsxd rax, ebx
    shl rax, 5
    lea rcx, [rel dom_nodes]
    add rcx, rax
    mov dword [rcx + DOM_NODE_TYPE], DOM_NODE_DOCUMENT
    ; Push root onto open-element stack
    lea rax, [rel dom_stack]
    mov [rax], ebx
    mov dword [rel dom_stack_top], 1
    mov [rel dom_root], ebx

    ; Token loop
    xor r12d, r12d                      ; i = 0
    mov r13d, [rel html_tok_count]

.dbt_loop:
    cmp r12d, r13d
    jge .dbt_done

    ; r14 = &html_tok_buf[i]
    movsxd rax, r12d
    shl rax, 5
    lea r14, [rel html_tok_buf]
    add r14, rax

    mov eax, [r14]                      ; token type

    cmp eax, TOK_START_TAG
    je .dbt_start_tag
    cmp eax, TOK_END_TAG
    je .dbt_end_tag
    cmp eax, TOK_TEXT
    je .dbt_text
    cmp eax, TOK_SELF_CLOSE
    je .dbt_self_close
    ; DOCTYPE, EOF, others: skip
    jmp .dbt_next

.dbt_start_tag:
    call dom_alloc_node
    cmp eax, -1
    je .dbt_done
    mov ebx, eax                        ; ebx = new node index
    ; Set fields
    movsxd rax, ebx
    shl rax, 5
    lea rcx, [rel dom_nodes]
    add rcx, rax
    mov dword [rcx + DOM_NODE_TYPE], DOM_NODE_ELEMENT
    mov eax, [r14 + 4]                  ; tok.start
    mov [rcx + DOM_NODE_TAG_START], eax
    mov eax, [r14 + 8]                  ; tok.length
    mov [rcx + DOM_NODE_TAG_LEN], eax
    mov eax, [r14 + 16]                 ; tok.attr_idx
    mov [rcx + DOM_NODE_ATTR_IDX], eax
    mov eax, [r14 + 12]                 ; tok.attr_count
    mov [rcx + DOM_NODE_ATTR_COUNT], eax
    ; Append to current parent
    mov eax, [rel dom_stack_top]
    dec eax
    lea rdx, [rel dom_stack]
    mov ecx, [rdx + rax*4]             ; parent = stack[top-1]
    mov edx, ebx                        ; child = new node
    call dom_append_child

    ; --- Void element check: don't push void elements onto stack ---
    ; They have no children and no closing tag (meta, br, hr, img, input, link, col, area, base, wbr)
    mov rcx, [rel html_last_src]
    movsxd rdx, dword [r14 + 4]     ; tok.start
    add rcx, rdx                      ; rcx = tag name start
    mov edx, [r14 + 8]               ; tok.length = tag name length

    ; Length-based dispatch
    cmp edx, 2
    je .dbt_void_len2
    cmp edx, 3
    je .dbt_void_len3
    cmp edx, 4
    je .dbt_void_len4
    cmp edx, 5
    je .dbt_void_len5
    jmp .dbt_push

.dbt_void_len2:
    ; br, hr
    movzx eax, byte [rcx]
    or al, 0x20
    movzx edx, byte [rcx+1]
    or dl, 0x20
    cmp al, 'b'
    jne .dbt_v2_hr
    cmp dl, 'r'
    je .dbt_next                      ; br → void
.dbt_v2_hr:
    cmp al, 'h'
    jne .dbt_push
    cmp dl, 'r'
    je .dbt_next                      ; hr → void
    jmp .dbt_push

.dbt_void_len3:
    ; img, col, wbr
    movzx eax, byte [rcx]
    or al, 0x20
    cmp al, 'i'
    jne .dbt_v3_col
    movzx eax, byte [rcx+1]
    or al, 0x20
    cmp al, 'm'
    jne .dbt_push
    movzx eax, byte [rcx+2]
    or al, 0x20
    cmp al, 'g'
    je .dbt_next                      ; img → void
    jmp .dbt_push
.dbt_v3_col:
    cmp al, 'c'
    jne .dbt_v3_wbr
    movzx eax, byte [rcx+1]
    or al, 0x20
    cmp al, 'o'
    jne .dbt_push
    movzx eax, byte [rcx+2]
    or al, 0x20
    cmp al, 'l'
    je .dbt_next                      ; col → void
    jmp .dbt_push
.dbt_v3_wbr:
    cmp al, 'w'
    jne .dbt_push
    movzx eax, byte [rcx+1]
    or al, 0x20
    cmp al, 'b'
    jne .dbt_push
    movzx eax, byte [rcx+2]
    or al, 0x20
    cmp al, 'r'
    je .dbt_next                      ; wbr → void
    jmp .dbt_push

.dbt_void_len4:
    ; meta, link, base, area
    movzx eax, byte [rcx]
    or al, 0x20
    cmp al, 'm'
    jne .dbt_v4_link
    movzx eax, byte [rcx+1]
    or al, 0x20
    cmp al, 'e'
    jne .dbt_push
    movzx eax, byte [rcx+2]
    or al, 0x20
    cmp al, 't'
    jne .dbt_push
    movzx eax, byte [rcx+3]
    or al, 0x20
    cmp al, 'a'
    je .dbt_next                      ; meta → void
    jmp .dbt_push
.dbt_v4_link:
    cmp al, 'l'
    jne .dbt_v4_base
    movzx eax, byte [rcx+1]
    or al, 0x20
    cmp al, 'i'
    jne .dbt_push
    movzx eax, byte [rcx+2]
    or al, 0x20
    cmp al, 'n'
    jne .dbt_push
    movzx eax, byte [rcx+3]
    or al, 0x20
    cmp al, 'k'
    je .dbt_next                      ; link → void
    jmp .dbt_push
.dbt_v4_base:
    cmp al, 'b'
    jne .dbt_v4_area
    movzx eax, byte [rcx+1]
    or al, 0x20
    cmp al, 'a'
    jne .dbt_push
    movzx eax, byte [rcx+2]
    or al, 0x20
    cmp al, 's'
    jne .dbt_push
    movzx eax, byte [rcx+3]
    or al, 0x20
    cmp al, 'e'
    je .dbt_next                      ; base → void
    jmp .dbt_push
.dbt_v4_area:
    cmp al, 'a'
    jne .dbt_push
    movzx eax, byte [rcx+1]
    or al, 0x20
    cmp al, 'r'
    jne .dbt_push
    movzx eax, byte [rcx+2]
    or al, 0x20
    cmp al, 'e'
    jne .dbt_push
    movzx eax, byte [rcx+3]
    or al, 0x20
    cmp al, 'a'
    je .dbt_next                      ; area → void
    jmp .dbt_push

.dbt_void_len5:
    ; input
    movzx eax, byte [rcx]
    or al, 0x20
    cmp al, 'i'
    jne .dbt_push
    movzx eax, byte [rcx+1]
    or al, 0x20
    cmp al, 'n'
    jne .dbt_push
    movzx eax, byte [rcx+2]
    or al, 0x20
    cmp al, 'p'
    jne .dbt_push
    movzx eax, byte [rcx+3]
    or al, 0x20
    cmp al, 'u'
    jne .dbt_push
    movzx eax, byte [rcx+4]
    or al, 0x20
    cmp al, 't'
    je .dbt_next                      ; input → void
    jmp .dbt_push

.dbt_push:
    ; Push new element onto stack (non-void elements only)
    mov eax, [rel dom_stack_top]
    cmp eax, DOM_STACK_SIZE
    jge .dbt_next
    lea rcx, [rel dom_stack]
    mov [rcx + rax*4], ebx
    inc eax
    mov [rel dom_stack_top], eax
    jmp .dbt_next

.dbt_end_tag:
    ; Pop stack (keep at least root)
    mov eax, [rel dom_stack_top]
    cmp eax, 1
    jle .dbt_next
    dec eax
    mov [rel dom_stack_top], eax
    jmp .dbt_next

.dbt_text:
    call dom_alloc_node
    cmp eax, -1
    je .dbt_done
    mov ebx, eax
    movsxd rax, ebx
    shl rax, 5
    lea rcx, [rel dom_nodes]
    add rcx, rax
    mov dword [rcx + DOM_NODE_TYPE], DOM_NODE_TEXT
    mov eax, [r14 + 4]                  ; tok.start (text offset)
    mov [rcx + DOM_NODE_TAG_START], eax
    mov eax, [r14 + 8]                  ; tok.length (text length)
    mov [rcx + DOM_NODE_TAG_LEN], eax
    ; Append to parent (don't push — text has no children)
    mov eax, [rel dom_stack_top]
    dec eax
    lea rdx, [rel dom_stack]
    mov ecx, [rdx + rax*4]
    mov edx, ebx
    call dom_append_child
    jmp .dbt_next

.dbt_self_close:
    call dom_alloc_node
    cmp eax, -1
    je .dbt_done
    mov ebx, eax
    movsxd rax, ebx
    shl rax, 5
    lea rcx, [rel dom_nodes]
    add rcx, rax
    mov dword [rcx + DOM_NODE_TYPE], DOM_NODE_ELEMENT
    mov eax, [r14 + 4]
    mov [rcx + DOM_NODE_TAG_START], eax
    mov eax, [r14 + 8]
    mov [rcx + DOM_NODE_TAG_LEN], eax
    mov eax, [r14 + 16]                 ; attr_idx
    mov [rcx + DOM_NODE_ATTR_IDX], eax
    mov eax, [r14 + 12]                 ; attr_count
    mov [rcx + DOM_NODE_ATTR_COUNT], eax
    ; Append to parent (don't push — self-closing)
    mov eax, [rel dom_stack_top]
    dec eax
    lea rdx, [rel dom_stack]
    mov ecx, [rdx + rax*4]
    mov edx, ebx
    call dom_append_child
    jmp .dbt_next

.dbt_next:
    inc r12d
    jmp .dbt_loop

.dbt_done:
    mov eax, [rel dom_node_count]

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

; ------------------------------------------------------------
; dom_print_tree() -> void
;
; Iterative DFS using parent/first_child/next_sibling links.
; No recursion, no extra stack. Prints to serial with [DOM]
; prefix and depth-based indentation.
;
; Register allocation:
;   RBX  = html_last_src (source base for tag name extraction)
;   R12d = current node index
;   R13d = current depth
;   R14  = base of dom_nodes array
;   RSI  = current node pointer (reloaded each iteration)
;   RDI  = write cursor into html_tmp_buf
;
; Stack: 8 pushes (64) + 8 (call) + 56 = 128. 128%16=0
; ------------------------------------------------------------
dom_print_tree:
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56

    mov rbx, [rel html_last_src]
    lea r14, [rel dom_nodes]
    mov r12d, [rel dom_root]
    xor r13d, r13d                      ; depth = 0

.dpt_loop:
    cmp r12d, -1
    je .dpt_done

    ; rsi = node pointer
    movsxd rax, r12d
    shl rax, 5
    lea rsi, [r14 + rax]

    ; Build line in html_tmp_buf: "[DOM] " + indent + content + "\n\0"
    lea rdi, [rel html_tmp_buf]
    mov byte [rdi], '['
    mov byte [rdi+1], 'D'
    mov byte [rdi+2], 'O'
    mov byte [rdi+3], 'M'
    mov byte [rdi+4], ']'
    mov byte [rdi+5], ' '
    add rdi, 6

    ; Write depth*2 spaces
    xor ecx, ecx
    mov edx, r13d
    shl edx, 1                          ; depth * 2
.dpt_indent:
    cmp ecx, edx
    jge .dpt_indent_done
    mov byte [rdi + rcx], ' '
    inc ecx
    jmp .dpt_indent
.dpt_indent_done:
    add rdi, rcx

    ; Dispatch on node type
    mov eax, [rsi + DOM_NODE_TYPE]
    cmp eax, DOM_NODE_DOCUMENT
    je .dpt_doc
    cmp eax, DOM_NODE_TEXT
    je .dpt_txt
    jmp .dpt_elem

.dpt_doc:
    mov dword [rdi], 'DOCU'
    mov dword [rdi+4], 'MENT'
    mov byte [rdi+8], 10
    mov byte [rdi+9], 0
    jmp .dpt_print

.dpt_elem:
    ; Copy tag name from source
    mov eax, [rsi + DOM_NODE_TAG_START]
    mov ecx, [rsi + DOM_NODE_TAG_LEN]
    cmp ecx, 100
    jbe .dpt_elen_ok
    mov ecx, 100
.dpt_elen_ok:
    lea r8, [rbx + rax]
    xor edx, edx
.dpt_ecopy:
    cmp edx, ecx
    jge .dpt_ecopy_done
    movzx r9d, byte [r8 + rdx]
    mov [rdi + rdx], r9b
    inc edx
    jmp .dpt_ecopy
.dpt_ecopy_done:
    mov byte [rdi + rdx], 10
    mov byte [rdi + rdx + 1], 0
    jmp .dpt_print

.dpt_txt:
    ; Format "TEXT (N bytes)\n" at cursor
    mov rcx, rdi
    mov edx, 80
    lea r8, [rel str_dom_text]
    mov r9d, [rsi + DOM_NODE_TAG_LEN]
    call herb_snprintf
    ; Find null terminator and append newline
    xor ecx, ecx
.dpt_txt_scan:
    cmp byte [rdi + rcx], 0
    je .dpt_txt_end
    inc ecx
    cmp ecx, 79
    jge .dpt_txt_end
    jmp .dpt_txt_scan
.dpt_txt_end:
    mov byte [rdi + rcx], 10
    mov byte [rdi + rcx + 1], 0
    jmp .dpt_print

.dpt_print:
    lea rcx, [rel html_tmp_buf]
    call serial_print

    ; --- Tree traversal ---
    ; If first_child != -1: descend
    cmp dword [rsi + DOM_NODE_FIRST_CHILD], -1
    je .dpt_no_child
    mov r12d, [rsi + DOM_NODE_FIRST_CHILD]
    inc r13d
    jmp .dpt_loop

.dpt_no_child:
    ; If next_sibling != -1: go sideways
    cmp dword [rsi + DOM_NODE_NEXT_SIB], -1
    je .dpt_backtrack
    mov r12d, [rsi + DOM_NODE_NEXT_SIB]
    jmp .dpt_loop

.dpt_backtrack:
    ; Walk up parents until one has a next sibling
    mov r12d, [rsi + DOM_NODE_PARENT]
    dec r13d
    cmp r12d, -1
    je .dpt_done
    ; Load parent node
    movsxd rax, r12d
    shl rax, 5
    lea rsi, [r14 + rax]
    cmp dword [rsi + DOM_NODE_NEXT_SIB], -1
    jne .dpt_bt_found
    jmp .dpt_backtrack

.dpt_bt_found:
    mov r12d, [rsi + DOM_NODE_NEXT_SIB]
    jmp .dpt_loop

.dpt_done:
    ; Print node count summary
    lea rcx, [rel html_tmp_buf]
    mov edx, 128
    lea r8, [rel str_dom_count]
    mov r9d, [rel dom_node_count]
    call herb_snprintf
    lea rcx, [rel html_tmp_buf]
    call serial_print

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

; ------------------------------------------------------------
; browser_dom_cmd() -> void
;
; Shell command handler for /dom.
; Tokenizes HTML, builds DOM tree, prints tree to serial,
; and outputs summary to shell output window.
; ------------------------------------------------------------
browser_dom_cmd:
    push rbp
    push rbx
    push rsi
    sub rsp, 48                         ; 3*8+8+48=80, 80%16=0

    ; Select HTML source: HTTP body or embedded test
    cmp dword [rel tcp_recv_done], 1
    jne .bdc_use_test
    cmp dword [rel http_body_len], 0
    jle .bdc_use_test

    lea rcx, [rel tcp_recv_buf]
    movsxd rax, dword [rel http_body_offset]
    add rcx, rax
    mov edx, [rel http_body_len]
    jmp .bdc_go

.bdc_use_test:
    lea rcx, [rel html_test_src]
    mov edx, HTML_TEST_LEN

.bdc_go:
    call html_tokenize_all

    call dom_build_tree
    mov ebx, eax                        ; save node count

    call dom_print_tree

    ; Format summary for shell output window
    lea rcx, [rel html_tmp_buf]
    mov edx, 128
    lea r8, [rel str_la_dom]
    mov r9d, ebx
    call herb_snprintf
    lea rcx, [rel html_tmp_buf]
    call shell_output_print

    add rsp, 48
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; LAYOUT ENGINE
;
; Phase 1: Create HERB entities from DOM nodes with style props
; Phase 2: Recursive tree walk to compute x/y/w/h geometry
; Phase 3: Serial dump of layout tree
; ============================================================

; Display type constants
DISPLAY_BLOCK   equ 0
DISPLAY_INLINE  equ 1
DISPLAY_NONE    equ 2

; Font constants for text wrapping
LAYOUT_FONT_W   equ 12
LAYOUT_FONT_H   equ 24

; MAX_ENTITY_PER_CONTAINER (must match herb_graph.asm)
LAYOUT_MAX_ENTS equ 1024

; ------------------------------------------------------------
; layout_get_tag_defaults
;
; Given a tag name from the source HTML, returns CSS-like defaults.
;
; Args:
;   RCX = source HTML pointer
;   EDX = tag_start offset
;   R8D = tag_len
;
; Returns:
;   EAX = display (0=block, 1=inline, 2=none)
;   ECX = margin_top
;   EDX = margin_bot
;   R8D = margin_left
;   R9D = padding
; ------------------------------------------------------------
layout_get_tag_defaults:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56

    ; Extract tag name into layout_name_buf (lowercase, null-terminated)
    lea rsi, [rcx + rdx]
    mov edi, r8d
    cmp edi, 14
    jbe .lgtd_len_ok
    mov edi, 14
.lgtd_len_ok:

    lea rbx, [rel layout_name_buf]
    xor ecx, ecx
.lgtd_copy:
    cmp ecx, edi
    jge .lgtd_copy_done
    movzx eax, byte [rsi + rcx]
    cmp al, 'A'
    jb .lgtd_no_lc
    cmp al, 'Z'
    ja .lgtd_no_lc
    add al, 32
.lgtd_no_lc:
    mov [rbx + rcx], al
    inc ecx
    jmp .lgtd_copy
.lgtd_copy_done:
    mov byte [rbx + rcx], 0

    ; Length-based dispatch
    cmp edi, 1
    je .lgtd_len1
    cmp edi, 2
    je .lgtd_len2
    cmp edi, 3
    je .lgtd_len3
    cmp edi, 4
    je .lgtd_len4
    cmp edi, 5
    je .lgtd_len5
    cmp edi, 6
    je .lgtd_len6
    jmp .lgtd_default_inline

.lgtd_len1:
    movzx eax, byte [rbx]
    cmp al, 'p'
    je .lgtd_p
    cmp al, 'a'
    je .lgtd_inline
    cmp al, 'b'
    je .lgtd_inline
    cmp al, 'i'
    je .lgtd_inline
    cmp al, 'u'
    je .lgtd_inline
    jmp .lgtd_default_inline

.lgtd_len2:
    movzx eax, word [rbx]
    cmp ax, 'h' | ('1' << 8)
    je .lgtd_h1
    cmp ax, 'h' | ('2' << 8)
    je .lgtd_h2
    cmp ax, 'h' | ('3' << 8)
    je .lgtd_h3
    cmp ax, 'h' | ('4' << 8)
    je .lgtd_h3
    cmp ax, 'h' | ('5' << 8)
    je .lgtd_h3
    cmp ax, 'h' | ('6' << 8)
    je .lgtd_h3
    cmp ax, 'u' | ('l' << 8)
    je .lgtd_list
    cmp ax, 'o' | ('l' << 8)
    je .lgtd_list
    cmp ax, 'l' | ('i' << 8)
    je .lgtd_li
    cmp ax, 'h' | ('r' << 8)
    je .lgtd_hr
    cmp ax, 'b' | ('r' << 8)
    je .lgtd_br
    cmp ax, 'e' | ('m' << 8)
    je .lgtd_inline
    jmp .lgtd_default_inline

.lgtd_len3:
    cmp byte [rbx], 'd'
    jne .lgtd_len3_not_div
    cmp byte [rbx+1], 'i'
    jne .lgtd_len3_not_div
    cmp byte [rbx+2], 'v'
    jne .lgtd_len3_not_div
    jmp .lgtd_div
.lgtd_len3_not_div:
    cmp byte [rbx], 'i'
    jne .lgtd_len3_not_img
    cmp byte [rbx+1], 'm'
    jne .lgtd_len3_not_img
    cmp byte [rbx+2], 'g'
    jne .lgtd_len3_not_img
    jmp .lgtd_inline
.lgtd_len3_not_img:
    jmp .lgtd_default_inline

.lgtd_len4:
    mov eax, [rbx]
    cmp eax, 'h' | ('t' << 8) | ('m' << 16) | ('l' << 24)
    je .lgtd_html
    cmp eax, 'b' | ('o' << 8) | ('d' << 16) | ('y' << 24)
    je .lgtd_body
    cmp eax, 'h' | ('e' << 8) | ('a' << 16) | ('d' << 24)
    je .lgtd_none
    cmp eax, 'm' | ('e' << 8) | ('t' << 16) | ('a' << 24)
    je .lgtd_none
    cmp eax, 'l' | ('i' << 8) | ('n' << 16) | ('k' << 24)
    je .lgtd_none
    cmp eax, 's' | ('p' << 8) | ('a' << 16) | ('n' << 24)
    je .lgtd_inline
    cmp eax, 'c' | ('o' << 8) | ('d' << 16) | ('e' << 24)
    je .lgtd_inline
    jmp .lgtd_default_inline

.lgtd_len5:
    mov eax, [rbx]
    cmp eax, 't' | ('i' << 8) | ('t' << 16) | ('l' << 24)
    jne .lgtd_len5_not_title
    cmp byte [rbx+4], 'e'
    je .lgtd_none
.lgtd_len5_not_title:
    cmp eax, 's' | ('t' << 8) | ('y' << 16) | ('l' << 24)
    jne .lgtd_len5_not_style
    cmp byte [rbx+4], 'e'
    je .lgtd_none
.lgtd_len5_not_style:
    jmp .lgtd_default_inline

.lgtd_len6:
    mov eax, [rbx]
    cmp eax, 's' | ('c' << 8) | ('r' << 16) | ('i' << 24)
    jne .lgtd_len6_not_script
    cmp word [rbx+4], 'p' | ('t' << 8)
    je .lgtd_none
.lgtd_len6_not_script:
    cmp eax, 's' | ('t' << 8) | ('r' << 16) | ('o' << 24)
    jne .lgtd_len6_not_strong
    cmp word [rbx+4], 'n' | ('g' << 8)
    je .lgtd_inline
.lgtd_len6_not_strong:
    jmp .lgtd_default_inline

    ; --- Return values ---
.lgtd_html:
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_body:
    xor eax, eax
    mov ecx, 8
    mov edx, 8
    mov r8d, 8
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_h1:
    xor eax, eax
    mov ecx, 16
    mov edx, 8
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_h2:
    xor eax, eax
    mov ecx, 12
    mov edx, 6
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_h3:
    xor eax, eax
    mov ecx, 8
    mov edx, 4
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_p:
    xor eax, eax
    mov ecx, 8
    mov edx, 8
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_div:
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_list:
    xor eax, eax
    mov ecx, 8
    mov edx, 8
    xor r8d, r8d
    mov r9d, 16
    jmp .lgtd_done

.lgtd_li:
    xor eax, eax
    mov ecx, 2
    mov edx, 2
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_hr:
    xor eax, eax
    mov ecx, 8
    mov edx, 8
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_br:
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_none:
    mov eax, DISPLAY_NONE
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_inline:
    mov eax, DISPLAY_INLINE
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    jmp .lgtd_done

.lgtd_default_inline:
    mov eax, DISPLAY_INLINE
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d

.lgtd_done:
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret


; ------------------------------------------------------------
; layout_create_entities
;
; Creates HERB entities for each DOM node with style properties.
; Must be called after dom_build_tree().
;
; Stack: push rbp + 7 pushes (56) + sub 120 = 184 bytes
;   Entry RSP = 16n-8. push rbp: 16n-16. 7 pushes: 16n-72.
;   sub 120: 16n-192=16(n-12) ✓
;
; Stack locals:
;   [rsp+0..31]   shadow space
;   [rsp+32]      loop index i
;   [rsp+36]      saved display value
;   [rsp+40]      saved margin_top
;   [rsp+44]      saved margin_bot
;   [rsp+48]      saved margin_left
;   [rsp+52]      saved padding
;   [rsp+56]      entity_id
;   [rsp+60]      is_text flag
;   [rsp+64]      text_len
;   [rsp+68]      parent_idx
;   [rsp+72]      depth
; ------------------------------------------------------------
layout_create_entities:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 120

    ; --- Cleanup: remove old entities from browser.NODES ---
    mov eax, [rel layout_node_count]
    test eax, eax
    jz .lce_no_cleanup

    lea rcx, [rel str_browser_nodes]
    call intern
    mov ecx, eax
    call graph_find_container_by_name
    test eax, eax
    js .lce_no_cleanup
    mov r12d, eax

.lce_cleanup_loop:
    movsxd rax, r12d
    lea rcx, [g_container_entity_counts]
    mov edx, [rcx + rax*4]
    test edx, edx
    jz .lce_cleanup_done
    dec edx
    movsxd rcx, r12d
    imul rcx, LAYOUT_MAX_ENTS
    movsxd rax, edx
    add rax, rcx
    lea rcx, [g_container_entities]
    mov edx, [rcx + rax*4]
    mov ecx, r12d
    call container_remove
    jmp .lce_cleanup_loop

.lce_cleanup_done:
    mov dword [rel layout_node_count], 0
.lce_no_cleanup:

    ; Cache container index and type id
    lea rcx, [rel str_browser_nodes]
    call intern
    mov ecx, eax
    call graph_find_container_by_name
    mov [rel layout_container_idx], eax
    mov r15d, eax

    lea rcx, [rel str_browser_node]
    call intern
    mov [rel layout_type_id], eax
    mov r14d, eax

    ; Create entities for each DOM node
    mov dword [rsp+32], 0
    lea r13, [rel dom_nodes]

.lce_loop:
    mov eax, [rsp+32]
    cmp eax, [rel dom_node_count]
    jge .lce_done

    movsxd rax, dword [rsp+32]
    shl rax, 5
    lea rsi, [r13 + rax]

    ; Get tag defaults based on node type
    mov eax, [rsi + DOM_NODE_TYPE]
    cmp eax, DOM_NODE_TEXT
    je .lce_text_defaults
    cmp eax, DOM_NODE_DOCUMENT
    je .lce_doc_defaults

    ; Element node
    mov rcx, [rel html_last_src]
    mov edx, [rsi + DOM_NODE_TAG_START]
    mov r8d, [rsi + DOM_NODE_TAG_LEN]
    call layout_get_tag_defaults
    mov [rsp+36], eax
    mov [rsp+40], ecx
    mov [rsp+44], edx
    mov [rsp+48], r8d
    mov [rsp+52], r9d
    mov dword [rsp+60], 0
    mov dword [rsp+64], 0
    jmp .lce_create

.lce_text_defaults:
    mov dword [rsp+36], DISPLAY_INLINE
    mov dword [rsp+40], 0
    mov dword [rsp+44], 0
    mov dword [rsp+48], 0
    mov dword [rsp+52], 0
    mov dword [rsp+60], 1
    mov eax, [rsi + DOM_NODE_TAG_LEN]
    mov [rsp+64], eax
    jmp .lce_create

.lce_doc_defaults:
    mov dword [rsp+36], DISPLAY_BLOCK
    mov dword [rsp+40], 0
    mov dword [rsp+44], 0
    mov dword [rsp+48], 0
    mov dword [rsp+52], 0
    mov dword [rsp+60], 0
    mov dword [rsp+64], 0

.lce_create:
    ; Generate entity name
    lea rcx, [rel layout_name_buf]
    mov edx, 16
    lea r8, [rel str_node_fmt]
    mov r9d, [rsp+32]
    call herb_snprintf

    lea rcx, [rel layout_name_buf]
    call intern
    mov ebx, eax

    mov ecx, r14d
    mov edx, ebx
    mov r8d, r15d
    call create_entity
    mov [rsp+56], eax
    movsxd rcx, dword [rsp+32]
    lea rdx, [rel layout_entity_ids]
    mov [rdx + rcx*4], eax

    ; Reload rsi
    movsxd rax, dword [rsp+32]
    shl rax, 5
    lea rsi, [r13 + rax]

    ; Get parent_idx and compute depth
    mov eax, [rsi + DOM_NODE_PARENT]
    mov [rsp+68], eax

    xor edi, edi
    mov ecx, eax
.lce_depth_loop:
    cmp ecx, -1
    je .lce_depth_done
    inc edi
    movsxd rax, ecx
    shl rax, 5
    mov ecx, [r13 + rax + DOM_NODE_PARENT]
    jmp .lce_depth_loop
.lce_depth_done:
    mov [rsp+72], edi

    ; Set 14 properties
    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_display]
    movsxd r8, dword [rsp+36]
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_margin_top]
    movsxd r8, dword [rsp+40]
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_margin_bot]
    movsxd r8, dword [rsp+44]
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_margin_left]
    movsxd r8, dword [rsp+48]
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_padding]
    movsxd r8, dword [rsp+52]
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_node_idx]
    movsxd r8, dword [rsp+32]
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_parent_idx]
    movsxd r8, dword [rsp+68]
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_depth]
    movsxd r8, dword [rsp+72]
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_is_text]
    movsxd r8, dword [rsp+60]
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_text_len]
    movsxd r8, dword [rsp+64]
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_layout_x]
    xor r8d, r8d
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_layout_y]
    xor r8d, r8d
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_layout_w]
    xor r8d, r8d
    call herb_set_prop_int

    mov ecx, [rsp+56]
    lea rdx, [rel str_prop_layout_h]
    xor r8d, r8d
    call herb_set_prop_int

    mov eax, [rel layout_node_count]
    inc eax
    mov [rel layout_node_count], eax

    inc dword [rsp+32]
    jmp .lce_loop

.lce_done:
    add rsp, 120
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ------------------------------------------------------------
; layout_tree(ECX=node_idx, EDX=x, R8D=y, R9D=avail_width)
;   -> EAX = new y position after this node
;
; Recursive layout computation.
;
; Stack: push rbp + 7 pushes (56) + sub 120 = 184 bytes
;   Entry RSP = 16n-8. push rbp: 16n-16. 7 pushes: 16n-72.
;   sub 120: 16n-192=16(n-12) ✓
;
; Stack locals:
;   [rsp+0..31]   shadow space
;   [rsp+32]      node_idx
;   [rsp+36]      x
;   [rsp+40]      y
;   [rsp+44]      avail_width
;   [rsp+48]      entity_id
;   [rsp+52]      display
;   [rsp+56]      margin_top
;   [rsp+60]      margin_bot
;   [rsp+64]      margin_left
;   [rsp+68]      padding
;   [rsp+72]      box_x
;   [rsp+76]      box_y
;   [rsp+80]      box_w
;   [rsp+84]      inner_x
;   [rsp+88]      inner_y
;   [rsp+92]      inner_w
;   [rsp+96]      content_h
;   [rsp+100]     child_idx
; ------------------------------------------------------------
layout_tree:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 120

    mov [rsp+32], ecx
    mov [rsp+36], edx
    mov [rsp+40], r8d
    mov [rsp+44], r9d

    ; Look up entity_id
    movsxd rax, ecx
    lea rdx, [rel layout_entity_ids]
    mov eax, [rdx + rax*4]
    mov [rsp+48], eax
    mov ebx, eax

    ; Read display
    mov ecx, ebx
    lea rdx, [rel str_prop_display]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+52], eax

    ; If display==NONE: zero geometry, return y
    cmp eax, DISPLAY_NONE
    jne .lt_not_none

    mov ecx, ebx
    lea rdx, [rel str_prop_layout_w]
    xor r8d, r8d
    call herb_set_prop_int
    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_layout_h]
    xor r8d, r8d
    call herb_set_prop_int
    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_layout_x]
    xor r8d, r8d
    call herb_set_prop_int
    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_layout_y]
    xor r8d, r8d
    call herb_set_prop_int

    mov eax, [rsp+40]
    jmp .lt_done

.lt_not_none:
    ; Read margins and padding
    mov ecx, ebx
    lea rdx, [rel str_prop_margin_top]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+56], eax

    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_margin_bot]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+60], eax

    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_margin_left]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+64], eax

    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_padding]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+68], eax

    ; box_x = x + margin_left
    mov eax, [rsp+36]
    add eax, [rsp+64]
    mov [rsp+72], eax

    ; box_y = y + margin_top
    mov eax, [rsp+40]
    add eax, [rsp+56]
    mov [rsp+76], eax

    ; box_w = avail_width - margin_left
    mov eax, [rsp+44]
    sub eax, [rsp+64]
    cmp eax, 1
    jge .lt_bw_ok
    mov eax, 1
.lt_bw_ok:
    mov [rsp+80], eax

    ; inner_x = box_x + padding
    mov eax, [rsp+72]
    add eax, [rsp+68]
    mov [rsp+84], eax

    ; inner_y = box_y + padding
    mov eax, [rsp+76]
    add eax, [rsp+68]
    mov [rsp+88], eax

    ; inner_w = box_w - padding*2
    mov eax, [rsp+80]
    mov ecx, [rsp+68]
    shl ecx, 1
    sub eax, ecx
    cmp eax, 1
    jge .lt_iw_ok
    mov eax, 1
.lt_iw_ok:
    mov [rsp+92], eax

    ; Check if text node
    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_is_text]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+104], eax         ; save is_text

    test eax, eax
    jnz .lt_text_node

    ; Element: recurse children
    mov dword [rsp+96], 0

    movsxd rax, dword [rsp+32]
    shl rax, 5
    lea rcx, [rel dom_nodes]
    mov eax, [rcx + rax + DOM_NODE_FIRST_CHILD]
    mov [rsp+100], eax

    mov r12d, [rsp+88]             ; cursor_y = inner_y

.lt_child_loop:
    cmp dword [rsp+100], -1
    je .lt_children_done

    mov ecx, [rsp+100]
    mov edx, [rsp+84]
    mov r8d, r12d
    mov r9d, [rsp+92]
    call layout_tree
    mov r12d, eax

    movsxd rax, dword [rsp+100]
    shl rax, 5
    lea rcx, [rel dom_nodes]
    mov eax, [rcx + rax + DOM_NODE_NEXT_SIB]
    mov [rsp+100], eax
    jmp .lt_child_loop

.lt_children_done:
    mov eax, r12d
    sub eax, [rsp+88]
    mov [rsp+96], eax

    jmp .lt_write_back

.lt_text_node:
    ; chars_per_line = inner_w / FONT_WIDTH
    mov eax, [rsp+92]
    xor edx, edx
    mov ecx, LAYOUT_FONT_W
    div ecx
    cmp eax, 1
    jge .lt_cpl_ok
    mov eax, 1
.lt_cpl_ok:
    mov r12d, eax                   ; R12D = chars_per_line (callee-saved)

    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_text_len]
    xor r8d, r8d
    call herb_entity_prop_int
    ; EAX = text_len, R12D preserved

    test eax, eax
    jnz .lt_has_text
    mov eax, 1
    jmp .lt_text_h
.lt_has_text:
    add eax, r12d
    dec eax
    xor edx, edx
    mov ecx, r12d
    div ecx

.lt_text_h:
    imul eax, LAYOUT_FONT_H
    mov [rsp+96], eax

.lt_write_back:
    ; box_h = content_h + padding * 2
    mov eax, [rsp+96]
    mov ecx, [rsp+68]
    shl ecx, 1
    add eax, ecx
    mov r12d, eax                   ; R12D = box_h

    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_layout_x]
    movsxd r8, dword [rsp+72]
    call herb_set_prop_int

    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_layout_y]
    movsxd r8, dword [rsp+76]
    call herb_set_prop_int

    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_layout_w]
    movsxd r8, dword [rsp+80]
    call herb_set_prop_int

    mov ecx, [rsp+48]
    lea rdx, [rel str_prop_layout_h]
    movsxd r8, dword [rsp+68]
    shl r8d, 1
    add r8d, [rsp+96]
    call herb_set_prop_int

    ; Return box_y + box_h + margin_bot
    mov eax, [rsp+76]
    add eax, r12d
    add eax, [rsp+60]

.lt_done:
    add rsp, 120
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ------------------------------------------------------------
; layout_print_tree
;
; Iterative DFS printing of layout results.
; Format: [LAYOUT] {indent}{tag} x=N y=N w=N h=N BLOCK|INLINE|NONE d=N
;
; Register allocation:
;   RBX  = html_last_src (reloaded each iter)
;   R12d = current node index
;   R13d = current depth
;   R14  = dom_nodes base
;
; Stack: 8 pushes (64) + 8 (call) + 88 = 160. 160%16=0 ✓
;
; Stack locals:
;   [rsp+0..31]   shadow space
;   [rsp+32]      saved node_idx (for traversal recovery)
;   [rsp+36]      entity_id
;   [rsp+40]      layout_x
;   [rsp+44]      layout_y
;   [rsp+48]      layout_w
;   [rsp+52]      layout_h
;   [rsp+56]      display
; ------------------------------------------------------------
layout_print_tree:
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88

    ; Print header
    lea rcx, [rel layout_tmp_buf]
    mov edx, 256
    lea r8, [rel str_layout_hdr]
    mov r9d, [rel dom_node_count]
    mov dword [rsp+32], 1280
    call herb_snprintf
    lea rcx, [rel layout_tmp_buf]
    call serial_print

    mov rbx, [rel html_last_src]
    lea r14, [rel dom_nodes]
    mov r12d, [rel dom_root]
    xor r13d, r13d

.lpt_loop:
    cmp r12d, -1
    je .lpt_done

    mov [rsp+32], r12d

    movsxd rax, r12d
    shl rax, 5
    lea rsi, [r14 + rax]

    ; Get entity_id
    movsxd rax, r12d
    lea rcx, [rel layout_entity_ids]
    mov edi, [rcx + rax*4]
    mov [rsp+36], edi

    ; Read layout values
    mov ecx, edi
    lea rdx, [rel str_prop_layout_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+40], eax

    mov ecx, [rsp+36]
    lea rdx, [rel str_prop_layout_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+44], eax

    mov ecx, [rsp+36]
    lea rdx, [rel str_prop_layout_w]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+48], eax

    mov ecx, [rsp+36]
    lea rdx, [rel str_prop_layout_h]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+52], eax

    mov ecx, [rsp+36]
    lea rdx, [rel str_prop_display]
    xor r8d, r8d
    call herb_entity_prop_int
    mov [rsp+56], eax

    ; Build line in layout_tmp_buf
    lea r15, [rel layout_tmp_buf]

    mov byte [r15], '['
    mov byte [r15+1], 'L'
    mov byte [r15+2], 'A'
    mov byte [r15+3], 'Y'
    mov byte [r15+4], 'O'
    mov byte [r15+5], 'U'
    mov byte [r15+6], 'T'
    mov byte [r15+7], ']'
    mov byte [r15+8], ' '
    add r15, 9

    ; Indent
    xor ecx, ecx
    mov edx, r13d
    shl edx, 1
.lpt_indent:
    cmp ecx, edx
    jge .lpt_indent_done
    mov byte [r15 + rcx], ' '
    inc ecx
    jmp .lpt_indent
.lpt_indent_done:
    add r15, rcx

    ; Reload RSI
    movsxd rax, dword [rsp+32]
    shl rax, 5
    lea rsi, [r14 + rax]
    mov rbx, [rel html_last_src]

    ; Node type dispatch
    mov eax, [rsi + DOM_NODE_TYPE]
    cmp eax, DOM_NODE_DOCUMENT
    je .lpt_doc
    cmp eax, DOM_NODE_TEXT
    je .lpt_text
    jmp .lpt_elem

.lpt_doc:
    mov dword [r15], 'DOCU'
    mov dword [r15+4], 'MENT'
    add r15, 8
    jmp .lpt_geom

.lpt_text:
    mov dword [r15], 'TEXT'
    add r15, 4
    jmp .lpt_geom

.lpt_elem:
    mov eax, [rsi + DOM_NODE_TAG_START]
    mov ecx, [rsi + DOM_NODE_TAG_LEN]
    cmp ecx, 40
    jbe .lpt_elen_ok
    mov ecx, 40
.lpt_elen_ok:
    lea r8, [rbx + rax]
    xor edx, edx
.lpt_ecopy:
    cmp edx, ecx
    jge .lpt_ecopy_done
    movzx r9d, byte [r8 + rdx]
    mov [r15 + rdx], r9b
    inc edx
    jmp .lpt_ecopy
.lpt_ecopy_done:
    add r15, rdx

.lpt_geom:
    ; Format " x=N y=N w=N h=N" — need sub rsp for stack args
    sub rsp, 32
    mov ecx, [rsp+44+32]           ; layout_y
    mov [rsp+32], ecx
    mov ecx, [rsp+48+32]           ; layout_w
    mov [rsp+40], ecx
    mov ecx, [rsp+52+32]           ; layout_h
    mov [rsp+48], ecx

    mov rcx, r15
    mov edx, 80
    lea r8, [rel str_layout_geom]
    mov r9d, [rsp+40+32]           ; layout_x
    call herb_snprintf
    add rsp, 32

    ; Advance r15 past formatted text
    xor ecx, ecx
.lpt_scan_null:
    cmp byte [r15 + rcx], 0
    je .lpt_found_null
    inc ecx
    cmp ecx, 80
    jge .lpt_found_null
    jmp .lpt_scan_null
.lpt_found_null:
    add r15, rcx

    ; Append display type + depth
    mov eax, [rsp+56]
    cmp eax, DISPLAY_BLOCK
    je .lpt_disp_block
    cmp eax, DISPLAY_NONE
    je .lpt_disp_none
    jmp .lpt_disp_inline

.lpt_disp_block:
    lea r8, [rel str_layout_disp]
    jmp .lpt_disp_fmt
.lpt_disp_none:
    lea r8, [rel str_layout_none]
    jmp .lpt_disp_fmt
.lpt_disp_inline:
    lea r8, [rel str_layout_inline]

.lpt_disp_fmt:
    mov rcx, r15
    mov edx, 40
    mov r9d, r13d
    call herb_snprintf

    lea rcx, [rel layout_tmp_buf]
    call serial_print

    ; --- Tree traversal ---
    mov r12d, [rsp+32]
    movsxd rax, r12d
    shl rax, 5
    lea rsi, [r14 + rax]

    cmp dword [rsi + DOM_NODE_FIRST_CHILD], -1
    je .lpt_no_child
    mov r12d, [rsi + DOM_NODE_FIRST_CHILD]
    inc r13d
    jmp .lpt_loop

.lpt_no_child:
    cmp dword [rsi + DOM_NODE_NEXT_SIB], -1
    je .lpt_backtrack
    mov r12d, [rsi + DOM_NODE_NEXT_SIB]
    jmp .lpt_loop

.lpt_backtrack:
    mov r12d, [rsi + DOM_NODE_PARENT]
    dec r13d
    cmp r12d, -1
    je .lpt_done
    movsxd rax, r12d
    shl rax, 5
    lea rsi, [r14 + rax]
    cmp dword [rsi + DOM_NODE_NEXT_SIB], -1
    jne .lpt_bt_found
    jmp .lpt_backtrack

.lpt_bt_found:
    mov r12d, [rsi + DOM_NODE_NEXT_SIB]
    jmp .lpt_loop

.lpt_done:
    add rsp, 88
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ------------------------------------------------------------
; browser_layout_cmd() -> void
;
; Shell command handler for /layout.
; ------------------------------------------------------------
browser_layout_cmd:
    push rbp
    push rbx
    push rsi
    sub rsp, 48

    cmp dword [rel tcp_recv_done], 1
    jne .blc_use_test
    cmp dword [rel http_body_len], 0
    jle .blc_use_test

    lea rcx, [rel tcp_recv_buf]
    movsxd rax, dword [rel http_body_offset]
    add rcx, rax
    mov edx, [rel http_body_len]
    jmp .blc_go

.blc_use_test:
    lea rcx, [rel html_test_src]
    mov edx, HTML_TEST_LEN

.blc_go:
    call html_tokenize_all

    call dom_build_tree
    mov ebx, eax

    call layout_create_entities

    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    mov r9d, 1280
    call layout_tree

    call layout_print_tree

    lea rcx, [rel layout_tmp_buf]
    mov edx, 256
    lea r8, [rel str_la_layout]
    mov r9d, ebx
    call herb_snprintf
    lea rcx, [rel layout_tmp_buf]
    call shell_output_print

    add rsp, 48
    pop rsi
    pop rbx
    pop rbp
    ret


; ============================================================
; Paint cache entry offsets (32 bytes per entry)
; ============================================================
PC_X         equ 0       ; layout_x (viewport-relative, i32)
PC_Y         equ 4       ; layout_y (i32)
PC_W         equ 8       ; layout_w (i32)
PC_H         equ 12      ; layout_h (i32)
PC_DISPLAY   equ 16      ; 0=block, 1=inline, 2=none
PC_IS_TEXT   equ 20      ; 1 if text node
PC_TEXT_OFF  equ 24      ; offset into html_last_src for text content
PC_TEXT_LEN  equ 28      ; character count

FONT_WIDTH_B equ 12
FONT_HEIGHT_B equ 24


; ============================================================
; browser_build_paint_cache() -> EAX=visible_count
;
; Walk DOM nodes, read layout from HERB entities, populate paint_cache[].
; Sets paint_cache_count.
; ============================================================
browser_build_paint_cache:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72                     ; locals at [rsp+32..80+]

    ; [rsp+32] = free for 5th arg
    ; [rsp+40] = i (loop index)
    ; [rsp+44] = visible count
    ; [rsp+48] = saved x
    ; [rsp+52] = saved y
    ; [rsp+56] = saved w
    ; [rsp+60] = saved h
    ; [rsp+64] = saved is_text
    ; [rsp+68] = saved text_len

    mov dword [rel paint_cache_count], 0
    mov dword [rsp+44], 0           ; visible = 0

    mov r12d, dword [rel dom_node_count]
    test r12d, r12d
    jz .bpc_done

    xor ebx, ebx                   ; i = 0
.bpc_loop:
    cmp ebx, r12d
    jge .bpc_done

    ; Check if we have a layout entity for this node
    lea rax, [rel layout_entity_ids]
    movsxd rcx, ebx
    mov r13d, dword [rax + rcx*4]   ; entity_id
    test r13d, r13d
    js .bpc_next                    ; -1 or negative = no entity

    ; Read display
    mov ecx, r13d
    lea rdx, [rel str_prop_display]
    xor r8d, r8d                    ; default BLOCK
    call herb_entity_prop_int
    mov r14d, eax                   ; display

    ; Skip display=NONE (2)
    cmp r14d, 2
    je .bpc_next

    ; Read layout_x
    mov ecx, r13d
    lea rdx, [rel str_prop_layout_x]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp+48], eax

    ; Read layout_y
    mov ecx, r13d
    lea rdx, [rel str_prop_layout_y]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp+52], eax

    ; Read layout_w
    mov ecx, r13d
    lea rdx, [rel str_prop_layout_w]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp+56], eax

    ; Read layout_h
    mov ecx, r13d
    lea rdx, [rel str_prop_layout_h]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp+60], eax

    ; Skip if w == 0 and h == 0
    mov eax, dword [rsp+56]
    or eax, dword [rsp+60]
    jz .bpc_next

    ; Read is_text
    mov ecx, r13d
    lea rdx, [rel str_prop_is_text]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp+64], eax

    ; Read text_len
    mov ecx, r13d
    lea rdx, [rel str_prop_text_len]
    xor r8d, r8d
    call herb_entity_prop_int
    mov dword [rsp+68], eax

    ; Fill paint_cache entry
    mov eax, dword [rel paint_cache_count]
    cmp eax, 512
    jge .bpc_done                   ; overflow guard
    mov esi, eax                    ; save index
    shl eax, 5                      ; * 32
    lea rcx, [rel paint_cache]
    add rcx, rax                    ; rcx = entry ptr

    mov eax, dword [rsp+48]
    mov dword [rcx + PC_X], eax
    mov eax, dword [rsp+52]
    mov dword [rcx + PC_Y], eax
    mov eax, dword [rsp+56]
    mov dword [rcx + PC_W], eax
    mov eax, dword [rsp+60]
    mov dword [rcx + PC_H], eax
    mov dword [rcx + PC_DISPLAY], r14d
    mov eax, dword [rsp+64]
    mov dword [rcx + PC_IS_TEXT], eax
    ; PC_TEXT_OFF from DOM node's TAG_START
    movsxd rax, ebx
    shl rax, 5                      ; * DOM_NODE_SIZE
    lea rdx, [rel dom_nodes]
    mov eax, dword [rdx + rax + DOM_NODE_TAG_START]
    mov dword [rcx + PC_TEXT_OFF], eax
    mov eax, dword [rsp+68]
    mov dword [rcx + PC_TEXT_LEN], eax

    inc dword [rel paint_cache_count]
    inc dword [rsp+44]

.bpc_next:
    inc ebx
    jmp .bpc_loop

.bpc_done:
    mov eax, dword [rsp+44]         ; return visible count
    add rsp, 72
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
; browser_draw_fn(ECX=cx, EDX=cy, R8D=cw, R9D=ch, [rbp+48]=win_ptr)
;
; WM draw callback for the BROWSER window. Called each frame.
; Reads from paint_cache[] (flat array built by /paint).
; ============================================================
browser_draw_fn:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88                     ; 8 pushes (64) + sub 88 + rbp+ret (16) = 168 (aligned)

    ; Save client rect to callee-saved regs (survive function calls)
    mov r12d, ecx                   ; cx
    mov r13d, edx                   ; cy
    mov r14d, r8d                   ; cw
    mov r15d, r9d                   ; ch

    ; wm_set_clip(cx, cy, cw, ch)
    ; args already in ecx/edx/r8d/r9d
    call wm_set_clip

    ; fb_fill_rect(cx, cy, cw, ch, 0x00F0F0F0) — white background
    mov ecx, r12d
    mov edx, r13d
    mov r8d, r14d
    mov r9d, r15d
    mov dword [rsp+32], 0x00F0F0F0
    call fb_fill_rect

    ; If paint not ready or empty, show placeholder
    cmp dword [rel paint_ready], 0
    je .bdf_placeholder
    cmp dword [rel paint_cache_count], 0
    je .bdf_placeholder
    jmp .bdf_paint

.bdf_placeholder:
    ; fb_draw_string(cx+12, cy+12, "Type /paint", 0x808080, 0)
    lea ecx, [r12d + 12]
    lea edx, [r13d + 12]
    lea r8, [rel str_paint_hint]
    mov r9d, 0x00808080
    mov dword [rsp+32], 0
    call fb_draw_string
    jmp .bdf_done

.bdf_paint:
    ; Walk paint cache
    ; [rsp+48] = cx, [rsp+52] = cy, [rsp+56] = cw, [rsp+60] = ch (stable copies)
    mov dword [rsp+48], r12d
    mov dword [rsp+52], r13d
    mov dword [rsp+56], r14d
    mov dword [rsp+60], r15d

    xor ebx, ebx                   ; i = 0
    mov esi, dword [rel paint_cache_count]

.bdf_loop:
    cmp ebx, esi
    jge .bdf_done

    ; Load entry
    mov eax, ebx
    shl eax, 5                      ; * 32
    lea rdi, [rel paint_cache]
    add rdi, rax                    ; rdi = entry ptr

    ; Skip display == NONE (2)
    cmp dword [rdi + PC_DISPLAY], 2
    je .bdf_next

    ; Skip if w == 0 or h == 0
    cmp dword [rdi + PC_W], 0
    je .bdf_next
    cmp dword [rdi + PC_H], 0
    je .bdf_next

    ; Skip non-text (no visual for element boxes)
    cmp dword [rdi + PC_IS_TEXT], 0
    je .bdf_next

    ; Skip if text_len == 0
    cmp dword [rdi + PC_TEXT_LEN], 0
    je .bdf_next

    ; Compute screen positions
    ; screen_x = cx + entry.x
    mov eax, dword [rsp+48]         ; cx
    add eax, dword [rdi + PC_X]
    mov dword [rsp+64], eax         ; screen_x

    ; screen_y = cy + entry.y
    mov eax, dword [rsp+52]         ; cy
    add eax, dword [rdi + PC_Y]
    mov dword [rsp+68], eax         ; screen_y

    ; Clip: skip if entirely below window
    mov eax, dword [rsp+68]         ; screen_y
    mov ecx, dword [rsp+52]
    add ecx, dword [rsp+60]         ; cy + ch
    cmp eax, ecx
    jge .bdf_next

    ; Clip: skip if entirely above window
    mov eax, dword [rsp+68]
    add eax, dword [rdi + PC_H]     ; screen_y + entry.h
    cmp eax, dword [rsp+52]         ; cy
    jle .bdf_next

    ; Draw text characters
    ; r12 = draw_x, r13 = draw_y (reuse callee-saved, save/restore cx/cy later)
    mov r12d, dword [rsp+64]        ; draw_x = screen_x
    mov r13d, dword [rsp+68]        ; draw_y = screen_y

    ; r14 = max_x (screen_x + entry.w)
    mov r14d, dword [rsp+64]
    add r14d, dword [rdi + PC_W]

    ; r15 = max_y (screen_y + entry.h)
    mov r15d, dword [rsp+68]
    add r15d, dword [rdi + PC_H]

    ; Get source text pointer
    mov rax, [rel html_last_src]
    movsxd rcx, dword [rdi + PC_TEXT_OFF]
    add rax, rcx
    mov [rsp+72], rax               ; src pointer

    mov dword [rsp+80], 0           ; char index

.bdf_char_loop:
    mov eax, dword [rsp+80]
    cmp eax, dword [rdi + PC_TEXT_LEN]
    jge .bdf_next

    ; Check y overflow
    mov eax, r13d
    add eax, FONT_HEIGHT_B
    cmp eax, r15d
    jg .bdf_next

    ; Get character
    mov rax, [rsp+72]               ; src ptr
    movsxd rcx, dword [rsp+80]
    movzx eax, byte [rax + rcx]

    ; Skip control chars (< 32), but treat them as spaces
    cmp eax, 32
    jge .bdf_printable
    mov eax, 32                     ; replace with space
.bdf_printable:

    ; fb_draw_char(draw_x, draw_y, ch, fg=0x202020, bg=0)
    mov ecx, r12d
    mov edx, r13d
    mov r8d, eax
    mov r9d, 0x00202020             ; dark gray text
    mov dword [rsp+32], 0           ; transparent bg
    ; Save rdi (entry ptr) — clobbered by call
    mov [rsp+40], rdi
    call fb_draw_char
    mov rdi, [rsp+40]               ; restore entry ptr

    ; Advance draw_x
    add r12d, FONT_WIDTH_B

    ; Check wrap: if draw_x + FONT_WIDTH > max_x, newline
    mov eax, r12d
    add eax, FONT_WIDTH_B
    cmp eax, r14d
    jle .bdf_no_wrap

    ; Wrap: draw_x = screen_x, draw_y += FONT_HEIGHT
    mov r12d, dword [rsp+64]
    add r13d, FONT_HEIGHT_B

.bdf_no_wrap:
    inc dword [rsp+80]
    jmp .bdf_char_loop

.bdf_next:
    inc ebx
    jmp .bdf_loop

.bdf_done:
    call wm_clear_clip

    ; Restore cx/cy/cw/ch to r12-r15 is not needed — we're done
    add rsp, 88
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
; browser_paint_cmd() -> void
;
; Shell command handler for /paint.
; Runs full pipeline: tokenize → DOM → layout → paint cache.
; ============================================================
browser_paint_cmd:
    push rbp
    push rbx
    push rsi
    push rdi
    sub rsp, 56                     ; [rsp+32] = free for 5th arg

    ; Select HTML source (HTTP body or test HTML)
    cmp dword [rel tcp_recv_done], 1
    jne .bpc2_use_test
    cmp dword [rel http_body_len], 0
    jle .bpc2_use_test

    lea rcx, [rel tcp_recv_buf]
    movsxd rax, dword [rel http_body_offset]
    add rcx, rax
    mov edx, [rel http_body_len]
    jmp .bpc2_go

.bpc2_use_test:
    lea rcx, [rel html_test_src]
    mov edx, HTML_TEST_LEN

.bpc2_go:
    ; Tokenize
    call html_tokenize_all
    mov ebx, eax                    ; token count (not used but good to have)

    ; Build DOM
    call dom_build_tree
    mov esi, eax                    ; node count

    ; Create layout entities
    call layout_create_entities

    ; Run layout
    xor ecx, ecx                   ; root node = 0
    xor edx, edx                   ; x = 0
    xor r8d, r8d                   ; y = 0
    mov r9d, 440                   ; avail_width = browser window content (~448 - 8 padding)
    call layout_tree

    ; Build paint cache
    call browser_build_paint_cache
    mov edi, eax                    ; visible count

    ; Mark paint as ready
    mov dword [rel paint_ready], 1

    ; Print serial summary: [PAINT] N nodes, M visible
    lea rcx, [rel layout_tmp_buf]
    mov edx, 256
    lea r8, [rel str_paint_hdr]
    mov r9d, esi                    ; node count
    mov dword [rsp+32], edi         ; visible count
    call herb_snprintf
    lea rcx, [rel layout_tmp_buf]
    call serial_print

    ; Print to shell output: "Paint: N visible"
    lea rcx, [rel layout_tmp_buf]
    mov edx, 256
    lea r8, [rel str_la_paint]
    mov r9d, edi
    call herb_snprintf
    lea rcx, [rel layout_tmp_buf]
    call shell_output_print

    add rsp, 56
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ============================================================
; browser_browse_cmd(RCX=domain_ptr) -> void
;
; Shell command handler for /browse.
; Starts HTTP GET, busy-polls until response, then runs full
; browser pipeline (tokenize -> DOM -> layout -> paint).
; ============================================================
browser_browse_cmd:
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    ; 6 pushes = 48 bytes. (8 + 48 + N) % 16 == 0 → N = 72
    sub rsp, 72

    mov [rsp+64], rcx       ; save domain_ptr

    ; 1. Check NIC
    cmp dword [rel net_present], 0
    je .browse_no_nic

    ; 2. Copy domain to browse_domain_buf (max 63 chars)
    mov rsi, rcx            ; source = domain_ptr
    lea rdi, [rel browse_domain_buf]
    xor ecx, ecx
.browse_copy:
    cmp ecx, 63
    jge .browse_copy_done
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz .browse_copy_done
    inc ecx
    jmp .browse_copy
.browse_copy_done:
    mov byte [rdi + rcx], 0 ; null terminate

    ; 3. Serial: [BROWSE] fetching domain...
    lea rcx, [rel str_browse_fetch]
    call serial_print
    lea rcx, [rel browse_domain_buf]
    call serial_print
    lea rcx, [rel str_browse_dots]
    call serial_print

    ; 4. Shell output: "Browse: fetching..."
    lea rcx, [rel str_la_browse]
    call shell_output_print

    ; 5. http_get(domain, "/")
    lea rcx, [rel browse_domain_buf]
    lea rdx, [rel str_browse_slash]
    call http_get

    ; 6. Busy-poll loop (max 50,000 iterations)
    xor r12d, r12d          ; counter
.browse_poll:
    cmp r12d, 2000000
    jge .browse_timeout

    call net_poll_rx
    call http_poll_state

    cmp dword [rel tcp_recv_done], 1
    je .browse_got_response

    inc r12d
    jmp .browse_poll

.browse_timeout:
    ; Serial + shell output: failed
    lea rcx, [rel str_browse_fail]
    call serial_print
    lea rcx, [rel str_la_browse_fail]
    call shell_output_print
    jmp .browse_return

.browse_got_response:
    ; Check body length
    cmp dword [rel http_body_len], 0
    jle .browse_timeout     ; no body = failure

    ; Serial: [BROWSE] received N bytes body
    lea rcx, [rel layout_tmp_buf]
    mov edx, 256
    lea r8, [rel str_browse_recv]
    mov r9d, [rel http_body_len]
    call herb_snprintf
    lea rcx, [rel layout_tmp_buf]
    call serial_print

    ; 7. Run full browser pipeline
    call browser_paint_cmd  ; auto-detects HTTP body

    ; Serial + shell output: done
    lea rcx, [rel str_browse_done]
    call serial_print
    lea rcx, [rel str_la_browse_done]
    call shell_output_print

.browse_return:
    add rsp, 72
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

.browse_no_nic:
    lea rcx, [rel str_browse_no_nic]
    call serial_print
    lea rcx, [rel str_la_browse_nonet]
    call shell_output_print
    jmp .browse_return
