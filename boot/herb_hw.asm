; boot/herb_hw.asm — HERB hardware interface (Phase 2 assembly)
;
; x86-64 hardware primitives. Called from C via Microsoft x64 ABI.
; Replaces inline asm wrappers in kernel_main.c and framebuffer.h.
;
; Session 58: outb, inb (port I/O bytes)
; Session 59: outw, inw, outl, inl, io_wait (port I/O words/dwords)
;             hw_lidt, hw_sti, hw_hlt, hw_flush_tlb (privileged CPU ops)
; Session 60: serial_init, serial_putchar, serial_print (serial port)
; Session 61: pic_remap, pit_init (interrupt infrastructure)
;
; Assembled with: nasm -f win64 herb_hw.asm -o herb_hw.o

[bits 64]
default rel

; Port I/O
global outb
global inb
global outw
global inw
global outl
global inl
global io_wait

; Privileged CPU operations
global hw_lidt
global hw_sti
global hw_hlt
global hw_flush_tlb

; Serial port (COM1)
global serial_init
global serial_putchar
global serial_print

; Interrupt infrastructure (PIC + PIT)
global pic_remap
global pit_init

; PS/2 mouse
global ps2_wait_input
global ps2_wait_output
global mouse_write
global mouse_read
global mouse_init

; VGA text mode (Phase D Step 1)
global serial_print_int
global vga_set_color
global vga_clear
global vga_putchar
global vga_print
global vga_print_at
global vga_print_int
global vga_clear_row
global vga_print_padded
global vga_color
global vga_row
global vga_col

; Framebuffer primitives (Phase D Step 2)
global fb_init_display
global fb_pixel
global fb_clear
global fb_fill_rect
global fb_draw_rect
global fb_draw_rect2
global fb_hline
global fb_flip
global fb_ptr
global fb_back
global fb_w
global fb_h
global fb_active

; Framebuffer text + widgets + cursor (Phase D Step 3)
global fb_draw_char
global fb_draw_string
global fb_draw_int
global fb_draw_padded
global fb_draw_container
global fb_draw_process
global fb_draw_resources
global fb_cursor_draw
global fb_cursor_erase
global cursor_x
global cursor_y
global cursor_old_x
global cursor_old_y

; PCI config read (used by herb_net.asm)
global hw_pci_read

; Clip rectangle
global wm_clip_x
global wm_clip_y
global wm_clip_w
global wm_clip_h
global wm_clip_enabled
global wm_set_clip
global wm_clear_clip

; Utility (from herb_freestanding.asm)
extern herb_snprintf
; Privileged ops (defined in this file, referenced internally)
; hw_flush_tlb — already defined above

section .text

; ============================================================
; PORT I/O — Tier 1
; ============================================================

; void outb(uint16_t port, uint8_t val)
; MS x64: rcx = port, rdx = val
outb:
    mov al, dl          ; val -> AL (read before dx clobbered)
    mov dx, cx          ; port -> DX
    out dx, al
    ret

; uint8_t inb(uint16_t port)
; MS x64: rcx = port, return in rax
inb:
    xor eax, eax        ; zero full rax for clean return
    mov dx, cx          ; port -> DX
    in al, dx            ; read port -> AL
    ret

; void outw(uint16_t port, uint16_t val)
; MS x64: rcx = port, rdx = val
outw:
    mov ax, dx          ; val -> AX (read before dx clobbered)
    mov dx, cx          ; port -> DX
    out dx, ax
    ret

; uint16_t inw(uint16_t port)
; MS x64: rcx = port, return in rax
inw:
    xor eax, eax        ; zero full rax for clean return
    mov dx, cx          ; port -> DX
    in ax, dx            ; read port -> AX
    ret

; void outl(uint16_t port, uint32_t val)
; MS x64: rcx = port, rdx = val
outl:
    mov eax, edx        ; val -> EAX (read before dx clobbered)
    mov dx, cx          ; port -> DX
    out dx, eax
    ret

; uint32_t inl(uint16_t port)
; MS x64: rcx = port, return in rax
inl:
    xor eax, eax        ; zero full rax for clean return
    mov dx, cx          ; port -> DX
    in eax, dx           ; read port -> EAX
    ret

; void io_wait(void)
; Write to port 0x80 (POST diagnostic, safe to write) for ~1µs delay
io_wait:
    mov al, 0
    mov dx, 0x80
    out dx, al
    ret

; ============================================================
; PRIVILEGED CPU OPERATIONS — Tier 2
; ============================================================

; void hw_lidt(void* idt_descriptor)
; MS x64: rcx = pointer to IDT descriptor struct
hw_lidt:
    lidt [rcx]
    ret

; void hw_sti(void)
; Enable interrupts
hw_sti:
    sti
    ret

; void hw_hlt(void)
; Halt CPU until next interrupt
hw_hlt:
    hlt
    ret

; void hw_flush_tlb(void)
; Flush TLB by reloading CR3
hw_flush_tlb:
    mov rax, cr3
    mov cr3, rax
    ret

; ============================================================
; SERIAL PORT (COM1) — Tier 3
; ============================================================

; void serial_init(void)
; Configure COM1 UART: 115200 baud, 8N1, FIFO enabled
serial_init:
    ; Disable interrupts
    mov dx, 0x3F9           ; COM1 + 1
    mov al, 0x00
    out dx, al

    ; Enable DLAB (set baud rate divisor)
    mov dx, 0x3FB           ; COM1 + 3
    mov al, 0x80
    out dx, al

    ; Divisor low byte = 1 (115200 baud)
    mov dx, 0x3F8           ; COM1 + 0
    mov al, 0x01
    out dx, al

    ; Divisor high byte = 0
    mov dx, 0x3F9           ; COM1 + 1
    mov al, 0x00
    out dx, al

    ; 8 bits, no parity, 1 stop bit (8N1), DLAB off
    mov dx, 0x3FB           ; COM1 + 3
    mov al, 0x03
    out dx, al

    ; Enable FIFO, clear, 14-byte threshold
    mov dx, 0x3FA           ; COM1 + 2
    mov al, 0xC7
    out dx, al

    ; DTR + RTS + OUT2
    mov dx, 0x3FC           ; COM1 + 4
    mov al, 0x0B
    out dx, al

    ret

; void serial_putchar(char c)
; MS x64: c in cl. Poll until TX ready, then send.
serial_putchar:
    mov r8b, cl             ; save char (r8 is volatile, no calls here)
.poll:
    mov dx, 0x3FD           ; COM1 + 5 (Line Status Register)
    in al, dx
    test al, 0x20           ; bit 5 = TX holding register empty
    jz .poll
    mov dx, 0x3F8           ; COM1 + 0 (data register)
    mov al, r8b
    out dx, al
    ret

; void serial_print(const char* s)
; MS x64: s in rcx. Loop over string, emit \r before \n.
serial_print:
    push rsi                ; rsi is non-volatile in MS x64
    sub rsp, 32             ; shadow space for serial_putchar calls
    mov rsi, rcx            ; save string pointer
.loop:
    movzx eax, byte [rsi]
    test al, al
    jz .done
    cmp al, 0x0A            ; '\n'?
    jne .emit
    ; Emit \r before \n
    mov cl, 0x0D
    call serial_putchar
.emit:
    mov cl, [rsi]
    call serial_putchar
    inc rsi
    jmp .loop
.done:
    add rsp, 32             ; restore shadow space
    pop rsi
    ret

; ============================================================
; INTERRUPT INFRASTRUCTURE (PIC + PIT) — Tier 3
; ============================================================

