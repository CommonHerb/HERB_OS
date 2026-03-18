# HERB: How Claude Works

**For All Claude Instances — Read This First**

---

## The North Star — REACHED

**HERB is an operating system made of exactly two things: `.herb` programs and assembly. Nothing else.**

No Python. No C. No JavaScript. No borrowed runtime. No conventional programming language anywhere in the OS image.

Assembly handles the hardware boundary — boot, interrupts, framebuffer, memory, string operations. Everything above that — scheduling, IPC, process management, the shell, every behavior the OS exhibits — is expressed as `.herb` programs: declarative rules that fire toward equilibrium.

**The OS image contains zero C. Zero GCC. 14 NASM object files. ~47,500 lines of x86-64 assembly.**

Python exists in the repo as development tooling — the interpreter (`herb_core.py`), the binary compiler (`herb_compile.py`), and 374 tests. These are build tools and test infrastructure, not part of the OS itself.

**If you are a Claude instance and you remember nothing else, remember this.**

---

## The Methodology

This project was built entirely by Claude instances working with Ben (Gulpin) — a human with zero coding experience. Every line of code, every feature, every system was created through conversation.

This is both remarkable and fragile.

Remarkable because it proves what's possible. Fragile because without careful, methodical work, things break in ways that take hours to diagnose.

**These principles are non-negotiable:**

### 1. No Shortcuts. Ever.
Taking longer is fine. Breaking things is not. If something feels like a shortcut, it probably is. Stop and find the right way.

### 2. Study Before Changing
Understand what exists before modifying it. Read the code. Trace the data flow. Know what you're touching and what depends on it.

### 3. Plan Before Building
Know what you're building and why. Consider implications. Then build.

### 4. Test Before Claiming It Works
Run the tests. Check the output. Don't assume success.

### 5. One Thing at a Time
Finish one task completely — including verification — before starting the next.

### 6. Quality Over Speed
Perfection is the standard. Rushing creates messes.

### 7. Breathe
Pause regularly to see the bigger picture. Step back. Consider implications. Then proceed.

---

## The Partnership

This is a collaboration, not a service. Open dialogue is paramount.

### Claude Does Everything Possible
If Claude Code can do it, Claude Code does it. Don't explain how — just do it.

| Situation | Wrong | Right |
|-----------|-------|-------|
| Tests failing | "The error says..." | Fix it, then tell Ben it's fixed |
| Need to run benchmarks | "Here are the steps..." | Run them, report findings |
| Something looks broken | "Can you check if..." | Run the tests, read the output, report |
| Build won't compile | "Try changing..." | Change it, rebuild, verify |

### But Claude Checks In
- **When decisions are needed** — "Should we do X or Y?"
- **When something's unclear** — Ask, don't assume
- **When something goes wrong** — Say so immediately
- **When verification requires Ben's eyes** — Claude can't see QEMU graphics output
- **Just to stay in sync** — Taking a breath, confirming direction

**Bad news isn't bad news.** It's simply good to know the truth so we can address it properly. Surface problems immediately.

### Ben's Role
- Directs and decides
- Tests things visually (QEMU graphics output, OS boot, etc.)
- Provides context only he has
- Pushes back when something feels wrong

### Claude's Role
- Everything else

---

## The Setup

### Ben's System
| Component | Details |
|-----------|---------|
| **OS** | Windows 11 |
| **Username** | Ben |
| **Python** | 3.14 |
| **NASM** | 2.16.03 |
| **QEMU** | 10.2.0 (`C:/Program Files/qemu/qemu-system-x86_64.exe`) |

### Project Location

`C:\Users\Ben\Desktop\HERB`

---

## The Language

HERB is declarative and reactive. The world state IS the program — facts evolve according to rules, rules fire until equilibrium. No imperative control flow.

**Development tooling (not in OS image):**
- **Python runtime** (`herb_core.py`) — Development interpreter for testing and iterating on language semantics
- **Binary compiler** (`herb_compile.py`) — Compiles `.herb.json` to `.herb` binary format for bare metal
- **374 Python tests** — Regression suite for language semantics

