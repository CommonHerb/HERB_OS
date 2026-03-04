; boot/herb_disk.asm — ATA PIO disk driver + flat filesystem
;
; Session 75: Persistent storage for HERB OS.
; ATA PIO driver targets drive 1 (slave) — the data disk (herb_disk.img).
; Flat filesystem: superblock + directory (42 entries) + forward-only data allocation.
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

; Filesystem constants
%define FS_MAGIC        0x48455242      ; "HERB"
%define FS_VERSION      1
%define FS_DIR_SECTORS  4
%define FS_DIR_START    1
%define FS_DATA_START   5
%define FS_MAX_ENTRIES  42
%define FS_ENTRY_SIZE   48
%define FS_NAME_LEN     32

; ============================================================
; BSS
; ============================================================

section .bss
align 16
disk_sector_buf:    resb 512        ; scratch buffer for identify/self-test
fs_superblock:      resb 512        ; cached superblock (sector 0)
fs_dir_buf:         resb 2048       ; cached directory (sectors 1-4)
fs_data_buf:        resb 4096       ; general-purpose data buffer (8 sectors)
global fs_data_buf

align 4
disk_present:       resd 1          ; 1 if ATA slave detected
disk_total_sectors: resd 1          ; LBA28 sector count from IDENTIFY
fs_initialized:     resd 1          ; 1 after fs_init succeeds

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
str_fs_err_dup:     db "[FS] error: file exists", 10, 0
str_fs_err_nodir:   db "[FS] error: directory full", 10, 0

; ============================================================
; TEXT — ATA PIO DRIVER
; ============================================================

section .text

; ---- disk_identify() → 0 success, -1 no disk ----
; Detects ATA slave drive (drive 1) via IDENTIFY command.
; No args. Returns EAX = 0 on success, -1 on failure.
; Stack: push rbp + sub rsp 40 = 48 aligned. 8+8+40=56. 56%16=8.
;   Need sub rsp 48: 8+8+48=64. 64%16=0. Good.
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
; Internal. Write 0xDEADBEEF pattern to sector 2047, read back, compare.
; Stack: push rbp,rbx + sub rsp 40 = 56 aligned. 8+16+40=64. 64%16=0. Good.
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

    ; Write to sector 2047 (last sector of 1MB disk)
    mov ecx, 2047
    mov rdx, rbx
    call disk_write_sector
    test eax, eax
    jnz .dst_fail

    ; Clear the buffer
    mov rcx, rbx
    xor edx, edx
    mov r8d, 512
    call herb_memset

    ; Read sector 2047 back into disk_sector_buf
    mov ecx, 2047
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
; Stack: push rbp,rbx,rsi + sub rsp 40 = 64 aligned. 8+24+40=72. 72%16=8.
;   Need sub rsp 48: 8+24+48=80. 80%16=0. Good.
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
; TEXT — FLAT FILESYSTEM
; ============================================================

; Superblock layout (sector 0, 512 bytes):
;   Offset 0:   u32 magic (0x48455242 = "HERB")
;   Offset 4:   u16 version (1)
;   Offset 6:   u16 entry_count (active files)
;   Offset 8:   u32 first_free_sector (starts at 5)
;   Offset 12:  500 bytes reserved (zero)
;
; Directory entry (48 bytes, 42 per 4 sectors):
;   Offset 0:   char[32] filename (null-terminated, max 31 chars)
;   Offset 32:  u32 start_sector
;   Offset 36:  u32 size_bytes
;   Offset 40:  u32 flags (bit 0: active)
;   Offset 44:  u32 reserved

%define SB_MAGIC        0
%define SB_VERSION      4
%define SB_ENTRY_COUNT  6
%define SB_FIRST_FREE   8

%define DE_NAME         0
%define DE_START        32
%define DE_SIZE         36
%define DE_FLAGS        40


