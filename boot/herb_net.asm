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
global arp_send_request
global arp_cache_lookup
global net_resolve_gateway
global net_poll_rx
global net_present
global net_rx_flag
global net_mac
global net_our_ip
global net_gateway_ip
global net_bar0
global ip_send
global icmp_send_echo
global udp_send
global udp_register_listener
global dns_resolve
global dns_result_ip
global dns_resolved_flag
global dns_pending
global tcp_connect
global tcp_state
global tcp_established
global tcp_send_data
global tcp_recv_buf
global tcp_recv_len
global tcp_recv_done
global http_get
global http_poll_state
global http_state

; ============================================================
; EXTERNS
; ============================================================
extern hw_pci_read          ; herb_hw.asm: (bus=CL, slot=DL, func=R8B, offset=R9B) -> EAX
extern serial_print         ; herb_hw.asm: (RCX=str)
extern herb_snprintf        ; herb_freestanding.asm
extern herb_memset          ; herb_freestanding.asm
extern herb_strcmp           ; herb_freestanding.asm
extern herb_strlen          ; herb_freestanding.asm
extern ping_pending         ; herb_kernel.asm: cleared when reply received
extern ping_tick            ; herb_kernel.asm: tick when ping was sent
extern timer_count          ; herb_kernel.asm: current tick count

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
RCTL_UPE        equ (1 << 3)   ; Unicast Promiscuous Enable
RCTL_MPE        equ (1 << 4)   ; Multicast Promiscuous Enable
RCTL_BAM        equ (1 << 15)  ; Broadcast Accept Mode
RCTL_SECRC      equ (1 << 26)  ; Strip Ethernet CRC
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

    mov [rel net_pci_slot], esi
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

    ; NOTE: RDT set AFTER RCTL enable (per E1000 spec)
    mov ecx, E1000_RDT
    xor edx, edx                   ; tail = 0 initially
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

    ; --- Enable RX: RCTL = EN | BAM | SECRC ---
    mov ecx, E1000_RCTL
    mov edx, RCTL_EN | RCTL_BAM | RCTL_SECRC
    call e1000_write

    ; Now set RDT to make descriptors available (must be after RCTL enable)
    mov ecx, E1000_RDT
    mov edx, RX_DESC_COUNT - 1      ; tail = 31
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

    ; --- Re-enable PCI bus mastering (may be cleared by device reset) ---
    ; Read PCI command register, set bit 2, also set MMIO enable (bit 1) and IO (bit 0)
    xor ecx, ecx                   ; bus 0
    mov edx, [rel net_pci_slot]
    xor r8d, r8d                    ; func 0
    mov r9d, 0x04                   ; command register
    call hw_pci_read
    or eax, 0x07                    ; bits 0,1,2: IO + Memory + Bus Master
    mov r12d, eax                   ; save target value

    ; Write PCI config space — 32-bit write to trigger QEMU PCI config handler
    mov eax, [rel net_pci_slot]
    shl eax, 11
    or eax, 0x80000004
    mov dx, 0x0CF8
    out dx, eax
    mov eax, r12d
    mov dx, 0x0CFC
    out dx, eax                     ; write 32-bit (triggers QEMU PCI config handler)

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

    ; Set IP config
    mov dword [rel net_our_ip], 0x0F02000A      ; 10.0.2.15
    mov dword [rel net_gateway_ip], 0x0202000A   ; 10.0.2.2
    mov dword [rel net_subnet_mask], 0x00FFFFFF  ; 255.255.255.0

    ; Register DNS UDP listener on port DNS_SRC_PORT
    mov ecx, DNS_SRC_PORT           ; 4444
    lea rdx, [rel dns_handle_response]
    call udp_register_listener

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
; Backward-compat wrapper: sends ARP request for gateway IP
; ============================================================
net_send_arp_request:
    push rbp
    mov rbp, rsp
    sub rsp, 32                     ; shadow

    cmp dword [rel net_present], 0
    je .legacy_arp_skip

    mov ecx, [rel net_gateway_ip]
    call arp_send_request

.legacy_arp_skip:
    add rsp, 32
    pop rbp
    ret

; ============================================================
; arp_send_request(ECX=target_ip)
; Build and send a broadcast ARP "who-has" for target_ip
; ============================================================
arp_send_request:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48                     ; shadow(32) + 16(align)
    ; 8(ret)+8(rbp)+32(push)+48(sub)=96, 96%16=0 ✓

    mov r12d, ecx                   ; save target_ip

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

    ; Sender IP: from config
    mov eax, [rel net_our_ip]
    mov [rdi+28], eax               ; 4 bytes, network order in memory

    ; Target MAC: 00:00:00:00:00:00
    xor eax, eax
    mov [rdi+32], al
    mov [rdi+33], al
    mov [rdi+34], al
    mov [rdi+35], al
    mov [rdi+36], al
    mov [rdi+37], al

    ; Target IP: from param
    mov [rdi+38], r12d              ; 4 bytes

    ; Send it
    lea rcx, [rel net_arp_buf]
    mov edx, 42
    call net_send

    test eax, eax
    jnz .arp_req_fail

    ; Serial: "[ARP] request: who has X.X.X.X?"
    lea rdi, [rel net_fmt_scratch]
    mov ecx, r12d
    call net_format_ip              ; writes IP string to net_fmt_scratch

    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_arp_req_fmt]
    lea r9, [rel net_fmt_scratch]
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print
    jmp .arp_req_done

.arp_req_fail:
    lea rcx, [rel str_net_arp_fail]
    call serial_print

.arp_req_done:
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; arp_send_reply(RCX=dst_mac_ptr, EDX=dst_ip)
; Build and send ARP reply to a specific host
; ============================================================
arp_send_reply:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 40                     ; shadow(32) + 8(align)
    ; 8(ret)+8(rbp)+40(push)+40(sub)=96, 96%16=0 ✓

    mov r12, rcx                    ; dst_mac_ptr
    mov r13d, edx                   ; dst_ip

    lea rdi, [rel net_arp_buf]

    ; Ethernet header: dst MAC from param
    mov al, [r12+0]
    mov [rdi+0], al
    mov al, [r12+1]
    mov [rdi+1], al
    mov al, [r12+2]
    mov [rdi+2], al
    mov al, [r12+3]
    mov [rdi+3], al
    mov al, [r12+4]
    mov [rdi+4], al
    mov al, [r12+5]
    mov [rdi+5], al

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

    ; EtherType: 0x0806 (ARP)
    mov byte [rdi+12], 0x08
    mov byte [rdi+13], 0x06

    ; ARP header
    mov byte [rdi+14], 0x00
    mov byte [rdi+15], 0x01        ; HTYPE=1
    mov byte [rdi+16], 0x08
    mov byte [rdi+17], 0x00        ; PTYPE=0x0800
    mov byte [rdi+18], 6           ; HLEN
    mov byte [rdi+19], 4           ; PLEN
    mov byte [rdi+20], 0x00
    mov byte [rdi+21], 0x02        ; OPER=2 (reply)

    ; Sender MAC (ours)
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

    ; Sender IP (ours)
    mov eax, [rel net_our_ip]
    mov [rdi+28], eax

    ; Target MAC (requester)
    mov al, [r12+0]
    mov [rdi+32], al
    mov al, [r12+1]
    mov [rdi+33], al
    mov al, [r12+2]
    mov [rdi+34], al
    mov al, [r12+3]
    mov [rdi+35], al
    mov al, [r12+4]
    mov [rdi+36], al
    mov al, [r12+5]
    mov [rdi+37], al

    ; Target IP (requester)
    mov [rdi+38], r13d

    ; Send it
    lea rcx, [rel net_arp_buf]
    mov edx, 42
    call net_send

    ; Serial log
    lea rcx, [rel str_arp_reply_sent]
    call serial_print

    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; net_format_hex_byte(AL=byte, RDI=output_ptr)
; Writes 2 hex chars to [rdi], advances rdi by 2
; ============================================================
net_format_hex_byte:
    push rbx
    mov bl, al                      ; save byte

    ; High nibble
    mov al, bl
    shr al, 4
    cmp al, 10
    jb .hex_hi_digit
    add al, ('A' - 10)
    jmp .hex_hi_done
.hex_hi_digit:
    add al, '0'
.hex_hi_done:
    mov [rdi], al

    ; Low nibble
    mov al, bl
    and al, 0x0F
    cmp al, 10
    jb .hex_lo_digit
    add al, ('A' - 10)
    jmp .hex_lo_done
.hex_lo_digit:
    add al, '0'
.hex_lo_done:
    mov [rdi+1], al

    add rdi, 2
    pop rbx
    ret

; ============================================================
; net_format_mac(RSI=mac_ptr, RDI=out_buf)
; Writes "XX:XX:XX:XX:XX:XX\0" (18 bytes) to out_buf
; ============================================================
net_format_mac:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 8                     ; align: 8(ret)+32(push)+8(sub)=48, 48%16=0 ✓
    mov r12, rdi                    ; save start

    xor ebx, ebx
.fmt_mac_loop:
    cmp ebx, 6
    jge .fmt_mac_done
    movzx eax, byte [rsi + rbx]
    call net_format_hex_byte        ; writes 2 chars, advances rdi
    inc ebx
    cmp ebx, 6
    jge .fmt_mac_done
    mov byte [rdi], ':'
    inc rdi
    jmp .fmt_mac_loop
.fmt_mac_done:
    mov byte [rdi], 0              ; null-terminate

    add rsp, 8
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ============================================================
; net_format_ip(ECX=ip_dword, RDI=out_buf)
; Writes "X.X.X.X\0" to out_buf
; IP is stored as raw bytes in memory (10.0.2.15 = 0x0F02000A as dword)
; We extract byte 0 (lowest) first = first octet
; ============================================================
net_format_ip:
    push rbx
    push rsi
    push rdi
    push r12
    mov r12, rdi                    ; save out_buf
    mov esi, ecx                    ; save ip dword

    xor ebx, ebx                   ; byte index
.fmt_ip_loop:
    cmp ebx, 4
    jge .fmt_ip_done

    ; Extract byte ebx from esi
    mov eax, esi
    mov ecx, ebx
    shl ecx, 3                     ; byte_index * 8
    shr eax, cl
    and eax, 0xFF                  ; single byte value 0-255

    ; Convert to decimal digits
    ; Divide by 100
    cmp eax, 100
    jb .ip_no_hundreds
    push rax
    xor edx, edx
    mov ecx, 100
    div ecx                        ; eax=hundreds digit, edx=remainder
    add al, '0'
    mov [rdi], al
    inc rdi
    mov eax, edx                   ; remainder
    pop rcx                        ; discard saved (we used div result)
    jmp .ip_tens
.ip_no_hundreds:
    ; Check if >= 10 for leading tens digit
.ip_tens:
    cmp eax, 10
    jb .ip_ones
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [rdi], al
    inc rdi
    mov eax, edx
.ip_ones:
    add al, '0'
    mov [rdi], al
    inc rdi

    ; Add dot separator (except after last byte)
    inc ebx
    cmp ebx, 4
    jge .fmt_ip_done
    mov byte [rdi], '.'
    inc rdi
    jmp .fmt_ip_loop

.fmt_ip_done:
    mov byte [rdi], 0              ; null-terminate
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ============================================================
; arp_cache_lookup(ECX=ip) -> RAX = pointer to 6-byte MAC, or 0
; ============================================================
arp_cache_lookup:
    push rbx
    push rsi

    xor ebx, ebx                   ; i = 0
