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