; ---- fs_init() → 0 success, -1 error ----
; Initialize filesystem. Read superblock, format if needed, cache directory.
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

    ; Valid superblock — read directory (sectors 1-4)
    call fs_read_dir
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

    ; Free sectors = 2048 - first_free
    lea rax, [rel fs_superblock]
    mov eax, [rax + SB_FIRST_FREE]
    mov ecx, 2048
    sub ecx, eax
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
; Internal. Write fresh superblock + empty directory.
; Stack: push rbp + sub rsp 48. 8+8+48=64. 64%16=0. Good.
fs_format:
    push rbp
    mov rbp, rsp
    sub rsp, 48

    ; Zero superblock buffer
    lea rcx, [rel fs_superblock]
    xor edx, edx
    mov r8d, 512
    call herb_memset

    ; Write magic, version, entry_count=0, first_free=5
    lea rax, [rel fs_superblock]
    mov dword [rax + SB_MAGIC], FS_MAGIC
    mov word [rax + SB_VERSION], FS_VERSION
    mov word [rax + SB_ENTRY_COUNT], 0
    mov dword [rax + SB_FIRST_FREE], FS_DATA_START

    ; Write superblock to disk sector 0
    xor ecx, ecx
    lea rdx, [rel fs_superblock]
    call disk_write_sector

    ; Zero directory buffer
    lea rcx, [rel fs_dir_buf]
    xor edx, edx
    mov r8d, 2048
    call herb_memset

    ; Write directory sectors 1-4
    call fs_write_dir

    lea rcx, [rel str_fs_formatted]
    call serial_print

    add rsp, 48
    pop rbp
    ret


; ---- fs_read_dir() → 0 success, -1 error ----
; Read directory sectors 1-4 into fs_dir_buf.
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
; Write fs_dir_buf to directory sectors 1-4, then superblock to sector 0.
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
; Stack: push rbp,rbx,rsi,rdi + sub rsp 32. 8+32+32=72. 72%16=8.
;   Need sub rsp 40: 8+32+40=80. 80%16=0. Good.
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
; Create a new file. Rejects duplicates.
; Args: RCX = name (string), RDX = data ptr, R8D = size in bytes
; Returns: EAX = entry index, or -1 on error
; Stack: push rbp,rbx,rsi,rdi,r12,r13,r14 + sub rsp 48.
;   8+56+48=112. 112%16=0. Good.
;   rbx=name, rsi=data, edi=size, r12=entry_ptr, r13d=entry_idx,
;   r14d=sectors_needed
fs_create:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 48

    mov rbx, rcx            ; save name
    mov rsi, rdx             ; save data
    mov edi, r8d             ; save size

    ; Check initialized
    cmp dword [rel fs_initialized], 0
    je .fc_no_disk

    ; Check for duplicate name
    mov rcx, rbx
    call fs_find
    test rax, rax
    jnz .fc_duplicate

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

.fc_got_slot:
    ; Calculate sectors needed: (size + 511) / 512
    mov eax, edi
    add eax, 511
    shr eax, 9              ; / 512
    mov r14d, eax            ; sectors_needed

    ; Check space: first_free + sectors <= 2048
    lea rax, [rel fs_superblock]
    mov eax, [rax + SB_FIRST_FREE]
    add eax, r14d
    cmp eax, 2048
    ja .fc_full

    ; Copy name to entry (max 31 chars + null)
    ; First zero the name field
    lea rcx, [r12 + DE_NAME]
    xor edx, edx
    mov r8d, FS_NAME_LEN
    call herb_memset

    ; Copy name
    lea rcx, [r12 + DE_NAME]
    mov rdx, rbx
    ; Find name length (max 31)
    push rcx                ; save dest
    mov rcx, rbx
    call herb_strlen
    cmp eax, 31
    jle .fc_name_len_ok
    mov eax, 31
.fc_name_len_ok:
    mov r8d, eax            ; length to copy
    pop rcx                 ; restore dest
    mov rdx, rbx            ; source
    call herb_memcpy

    ; Set entry fields
    lea rax, [rel fs_superblock]
    mov ecx, [rax + SB_FIRST_FREE]
    mov [r12 + DE_START], ecx        ; start_sector
    mov [r12 + DE_SIZE], edi         ; size
    mov dword [r12 + DE_FLAGS], 1    ; active

    ; Write data sectors
    ; Loop: for each sector, write 512 bytes
    mov eax, [r12 + DE_START]        ; current sector LBA
    mov ecx, edi                     ; remaining bytes
    mov rdx, rsi                     ; data ptr

