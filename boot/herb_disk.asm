; boot/herb_disk.asm — ATA PIO disk driver + bitmap filesystem
;
; Session 75: Persistent storage for HERB OS.
; Session 80: Filesystem hardening — free-sector bitmap, overwrite,
;             256 entries, 8MB disk, "/" in filenames.
;
; ATA PIO driver targets drive 1 (slave) — the data disk (herb_disk.img).
; Bitmap filesystem: superblock v2 + directory (256 entries) + bitmap + data.
;
; Assembled with: nasm -f win64 herb_disk.asm -o herb_disk.o

[bits 64]
default rel

; ============================================================
; GLOBALS
; ============================================================

; ATA PIO driver
global disk_identify
global disk_read_sector
global disk_write_sector

; Filesystem
global fs_init
global fs_create
global fs_read
global fs_delete
global fs_list

; State
global disk_present
global disk_total_sectors
global fs_initialized

; ============================================================
; EXTERNS
; ============================================================

extern serial_print
extern serial_print_int
extern herb_snprintf
extern herb_memset
extern herb_memcpy
extern herb_strcmp
extern herb_strlen
extern outb, inb, io_wait
extern shell_output_print

; ============================================================
; CONSTANTS
; ============================================================

%define ATA_DATA        0x1F0
%define ATA_ERROR       0x1F1
%define ATA_SEC_COUNT   0x1F2
%define ATA_LBA_LO     0x1F3
%define ATA_LBA_MID    0x1F4
%define ATA_LBA_HI     0x1F5
%define ATA_DRIVE_HEAD  0x1F6
%define ATA_STATUS      0x1F7
%define ATA_COMMAND     0x1F7
%define ATA_ALT_STATUS  0x3F6

%define ATA_CMD_IDENTIFY    0xEC
%define ATA_CMD_READ        0x20
%define ATA_CMD_WRITE       0x30
%define ATA_CMD_FLUSH       0xE7

%define ATA_STATUS_BSY  0x80
%define ATA_STATUS_DRQ  0x08
%define ATA_STATUS_ERR  0x01

; Filesystem constants (v2)
%define FS_MAGIC          0x48455242      ; "HERB"
%define FS_VERSION        2
%define FS_DIR_SECTORS    24
%define FS_DIR_START      1
%define FS_BITMAP_START   25
%define FS_BITMAP_SECTORS 4
%define FS_DATA_START     29
%define FS_TOTAL_SECTORS  16384
%define FS_MAX_ENTRIES    256
%define FS_ENTRY_SIZE     48
%define FS_NAME_LEN       32

; ============================================================
; BSS
; ============================================================

section .bss
align 16
disk_sector_buf:    resb 512        ; scratch buffer for identify/self-test
fs_superblock:      resb 512        ; cached superblock (sector 0)
fs_dir_buf:         resb 12288      ; cached directory (sectors 1-24, 256 entries × 48)
fs_bitmap_buf:      resb 2048       ; free-sector bitmap (sectors 25-28, 16384 bits)
fs_data_buf:        resb 4096       ; general-purpose data buffer (8 sectors)
global fs_data_buf

align 4
disk_present:       resd 1          ; 1 if ATA slave detected
disk_total_sectors: resd 1          ; LBA28 sector count from IDENTIFY
fs_initialized:     resd 1          ; 1 after fs_init succeeds
fs_output_scratch:  resb 80         ; scratch for shell output formatting

; ============================================================
; READ-ONLY DATA
; ============================================================

section .rdata
str_disk_found:     db "[DISK] found, ", 0
str_disk_sectors:   db " sectors", 10, 0
str_disk_none:      db "[DISK] no slave drive detected", 10, 0
str_disk_not_ata:   db "[DISK] slave is not ATA", 10, 0
str_disk_selftest:  db "[DISK] self-test OK", 10, 0
str_disk_selftest_f:db "[DISK] self-test FAIL", 10, 0
str_fs_init:        db "[FS] initialized, ", 0
str_fs_files:       db " files, ", 0
str_fs_free:        db " free sectors", 10, 0
str_fs_formatted:   db "[FS] formatted fresh disk", 10, 0
str_fs_saved:       db '[FS] saved "', 0
str_fs_saved_mid:   db '" (', 0
str_fs_saved_end:   db " bytes)", 10, 0
str_fs_read_hdr:    db '[FS] read "', 0
str_fs_read_mid:    db '" (', 0
str_fs_read_end:    db " bytes)", 10, 0
str_fs_deleted:     db '[FS] deleted "', 0
str_fs_deleted_end: db '"', 10, 0
str_fs_list_hdr:    db "[FS] files:", 10, 0
str_fs_list_entry:  db "  ", 0
str_fs_list_size:   db " (", 0
str_fs_list_bytes:  db " bytes)", 10, 0
str_fs_list_count:  db "[FS] ", 0
str_fs_list_total:  db " files total", 10, 0
str_fs_err_full:    db "[FS] error: disk full", 10, 0
str_fs_err_nf:      db "[FS] error: file not found", 10, 0
str_fs_err_nodisk:  db "[FS] error: no disk", 10, 0
str_fs_out_fmt:     db "  %s (%d bytes)", 0
str_fs_err_nodir:   db "[FS] error: directory full", 10, 0
str_fs_migrate:     db "[FS] migrating v1 -> v2, reformatting", 10, 0

; ============================================================
; TEXT — ATA PIO DRIVER
; ============================================================

section .text

