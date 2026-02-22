# ============================================================
# HERB OS Build System
#
# Targets:
#   make                — build herb_os.img with GRAPHICS_MODE
#   make run            — build + launch QEMU (pixel framebuffer)
#   make run-text       — build + launch QEMU (VGA text mode)
#   make test-bare-metal — build text mode + run automated QEMU tests
#   make clean          — remove build artifacts
#   make help           — show available targets
#
# Variables:
#   PROGRAM=interactive_os        — build flat scheduler
#   PROGRAM=interactive_kernel    — build four-module kernel (default)
#   GRAPHICS=1                    — enable BGA framebuffer (default for run)
#   GRAPHICS=0                    — force VGA text mode
# ============================================================

NASM    = nasm
CC      = gcc
LD      = ld
OBJCOPY = objcopy
PYTHON  = python
QEMU    = "C:/Program Files/qemu/qemu-system-x86_64.exe"

# HERB program to embed (override with: make PROGRAM=interactive_os)
PROGRAM ?= interactive_kernel

# Graphics mode: 1=framebuffer, 0=text (default: 1 for interactive use)
GRAPHICS ?= 1

# Freestanding kernel flags
# -DHERB_BINARY_ONLY strips the JSON parser — bare metal loads .herb binary only
CFLAGS = -ffreestanding -nostdlib -mno-red-zone -fno-stack-protector \
         -fno-pic -fno-exceptions -Wall -O2 -I../src -I. -DHERB_BINARY_ONLY

# Add KERNEL_MODE flag for the four-module kernel
ifeq ($(PROGRAM),interactive_kernel)
CFLAGS += -DKERNEL_MODE
endif

# Add GRAPHICS_MODE flag
ifeq ($(GRAPHICS),1)
CFLAGS += -DGRAPHICS_MODE
endif

# Program paths
PROGRAM_JSON = ../programs/$(PROGRAM).herb.json
PROGRAM_BIN  = $(PROGRAM).herb

# Process program paths (loaded as data at runtime)
PROC_PROGRAMS = producer consumer worker beacon schedule_priority schedule_roundrobin shell
PROC_HERB_BINS = $(addsuffix .herb,$(PROC_PROGRAMS))

.PHONY: all run run-text clean help test-bare-metal

all: herb_os.img

# ---- Step 1a: Compile .herb.json to .herb binary (main kernel program) ----
$(PROGRAM_BIN): ../src/herb_compile.py $(PROGRAM_JSON)
	$(PYTHON) ../src/herb_compile.py $(PROGRAM_JSON) $(PROGRAM_BIN)

# ---- Step 1b: Compile process program fragments ----
%.herb: ../programs/%.herb.json ../src/herb_compile.py
	$(PYTHON) ../src/herb_compile.py $< $@

# ---- Step 1c: Generate embedded program header (main kernel) ----
program_data.h: gen_program_data.py $(PROGRAM_BIN)
	$(PYTHON) gen_program_data.py $(PROGRAM_BIN) program_data.h

# ---- Step 1d: Generate embedded process programs header ----
process_programs.h: gen_multi_program_data.py $(PROC_HERB_BINS)
	$(PYTHON) gen_multi_program_data.py $(foreach p,$(PROC_PROGRAMS),$(p):$(p).herb) process_programs.h

# ---- Step 2: Compile all objects ----
kernel_entry.o: kernel_entry.asm
	$(NASM) -f win64 $< -o $@

kernel_main.o: kernel_main.c program_data.h process_programs.h ../src/herb_freestanding.h font8x16.h framebuffer.h
	$(CC) $(CFLAGS) -c $< -o $@

herb_runtime_freestanding.o: ../src/herb_runtime_freestanding.c ../src/herb_freestanding.h
	$(CC) $(CFLAGS) -c $< -o $@

herb_freestanding.o: ../src/herb_freestanding.c ../src/herb_freestanding.h
	$(CC) $(CFLAGS) -c $< -o $@

herb_hw.o: herb_hw.asm
	$(NASM) -f win64 $< -o $@

herb_ham.o: herb_ham.asm
	$(NASM) -f win64 $< -o $@

herb_graph.o: herb_graph.asm herb_graph_layout.inc
	$(NASM) -f win64 $< -o $@