; void pic_remap(void)
; Remap 8259 PICs: master IRQ0-7 → vectors 0x20-0x27
;                  slave  IRQ8-15 → vectors 0x28-0x2F
; Unmask: IRQ0(timer), IRQ1(keyboard), IRQ2(cascade), IRQ12(mouse)
pic_remap:
    ; Drain pending data
    in al, 0x21          ; read master data (discard)
    in al, 0xA1          ; read slave data (discard)

    ; ICW1: init + ICW4 needed
    mov al, 0x11
    out 0x20, al         ; master CMD
    out 0x80, al         ; io_wait
    out 0xA0, al         ; slave CMD
    out 0x80, al         ; io_wait

    ; ICW2: vector base addresses
    mov al, 0x20
    out 0x21, al         ; master: IRQ0 → vector 32
    out 0x80, al         ; io_wait
    mov al, 0x28
    out 0xA1, al         ; slave: IRQ8 → vector 40
    out 0x80, al         ; io_wait

    ; ICW3: cascade wiring
    mov al, 0x04
    out 0x21, al         ; master: slave on IR2
    out 0x80, al         ; io_wait
    mov al, 0x02
    out 0xA1, al         ; slave: cascade identity 2
    out 0x80, al         ; io_wait

    ; ICW4: 8086 mode
    mov al, 0x01
    out 0x21, al         ; master
    out 0x80, al         ; io_wait
    out 0xA1, al         ; slave (same value)
    out 0x80, al         ; io_wait

    ; IMR: interrupt masks
    mov al, 0xF8         ; 11111000 → unmask IRQ0,1,2
    out 0x21, al
    mov al, 0xEF         ; 11101111 → unmask IRQ12 (bit 4 on slave)
    out 0xA1, al
    ret

; void pit_init(int hz)
; MS x64: ecx = frequency in Hz
; Programs PIT channel 0: mode 3 (square wave), 16-bit divisor
pit_init:
    mov eax, 1193182     ; PIT base frequency
    xor edx, edx         ; zero-extend for div
    div ecx              ; eax = 1193182 / hz
    mov ecx, eax         ; save divisor

    mov al, 0x36         ; channel 0, lobyte/hibyte, mode 3, binary
    out 0x43, al         ; PIT command port

    mov al, cl           ; divisor low byte
    out 0x40, al         ; PIT channel 0 data

    mov al, ch           ; divisor high byte
    out 0x40, al
    ret

; ============================================================
; PS/2 MOUSE — Tier 3/4
; ============================================================

; void ps2_wait_input(void)
; Poll status port 0x64 bit 1 until clear (input buffer empty).
; Timeout after 100,000 iterations to prevent hang on missing hardware.
ps2_wait_input:
    mov ecx, 100000
.loop:
    in al, 0x64
    test al, 0x02           ; bit 1 = input buffer full
    jz .done
    dec ecx
    jnz .loop
.done:
    ret

; void ps2_wait_output(void)
; Poll status port 0x64 bit 0 until set (output buffer has data).
; Timeout after 100,000 iterations.
ps2_wait_output:
    mov ecx, 100000
.loop:
    in al, 0x64
    test al, 0x01           ; bit 0 = output buffer full
    jnz .done
    dec ecx
    jnz .loop
.done:
    ret

; void mouse_write(uint8_t data)
; MS x64: data in cl. Send 0xD4 prefix to 0x64, wait, write data to 0x60.
mouse_write:
    push rbx                ; save non-volatile (also aligns stack to 16)
    sub rsp, 32             ; shadow space
    mov bl, cl              ; save data byte in non-volatile register

    call ps2_wait_input
    mov al, 0xD4            ; prefix: next byte goes to auxiliary device
    out 0x64, al

    call ps2_wait_input
    mov al, bl              ; retrieve saved data byte
    out 0x60, al

    add rsp, 32
    pop rbx
    ret

; uint8_t mouse_read(void)
; Wait for output buffer, read byte from 0x60. Return in AL.
mouse_read:
    sub rsp, 40             ; shadow space (40 = 32 + 8 for alignment, no push)
    call ps2_wait_output
    xor eax, eax            ; zero-extend for clean return
    in al, 0x60
    add rsp, 40
    ret

; void mouse_init(void)
; Full PS/2 mouse initialization: enable aux device, configure IRQ12,
; enable data reporting.
mouse_init:
    push rbx                ; save non-volatile (also aligns stack to 16)
    sub rsp, 32             ; shadow space

    ; Enable the auxiliary device (mouse)
    call ps2_wait_input
    mov al, 0xA8
    out 0x64, al

    ; Read controller configuration byte
    call ps2_wait_input
    mov al, 0x20            ; command: read config
    out 0x64, al
    call ps2_wait_output
    in al, 0x60             ; read config byte
    mov bl, al              ; save config in non-volatile register

    ; Enable IRQ12 (set bit 1) and enable aux clock (clear bit 5)
    or bl, 0x02             ; set bit 1: enable IRQ12
    and bl, 0xDF            ; clear bit 5 (0xDF = ~0x20): enable aux clock

    ; Write modified configuration byte back
    call ps2_wait_input
    mov al, 0x60            ; command: write config
    out 0x64, al
    call ps2_wait_input
    mov al, bl              ; modified config
    out 0x60, al

    ; Enable data reporting on the mouse (command 0xF4)
    mov cl, 0xF4
    call mouse_write
    call mouse_read         ; ACK (0xFA) — discard

    add rsp, 32
    pop rbx
    ret

; ============================================================
; VGA TEXT MODE — Tier 5 (Phase D Step 1)
;
; Ported from kernel_main.c. VGA text mode output via 0xB8000.
; ============================================================

VGA_ADDR   equ 0xB8000
VGA_WIDTH  equ 80
VGA_HEIGHT equ 25

; void serial_print_int(int val)
; MS x64: ECX = val. Format val as decimal string, emit via serial port.
serial_print_int:
    push rbx
    sub rsp, 48                 ; shadow(32) + buf[16]
    mov ebx, ecx                ; save val
    ; herb_snprintf(buf, 16, "%d", val)
    lea rcx, [rsp + 32]         ; buf
    mov edx, 16                 ; sizeof(buf)
    lea r8, [rel hw_fmt_d]      ; "%d"
    mov r9d, ebx                ; val
    call herb_snprintf
    ; serial_print(buf)
    lea rcx, [rsp + 32]
    call serial_print
    add rsp, 48
    pop rbx
    ret

; void vga_set_color(uint8_t fg, uint8_t bg)
; MS x64: CL = fg, DL = bg
vga_set_color:
    shl dl, 4                   ; bg << 4
    and cl, 0x0F                ; fg & 0x0F
    or cl, dl                   ; (bg << 4) | (fg & 0x0F)
    mov [rel vga_color], cl
    ret

; void vga_clear(void)
; Fill VGA_WIDTH*VGA_HEIGHT words with blank in current color, reset cursor.
vga_clear:
    movzx eax, byte [rel vga_color]
    shl eax, 8
    or eax, 0x20                ; blank = ' ' | (color << 8)
    mov ecx, VGA_WIDTH * VGA_HEIGHT
    mov edx, VGA_ADDR
.vgc_loop:
    mov word [rdx], ax
    add rdx, 2
    dec ecx
    jnz .vgc_loop
    mov dword [rel vga_row], 0
    mov dword [rel vga_col], 0
    ret

; void vga_putchar(char c)
; MS x64: CL = c. Handle \n, \r, bounds check, write char+color to VGA.
vga_putchar:
    cmp cl, 10                  ; '\n'?
    je .vgp_newline
    cmp cl, 13                  ; '\r'?
    je .vgp_cr
    ; Bounds check
    mov eax, [rel vga_row]
    cmp eax, VGA_HEIGHT
    jge .vgp_done
    mov edx, [rel vga_col]
    cmp edx, VGA_WIDTH
    jge .vgp_done
    ; offset = row * VGA_WIDTH + col
    imul eax, eax, VGA_WIDTH
    add eax, edx
    ; word = c | (vga_color << 8)
    movzx r8d, byte [rel vga_color]
    shl r8d, 8
    movzx ecx, cl
    or ecx, r8d
    ; Write to VGA buffer
    mov edx, VGA_ADDR
    mov word [rdx + rax*2], cx
    ; vga_col++
    inc dword [rel vga_col]
