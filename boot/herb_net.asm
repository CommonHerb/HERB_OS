; boot/herb_net.asm — HERB OS E1000 Virtual NIC Driver
;
; Intel E1000 Ethernet driver for QEMU's virtual NIC.
; PCI discovery, MMIO init, TX/RX rings, IRQ handling.
;
; Assembled with: nasm -f win64 herb_net.asm -o herb_net.o

[bits 64]
default rel

; ============================================================
; GLOBALS
; ============================================================
global net_init
global net_send
global net_send_arp_request
global net_poll_rx
global net_present
global net_rx_flag
global net_mac

; ============================================================
; EXTERNS
; ============================================================
extern hw_pci_read          ; herb_hw.asm: (bus=CL, slot=DL, func=R8B, offset=R9B) -> EAX
extern serial_print         ; herb_hw.asm: (RCX=str)
extern herb_snprintf        ; herb_freestanding.asm
extern herb_memset          ; herb_freestanding.asm

; ============================================================
; E1000 REGISTER OFFSETS
; ============================================================
E1000_CTRL      equ 0x0000
E1000_STATUS    equ 0x0008
E1000_ICR       equ 0x00C0  ; Interrupt Cause Read
E1000_IMS       equ 0x00D0  ; Interrupt Mask Set
E1000_IMC       equ 0x00D8  ; Interrupt Mask Clear
E1000_RCTL      equ 0x0100  ; RX Control
E1000_TCTL      equ 0x0400  ; TX Control
E1000_RDBAL     equ 0x2800  ; RX Desc Base Low
E1000_RDBAH     equ 0x2804  ; RX Desc Base High
E1000_RDLEN     equ 0x2808  ; RX Desc Length
E1000_RDH       equ 0x2810  ; RX Desc Head
E1000_RDT       equ 0x2818  ; RX Desc Tail
E1000_TDBAL     equ 0x3800  ; TX Desc Base Low
E1000_TDBAH     equ 0x3804  ; TX Desc Base High
E1000_TDLEN     equ 0x3808  ; TX Desc Length
E1000_TDH       equ 0x3810  ; TX Desc Head
E1000_TDT       equ 0x3818  ; TX Desc Tail
E1000_RAL       equ 0x5400  ; Receive Address Low
E1000_RAH       equ 0x5404  ; Receive Address High

; CTRL bits
CTRL_RST        equ (1 << 26)
CTRL_SLU        equ (1 << 6)   ; Set Link Up

; RCTL bits
RCTL_EN         equ (1 << 1)
RCTL_BAM        equ (1 << 15)  ; Broadcast Accept Mode
; BSIZE bits clear = 2048 byte buffers

; TCTL bits
TCTL_EN         equ (1 << 1)
TCTL_PSP        equ (1 << 3)   ; Pad Short Packets
TCTL_CT_SHIFT   equ 4
TCTL_COLD_SHIFT equ 12

; TX descriptor CMD bits
TXCMD_EOP       equ 0x01       ; End Of Packet
TXCMD_RS        equ 0x08       ; Report Status

; Descriptor status bits
DESC_DD         equ 0x01       ; Descriptor Done

; Ring sizes
RX_DESC_COUNT   equ 32
TX_DESC_COUNT   equ 32
BUF_SIZE        equ 2048

; PCI vendor/device
E1000_VENDOR    equ 0x8086
E1000_DEVICE    equ 0x100E

; ============================================================
; TEXT
; ============================================================
section .text

; ============================================================
; e1000_read(reg=ECX) -> EAX
; MMIO read from E1000 register
; ============================================================
e1000_read:
    mov rax, [rel net_bar0]
    mov eax, dword [rax + rcx]
    ret

; ============================================================
; e1000_write(reg=ECX, val=EDX)
; MMIO write to E1000 register
; ============================================================
e1000_write:
    mov rax, [rel net_bar0]
    mov dword [rax + rcx], edx
    ret

; ============================================================
; net_pci_scan() -> EAX (0=found, -1=not found)
; Scan PCI bus 0, slots 0-31 for E1000
; ============================================================
net_pci_scan:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40                     ; shadow(32) + 8(align)

    xor esi, esi                    ; slot = 0