.cache_scan:
    cmp ebx, ARP_CACHE_SIZE
    jge .cache_miss

    ; Check valid
    lea rsi, [rel arp_cache_valid]
    cmp byte [rsi + rbx], 1
    jne .cache_next

    ; Check IP match
    lea rsi, [rel arp_cache_ip]
    cmp [rsi + rbx*4], ecx
    jne .cache_next

    ; Found — return pointer to MAC
    lea rax, [rel arp_cache_mac]
    mov esi, ebx
    imul esi, 6
    add rax, rsi
    pop rsi
    pop rbx
    ret

.cache_next:
    inc ebx
    jmp .cache_scan

.cache_miss:
    xor eax, eax
    pop rsi
    pop rbx
    ret

; ============================================================
; arp_cache_insert(ECX=ip, RDX=mac_ptr)
; ============================================================
arp_cache_insert:
    push rbx
    push rsi
    push rdi

    ; Find first empty slot
    xor ebx, ebx
.insert_scan:
    cmp ebx, ARP_CACHE_SIZE
    jge .insert_overwrite           ; full — overwrite slot 0
    lea rsi, [rel arp_cache_valid]
    cmp byte [rsi + rbx], 0
    je .insert_slot
    inc ebx
    jmp .insert_scan

.insert_overwrite:
    xor ebx, ebx                   ; overwrite slot 0

.insert_slot:
    ; Store IP
    lea rsi, [rel arp_cache_ip]
    mov [rsi + rbx*4], ecx

    ; Store MAC (6 bytes)
    lea rdi, [rel arp_cache_mac]
    mov eax, ebx
    imul eax, 6
    add rdi, rax
    mov rsi, rdx                    ; mac_ptr
    mov al, [rsi+0]
    mov [rdi+0], al
    mov al, [rsi+1]
    mov [rdi+1], al
    mov al, [rsi+2]
    mov [rdi+2], al
    mov al, [rsi+3]
    mov [rdi+3], al
    mov al, [rsi+4]
    mov [rdi+4], al
    mov al, [rsi+5]
    mov [rdi+5], al

    ; Mark valid
    lea rsi, [rel arp_cache_valid]
    mov byte [rsi + rbx], 1

    pop rdi
    pop rsi
    pop rbx
    ret

; ============================================================
; arp_handle_packet(RSI=rx_buf_start, ECX=length)
; Called from net_poll_rx when ethertype == 0x0806
; ============================================================
arp_handle_packet:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 40                     ; shadow(32) + 8(align)
    ; 8(ret)+8(rbp)+40(push)+40(sub)=96, 96%16=0 ✓

    mov r12, rsi                    ; save rx_buf_start

    ; Verify ARP header basics
    ; htype at offset 14-15 must be 0x0001
    movzx eax, byte [r12 + 14]
    shl eax, 8
    movzx edx, byte [r12 + 15]
    or eax, edx
    cmp eax, 1
    jne .arp_handle_done

    ; ptype at offset 16-17 must be 0x0800
    movzx eax, byte [r12 + 16]
    shl eax, 8
    movzx edx, byte [r12 + 17]
    or eax, edx
    cmp eax, 0x0800
    jne .arp_handle_done

    ; hlen=6, plen=4
    cmp byte [r12 + 18], 6
    jne .arp_handle_done
    cmp byte [r12 + 19], 4
    jne .arp_handle_done

    ; Read oper (offset 20-21, big-endian)
    movzx eax, byte [r12 + 20]
    shl eax, 8
    movzx edx, byte [r12 + 21]
    or eax, edx
    mov ebx, eax                    ; ebx = oper

    cmp ebx, 2
    je .arp_is_reply
    cmp ebx, 1
    je .arp_is_request
    jmp .arp_handle_done

.arp_is_reply:
    ; Extract sender IP (spa) at offset 28 (4 bytes)
    mov ecx, [r12 + 28]            ; sender IP (raw bytes, already correct)
    ; Extract sender MAC (sha) pointer at offset 22
    lea rdx, [r12 + 22]

    ; Insert into cache
    call arp_cache_insert

    ; Serial: "[ARP] reply: X.X.X.X is at XX:XX:XX:XX:XX:XX"
    ; Format IP
    mov ecx, [r12 + 28]
    lea rdi, [rel net_fmt_scratch]
    call net_format_ip

    ; Format MAC
    lea rsi, [r12 + 22]
    lea rdi, [rel net_fmt_scratch + 20]   ; offset to avoid overlap
    call net_format_mac

    ; Build message
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_arp_reply_fmt]
    lea r9, [rel net_fmt_scratch]         ; IP string
    lea rax, [rel net_fmt_scratch + 20]   ; MAC string
    mov [rsp+32], rax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print
    jmp .arp_handle_done

.arp_is_request:
    ; Read target IP (tpa) at offset 38
    mov eax, [r12 + 38]
    cmp eax, [rel net_our_ip]
    jne .arp_handle_done

    ; Someone is asking for our MAC — reply
    lea rcx, [r12 + 22]            ; requester's MAC (sha)
    mov edx, [r12 + 28]            ; requester's IP (spa)
    call arp_send_reply

    lea rcx, [rel str_arp_reply_to_req]
    call serial_print

.arp_handle_done:
    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; net_resolve_gateway()
; Send ARP request for gateway, non-blocking.
; Reply will be processed by net_poll_rx in the main loop.
; ============================================================
net_resolve_gateway:
    push rbp
    mov rbp, rsp
    sub rsp, 32                     ; shadow

    ; Just send the ARP request — reply handled asynchronously
    mov ecx, [rel net_gateway_ip]
    call arp_send_request

    lea rcx, [rel str_net_gw_arp_sent]
    call serial_print

    add rsp, 32
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
    movzx esi, word [rdi + 8]       ; length at offset 8 (callee-saved)

    ; Compute rx buffer pointer
    lea rax, [rel net_rx_bufs]
    mov ecx, ebx
    imul ecx, BUF_SIZE
    add rax, rcx                    ; rax = rx buffer for this descriptor
    mov [rsp+40], rax               ; save rx buf ptr in stack slot

    ; Read ethertype from packet (offset 12-13 in ethernet frame)
    movzx edx, byte [rax + 12]     ; high byte of ethertype
    shl edx, 8
    movzx ecx, byte [rax + 13]     ; low byte
    or edx, ecx                     ; edx = ethertype

    ; Log the packet
    mov [rsp+32], rdx               ; ethertype (stack arg)
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel net_fmt_rx]
    mov r9d, esi                    ; length
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    ; Reload rx buf ptr and recompute ethertype (snprintf clobbered regs)
    mov rax, [rsp+40]              ; rx buf ptr
    movzx edx, byte [rax + 12]
    shl edx, 8
    movzx ecx, byte [rax + 13]
    or edx, ecx

    ; Dispatch by ethertype
    cmp edx, 0x0806                ; ARP?
    jne .poll_check_ip

    ; ARP packet — dispatch to handler
    ; arp_handle_packet(RSI=rx_buf_start, ECX=length)
    mov ecx, esi                   ; length (esi callee-saved, still valid)
    mov rsi, [rsp+40]              ; rx buf ptr
    call arp_handle_packet
    jmp .poll_advance

.poll_check_ip:
    cmp edx, 0x0800                ; IPv4?
    jne .poll_advance

    ; IPv4 packet — dispatch to handler
    ; ip_handle_packet(RSI=frame_ptr, ECX=frame_len)
    mov ecx, esi                   ; length
    mov rsi, [rsp+40]              ; rx buf ptr
    call ip_handle_packet

.poll_advance:
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
; ip_checksum(RCX=data_ptr, EDX=length) -> AX (16-bit checksum)
; One's complement sum of 16-bit words, folded, complemented.
; ============================================================
ip_checksum:
    push rbx
    push rsi

    mov rsi, rcx                    ; data pointer
    mov ecx, edx                    ; length
    xor eax, eax                    ; accumulator (32-bit)

    ; Process 16-bit words
    mov ebx, ecx
    shr ebx, 1                      ; word count
    test ebx, ebx
    jz .cksum_odd_check
    xor edx, edx                    ; word index
.cksum_loop:
    movzx r8d, word [rsi + rdx*2]
    add eax, r8d
    inc edx
    cmp edx, ebx
    jb .cksum_loop

.cksum_odd_check:
    ; Handle odd trailing byte
    test ecx, 1
    jz .cksum_fold
    movzx r8d, byte [rsi + rcx - 1]
    shl r8d, 8                      ; high byte in network order
    add eax, r8d

.cksum_fold:
    ; Fold 32-bit carries into 16 bits
    mov edx, eax
    shr edx, 16
    and eax, 0xFFFF
    add eax, edx
    ; May produce another carry
    mov edx, eax
    shr edx, 16
    add eax, edx
    and eax, 0xFFFF

    ; One's complement
    not eax
    and eax, 0xFFFF

    pop rsi
    pop rbx
    ret