.vgp_done:
    ret
.vgp_newline:
    mov dword [rel vga_col], 0
    inc dword [rel vga_row]
    ret
.vgp_cr:
    mov dword [rel vga_col], 0
    ret

; void vga_print(const char* s)
; MS x64: RCX = s. Loop over string, calling vga_putchar for each char.
vga_print:
    push rsi
    sub rsp, 32                 ; shadow space
    mov rsi, rcx
.vgpr_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .vgpr_done
    mov cl, al
    call vga_putchar
    inc rsi
    jmp .vgpr_loop
.vgpr_done:
    add rsp, 32
    pop rsi
    ret

; void vga_print_at(int row, int col, const char* s)
; MS x64: ECX = row, EDX = col, R8 = s. Set cursor position, print string.
vga_print_at:
    mov [rel vga_row], ecx
    mov [rel vga_col], edx
    mov rcx, r8
    jmp vga_print               ; tail call

; void vga_print_int(int val)
; MS x64: ECX = val. Format val as decimal, print via VGA.
vga_print_int:
    push rbx
    sub rsp, 48                 ; shadow(32) + buf[16]
    mov ebx, ecx
    ; herb_snprintf(buf, 16, "%d", val)
    lea rcx, [rsp + 32]         ; buf
    mov edx, 16
    lea r8, [rel hw_fmt_d]      ; "%d"
    mov r9d, ebx
    call herb_snprintf
    ; vga_print(buf)
    lea rcx, [rsp + 32]
    call vga_print
    add rsp, 48
    pop rbx
    ret

; void vga_clear_row(int row)
; MS x64: ECX = row. Fill one row with spaces in the current color.
vga_clear_row:
    movzx eax, byte [rel vga_color]
    shl eax, 8
    or eax, 0x20                ; blank = ' ' | (color << 8)
    imul ecx, ecx, VGA_WIDTH
    mov edx, VGA_ADDR
    lea rdx, [rdx + rcx*2]     ; &vga_buffer[row * VGA_WIDTH]
    mov ecx, VGA_WIDTH
.vcr_loop:
    mov word [rdx], ax
    add rdx, 2
    dec ecx
    jnz .vcr_loop
    ret

; void vga_print_padded(const char* s, int width)
; MS x64: RCX = s, EDX = width. Print string padded to exactly width chars.
vga_print_padded:
    push rbx
    push rsi
    push rdi
    sub rsp, 32                 ; shadow space
    mov rsi, rcx                ; s
    mov edi, edx                ; width
    xor ebx, ebx                ; i = 0
.vpp_char_loop:
    cmp ebx, edi
    jge .vpp_done
    movzx eax, byte [rsi + rbx]
    test al, al
    jz .vpp_pad
    mov cl, al
    call vga_putchar
    inc ebx
    jmp .vpp_char_loop
.vpp_pad:
    cmp ebx, edi
    jge .vpp_done
    mov cl, ' '
    call vga_putchar
    inc ebx
    jmp .vpp_pad
.vpp_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; ============================================================
; FRAMEBUFFER PRIMITIVES — Tier 6 (Phase D Step 2)
;
; Ported from framebuffer.h. BGA graphics adapter + double-buffered
; pixel rendering. Back buffer in system RAM, fb_flip() copies to MMIO.
; ============================================================

FB_WIDTH     equ 1280
FB_HEIGHT    equ 800
FB_BPP       equ 32
FB_PIXELS    equ FB_WIDTH * FB_HEIGHT     ; 1024000
BACKBUF_ADDR equ 0xC00000                 ; after 4MB arena (0x800000-0xBFFFFF)

; PCI config space
PCI_CONFIG_ADDR equ 0x0CF8
PCI_CONFIG_DATA equ 0x0CFC

; BGA register indices
BGA_INDEX_PORT    equ 0x01CE
BGA_DATA_PORT     equ 0x01CF
BGA_REG_ID        equ 0x00
BGA_REG_XRES      equ 0x01
BGA_REG_YRES      equ 0x02
BGA_REG_BPP       equ 0x03
BGA_REG_ENABLE    equ 0x04
BGA_REG_VIRT_WIDTH  equ 0x06
BGA_REG_VIRT_HEIGHT equ 0x07
BGA_REG_X_OFFSET  equ 0x08
BGA_REG_Y_OFFSET  equ 0x09
BGA_DISABLED      equ 0x00
BGA_ENABLED       equ 0x01
BGA_LFB_ENABLED   equ 0x40

; --- Internal helpers (not exported) ---

; hw_pci_read(bus=CL, slot=DL, func=R8B, offset=R9B) → EAX
; Leaf function — direct port I/O, no calls.
hw_pci_read:
    ; address = (1<<31) | (bus<<16) | (slot<<11) | (func<<8) | (offset & 0xFC)
    movzx eax, cl               ; bus
    shl eax, 16                 ; bus << 16
    or eax, 0x80000000          ; enable bit
    movzx ecx, dl               ; slot
    shl ecx, 11                 ; slot << 11
    or eax, ecx
    movzx ecx, r8b              ; func
    shl ecx, 8                  ; func << 8
    or eax, ecx
    movzx ecx, r9b              ; offset
    and ecx, 0xFC
    or eax, ecx
    ; outl(PCI_CONFIG_ADDR, address)
    mov dx, PCI_CONFIG_ADDR
    out dx, eax
    ; return inl(PCI_CONFIG_DATA)
    mov dx, PCI_CONFIG_DATA
    in eax, dx
    ret

; hw_bga_write(reg=CX, val=DX) — leaf, no return value
hw_bga_write:
    mov r8w, dx                 ; save val
    mov ax, cx                  ; reg
    mov dx, BGA_INDEX_PORT
    out dx, ax                  ; write reg index
    mov ax, r8w                 ; val
    mov dx, BGA_DATA_PORT
    out dx, ax                  ; write val
    ret

; hw_bga_read(reg=CX) → AX
hw_bga_read:
    mov ax, cx
    mov dx, BGA_INDEX_PORT
    out dx, ax                  ; write reg index
    mov dx, BGA_DATA_PORT
    in ax, dx                   ; read data
    ret

; --- Exported framebuffer functions ---

; int fb_init_display(void)
; PCI scan for BGA (vendor 0x1234, device 0x1111), map framebuffer,
; configure BGA mode 800x600x32. Returns 0 on success, <0 on failure.
fb_init_display:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40                 ; shadow(32) + 8(align)
    ; Stack: 8(ret)+8(rbp)+4*8(push)+40(sub) = 88. (88-8)%16=80%16=0 ✓

    ; --- find_bga_bar0: scan PCI bus 0 for BGA ---
    xor esi, esi                ; slot = 0
.fbi_pci_scan:
    cmp esi, 32
    jge .fbi_not_found
    ; pci_read(bus=0, slot=esi, func=0, offset=0)
    xor ecx, ecx               ; bus = 0
    mov edx, esi                ; slot
    xor r8d, r8d                ; func = 0
    xor r9d, r9d                ; offset = 0
    call hw_pci_read
    ; Check vendor 0x1234, device 0x1111
    mov ecx, eax
    and ecx, 0xFFFF             ; vendor
    cmp ecx, 0x1234
    jne .fbi_next_slot
    shr eax, 16                 ; device
    cmp ax, 0x1111
    jne .fbi_next_slot
    ; Found! Read BAR0 (offset 0x10)
    xor ecx, ecx               ; bus = 0
    mov edx, esi                ; slot
    xor r8d, r8d                ; func = 0
    mov r9d, 0x10               ; offset = BAR0
    call hw_pci_read
    and eax, 0xFFFFFFF0         ; mask BAR flags
    mov ebx, eax                ; save bar0 in rbx
    jmp .fbi_found
.fbi_next_slot:
    inc esi
    jmp .fbi_pci_scan
.fbi_not_found:
    mov eax, -1
    jmp .fbi_done

