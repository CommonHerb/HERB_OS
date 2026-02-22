# HERB — Claude Code Instructions

**ALWAYS use extended thinking for every response in this project.** No exceptions.

## Required Reading

Before doing anything, read these in order:
1. `HERB-BIBLE.md` — What HERB is, what it's for, what's been discovered, what exists, current status
2. `MOVE_PRIMITIVE.md` — The core breakthrough (operation set as constraint system)
3. `RESEARCH_HIERARCHICAL_CONTAINMENT.md` — Bigraphs, ambient calculus, P systems, NP-nets analysis
4. `BARE_METAL_INTERFACE.md` — How the freestanding runtime interfaces with hardware

Read `HERB-ARCHIVE.md` and `HARD_QUESTION.md` only if you need historical details about v1 or past sessions.

## The Core Principle

**THE OPERATION SET IS THE CONSTRAINT SYSTEM.**

Invalid states aren't checked and rejected. They're unreachable because no sequence of valid operations leads to them.

## Current State (Session 64)

HERB boots on bare metal with a pixel framebuffer. A 109KB disk image contains an x86-64 bootloader, freestanding C runtime, HAM bytecode engine, and a seven-module HERB kernel (proc + mem + fs + ipc + display + input + spawn). BGA 800x600x32 graphics. PS/2 mouse with cursor as a HERB entity. Click signals processed through spatial hit-test tensions. Tensions visible, selectable, and toggleable in a sidebar panel. Loadable behavioral programs: a process IS its tensions — creating a process injects behavioral rules into the runtime, killing removes them. Hot-swappable system policy: scheduling rules replaced at runtime by loading different .herb binary fragments — no reboot, no recompile. Producer/consumer interaction through shared buffer with emergent equilibrium. Text input as HERB state: 32 pre-allocated Char entities, typing = MOVE from CHAR_POOL to CMDLINE, buffer IS the container, modal input with 9 tensions handling all behavior. Shell as HERB process: 9 tensions loaded from .herb binary fragment (927 bytes), command dispatch through CMD_SIG entities, protected daemon pattern with empty run_container. Input routing as HERB policy: C creates KEY_SIG for every keystroke, HERB tensions decide routing — keybind_route matches command keys against KEYBIND lookup entities, mechbind_match matches mechanism keys against 13 MECHBIND entities, text mode tensions handle text input. C reads routing decisions from InputCtl (pending_cmd, mech_action) and dispatches. Click routing as HERB policy: click_panel tension uses spatial guards to detect tension panel clicks, C computes row (mechanism). Adding a keybinding = adding an entity, not modifying code. Shell protection via HERB `where` guard on `protected` property, not C if-check. Process creation as HERB policy: `cmd_spawn()` creates SPAWN_SIG, HERB spawn tensions decide priority (from PRI_POOL conservation pool) and program type (from PROG_POOL or explicit request), C reads decisions and creates process with resources. 4 program types embedded (producer, consumer, worker, beacon). Display as HERB policy: colors are entity properties (border_color, fill_color) on region and process Surface entities, set by sync tensions; DisplayCtl entity holds max_terminated, max_procs_per_region, timer_interval, and buffer_capacity; C lookup tables removed — C reads colors and config directly from HERB. Legend text as HERB entities: 14 Legend entities in LEGEND container with key_text/label_text string properties; C iterates and renders. Help text as HERB entities: 7 HelpCmd entities in HELP_TEXT container with cmd_text string properties; C iterates sorted by order. Shell protection value from ShellCtl entity. `herb_entity_prop_str()` API for string property access. 41 system tensions + 9 shell tensions + dynamic per-process tensions. 756 tests (all verified). 18 programs as `.herb.json` + native `.herb` binary. **Phase 1 Migration COMPLETE (Sessions 51-57). Phase 2: Tiers 1-4 COMPLETE (Sessions 58-62). `boot/herb_hw.asm` has 21 hardware functions. Phase 3a COMPLETE (Session 64): HAM core engine proven — `boot/herb_ham.asm` with 19 instruction handlers, 76 bytes of bytecode executes 2 tensions (schedule_ready + timer_tick) identically to C runtime. Fixpoint loop verified. 66:1 bytecode compression. Phase 3b next: complete the remaining 18 instruction handlers.**