OBJS = kernel_entry.o kernel_main.o herb_runtime_freestanding.o herb_freestanding.o herb_hw.o herb_ham.o herb_graph.o

# ---- Step 3: Link into PE, then extract flat binary ----
# Image base 0x0FFC00 makes .text land at VMA 0x100000
# (PE headers occupy 0x0FFC00-0x0FFFFF, first section at +0x400)
kernel.pe: $(OBJS)
	$(LD) --image-base=0x0FFC00 --section-alignment=0x200 --file-alignment=0x200 \
	      -e _start -nostdlib -o $@ $(OBJS)

kernel.bin: kernel.pe
	$(OBJCOPY) -O binary -j .text -j .data -j .rdata $< $@
	@echo "Kernel binary: $$(wc -c < kernel.bin) bytes"

# ---- Step 4: Assemble bootloader (needs kernel size) ----
boot.bin: boot.asm kernel.bin
	$(eval KSECTORS := $(shell $(PYTHON) -c "import math; print(math.ceil($$(wc -c < kernel.bin) / 512))"))
	@echo "Kernel sectors: $(KSECTORS)"
	$(NASM) -f bin -DKERNEL_SECTORS=$(KSECTORS) $< -o $@

# ---- Step 5: Assemble final disk image ----
herb_os.img: boot.bin kernel.bin
	cat boot.bin kernel.bin > $@
	@# Pad to 512-byte boundary
	$(PYTHON) -c "import os; s=os.path.getsize('$@'); pad=((s+511)//512)*512-s; open('$@','ab').write(b'\x00'*pad) if pad else None"
	@echo ""
	@echo "=== HERB OS Image Built ==="
	@echo "  Program:  $(PROGRAM)"
	@echo "  Graphics: $(GRAPHICS)"
	@echo "  File: $@  ($$(wc -c < $@) bytes)"
	@echo "  Run:  make run"

# ---- Run in QEMU (graphics mode, default) ----
run: herb_os.img
	$(QEMU) -drive format=raw,file=herb_os.img -m 64 -no-reboot -serial stdio

# ---- Run in QEMU (text mode — for debugging / fallback) ----
run-text:
	$(MAKE) clean
	$(MAKE) GRAPHICS=0
	$(QEMU) -drive format=raw,file=herb_os.img -m 64 -no-reboot -serial stdio

# ---- Automated bare metal tests (always text mode — tests use serial) ----
test-bare-metal:
	$(MAKE) clean
	$(MAKE) GRAPHICS=0
	@echo "Running bare metal tests..."
	$(PYTHON) test_bare_metal.py herb_os.img

# ---- Clean ----
clean:
	rm -f *.o kernel.pe kernel.bin boot.bin herb_os.img program_data.h process_programs.h
	rm -f interactive_kernel.herb interactive_os.herb
	rm -f producer.herb consumer.herb worker.herb beacon.herb
	rm -f schedule_priority.herb schedule_roundrobin.herb shell.herb
	rm -f test_serial.log

# ---- Help ----
help:
	@echo "HERB OS Build System"
	@echo ""
	@echo "Targets:"
	@echo "  make                  Build herb_os.img (graphics mode)"
	@echo "  make run              Build and launch in QEMU (pixel framebuffer)"
	@echo "  make run-text         Build and launch in QEMU (VGA text mode)"
	@echo "  make test-bare-metal  Build text mode and run automated QEMU tests"
	@echo "  make clean            Remove build artifacts"
	@echo ""
	@echo "Programs:"
	@echo "  make PROGRAM=interactive_kernel   Four-module kernel (default)"
	@echo "  make PROGRAM=interactive_os       Flat scheduler"
	@echo ""
	@echo "Process Programs (loaded as data at runtime):"
	@echo "  producer.herb, consumer.herb — process program fragments"
	@echo "  schedule_priority.herb, schedule_roundrobin.herb — scheduling policies"
	@echo ""
	@echo "Display:"
	@echo "  GRAPHICS=1 (default)   BGA framebuffer 800x600x32"
	@echo "  GRAPHICS=0             VGA text mode 80x25"
	@echo ""
	@echo "Tests always run in text mode (serial-based validation)."