; ============================================================
; ip_send(RCX=dst_ip_dword, EDX=protocol, R8=payload_ptr, R9D=payload_len)
; Build IPv4 frame and send via Ethernet
; Returns: EAX (0=ok, -1=fail)
; ============================================================
ip_send:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 48                     ; shadow(32) + 16(args)
    ; 8(ret)+8(rbp)+48(push)+48(sub)=112, 112%16=0 ✓

    mov r12d, ecx                   ; dst_ip
    mov r13d, edx                   ; protocol
    mov r14, r8                     ; payload_ptr
    mov ebx, r9d                    ; payload_len

    ; Look up gateway MAC via ARP cache
    mov ecx, [rel net_gateway_ip]
    call arp_cache_lookup
    test rax, rax
    jz .ip_send_no_mac

    mov rsi, rax                    ; rsi = gateway MAC pointer

    ; Build frame in ip_send_buf
    lea rdi, [rel ip_send_buf]

    ; === Ethernet header (14 bytes) ===
    ; Destination MAC (from ARP cache)
    mov al, [rsi+0]
    mov [rdi+0], al
    mov al, [rsi+1]
    mov [rdi+1], al
    mov al, [rsi+2]
    mov [rdi+2], al
    mov al, [rsi+3]
    mov [rdi+3], al
    mov al, [rsi+4]
    mov [rdi+4], al
    mov al, [rsi+5]
    mov [rdi+5], al
    ; Source MAC
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
    ; EtherType: 0x0800 (IPv4)
    mov byte [rdi+12], 0x08
    mov byte [rdi+13], 0x00

    ; === IPv4 header (20 bytes, starting at offset 14) ===
    ; version=4, IHL=5 -> 0x45
    mov byte [rdi+14], 0x45
    ; DSCP/ECN = 0
    mov byte [rdi+15], 0x00
    ; Total length = 20 + payload_len (big-endian)
    lea eax, [ebx + 20]
    mov [rdi+16], ah                ; high byte
    mov [rdi+17], al                ; low byte
    ; Identification (big-endian, incrementing)
    movzx eax, word [rel ip_id_counter]
    inc word [rel ip_id_counter]
    mov [rdi+18], ah
    mov [rdi+19], al
    ; Flags + Fragment Offset: 0x40 0x00 (Don't Fragment)
    mov byte [rdi+20], 0x40
    mov byte [rdi+21], 0x00
    ; TTL = 64
    mov byte [rdi+22], 64
    ; Protocol
    mov [rdi+23], r13b
    ; Header checksum = 0 (placeholder)
    mov word [rdi+24], 0
    ; Source IP
    mov eax, [rel net_our_ip]
    mov [rdi+26], eax
    ; Destination IP
    mov [rdi+30], r12d

    ; Compute IP header checksum over 20 bytes at offset 14
    lea rcx, [rdi+14]
    mov edx, 20
    call ip_checksum
    ; Store checksum (already in network byte order due to LE reads)
    lea rdi, [rel ip_send_buf]
    mov [rdi+24], ax

    ; === Copy payload after IP header (offset 34) ===
    xor ecx, ecx
.ip_copy_payload:
    cmp ecx, ebx
    jge .ip_copy_done
    mov al, [r14 + rcx]
    mov [rdi + 34 + rcx], al
    inc ecx
    jmp .ip_copy_payload
.ip_copy_done:

    ; Send frame: 14 (eth) + 20 (ip) + payload_len
    lea rcx, [rel ip_send_buf]
    lea edx, [ebx + 34]
    call net_send
    jmp .ip_send_done

.ip_send_no_mac:
    lea rcx, [rel str_ip_no_mac]
    call serial_print
    mov eax, -1

.ip_send_done:
    add rsp, 48
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; ip_handle_packet(RSI=frame_ptr, ECX=frame_len)
; Parse and dispatch incoming IPv4 packet
; ============================================================
ip_handle_packet:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 56                     ; shadow(32) + 24(args+locals)
    ; 8(ret)+8(rbp)+40(push)+56(sub)=112, 112%16=0 ✓

    mov r12, rsi                    ; frame_ptr
    mov r13d, ecx                   ; frame_len

    ; Verify IPv4 (version nibble == 4)
    movzx eax, byte [r12 + 14]
    mov ebx, eax                    ; save version_ihl byte
    shr eax, 4
    cmp eax, 4
    jne .ip_handle_done

    ; IHL = low nibble (header length in 32-bit words)
    and ebx, 0x0F
    ; ebx = IHL (typically 5 = 20 bytes)

    ; Protocol at offset 14+9 = 23
    movzx esi, byte [r12 + 23]     ; protocol (callee-saved)

    ; Source IP at offset 14+12 = 26
    mov ecx, [r12 + 26]            ; src_ip (network byte order)

    ; Dest IP at offset 14+16 = 30
    mov eax, [r12 + 30]
    cmp eax, [rel net_our_ip]
    jne .ip_handle_done             ; not for us

    ; Save src_ip in stack slot (past shadow+args area)
    mov [rsp+48], ecx

    ; Serial log: [IP] from X.X.X.X proto=N len=N
    lea rdi, [rel net_fmt_scratch]
    ; ecx already = src_ip
    call net_format_ip

    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_ip_rx_fmt]
    lea r9, [rel net_fmt_scratch]   ; IP string
    mov eax, esi                    ; protocol
    mov [rsp+32], rax               ; 5th arg
    mov eax, r13d
    mov [rsp+40], rax               ; 6th arg = frame_len
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    ; Dispatch by protocol
    cmp esi, 1                      ; ICMP?
    jne .not_icmp

    ; icmp_handle(RSI=frame_ptr, ECX=frame_len, EDX=src_ip)
    mov rsi, r12
    mov ecx, r13d
    mov edx, [rsp+48]              ; src_ip from stack slot
    call icmp_handle
    jmp .ip_handle_done

.not_icmp:
    cmp esi, 6                      ; TCP?
    jne .not_tcp
    mov rsi, r12
    mov ecx, r13d
    mov edx, [rsp+48]              ; src_ip from stack slot
    call tcp_handle_packet
    jmp .ip_handle_done
.not_tcp:
    cmp esi, 17                     ; UDP?
    jne .ip_handle_done

    ; udp_handle_packet(RSI=frame_ptr, ECX=frame_len, EDX=src_ip)
    mov rsi, r12
    mov ecx, r13d
    mov edx, [rsp+48]              ; src_ip from stack slot
    call udp_handle_packet

.ip_handle_done:
    add rsp, 56
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; icmp_send_echo(ECX=dst_ip, EDX=sequence)
; Build ICMP echo request and send via ip_send
; ============================================================
icmp_send_echo:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 40                     ; shadow(32) + 8(align)
    ; 8(ret)+8(rbp)+40(push)+40(sub)=96, 96%16=0 ✓

    mov r12d, ecx                   ; dst_ip
    mov r13d, edx                   ; sequence

    lea rdi, [rel icmp_buf]

    ; Type = 8 (echo request), Code = 0
    mov byte [rdi+0], 8
    mov byte [rdi+1], 0
    ; Checksum = 0 (placeholder)
    mov word [rdi+2], 0
    ; Identifier = 0x4845 ("HE") big-endian: 0x48, 0x45
    mov byte [rdi+4], 0x48
    mov byte [rdi+5], 0x45
    ; Sequence (big-endian)
    mov eax, r13d
    mov [rdi+6], ah
    mov [rdi+7], al

    ; 32 bytes of payload ('A' = 0x41)
    mov ecx, 0
.icmp_fill:
    cmp ecx, 32
    jge .icmp_fill_done
    mov byte [rdi + 8 + rcx], 0x41
    inc ecx
    jmp .icmp_fill
.icmp_fill_done:

    ; Compute ICMP checksum over 40 bytes
    lea rcx, [rel icmp_buf]
    mov edx, 40
    call ip_checksum
    lea rdi, [rel icmp_buf]
    mov [rdi+2], ax                 ; store checksum

    ; ip_send(dst_ip, protocol=1, payload, len=40)
    mov ecx, r12d                   ; dst_ip
    mov edx, 1                      ; ICMP protocol
    lea r8, [rel icmp_buf]
    mov r9d, 40
    call ip_send

    ; Serial: [PING] sent to X.X.X.X seq=N
    lea rdi, [rel net_fmt_scratch]
    mov ecx, r12d
    call net_format_ip

    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_ping_sent_fmt]
    lea r9, [rel net_fmt_scratch]
    mov [rsp+32], r13               ; seq = 5th arg (zero-extended)
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; icmp_handle(RSI=frame_ptr, ECX=frame_len, EDX=src_ip)
; Handle incoming ICMP packet (echo reply or echo request)
; ============================================================
icmp_handle:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 48                     ; shadow(32) + 16(args)
    ; 8(ret)+8(rbp)+48(push)+48(sub)=112, 112%16=0 ✓

    mov r12, rsi                    ; frame_ptr
    mov r13d, ecx                   ; frame_len
    mov r14d, edx                   ; src_ip

    ; ICMP starts after Ethernet (14) + IP header
    ; Read IHL from byte 14
    movzx eax, byte [r12 + 14]
    and eax, 0x0F
    shl eax, 2                      ; IHL * 4 = IP header size
    add eax, 14                     ; offset to ICMP data
    mov ebx, eax                    ; ebx = ICMP offset

    ; Read ICMP type
    movzx edi, byte [r12 + rbx]

    cmp edi, 0                      ; Echo Reply
    je .icmp_echo_reply
    cmp edi, 8                      ; Echo Request
    je .icmp_echo_request
    jmp .icmp_handle_done

.icmp_echo_reply:
    ; Read sequence number at offset +6 (big-endian)
    movzx eax, byte [r12 + rbx + 6]
    shl eax, 8
    movzx ecx, byte [r12 + rbx + 7]
    or eax, ecx
    mov esi, eax                    ; esi = sequence

    ; Serial: [PING] reply from X.X.X.X seq=N
    push rsi                        ; save seq
    lea rdi, [rel net_fmt_scratch]
    mov ecx, r14d
    call net_format_ip

    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_ping_reply_fmt]
    lea r9, [rel net_fmt_scratch]
    pop rax                         ; seq
    mov [rsp+32], rax               ; 5th arg
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    ; Clear ping_pending
    mov dword [rel ping_pending], 0

    ; Compute approximate RTT: (current_tick - ping_tick) * 10 ms
    mov eax, [rel timer_count]
    sub eax, [rel ping_tick]
    imul eax, 10                    ; 100Hz PIT -> 10ms per tick
    ; Serial: [PING] time=Nms
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_ping_time_fmt]
    mov r9d, eax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    jmp .icmp_handle_done

.icmp_echo_request:
    ; Respond to incoming ping
    ; icmp_send_reply(RSI=frame_ptr, ECX=frame_len, EDX=src_ip)
    mov rsi, r12
    mov ecx, r13d
    mov edx, r14d
    call icmp_send_reply
    jmp .icmp_handle_done

.icmp_handle_done:
    add rsp, 48
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; icmp_send_reply(RSI=frame_ptr, ECX=frame_len, EDX=src_ip)
; Reply to an incoming ICMP echo request
; ============================================================
icmp_send_reply:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 48                     ; shadow(32) + 16(args)
    ; 8(ret)+8(rbp)+48(push)+48(sub)=112, 112%16=0 ✓

    mov r12, rsi                    ; frame_ptr
    mov r13d, ecx                   ; frame_len
    mov r14d, edx                   ; src_ip

    ; Compute ICMP offset and length
    movzx eax, byte [r12 + 14]
    and eax, 0x0F
    shl eax, 2                      ; IP header len
    mov ebx, eax                    ; IP header size
    lea edi, [eax + 14]            ; ICMP data offset in frame
    ; ICMP length = frame_len - 14 - IP_header_len
    mov esi, r13d
    sub esi, 14
    sub esi, ebx                    ; esi = ICMP payload length

    ; Bounds check
    cmp esi, 4
    jb .icmp_reply_done
    cmp esi, 128
    ja .icmp_reply_done

    ; Copy ICMP data to icmp_reply_buf
    ; Compute ICMP start: r12 + rdi (frame_ptr + icmp_offset)
    lea r8, [r12 + rdi]            ; r8 = ICMP data start in frame
    lea rcx, [rel icmp_reply_buf]
    xor edx, edx
.icmp_reply_copy:
    cmp edx, esi
    jge .icmp_reply_copied
    mov al, [r8 + rdx]
    mov [rcx + rdx], al
    inc edx
    jmp .icmp_reply_copy
.icmp_reply_copied:

    ; Change type to 0 (echo reply), code stays 0
    lea rcx, [rel icmp_reply_buf]
    mov byte [rcx+0], 0             ; type = echo reply
    mov byte [rcx+1], 0             ; code = 0
    ; Zero checksum for recomputation
    mov word [rcx+2], 0

    ; Recompute ICMP checksum
    lea rcx, [rel icmp_reply_buf]
    mov edx, esi
    call ip_checksum
    lea rcx, [rel icmp_reply_buf]
    mov [rcx+2], ax

    ; ip_send(src_ip, protocol=1, icmp_reply_buf, icmp_len)
    mov ecx, r14d                   ; src_ip (reply to sender)
    mov edx, 1                      ; ICMP
    lea r8, [rel icmp_reply_buf]
    mov r9d, esi
    call ip_send

    ; Serial: [PING] responding to X.X.X.X
    lea rdi, [rel net_fmt_scratch]
    mov ecx, r14d
    call net_format_ip

    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_ping_respond_fmt]
    lea r9, [rel net_fmt_scratch]
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