.fbi_found:
    ; rbx = bar0 (32-bit physical address, typically 0xFD000000)
    mov rdi, rbx                ; save bar0 in rdi (callee-saved)

    ; --- map_framebuffer: only handle 3-4GB range ---
    mov rax, 0xC0000000
    cmp rdi, rax
    jb .fbi_map_fail
    mov rax, 0x100000000
    cmp rdi, rax
    jae .fbi_map_fail

    ; Zero PD page at 0x4000 (512 entries × 8 bytes)
    mov edx, 0x4000
    xor eax, eax
    mov ecx, 512
.fbi_zero_pd:
    mov qword [rdx], rax
    add rdx, 8
    dec ecx
    jnz .fbi_zero_pd

    ; PDPT[3] → PD at 0x4000 (present + writable = 0x03)
    mov edx, 0x2000
    mov qword [rdx + 3*8], 0x4003

    ; Calculate PD entries: offset = bar0 - 0xC0000000
    mov rax, rdi
    mov rcx, 0xC0000000
    sub rax, rcx
    shr rax, 21                 ; pd_start = offset / 2MB
    mov esi, eax                ; esi = pd_start
    ; Map 8 × 2MB pages (16MB total)
    xor ecx, ecx                ; i = 0
.fbi_map_loop:
    cmp ecx, 8
    jge .fbi_map_done
    mov eax, esi
    add eax, ecx
    cmp eax, 512
    jge .fbi_map_done
    ; page_addr = bar0 + i * 2MB
    mov rax, rcx
    shl rax, 21                 ; i * 0x200000
    add rax, rdi                ; + bar0
    ; Flags: Present(1)+Writable(2)+PS/2MB(0x80)+PCD(0x10)+PWT(8) = 0x9B
    or rax, 0x9B
    ; new_pd[pd_start + i]
    mov r8d, esi
    add r8d, ecx
    mov edx, 0x4000
    mov [rdx + r8*8], rax
    inc ecx
    jmp .fbi_map_loop
.fbi_map_done:
    ; Flush TLB
    mov rax, cr3
    mov cr3, rax

    ; --- Verify BGA by reading ID register ---
    mov cx, BGA_REG_ID
    call hw_bga_read
    cmp ax, 0xB0C0
    jb .fbi_bga_fail
    cmp ax, 0xB0C5
    ja .fbi_bga_fail

    ; --- Configure BGA mode ---
    mov cx, BGA_REG_ENABLE
    xor dx, dx                  ; BGA_DISABLED
    call hw_bga_write
    mov cx, BGA_REG_XRES
    mov dx, FB_WIDTH
    call hw_bga_write
    mov cx, BGA_REG_YRES
    mov dx, FB_HEIGHT
    call hw_bga_write
    mov cx, BGA_REG_BPP
    mov dx, FB_BPP
    call hw_bga_write
    mov cx, BGA_REG_VIRT_WIDTH
    mov dx, FB_WIDTH
    call hw_bga_write
    mov cx, BGA_REG_VIRT_HEIGHT
    mov dx, FB_HEIGHT
    call hw_bga_write
    mov cx, BGA_REG_X_OFFSET
    xor dx, dx
    call hw_bga_write
    mov cx, BGA_REG_Y_OFFSET
    xor dx, dx
    call hw_bga_write
    mov cx, BGA_REG_ENABLE
    mov dx, BGA_ENABLED | BGA_LFB_ENABLED
    call hw_bga_write

    ; --- Set up framebuffer state ---
    mov [rel fb_ptr], rdi       ; fb_ptr = bar0
    mov rax, BACKBUF_ADDR
    mov [rel fb_back], rax      ; fb_back = 0x500000
    mov dword [rel fb_w], FB_WIDTH
    mov dword [rel fb_h], FB_HEIGHT
    mov dword [rel fb_active], 1

    xor eax, eax                ; return 0 (success)
    jmp .fbi_done

.fbi_map_fail:
    mov eax, -2
    jmp .fbi_done
.fbi_bga_fail:
    mov eax, -3
.fbi_done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; void fb_pixel(int x, int y, uint32_t color)
; MS x64: ECX=x, EDX=y, R8D=color. Set single pixel in back buffer.
fb_pixel:
    test ecx, ecx
    js .fbpx_done               ; x < 0
    cmp ecx, FB_WIDTH
    jge .fbpx_done              ; x >= 800
    test edx, edx
    js .fbpx_done               ; y < 0
    cmp edx, FB_HEIGHT
    jge .fbpx_done              ; y >= 600
    imul eax, edx, FB_WIDTH     ; y * 800
    add eax, ecx               ; + x
    mov rdx, [rel fb_back]
    mov [rdx + rax*4], r8d
.fbpx_done:
    ret

; void fb_clear(uint32_t color)
; MS x64: ECX = color. Fill entire back buffer.
fb_clear:
    push rdi
    mov eax, ecx                ; color
    mov rdi, [rel fb_back]      ; destination
    mov ecx, FB_PIXELS          ; 480000 dwords
    rep stosd
    pop rdi
    ret

; void fb_fill_rect(int x, int y, int w, int h, uint32_t color)
; MS x64: ECX=x, EDX=y, R8D=w, R9D=h, 5th=[rbp+48]=color
; Clips to screen bounds, fills rectangle in back buffer.
fb_fill_rect:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    ; 7 pushes total (incl rbp). At entry RSP%16=8.
    ; 7*8=56. (8+56)%16=(64)%16=0. No sub needed. ✓
    ; (No function calls from this function.)

    ; Clip x0 = max(x, 0)
    mov eax, ecx
    test eax, eax
    cmovs eax, r15d             ; Hmm, r15d not set. Use conditional:
    xor ebx, ebx
    test ecx, ecx
    cmovns ebx, ecx             ; ebx = x >= 0 ? x : 0

    ; Clip y0 = max(y, 0)
    xor esi, esi
    test edx, edx
    cmovns esi, edx             ; esi = y >= 0 ? y : 0

    ; Clip x1 = min(x + w, FB_WIDTH)
    mov eax, ecx
    add eax, r8d                ; x + w
    cmp eax, FB_WIDTH
    mov edi, FB_WIDTH
    cmovl edi, eax              ; edi = min(x+w, 800)

    ; Clip y1 = min(y + h, FB_HEIGHT)
    mov eax, edx
    add eax, r9d                ; y + h
    cmp eax, FB_HEIGHT
    mov r12d, FB_HEIGHT
    cmovl r12d, eax             ; r12d = min(y+h, 600)

    ; Intersect with clip rect if enabled
    cmp dword [rel wm_clip_enabled], 0
    je .ffr_no_clip
    ; x0 = max(x0, clip_x)
    mov eax, [rel wm_clip_x]
    cmp ebx, eax
    cmovl ebx, eax
    ; y0 = max(y0, clip_y)
    mov eax, [rel wm_clip_y]
    cmp esi, eax
    cmovl esi, eax
    ; x1 = min(x1, clip_x + clip_w)
    mov eax, [rel wm_clip_x]
    add eax, [rel wm_clip_w]
    cmp edi, eax
    cmovg edi, eax
    ; y1 = min(y1, clip_y + clip_h)
    mov eax, [rel wm_clip_y]
    add eax, [rel wm_clip_h]
    cmp r12d, eax
    cmovg r12d, eax
.ffr_no_clip:

    ; color = 5th arg
    mov r13d, [rbp + 48]

    ; Get fb_back pointer
    mov r14, [rel fb_back]

    ; Check if any area to fill
    cmp ebx, edi
    jge .ffr_done
    cmp esi, r12d
    jge .ffr_done

    ; Outer loop: py = y0..y1-1
    mov edx, esi                ; py = y0
.ffr_row_loop:
    cmp edx, r12d
    jge .ffr_done
    ; row_ptr = fb_back + py * FB_WIDTH
    imul eax, edx, FB_WIDTH
    lea rax, [r14 + rax*4]      ; row pointer
    ; Inner loop: px = x0..x1-1
    mov ecx, ebx                ; px = x0