.scan_loop:
    cmp esi, 32
    jge .not_found

    ; hw_pci_read(bus=0, slot=esi, func=0, offset=0)
    xor ecx, ecx                   ; bus = 0
    mov edx, esi                    ; slot
    xor r8d, r8d                    ; func = 0
    xor r9d, r9d                    ; offset = 0
    call hw_pci_read

    ; Check vendor 0x8086, device 0x100E
    mov ebx, eax
    and ebx, 0xFFFF                 ; vendor
    cmp ebx, E1000_VENDOR
    jne .next_slot
    shr eax, 16                     ; device
    cmp ax, E1000_DEVICE
    jne .next_slot

    ; Found! Read BAR0 (offset 0x10)
    xor ecx, ecx
    mov edx, esi
    xor r8d, r8d
    mov r9d, 0x10
    call hw_pci_read
    and eax, 0xFFFFFFF0             ; mask BAR type bits
    mov [rel net_bar0], rax         ; store (zero-extended to 64-bit)

    ; Read IRQ line (offset 0x3C, low byte)
    xor ecx, ecx
    mov edx, esi
    xor r8d, r8d
    mov r9d, 0x3C
    call hw_pci_read
    and eax, 0xFF
    mov [rel net_irq], eax

    ; Enable PCI bus mastering (offset 0x04, set bit 2)
    xor ecx, ecx
    mov edx, esi
    xor r8d, r8d
    mov r9d, 0x04
    call hw_pci_read
    or eax, (1 << 2)               ; Bus Master Enable
    ; Write back: need to write PCI config space
    ; PCI config write: build address, out to 0xCF8, then write data to 0xCFC
    mov edi, eax                    ; save command value
    ; Build PCI address: (1<<31) | (bus<<16) | (slot<<11) | (func<<8) | (offset & 0xFC)
    mov eax, esi
    shl eax, 11
    or eax, 0x80000004             ; enable + offset 0x04
    mov dx, 0x0CF8
    out dx, eax
    mov eax, edi
    mov dx, 0x0CFC
    out dx, eax

    ; Serial: [NET] E1000 found slot=N BAR0=0xXXXXXXXX IRQ=N
    ; herb_snprintf(buf=RCX, size=EDX, fmt=R8, args=R9+stack)
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel net_fmt_found]
    mov r9d, esi                    ; slot
    ; Push BAR0 and IRQ as stack args
    mov rax, [rel net_bar0]
    mov [rsp+32], rax
    mov eax, [rel net_irq]
    mov [rsp+40], rax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    mov dword [rel net_present], 1
    xor eax, eax                    ; return 0 = found
    jmp .scan_done

.next_slot:
    inc esi
    jmp .scan_loop

.not_found:
    lea rcx, [rel str_net_not_found]
    call serial_print
    mov dword [rel net_present], 0
    mov eax, -1

.scan_done:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; net_map_mmio()
; Map E1000 BAR0 region in page tables (3-4GB range)
; ============================================================
net_map_mmio:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 32                     ; shadow

    mov rdi, [rel net_bar0]

    ; Check range: must be in 3-4GB
    mov rax, 0xC0000000
    cmp rdi, rax
    jb .map_fail
    mov rax, 0x100000000
    cmp rdi, rax
    jae .map_fail

    ; Check if PDPT[3] exists
    mov edx, 0x2000                 ; PDPT base
    mov rax, [rdx + 3*8]
    test rax, rax
    jnz .pdpt3_exists

    ; Create PDPT[3]: zero PD page at 0x4000
    mov edx, 0x4000
    xor eax, eax
    mov ecx, 512
.zero_pd:
    mov qword [rdx], rax
    add rdx, 8
    dec ecx
    jnz .zero_pd
    ; Set PDPT[3] = 0x4003 (present + writable)
    mov edx, 0x2000
    mov qword [rdx + 3*8], 0x4003

.pdpt3_exists:
    ; Calculate PD index: (bar0 - 0xC0000000) >> 21
    mov rax, rdi
    mov rcx, 0xC0000000
    sub rax, rcx
    shr rax, 21
    mov esi, eax                    ; PD index

    ; Write 1 PD entry: bar0_aligned | 0x9B (present+writable+PS/2MB+PCD+PWT)
    mov rax, rdi
    and rax, ~0x1FFFFF              ; align to 2MB
    or rax, 0x9B
    mov edx, 0x4000
    mov [rdx + rsi*8], rax

    ; Flush TLB
    mov rax, cr3
    mov cr3, rax

    lea rcx, [rel str_net_mapped]
    call serial_print

    jmp .map_done

