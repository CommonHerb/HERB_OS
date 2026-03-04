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
LD      = ld
OBJCOPY = objcopy
PYTHON  = py
QEMU    = "C:/Program Files/qemu/qemu-system-x86_64.exe"

# HERB program to embed (override with: make PROGRAM=interactive_os)
PROGRAM ?= interactive_kernel

# Graphics mode: 1=framebuffer, 0=text (default: 1 for interactive use)
GRAPHICS ?= 1

# NASM flags for herb_kernel.asm (conditional build modes)
NASMFLAGS_KERNEL = -f win64
ifeq ($(PROGRAM),interactive_kernel)
NASMFLAGS_KERNEL += -DKERNEL_MODE
endif
ifeq ($(GRAPHICS),1)
NASMFLAGS_KERNEL += -DGRAPHICS_MODE
endif

# .herb source files (compiled at boot by in-kernel compiler)
HERB_SOURCES = ../programs/interactive_kernel.herb \
               ../programs/shell.herb ../programs/producer.herb \
               ../programs/consumer.herb ../programs/worker.herb \
               ../programs/beacon.herb ../programs/schedule_priority.herb \
               ../programs/schedule_roundrobin.herb \
               ../programs/turing.herb

.PHONY: all run run-text clean help test-bare-metal

all: herb_os.img

# ---- Step 1: Compile all objects ----
kernel_entry.o: kernel_entry.asm
	$(NASM) -f win64 $< -o $@

herb_freestanding.o: herb_freestanding.asm herb_freestanding_layout.inc
	$(NASM) -f win64 $< -o $@

herb_hw.o: herb_hw.asm
	$(NASM) -f win64 $< -o $@

herb_ham.o: herb_ham.asm
	$(NASM) -f win64 $< -o $@

herb_graph.o: herb_graph.asm herb_graph_layout.inc
	$(NASM) -f win64 $< -o $@

herb_loader.o: herb_loader.asm herb_graph_layout.inc herb_freestanding_layout.inc
	$(NASM) -f win64 $< -o $@

herb_compiler.o: herb_compiler.asm herb_graph_layout.inc
	$(NASM) -f win64 $< -o $@

herb_wm.o: herb_wm.asm
	$(NASM) -f win64 $< -o $@

herb_editor.o: herb_editor.asm
	$(NASM) -f win64 $< -o $@

herb_disk.o: herb_disk.asm
	$(NASM) -f win64 $< -o $@

herb_kernel.o: herb_kernel.asm $(HERB_SOURCES)
	$(NASM) $(NASMFLAGS_KERNEL) $< -o $@

OBJS = kernel_entry.o herb_freestanding.o herb_hw.o herb_ham.o herb_graph.o herb_loader.o herb_compiler.o herb_wm.o herb_editor.o herb_disk.o herb_kernel.o

# ---- Step 2: Link into PE, then extract flat binary ----
# Image base 0x0FFC00 makes .text land at VMA 0x100000
# (PE headers occupy 0x0FFC00-0x0FFFFF, first section at +0x400)
kernel.pe: $(OBJS)
	$(LD) --image-base=0x0FFC00 --section-alignment=0x200 --file-alignment=0x200 \
	      -e _start -nostdlib -o $@ $(OBJS)

kernel.bin: kernel.pe
	$(OBJCOPY) -O binary -j .text -j .data -j .rdata $< $@
	@$(PYTHON) -c "import os; print('Kernel binary: ' + str(os.path.getsize('kernel.bin')) + ' bytes')"

# ---- Step 3: Assemble bootloader (needs kernel size) ----
boot.bin: boot.asm kernel.bin
	$(eval KSECTORS := $(shell $(PYTHON) -c "import math,os; print(math.ceil(os.path.getsize('kernel.bin') / 512))"))
	@echo "Kernel sectors: $(KSECTORS)"
	$(NASM) -f bin -DKERNEL_SECTORS=$(KSECTORS) $< -o $@

# ---- Step 4: Assemble final disk image ----
herb_os.img: boot.bin kernel.bin
	$(PYTHON) -c "open('$@','wb').write(open('boot.bin','rb').read()+open('kernel.bin','rb').read())"
	$(PYTHON) -c "import os; s=os.path.getsize('$@'); pad=((s+511)//512)*512-s; open('$@','ab').write(b'\x00'*pad) if pad else None"
	@echo ""
	@echo "=== HERB OS Image Built ==="
	@echo "  Program:  $(PROGRAM)"
	@echo "  Graphics: $(GRAPHICS)"
	@$(PYTHON) -c "import os; print('  File: $@  (' + str(os.path.getsize('$@')) + ' bytes)')"
	@echo "  Run:  make run"

# ---- Data disk image (persistent storage, 1MB) ----
herb_disk.img:
	$(PYTHON) -c "open('herb_disk.img','wb').write(b'\x00'*1048576)"

# ---- Run in QEMU (graphics mode, default) ----
run: herb_os.img herb_disk.img
	$(QEMU) -drive format=raw,file=herb_os.img -drive format=raw,file=herb_disk.img -m 64 -no-reboot -serial stdio

# ---- Run in QEMU (text mode — for debugging / fallback) ----
run-text:
	$(MAKE) clean
	$(MAKE) GRAPHICS=0
	$(QEMU) -drive format=raw,file=herb_os.img -drive format=raw,file=herb_disk.img -m 64 -no-reboot -serial stdio

# ---- Automated bare metal tests (always text mode — tests use serial) ----
test-bare-metal:
	$(MAKE) clean
	$(MAKE) GRAPHICS=0
	$(PYTHON) -c "open('herb_disk.img','wb').write(b'\x00'*1048576)"
	@echo "Running bare metal tests..."
	$(PYTHON) test_bare_metal.py herb_os.img

# ---- Clean ----
clean:
	$(PYTHON) -c "import glob,os;\
	[os.remove(f) for p in ['*.o','kernel.pe','kernel.bin','boot.bin','herb_os.img','test_serial.log'] for f in glob.glob(p) if os.path.isfile(f)]"

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
	@echo ".herb source is compiled at boot by the in-kernel compiler."
	@echo "No Python compilation step in the build chain."
	@echo ""
	@echo "Display:"
	@echo "  GRAPHICS=1 (default)   BGA framebuffer 800x600x32"
	@echo "  GRAPHICS=0             VGA text mode 80x25"
	@echo ""
	@echo "Tests always run in text mode (serial-based validation)."