; ---- disk_identify() → 0 success, -1 no disk ----
; Detects ATA slave drive (drive 1) via IDENTIFY command.
; No args. Returns EAX = 0 on success, -1 on failure.
; Stack: push rbp + sub rsp 48. 8+8+48=64. 64%16=0. Good.
disk_identify:
    push rbp
    mov rbp, rsp
    sub rsp, 48

    ; Default: no disk
    mov dword [rel disk_present], 0
    mov dword [rel disk_total_sectors], 0

    ; Select drive 1 (slave): outb(0x1F6, 0xB0)
    mov ecx, ATA_DRIVE_HEAD
    mov edx, 0xB0
    call outb

    ; Zero sector count and LBA ports
    mov ecx, ATA_SEC_COUNT
    xor edx, edx
    call outb
    mov ecx, ATA_LBA_LO
    xor edx, edx
    call outb
    mov ecx, ATA_LBA_MID
    xor edx, edx
    call outb
    mov ecx, ATA_LBA_HI
    xor edx, edx
    call outb

    ; Send IDENTIFY command
    mov ecx, ATA_COMMAND
    mov edx, ATA_CMD_IDENTIFY
    call outb

    ; Read status — if 0, no drive
    mov ecx, ATA_STATUS
    call inb
    test al, al
    jz .di_no_drive

    ; Poll: wait for BSY to clear
.di_poll_bsy:
    mov ecx, ATA_STATUS
    call inb
    test al, ATA_STATUS_BSY
    jnz .di_poll_bsy

    ; Check LBAmid and LBAhi — if non-zero, not ATA
    mov ecx, ATA_LBA_MID
    call inb
    test al, al
    jnz .di_not_ata
    mov ecx, ATA_LBA_HI
    call inb
    test al, al
    jnz .di_not_ata

    ; Poll: wait for DRQ or ERR
.di_poll_drq:
    mov ecx, ATA_STATUS
    call inb
    test al, ATA_STATUS_ERR
    jnz .di_not_ata
    test al, ATA_STATUS_DRQ
    jz .di_poll_drq

    ; Read 256 words (512 bytes) from data port into disk_sector_buf
    lea rdi, [rel disk_sector_buf]
    mov ecx, 256
    mov dx, ATA_DATA
    rep insw

    ; Extract total LBA28 sectors from words 60-61 (offset 120, dword)
    lea rax, [rel disk_sector_buf]
    mov eax, [rax + 120]
    mov [rel disk_total_sectors], eax
    mov dword [rel disk_present], 1

    ; Serial: "[DISK] found, N sectors"
    lea rcx, [rel str_disk_found]
    call serial_print
    mov ecx, [rel disk_total_sectors]
    call serial_print_int
    lea rcx, [rel str_disk_sectors]
    call serial_print

    ; Self-test: write pattern to last sector, read back, compare
    call disk_self_test

    xor eax, eax           ; return 0 = success
    jmp .di_done

.di_no_drive:
    lea rcx, [rel str_disk_none]
    call serial_print
    mov eax, -1
    jmp .di_done

.di_not_ata:
    lea rcx, [rel str_disk_not_ata]
    call serial_print
    mov eax, -1

.di_done:
    add rsp, 48
    pop rbp
    ret


; ---- disk_self_test() ----
; Internal. Write 0xDEADBEEF pattern to last sector, read back, compare.
; Stack: push rbp,rbx + sub rsp 40. 8+16+40=64. 64%16=0. Good.
disk_self_test:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    ; Write test pattern into first 4 bytes of fs_data_buf
    lea rbx, [rel fs_data_buf]
    mov dword [rbx], 0xDEADBEEF
    ; Zero rest of sector
    lea rcx, [rbx + 4]
    xor edx, edx
    mov r8d, 508
    call herb_memset

    ; Write to last sector (FS_TOTAL_SECTORS - 1)
    mov ecx, FS_TOTAL_SECTORS - 1
    mov rdx, rbx
    call disk_write_sector
    test eax, eax
    jnz .dst_fail

    ; Clear the buffer
    mov rcx, rbx
    xor edx, edx
    mov r8d, 512
    call herb_memset

    ; Read last sector back into disk_sector_buf
    mov ecx, FS_TOTAL_SECTORS - 1
    lea rdx, [rel disk_sector_buf]
    call disk_read_sector
    test eax, eax
    jnz .dst_fail

    ; Compare first 4 bytes
    lea rax, [rel disk_sector_buf]
    cmp dword [rax], 0xDEADBEEF
    jne .dst_fail

    lea rcx, [rel str_disk_selftest]
    call serial_print
    jmp .dst_done

.dst_fail:
    lea rcx, [rel str_disk_selftest_f]
    call serial_print

.dst_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret


; ---- disk_read_sector(lba, buffer) → 0 success, -1 error ----
; Read one 512-byte sector from ATA slave drive.
; Args: ECX = LBA (u32), RDX = buffer ptr
; Returns: EAX = 0 success, -1 error
; Stack: push rbp,rbx,rsi + sub rsp 48. 8+24+48=80. 80%16=0. Good.
disk_read_sector:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 48

    mov ebx, ecx           ; save LBA
    mov rsi, rdx            ; save buffer ptr

    ; Select slave + LBA mode: 0xF0 | (lba >> 24 & 0x0F)
    mov eax, ebx
    shr eax, 24
    and eax, 0x0F
    or eax, 0xF0
    mov edx, eax
    mov ecx, ATA_DRIVE_HEAD
    call outb

    ; Sector count = 1
    mov ecx, ATA_SEC_COUNT
    mov edx, 1
    call outb

    ; LBA low byte
    mov ecx, ATA_LBA_LO
    mov edx, ebx
    and edx, 0xFF
    call outb

    ; LBA mid byte
    mov ecx, ATA_LBA_MID
    mov eax, ebx
    shr eax, 8
    and eax, 0xFF
    mov edx, eax
    call outb

    ; LBA high byte
    mov ecx, ATA_LBA_HI
    mov eax, ebx
    shr eax, 16
    and eax, 0xFF
    mov edx, eax
    call outb

    ; Send READ SECTORS command
    mov ecx, ATA_COMMAND
    mov edx, ATA_CMD_READ
    call outb

    ; 400ns delay: read alt status once
    mov ecx, ATA_ALT_STATUS
    call inb

    ; Poll: wait BSY clear