.map_fail:
    lea rcx, [rel str_net_map_fail]
    call serial_print

.map_done:
    add rsp, 32
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; net_e1000_init()
; Reset device, read MAC, setup RX/TX rings, enable interrupts
; ============================================================
net_e1000_init:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48                     ; shadow(32) + 16(args)
    ; Stack: 8(ret)+8(rbp)+4*8(push)+48(sub) = 96. (96-8)%16=88%16=8...
    ; Fix alignment: 8(ret)+8(rbp)+32(push)+48(sub) = 96. 96%16=0 ✓

    ; --- Reset: set CTRL.RST, wait for it to clear ---
    mov ecx, E1000_CTRL
    call e1000_read
    or eax, CTRL_RST
    mov edx, eax
    mov ecx, E1000_CTRL
    call e1000_write

    ; Spin until RST clears (or timeout)
    mov ebx, 100000
.reset_wait:
    dec ebx
    jz .reset_done
    mov ecx, E1000_CTRL
    call e1000_read
    test eax, CTRL_RST
    jnz .reset_wait
.reset_done:

    ; Small delay after reset
    mov ecx, 50000
.post_reset:
    dec ecx
    jnz .post_reset

    ; --- Disable all interrupts ---
    mov ecx, E1000_IMC
    mov edx, 0xFFFFFFFF
    call e1000_write

    ; --- Read MAC from RAL/RAH ---
    mov ecx, E1000_RAL
    call e1000_read
    lea rdi, [rel net_mac]
    mov [rdi], eax                  ; bytes 0-3

    mov ecx, E1000_RAH
    call e1000_read
    mov [rdi + 4], ax               ; bytes 4-5

    ; --- Setup RX descriptors ---
    ; Each RX descriptor is 16 bytes:
    ;   [0..7]  buffer_addr (64-bit physical)
    ;   [8..9]  length
    ;   [10]    checksum
    ;   [11]    status
    ;   [12]    errors
    ;   [13]    special
    ;   [14..15] reserved (VLAN)

    ; Zero all RX descriptors
    lea rcx, [rel net_rx_descs]
    xor edx, edx
    mov r8d, RX_DESC_COUNT * 16
    call herb_memset

    ; Fill each descriptor with buffer pointer
    xor esi, esi                    ; i = 0
.rx_desc_fill:
    cmp esi, RX_DESC_COUNT
    jge .rx_desc_done
    ; buffer_addr = &net_rx_bufs[i * BUF_SIZE]
    lea rax, [rel net_rx_bufs]
    mov ecx, esi
    imul ecx, BUF_SIZE
    add rax, rcx
    ; Write to descriptor[i].buffer_addr
    lea rdi, [rel net_rx_descs]
    mov ecx, esi
    shl ecx, 4                     ; i * 16
    mov [rdi + rcx], rax
    inc esi
    jmp .rx_desc_fill
.rx_desc_done:

    ; Program RX ring registers
    lea rax, [rel net_rx_descs]
    mov edx, eax                    ; low 32 bits
    mov ecx, E1000_RDBAL
    call e1000_write

    lea rax, [rel net_rx_descs]
    shr rax, 32
    mov edx, eax
    mov ecx, E1000_RDBAH
    call e1000_write

    mov ecx, E1000_RDLEN
    mov edx, RX_DESC_COUNT * 16     ; 512
    call e1000_write

    mov ecx, E1000_RDH
    xor edx, edx                   ; head = 0
    call e1000_write

    mov ecx, E1000_RDT
    mov edx, RX_DESC_COUNT - 1      ; tail = 31
    call e1000_write

    ; --- Setup TX descriptors ---
    lea rcx, [rel net_tx_descs]
    xor edx, edx
    mov r8d, TX_DESC_COUNT * 16
    call herb_memset

    ; Program TX ring registers
    lea rax, [rel net_tx_descs]
    mov edx, eax
    mov ecx, E1000_TDBAL
    call e1000_write

    lea rax, [rel net_tx_descs]
    shr rax, 32
    mov edx, eax
    mov ecx, E1000_TDBAH
    call e1000_write

    mov ecx, E1000_TDLEN
    mov edx, TX_DESC_COUNT * 16     ; 512
    call e1000_write

    mov ecx, E1000_TDH
    xor edx, edx
    call e1000_write

    mov ecx, E1000_TDT
    xor edx, edx
    call e1000_write

    ; --- Enable RX: RCTL = EN | BAM | BSIZE_2048 ---
    mov ecx, E1000_RCTL
    mov edx, RCTL_EN | RCTL_BAM     ; BSIZE bits clear = 2048
    call e1000_write

    ; --- Enable TX: TCTL = EN | PSP | CT=0x10 | COLD=0x40 ---
    mov ecx, E1000_TCTL
    mov edx, TCTL_EN | TCTL_PSP | (0x10 << TCTL_CT_SHIFT) | (0x40 << TCTL_COLD_SHIFT)
    call e1000_write

    ; --- Enable RX interrupts: IMS = RXT0 (bit 7) ---
    mov ecx, E1000_IMS
    mov edx, 0x80                   ; RXT0
    call e1000_write

    ; --- Link up: set CTRL.SLU ---
    mov ecx, E1000_CTRL
    call e1000_read
    or eax, CTRL_SLU
    mov edx, eax
    mov ecx, E1000_CTRL
    call e1000_write

    ; --- Print MAC address (byte by byte) ---
    lea rcx, [rel str_net_mac_prefix]
    call serial_print

    ; Print each MAC byte as hex
    lea rsi, [rel net_mac]
    xor ebx, ebx