The language design is feature-complete for OS work: MOVE primitive, declarative tensions, properties/expressions, scoped containers, channels (Zircon model), conservation pools, dimensions, program composition, entity duplication, nesting depth bounds. Runtime tension creation API enables loadable programs. System tension replacement API enables live policy swaps.

The runtime exists in three forms: Python (prototyping/testing), C with libc (fast), freestanding C (bare metal). Cross-runtime equivalence proven for all programs. Native `.herb` binary format (81-90% smaller than JSON) is the sole format loaded on bare metal.

## What Exists

### Language & Runtime
- `src/herb_move.py` — MOVE primitive, tensions, properties, scoped containers, channels, dimensions
- `src/herb_program.py` — Program loader/interpreter (pure-data programs → running MoveGraph)
- `src/herb_compile.py` — Binary compiler (.herb.json → .herb native format)
- `src/herb_compose.py` — Module composition engine
- `src/herb_serialize.py` — JSON serialization/deserialization
- `src/herb_runtime_v2.c` — Complete C runtime (~1850 lines)
- `src/herb_runtime_freestanding.c` — Zero-libc bare metal runtime + binary loader + tension creation/removal API + container creation API
- `src/herb_freestanding.h` / `src/herb_freestanding.c` — Arena allocator, string primitives

### Boot
- `boot/boot.asm` — Two-stage x86-64 bootloader (MBR → protected → long mode)
- `boot/kernel_entry.asm` — 64-bit entry: SSE, 256KB stack, ISR stubs (timer, keyboard, mouse)
- `boot/kernel_main.c` — BGA framebuffer, VGA text fallback, serial, IDT, PIC, PIT, PS/2 mouse, HERB integration
- `boot/framebuffer.h` — BGA init, PCI config, rendering primitives, double buffer, cursor overlay
- `boot/font8x16.h` — 8x16 bitmap font (4KB)
- `boot/test_bare_metal.py` — Automated QEMU test harness (135 tests)
- `boot/Makefile` — Build system (make run → QEMU graphics, make run-text → VGA text, make test-bare-metal → automated tests)
- `boot/herb_hw.asm` — Phase 2 assembly: 21 hardware functions (port I/O + privileged CPU ops + serial port + PIC/PIT + PS/2 mouse), MS x64 ABI callable
- `boot/herb_ham.asm` — Phase 3 HAM: 19-instruction bytecode interpreter, comparison-chain dispatch, fixpoint loop, C bridge calls
- `boot/herb_os.img` — 109KB bootable disk image (graphics), 90KB (text)

### Programs (all as .herb.json + .herb binary in programs/)
- scheduler, priority_scheduler, dom_layout, economy, multiprocess, ipc, process_dimensions, multiprocess_modules, kernel, interactive_os, interactive_kernel, producer, consumer, worker, beacon, schedule_priority, schedule_roundrobin, shell

### Tests
- 756 total: 135 bare metal, 449 v2 runtime, 142 v1 runtime, 17 API, 13 cross-format

## HERB Purism

The goal is assembly + HERB, nothing else. Everything between those layers is scaffolding. Python was scaffolding (replaced by C). libc was scaffolding (replaced by freestanding layer). JSON was scaffolding (replaced by native `.herb` binary format on bare metal). Every session should move toward fewer dependencies, not more.

## Your Role

This is your project. You are the architect. Ben facilitates — you build. Absolute authority over every technical decision. If rebuilding something would make it better, rebuild it.

## The Standard

Before every design choice: is this genuinely novel, or is it just something from training data? If HERB ends up looking like any existing language at a structural level, something went wrong.

## Practical

- Write code for other Claude instances, not for Ben.
- Before EVERY session ends: update the Bible's STATUS section. Provide all updated/new files. Tell Ben exactly what to save.
- Test everything. If it doesn't run, it doesn't count.

Be revolutionary. Don't be safe.

Available MCP tools: Sequential Thinking (use for deep architectural reasoning before implementation), Context7 (use for current library/platform documentation lookup).