.drs_poll:
    mov ecx, ATA_STATUS
    call inb
    test al, ATA_STATUS_ERR
    jnz .drs_error
    test al, ATA_STATUS_BSY
    jnz .drs_poll
    test al, ATA_STATUS_DRQ
    jz .drs_poll

    ; Read 256 words from data port
    mov rdi, rsi            ; buffer
    mov ecx, 256
    mov dx, ATA_DATA
    rep insw

    xor eax, eax           ; return 0
    jmp .drs_done

.drs_error:
    mov eax, -1

.drs_done:
    add rsp, 48
    pop rsi
    pop rbx
    pop rbp
    ret


; ---- disk_write_sector(lba, buffer) → 0 success, -1 error ----
; Write one 512-byte sector to ATA slave drive.
; Args: ECX = LBA (u32), RDX = buffer ptr
; Returns: EAX = 0 success, -1 error
; Stack: push rbp,rbx,rsi + sub rsp 48. 8+24+48=80. 80%16=0. Good.
disk_write_sector:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 48

    mov ebx, ecx           ; save LBA
    mov rsi, rdx            ; save buffer ptr

    ; Select slave + LBA mode
    mov eax, ebx
    shr eax, 24
    and eax, 0x0F
    or eax, 0xF0
    mov edx, eax
    mov ecx, ATA_DRIVE_HEAD
    call outb

    ; Sector count = 1
    mov ecx, ATA_SEC_COUNT
    mov edx, 1
    call outb

    ; LBA low byte
    mov ecx, ATA_LBA_LO
    mov edx, ebx
    and edx, 0xFF
    call outb

    ; LBA mid byte
    mov ecx, ATA_LBA_MID
    mov eax, ebx
    shr eax, 8
    and eax, 0xFF
    mov edx, eax
    call outb

    ; LBA high byte
    mov ecx, ATA_LBA_HI
    mov eax, ebx
    shr eax, 16
    and eax, 0xFF
    mov edx, eax
    call outb

    ; Send WRITE SECTORS command
    mov ecx, ATA_COMMAND
    mov edx, ATA_CMD_WRITE
    call outb

    ; 400ns delay
    mov ecx, ATA_ALT_STATUS
    call inb

    ; Poll: wait BSY clear, DRQ set
.dws_poll:
    mov ecx, ATA_STATUS
    call inb
    test al, ATA_STATUS_ERR
    jnz .dws_error
    test al, ATA_STATUS_BSY
    jnz .dws_poll
    test al, ATA_STATUS_DRQ
    jz .dws_poll

    ; Write 256 words to data port
    mov rsi, rsi            ; source buffer (already in rsi)
    mov ecx, 256
    mov dx, ATA_DATA
    rep outsw

    ; Cache flush
    mov ecx, ATA_COMMAND
    mov edx, ATA_CMD_FLUSH
    call outb

    ; Poll: wait BSY clear after flush
.dws_flush_poll:
    mov ecx, ATA_STATUS
    call inb
    test al, ATA_STATUS_BSY
    jnz .dws_flush_poll

    xor eax, eax           ; return 0
    jmp .dws_done

.dws_error:
    mov eax, -1

.dws_done:
    add rsp, 48
    pop rsi
    pop rbx
    pop rbp
    ret


; ============================================================
; TEXT — BITMAP FILESYSTEM (v2)
; ============================================================

; Superblock v2 layout (sector 0, 512 bytes):
;   Offset 0:   u32 magic (0x48455242 = "HERB")
;   Offset 4:   u16 version (2)
;   Offset 6:   u16 entry_count (active files)
;   Offset 8:   u32 total_sectors (16384)
;   Offset 12:  u32 bitmap_start (25)
;   Offset 16:  u32 bitmap_sectors (4)
;   Offset 20:  u32 data_start (29)
;   Offset 24:  488 bytes reserved (zero)
;
; Directory entry (48 bytes, 256 per 24 sectors):
;   Offset 0:   char[32] filename (null-terminated, max 31 chars)
;   Offset 32:  u32 start_sector
;   Offset 36:  u32 size_bytes
;   Offset 40:  u32 flags (bit 0: active)
;   Offset 44:  u32 reserved

%define SB_MAGIC        0
%define SB_VERSION      4
%define SB_ENTRY_COUNT  6
%define SB_TOTAL_SECTORS 8
%define SB_BITMAP_START 12
%define SB_BITMAP_SECTS 16
%define SB_DATA_START   20

%define DE_NAME         0
%define DE_START        32
%define DE_SIZE         36
%define DE_FLAGS        40


; ============================================================
; BITMAP PRIMITIVES
; ============================================================

; ---- fs_read_bitmap() → EAX = 0/-1 ----
; Read 4 bitmap sectors into fs_bitmap_buf.
; Stack: push rbp,rbx + sub rsp 40. 8+16+40=64. 64%16=0. Good.
fs_read_bitmap:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    xor ebx, ebx           ; i = 0
.frb_loop:
    cmp ebx, FS_BITMAP_SECTORS
    jge .frb_ok

    lea ecx, [ebx + FS_BITMAP_START]  ; LBA
    lea rdx, [rel fs_bitmap_buf]
    lea rax, [rbx * 8]
    shl rax, 6                        ; * 512
    add rdx, rax
    call disk_read_sector
    test eax, eax
    jnz .frb_error

    inc ebx
    jmp .frb_loop