.icmp_reply_done:
    add rsp, 48
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; udp_handle_packet(RSI=frame_ptr, ECX=frame_len, EDX=src_ip)
; Parse UDP header and dispatch by destination port
; ============================================================
udp_handle_packet:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 48                     ; shadow(32) + 16(locals)
    ; 8(ret)+8(rbp)+48(push)+48(sub)=112, 112%16=0 ✓

    mov r12, rsi                    ; frame_ptr
    mov r13d, ecx                   ; frame_len
    mov [rsp+44], edx               ; src_ip at [rsp+44]

    ; UDP header starts at 14 (eth) + IHL*4 (typically 20) = 34
    movzx eax, byte [r12 + 14]     ; version_ihl
    and eax, 0x0F                   ; IHL
    shl eax, 2                      ; IHL * 4
    add eax, 14                     ; + ethernet header
    mov ebx, eax                    ; ebx = udp_offset

    ; Bounds check: need at least 8 bytes for UDP header
    lea ecx, [ebx + 8]
    cmp ecx, r13d
    ja .udp_rx_done

    ; Parse UDP header (big-endian)
    ; src_port at [frame + udp_offset + 0..1]
    movzx r14d, byte [r12 + rbx]
    shl r14d, 8
    movzx eax, byte [r12 + rbx + 1]
    or r14d, eax                    ; r14d = src_port

    ; dst_port at [frame + udp_offset + 2..3]
    movzx edi, byte [r12 + rbx + 2]
    shl edi, 8
    movzx eax, byte [r12 + rbx + 3]
    or edi, eax                     ; edi = dst_port

    ; length at [frame + udp_offset + 4..5]
    movzx eax, byte [r12 + rbx + 4]
    shl eax, 8
    movzx ecx, byte [r12 + rbx + 5]
    or eax, ecx                     ; eax = udp_length (header + payload)

    ; payload_len = udp_length - 8
    mov ecx, eax
    sub ecx, 8
    jb .udp_rx_done                 ; malformed if length < 8

    ; Serial log: [UDP] from X.X.X.X:N -> port N
    ; NOTE: net_format_ip clobbers rdi, so dst_port in edi is lost.
    ; We re-parse dst_port from the packet below for both logging and dispatch.

    lea rdi, [rel net_fmt_scratch]
    mov ecx, [rsp+44]              ; src_ip
    call net_format_ip

    ; Re-parse dst_port from packet for snprintf (edi was clobbered)
    movzx eax, byte [r12 + rbx + 2]
    shl eax, 8
    movzx ecx, byte [r12 + rbx + 3]
    or eax, ecx                     ; eax = dst_port

    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_udp_rx_fmt]
    lea r9, [rel net_fmt_scratch]   ; IP string
    mov esi, eax                    ; save dst_port in esi (callee-saved, free here)
    mov eax, r14d                   ; src_port
    mov [rsp+32], rax
    movzx eax, si                   ; dst_port
    mov [rsp+40], rax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    ; esi = dst_port (preserved across calls)
    mov edi, esi                    ; restore for dispatch

    ; Dispatch: recalculate payload_ptr and payload_len from preserved regs
    ; r12=frame, ebx=udp_offset, r14d=src_port, edi=dst_port
    lea r9, [r12 + rbx + 8]        ; payload_ptr

    ; Recalculate payload_len from UDP length field
    movzx eax, byte [r12 + rbx + 4]
    shl eax, 8
    movzx ecx, byte [r12 + rbx + 5]
    or eax, ecx
    sub eax, 8                      ; payload_len
    mov [rsp+32], rax               ; 5th arg = payload_len

    mov ecx, edi                    ; dst_port
    mov edx, [rsp+44]              ; src_ip
    mov r8d, r14d                   ; src_port
    ; r9 = payload_ptr (set above)
    call udp_dispatch

.udp_rx_done:
    add rsp, 48
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; udp_dispatch(ECX=dst_port, EDX=src_ip, R8D=src_port, R9=payload_ptr,
;              [rsp+32]=payload_len)
; Scan listener table, call matching handler
; Handler signature: handler(RCX=src_ip, EDX=src_port, R8=payload_ptr, R9D=payload_len)
; ============================================================
udp_dispatch:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 56                     ; shadow(32) + 24(locals)
    ; 8(ret)+8(rbp)+24(push)+56(sub)=96, 96%16=0 ✓

    ; Save args — NO overlapping slots (Discovery 68)
    mov ebx, ecx                    ; dst_port
    mov esi, edx                    ; src_ip
    mov edi, r8d                    ; src_port
    mov [rsp+32], r9                ; payload_ptr (8 bytes at [32..39])
    mov rax, [rbp+48]              ; 5th arg = payload_len (caller's [rsp+32])
    mov [rsp+48], eax               ; payload_len (4 bytes at [48..51]) — no overlap

    ; Scan listener table
    lea rcx, [rel udp_listener_ports]
    xor edx, edx                    ; i = 0
.udp_scan:
    cmp edx, UDP_MAX_LISTENERS
    jge .udp_no_listener

    movzx eax, word [rcx + rdx*2]
    cmp eax, ebx                    ; match dst_port?
    je .udp_found
    inc edx
    jmp .udp_scan

.udp_found:
    ; Call handler(RCX=src_ip, EDX=src_port, R8=payload_ptr, R9D=payload_len)
    lea rax, [rel udp_listener_funcs]
    mov rax, [rax + rdx*8]
    test rax, rax
    jz .udp_no_listener

    mov ecx, esi                    ; src_ip
    mov edx, edi                    ; src_port
    mov r8, [rsp+32]               ; payload_ptr
    mov r9d, [rsp+48]              ; payload_len
    call rax
    jmp .udp_dispatch_done

.udp_no_listener:
    ; Serial: [UDP] no listener on port N
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_udp_no_listener]
    mov r9d, ebx                    ; dst_port
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

.udp_dispatch_done:
    add rsp, 56
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; udp_register_listener(ECX=port, RDX=handler_fn)
; Register a UDP port listener. Returns 0=ok, -1=full.
; ============================================================
udp_register_listener:
    push rbx
    lea r8, [rel udp_listener_ports]
    lea r9, [rel udp_listener_funcs]
    xor eax, eax                    ; i = 0
.url_scan:
    cmp eax, UDP_MAX_LISTENERS
    jge .url_full

    movzx ebx, word [r8 + rax*2]
    test ebx, ebx                   ; port == 0 means empty
    jz .url_store
    inc eax
    jmp .url_scan

.url_store:
    mov [r8 + rax*2], cx            ; store port
    mov [r9 + rax*8], rdx           ; store handler
    xor eax, eax                    ; return 0
    pop rbx
    ret

.url_full:
    mov eax, -1
    pop rbx
    ret

; ============================================================
; udp_send(RCX=dst_ip, EDX=dst_port, R8D=src_port, R9=payload_ptr,
;          [rsp+40]=payload_len)
; Build UDP header + payload, send via ip_send
; ============================================================
udp_send:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48                     ; shadow(32) + 16(locals)
    ; 8(ret)+8(rbp)+40(push)+48(sub)=104, 104%16=0 ✓

    mov [rsp+40], ecx               ; dst_ip at [rsp+40]
    mov r12d, edx                   ; dst_port
    mov r13d, r8d                   ; src_port
    mov rsi, r9                     ; payload_ptr
    mov edi, [rbp+48]              ; payload_len (caller's 5th arg)
    ; Caller's 5th arg at [rsp+32] before call. After call: ret pushed,
    ; then push rbp, mov rbp,rsp. So caller's [rsp+32] = [rbp+16+32] = [rbp+48]

    ; Build UDP header in udp_send_buf
    lea rbx, [rel udp_send_buf]

    ; src_port (big-endian)
    mov eax, r13d
    mov [rbx], ah                   ; high byte
    mov [rbx+1], al                 ; low byte

    ; dst_port (big-endian)
    mov eax, r12d
    mov [rbx+2], ah
    mov [rbx+3], al

    ; length = 8 + payload_len (big-endian)
    lea eax, [edi + 8]
    mov [rbx+4], ah
    mov [rbx+5], al

    ; checksum = 0 (legal per RFC 768 for IPv4)
    mov word [rbx+6], 0

    ; Copy payload after UDP header
    test edi, edi
    jz .udp_send_no_payload
    xor ecx, ecx
.udp_copy:
    cmp ecx, edi
    jge .udp_send_no_payload
    movzx eax, byte [rsi + rcx]
    mov [rbx + rcx + 8], al
    inc ecx
    jmp .udp_copy
.udp_send_no_payload:

    ; ip_send(RCX=dst_ip, EDX=protocol=17, R8=udp_send_buf, R9D=8+payload_len)
    mov ecx, [rsp+40]              ; dst_ip
    mov edx, 17                     ; UDP protocol
    mov r8, rbx                     ; udp_send_buf
    lea r9d, [edi + 8]             ; total UDP length
    call ip_send

    ; Serial log: [UDP] sent to X.X.X.X:N len=N
    ; Save payload_len before net_format_ip clobbers rdi
    mov r13d, edi                   ; r13d = payload_len (r13 is callee-saved)
    lea rdi, [rel net_fmt_scratch]
    mov ecx, [rsp+40]              ; dst_ip
    call net_format_ip

    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_udp_sent_fmt]
    lea r9, [rel net_fmt_scratch]   ; IP string
    mov eax, r12d                   ; dst_port
    mov [rsp+32], rax
    mov eax, r13d                   ; payload_len (saved)
    mov [rsp+40], rax               ; clobbers saved dst_ip, but we're done with it
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; dns_encode_name(RCX=domain_str, RDX=output_ptr) -> EAX=bytes_written
; Converts "example.com" to DNS label format: \x07example\x03com\x00
; ============================================================
dns_encode_name:
    push rbx
    push rsi
    push rdi
    mov rsi, rcx                    ; domain string
    mov rdi, rdx                    ; output buffer
    xor ebx, ebx                    ; total bytes written

.den_segment:
    ; Write placeholder length byte
    lea rax, [rdi + rbx]            ; length byte position
    push rax                        ; save it
    inc ebx                         ; advance past length byte
    xor ecx, ecx                    ; segment char count

.den_char:
    movzx eax, byte [rsi]
    test al, al
    jz .den_end_segment
    cmp al, '.'
    je .den_dot

    ; Copy character
    mov [rdi + rbx], al
    inc ebx
    inc ecx
    inc rsi
    jmp .den_char

.den_dot:
    ; Fill in length byte for this segment
    pop rax                         ; length byte position
    mov [rax], cl
    inc rsi                         ; skip the dot
    jmp .den_segment

.den_end_segment:
    ; Fill in length byte for last segment
    pop rax
    mov [rax], cl
    ; Write null terminator
    mov byte [rdi + rbx], 0
    inc ebx
    mov eax, ebx                    ; return total bytes

    pop rdi
    pop rsi
    pop rbx
    ret

; ============================================================
; dns_build_query(RCX=domain_str, RDX=buffer) -> EAX=query_length
; Builds a complete DNS query packet
; ============================================================
dns_build_query:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40                     ; shadow(32) + 8(align)
    ; 8(ret)+8(rbp)+24(push)+40(sub)=80, 80%16=0 ✓

    mov rsi, rcx                    ; domain string
    mov rdi, rdx                    ; buffer

    ; Zero the first 12 bytes (DNS header)
    xor eax, eax
    mov [rdi], rax                  ; bytes 0-7
    mov [rdi+8], eax                ; bytes 8-11

    ; Transaction ID: increment counter, store big-endian
    movzx eax, word [rel dns_txid_counter]
    inc eax
    mov [rel dns_txid_counter], ax
    mov [rel dns_txid], ax          ; save for matching response
    xchg al, ah                     ; big-endian
    mov [rdi], ax                   ; txid at [0..1]

    ; Flags: 0x0100 (standard query, RD=1)
    mov byte [rdi+2], 0x01
    mov byte [rdi+3], 0x00

    ; QDCOUNT = 1
    mov byte [rdi+4], 0x00
    mov byte [rdi+5], 0x01

    ; Encode domain name starting at offset 12
    mov rcx, rsi                    ; domain string
    lea rdx, [rdi + 12]            ; output = buf+12
    call dns_encode_name
    mov ebx, eax                    ; name_len

    ; After encoded name: QTYPE=1 (A record), QCLASS=1 (IN)
    lea eax, [ebx + 12]            ; offset after name
    mov byte [rdi + rax], 0x00
    mov byte [rdi + rax + 1], 0x01  ; QTYPE=1
    mov byte [rdi + rax + 2], 0x00
    mov byte [rdi + rax + 3], 0x01  ; QCLASS=1

    ; Total length = 12 + name_len + 4
    lea eax, [ebx + 16]

    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; dns_cache_lookup(RCX=domain_str) -> EAX=ip (0 if not found)