.ffr_col_loop:
    cmp ecx, edi
    jge .ffr_next_row
    mov [rax + rcx*4], r13d     ; row[px] = color
    inc ecx
    jmp .ffr_col_loop
.ffr_next_row:
    inc edx
    jmp .ffr_row_loop
.ffr_done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; void fb_draw_rect(int x, int y, int w, int h, uint32_t color)
; MS x64: ECX=x, EDX=y, R8D=w, R9D=h, 5th=[rbp+48]=color
; Draw 1px rectangle outline via fb_pixel calls.
fb_draw_rect:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 40                 ; shadow(32) + 8(align)
    ; 6 pushes + sub 40 = 48+40 = 88. (8+88)%16 = 96%16 = 0. ✓

    mov ebx, ecx                ; x
    mov esi, edx                ; y
    lea edi, [ecx + r8d]        ; x + w (exclusive end)
    lea r12d, [edx + r9d]       ; y + h (exclusive end)
    mov r13d, [rbp + 48]        ; color

    ; --- Top edge: fb_pixel(px, y, color) for px = x..x+w-1 ---
    mov [rsp + 32], ebx         ; px = x
.fdr_top:
    mov ecx, [rsp + 32]
    cmp ecx, edi
    jge .fdr_bot_start
    mov edx, esi                ; y
    mov r8d, r13d               ; color
    call fb_pixel
    inc dword [rsp + 32]
    jmp .fdr_top

.fdr_bot_start:
    ; --- Bottom edge: fb_pixel(px, y+h-1, color) ---
    mov [rsp + 32], ebx         ; px = x
    lea eax, [r12d - 1]         ; y + h - 1
    mov [rsp + 36], eax         ; y_bot
.fdr_bot:
    mov ecx, [rsp + 32]
    cmp ecx, edi
    jge .fdr_left_start
    mov edx, [rsp + 36]         ; y_bot
    mov r8d, r13d
    call fb_pixel
    inc dword [rsp + 32]
    jmp .fdr_bot

.fdr_left_start:
    ; --- Left edge: fb_pixel(x, py, color) for py = y..y+h-1 ---
    mov [rsp + 32], esi         ; py = y
.fdr_left:
    mov edx, [rsp + 32]
    cmp edx, r12d
    jge .fdr_right_start
    mov ecx, ebx                ; x
    mov r8d, r13d
    call fb_pixel
    inc dword [rsp + 32]
    jmp .fdr_left

.fdr_right_start:
    ; --- Right edge: fb_pixel(x+w-1, py, color) ---
    lea eax, [edi - 1]          ; x + w - 1
    mov [rsp + 36], eax         ; x_right
    mov [rsp + 32], esi         ; py = y
.fdr_right:
    mov edx, [rsp + 32]
    cmp edx, r12d
    jge .fdr_done
    mov ecx, [rsp + 36]         ; x_right
    mov r8d, r13d
    call fb_pixel
    inc dword [rsp + 32]
    jmp .fdr_right

.fdr_done:
    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; void fb_draw_rect2(int x, int y, int w, int h, uint32_t color)
; MS x64: ECX=x, EDX=y, R8D=w, R9D=h, 5th=[rbp+48]=color
; Draw 2px rectangle outline (outer + inner).
fb_draw_rect2:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 40
    ; Same alignment as fb_draw_rect ✓

    mov ebx, ecx                ; x
    mov esi, edx                ; y
    mov edi, r8d                ; w
    mov r12d, r9d               ; h
    mov r13d, [rbp + 48]        ; color

    ; fb_draw_rect(x, y, w, h, color)
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    mov r9d, r12d
    mov [rsp + 32], r13d        ; 5th arg
    call fb_draw_rect

    ; fb_draw_rect(x+1, y+1, w-2, h-2, color)
    lea ecx, [ebx + 1]
    lea edx, [esi + 1]
    lea r8d, [edi - 2]
    lea r9d, [r12d - 2]
    mov [rsp + 32], r13d        ; 5th arg
    call fb_draw_rect

    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; void fb_hline(int x, int y, int w, uint32_t color)
; MS x64: ECX=x, EDX=y, R8D=w, R9D=color
; Draw horizontal line via fb_pixel calls.
fb_hline:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40                 ; shadow(32) + 8(align)
    ; 4 pushes + sub 40 = 32+40 = 72. (8+72)%16 = 80%16 = 0. ✓

    mov ebx, ecx                ; x (loop counter start)
    mov esi, edx                ; y
    lea edi, [ecx + r8d]        ; x + w (loop end)
    mov r12d, r9d               ; color

.fbhl_loop:
    cmp ebx, edi
    jge .fbhl_done
    mov ecx, ebx                ; x + i
    mov edx, esi                ; y
    mov r8d, r12d               ; color
    call fb_pixel
    inc ebx
    jmp .fbhl_loop
.fbhl_done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; void fb_flip(void)
; Copy back buffer (cached RAM) to MMIO framebuffer (uncached).
; 480,000 dwords via rep movsd.
fb_flip:
    mov eax, [rel fb_active]
    test eax, eax
    jz .fbfl_done
    push rsi
    push rdi
    ; 2 pushes. No calls, so alignment doesn't matter.
    mov rdi, [rel fb_ptr]       ; dst = MMIO framebuffer
    mov rsi, [rel fb_back]      ; src = back buffer
    mov ecx, FB_PIXELS          ; 480000 dwords
    cld                         ; ensure forward direction
    rep movsd
    pop rdi
    pop rsi
.fbfl_done:
    ret

; ============================================================
; FRAMEBUFFER TEXT + WIDGETS + CURSOR — Tier 7 (Phase D Step 3)
;
; Ported from framebuffer.h. Text rendering with 8x16 bitmap font,
; widget drawing (containers, processes, resources), mouse cursor.
; ============================================================

FONT_WIDTH   equ 8
FONT_HEIGHT  equ 16
CURSOR_W     equ 10
CURSOR_H     equ 14

; Color constants used by widgets
COL_TEXT_HI  equ 0x00FFFFFF
COL_TEXT_DIM equ 0x00888888
COL_TEXT_VAL equ 0x0066CCFF
COL_RES_FREE equ 0x00338855
COL_RES_USED equ 0x00CC4444
COL_RES_FD_F equ 0x00335588
COL_RES_FD_U equ 0x00CC8844
COL_CURSOR_FG equ 0x00FFFFFF
COL_CURSOR_BG equ 0x00000000

; void fb_draw_char(int x, int y, char ch, uint32_t fg, uint32_t bg)
; MS x64: ECX=x, EDX=y, R8D=ch, R9D=fg, [rbp+48]=bg
; Draw 8x16 character from bitmap font. bg=0 means transparent.
fb_draw_char:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40                 ; shadow(32) + 8(align)
    ; 8 pushes(incl rbp) + sub 40. Total adjust = 64+40 = 104. 104%16=8. ✓

    mov ebx, ecx                ; x
    mov esi, edx                ; y
    movzx edi, r8b              ; ch (unsigned char index)
    mov r12d, r9d               ; fg
    mov r13d, [rbp + 48]        ; bg (5th arg)

    ; Coarse clip reject: if char bbox fully outside clip rect, skip
    cmp dword [rel wm_clip_enabled], 0
    je .fdc_clip_ok
    ; Check: x + 8 <= clip_x  →  fully left
    lea eax, [ebx + FONT_WIDTH]
    cmp eax, [rel wm_clip_x]
    jle .fdc_done
    ; Check: x >= clip_x + clip_w  →  fully right
    mov eax, [rel wm_clip_x]
    add eax, [rel wm_clip_w]
    cmp ebx, eax
    jge .fdc_done
    ; Check: y + 16 <= clip_y  →  fully above
    lea eax, [esi + FONT_HEIGHT]
    cmp eax, [rel wm_clip_y]
    jle .fdc_done
    ; Check: y >= clip_y + clip_h  →  fully below
    mov eax, [rel wm_clip_y]
    add eax, [rel wm_clip_h]
    cmp esi, eax
    jge .fdc_done