.fc_write_loop:
    test ecx, ecx
    jle .fc_write_done

    ; Save state before disk_write_sector call
    mov [rsp+0], eax         ; current LBA
    mov [rsp+4], ecx         ; remaining bytes
    mov [rsp+8], rdx         ; data ptr (low 32 bits... no, save full)
    mov [rsp+16], rdx        ; save data ptr (64-bit)

    ; If remaining < 512, copy partial to fs_data_buf with zero pad
    cmp ecx, 512
    jge .fc_write_full

    ; Partial last sector: zero fs_data_buf, then copy remaining
    push rax
    push rcx
    push rdx
    lea rcx, [rel fs_data_buf]
    xor edx, edx
    mov r8d, 512
    call herb_memset
    pop rdx                  ; data ptr
    pop rcx                  ; remaining
    pop rax                  ; LBA

    push rax
    push rcx
    lea r8, [rcx]            ; r8d = remaining bytes (copy count)
    mov r8d, ecx
    lea rcx, [rel fs_data_buf]
    ; rdx already = data ptr
    call herb_memcpy
    pop rcx
    pop rax

    ; Write padded sector
    mov ecx, eax             ; LBA
    lea rdx, [rel fs_data_buf]
    push rax
    call disk_write_sector
    pop rax
    jmp .fc_write_done       ; last sector done

.fc_write_full:
    ; Write full 512-byte sector directly from data ptr
    mov [rsp+0], eax         ; save LBA again
    mov [rsp+16], rdx        ; save data ptr
    mov ecx, eax             ; LBA
    ; rdx already = data ptr
    call disk_write_sector

    ; Restore and advance
    mov eax, [rsp+0]         ; LBA
    mov ecx, [rsp+4]         ; remaining
    mov rdx, [rsp+16]        ; data ptr
    inc eax                  ; next sector
    sub ecx, 512
    add rdx, 512
    jmp .fc_write_loop

.fc_write_done:
    ; Update superblock: advance first_free
    lea rax, [rel fs_superblock]
    mov ecx, [rax + SB_FIRST_FREE]
    add ecx, r14d
    mov [rax + SB_FIRST_FREE], ecx

    ; Update entry count
    call fs_count_active
    lea rcx, [rel fs_superblock]
    mov [rcx + SB_ENTRY_COUNT], ax

    ; Flush directory + superblock
    call fs_write_dir

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

.fc_duplicate:
    lea rcx, [rel str_fs_err_dup]
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
    ; Read sectors into buffer
    mov ecx, [rbx + DE_START]    ; start LBA
    xor edx, edx                ; sector index

.fr_read_loop:
    cmp edx, eax
    jge .fr_read_done

    ; Save loop state
    push rax                     ; total sectors
    push rdx                     ; sector index

    ; disk_read_sector(start + index, buffer + index*512)
    mov eax, [rbx + DE_START]
    add eax, edx                ; LBA = start + index
    mov ecx, eax
    mov rdx, rsi
    pop rax                     ; get sector index back
    push rax                    ; re-save it
    imul rax, 512
    add rdx, rax                ; buffer offset

    call disk_read_sector
    test eax, eax
    jnz .fr_read_error

    pop rdx                     ; restore sector index
    pop rax                     ; restore total sectors
    inc edx
    jmp .fr_read_loop

.fr_read_error:
    pop rdx
    pop rax
    mov eax, -1
    jmp .fr_done

.fr_read_done:
    ; Serial: [FS] read "name" (N bytes)
    lea rcx, [rel str_fs_read_hdr]
    call serial_print
    mov rcx, [rbx + DE_NAME]     ; entry name is at start of entry
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
; Mark file as inactive. Does NOT reclaim disk space.
; Args: RCX = name
; Returns: EAX = 0 success, -1 error
; Stack: push rbp,rbx + sub rsp 40. 8+16+40=64. 64%16=0. Good.
fs_delete:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40

    ; Check initialized
    cmp dword [rel fs_initialized], 0
    je .fd_no_disk

    ; rcx = name
    call fs_find
    test rax, rax
    jz .fd_not_found
    mov rbx, rax

    ; Clear active flag
    mov dword [rbx + DE_FLAGS], 0

    ; Update entry count in superblock
    call fs_count_active
    lea rcx, [rel fs_superblock]
    mov [rcx + SB_ENTRY_COUNT], ax

    ; Flush
    call fs_write_dir

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
    add rsp, 40
    pop rbx
    pop rbp
    ret


; ---- fs_list() → EAX = active count ----
; Print all active files to serial. Returns active count.
; Stack: push rbp,rbx,rsi + sub rsp 40. 8+24+40=72. 72%16=8.
;   Need sub rsp 48: 8+24+48=80. 80%16=0. Good.
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

    ; Print: "  name (size bytes)"
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