; Linear scan of DNS cache
; ============================================================
dns_cache_lookup:
    push rbx
    push rsi
    push rdi
    sub rsp, 32                     ; shadow
    ; 8(ret)+24(push)+32(sub)=64, 64%16=0 ✓

    mov rsi, rcx                    ; domain to look up
    lea rdi, [rel dns_cache_names]
    xor ebx, ebx                    ; i = 0

.dcl_loop:
    cmp ebx, DNS_CACHE_SIZE
    jge .dcl_not_found

    ; Compare domain with cache entry
    mov rcx, rsi                    ; domain string
    mov eax, ebx
    shl eax, 6                      ; i * 64
    lea rdx, [rdi + rax]           ; cache entry

    ; Check if entry is non-empty
    cmp byte [rdx], 0
    je .dcl_next

    call herb_strcmp
    test eax, eax
    jz .dcl_found

.dcl_next:
    inc ebx
    jmp .dcl_loop

.dcl_found:
    lea rax, [rel dns_cache_ips]
    mov eax, [rax + rbx*4]

    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

.dcl_not_found:
    xor eax, eax

    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; ============================================================
; dns_cache_insert(RCX=domain_str, EDX=ip)
; Insert into circular DNS cache
; ============================================================
dns_cache_insert:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 32                     ; shadow
    ; 8(ret)+8(rbp)+32(push)+32(sub)=80, 80%16=0 ✓

    mov rsi, rcx                    ; domain string
    mov r12d, edx                   ; IP (saved in callee-saved r12)

    ; Compute slot = dns_cache_count % DNS_CACHE_SIZE
    mov eax, [rel dns_cache_count]
    and eax, (DNS_CACHE_SIZE - 1)   ; mod 8
    mov ebx, eax                    ; slot index

    ; Compute dest pointer: dns_cache_names + slot*64
    lea rdi, [rel dns_cache_names]
    mov eax, ebx
    shl eax, 6                      ; slot * 64
    add rdi, rax                    ; rdi = dest (callee-saved, safe across calls)

    ; Copy string byte by byte (up to 63 chars)
    xor ecx, ecx
.dci_copy:
    cmp ecx, 63
    jge .dci_copy_done
    movzx eax, byte [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz .dci_copy_done
    inc ecx
    jmp .dci_copy
.dci_copy_done:
    mov byte [rdi + rcx], 0         ; ensure null-terminated

    ; Store IP
    lea rax, [rel dns_cache_ips]
    mov [rax + rbx*4], r12d

    ; Increment cache count
    inc dword [rel dns_cache_count]

    add rsp, 32
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; dns_resolve(RCX=domain_str) -> void
; Send DNS query (non-blocking). Response arrives via UDP listener.
; ============================================================
dns_resolve:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40                     ; shadow(32) + 8(align)
    ; 8(ret)+8(rbp)+24(push)+40(sub)=80, 80%16=0 ✓

    mov rsi, rcx                    ; domain string

    ; Check DNS cache first
    ; rcx already = domain_str
    call dns_cache_lookup
    test eax, eax
    jz .dns_cache_miss

    ; Cache hit — store result and log
    mov [rel dns_result_ip], eax
    mov dword [rel dns_resolved_flag], 1
    mov ebx, eax                    ; save IP

    ; Format IP for log
    lea rdi, [rel net_fmt_scratch]
    mov ecx, ebx
    call net_format_ip

    ; Serial: [DNS] cached: <domain> -> X.X.X.X
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_dns_cached_fmt]
    mov r9, rsi                     ; domain name
    lea rax, [rel net_fmt_scratch]
    mov [rsp+32], rax               ; 5th arg = IP string
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print
    jmp .dns_resolve_done

.dns_cache_miss:
    ; Copy domain name for response handler logging
    lea rdi, [rel dns_query_name]
    xor ecx, ecx
.dns_copy_name:
    cmp ecx, 63
    jge .dns_copy_name_done
    movzx eax, byte [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz .dns_copy_name_done
    inc ecx
    jmp .dns_copy_name
.dns_copy_name_done:
    mov byte [rdi + rcx], 0

    ; Build DNS query
    mov rcx, rsi                    ; domain string
    lea rdx, [rel dns_query_buf]
    call dns_build_query
    mov ebx, eax                    ; query_len

    ; Set pending state
    mov dword [rel dns_pending], 1
    mov dword [rel dns_resolved_flag], 0

    ; Send via UDP: udp_send(dst_ip, dst_port=53, src_port=DNS_SRC_PORT, payload, len)
    mov ecx, [rel dns_server_ip]    ; 10.0.2.3
    mov edx, 53                     ; DNS port
    mov r8d, DNS_SRC_PORT           ; 4444
    lea r9, [rel dns_query_buf]
    mov [rsp+32], ebx               ; payload_len (on stack as 5th arg)
    call udp_send

    ; Serial: [DNS] query: <domain>
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_dns_query_fmt]
    lea r9, [rel dns_query_name]
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

.dns_resolve_done:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; dns_handle_response(RCX=src_ip, EDX=src_port, R8=payload_ptr, R9D=payload_len)
; UDP listener callback for DNS responses (port DNS_SRC_PORT)
; ============================================================
dns_handle_response:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 48                     ; shadow(32) + 16(locals)
    ; 8(ret)+8(rbp)+48(push)+48(sub)=112, 112%16=0 ✓

    mov r12, r8                     ; payload_ptr
    mov r13d, r9d                   ; payload_len

    ; Verify we're waiting for a response
    cmp dword [rel dns_pending], 0
    je .dns_resp_done

    ; Need at least 12 bytes for DNS header
    cmp r13d, 12
    jb .dns_resp_done

    ; Check transaction ID
    movzx eax, byte [r12]
    shl eax, 8
    movzx ecx, byte [r12+1]
    or eax, ecx                     ; txid from response (big-endian)
    movzx ecx, word [rel dns_txid]
    cmp eax, ecx
    jne .dns_resp_done              ; txid mismatch

    ; Check QR bit (byte[2] bit 7 must be 1 = response)
    test byte [r12+2], 0x80
    jz .dns_resp_done

    ; Check RCODE (byte[3] low nibble must be 0 = no error)
    movzx eax, byte [r12+3]
    and eax, 0x0F
    test eax, eax
    jnz .dns_resp_rcode_error

    ; Read ANCOUNT at [6..7] (big-endian)
    movzx eax, byte [r12+6]
    shl eax, 8
    movzx ecx, byte [r12+7]
    or eax, ecx
    test eax, eax
    jz .dns_resp_no_answer          ; ancount == 0

    mov r14d, eax                   ; r14d = ancount

    ; Skip question section (starts at offset 12)
    mov ebx, 12                     ; ebx = current offset

    ; Skip QNAME labels
.dns_skip_qname:
    cmp ebx, r13d
    jge .dns_resp_done              ; bounds
    movzx eax, byte [r12 + rbx]
    test al, al
    jz .dns_skip_qname_done         ; null terminator
    ; Check compression pointer (top 2 bits = 11)
    cmp al, 0xC0
    jae .dns_skip_qname_ptr
    ; Regular label: skip length + that many bytes
    movzx ecx, al
    inc ecx                         ; length byte + chars
    add ebx, ecx
    jmp .dns_skip_qname
.dns_skip_qname_ptr:
    add ebx, 2                     ; compression pointer = 2 bytes
    jmp .dns_skip_qtype
.dns_skip_qname_done:
    inc ebx                         ; skip null byte

.dns_skip_qtype:
    ; Skip QTYPE (2) + QCLASS (2)
    add ebx, 4

    ; Now parse answer RRs
    ; ebx = offset to first answer
.dns_parse_answer:
    cmp r14d, 0
    jle .dns_resp_no_answer         ; no more answers
    dec r14d

    ; Bounds check
    lea eax, [ebx + 12]            ; need at least name(2) + type(2) + class(2) + ttl(4) + rdlen(2)
    cmp eax, r13d
    jg .dns_resp_done

    ; Skip answer NAME
    movzx eax, byte [r12 + rbx]
    cmp al, 0xC0
    jae .dns_ans_name_ptr
    ; Regular labels — skip until null
.dns_ans_name_labels:
    cmp ebx, r13d
    jge .dns_resp_done
    movzx eax, byte [r12 + rbx]
    test al, al
    jz .dns_ans_name_null
    cmp al, 0xC0
    jae .dns_ans_name_ptr
    movzx ecx, al
    inc ecx
    add ebx, ecx
    jmp .dns_ans_name_labels
.dns_ans_name_null:
    inc ebx                         ; skip null
    jmp .dns_ans_parse_rr
.dns_ans_name_ptr:
    add ebx, 2                     ; compression pointer
    ; fall through

.dns_ans_parse_rr:
    ; Bounds check for TYPE(2)+CLASS(2)+TTL(4)+RDLENGTH(2) = 10 bytes
    lea eax, [ebx + 10]
    cmp eax, r13d
    jg .dns_resp_done

    ; TYPE at [ebx+0..1]
    movzx eax, byte [r12 + rbx]
    shl eax, 8
    movzx ecx, byte [r12 + rbx + 1]
    or eax, ecx                     ; type
    mov esi, eax                    ; save type

    ; RDLENGTH at [ebx+8..9]
    movzx eax, byte [r12 + rbx + 8]
    shl eax, 8
    movzx ecx, byte [r12 + rbx + 9]
    or eax, ecx                     ; rdlength
    mov edi, eax                    ; save rdlength

    ; Check if TYPE == 1 (A record) and RDLENGTH == 4
    cmp esi, 1
    jne .dns_ans_skip_rr
    cmp edi, 4
    jne .dns_ans_skip_rr

    ; RDATA at [ebx+10..13] = IPv4 address (network byte order = direct copy)
    lea eax, [ebx + 14]            ; need ebx+10+4
    cmp eax, r13d
    jg .dns_resp_done
    mov eax, [r12 + rbx + 10]      ; 4-byte IP address

    ; Store result
    mov [rel dns_result_ip], eax
    mov dword [rel dns_resolved_flag], 1
    mov dword [rel dns_pending], 0
    mov ebx, eax                    ; save IP for logging

    ; Cache the result
    lea rcx, [rel dns_query_name]
    mov edx, ebx
    call dns_cache_insert

    ; Format IP for log
    lea rdi, [rel net_fmt_scratch]
    mov ecx, ebx
    call net_format_ip

    ; Serial: [DNS] resolved: <domain> -> X.X.X.X
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_dns_resolved_fmt]
    lea r9, [rel dns_query_name]
    lea rax, [rel net_fmt_scratch]
    mov [rsp+32], rax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print
    jmp .dns_resp_done

.dns_ans_skip_rr:
    ; Skip this RR: advance by 10 + rdlength
    add ebx, 10
    add ebx, edi
    jmp .dns_parse_answer