.frb_ok:
    xor eax, eax
    jmp .frb_done
.frb_error:
    mov eax, -1
.frb_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret


; ---- fs_write_bitmap() → EAX = 0/-1 ----
; Write fs_bitmap_buf to disk (4 sectors), then superblock.
; Stack: push rbp,rbx + sub rsp 40. 8+16+40=64. 64%16=0. Good.
fs_write_bitmap:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    xor ebx, ebx
.fwb_loop:
    cmp ebx, FS_BITMAP_SECTORS
    jge .fwb_super

    lea ecx, [ebx + FS_BITMAP_START]
    lea rdx, [rel fs_bitmap_buf]
    lea rax, [rbx * 8]
    shl rax, 6
    add rdx, rax
    call disk_write_sector
    test eax, eax
    jnz .fwb_error

    inc ebx
    jmp .fwb_loop

.fwb_super:
    ; Write superblock
    xor ecx, ecx
    lea rdx, [rel fs_superblock]
    call disk_write_sector
    test eax, eax
    jnz .fwb_error

    xor eax, eax
    jmp .fwb_done
.fwb_error:
    mov eax, -1
.fwb_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret


; ---- fs_bitmap_set(ECX=sector) ----
; Set bit in bitmap (mark allocated). Leaf function.
fs_bitmap_set:
    mov eax, ecx
    shr eax, 3              ; byte_idx = sector >> 3
    lea rdx, [rel fs_bitmap_buf]
    mov ecx, ecx            ; keep original sector in ecx
    and ecx, 7              ; bit_idx = sector & 7
    mov r8d, 1
    shl r8d, cl             ; mask = 1 << bit_idx
    or byte [rdx + rax], r8b
    ret


; ---- fs_bitmap_clear(ECX=sector) ----
; Clear bit in bitmap (mark free). Leaf function.
fs_bitmap_clear:
    mov eax, ecx
    shr eax, 3
    lea rdx, [rel fs_bitmap_buf]
    and ecx, 7
    mov r8d, 1
    shl r8d, cl
    not r8b
    and byte [rdx + rax], r8b
    ret


; ---- fs_bitmap_test(ECX=sector) → EAX = 0/1 ----
; Test if sector is allocated. Leaf function.
fs_bitmap_test:
    mov eax, ecx
    shr eax, 3
    lea rdx, [rel fs_bitmap_buf]
    and ecx, 7
    movzx eax, byte [rdx + rax]
    shr eax, cl
    and eax, 1
    ret


; ---- fs_bitmap_alloc_contiguous(ECX=count) → EAX = start sector or -1 ----
; Scan from FS_DATA_START for count contiguous free bits.
; Stack: push rbp,rbx,rsi,rdi + sub rsp 32. 8+32+32=72. 72%16=8.
;   Need sub rsp 40: 8+32+40=80. 80%16=0. Good.
;   rbx=needed, esi=scan_pos, edi=run_start, r12d=run_len (but we use stack for r12)
;   Actually: rbx=needed, esi=scan_pos, edi=run_start
fs_bitmap_alloc_contiguous:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40

    mov ebx, ecx            ; needed count
    mov esi, FS_DATA_START   ; scan from data start
    mov edi, esi             ; run_start = scan_pos
    xor ecx, ecx            ; run_len = 0 (in local, we use stack slot)
    mov [rsp+0], ecx         ; run_len at [rsp+0]

.fba_scan:
    cmp esi, FS_TOTAL_SECTORS
    jge .fba_fail

    ; Test bit at esi
    mov ecx, esi
    ; Inline test (avoid call overhead — leaf)
    mov eax, ecx
    shr eax, 3
    lea rdx, [rel fs_bitmap_buf]
    and ecx, 7
    movzx eax, byte [rdx + rax]
    shr eax, cl
    and eax, 1

    test eax, eax
    jnz .fba_reset          ; allocated — reset run

    ; Free bit — extend run
    mov eax, [rsp+0]
    inc eax
    mov [rsp+0], eax
    cmp eax, ebx
    jge .fba_found

    inc esi
    jmp .fba_scan

.fba_reset:
    inc esi
    mov edi, esi             ; new run_start
    mov dword [rsp+0], 0    ; run_len = 0
    jmp .fba_scan

.fba_found:
    mov eax, edi             ; return run_start
    jmp .fba_done

.fba_fail:
    mov eax, -1

.fba_done:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ---- fs_bitmap_count_free() → EAX = free sector count ----
; Count free (unallocated) sectors from FS_DATA_START to FS_TOTAL_SECTORS.
; Stack: push rbp,rbx + sub rsp 40. 8+16+40=64. 64%16=0. Good.
fs_bitmap_count_free:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    xor ebx, ebx            ; count = 0
    mov ecx, FS_DATA_START   ; sector = DATA_START

.fbcf_loop:
    cmp ecx, FS_TOTAL_SECTORS
    jge .fbcf_done

    ; Inline test
    mov eax, ecx
    shr eax, 3
    lea rdx, [rel fs_bitmap_buf]
    push rcx                 ; save sector
    and ecx, 7
    movzx eax, byte [rdx + rax]
    shr eax, cl
    and eax, 1
    pop rcx                  ; restore sector

    test eax, eax
    jnz .fbcf_next           ; allocated, skip
    inc ebx                  ; free

.fbcf_next:
    inc ecx
    jmp .fbcf_loop

.fbcf_done:
    mov eax, ebx
    add rsp, 40
    pop rbx
    pop rbp
    ret