.fdc_clip_ok:

    ; Glyph pointer: font_8x16 + ch * 16
    shl edi, 4                  ; ch * 16
    lea r14, [rel font_8x16]
    add r14, rdi                ; r14 = glyph base

    ; Outer loop: row = 0..15
    xor r15d, r15d              ; row = 0
.fdc_row:
    cmp r15d, FONT_HEIGHT
    jge .fdc_done
    ; Per-row clip: skip if y+row outside clip rect
    cmp dword [rel wm_clip_enabled], 0
    je .fdc_row_ok
    lea eax, [esi + r15d]      ; y + row
    cmp eax, [rel wm_clip_y]
    jl .fdc_next_row
    mov ecx, [rel wm_clip_y]
    add ecx, [rel wm_clip_h]
    cmp eax, ecx
    jge .fdc_done               ; all remaining rows are outside
.fdc_row_ok:
    movzx edi, byte [r14 + r15] ; bits = glyph[row]
    ; Inner loop: col = 0..7
    mov dword [rsp + 32], 0     ; col = 0
.fdc_col:
    mov ecx, [rsp + 32]
    cmp ecx, FONT_WIDTH
    jge .fdc_next_row
    ; Per-col clip: skip if x+col outside clip rect
    cmp dword [rel wm_clip_enabled], 0
    je .fdc_col_ok
    lea eax, [ebx + ecx]       ; x + col
    cmp eax, [rel wm_clip_x]
    jl .fdc_skip
    mov eax, [rel wm_clip_x]
    add eax, [rel wm_clip_w]
    lea ecx, [ebx]
    add ecx, [rsp + 32]
    cmp ecx, eax
    jge .fdc_skip
    mov ecx, [rsp + 32]        ; restore col
.fdc_col_ok:
    ; Test bit: bits & (0x80 >> col)
    mov eax, 0x80
    mov cl, [rsp + 32]         ; col into CL for shift
    shr eax, cl                 ; mask = 0x80 >> col
    test edi, eax               ; bits & mask
    jnz .fdc_fg
    ; Background pixel
    test r13d, r13d
    jz .fdc_skip                ; bg=0 → transparent
    mov ecx, [rsp + 32]
    lea ecx, [ebx + ecx]       ; x + col
    lea edx, [esi + r15d]      ; y + row
    mov r8d, r13d               ; bg
    call fb_pixel
    jmp .fdc_skip
.fdc_fg:
    mov ecx, [rsp + 32]
    lea ecx, [ebx + ecx]       ; x + col
    lea edx, [esi + r15d]      ; y + row
    mov r8d, r12d               ; fg
    call fb_pixel
.fdc_skip:
    inc dword [rsp + 32]        ; col++
    jmp .fdc_col
.fdc_next_row:
    inc r15d
    jmp .fdc_row
.fdc_done:
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

; int fb_draw_string(int x, int y, const char* s, uint32_t fg, uint32_t bg)
; MS x64: ECX=x, EDX=y, R8=s, R9D=fg, [rbp+48]=bg
; Returns final X position in EAX.
fb_draw_string:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 40                 ; shadow(32) + 8(5th arg slot)
    ; 6 pushes + sub 40 = 48+40 = 88. 88%16=8. ✓

    mov ebx, ecx                ; x (advances per char)
    mov esi, edx                ; y
    mov rdi, r8                 ; s (string pointer)
    mov r12d, r9d               ; fg
    mov r13d, [rbp + 48]        ; bg

.fds_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .fds_done
    ; fb_draw_char(x, y, ch, fg, bg)
    mov ecx, ebx                ; x
    mov edx, esi                ; y
    mov r8d, eax                ; ch
    mov r9d, r12d               ; fg
    mov [rsp + 32], r13d        ; bg (5th arg)
    call fb_draw_char
    add ebx, FONT_WIDTH         ; x += 8
    inc rdi
    jmp .fds_loop
.fds_done:
    mov eax, ebx                ; return final x
    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; int fb_draw_int(int x, int y, int val, uint32_t fg, uint32_t bg)
; MS x64: ECX=x, EDX=y, R8D=val, R9D=fg, [rbp+48]=bg
; Returns final X position in EAX.
fb_draw_int:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 56                 ; shadow(32) + buf[16] + 8(5th arg)
    ; 6 pushes(incl rbp) + sub 56 = 48+56 = 104. 104%16=8. ✓

    mov ebx, ecx                ; x
    mov esi, edx                ; y
    mov edi, r8d                ; val (save before R8 clobbered)
    mov r12d, r9d               ; fg
    mov r13d, [rbp + 48]        ; bg

    ; herb_snprintf(buf, 16, "%d", val)
    lea rcx, [rsp + 40]         ; buf at [rsp+40..55]
    mov edx, 16
    lea r8, [rel hw_fmt_d]      ; "%d"
    mov r9d, edi                ; val
    call herb_snprintf

    ; fb_draw_string(x, y, buf, fg, bg)
    mov ecx, ebx                ; x
    mov edx, esi                ; y
    lea r8, [rsp + 40]          ; buf
    mov r9d, r12d               ; fg
    mov dword [rsp + 32], r13d  ; bg (5th arg)
    call fb_draw_string
    ; eax = final x from fb_draw_string

    add rsp, 56
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; int fb_draw_padded(int x, int y, const char* s, int width, uint32_t fg, uint32_t bg)
; MS x64: ECX=x, EDX=y, R8=s, R9D=width, [rbp+48]=fg, [rbp+56]=bg
; Returns x + width * FONT_WIDTH.
fb_draw_padded:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40                 ; shadow(32) + 8(5th arg)
    ; 8 pushes(incl rbp) + sub 40 = 64+40 = 104. 104%16=8. ✓

    mov ebx, ecx                ; x
    mov esi, edx                ; y
    mov rdi, r8                 ; s
    mov r12d, r9d               ; width
    mov r13d, [rbp + 48]        ; fg (5th arg)
    mov r14d, [rbp + 56]        ; bg (6th arg)
    xor r15d, r15d              ; i = 0

    ; Phase 1: draw string chars while s[i] && i < width
.fdp_str:
    cmp r15d, r12d
    jge .fdp_pad
    movzx eax, byte [rdi + r15]
    test al, al
    jz .fdp_pad
    ; fb_draw_char(x + i * FONT_WIDTH, y, s[i], fg, bg)
    imul ecx, r15d, FONT_WIDTH
    add ecx, ebx                ; x + i*8
    mov edx, esi                ; y
    mov r8d, eax                ; ch
    mov r9d, r13d               ; fg
    mov dword [rsp + 32], r14d  ; bg (5th arg)
    call fb_draw_char
    inc r15d
    jmp .fdp_str

    ; Phase 2: pad remaining with spaces
.fdp_pad:
    cmp r15d, r12d
    jge .fdp_done
    imul ecx, r15d, FONT_WIDTH
    add ecx, ebx                ; x + i*8
    mov edx, esi                ; y
    mov r8d, ' '                ; space
    mov r9d, r13d               ; fg
    mov dword [rsp + 32], r14d  ; bg (5th arg)
    call fb_draw_char
    inc r15d
    jmp .fdp_pad

.fdp_done:
    ; return x + width * FONT_WIDTH
    imul eax, r12d, FONT_WIDTH
    add eax, ebx
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