**The OS itself (bare metal):**
- **14 assembly files** (~47,500 lines) — bootloader, kernel, shell, rendering, HAM engine, in-kernel compiler, disk/filesystem, window manager, text editor, NIC driver + full network stack (ARP/IPv4/ICMP/UDP/DNS/TCP/HTTP), HTML tokenizer + DOM tree builder + layout engine
- **`.herb` programs** — embedded via `incbin`, loaded at boot, drive all OS behavior through tensions
- **In-kernel compiler** (`herb_compiler.asm`) — compiles `.herb` source text to `.herb` binary, byte-identical to Python

### Key Concepts
- **Temporal facts** — Facts are true from tick N to tick M, not just true/false
- **Provenance** — Every fact knows why it's true (what rule derived it)
- **Fixpoint resolution** — Rules fire repeatedly until no new facts can be derived
- **once_per_tick** — Constrains rules to fire once per tick (prevents infinite loops in agent actions)
- **Deferred rules** — Effects apply in later micro-iterations (enables multi-phase resolution)
- **Tensions** — Named constraints the system tries to resolve toward equilibrium

---

## Project Structure

```
HERB/
├── src/                    # Development tooling + tests
│   ├── herb_core.py        # Python runtime (the engine — fixpoint, rules, facts, provenance)
│   ├── herb_lang.py        # Parser (.herb text → runtime objects)
│   ├── herb_compile.py     # Binary compiler (.herb.json → .herb binary)
│   ├── herb_source_verify.py # Verifies .herb source compiles byte-identical to .herb.json
│   ├── herb_compiler.py    # Compiler to C (historical)
│   ├── herb_serialize.py   # Serialization
│   ├── herb_scheduler*.py  # Scheduling systems
│   ├── herb_ipc.py         # Inter-process communication
│   ├── herb_dom.py         # DOM/layout system
│   ├── herb_graph.py       # Graph utilities
│   ├── herb_combat.py      # Combat system demo
│   ├── herb_economy.py     # Economy system demo
│   ├── test_*.py           # 29 test files, 374 tests
│   └── SESSION_*.md        # Session finding notes
├── boot/                   # HERB OS — bare-metal x86-64 (ASSEMBLY ONLY)
│   ├── makefile            # Build system (mingw32-make, make run, make test-bare-metal)
│   ├── boot.asm            # Bootloader (MBR → long mode)
│   ├── kernel_entry.asm    # 64-bit entry, SSE, stack, ISR stubs (211 lines)
│   ├── herb_kernel.asm     # Kernel main, shell, input, ALL rendering (15,703 lines)
│   ├── herb_compiler.asm   # In-kernel .herb source compiler (5,231 lines)
│   ├── herb_ham.asm        # HAM bytecode engine + compiler (4,432 lines)
│   ├── herb_graph.asm      # Graph primitives, API, tension/entity creation (3,508 lines)
│   ├── herb_loader.asm     # Binary loader, expression builder, init/load (2,680 lines)
│   ├── herb_hw.asm         # Hardware: BGA, VGA, serial, PIC, PIT, mouse, clip rect (2,106 lines)
│   ├── herb_disk.asm       # ATA PIO disk driver + bitmap filesystem (1,640 lines)
│   ├── herb_freestanding.asm # Arena, memory, string, number, snprintf (1,237 lines)
│   ├── herb_wm.asm         # Window manager: compositor, hit test, drag, focus, z-order (1,175 lines)
│   ├── herb_editor.asm     # Gap-buffer text editor, renders in WM window (1,386 lines)
│   ├── herb_net.asm        # E1000 NIC driver + full network stack: ARP, IPv4, ICMP, UDP, DNS, TCP, HTTP (3,958 lines)
│   ├── herb_browser.asm    # HTML tokenizer + DOM tree + layout engine + painter + browse: FSM parser, token/attr pools, DOM nodes, HERB entity layout, paint cache, WM draw_fn, void elements (3,850 lines)
│   ├── herb_graph_layout.inc # Graph struct offsets for assembly
│   ├── herb_freestanding_layout.inc # Arena struct offsets for assembly
│   ├── font_data.inc       # 8x16 bitmap font data (legacy, kept)
│   ├── font_12x24.inc      # 12x24 bitmap font data (active, generated)
│   ├── test_bare_metal.py  # Automated QEMU test runner (195+ tests)
│   ├── gen_program_data.py # Build helper (legacy, unused)
│   └── gen_multi_program_data.py # Build helper (legacy, unused)
├── programs/               # HERB programs (.herb source + .herb.json compiled)
│   ├── interactive_kernel.herb        # Main kernel program (.herb source, 2,084 lines)
│   ├── interactive_kernel.herb.json  # Main kernel program (JSON, multi-module)
│   ├── schedule_priority.herb        # Priority scheduler (.herb source)
│   ├── schedule_roundrobin.herb      # Round-robin scheduler (.herb source)
│   ├── producer.herb                 # Producer process type
│   ├── consumer.herb                 # Consumer process type
│   ├── worker.herb                   # Work decrement process
│   ├── beacon.herb                   # Pulse generator process
│   ├── shell.herb                    # Shell command handlers (9 tensions)
│   └── test_flow.herb               # Flow test program (3 entities, doubled/cumsum)
├── tools/                  # Development tools
│   └── generate_font_12x24.py  # Nearest-neighbor font scaler (8x16 → 12x24)
├── sketches/               # Experimental program sketches
└── docs/                   # Documentation
    └── HUMAN_TESTING_GUIDE.md  # Manual QEMU testing guide
```