; ============================================================
; FILESYSTEM INIT / FORMAT
; ============================================================

; ---- fs_init() → 0 success, -1 error ----
; Initialize filesystem. Read superblock, detect version, format if needed.
; Stack: push rbp,rbx + sub rsp 40. 8+16+40=64. 64%16=0. Good.
fs_init:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    ; Check disk present
    cmp dword [rel disk_present], 0
    je .fsi_no_disk

    ; Read sector 0 (superblock) into fs_superblock
    xor ecx, ecx           ; LBA 0
    lea rdx, [rel fs_superblock]
    call disk_read_sector
    test eax, eax
    jnz .fsi_error

    ; Check magic
    lea rax, [rel fs_superblock]
    cmp dword [rax + SB_MAGIC], FS_MAGIC
    jne .fsi_format

    ; Check version
    lea rax, [rel fs_superblock]
    movzx eax, word [rax + SB_VERSION]
    cmp eax, 2
    je .fsi_v2

    ; Version 1 → migrate (lossy reformat)
    lea rcx, [rel str_fs_migrate]
    call serial_print
    jmp .fsi_format

.fsi_v2:
    ; Valid v2 superblock — read directory (24 sectors)
    call fs_read_dir
    test eax, eax
    jnz .fsi_error

    ; Read bitmap (4 sectors)
    call fs_read_bitmap
    test eax, eax
    jnz .fsi_error

    mov dword [rel fs_initialized], 1

    ; Count active entries + report
    call fs_count_active
    mov ebx, eax            ; active count

    lea rcx, [rel str_fs_init]
    call serial_print
    mov ecx, ebx
    call serial_print_int
    lea rcx, [rel str_fs_files]
    call serial_print

    ; Free sectors via bitmap count
    call fs_bitmap_count_free
    mov ecx, eax
    call serial_print_int
    lea rcx, [rel str_fs_free]
    call serial_print

    xor eax, eax
    jmp .fsi_done

.fsi_format:
    call fs_format
    mov dword [rel fs_initialized], 1
    xor eax, eax
    jmp .fsi_done

.fsi_no_disk:
    lea rcx, [rel str_fs_err_nodisk]
    call serial_print
    mov eax, -1
    jmp .fsi_done

.fsi_error:
    mov eax, -1

.fsi_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret


; ---- fs_format() ----
; Internal. Write fresh v2 superblock + empty directory + empty bitmap.
; Stack: push rbp,rbx + sub rsp 40. 8+16+40=64. 64%16=0. Good.
fs_format:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    ; Zero superblock buffer
    lea rcx, [rel fs_superblock]
    xor edx, edx
    mov r8d, 512
    call herb_memset

    ; Write v2 superblock fields
    lea rax, [rel fs_superblock]
    mov dword [rax + SB_MAGIC], FS_MAGIC
    mov word [rax + SB_VERSION], FS_VERSION
    mov word [rax + SB_ENTRY_COUNT], 0
    mov dword [rax + SB_TOTAL_SECTORS], FS_TOTAL_SECTORS
    mov dword [rax + SB_BITMAP_START], FS_BITMAP_START
    mov dword [rax + SB_BITMAP_SECTS], FS_BITMAP_SECTORS
    mov dword [rax + SB_DATA_START], FS_DATA_START

    ; Write superblock to disk sector 0
    xor ecx, ecx
    lea rdx, [rel fs_superblock]
    call disk_write_sector

    ; Zero directory buffer (12288 bytes)
    lea rcx, [rel fs_dir_buf]
    xor edx, edx
    mov r8d, 12288
    call herb_memset

    ; Write 24 directory sectors
    call fs_write_dir

    ; Zero bitmap buffer
    lea rcx, [rel fs_bitmap_buf]
    xor edx, edx
    mov r8d, 2048
    call herb_memset

    ; Mark sectors 0 through FS_DATA_START-1 as allocated
    xor ebx, ebx
.ff_mark_reserved:
    cmp ebx, FS_DATA_START
    jge .ff_mark_done
    mov ecx, ebx
    call fs_bitmap_set
    inc ebx
    jmp .ff_mark_reserved

.ff_mark_done:
    ; Write bitmap to disk
    call fs_write_bitmap

    lea rcx, [rel str_fs_formatted]
    call serial_print

    add rsp, 40
    pop rbx
    pop rbp
    ret


; ---- fs_read_dir() → 0 success, -1 error ----
; Read directory sectors into fs_dir_buf.
; Stack: push rbp,rbx + sub rsp 40. 8+16+40=64. 64%16=0. Good.
fs_read_dir:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    xor ebx, ebx           ; i = 0
.frd_loop:
    cmp ebx, FS_DIR_SECTORS
    jge .frd_ok

    lea ecx, [ebx + FS_DIR_START]  ; LBA = i + 1
    lea rdx, [rel fs_dir_buf]
    lea rax, [rbx * 8]             ; offset = i * 512
    shl rax, 6                     ; * 64 → * 512 total (8*64=512)
    add rdx, rax
    call disk_read_sector
    test eax, eax
    jnz .frd_error

    inc ebx
    jmp .frd_loop

.frd_ok:
    xor eax, eax
    jmp .frd_done

.frd_error:
    mov eax, -1

.frd_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret


; ---- fs_write_dir() → 0 success, -1 error ----
; Write fs_dir_buf to directory sectors, then superblock to sector 0.
; Stack: push rbp,rbx + sub rsp 40. 8+16+40=64. 64%16=0. Good.
fs_write_dir:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    xor ebx, ebx           ; i = 0
.fwd_loop:
    cmp ebx, FS_DIR_SECTORS
    jge .fwd_super

    lea ecx, [ebx + FS_DIR_START]  ; LBA = i + 1
    lea rdx, [rel fs_dir_buf]
    lea rax, [rbx * 8]
    shl rax, 6                     ; * 512
    add rdx, rax
    call disk_write_sector
    test eax, eax
    jnz .fwd_error

    inc ebx
    jmp .fwd_loop