; void fb_draw_container(int x, int y, int w, int h,
;                        const char* title, uint32_t border_color, uint32_t fill_color)
; MS x64: ECX=x, EDX=y, R8D=w, R9D=h
;         [rbp+48]=title, [rbp+56]=border_color, [rbp+64]=fill_color
fb_draw_container:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40                 ; shadow(32) + 8(5th arg)
    ; 8 pushes + sub 40 = 104. 104%16=8. ✓

    mov ebx, ecx                ; x
    mov esi, edx                ; y
    mov edi, r8d                ; w
    mov r12d, r9d               ; h
    mov r13, [rbp + 48]         ; title (pointer)
    mov r14d, [rbp + 56]        ; border_color
    mov r15d, [rbp + 64]        ; fill_color

    ; fb_fill_rect(x, y, w, h, fill_color)
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    mov r9d, r12d
    mov dword [rsp + 32], r15d
    call fb_fill_rect

    ; fb_draw_rect2(x, y, w, h, border_color)
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    mov r9d, r12d
    mov dword [rsp + 32], r14d
    call fb_draw_rect2

    ; fb_fill_rect(x+2, y+2, w-4, 18, border_color)
    lea ecx, [ebx + 2]
    lea edx, [esi + 2]
    lea r8d, [edi - 4]
    mov r9d, 18
    mov dword [rsp + 32], r14d
    call fb_fill_rect

    ; fb_draw_string(x+6, y+3, title, COL_TEXT_HI, border_color)
    lea ecx, [ebx + 6]
    lea edx, [esi + 3]
    mov r8, r13                 ; title
    mov r9d, COL_TEXT_HI
    mov dword [rsp + 32], r14d  ; border_color as bg
    call fb_draw_string

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

; int fb_draw_process(int x, int y, int w, int h,
;                     const char* name, int priority, int time_slice,
;                     uint32_t border_color, uint32_t fill_color)
; MS x64: ECX=x, EDX=y, R8D=w, R9D=h
;   [rbp+48]=name, [rbp+56]=priority, [rbp+64]=time_slice
;   [rbp+72]=border_color, [rbp+80]=fill_color
; Returns h.
fb_draw_process:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40                 ; shadow(32) + 8(5th arg)
    ; 8 pushes + sub 40 = 104. 104%16=8. ✓

    mov ebx, ecx                ; x
    mov esi, edx                ; y
    mov edi, r8d                ; w
    mov r12d, r9d               ; h
    mov r13, [rbp + 48]         ; name (pointer)
    mov r14d, [rbp + 72]        ; border_color
    mov r15d, [rbp + 80]        ; fill_color

    ; fb_fill_rect(x, y, w, h, fill_color)
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    mov r9d, r12d
    mov dword [rsp + 32], r15d
    call fb_fill_rect

    ; fb_draw_rect(x, y, w, h, border_color)
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    mov r9d, r12d
    mov dword [rsp + 32], r14d
    call fb_draw_rect

    ; fb_draw_string(x+4, y+3, name, COL_TEXT_HI, 0)
    lea ecx, [ebx + 4]
    lea edx, [esi + 3]
    mov r8, r13                 ; name
    mov r9d, COL_TEXT_HI
    mov dword [rsp + 32], 0     ; transparent bg
    call fb_draw_string

    ; int tx = fb_draw_string(x+4, y+19, "p=", COL_TEXT_DIM, 0)
    lea ecx, [ebx + 4]
    lea edx, [esi + 19]
    lea r8, [rel hw_str_p_eq]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], 0
    call fb_draw_string
    ; eax = tx

    ; Save tx, we need it for subsequent calls
    ; Use stack-local approach: store priority and time_slice
    mov ecx, eax                ; tx
    lea edx, [esi + 19]         ; y + 19
    mov r8d, [rbp + 56]         ; priority (val)
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], 0
    call fb_draw_int
    ; eax = new tx

    ; tx = fb_draw_string(tx+4, y+19, "ts=", COL_TEXT_DIM, 0)
    lea ecx, [eax + 4]
    lea edx, [esi + 19]
    lea r8, [rel hw_str_ts_eq]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], 0
    call fb_draw_string

    ; fb_draw_int(tx, y+19, time_slice, COL_TEXT_VAL, 0)
    mov ecx, eax                ; tx
    lea edx, [esi + 19]
    mov r8d, [rbp + 64]         ; time_slice
    mov r9d, COL_TEXT_VAL
    mov dword [rsp + 32], 0
    call fb_draw_int

    ; return h
    mov eax, r12d
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

; void fb_draw_resources(int x, int y, int mem_free, int mem_used,
;                        int fd_free, int fd_open)
; MS x64: ECX=x, EDX=y, R8D=mem_free, R9D=mem_used
;         [rbp+48]=fd_free, [rbp+56]=fd_open
fb_draw_resources:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40                 ; shadow(32) + 8(5th arg)
    ; 8 pushes + sub 40 = 104. 104%16=8. ✓

    mov ebx, ecx                ; sx = x
    mov esi, edx                ; y
    mov edi, r8d                ; mem_free
    mov r12d, r9d               ; mem_used
    mov r13d, [rbp + 48]        ; fd_free
    mov r14d, [rbp + 56]        ; fd_open

    ; fb_draw_string(sx, y, "M", COL_TEXT_DIM, 0)
    mov ecx, ebx
    mov edx, esi
    lea r8, [rel hw_str_M]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], 0
    call fb_draw_string
    add ebx, 10                 ; sx += 10

    ; Free pages (green squares): sq=6, gap=2
    xor r15d, r15d              ; i = 0
.fdr_mem_free:
    cmp r15d, edi
    jge .fdr_mem_used_start
    cmp r15d, 8
    jge .fdr_mem_used_start
    ; fb_fill_rect(sx, y+2, 6, 6, COL_RES_FREE)
    mov ecx, ebx
    lea edx, [esi + 2]
    mov r8d, 6
    mov r9d, 6
    mov dword [rsp + 32], COL_RES_FREE
    call fb_fill_rect
    add ebx, 8                  ; sx += sq + gap (6+2)
    inc r15d
    jmp .fdr_mem_free

.fdr_mem_used_start:
    ; Used pages (red squares)
    xor r15d, r15d
.fdr_mem_used:
    cmp r15d, r12d
    jge .fdr_fd_label
    cmp r15d, 8
    jge .fdr_fd_label
    mov ecx, ebx
    lea edx, [esi + 2]
    mov r8d, 6
    mov r9d, 6
    mov dword [rsp + 32], COL_RES_USED
    call fb_fill_rect
    add ebx, 8
    inc r15d
    jmp .fdr_mem_used

.fdr_fd_label:
    add ebx, 6                  ; sx += 6
    ; fb_draw_string(sx, y, "F", COL_TEXT_DIM, 0)
    mov ecx, ebx
    mov edx, esi
    lea r8, [rel hw_str_F]
    mov r9d, COL_TEXT_DIM
    mov dword [rsp + 32], 0
    call fb_draw_string
    add ebx, 10                 ; sx += 10

    ; Free FDs (blue squares)
    xor r15d, r15d
.fdr_fd_free:
    cmp r15d, r13d
    jge .fdr_fd_open_start
    cmp r15d, 8
    jge .fdr_fd_open_start
    mov ecx, ebx
    lea edx, [esi + 2]
    mov r8d, 6
    mov r9d, 6
    mov dword [rsp + 32], COL_RES_FD_F
    call fb_fill_rect
    add ebx, 8
    inc r15d
    jmp .fdr_fd_free

.fdr_fd_open_start:
    ; Open FDs (orange squares)
    xor r15d, r15d
.fdr_fd_open:
    cmp r15d, r14d
    jge .fdr_done
    cmp r15d, 8
    jge .fdr_done
    mov ecx, ebx
    lea edx, [esi + 2]
    mov r8d, 6
    mov r9d, 6
    mov dword [rsp + 32], COL_RES_FD_U
    call fb_fill_rect
    add ebx, 8
    inc r15d
    jmp .fdr_fd_open

.fdr_done:
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