.dns_resp_rcode_error:
    ; Serial: [DNS] error: RCODE=N
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_dns_error]
    movzx r9d, byte [r12+3]
    and r9d, 0x0F
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print
    mov dword [rel dns_pending], 0
    jmp .dns_resp_done

.dns_resp_no_answer:
    lea rcx, [rel str_dns_no_answer]
    call serial_print
    mov dword [rel dns_pending], 0

.dns_resp_done:
    add rsp, 48
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; tcp_checksum(ECX=src_ip_dword, EDX=dst_ip_dword, R8=tcp_ptr, R9D=tcp_len)
; Build pseudo-header + TCP segment, compute checksum -> AX
; ============================================================
tcp_checksum:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40                     ; shadow(32) + 8(align)
    ; 8(ret)+32(push)+40(sub)=80, 80%16=0 ✓

    mov r12d, r9d                   ; tcp_len

    ; Build 12-byte pseudo-header in tcp_cksum_buf
    lea rdi, [rel tcp_cksum_buf]
    ; src_ip (4 bytes, raw memory order = network order)
    mov [rdi+0], ecx
    ; dst_ip (4 bytes)
    mov [rdi+4], edx
    ; zero + protocol(6) + tcp_len(big-endian)
    mov byte [rdi+8], 0
    mov byte [rdi+9], 6
    mov eax, r12d
    mov [rdi+10], ah                ; tcp_len high byte
    mov [rdi+11], al                ; tcp_len low byte

    ; Copy TCP header+payload after pseudo-header
    xor ecx, ecx
.tcp_cksum_copy:
    cmp ecx, r12d
    jge .tcp_cksum_compute
    mov al, [r8 + rcx]
    mov [rdi + 12 + rcx], al
    inc ecx
    jmp .tcp_cksum_copy
.tcp_cksum_compute:
    ; ip_checksum(tcp_cksum_buf, 12 + tcp_len)
    lea rcx, [rel tcp_cksum_buf]
    lea edx, [r12d + 12]
    call ip_checksum
    ; result in AX

    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ============================================================
; tcp_send_segment(CL=flags, RDX=payload_ptr, R8D=payload_len)
; Build TCP header + payload, checksum, send via ip_send
; ============================================================
tcp_send_segment:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 48                     ; shadow(32) + 16(locals)
    ; 8(ret)+8(rbp)+48(push)+48(sub)=112, 112%16=0 ✓

    movzx r12d, cl                  ; flags
    mov r13, rdx                    ; payload_ptr
    mov r14d, r8d                   ; payload_len

    ; Build TCP header (20 bytes) in tcp_send_buf
    lea rbx, [rel tcp_send_buf]

    ; Offset 0-1: local port (big-endian)
    movzx eax, word [rel tcp_local_port]
    mov [rbx], ah
    mov [rbx+1], al

    ; Offset 2-3: remote port (big-endian)
    movzx eax, word [rel tcp_remote_port]
    mov [rbx+2], ah
    mov [rbx+3], al

    ; Offset 4-7: seq_num (big-endian)
    mov eax, [rel tcp_seq_num]
    bswap eax
    mov [rbx+4], eax

    ; Offset 8-11: ack_num (big-endian)
    mov eax, [rel tcp_ack_num]
    bswap eax
    mov [rbx+8], eax

    ; Offset 12: data offset = 5 words (20 bytes), upper 4 bits = 0101
    mov byte [rbx+12], 0x50

    ; Offset 13: flags
    mov [rbx+13], r12b

    ; Offset 14-15: window = 8192 (big-endian = 0x20 0x00)
    mov byte [rbx+14], 0x20
    mov byte [rbx+15], 0x00

    ; Offset 16-17: checksum = 0 (placeholder)
    mov word [rbx+16], 0

    ; Offset 18-19: urgent = 0
    mov word [rbx+18], 0

    ; Copy payload after header if payload_len > 0
    test r14d, r14d
    jz .tcp_seg_no_payload
    xor ecx, ecx
.tcp_seg_copy:
    cmp ecx, r14d
    jge .tcp_seg_no_payload
    mov al, [r13 + rcx]
    mov [rbx + 20 + rcx], al
    inc ecx
    jmp .tcp_seg_copy
.tcp_seg_no_payload:

    ; tcp_checksum(src_ip, dst_ip, tcp_send_buf, 20 + payload_len)
    mov ecx, [rel net_our_ip]
    mov edx, [rel tcp_remote_ip]
    mov r8, rbx                     ; tcp_send_buf
    lea r9d, [r14d + 20]           ; total TCP length
    call tcp_checksum

    ; Store checksum at offset 16-17
    lea rbx, [rel tcp_send_buf]
    mov [rbx+16], ax

    ; ip_send(dst_ip, protocol=6, tcp_send_buf, 20 + payload_len)
    mov ecx, [rel tcp_remote_ip]
    mov edx, 6                      ; TCP
    lea r8, [rel tcp_send_buf]
    lea r9d, [r14d + 20]
    call ip_send

    add rsp, 48
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; tcp_connect(ECX=remote_ip, EDX=remote_port)
; Initiate TCP three-way handshake (send SYN)
; ============================================================
tcp_connect:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48                     ; shadow(32) + 16(locals)
    ; 8(ret)+8(rbp)+40(push)+48(sub)=104, 104%16=0 ✓

    ; Store connection params
    mov [rel tcp_remote_ip], ecx
    mov [rel tcp_remote_port], dx
    mov r12d, edx                   ; save remote_port

    ; Pick ephemeral local port: 49152 + (counter++ & 0x3FF)
    movzx eax, word [rel tcp_local_port_counter]
    inc word [rel tcp_local_port_counter]
    and eax, 0x3FF
    add eax, 49152
    mov [rel tcp_local_port], ax

    ; Initial sequence number = timer_count
    mov eax, [rel timer_count]
    mov [rel tcp_seq_num], eax
    mov r13d, eax                   ; save ISN for logging

    ; ack_num = 0
    mov dword [rel tcp_ack_num], 0

    ; Set state
    mov dword [rel tcp_state], TCP_STATE_SYN_SENT
    mov dword [rel tcp_established], 0

    ; Send SYN segment
    mov cl, TCP_SYN                 ; flags
    xor edx, edx                    ; no payload
    xor r8d, r8d                    ; payload_len = 0
    call tcp_send_segment

    ; SYN consumes 1 sequence number
    inc dword [rel tcp_seq_num]

    ; Serial: [TCP] SYN sent to X.X.X.X:port seq=N
    mov ebx, [rel tcp_remote_ip]    ; save IP before format call clobbers
    lea rdi, [rel net_fmt_scratch]
    mov ecx, ebx
    call net_format_ip

    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_tcp_syn_fmt]
    lea r9, [rel net_fmt_scratch]
    movzx eax, r12w                 ; remote_port
    mov [rsp+32], rax
    mov eax, r13d                   ; ISN
    mov [rsp+40], rax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; tcp_send_data(RCX=data_ptr, EDX=data_len) -> void
; Send data over established TCP connection
; ============================================================
tcp_send_data:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 32                     ; shadow only
    ; 8(ret)+8(rbp)+16(push)+32(sub)=64, 64%16=0 ✓

    mov rsi, rcx                    ; data_ptr
    mov ebx, edx                    ; data_len

    cmp dword [rel tcp_state], TCP_STATE_ESTABLISHED
    jne .tsd_done

    ; tcp_send_segment(CL=flags, RDX=payload_ptr, R8D=payload_len)
    mov cl, (TCP_ACK | TCP_PSH)
    mov rdx, rsi                    ; payload_ptr
    mov r8d, ebx                    ; payload_len
    call tcp_send_segment

    ; Advance sequence number
    add [rel tcp_seq_num], ebx

    ; Serial: [TCP] sent N bytes
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_tcp_sent_fmt]
    mov r9d, ebx
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

.tsd_done:
    add rsp, 32
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; http_build_request() -> sets http_req_len
; Build HTTP/1.0 GET request in http_req_buf
; ============================================================
http_build_request:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40                     ; shadow(32) + 8(align)
    ; 8(ret)+8(rbp)+8(push)+40(sub)=64, 64%16=0 ✓

    lea rcx, [rel http_req_buf]
    mov edx, 256
    lea r8, [rel str_http_req_fmt]  ; "GET %s HTTP/1.0\r\nHost: %s\r\n\r\n"
    lea r9, [rel http_path]         ; 1st %s = path
    lea rax, [rel http_host]
    mov [rsp+32], rax               ; 2nd %s = host
    call herb_snprintf

    ; Measure length with herb_strlen
    lea rcx, [rel http_req_buf]
    call herb_strlen
    mov [rel http_req_len], eax

    add rsp, 40
    pop rbx
    pop rbp
    ret

; ============================================================
; http_parse_response() -> sets http_status, prints body to serial
; ============================================================
http_parse_response:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48                     ; shadow(32) + 16(locals)
    ; 8(ret)+8(rbp)+32(push)+48(sub)=96, 96%16=0 ✓

    ; Null-terminate recv buffer
    lea rbx, [rel tcp_recv_buf]
    mov ecx, [rel tcp_recv_len]
    mov byte [rbx + rcx], 0

    ; Parse status code: skip "HTTP/1.x " (9 bytes), read 3 digits
    ; Verify we have at least 12 bytes
    cmp ecx, 12
    jb .hpr_no_status
    ; Status code at offset 9: e.g., "200"
    movzx eax, byte [rbx+9]
    sub eax, '0'
    imul eax, 100
    mov r12d, eax
    movzx eax, byte [rbx+10]
    sub eax, '0'
    imul eax, 10
    add r12d, eax
    movzx eax, byte [rbx+11]
    sub eax, '0'
    add r12d, eax
    mov [rel http_status], r12d

    ; Find "\r\n\r\n" (0x0D 0x0A 0x0D 0x0A) — end of headers
    xor esi, esi                    ; scan index
    mov edi, [rel tcp_recv_len]
    sub edi, 3                      ; need 4 bytes to match
.hpr_scan:
    cmp esi, edi
    jge .hpr_no_body
    cmp byte [rbx + rsi], 0x0D
    jne .hpr_scan_next
    cmp byte [rbx + rsi + 1], 0x0A
    jne .hpr_scan_next
    cmp byte [rbx + rsi + 2], 0x0D
    jne .hpr_scan_next
    cmp byte [rbx + rsi + 3], 0x0A
    jne .hpr_scan_next
    ; Found! Body starts at rsi + 4
    add esi, 4
    jmp .hpr_found_body
.hpr_scan_next:
    inc esi
    jmp .hpr_scan

.hpr_found_body:
    ; body_len = recv_len - body_offset
    mov eax, [rel tcp_recv_len]
    sub eax, esi                    ; body_len
    mov r12d, eax                   ; save body_len (repurpose r12d, status already stored)

    ; Serial: [HTTP] status=N body=N bytes
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_http_status_fmt]
    mov r9d, [rel http_status]
    mov eax, r12d
    mov [rsp+32], rax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    ; Print "[HTTP] body:" header
    lea rcx, [rel str_http_body_hdr]
    call serial_print

    ; Print body (first 500 chars max) — temporarily null-terminate
    lea rcx, [rbx + rsi]           ; body start
    mov eax, r12d
    cmp eax, 500
    jbe .hpr_print_body
    mov eax, 500                    ; cap at 500
.hpr_print_body:
    ; Save byte at cap position, null-terminate, print, restore
    mov edi, eax                    ; cap length
    movzx r8d, byte [rcx + rdi]    ; save original byte
    mov byte [rcx + rdi], 0         ; null-terminate
    call serial_print               ; print body
    lea rcx, [rbx + rsi]           ; re-derive body start (rcx clobbered)
    mov [rcx + rdi], r8b            ; restore byte
    jmp .hpr_done