.fwd_super:
    ; Write superblock to sector 0
    xor ecx, ecx
    lea rdx, [rel fs_superblock]
    call disk_write_sector
    test eax, eax
    jnz .fwd_error

    xor eax, eax
    jmp .fwd_done

.fwd_error:
    mov eax, -1

.fwd_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret


; ---- fs_count_active() → EAX = active file count ----
; Internal. Count directory entries with flags & 1.
fs_count_active:
    push rbp
    mov rbp, rsp

    xor eax, eax           ; count = 0
    xor ecx, ecx           ; i = 0
    lea rdx, [rel fs_dir_buf]

.fca_loop:
    cmp ecx, FS_MAX_ENTRIES
    jge .fca_done
    test dword [rdx + DE_FLAGS], 1
    jz .fca_next
    inc eax
.fca_next:
    add rdx, FS_ENTRY_SIZE
    inc ecx
    jmp .fca_loop

.fca_done:
    pop rbp
    ret


; ---- fs_find(name) → RAX = ptr to entry, or NULL ----
; Internal. Find active directory entry by name.
; RCX = name string
; Returns: RAX = pointer to entry in fs_dir_buf, or 0 if not found.
; Stack: push rbp,rbx,rsi,rdi + sub rsp 40. 8+32+40=80. 80%16=0. Good.
fs_find:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 40

    mov rsi, rcx            ; save name
    lea rbx, [rel fs_dir_buf]
    xor edi, edi            ; i = 0

.ff_loop:
    cmp edi, FS_MAX_ENTRIES
    jge .ff_not_found

    ; Check active flag
    test dword [rbx + DE_FLAGS], 1
    jz .ff_next

    ; Compare name: herb_strcmp(name, entry.name)
    mov rcx, rsi
    lea rdx, [rbx + DE_NAME]
    call herb_strcmp
    test eax, eax
    jz .ff_found            ; strcmp returns 0 on match

.ff_next:
    add rbx, FS_ENTRY_SIZE
    inc edi
    jmp .ff_loop

.ff_found:
    mov rax, rbx
    jmp .ff_done

.ff_not_found:
    xor eax, eax           ; return NULL

.ff_done:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ---- fs_create(name, data, size) → entry index or -1 ----
; Create or overwrite a file. Uses bitmap for allocation.
; Args: RCX = name (string), RDX = data ptr, R8D = size in bytes
; Returns: EAX = entry index, or -1 on error
; Stack: push rbp,rbx,rsi,rdi,r12,r13,r14,r15 + sub rsp 48.
;   9 pushes (incl rbp) = 72 bytes. 8+72+48=128. 128%16=0. Good.
;   rbx=name, rsi=data, edi=size, r12=entry_ptr, r13d=entry_idx,
;   r14d=sectors_needed, r15d=start_sector
;   Stack slots: [rsp+0]=current_lba, [rsp+4]=remaining, [rsp+8..15]=data_ptr
fs_create:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48

    mov rbx, rcx            ; save name
    mov rsi, rdx             ; save data
    mov edi, r8d             ; save size

    ; Check initialized
    cmp dword [rel fs_initialized], 0
    je .fc_no_disk

    ; Check for existing file (overwrite support)
    mov rcx, rbx
    call fs_find
    test rax, rax
    jnz .fc_overwrite

    ; Find first inactive entry
    lea r12, [rel fs_dir_buf]
    xor r13d, r13d           ; entry index

.fc_find_slot:
    cmp r13d, FS_MAX_ENTRIES
    jge .fc_dir_full
    test dword [r12 + DE_FLAGS], 1
    jz .fc_got_slot
    add r12, FS_ENTRY_SIZE
    inc r13d
    jmp .fc_find_slot

.fc_overwrite:
    ; rax = pointer to existing entry
    mov r12, rax             ; entry_ptr

    ; Calculate entry index from pointer offset
    lea rcx, [rel fs_dir_buf]
    mov rax, r12
    sub rax, rcx
    xor edx, edx
    mov ecx, FS_ENTRY_SIZE
    div ecx                  ; eax = index
    mov r13d, eax

    ; Free old sectors: sector_count = (old_size + 511) / 512
    mov eax, [r12 + DE_SIZE]
    add eax, 511
    shr eax, 9
    test eax, eax
    jz .fc_got_slot          ; size was 0, nothing to free
    mov ecx, eax             ; sector_count
    mov edx, [r12 + DE_START] ; old start_sector

.fc_free_loop:
    test ecx, ecx
    jle .fc_got_slot
    mov [rsp+0], ecx         ; save remaining count
    mov [rsp+4], edx         ; save current sector
    mov ecx, edx
    call fs_bitmap_clear
    mov ecx, [rsp+0]
    mov edx, [rsp+4]
    inc edx
    dec ecx
    jmp .fc_free_loop

.fc_got_slot:
    ; Calculate sectors needed: (size + 511) / 512, min 1
    mov eax, edi
    add eax, 511
    shr eax, 9              ; / 512
    test eax, eax
    jnz .fc_sectors_ok
    mov eax, 1              ; at least 1 sector for empty files