; void fb_cursor_erase(void)
; Restore area under old cursor from back buffer to MMIO framebuffer.
fb_cursor_erase:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8                  ; align only
    ; 8 pushes + sub 8 = 64+8 = 72. 72%16=8. ✓

    ; if (!fb_active) return
    cmp dword [rel fb_active], 0
    je .fce_done

    ; x0 = cursor_old_x - 1, y0 = cursor_old_y - 1
    mov ebx, [rel cursor_old_x]
    dec ebx                     ; x0
    mov esi, [rel cursor_old_y]
    dec esi                     ; y0

    ; x1 = x0 + CURSOR_W + 2 = x0 + 12
    lea edi, [ebx + CURSOR_W + 2]
    ; y1 = y0 + CURSOR_H + 2 = y0 + 16
    lea r12d, [esi + CURSOR_H + 2]

    ; Clamp
    test ebx, ebx
    jns .fce_x0ok
    xor ebx, ebx
.fce_x0ok:
    test esi, esi
    jns .fce_y0ok
    xor esi, esi
.fce_y0ok:
    cmp edi, [rel fb_w]
    jle .fce_x1ok
    mov edi, [rel fb_w]
.fce_x1ok:
    cmp r12d, [rel fb_h]
    jle .fce_y1ok
    mov r12d, [rel fb_h]
.fce_y1ok:

    ; Load fb_ptr and fb_back
    mov r13, [rel fb_ptr]       ; MMIO framebuffer
    mov r14, [rel fb_back]      ; back buffer
    mov r15d, [rel fb_w]        ; width for offset calc

    ; for py = y0..y1-1
    mov ecx, esi                ; py = y0
.fce_row:
    cmp ecx, r12d
    jge .fce_done
    ; for px = x0..x1-1
    mov edx, ebx                ; px = x0
.fce_col:
    cmp edx, edi
    jge .fce_next_row
    ; offset = py * fb_w + px
    mov eax, ecx
    imul eax, r15d              ; py * fb_w
    add eax, edx                ; + px (ecx/edx not clobbered by 2-op imul)
    ; fb_ptr[offset] = fb_back[offset]
    mov r8d, [r14 + rax*4]      ; read from back buffer
    mov [r13 + rax*4], r8d      ; write to MMIO
    inc edx
    jmp .fce_col
.fce_next_row:
    inc ecx
    jmp .fce_row

.fce_done:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; void fb_cursor_draw(void)
; Draw cursor directly to MMIO framebuffer (not back buffer).
fb_cursor_draw:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8                  ; align
    ; 8 pushes + sub 8 = 72. 72%16=8. ✓

    ; if (!fb_active) return
    cmp dword [rel fb_active], 0
    je .fcd_done

    mov r13, [rel fb_ptr]       ; MMIO framebuffer
    mov r14d, [rel fb_w]        ; screen width
    mov r15d, [rel fb_h]        ; screen height

    ; --- Draw shadow first (1px offset) ---
    xor ebx, ebx                ; row = 0
.fcd_shadow_row:
    cmp ebx, CURSOR_H
    jge .fcd_fg_start
    lea rax, [rel cursor_shadow]
    movzx esi, word [rax + rbx*2] ; bits = cursor_shadow[row]
    xor edi, edi                ; col = 0
.fcd_shadow_col:
    cmp edi, CURSOR_W
    jge .fcd_shadow_next_row
    ; test bits & (0x8000 >> col)
    mov eax, 0x8000
    mov ecx, edi
    shr eax, cl
    test esi, eax
    jz .fcd_shadow_skip
    ; px = cursor_x + col + 1, py = cursor_y + row + 1
    mov r8d, [rel cursor_x]
    add r8d, edi
    inc r8d                     ; +1 for shadow
    mov r9d, [rel cursor_y]
    add r9d, ebx
    inc r9d                     ; +1 for shadow
    ; bounds check
    test r8d, r8d
    js .fcd_shadow_skip
    cmp r8d, r14d
    jge .fcd_shadow_skip
    test r9d, r9d
    js .fcd_shadow_skip
    cmp r9d, r15d
    jge .fcd_shadow_skip
    ; fb_ptr[py * fb_w + px] = COL_CURSOR_BG (0)
    mov eax, r9d
    imul eax, r14d
    add eax, r8d
    mov dword [r13 + rax*4], COL_CURSOR_BG
.fcd_shadow_skip:
    inc edi
    jmp .fcd_shadow_col
.fcd_shadow_next_row:
    inc ebx
    jmp .fcd_shadow_row

.fcd_fg_start:
    ; --- Draw foreground ---
    xor ebx, ebx                ; row = 0
.fcd_fg_row:
    cmp ebx, CURSOR_H
    jge .fcd_update
    lea rax, [rel cursor_shape]
    movzx esi, word [rax + rbx*2] ; bits = cursor_shape[row]
    xor edi, edi                ; col = 0
.fcd_fg_col:
    cmp edi, CURSOR_W
    jge .fcd_fg_next_row
    mov eax, 0x8000
    mov ecx, edi
    shr eax, cl
    test esi, eax
    jz .fcd_fg_skip
    ; px = cursor_x + col, py = cursor_y + row
    mov r8d, [rel cursor_x]
    add r8d, edi
    mov r9d, [rel cursor_y]
    add r9d, ebx
    ; bounds check
    test r8d, r8d
    js .fcd_fg_skip
    cmp r8d, r14d
    jge .fcd_fg_skip
    test r9d, r9d
    js .fcd_fg_skip
    cmp r9d, r15d
    jge .fcd_fg_skip
    ; fb_ptr[py * fb_w + px] = COL_CURSOR_FG (0x00FFFFFF)
    mov eax, r9d
    imul eax, r14d
    add eax, r8d
    mov dword [r13 + rax*4], COL_CURSOR_FG
.fcd_fg_skip:
    inc edi
    jmp .fcd_fg_col
.fcd_fg_next_row:
    inc ebx
    jmp .fcd_fg_row

.fcd_update:
    ; cursor_old_x = cursor_x, cursor_old_y = cursor_y
    mov eax, [rel cursor_x]
    mov [rel cursor_old_x], eax
    mov eax, [rel cursor_y]
    mov [rel cursor_old_y], eax

.fcd_done:
    add rsp, 8
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
; CLIP RECTANGLE
; ============================================================

; void wm_set_clip(int x, int y, int w, int h)
; MS x64: ECX=x, EDX=y, R8D=w, R9D=h
wm_set_clip:
    mov [rel wm_clip_x], ecx
    mov [rel wm_clip_y], edx
    mov [rel wm_clip_w], r8d
    mov [rel wm_clip_h], r9d
    mov dword [rel wm_clip_enabled], 1
    ret

; void wm_clear_clip(void)
wm_clear_clip:
    mov dword [rel wm_clip_enabled], 0
    ret

; ============================================================
; DATA SECTIONS
; ============================================================

section .data

vga_color: db 0x0F              ; current VGA color attribute (white on black)

; Cursor initial positions (Phase D Step 3)
cursor_x:     dd 400
cursor_y:     dd 300
cursor_old_x: dd 400
cursor_old_y: dd 300

section .bss

vga_row: resd 1
vga_col: resd 1

; Framebuffer state (Phase D Step 2)
fb_ptr:    resq 1
fb_back:   resq 1
fb_w:      resd 1
fb_h:      resd 1
fb_active: resd 1

; Clip rectangle (WM integration)
wm_clip_x:       resd 1
wm_clip_y:       resd 1
wm_clip_w:       resd 1
wm_clip_h:       resd 1
wm_clip_enabled: resd 1

section .rdata

hw_fmt_d: db "%d", 0

; Cursor bitmaps (Phase D Step 3)
cursor_shape:
    dw 0x8000, 0xC000, 0xE000, 0xF000, 0xF800, 0xFC00, 0xFE00
    dw 0xFF00, 0xFF80, 0xFE00, 0xEC00, 0xC600, 0x0600, 0x0300
cursor_shadow:
    dw 0x4000, 0x2000, 0x1000, 0x0800, 0x0400, 0x0200, 0x0100
    dw 0x0080, 0x0040, 0x0100, 0x1200, 0x2100, 0x0100, 0x0080

hw_str_M: db "M", 0
hw_str_F: db "F", 0
hw_str_p_eq: db "p=", 0
hw_str_ts_eq: db "ts=", 0

%include "font_data.inc"