.mac_print_loop:
    cmp ebx, 6
    jge .mac_print_done
    movzx eax, byte [rsi + rbx]
    ; Format as decimal byte into net_msg_buf
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel net_fmt_byte]
    mov r9d, eax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print
    inc ebx
    cmp ebx, 6
    jge .mac_print_done
    lea rcx, [rel str_colon]
    call serial_print
    jmp .mac_print_loop
.mac_print_done:
    ; Print IRQ and newline
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel net_fmt_irq]
    mov r9d, [rel net_irq]
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; net_init()
; Full initialization: PCI scan + MMIO map + device init
; Called from kernel_main at boot
; ============================================================
net_init:
    push rbp
    mov rbp, rsp
    sub rsp, 32                     ; shadow

    call net_pci_scan
    test eax, eax
    jnz .net_init_done              ; no E1000 found

    call net_map_mmio
    call net_e1000_init

    ; Return IRQ number in EAX for IDT setup
    mov eax, [rel net_irq]

.net_init_done:
    add rsp, 32
    pop rbp
    ret

; ============================================================
; net_send(RCX=buffer, EDX=length) -> EAX (0=ok, -1=fail)
; ============================================================
net_send:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40                     ; shadow(32) + 8(align)

    mov rsi, rcx                    ; source buffer
    mov r12d, edx                   ; length

    ; Validate length
    cmp r12d, BUF_SIZE
    ja .send_fail
    test r12d, r12d
    jz .send_fail

    ; Get current TX tail
    mov ebx, [rel net_tx_tail]

    ; Copy data to TX buffer: net_tx_bufs[tail * BUF_SIZE]
    lea rdi, [rel net_tx_bufs]
    mov eax, ebx
    imul eax, BUF_SIZE
    add rdi, rax                    ; dest = &net_tx_bufs[tail * BUF_SIZE]

    ; Copy r12d bytes from rsi to rdi
    mov ecx, r12d
.copy_loop:
    dec ecx
    js .copy_done
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    jmp .copy_loop
.copy_done:

    ; Fill TX descriptor at net_tx_descs[tail * 16]
    lea rdi, [rel net_tx_descs]
    mov eax, ebx
    shl eax, 4                      ; tail * 16
    add rdi, rax

    ; descriptor.buffer_addr = physical addr of TX buffer
    lea rax, [rel net_tx_bufs]
    mov ecx, ebx
    imul ecx, BUF_SIZE
    add rax, rcx
    mov [rdi], rax                  ; [0..7] buffer addr

    ; descriptor.length = r12d
    mov [rdi + 8], r12w             ; [8..9] length

    ; descriptor.cmd = EOP | RS
    mov byte [rdi + 11], TXCMD_EOP | TXCMD_RS  ; cmd is at offset 11 in legacy desc

    ; descriptor.status = 0
    mov byte [rdi + 12], 0          ; status at offset 12

    ; Advance TDT
    mov eax, ebx
    inc eax
    and eax, (TX_DESC_COUNT - 1)    ; mod 32
    mov [rel net_tx_tail], eax

    ; Write new tail to hardware
    mov edx, eax
    mov ecx, E1000_TDT
    call e1000_write

    ; Spin-wait for DD bit (with timeout)
    mov ecx, 1000000