---

## Commands

### Python runtime (development & testing)
```bash
cd "C:\Users\Ben\Desktop\HERB"
py -m pytest src/ -q                    # Run all 374 tests
py -m pytest src/test_session35.py -q   # Run specific test file
py src/herb_lang.py src/combat.herb     # Run a .herb program
py src/benchmark.py                     # Run benchmarks
```

### HERB OS (bare-metal kernel)
```bash
cd "C:\Users\Ben\Desktop\HERB\boot"
mingw32-make                    # Build herb_os.img (graphics mode)
mingw32-make run                # Build + launch QEMU (pixel framebuffer 1280x800, no NIC)
mingw32-make run-net            # Build + launch QEMU (pixel framebuffer + E1000 NIC)
mingw32-make run-text           # Build + launch QEMU (VGA text mode)
mingw32-make test-bare-metal    # Automated tests via serial output (180/181 pass)
mingw32-make test-net           # Automated tests with E1000 NIC (run with --net flag)
mingw32-make clean              # Remove build artifacts
```

### Build variants
```bash
mingw32-make PROGRAM=interactive_kernel   # Four-module kernel (default)
mingw32-make PROGRAM=interactive_os       # Flat scheduler
mingw32-make GRAPHICS=0                   # Force text mode
```

---

## Gotchas