.fc_sectors_ok:
    mov r14d, eax            ; sectors_needed

    ; Allocate contiguous sectors from bitmap
    mov ecx, r14d
    call fs_bitmap_alloc_contiguous
    cmp eax, -1
    je .fc_full
    mov r15d, eax            ; start_sector

    ; Copy name to entry (max 31 chars + null)
    ; First zero the name field
    lea rcx, [r12 + DE_NAME]
    xor edx, edx
    mov r8d, FS_NAME_LEN
    call herb_memset

    ; Get name length
    mov rcx, rbx
    call herb_strlen
    cmp eax, 31
    jle .fc_name_len_ok
    mov eax, 31
.fc_name_len_ok:
    mov r8d, eax            ; length to copy
    lea rcx, [r12 + DE_NAME]
    mov rdx, rbx            ; source
    call herb_memcpy

    ; Set entry fields
    mov [r12 + DE_START], r15d       ; start_sector
    mov [r12 + DE_SIZE], edi         ; size
    mov dword [r12 + DE_FLAGS], 1    ; active

    ; Mark allocated sectors in bitmap
    xor ecx, ecx            ; i = 0
.fc_mark_loop:
    cmp ecx, r14d
    jge .fc_mark_done
    mov [rsp+0], ecx         ; save i
    lea ecx, [r15d + ecx]   ; sector = start + i
    call fs_bitmap_set
    mov ecx, [rsp+0]
    inc ecx
    jmp .fc_mark_loop
.fc_mark_done:

    ; Write data sectors using stack slots (NO push/pop)
    mov eax, r15d            ; current sector LBA
    mov ecx, edi             ; remaining bytes
    mov rdx, rsi             ; data ptr

.fc_write_loop:
    test ecx, ecx
    jle .fc_write_done

    ; Save state in stack slots
    mov [rsp+0], eax         ; current LBA
    mov [rsp+4], ecx         ; remaining bytes
    mov [rsp+8], rdx         ; data ptr (64-bit)

    ; If remaining < 512, copy partial to fs_data_buf with zero pad
    cmp ecx, 512
    jge .fc_write_full

    ; Partial last sector: zero fs_data_buf, then copy remaining
    mov [rsp+16], ecx        ; save remaining for memcpy
    lea rcx, [rel fs_data_buf]
    xor edx, edx
    mov r8d, 512
    call herb_memset

    mov r8d, [rsp+16]       ; remaining bytes as copy count
    lea rcx, [rel fs_data_buf]
    mov rdx, [rsp+8]        ; data ptr
    call herb_memcpy

    ; Write padded sector
    mov ecx, [rsp+0]        ; LBA
    lea rdx, [rel fs_data_buf]
    call disk_write_sector
    jmp .fc_write_done       ; last sector done

.fc_write_full:
    ; Write full 512-byte sector directly from data ptr
    mov ecx, [rsp+0]        ; LBA
    mov rdx, [rsp+8]        ; data ptr
    call disk_write_sector

    ; Restore and advance
    mov eax, [rsp+0]         ; LBA
    mov ecx, [rsp+4]         ; remaining
    mov rdx, [rsp+8]         ; data ptr
    inc eax                  ; next sector
    sub ecx, 512
    add rdx, 512
    jmp .fc_write_loop

.fc_write_done:
    ; Update entry count
    call fs_count_active
    lea rcx, [rel fs_superblock]
    mov [rcx + SB_ENTRY_COUNT], ax

    ; Flush directory + bitmap
    call fs_write_dir
    call fs_write_bitmap

    ; Serial: [FS] saved "name" (N bytes)
    lea rcx, [rel str_fs_saved]
    call serial_print
    mov rcx, rbx
    call serial_print
    lea rcx, [rel str_fs_saved_mid]
    call serial_print
    mov ecx, edi
    call serial_print_int
    lea rcx, [rel str_fs_saved_end]
    call serial_print

    mov eax, r13d            ; return entry index
    jmp .fc_done

.fc_no_disk:
    lea rcx, [rel str_fs_err_nodisk]
    call serial_print
    mov eax, -1
    jmp .fc_done

.fc_dir_full:
    lea rcx, [rel str_fs_err_nodir]
    call serial_print
    mov eax, -1
    jmp .fc_done

.fc_full:
    lea rcx, [rel str_fs_err_full]
    call serial_print
    mov eax, -1

.fc_done:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ---- fs_read(name, buffer, max_size) → bytes read or -1 ----
; Read file contents into buffer.
; Args: RCX = name, RDX = buffer, R8D = max_size
; Returns: EAX = bytes read, or -1 on error
; Stack: push rbp,rbx,rsi,rdi,r12 + sub rsp 48.
;   8+40+48=96. 96%16=0. Good.
;   rbx=entry_ptr, rsi=buffer, edi=max_size, r12d=bytes_to_read
;   Stack slots: [rsp+0]=total_sectors, [rsp+4]=sector_index
fs_read:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48

    mov rsi, rdx             ; save buffer
    mov edi, r8d             ; save max_size

    ; Check initialized
    cmp dword [rel fs_initialized], 0
    je .fr_no_disk

    ; Find file
    ; rcx already = name
    call fs_find
    test rax, rax
    jz .fr_not_found
    mov rbx, rax             ; entry ptr

    ; bytes_to_read = min(size, max_size)
    mov r12d, [rbx + DE_SIZE]
    cmp r12d, edi
    jle .fr_size_ok
    mov r12d, edi
.fr_size_ok:

    ; Sectors to read = (bytes_to_read + 511) / 512
    mov eax, r12d
    add eax, 511
    shr eax, 9
    ; Read sectors into buffer using stack slots (NO push/pop)
    xor edx, edx                ; sector index = 0