.wait_dd:
    dec ecx
    jz .send_timeout
    test byte [rdi + 12], DESC_DD   ; check status DD
    jz .wait_dd

    xor eax, eax                    ; success
    jmp .send_done

.send_timeout:
    lea rcx, [rel str_net_tx_timeout]
    call serial_print
.send_fail:
    mov eax, -1

.send_done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; net_send_arp_request()
; Build and send a broadcast ARP "who-has 10.0.2.2"
; ============================================================
net_send_arp_request:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40                     ; shadow(32) + 8(align)

    cmp dword [rel net_present], 0
    je .arp_skip

    ; Build ARP packet in net_arp_buf (42 bytes)
    lea rdi, [rel net_arp_buf]

    ; Ethernet header (14 bytes)
    ; Destination: FF:FF:FF:FF:FF:FF (broadcast)
    mov byte [rdi+0], 0xFF
    mov byte [rdi+1], 0xFF
    mov byte [rdi+2], 0xFF
    mov byte [rdi+3], 0xFF
    mov byte [rdi+4], 0xFF
    mov byte [rdi+5], 0xFF

    ; Source: our MAC
    lea rsi, [rel net_mac]
    mov al, [rsi+0]
    mov [rdi+6], al
    mov al, [rsi+1]
    mov [rdi+7], al
    mov al, [rsi+2]
    mov [rdi+8], al
    mov al, [rsi+3]
    mov [rdi+9], al
    mov al, [rsi+4]
    mov [rdi+10], al
    mov al, [rsi+5]
    mov [rdi+11], al

    ; EtherType: 0x0806 (ARP) — network byte order
    mov byte [rdi+12], 0x08
    mov byte [rdi+13], 0x06

    ; ARP header (28 bytes, starting at offset 14)
    ; HTYPE = 1 (Ethernet), big-endian
    mov byte [rdi+14], 0x00
    mov byte [rdi+15], 0x01
    ; PTYPE = 0x0800 (IPv4), big-endian
    mov byte [rdi+16], 0x08
    mov byte [rdi+17], 0x00
    ; HLEN = 6
    mov byte [rdi+18], 6
    ; PLEN = 4
    mov byte [rdi+19], 4
    ; OPER = 1 (request), big-endian
    mov byte [rdi+20], 0x00
    mov byte [rdi+21], 0x01

    ; Sender MAC (our MAC)
    mov al, [rsi+0]
    mov [rdi+22], al
    mov al, [rsi+1]
    mov [rdi+23], al
    mov al, [rsi+2]
    mov [rdi+24], al
    mov al, [rsi+3]
    mov [rdi+25], al
    mov al, [rsi+4]
    mov [rdi+26], al
    mov al, [rsi+5]
    mov [rdi+27], al

    ; Sender IP: 10.0.2.15
    mov byte [rdi+28], 10
    mov byte [rdi+29], 0
    mov byte [rdi+30], 2
    mov byte [rdi+31], 15

    ; Target MAC: 00:00:00:00:00:00
    xor eax, eax
    mov [rdi+32], al
    mov [rdi+33], al
    mov [rdi+34], al
    mov [rdi+35], al
    mov [rdi+36], al
    mov [rdi+37], al

    ; Target IP: 10.0.2.2
    mov byte [rdi+38], 10
    mov byte [rdi+39], 0
    mov byte [rdi+40], 2
    mov byte [rdi+41], 2

    ; Send it
    lea rcx, [rel net_arp_buf]
    mov edx, 42
    call net_send

    test eax, eax
    jnz .arp_fail

    lea rcx, [rel str_net_arp_sent]
    call serial_print
    jmp .arp_done

.arp_fail:
    lea rcx, [rel str_net_arp_fail]
    call serial_print
    jmp .arp_done

.arp_skip:
    ; NIC not present, silently return
.arp_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret

; ============================================================
; net_poll_rx()
; Called from main loop. Check for received packets.
; ============================================================
net_poll_rx:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 48                     ; shadow(32) + 16(args)

    cmp dword [rel net_present], 0
    je .poll_done

    ; Check flag from ISR
    cmp dword [rel net_rx_flag], 0
    jne .poll_check
    ; Also check DD bit directly (polling fallback)
    mov ebx, [rel net_rx_head]
    lea rdi, [rel net_rx_descs]
    mov eax, ebx
    shl eax, 4
    add rdi, rax
    test byte [rdi + 12], DESC_DD   ; status byte at offset 12
    jz .poll_done
    jmp .poll_process