.hpr_no_status:
.hpr_no_body:
    ; Minimal log if parsing failed
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_http_status_fmt]
    xor r9d, r9d                    ; status=0
    xor eax, eax
    mov [rsp+32], rax               ; body=0
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

.hpr_done:
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; http_get(RCX=host_ptr, RDX=path_ptr)
; Start HTTP GET state machine
; ============================================================
http_get:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40                     ; shadow(32) + 8(align)
    ; 8(ret)+8(rbp)+24(push)+40(sub)=80, 80%16=0 ✓

    mov rsi, rcx                    ; host_ptr
    mov rdi, rdx                    ; path_ptr

    ; Copy host → http_host (up to 63 chars)
    lea rbx, [rel http_host]
    xor ecx, ecx
.hg_copy_host:
    cmp ecx, 63
    jge .hg_host_done
    mov al, [rsi + rcx]
    mov [rbx + rcx], al
    test al, al
    jz .hg_host_null
    inc ecx
    jmp .hg_copy_host
.hg_host_null:
.hg_host_done:
    mov byte [rbx + rcx], 0

    ; Copy path → http_path (up to 127 chars)
    lea rbx, [rel http_path]
    xor ecx, ecx
.hg_copy_path:
    cmp ecx, 127
    jge .hg_path_done
    mov al, [rdi + rcx]
    mov [rbx + rcx], al
    test al, al
    jz .hg_path_null
    inc ecx
    jmp .hg_copy_path
.hg_path_null:
.hg_path_done:
    mov byte [rbx + rcx], 0

    ; Reset receive state
    mov dword [rel tcp_recv_len], 0
    mov dword [rel tcp_recv_done], 0
    mov dword [rel tcp_state], TCP_STATE_CLOSED
    mov dword [rel tcp_established], 0

    ; Check if DNS already resolved
    cmp dword [rel dns_resolved_flag], 0
    je .hg_need_dns

    ; DNS resolved → connect immediately
    mov ecx, [rel dns_result_ip]
    mov edx, 80
    call tcp_connect
    mov dword [rel http_state], HTTP_STATE_CONNECT

    ; Serial: [HTTP] GET host/path
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_http_get_fmt]
    lea r9, [rel http_host]
    lea rax, [rel http_path]
    mov [rsp+32], rax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print
    jmp .hg_done

.hg_need_dns:
    lea rcx, [rel http_host]
    call dns_resolve
    mov dword [rel http_state], HTTP_STATE_DNS

.hg_done:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================
; http_poll_state()
; Called every tick from kernel — advances HTTP state machine
; ============================================================
http_poll_state:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40                     ; shadow(32) + 8(align)
    ; 8(ret)+8(rbp)+8(push)+40(sub)=64, 64%16=0 ✓

    mov eax, [rel http_state]
    test eax, eax
    jz .hps_ret                     ; IDLE — fast exit (most ticks)

    cmp eax, HTTP_STATE_DNS
    je .hps_dns
    cmp eax, HTTP_STATE_CONNECT
    je .hps_connect
    cmp eax, HTTP_STATE_RECV
    je .hps_recv
    cmp eax, HTTP_STATE_DONE
    je .hps_done
    jmp .hps_ret

.hps_dns:
    ; Waiting for DNS resolution
    cmp dword [rel dns_resolved_flag], 0
    je .hps_ret
    ; DNS resolved → connect
    mov ecx, [rel dns_result_ip]
    mov edx, 80
    call tcp_connect
    mov dword [rel http_state], HTTP_STATE_CONNECT
    ; Serial: [HTTP] GET host/path
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_http_get_fmt]
    lea r9, [rel http_host]
    lea rax, [rel http_path]
    mov [rsp+32], rax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print
    jmp .hps_ret

.hps_connect:
    ; Waiting for TCP handshake
    cmp dword [rel tcp_established], 0
    je .hps_ret
    ; Connected → build and send HTTP request
    call http_build_request
    lea rcx, [rel http_req_buf]
    mov edx, [rel http_req_len]
    call tcp_send_data
    mov dword [rel http_state], HTTP_STATE_RECV
    jmp .hps_ret

.hps_recv:
    ; Waiting for server response (FIN sets tcp_recv_done)
    cmp dword [rel tcp_recv_done], 0
    je .hps_ret
    ; Response complete → parse and display
    call http_parse_response
    mov dword [rel http_state], HTTP_STATE_IDLE
    jmp .hps_ret

.hps_done:
    mov dword [rel http_state], HTTP_STATE_IDLE

.hps_ret:
    add rsp, 40
    pop rbx
    pop rbp
    ret

; ============================================================
; tcp_handle_packet(RSI=frame_ptr, ECX=frame_len, EDX=src_ip)
; Parse TCP header and run state machine
; ============================================================
tcp_handle_packet:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 64                     ; shadow(32) + 32(locals)
    ; 8(ret)+8(rbp)+48(push)+64(sub)=128, 128%16=0 ✓

    mov r12, rsi                    ; frame_ptr
    mov r13d, ecx                   ; frame_len
    mov [rsp+56], edx               ; src_ip at [rsp+56]

    ; TCP header starts at 14 (eth) + IHL*4
    movzx eax, byte [r12 + 14]     ; version_ihl
    and eax, 0x0F                   ; IHL
    shl eax, 2                      ; IHL * 4
    add eax, 14                     ; + ethernet header
    mov ebx, eax                    ; ebx = tcp_offset

    ; Bounds check: need at least 20 bytes for TCP header
    lea ecx, [ebx + 20]
    cmp ecx, r13d
    ja .tcp_rx_done

    ; Parse TCP header fields (big-endian)
    ; src_port at [frame + tcp_offset + 0..1]
    movzx r14d, byte [r12 + rbx]
    shl r14d, 8
    movzx eax, byte [r12 + rbx + 1]
    or r14d, eax                    ; r14d = src_port

    ; dst_port at [frame + tcp_offset + 2..3]
    movzx edi, byte [r12 + rbx + 2]
    shl edi, 8
    movzx eax, byte [r12 + rbx + 3]
    or edi, eax                     ; edi = dst_port

    ; seq_num at [frame + tcp_offset + 4..7]
    mov eax, [r12 + rbx + 4]
    bswap eax
    mov [rsp+48], eax               ; peer_seq at [rsp+48]

    ; ack_num at [frame + tcp_offset + 8..11]
    mov eax, [r12 + rbx + 8]
    bswap eax
    mov [rsp+52], eax               ; peer_ack at [rsp+52]

    ; flags at [frame + tcp_offset + 13]
    movzx esi, byte [r12 + rbx + 13]  ; esi = flags

    ; window at [frame + tcp_offset + 14..15]
    movzx eax, byte [r12 + rbx + 14]
    shl eax, 8
    movzx ecx, byte [r12 + rbx + 15]
    or eax, ecx                     ; eax = window
    mov [rsp+44], ax                ; peer_window at [rsp+44]

    ; data_offset (upper 4 bits of byte 12) * 4
    movzx eax, byte [r12 + rbx + 12]
    shr eax, 4
    shl eax, 2                      ; TCP header len
    ; payload_len = frame_len - tcp_offset - tcp_header_len
    mov ecx, r13d
    sub ecx, ebx
    sub ecx, eax                    ; ecx = TCP payload len
    jb .tcp_rx_done                 ; negative = malformed
    mov [rsp+40], ecx               ; payload_len at [rsp+40]
    mov [rsp+60], ecx               ; BACKUP at [rsp+60] (safe from snprintf clobber)

    ; Save dst_port before net_format_ip clobbers edi (Discovery 69)
    mov r13d, edi                   ; r13d = dst_port (done with frame_len)

    ; Serial log: [TCP] from X.X.X.X:port flags=N
    ; esi = flags (callee-saved, preserved across calls)
    mov ecx, [rsp+56]              ; src_ip
    lea rdi, [rel net_fmt_scratch]
    call net_format_ip

    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_tcp_rx_fmt]
    lea r9, [rel net_fmt_scratch]
    movzx eax, r14w                 ; src_port
    mov [rsp+32], rax
    movzx eax, si                   ; flags
    mov [rsp+40], rax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    ; Check dst_port matches our local port
    movzx eax, word [rel tcp_local_port]
    cmp r13d, eax
    jne .tcp_rx_done                ; not for us

    ; State machine dispatch
    mov eax, [rel tcp_state]

    cmp eax, TCP_STATE_SYN_SENT
    je .tcp_state_syn_sent

    cmp eax, TCP_STATE_ESTABLISHED
    je .tcp_state_established

    cmp eax, TCP_STATE_LAST_ACK
    je .tcp_state_last_ack

    ; Default: ignore
    jmp .tcp_rx_done

.tcp_state_syn_sent:
    ; Check for RST
    test esi, TCP_RST
    jnz .tcp_got_rst

    ; Check flags == SYN|ACK (0x12)
    mov eax, esi
    and eax, (TCP_SYN | TCP_ACK)
    cmp eax, (TCP_SYN | TCP_ACK)
    jne .tcp_rx_done                ; not SYN-ACK, ignore

    ; Verify ack_num == our tcp_seq_num
    mov eax, [rsp+52]              ; peer_ack
    cmp eax, [rel tcp_seq_num]
    jne .tcp_rx_done                ; wrong ack

    ; Store server's seq+1 as our tcp_ack_num
    mov eax, [rsp+48]              ; peer_seq
    inc eax
    mov [rel tcp_ack_num], eax

    ; Store server's window
    mov ax, [rsp+44]
    mov [rel tcp_remote_win], ax

    ; Update state
    mov dword [rel tcp_state], TCP_STATE_ESTABLISHED
    mov dword [rel tcp_established], 1

    ; Serial: [TCP] SYN-ACK from X.X.X.X seq=N ack=N
    ; net_fmt_scratch already has formatted IP from above
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_tcp_synack_fmt]
    lea r9, [rel net_fmt_scratch]
    mov eax, [rsp+48]              ; peer_seq
    mov [rsp+32], rax
    mov eax, [rsp+52]              ; peer_ack
    mov [rsp+40], rax
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print

    ; Send ACK to complete handshake
    mov cl, TCP_ACK
    xor edx, edx
    xor r8d, r8d
    call tcp_send_segment

    ; Serial: [TCP] ACK sent, connection ESTABLISHED
    lea rcx, [rel str_tcp_ack_fmt]
    call serial_print

    jmp .tcp_rx_done

.tcp_got_rst:
    mov dword [rel tcp_state], TCP_STATE_CLOSED
    mov dword [rel tcp_established], 0
    lea rcx, [rel str_tcp_rst_fmt]
    call serial_print
    jmp .tcp_rx_done

.tcp_state_established:
    ; Check RST first
    test esi, TCP_RST
    jnz .tcp_got_rst

    ; Get payload_len from backup slot (safe from serial log clobber)
    mov ecx, [rsp+60]              ; payload_len

    ; --- Handle incoming data ---
    test ecx, ecx
    jz .tcp_est_check_fin           ; no payload, check FIN

    ; Verify in-order delivery: peer_seq == tcp_ack_num
    mov eax, [rsp+48]              ; peer_seq
    cmp eax, [rel tcp_ack_num]
    jne .tcp_est_ooo                ; out-of-order → drop

    ; Bounds check: don't overflow recv buffer
    mov eax, [rel tcp_recv_len]
    add eax, ecx                    ; new total
    cmp eax, TCP_RECV_BUF_SIZE
    ja .tcp_est_overflow

    ; Compute payload pointer: frame_ptr + tcp_offset + tcp_header_len
    ; ebx = tcp_offset (callee-saved, still valid)
    ; re-derive tcp_header_len from data_offset byte
    ; Use r14 for payload pointer to preserve esi=flags for FIN check
    movzx eax, byte [r12 + rbx + 12]
    shr eax, 4
    shl eax, 2                      ; TCP header len in eax
    lea r14, [r12 + rbx]           ; TCP header start
    add r14, rax                    ; r14 = payload pointer

    ; Copy payload to tcp_recv_buf + tcp_recv_len
    lea rdi, [rel tcp_recv_buf]
    mov eax, [rel tcp_recv_len]
    add rdi, rax                    ; rdi = dest
    ; ecx = payload_len, r14 = src
    xor edx, edx