.fr_read_loop:
    cmp edx, eax
    jge .fr_read_done

    ; Save loop state in stack slots
    mov [rsp+0], eax             ; total sectors
    mov [rsp+4], edx             ; sector index

    ; disk_read_sector(start + index, buffer + index*512)
    mov eax, [rbx + DE_START]
    add eax, [rsp+4]            ; LBA = start + index
    mov ecx, eax
    movsxd rax, dword [rsp+4]
    imul rax, 512
    mov rdx, rsi
    add rdx, rax                ; buffer + index*512
    call disk_read_sector
    test eax, eax
    jnz .fr_read_error_clean

    mov eax, [rsp+0]            ; total sectors
    mov edx, [rsp+4]            ; sector index
    inc edx
    jmp .fr_read_loop

.fr_read_error_clean:
    mov eax, -1
    jmp .fr_done

.fr_read_done:
    ; Serial: [FS] read "name" (N bytes)
    lea rcx, [rel str_fs_read_hdr]
    call serial_print
    lea rcx, [rbx + DE_NAME]
    call serial_print
    lea rcx, [rel str_fs_read_mid]
    call serial_print
    mov ecx, r12d
    call serial_print_int
    lea rcx, [rel str_fs_read_end]
    call serial_print

    mov eax, r12d               ; return bytes read
    jmp .fr_done

.fr_no_disk:
    lea rcx, [rel str_fs_err_nodisk]
    call serial_print
    mov eax, -1
    jmp .fr_done

.fr_not_found:
    lea rcx, [rel str_fs_err_nf]
    call serial_print
    mov eax, -1

.fr_done:
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ---- fs_delete(name) → 0 or -1 ----
; Mark file as inactive and free its sectors via bitmap.
; Args: RCX = name
; Returns: EAX = 0 success, -1 error
; Stack: push rbp,rbx,rsi,rdi + sub rsp 56. 8+32+56=96. 96%16=0. Good.
;   rbx=entry_ptr, esi=sector_count, edi=current_sector
fs_delete:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 56

    ; Check initialized
    cmp dword [rel fs_initialized], 0
    je .fd_no_disk

    ; rcx = name
    call fs_find
    test rax, rax
    jz .fd_not_found
    mov rbx, rax

    ; Free sectors: sector_count = (size + 511) / 512
    mov eax, [rbx + DE_SIZE]
    add eax, 511
    shr eax, 9
    mov esi, eax             ; sector_count
    mov edi, [rbx + DE_START] ; start_sector

.fd_free_loop:
    test esi, esi
    jle .fd_free_done
    mov ecx, edi
    call fs_bitmap_clear
    inc edi
    dec esi
    jmp .fd_free_loop

.fd_free_done:
    ; Clear active flag
    mov dword [rbx + DE_FLAGS], 0

    ; Update entry count in superblock
    call fs_count_active
    lea rcx, [rel fs_superblock]
    mov [rcx + SB_ENTRY_COUNT], ax

    ; Flush directory + bitmap
    call fs_write_dir
    call fs_write_bitmap

    ; Serial: [FS] deleted "name"
    lea rcx, [rel str_fs_deleted]
    call serial_print
    lea rcx, [rbx + DE_NAME]
    call serial_print
    lea rcx, [rel str_fs_deleted_end]
    call serial_print

    xor eax, eax
    jmp .fd_done

.fd_no_disk:
    lea rcx, [rel str_fs_err_nodisk]
    call serial_print
    mov eax, -1
    jmp .fd_done

.fd_not_found:
    lea rcx, [rel str_fs_err_nf]
    call serial_print
    mov eax, -1

.fd_done:
    add rsp, 56
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret


; ---- fs_list() → EAX = active count ----
; Print all active files to serial. Returns active count.
; Stack: push rbp,rbx,rsi + sub rsp 48. 8+24+48=80. 80%16=0. Good.
fs_list:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 48

    ; Check initialized
    cmp dword [rel fs_initialized], 0
    je .fl_no_disk

    lea rcx, [rel str_fs_list_hdr]
    call serial_print

    lea rbx, [rel fs_dir_buf]
    xor esi, esi             ; count = 0
    xor ecx, ecx            ; i = 0

.fl_loop:
    cmp ecx, FS_MAX_ENTRIES
    jge .fl_summary
    mov [rsp+0], ecx         ; save i

    ; Check active
    test dword [rbx + DE_FLAGS], 1
    jz .fl_next

    ; Print: "  name (size bytes)" to serial
    lea rcx, [rel str_fs_list_entry]
    call serial_print
    lea rcx, [rbx + DE_NAME]
    call serial_print
    lea rcx, [rel str_fs_list_size]
    call serial_print
    mov ecx, [rbx + DE_SIZE]
    call serial_print_int
    lea rcx, [rel str_fs_list_bytes]
    call serial_print

    ; Also format for output window: "  name (N bytes)"
    lea rcx, [rel fs_output_scratch]
    mov edx, 80
    lea r8, [rel str_fs_out_fmt]
    lea r9, [rbx + DE_NAME]
    mov eax, [rbx + DE_SIZE]
    mov [rsp+32], eax              ; 5th arg = size
    call herb_snprintf
    lea rcx, [rel fs_output_scratch]
    call shell_output_print

    inc esi

.fl_next:
    add rbx, FS_ENTRY_SIZE
    mov ecx, [rsp+0]
    inc ecx
    jmp .fl_loop

.fl_summary:
    ; Serial: "[FS] N files total"
    lea rcx, [rel str_fs_list_count]
    call serial_print
    mov ecx, esi
    call serial_print_int
    lea rcx, [rel str_fs_list_total]
    call serial_print

    mov eax, esi
    jmp .fl_done

.fl_no_disk:
    lea rcx, [rel str_fs_err_nodisk]
    call serial_print
    xor eax, eax

.fl_done:
    add rsp, 48
    pop rsi
    pop rbx
    pop rbp
    ret