.poll_check:
    ; Clear flag
    mov dword [rel net_rx_flag], 0

    ; Read ICR to acknowledge interrupt
    mov ecx, E1000_ICR
    call e1000_read

    ; Check RX descriptor
    mov ebx, [rel net_rx_head]
    lea rdi, [rel net_rx_descs]
    mov eax, ebx
    shl eax, 4
    add rdi, rax
    test byte [rdi + 12], DESC_DD
    jz .poll_done

.poll_process:
    ; Read length from descriptor
    movzx esi, word [rdi + 8]       ; length at offset 8

    ; Read ethertype from packet (offset 12-13 in ethernet frame)
    lea rax, [rel net_rx_bufs]
    mov ecx, ebx
    imul ecx, BUF_SIZE
    add rax, rcx
    movzx edx, byte [rax + 12]     ; high byte of ethertype
    shl edx, 8
    movzx ecx, byte [rax + 13]     ; low byte
    or edx, ecx                     ; edx = ethertype

    ; Serial: [NET] RX len=N ethertype=0xNNNN
    ; Compute ethertype first
    lea rax, [rel net_rx_bufs]
    mov ecx, ebx
    imul ecx, BUF_SIZE
    add rax, rcx
    movzx ecx, byte [rax + 12]
    shl ecx, 8
    movzx eax, byte [rax + 13]
    or ecx, eax
    mov [rsp+32], rcx               ; ethertype (stack arg)
    ; herb_snprintf(buf, size, fmt, length, ethertype)
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel net_fmt_rx]
    mov r9d, esi                    ; length
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    ; Clear DD bit
    mov byte [rdi + 12], 0

    ; Reset buffer addr in descriptor (already set, but just in case)
    lea rax, [rel net_rx_bufs]
    mov ecx, ebx
    imul ecx, BUF_SIZE
    add rax, rcx
    mov [rdi], rax

    ; Advance RDT
    mov edx, ebx
    mov ecx, E1000_RDT
    call e1000_write

    ; Advance head
    inc ebx
    and ebx, (RX_DESC_COUNT - 1)
    mov [rel net_rx_head], ebx

.poll_done:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; DATA — strings
; ============================================================
section .data

net_fmt_found:
    db "[NET] E1000 found slot=%d BAR0=%d IRQ=%d", 10, 0
str_net_not_found:
    db "[NET] no E1000 found", 10, 0
str_net_mapped:
    db "[NET] MMIO mapped", 10, 0
str_net_map_fail:
    db "[NET] MMIO map failed (BAR0 out of range)", 10, 0
str_net_mac_prefix:
    db "[NET] MAC=", 0
net_fmt_byte:
    db "%d", 0
str_colon:
    db ":", 0
net_fmt_irq:
    db " IRQ=%d initialized", 10, 0
str_net_tx_timeout:
    db "[NET] TX timeout", 10, 0
str_net_arp_sent:
    db "[NET] ARP request sent for 10.0.2.2", 10, 0
str_net_arp_fail:
    db "[NET] ARP send failed", 10, 0
net_fmt_rx:
    db "[NET] RX len=%d ethertype=%d", 10, 0

; ============================================================
; BSS
; ============================================================
section .bss

align 16
net_rx_descs:   resb RX_DESC_COUNT * 16     ; 512B RX descriptor ring
net_tx_descs:   resb TX_DESC_COUNT * 16     ; 512B TX descriptor ring
net_rx_bufs:    resb RX_DESC_COUNT * BUF_SIZE ; 64KB RX packet buffers
net_tx_bufs:    resb TX_DESC_COUNT * BUF_SIZE ; 64KB TX packet buffers
net_arp_buf:    resb 64                     ; ARP packet build buffer
net_mac:        resb 8                      ; MAC address (6 bytes + 2 pad)
net_bar0:       resq 1                      ; MMIO base address
net_irq:        resd 1                      ; IRQ number
net_rx_head:    resd 1                      ; software RX head index
net_tx_tail:    resd 1                      ; software TX tail index
net_rx_flag:    resd 1                      ; set by ISR, cleared by poll
net_present:    resd 1                      ; 1 if E1000 found
net_msg_buf:    resb 128                    ; snprintf buffer