.tcp_copy_payload:
    cmp edx, ecx
    jge .tcp_copy_done
    mov al, [r14 + rdx]
    mov [rdi + rdx], al
    inc edx
    jmp .tcp_copy_payload
.tcp_copy_done:

    ; Update recv_len and ack_num
    add [rel tcp_recv_len], ecx
    add [rel tcp_ack_num], ecx

    ; Save payload_len in ebx (tcp_offset no longer needed)
    mov ebx, ecx                    ; save payload_len in ebx
    mov cl, TCP_ACK
    xor edx, edx
    xor r8d, r8d
    call tcp_send_segment

    ; Serial: [TCP] received N bytes, ACKed
    lea rcx, [rel net_msg_buf]
    mov edx, 128
    lea r8, [rel str_tcp_recv_fmt]
    mov r9d, ebx                    ; payload_len
    call herb_snprintf
    lea rcx, [rel net_msg_buf]
    call serial_print
    jmp .tcp_est_check_fin          ; also check FIN (may be combined with data)

.tcp_est_ooo:
    lea rcx, [rel str_tcp_ooo_fmt]
    call serial_print
    jmp .tcp_rx_done

.tcp_est_overflow:
    lea rcx, [rel str_tcp_overflow]
    call serial_print
    jmp .tcp_est_check_fin          ; still check FIN

.tcp_est_check_fin:
    ; Check if server sent FIN
    test esi, TCP_FIN
    jz .tcp_rx_done                 ; no FIN, done

    ; FIN received — ACK it and send our own FIN
    inc dword [rel tcp_ack_num]     ; FIN consumes 1 seq number

    ; Send FIN+ACK combined
    mov cl, (TCP_FIN | TCP_ACK)
    xor edx, edx
    xor r8d, r8d
    call tcp_send_segment
    inc dword [rel tcp_seq_num]     ; our FIN consumes 1 seq number

    ; Mark recv as done, transition to LAST_ACK
    mov dword [rel tcp_recv_done], 1
    mov dword [rel tcp_state], TCP_STATE_LAST_ACK

    lea rcx, [rel str_tcp_fin_fmt]
    call serial_print
    jmp .tcp_rx_done

.tcp_state_last_ack:
    ; Waiting for server's ACK of our FIN
    test esi, TCP_RST
    jnz .tcp_got_rst
    test esi, TCP_ACK
    jz .tcp_rx_done
    ; Connection fully closed
    mov dword [rel tcp_state], TCP_STATE_CLOSED
    mov dword [rel tcp_established], 0
    lea rcx, [rel str_tcp_closed_fmt]
    call serial_print
    jmp .tcp_rx_done

.tcp_rx_done:
    add rsp, 64
    pop r14
    pop r13
    pop r12
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
str_net_arp_fail:
    db "[NET] ARP send failed", 10, 0
str_arp_req_fmt:
    db "[ARP] request: who has %s?", 10, 0
str_arp_reply_fmt:
    db "[ARP] reply: %s is at %s", 10, 0
str_arp_reply_sent:
    db "[ARP] reply sent", 10, 0
str_arp_reply_to_req:
    db "[ARP] responding to request for our IP", 10, 0
str_arp_timeout:
    db "[ARP] gateway resolution timeout", 10, 0
str_arp_gw_resolved:
    db "[ARP] gateway resolved", 10, 0
str_net_gw_arp_sent:
    db "[NET] gateway ARP sent, waiting for reply", 10, 0
net_fmt_rx:
    db "[NET] RX len=%d ethertype=%d", 10, 0
str_ip_no_mac:
    db "[IP] send failed: no gateway MAC in ARP cache", 10, 0
str_ip_rx_fmt:
    db "[IP] from %s proto=%d len=%d", 10, 0
str_ping_sent_fmt:
    db "[PING] sent to %s seq=%d", 10, 0
str_ping_reply_fmt:
    db "[PING] reply from %s seq=%d", 10, 0
str_ping_time_fmt:
    db "[PING] time=%dms", 10, 0
str_ping_respond_fmt:
    db "[PING] responding to %s", 10, 0
str_udp_rx_fmt:
    db "[UDP] from %s:%d -> port %d", 10, 0
str_udp_sent_fmt:
    db "[UDP] sent to %s:%d len=%d", 10, 0
str_udp_no_listener:
    db "[UDP] no listener on port %d", 10, 0
str_dns_query_fmt:
    db "[DNS] query: %s", 10, 0
str_dns_resolved_fmt:
    db "[DNS] resolved: %s -> %s", 10, 0
str_dns_error:
    db "[DNS] error: RCODE=%d", 10, 0
str_dns_no_answer:
    db "[DNS] no answer", 10, 0
str_dns_cached_fmt:
    db "[DNS] cached: %s -> %s", 10, 0
str_tcp_syn_fmt:    db "[TCP] SYN sent to %s:%d seq=%d", 10, 0
str_tcp_synack_fmt: db "[TCP] SYN-ACK from %s seq=%d ack=%d", 10, 0
str_tcp_ack_fmt:    db "[TCP] ACK sent, connection ESTABLISHED", 10, 0
str_tcp_rst_fmt:    db "[TCP] connection refused (RST)", 10, 0
str_tcp_rx_fmt:     db "[TCP] from %s:%d flags=%d", 10, 0
str_tcp_sent_fmt:    db "[TCP] sent %d bytes", 10, 0
str_tcp_recv_fmt:    db "[TCP] received %d bytes, ACKed", 10, 0
str_tcp_fin_fmt:     db "[TCP] FIN received, closing", 10, 0
str_tcp_closed_fmt:  db "[TCP] connection closed", 10, 0
str_tcp_ooo_fmt:     db "[TCP] seq mismatch, dropped", 10, 0
str_tcp_overflow:    db "[TCP] recv buffer full", 10, 0
str_http_get_fmt:    db "[HTTP] GET %s%s", 10, 0
str_http_status_fmt: db "[HTTP] status=%d body=%d bytes", 10, 0
str_http_body_hdr:   db "[HTTP] body:", 10, 0
str_http_req_fmt:    db "GET %s HTTP/1.0", 13, 10, "Host: %s", 13, 10, 13, 10, 0
str_http_slash:      db "/", 0

dns_server_ip:
    dd 0x0302000A               ; 10.0.2.3 in little-endian

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
net_pci_slot:   resd 1                      ; PCI slot number
net_rx_head:    resd 1                      ; software RX head index
net_tx_tail:    resd 1                      ; software TX tail index
net_rx_flag:    resd 1                      ; set by ISR, cleared by poll
net_present:    resd 1                      ; 1 if E1000 found
net_msg_buf:    resb 128                    ; snprintf buffer

; Network config
net_our_ip:     resd 1                      ; 10.0.2.15 = 0x0F02000A
net_gateway_ip: resd 1                      ; 10.0.2.2 = 0x0202000A
net_subnet_mask: resd 1                     ; 255.255.255.0

; ARP cache (16 entries)
ARP_CACHE_SIZE equ 16
arp_cache_ip:   resd 16                     ; IP addresses
arp_cache_mac:  resb 96                     ; MAC addresses (6 bytes × 16)
arp_cache_valid: resb 16                    ; 0=empty, 1=valid
arp_cache_count: resd 1

; IP send buffer
ip_send_buf:    resb 1518                   ; max Ethernet frame
ip_id_counter:  resw 1                      ; IPv4 identification counter

; ICMP buffers
icmp_buf:       resb 64                     ; ICMP echo request build buffer
icmp_reply_buf: resb 128                    ; ICMP echo reply build buffer

; Scratch buffer for formatting
net_fmt_scratch: resb 64

; UDP
UDP_MAX_LISTENERS equ 8
udp_send_buf:       resb 1480           ; max UDP in single Ethernet frame
udp_listener_ports: resw UDP_MAX_LISTENERS ; port numbers (0=empty)
udp_listener_funcs: resq UDP_MAX_LISTENERS ; handler function pointers

; DNS
DNS_CACHE_SIZE equ 8
DNS_SRC_PORT   equ 4444

dns_query_buf:      resb 256        ; outgoing DNS query buffer
dns_pending:        resd 1          ; 1 = waiting for response
dns_txid:           resw 1          ; current transaction ID
dns_txid_counter:   resw 1          ; incrementing counter
dns_result_ip:      resd 1          ; resolved IP (filled by response handler)
dns_resolved_flag:  resd 1          ; 1 = resolution complete
dns_query_name:     resb 64         ; copy of queried domain name (for logging)

; DNS cache (8 entries)
dns_cache_names:    resb 512        ; 8 * 64 bytes — domain name strings
dns_cache_ips:      resd 8          ; 8 * 4 bytes — resolved IP addresses
dns_cache_count:    resd 1          ; number of valid entries (circular insert)

; TCP (single connection)
TCP_STATE_CLOSED      equ 0
TCP_STATE_SYN_SENT    equ 1
TCP_STATE_ESTABLISHED equ 2

TCP_FIN equ 0x01
TCP_SYN equ 0x02
TCP_RST equ 0x04
TCP_ACK equ 0x10
TCP_PSH equ 0x08

TCP_STATE_CLOSE_WAIT  equ 3
TCP_STATE_LAST_ACK    equ 4

tcp_state:              resd 1      ; current state (TCP_STATE_*)
tcp_local_port:         resw 1      ; our ephemeral port
tcp_remote_port:        resw 1      ; server port (e.g. 80)
tcp_remote_ip:          resd 1      ; server IP
tcp_seq_num:            resd 1      ; our next sequence number
tcp_ack_num:            resd 1      ; next expected byte from server
tcp_remote_win:         resw 1      ; server's advertised window
tcp_local_port_counter: resw 1      ; incrementing ephemeral port counter
tcp_established:        resd 1      ; 1 = connection established (for kernel to check)
tcp_send_buf:           resb 1500   ; TCP segment build buffer
tcp_cksum_buf:          resb 1540   ; pseudo-header + segment for checksum

; TCP receive buffer (16KB)
TCP_RECV_BUF_SIZE equ 16384
tcp_recv_buf:       resb 16384
tcp_recv_len:       resd 1          ; bytes received so far
tcp_recv_done:      resd 1          ; 1 = server closed (FIN received)

; HTTP state machine
HTTP_STATE_IDLE     equ 0
HTTP_STATE_DNS      equ 1
HTTP_STATE_CONNECT  equ 2
HTTP_STATE_SEND     equ 3
HTTP_STATE_RECV     equ 4
HTTP_STATE_DONE     equ 5

http_state:         resd 1          ; current HTTP state
http_host:          resb 64         ; host string copy
http_path:          resb 128        ; path string copy
http_req_buf:       resb 256        ; built HTTP request
http_req_len:       resd 1          ; request length
http_status:        resd 1          ; parsed HTTP status code