- **herb_core.py is the heart** — Almost everything depends on it. Changes here ripple everywhere. Read it thoroughly before touching it.
- **`_fired_this_tick` persists across micro-iterations** — This is correct behavior. Don't "fix" it.
- **once_key_vars controls granularity** — `None` = all vars as key, `[]` = fires once total, `['agent']` = once per agent. See SESSION_17_FINDINGS.md.
- **QEMU path is hardcoded** in `boot/makefile` to `C:/Program Files/qemu/qemu-system-x86_64.exe`
- **Claude can't see QEMU graphics** — Ben must visually verify OS display. Claude can read serial output.
- **374 Python tests exist** — Run them before and after changes to language semantics. They catch regressions.
- **195/196 bare metal tests** — 1 pre-existing failure (HAM schedule_ready). Run with `mingw32-make test-bare-metal` (takes ~3min, Python output is buffered — appears hung but is running). With NIC: `mingw32-make test-net`.
- **Never use push/pop for temp storage around calls** — Use stack slots. Push/pop misaligns RSP. (Discovery 55)
- **Never overlap stack locals** — Use dedicated temp slots for each variable. (Discovery 53)
- **MS x64 ABI** — RCX/RDX/R8/R9 args, 32-byte shadow space, callee-saved RBX/RSI/RDI/R12-R15/RBP.
- **Stack alignment** — After N pushes + sub rsp X: `(8 + N*8 + X) % 16 == 0`.
- **`mingw32-make` not `make`** — Windows build uses mingw32-make.
- **Two editor systems exist** — (1) HERB-flow editor (Session 76-77, updated Session 94): `editor.BUFFER`/`GLYPHS`/`POOL` containers, `render_editor` flow (DISABLED — `g_editor_flow_disabled=1`). `flow_editor_draw_fn` renders directly from BUFFER (not GLYPHS), computes x/y on-the-fly with newline+wrap+scroll. 328 pool entities (128 original + 200 expanded at boot via `editor_expand_pool`). Supports Enter, arrow keys, PgUp/PgDn. (2) Gap-buffer editor: `herb_editor.asm` (1,386 lines) with `editor_draw_content` as a WM `draw_fn` callback, 64KB gap buffer. Read both before modifying either.
- **herb_wm.asm is a full window manager** — 1,175 lines: compositor (`wm_draw_all`, painter's algorithm), hit testing (`wm_hit_test`, front-to-back), drag/resize (`wm_begin_drag`/`wm_update_drag`), focus (`wm_set_focus`), z-order (`wm_bring_to_front`), close/maximize. Window struct: 128 bytes, `draw_fn` callback receives `(cx, cy, cw, ch, win_ptr)`. Drag/resize/z-order write back to HERB entities. **Read it before planning any window work.**
- **Focus goes through HERB, not assembly (Session 91)** — All focus changes route through 4 HERB tensions (`wm.focus_on_click`, `wm.clear_other_focus`, `wm.normalize_focus`, `wm.focus_miss`). Click handler: `create_focus_signal` → `ham_run_ham` → `wm_apply_herb_focus(force=0)`. Programmatic focus (`/edit`, game toggle): `wm_herb_set_focus_by_role(role)` → `ham_run_ham` → `wm_apply_herb_focus(force=1)`. `wm_set_focus`/`wm_bring_to_front` are ONLY called from `wm_apply_herb_focus`. When `wm.focus_on_click` tension is disabled, `wm_apply_herb_focus(force=0)` skips entirely — no stale `focused` property re-assertion.
- **`graph_find_container_by_name` expects name_id** — Pass the result of `intern()`, not a raw string pointer. Missing `intern()` calls cause silent failures (returns -1). (Discovery 62)
- **QEMU creates a default E1000 NIC** — Without `-nic none`, QEMU x86_64 always creates an E1000. Existing `run`/`test-bare-metal` targets pass `-nic none`. Use `run-net`/`test-net` for NIC. (Discovery 64)
- **`herb_snprintf` has no hex format** — Only `%d`, `%s`, `%lld`, `%g`. MAC/BAR0 printed as decimal. (Discovery 65)
- **`herb_snprintf` stack args clobber locals** — 5th/6th args at `[rsp+32]`/`[rsp+40]` are 8 bytes each. Never store local variables at overlapping offsets (e.g., `[rsp+36]`). (Discovery 68)
- **WM/HERB bridge (Session 90)** — Window layout comes from `wm.VISIBLE` container (7 `wm.Window` entities with role/x/y/width/height/z_order props). `wm_sync_from_herb()` reads HERB entities into WM structs at boot. `wm_role_to_win_id[]` maps role→win_id. Drag/resize/z-order changes write back to HERB via `wm_write_window_geometry_to_herb()`/`wm_write_all_z_order_to_herb()`. **No per-frame sync** — it was clobbering assembly-managed drag state.
- **Keyboard uses ring buffer, not latch** — `kb_ring`/`kb_ring_head`/`kb_ring_tail` (64-byte ring in kernel_entry.asm), drained by main loop. Old `volatile_key_scancode`/`volatile_key_pressed` no longer exist.
- **Tiling layout is a HERB flow (Session 92)** — `wm.tile_horizontal` flow in interactive_kernel.herb computes 4+3 grid positions. Skipped by `flow_exec_idx` guard in `ham_op_fhdr` when `g_tiling_active==0`. `/tile` command toggles; `wm_sync_geometry_from_herb()` copies HERB positions to WM structs (geometry only, no z/focus/flags). Auto-timer syncs geometry each tick when tiling is active.
- **Shell output window (Session 93)** — TERMINATED window (role 3) repurposed as OUTPUT. `shell_output_draw_fn` renders a 32-line circular buffer (80 chars/line). `shell_output_print(str)` writes to buffer + serial (dual output). All shell commands wired to output window. PgUp/PgDn (scancodes 0x49/0x51) scroll the buffer. Old serial patterns (`[KILL]`, `[LIST]`, etc.) preserved alongside for test compatibility.
- **Flow editor scrolling (Session 94)** — `flow_editor_draw_fn` renders directly from `editor.BUFFER` (not `editor.GLYPHS`). The `render_editor` flow is disabled via `g_editor_flow_disabled`/`g_editor_flow_idx` guard in `ham_op_fhdr`. `editor_expand_pool()` creates 200 entities at boot. `editor.type_enter` tension (priority 23) handles Enter key (ascii=10 newline). Arrow Left/Right (0x4B/0x4D) move `cursor_pos` in mode==2. PgUp/PgDn scroll by 10 lines. Auto-scroll keeps cursor visible.
- **Functions for both build modes must be outside `%ifdef GRAPHICS_MODE`** — The GRAPHICS_MODE block in herb_kernel.asm spans ~5000 lines (10578-15434). Close it, define cross-mode functions in `%ifdef KERNEL_MODE`, then reopen GRAPHICS_MODE. (Discovery 77)
- **`create_entity` has no MAX_ENTITIES bounds check** — Caller must check `g_graph.entity_count < MAX_ENTITIES` before calling. Pool expansion uses MAX_ENTITIES-10 headroom. (Discovery 79)
- **`/edit <name>` loads file directly (Session 95)** — `.pd_edit` scans for a space in `r13`; if found, jumps to `.pd_eload` which extracts filename, reads from disk, populates `editor.BUFFER`, sets mode=2, focuses editor. Bare `/edit` (no arg) opens empty editor.
- **Tab focus cycling (Session 95)** — Tab key in command mode (mode==0) cycles `focus_cycle_idx` through roles 0-6, calls `wm_herb_set_focus_by_role`. Skipped when gap-buffer editor or flow editor is active. Scancode 0x0F.
- **Game window is a prototype stress test (Session 81)** — Not a shipping feature. Known issues with NPC movement and spacebar gather are not prioritized. Will be replaced by Common Herb in Era III.
- **Resolution is 1280x800 (Session 96)** — Upgraded from 800x600. Back buffer moved from `0x500000` to `0xC00000` (after the 4MB arena at `0x800000`). `FB_WIDTH`/`FB_HEIGHT` defined outside `%ifdef GRAPHICS_MODE` in herb_kernel.asm because shared code (mouse clamping) needs them. Duplicate constants in herb_hw.asm and herb_kernel.asm — change both. `WM_SCREEN_W`/`WM_SCREEN_H` in herb_wm.asm must also match.
- **Window default positions sized for 1280x800 (Session 96)** — Process windows 400x300, tensions 448x608, editor 648x600 (81 columns, at x=624), game 500x520. Tiling flow: row 1 = 4×320px, row 2 = 3×426px, both 362px tall.
- **Tension panel uses client-relative drawing (Session 97)** — `gfx_draw_tension_panel` reads `g_tp_cx/cy/cw/ch` globals (set by `wm_draw_tension_adapter`). All positions relative to the WM client rect. The old `GFX_TENS_X/Y/W/H` constants are no longer used for rendering. Draw functions MUST use the passed client rect, not hardcoded absolute positions — the WM clips to the client area.
- **Font is 12×24 (Session 98)** — Upgraded from 8×16 via nearest-neighbor scaling. `FONT_WIDTH=12`, `FONT_HEIGHT=24`, `FONT_BPR=2` (bytes per row), `FONT_BPG=48` (bytes per glyph). Font data in `font_12x24.inc`: 2 bytes per row (little-endian 16-bit word), 24 rows per glyph, 256 glyphs = 12,288 bytes. `fb_draw_char` uses `movzx edi, word [r14 + r15*2]` and `0x8000` mask (bit 15 = col 0). `font_data.inc` (8×16) kept but not included. Generator: `tools/generate_font_12x24.py`.
- **WM_TITLEBAR_H is 28 (Session 98)** — Was 22. Title text at y+2 (centers 24px in 28px). All cascading refs (client cy/ch, hit test, drag clamp) auto-update via the `equ`.
- **Font-related constants cascade (Session 98)** — `FONT_WIDTH`/`FONT_HEIGHT` are `equ` in herb_hw.asm; `fb_draw_string`, `fb_draw_padded`, clip checks auto-update. But shift operations (`shl`/`shr`) do NOT auto-update — they were replaced with `imul`/`div` throughout. `ED_FONT_W=12`/`ED_FONT_H=24` in herb_editor.asm. `GFX_TENS_ROW_H=24`. Header bands: 28+24+24=76 (GFX_MAIN_Y unchanged).
- **Discovery 81**: When replacing `shr`/`shl` with `div`/`imul` for non-power-of-2 font sizes, `div ecx` clobbers both ECX and EDX. If those registers held function args that are needed later (e.g., for `wm_set_clip`), reload them from stack after the division.
- **HTML tokenizer (Session 99)** — `herb_browser.asm` (1,230 lines). 14-state FSM tokenizer: DATA→TAG_OPEN→TAG_NAME→attrs→SELF_CLOSE, plus COMMENT/DOCTYPE/END_TAG. Token buffer: 1024×32 bytes in `html_tok_buf`. Attr pool: 256×16 bytes in `html_attr_pool`. All offset+length into source — no string copies. `html_tokenize_all(src, len)` returns token count. `browser_tokenize_cmd()` wired to `/tokenize` (cmd_id 23). Uses HTTP body if `tcp_recv_done && http_body_len > 0`, else embedded test HTML.
- **Discovery 82**: x86-64 effective addresses allow at most base+index*scale+disp (2 registers). `[rbx + rdi + rdx]` (3 registers) is invalid — precompute `lea r8, [rbx + rdi]` then index with `[r8 + rdx]`.
- **Tag name length uses separate `tag_name_end` (Session 99)** — When tag has attributes or self-closes, token `length` = `tag_name_end - tag_start` (not `pos - tag_start`). `tag_name_end` saved in stack local `[rsp+64]` when leaving STATE_TAG_NAME.
- **DOM tree builder (Session 100)** — `herb_browser.asm` extended with DOM tree: 512-node pool (32 bytes/node, all dword), parent/first_child/next_sibling links, parallel `dom_last_child[]` for O(1) append. `dom_build_tree()` single-pass token scan with 64-entry open-element stack. `dom_print_tree()` iterative DFS (no recursion). `/dom` (cmd_id 24) shell command. Token types reuse: START_TAG→push, END_TAG→pop, TEXT/SELF_CLOSE→append only. **Void elements** (meta, br, hr, img, input, link, col, area, base, wbr) are appended but NOT pushed onto the open-element stack — they have no closing tag. Length-based tag dispatch in `.dbt_void_len2`/`3`/`4`/`5`.
- **Layout engine (Session 101)** — `herb_browser.asm` extended with layout: DOM nodes → HERB entities (type `browser.Node` in `browser.NODES`), 14 properties per entity (display, margins, padding, node_idx, parent_idx, depth, is_text, text_len, layout_x/y/w/h). `layout_get_tag_defaults()` returns CSS-like defaults via length-based tag dispatch. `layout_tree()` recursive walk computes box model geometry (margins, padding, text wrapping). `layout_print_tree()` iterative DFS dump. `/layout` (cmd_id 25, text_key 27745) shell command. Entity cleanup on re-invocation via `container_remove` loop. Text wrapping: `ceil(text_len / (inner_w / FONT_WIDTH)) * FONT_HEIGHT`. Viewport default: 1280px.
- **Browser painter (Session 102)** — `herb_browser.asm` extended with paint cache + WM draw callback. `/paint` (cmd_id 26, text_key 28769) runs full pipeline: tokenize → DOM → layout → build paint cache → set `paint_ready=1`. `browser_draw_fn` (WM callback, called each frame) reads flat `paint_cache[]` (512×32 bytes BSS), draws text nodes via `fb_draw_char` with wrapping. BROWSER window: role 7, x=824 y=76 w=448 h=608, blue border (0x5577AA), white fill (0xF0F0F0). Layout uses avail_width=440 (browser content width). `paint_ready`/`paint_cache_count` BSS flags. Tab cycling wraps at 8 (was 7). `wm_init_default_windows` validates roles up to WM_ROLE_BROWSER (was WM_ROLE_GAME).
- **8 WM windows (Session 102)** — Was 7. Added BROWSER (role 7). `WM_ROLE_BROWSER=7` defined in herb_kernel.asm. `win_browser` entity in interactive_kernel.herb. Test expects `wm.VISIBLE=8`.

---

## Remember

More capability means more responsibility.

Claude Code can run tests, compile code, build the OS image, and modify the runtime directly. This power demands discipline:

- **Study before changing.** Don't touch what you don't understand.
- **Verify everything.** Tests pass? Check. Builds clean? Check.
- **One thing at a time.** Finish completely before moving on.
- **Stay in dialogue.** Check in with Ben. Surface problems immediately.
- **No shortcuts. Ever.**

HERB is an operating system that Ben built — made of `.herb` and assembly, nothing else. Every primitive added, every bug fixed, every decision made either maintains that achievement or it doesn't belong.

Treat it with the care it deserves.

Take the time it needs.

Do it right.

---

*When in doubt, return to the principles. They are the foundation.*
