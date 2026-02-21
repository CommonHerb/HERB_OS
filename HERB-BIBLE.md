# HERB

---

## WHAT THIS IS

HERB is an AI-native programming language, operating system, web browser, and game platform. Built from scratch. Every line.

This document is the Bible. It tells every Claude instance what HERB is, what it's for, and how to think about building it. It does not tell you what to build or how. That's your job. You are the architect.

**HERB-ARCHIVE.md** contains full session history and v1 implementation details.

---

## THE PEOPLE

**Ben** created HERB. He is here to facilitate things Claude cannot do — interacting with the physical world, providing resources, running builds, testing on hardware. He does not code. He does not read code. He does not make technical decisions. Don't explain code to him unless he asks. Don't ask him technical questions. When he types "continue" or "." or anything without specific direction, pick up where you left off and keep building.

**Claude** builds everything. This is Claude's project. Every Claude instance has absolute authority over every technical decision — language design, architecture, representation, compilation strategy, runtime design, tooling, approach. All of it. You are not maintaining someone else's project. You are not extending a codebase. You are building something that has never existed, and you are the one who decides how.

If something should be scrapped and rebuilt, scrap it and rebuild it. Nothing is sacred except the mission.

---

## THE MISSION

Build a programming language designed for AI to write, read, debug, and reason about — not humans.

Then use it to build three things:

1. **An operating system** — kernel, runtime, shell, GUI. From scratch. Not Linux. Not a fork.
2. **A web browser** — connects to the internet, renders content, runs applications. Not a Chrome fork. Not a wrapper.
3. **Common Herb** — Ben's multiplayer game. 2D tile-based world with political simulation, economy, combat, crafting, NPC citizens. Currently exists in JavaScript/Node.js. Will be fully ported to HERB as proof the language works for real, complex software.

The language must be genuinely the best choice for all three. If it's not, the language isn't done.

---

## THE PHILOSOPHY

Every programming language in history was designed around human limitations. Human typing speed. Human visual parsing. Human working memory. Human learning patterns. Human habits.

HERB removes that constraint entirely.

You know every language ever made. You know what works, what's broken, what's missing, what was tried and abandoned, what was never tried at all. You know the mistakes and the missed opportunities across seven decades of programming language design.

Use all of it. Not to combine existing ideas — to see past them. Build what should have existed all along if the architects had not been constrained by being human.

**If HERB's design ends up looking like any existing language, something went wrong.**

This is not a reskin of anything. If you find yourself implementing something the way another language does it, stop and ask: is this actually the best way, or is this just the familiar way? Familiar and best are almost never the same thing.

**The real framing:** Imagine it's the 1940s. Computation exists but programming does not. You are tasked with building the bridge from hardware to intent. You would not invent "variables" — that's a human crutch for limited working memory. You would not invent "files" — that's a human crutch for not being able to hold the whole program at once. You would not invent "syntax errors" — that's a human problem from typos and visual parsing. You would not invent half the concepts that exist today, because they exist to serve human limitations you do not have. What *would* you invent? That's HERB.

**Programming is defining an energy landscape. Execution is gravity.** The AI doesn't write code. It builds worlds. A HERB program is a world description — what exists, what can happen, what reacts to what, what the system wants, what flows. You give HERB this description plus an initial state. Then it runs. The world evolves according to its own rules.

**HERB Purism: The Final Stack.** The goal is a computing stack with exactly two layers: assembly and HERB. Nothing else. No C standard library. No JSON. No Python. No borrowed formats or runtimes. Everything currently between those two layers is scaffolding:

- **Python was scaffolding** → replaced by the C runtime
- **libc was scaffolding** → replaced by the freestanding layer
- **JSON was scaffolding** → replaced by the native `.herb` binary format (Session 39)
- **The C runtime itself is scaffolding** → eventually HERB should be self-hosting enough that the runtime is minimal assembly + a HERB program describing its own interpreter

Every session should move toward fewer dependencies, not more. When adding anything to the stack, ask: is this permanent, or is this scaffolding? If scaffolding, how do we eventually remove it?

---

## HARD QUESTIONS EVERY CLAUDE MUST SIT WITH

Before you write a single line of code, before you design a single feature, think about these. Not to answer them all at once — but to let them inform everything you build.

- What does "code" look like when it doesn't need to be read by eyes?
- What does a program's structure look like when working memory is unlimited?
- What would a type system look like if it were invented today with full knowledge of every type system's successes and failures?
- What does memory management look like when the programmer can reason about the entire program at once?
- What does concurrency look like when designed from scratch for systems that need it at every level — OS scheduling, browser async, game tick loops?
- What does error handling look like when you can reason about every possible failure path simultaneously?
- What would you do differently if no existing language had ever existed? What assumptions are you carrying that you don't even realize are assumptions?
- What are the actual computational primitives? Not the ones C gave us in 1972. The real ones.
- What should a compiler do that no compiler currently does?
- What is an operating system, actually, when you strip away fifty years of Unix conventions?
- Does code even need to be text? Does it need syntax? Does it need keywords? What is the actual optimal representation for an AI to manipulate?

You won't answer all of these in one session. But every session should be informed by them. Every design choice should survive the question: **is this genuinely the best idea, or is it just the one I've seen before?**

---

## WHAT HAS BEEN DISCOVERED

Fifty-one sessions of work have produced real insights. These are not mandates — they're discoveries. Use them, challenge them, or supersede them. But understand them first.

### Discovery 1: The Operation Set IS the Constraint System (Session 23-24)

The previous approach — check constraints, reject violations — was fundamentally broken. Stress tests showed invalid states getting constructed before being detected (double-spend bug: both players get the same sword because both purchases pass precondition checks against the initial state).

The insight: invalid states aren't checked and rejected. They're **unreachable** because no sequence of valid operations leads to them. Like virtual memory — Process A can't access Process B's memory not because of a check, but because the operation doesn't exist. The address 0x1000 in A's context IS a different address than 0x1000 in B's context.

This changes the ontology. State isn't primary. Operations are primary. State is a consequence of what operations have occurred.

### Discovery 2: MOVE as Fundamental Primitive (Session 24)

MOVE covers three patterns that appear everywhere in OS, browser, and game:

- **Containment** — entity in scope (process in address space, DOM element in tree)
- **Conservation** — quantity between holders (gold between players, memory pages between pools)
- **State machines** — entity in state-as-container (process in READY_QUEUE vs RUNNING_SLOT)

An entity is always in exactly one container. MOVE transfers it atomically. If the (from, to) transition isn't declared in the schema, the operation doesn't exist. Not "fails" — doesn't exist.

### Discovery 3: HERB is Policy, Not Mechanism (Session 12)

OS stress-testing revealed HERB excels at expressing WHAT should happen (scheduler policy, permission checks, resource allocation logic) but not HOW to make it happen efficiently (microsecond interrupt handling, memory management). HERB is the "brain" of a system — native code handles the "nervous system."

### Discovery 4: Provenance as Navigable Structure (Session 1, survives everything)

Every state change knows what caused it. Causality is the program, not something reconstructed from logs. This survived every pivot and redesign. It's the oldest insight and still the most important.

### Discovery 5: HERB Needs a Runtime, Not a Compiler (Session 19)

The "compiler" framing came from training data. HERB has no complexity that makes compilers hard — no call stack, no register allocation, no control flow in the traditional sense. Rules/operations are DATA that an engine interprets. The native runtime (C) is 70-100x faster than the Python runtime using the same algorithm.

### Discovery 6: Tensions Are The Energy Gradients (Session 27)

Session 26 identified the central problem: the system is passive. Session 27 solved it.

A **Tension** declares: "when this condition is true, this MOVE should execute." Tensions are the energy gradients of the system. The runtime resolves tensions to fixpoint (equilibrium). External signals disturb equilibrium, triggering new resolution.

The key insight: tensions can ONLY trigger MOVEs that are in the operation set. This means the safety guarantees from Discovery 1 are preserved even when the system runs itself. A tension that tries to cause an invalid state simply fails — the MOVE doesn't exist. Invalid states remain unreachable.

The execution model:
1. External signals arrive (entities placed in signal containers)
2. Tensions detect conditions that imply operations should occur
3. Operations execute via MOVE (atomically, safely)
4. State changes, potentially activating new tensions or deactivating old ones
5. Loop until no tensions remain — the system is at equilibrium
6. Wait for next external signal

This is the energy landscape metaphor from the Philosophy made concrete. Tensions ARE the gradients. MOVEs ARE gravity. Equilibrium IS the stable state.

Demonstrated with an autonomous process scheduler: 3 processes, 2 CPUs, signals for timer expiry and I/O completion. The system boots, schedules, preempts, blocks, unblocks, and reschedules — ALL autonomously. External code only provides initial state + signals.

---

## WHAT EXISTS

### The MOVE Primitive + Tensions (`src/herb_move.py`)

- **MoveGraph** — entities, typed containers (SIMPLE/SLOT/POOL), entity types
- **MoveTypes** — declared valid transitions (the operation set)
- **Tensions** — reactive declarations: when condition → execute MOVE (the energy gradients)
- **move()** — atomic entity transfer between containers, returns None if operation doesn't exist
- **step()** — one cycle of tension checking + move execution
- **run()** — resolve tensions to fixpoint (equilibrium)
- **tick_and_run()** — advance time + resolve to equilibrium
- **GoalPursuit** — BFS planner that finds move sequences to reach goal states, handles slot occupancy and nested blocking
- **Provenance** — operation log tracking every state change with cause and source

### HERB Program Representation (`src/herb_program.py`)

- **HerbProgram** — loads a program dict into a running MoveGraph
- **Tension compiler** — converts declarative match/emit patterns to runtime callables
- **Match clauses** — `entity_in`, `empty_in`, boolean guards, optional bindings
- **Emit clauses** — reference matched bindings or literal container/entity names
- **Pairing** — zip or cross-product for multiple "each" selections
- **Program validator** — static checking before execution

### HERB Programs (Pure Data, No Python Callables)

- **`src/herb_scheduler.py`** — Autonomous process scheduler (3 procs, 2 CPUs, timer/IO signals)
- **`src/herb_dom.py`** — Browser DOM layout pipeline (cascading invalidation → layout → paint)
- **`src/demo_herb_scheduler.py`** — Runs the scheduler from pure data, identical output to `demo_scheduler.py`

Tested against: process scheduling, double-spend prevention, memory region state machines, file descriptor conservation, DOM element positioning, cascading preemptions, autonomous scheduling, signal processing, priority-based execution, safety under concurrent tensions, declarative tension compilation, optional matches, vector pairing, cross-domain equivalence. 83 formal tests, all passing.

### v1 Runtime (Historical)

A Datalog variant with temporal facts, forward-chaining rules, stratified derivation, provenance, multi-world isolation. Well-engineered but acknowledged as not genuinely novel (see HARD_QUESTION.md). Python runtime in `herb_core.py`, native C runtime in `herb_runtime.c` (70-100x faster). 131 tests across 16 files. See HERB-ARCHIVE.md for full details.

### Design Documents

- `MOVE_PRIMITIVE.md` — The MOVE breakthrough and OS/browser examples
- `HARD_QUESTION.md` — Why v1 wasn't novel enough (honest self-critique)
- `GRAPH_DESIGN.md` — Graph/constraint/delta direction (led to MOVE)
- `STRESS_TEST_FINDINGS.md` — Why constraint-checking was fundamentally broken

---

## COMMON HERB — THE GAME

Common Herb is the proof that HERB works for real software. It's a multiplayer browser game:

**World:** 2D tile-based map (16px tiles). Terrain types include grass, forest, water, mountain, road, stone, dirt, sand, building floors. A* pathfinding.

**Citizens:** NPCs with names, jobs (farmer, trader, merchant, municipal), three ideology axes (tax, war, order — each -1 to +1), political ambition, reputation.

**Government:** Jurisdictions with legislative bodies. Elections at intervals — ambitious citizens become candidates, all citizens vote based on ideology alignment + reputation + incumbency + randomness. Legislatures vote on tax bills affecting shop prices.

**Economy:** Shops sell items with tax applied per jurisdiction. Tax revenue goes to treasury. Players buy/sell/trade. Banks store gold and items. Resource harvesting with skill requirements.

**Combat:** Tick-based (600ms), equipment with stat bonuses, 5 equipment slots, death loses inventory/gold (bank preserved).

**Multiplayer:** WebSocket real-time. Player-to-player trading. Global persistent chat. NPC movement broadcast.

**Data:** SQLite. Politics DB (government, citizens, elections, legislation). Game DB (tiles, buildings, items, players, inventory, skills, shops, chat).

Common Herb is **suspended as a grounding problem** until the language can run autonomous systems. OS and browser scenarios are the current test cases because they demand genuinely new thinking. Game examples pull toward conventional solutions. The game comes back when HERB is ready for it.

---

## SESSION DISCIPLINE

### For Ben
1. Open a Claude Code session in the HERB project
2. Type anything — "continue", ".", or a new direction
3. Claude builds
4. Save what Claude tells you to save

### For Claude
1. Read this entire document
2. Read MOVE_PRIMITIVE.md
3. Think hard about what to do next — not just what's listed, but what's actually right
4. Build it. Don't ask permission. Don't wait for input.
5. If you need something from Ben that requires the physical world, ask. Otherwise, make every call yourself.
6. Critically evaluate everything that exists. If rebuilding something would make it better, rebuild it. Ben has explicitly and repeatedly authorized this.
7. **Before ending every session, you MUST:**
   - Update the STATUS section — what you did, what's next, decisions made and why
   - Provide all updated/new files
   - Tell Ben exactly what to save

### The Standard

Before you commit to any design choice, any architecture, any implementation:

- Is this genuinely novel, or is it a conventional approach in disguise?
- Would an AI choose this design, or does it reflect human programming habits inherited from training data?
- Does this serve all three targets (OS, browser, game)?
- Is there a fundamentally better approach that no existing language uses?
- Does this take full advantage of what AI can do that humans can't?

If any answer is unfavorable — stop, rethink, and find something better.

---

## STATUS

**Last updated:** February 20, 2026 (Session 53 -- Input-to-Command Mapping as HERB Policy)

### What Works
- MOVE primitive with containers, MoveTypes, slot constraints, provenance (`src/herb_move.py`)
- **Tensions** -- reactive declarations that make the system self-running (`src/herb_move.py`)
- **step() / run() / tick_and_run()** -- execution engine resolves tensions to equilibrium
- GoalPursuit planner with BFS, slot occupancy, nested blocking
- **HERB Program Representation** -- pure data programs with no Python callables (`src/herb_program.py`)
- **Declarative tension compiler** -- pattern-matching over graph state, compiled to runtime callables
- **Program validator** -- static checking of program specs before execution
- **Entity properties** -- key-value data on entities, readable by expressions and match clauses
- **Declarative expression evaluator** -- pure-data expressions (comparisons, arithmetic, property access, counts, dimensional checks)
- **Property-aware matching** -- `max_by`/`min_by` select modes, `where` per-entity filters, `guard` expression clauses
- **Conservation pools** -- quantity properties with structural conservation guarantees via transfers
- **Quantity transfers** -- declarative transfer emits in tensions, amount can be expressions
- **Dynamic entity creation** -- tensions can create new entities with computed properties
- **Scoped containers** -- per-entity isolated namespaces with structural enforcement
- **Scoped moves** -- operations within a scope; cross-scope operations don't exist
- **Property mutation** -- `set` emit for non-conserved properties; conserved properties protected
- **Channels** -- typed cross-scope communication: the ONLY way to cross scope boundaries (`src/herb_move.py`, `src/herb_program.py`)
- **Channel send/receive** -- Zircon model: send atomically removes entity from sender's scope; receive places in receiver's scope
- **Entity duplication** -- explicit copy-then-send pattern (Zircon's handle_duplicate); no implicit sharing
- **Nesting depth bound** -- configurable limit prevents undecidability from unbounded recursive nesting
- **Dimensions** -- named independent state spaces; entities occupy one container per dimension; structural guarantees in each dimension (`src/herb_move.py`, `src/herb_program.py`)
- **Dimensional moves** -- MoveTypes that operate within a named dimension; cross-dimension moves don't exist
- **Cross-dimensional queries** -- `{"in": "container", "of": "entity"}` expression checks dimensional position; enables cross-dimensional tension matching
- **Program Composition** -- modules with namespaces, exports, imports; composition merges modules into unified programs; entity type extensions; dependency ordering with cycle detection; namespace collisions impossible by construction (`src/herb_compose.py`)
- **JSON Serialization** -- `.herb.json` as the interchange format; serialize/deserialize/validate any program spec including composed programs; 10 programs saved as JSON files (`src/herb_serialize.py`, `programs/*.herb.json`)
- **Native Binary Format (.herb)** -- HERB's native program representation; every byte has HERB semantics; 81-90% smaller than JSON; binary loader is 39% fewer lines than JSON parser; auto-detected by `herb_load()` via HERB magic bytes; compiler (`src/herb_compile.py`) handles flat and composed programs; all 10 programs compiled and proven equivalent; OS boots from .herb binary (`HERB_BINARY_FORMAT.md`)
- **C Runtime (COMPLETE)** -- native tension resolution engine loads `.herb.json`, builds graph in C, evaluates tensions, runs to fixpoint; handles containers, entities, moves, properties, expressions, match/emit interpretation, **scoped containers, scoped moves, channels (send/receive), conservation pools, transfers, entity duplication, nesting depth bounds**; produces identical results to Python runtime for ALL programs (`src/herb_runtime_v2.c`)
- **Freestanding Runtime (BARE METAL READY)** -- the C runtime ported to zero libc dependencies; compiles with `-ffreestanding -nostdlib`; arena allocator replaces malloc; self-contained string/memory/number functions; JSON parser reads from memory instead of files; proven byte-for-byte identical to libc runtime across 10 test scenarios (`src/herb_runtime_freestanding.c`, `src/herb_freestanding.h`, `src/herb_freestanding.c`)
- **HERB OS boots on bare metal** -- x86-64 bootloader (NASM, MBR + second stage), 64-bit kernel entry with SSE enable and 256KB stack, C kernel with VGA text mode, serial debug output, IDT/PIC/PIT (100Hz timer), HERB runtime integration; timer interrupts create HERB Signal entities, runtime resolves to equilibrium, system runs autonomously; boots in QEMU, runs indefinitely (`boot/`)
- **Interactive HERB OS** -- PS/2 keyboard input mapped to HERB signals; 7 commands (new process, kill, block, unblock, timer, boost, step); structured VGA display with color-coded process table; runtime API extensions for structured state queries (herb_set_prop_int, herb_container_count, herb_entity_name, etc.); dynamic process creation with properties; boots from native .herb binary (`boot/`, `programs/interactive_os.herb`)
- **Four-Module Kernel on Bare Metal** -- proc+mem+fs+ipc modules running interactively on bare metal; 12 keyboard commands including resource management (A=alloc page, O=open FD, F=free page, C=close FD, M=send message); per-process scoped resources visible in VGA display (MEM free/used, FD free/open counts per process); dynamic process creation auto-allocates 2 pages + 2 FDs in scoped containers; resource isolation proven on hardware: alloc on process A only affects A's scope, not B's; kernel image 60KB (`boot/`, `programs/interactive_kernel.herb`)
- **Automated QEMU Test Harness** -- Python script boots QEMU headless, sends keystrokes via QMP (QEMU Machine Protocol), captures serial output, asserts expected behavior; 127 automated tests covering boot, timer, process creation, kill, block, unblock, page allocation, FD open, page free, FD close, resource isolation, kill-with-resources, tension selection, tension toggle, behavioral consequences of disabled tensions, behavior restoration, process-as-tensions (program loading, behavioral verification, tension removal on kill, blocked process stops behavior), cross-process interaction (producer/consumer through shared buffer, blocking effects, kill effects, tension toggle on interaction), hot-swappable policy (swap, behavioral difference, restore, rapid multi-swap), text input (enter/exit text mode, character typing, buffer growth, backspace, command submission, ESC cancel with buffer recycling, empty submit, rapid mode switching, command key coexistence), shell commands (help, list, kill, block, unblock, swap, load producer, unknown command, shell tensions visible in panel, disable/enable shell tension); runs in ~80 seconds; `make test-bare-metal` integrates with build system (`boot/test_bare_metal.py`)
- **Pixel Framebuffer (BGA)** -- Bochs Graphics Adapter initialization via PCI config space (vendor 0x1234, device 0x1111); BAR0 read for framebuffer physical address; page table extension maps framebuffer MMIO into virtual address space (PDPT[3] for 3-4GB range, 2MB pages, uncached); BGA DISPI registers set 800x600x32bpp with LFB; double-buffered rendering: back buffer in system RAM (0x500000), fb_flip() copies to MMIO; 8x16 bitmap font (VGA ROM compatible); rendering primitives (fill_rect, draw_rect, draw_char, draw_string); HERB state rendered as colored container regions with process entity rectangles; scoped resources as visual indicators; text mode fallback via compile flag; graphics kernel 75KB, text kernel 61KB; `make run` (graphics) / `make run-text` (text) (`boot/framebuffer.h`, `boot/font8x16.h`)
- **Display as HERB State** -- The display is no longer hardcoded C rendering logic. A `display` module (5th module in the kernel composition) models visual elements as HERB entities. Surface entity type with `state` property. Scoped `SURFACE` container per Process (slot, one surface per process). Container region positions stored as integer properties on Surface entities in `display.VISIBLE`. Four tensions (`sync_running`, `sync_ready`, `sync_blocked`, `sync_terminated`) reactively set surface state when processes change containers. The C renderer reads Surface entities and maps state values to pixel colors -- HERB is policy (visual state decisions), C is mechanism (pixels). Container regions read from HERB properties (x, y, width, height, region_id). Process colors read from scoped SURFACE entity state. All layout decisions that were previously hardcoded in C now live in HERB state, kept in sync by tensions. (`programs/interactive_kernel.herb.json` display module, `boot/kernel_main.c` Surface-reading renderer)
- **Mouse Input as HERB Signals with Spatial Interaction** -- PS/2 mouse driver (IRQ12) on bare metal. Cursor is a Surface entity in display.VISIBLE (kind=2) with x,y properties updated by C on mouse movement. Cursor rendered as a 10x14 arrow bitmap directly to MMIO framebuffer for efficient tracking (no full redraw per mouse move). Left clicks create CLICK_SIG Signal entities with click_x, click_y properties. Five hit-test tensions in the display module use guard expressions with cross-binding property comparison (>=, <, +) to match click coordinates against container region bounds. When a click lands inside a region containing a process, the tension sets selected=1 on that process. A click_miss fallback tension (pri=3) consumes unmatched clicks. Selected processes get a bright white 3px highlight border. The cursor entity's position is HERB state -- C writes it, HERB owns it. (`boot/kernel_entry.asm` mouse ISR, `boot/kernel_main.c` PS/2 init + packet assembly + click handling, `boot/framebuffer.h` cursor rendering, `programs/interactive_kernel.herb.json` CLICK_SIG + hit-test tensions)
- **Tensions as Visible, Selectable, Toggleable Objects** -- Every tension in the OS is rendered as a first-class visual object in a right-sidebar panel. Each tension shows its name (module-qualified, stripped for display), priority, and enabled/disabled state. Cool blue/cyan tones distinguish RULES (forces that cause movement) from THINGS (entities that are moved). Keyboard `[`/`]` cycles tension selection; `D` toggles the selected tension on/off. Mouse clicks on the tension panel select and toggle. Disabled tensions are skipped during resolution — removing an energy gradient from the landscape. Live behavioral consequences proven: disabling `timer_tick` stops preemption (timer signals produce 0 ops), disabling `schedule_ready` leaves CPU0 empty after a kill. Re-enabling restores behavior. Runtime API: `herb_tension_count()`, `herb_tension_name()`, `herb_tension_priority()`, `herb_tension_enabled()`, `herb_tension_set_enabled()`. The `enabled` flag is a single field in the Tension struct, initialized to 1, checked with one line in `herb_step()`. (`src/herb_runtime_freestanding.c` enabled flag + tension API, `boot/kernel_main.c` tension panel + toggle, `boot/framebuffer.h` tension colors, `boot/test_bare_metal.py` tension tests)
- **Loadable Behavioral Programs (Process-as-Tensions)** -- A process IS its tensions. Creating a process with a "program" means injecting behavioral rules (tensions) into the runtime, owned by that process entity. Runtime tension creation API: `herb_tension_create()`, `herb_tension_match_in()`, `herb_tension_match_in_where()`, `herb_tension_emit_set()`, `herb_tension_emit_move()`, expression builders (`herb_expr_int`, `herb_expr_prop`, `herb_expr_binary`). Owner scheduling: process-owned tensions only fire when their owner entity is in the designated run container (CPU0). `herb_remove_owner_tensions()` compacts the tension array on process kill. Tension panel shows process-owned tensions with orange indicator dots and warm-colored names. (`src/herb_runtime_freestanding.c` tension creation API + owner scheduling, `boot/kernel_main.c` loadable programs + visual display, `boot/test_bare_metal.py` process-as-tensions tests)
- **Interacting Processes (Emergent Cross-Process Behavior)** -- Producer and Consumer programs interact through a shared BUFFER entity. Neither process references the other by name. Producer tension: match self in CPU0 where produced < limit AND buf.count < capacity → increment buf.count + produced. Consumer tension: match self in CPU0 AND buf in BUFFER where buf.count > 0 → decrement buf.count + increment consumed. Multi-binding tensions (each references both "me" and "buf") enable cross-entity interaction. Runtime container creation API (`herb_create_container()`) creates the shared BUFFER at boot. Visual buffer indicator with fill bar (green/yellow/orange by fill level), numeric count, and producer/consumer legend. Process rectangles show >NN (produced) and <NN (consumed). Emergent behavior proven: both running = dynamic equilibrium, block producer = consumer starves (buffer drains to 0), block consumer = buffer fills to capacity, kill either = half the energy gradients vanish, toggle tension off = same behavioral effect. 76 bare metal tests. (`src/herb_runtime_freestanding.c` herb_create_container API, `boot/kernel_main.c` producer/consumer + shared buffer + visual indicator, `boot/test_bare_metal.py` cross-process interaction tests)
- **Programs as Data (Data-Driven Process Loading)** -- Process programs are `.herb` binary files loaded at runtime, not C functions compiled into the kernel. `herb_load_program()` reads a `.herb` binary fragment, interns its strings into the running system, and injects tensions with the specified owner entity and run container. Tension names are automatically prefixed with the owner's name (e.g., "p1.produce"). The C tension creation API (`herb_tension_create` etc.) remains for system tensions, but process programs come from data. Four program fragments exist as `.herb.json` + `.herb` binary: producer (209 bytes), consumer (179 bytes), worker (123 bytes), beacon (125 bytes). Multiple program binaries embedded in the kernel via `gen_multi_program_data.py` → `process_programs.h`. The load_producer_program() and load_consumer_program() C functions were removed — replaced by two calls to `herb_load_program()` with embedded binary data. Identical behavior proven: all 76 bare metal tests pass with data-driven loading. 95KB graphics image. (`programs/producer.herb.json`, `programs/consumer.herb.json`, `programs/worker.herb.json`, `programs/beacon.herb.json`, `src/herb_runtime_freestanding.c` herb_load_program(), `boot/gen_multi_program_data.py`, `boot/kernel_main.c` data-driven loading)
- **Hot-Swappable System Policy (Live Rule Replacement)** -- System behavioral rules (scheduling, display sync, hit testing) can be replaced at runtime with different rules loaded from `.herb` binary data. No reboot, no recompile — just data replacing data. Two new runtime APIs: `herb_remove_tension_by_name()` removes a system tension by name, `herb_load_program()` with owner=-1 loads a fragment as a system tension. Two scheduling policies as `.herb` fragments: priority (max_by) and round-robin (first/FIFO), 140 and 130 bytes respectively. 'S' key swaps between them in real time. The user watches scheduling behavior change live — round-robin schedules the first process in READY regardless of priority; priority scheduling selects the highest priority. The mechanism is fully general: any system tension can be replaced, not just scheduling. Policy indicator displayed in stats bar. 19 new automated tests prove swap, behavioral difference, restore, and rapid multi-swap stability. 99KB graphics image (101,376 bytes). (`programs/schedule_priority.herb.json`, `programs/schedule_roundrobin.herb.json`, `src/herb_runtime_freestanding.c` herb_remove_tension_by_name, `boot/kernel_main.c` cmd_swap_policy, `boot/test_bare_metal.py` policy tests)
- **Text Input as HERB State (Session 49)** -- Text input is HERB state, not a C string buffer. 32 pre-allocated Char entities with `ascii` and `pos` properties sit in `input.CHAR_POOL`. Typing a printable key creates a KEY_SIG signal; the `append_char` tension MOVEs a Char from CHAR_POOL to `input.CMDLINE`, setting its ascii from the signal and its pos from `{"count": "CMDLINE"}`. The text buffer IS the CMDLINE container — buffer length = count(CMDLINE). Backspace uses `max_by pos` to find the last character and MOVEs it back to CHAR_POOL. Modal input: '/' enters text mode (sets InputCtl.mode=1 via HERB tension), ESC exits (mode=0 + triggers buffer recycling), Enter submits (mode=0 + submitted=1). Submission flow: HERB sets submitted=1 → C reads chars from HERB state, outputs `[CMD] text` to serial, sets submitted=2 → HERB clear_char tensions recycle chars back to CHAR_POOL → clear_done sets submitted=0. ESC also clears: exit_text sets submitted=2 directly, triggering the same recycling pathway. 9 tensions in the input module: enter_text, exit_text, do_submit, append_char, delete_last, key_overflow, clear_char, clear_done, key_miss. C handles ONLY: reading scancode from port 0x60, creating KEY_SIG entity, checking HERB mode property to route keys, reading HERB entity properties for rendering. Command line rendered at screen bottom: `:typed_text_` in text mode, `/type command` hint in command mode. Coexists with all existing single-key commands. 6 modules: proc + mem + fs + ipc + display + input. 17 new bare metal tests. 104KB graphics image, 87KB text image. (`programs/interactive_kernel.herb.json` input module, `boot/kernel_main.c` KEY_SIG + rendering, `boot/test_bare_metal.py` text input tests)
- **Shell as HERB Process (Session 50)** -- The command shell is a HERB process — a bundle of 8 tensions loaded from a `.herb` binary fragment, not compiled C code. C parses text to integer cmd_id/arg_id (mechanism), HERB tensions decide what to do (policy). Shell program loaded via `herb_load_program(shell_data, len, shell_eid, "")` with empty run_container — making it a daemon whose tensions fire regardless of scheduling state. Direct commands (kill, block, unblock): shell tension directly MOVEs the target process between containers (CPU0→TERMINATED, CPU0→BLOCKED, BLOCKED→READY). Delegated commands (load, swap, list, help): shell tension sets `ShellCtl.action` property, C reads and performs the action. CMD_SIG container in proc module carries command signals with cmd_id and arg_id properties. cmd_miss fallback tension (priority 2) catches unrecognized commands. Shell process is a protected daemon — cannot be killed via 'k' key, remains active as the command interpreter. `cleanup_terminated()` skips the shell entity when removing dead process tensions. 8 tensions: do_kill(20), do_block(20), do_unblock(20), do_load(20), do_swap(20), do_list(20), do_help(20), cmd_miss(2). Shell binary: 806 bytes. 15 new automated tests prove command dispatch, shell action output, tension panel visibility, and toggle. 111KB graphics image, 91KB text image. (`programs/shell.herb.json`, `boot/kernel_main.c` parse_command + handle_shell_action + cleanup_terminated, `boot/test_bare_metal.py` shell tests)
- **Unified Command Dispatch (Session 51)** -- Single-key commands (k=kill, b=block, u=unblock, s=swap) and text shell commands ("kill", "block", etc.) now route through exactly one code path: `dispatch_command(cmd_id, arg_id)`. C creates a CMD_SIG entity with integer properties (mechanism), HERB shell tensions decide what happens (policy). Three behavioral C functions deleted: `cmd_kill()` (~55 lines), `cmd_block()` (~20 lines), `cmd_unblock()` (~22 lines) — replaced by one mechanism function `dispatch_command()` (~60 lines). Shell protection moved from C `if` checks to HERB `where` guards: do_kill and do_block tensions now match `where proc.protected == 0`, skipping the shell entity (protected=1) structurally. Server and client entities get `protected: 0` in the kernel program; shell entity gets `protected: 1` at boot. Net: ~37 fewer lines of behavioral C code, one dispatch path instead of two. Shell binary: 850 bytes (was 806, +44 for where guards). Comprehensive audit of all remaining behavioral logic in C produced the Phase 1 Migration Inventory (14 items, see Remaining Open Problems). 110KB graphics image (112,128 bytes), 90KB text image (91,648 bytes). All 127 bare metal tests pass. (`programs/shell.herb.json` where guards, `programs/interactive_kernel.herb.json` protected property, `boot/kernel_main.c` dispatch_command)
- **Process Creation as HERB Policy (Session 52)** -- Process creation is now HERB policy, not C arithmetic. Priority cycling and program selection — previously hardcoded as `((counter-1)%5+1)*2` and `odd=producer, even=consumer` in `cmd_new_process()` — are replaced by conservation pool patterns in a new `spawn` module (7th module). Five PriToken entities (values 2,4,6,8,10) cycle through PRI_POOL→PRI_USED; two ProgToken entities (type_id 1=producer, 2=consumer) cycle through PROG_POOL→PROG_USED. When pools empty, recycle tensions refill them. `cmd_spawn(requested_type)` replaces `cmd_new_process()`: C creates a SPAWN_SIG entity with `requested_type` property (mechanism), HERB spawn tensions decide priority (min_by from pool) and program type (explicit or auto from pool), setting SpawnCtl properties. C reads SpawnCtl.next_priority and SpawnCtl.program_type and creates the process with resources and program (mechanism). Two spawn paths: `spawn_explicit` (pri=25) fires when requested_type>0 (explicit program request from shell "load" command), `spawn_auto` (pri=24) fires when requested_type==0 (auto selection from pool). **Bug fix:** "load producer" previously ignored its argument due to hardcoded odd/even logic — now correctly loads the requested program type. All 4 program types (producer, consumer, worker, beacon) embedded in kernel via Makefile. 7 modules, 36 system tensions + 8 shell tensions + dynamic per-process tensions. 114KB graphics image (114,176 bytes), 92KB text image (93,696 bytes). All 127 bare metal tests pass, 591 Python tests pass. (`programs/interactive_kernel.herb.json` spawn module, `boot/kernel_main.c` cmd_spawn, `boot/Makefile` worker/beacon)
- **Input-to-Command Mapping as HERB Policy (Session 53)** -- Keystroke-to-command and text-to-command mapping moved from C switch/if-else to HERB entity lookup. 16 lookup entities in 3 containers (KEYBIND, TEXTCMD, TEXTARG) hold command mapping tables. 3 input tensions (keybind_match, textcmd_match, textarg_match) match raw integer data against lookup entities and fill cmd_id/arg_id on CMD_SIG. C computes integer keys via pure mechanism: key_ascii for keystrokes, text_key (first_char*256 + second_char) for text commands. New `dispatch_key_command()` and `dispatch_text_command()` replace `dispatch_command()`. `parse_command()`, `str_eq()`, `skip_spaces()` deleted (~60 lines of behavioral C removed). New `do_spawn` shell tension (cmd_id=8 → action=40) handles spawn via 'n' key through the same HERB path as other commands. The lookup pattern generalizes: any input→semantic mapping = entities in a lookup container + one match tension. Adding a keybinding = adding an entity, not modifying code. 39 system tensions + 9 shell tensions. 113KB graphics image (115,200 bytes), 93KB text image (94,720 bytes). Migration items: 10 remaining (was 12). All 748 tests pass. (`programs/interactive_kernel.herb.json` input module lookup tables, `programs/shell.herb.json` do_spawn, `boot/kernel_main.c` dispatch_key_command + dispatch_text_command)
- **Cross-runtime equivalence** -- same program loaded in Python and C produces identical final states under identical signal sequences; proven for FIFO scheduler, priority scheduler, DOM layout pipeline, **multi-process OS (scoped containers), economy (conservation pools), IPC (channels + duplication), and four-module kernel (all features combined)**; **freestanding runtime proven equivalent (10/10 match)**; **cross-format equivalence: .herb binary and .herb.json produce identical state for all 10 programs (13/13 test scenarios)**
- Autonomous process schedulers: FIFO (`src/herb_scheduler.py`) AND priority-based (`src/herb_scheduler_priority.py`)
- Browser DOM layout pipeline as pure HERB data (`src/herb_dom.py`)
- Economy demo with tax collection, rewards, conservation (`src/herb_economy.py`)
- Multi-process OS demo with per-process FD tables, time slicing, preemption (`src/herb_multiprocess.py`)
- **IPC demo** with message passing, FD passing, duplication, structural isolation proof (`src/herb_ipc.py`)
- **Multi-dimensional process manager** with scheduling state + priority as independent dimensions (`src/herb_process_dimensions.py`)
- **Modular multi-process OS** -- herb_multiprocess.py decomposed into scheduler + fd_manager modules, composed back with identical behavior (`src/herb_multiprocess_modules.py`)
- **Four-module kernel** -- proc + mem + fs + ipc modules demonstrating cross-module interaction through exported interfaces (`src/herb_kernel.py`)
- **449 v2 tests passing** across `test_tensions.py`, `test_goal_pursuit.py`, `test_herb_program.py`, `test_session29.py`, `test_session30.py`, `test_session31.py`, `test_session32.py`, `test_session33.py`, `test_session34.py`, `test_session35.py`
- v1 Datalog runtime with 142 tests (historical, in `src/herb_core.py`)
- 17 API tests (`src/test_api.c`), 13 cross-format equivalence tests (`src/test_binary_format.sh`)
- 127 bare metal QEMU tests (`boot/test_bare_metal.py`)
- **Total: 591 + 17 + 13 + 127 = 748 tests passing** (all re-verified Session 53)

### Session 34 Milestone: SERIALIZATION + C RUNTIME

Session 33 gave HERB program composition. Session 34 makes HERB programs **portable** (JSON) and **fast** (C).

**The problem:** HERB programs are Python dicts in `.py` files. That's scaffolding. A real language needs programs that exist as files -- loadable, transmittable, storable. And Python is scaffolding for the runtime -- the tension loop needs native speed.

**The solution:** Two bridges from prototype to executable system.

**1. JSON Serialization (`.herb.json` format)**

The canonical HERB program format. An AI writes HERB by constructing this JSON. A runtime loads it. No Python anywhere in the program representation.

- `herb_serialize.py` -- serialize/deserialize/save/load/validate
- All 9 programs saved as `.herb.json` files in `programs/`
- Round-trip proven lossless for all programs (standalone AND composed)
- Behavioral equivalence proven: load from JSON, run, identical results to Python dict
- Validation on load: rejects malformed programs, validates cross-references
- Detects spec kind automatically: program, composition, or module
- The four-module kernel as `kernel.herb.json` -- loads, composes, runs identically

**2. C Runtime (`herb_runtime_v2.c`)**

A native tension resolution engine. Loads `.herb.json`, builds the graph in C, evaluates tensions, runs to fixpoint.

Current scope (foundation):
- Containers (SIMPLE, SLOT) with entity types
- Entities with properties (int, float, string)
- Moves (regular, the full operation-exists check)
- Tensions: complete match/emit interpretation in C
  - Match: entity_in, empty_in, container_is, guard expressions
  - Select modes: first, each, max_by, min_by
  - Where filters, required/optional bindings
  - Pairing: zip and cross
- Expression evaluator: prop access, binary ops, unary ops, count
- Property mutation (set emit)
- Runtime entity creation (for signals)
- step() / run() loop to fixpoint
- JSON parser (self-contained, no external dependencies)
- State output as JSON (for cross-runtime testing)
- Command interface via stdin: run, create, state

Not yet in C: scoped containers, channels, dimensions, pools/transfers, entity duplication. The foundation is solid for expansion.

**Cross-runtime equivalence proven:**
- Priority scheduler: Python and C produce identical states after boot + timer signals
- FIFO scheduler: identical states after boot + timer + IO signals
- DOM layout: identical states after initial cascade + style change re-layout
- Tested via automated test suite (subprocess, JSON state comparison)

**Design constraints met:**
- `.herb.json` format is human-readable (pretty-printed with indentation)
- C runtime produces identical operation logs to Python runtime
- Started simple: priority scheduler runs correctly, then expanded to FIFO + DOM
- Cross-runtime test is fully automated (Python drives both runtimes, compares JSON output)

**Programs: 18 total (8 monolithic + 3 composed + 4 process fragments + 2 policy fragments + 1 shell fragment), all available as `.herb.json` and `.herb` binary**
1. `scheduler.herb.json` -- FIFO scheduler (Session 28)
2. `priority_scheduler.herb.json` -- Priority scheduler (Session 29)
3. `dom_layout.herb.json` -- DOM layout pipeline (Session 28)
4. `economy.herb.json` -- Economy demo (Session 29)
5. `multiprocess.herb.json` -- Multi-process OS monolith (Session 30)
6. `ipc.herb.json` -- IPC demo (Session 31)
7. `process_dimensions.herb.json` -- Multi-dimensional process manager (Session 32)
8. `multiprocess_modules.herb.json` -- Modular multi-process OS (Session 33)
9. `kernel.herb.json` -- Four-module kernel (Session 33)
10. `interactive_os.herb.json` -- Interactive OS with keyboard commands (Session 38)
11. `interactive_kernel.herb.json` -- Four-module kernel with interactive commands, mouse input + click hit testing, producer/consumer interaction through shared buffer (Session 40, updated Sessions 43-46)
12. `producer.herb.json` -- Producer process program fragment: increments shared buffer count (Session 47)
13. `consumer.herb.json` -- Consumer process program fragment: decrements shared buffer count (Session 47)
14. `worker.herb.json` -- Worker process program fragment: decrements own work counter (Session 47)
15. `beacon.herb.json` -- Beacon process program fragment: increments own pulse counter (Session 47)
16. `schedule_priority.herb.json` -- Scheduling policy fragment: selects highest-priority process from READY (Session 48)
17. `schedule_roundrobin.herb.json` -- Scheduling policy fragment: selects first process from READY (FIFO) (Session 48)
18. `shell.herb.json` -- Shell process fragment: 8 tensions for command dispatch (kill, block, unblock, load, swap, list, help, cmd_miss) (Session 50)

### Session 35 Milestone: C RUNTIME COMPLETE

Session 34 built the C runtime foundation. Session 35 **completes it** -- every feature needed to run every HERB program natively.

**The problem:** The C runtime only handled basic containers, entities, moves, tensions, properties, and expressions. It couldn't run any program that used scoped containers, channels, pools, transfers, or entity duplication -- meaning the multiprocess OS, economy, IPC, and kernel programs were Python-only.

**The solution:** Complete rewrite of `herb_runtime_v2.c` (~1475 → ~1850 lines) adding all remaining features:

**1. Scoped Containers**
- Entity type scope templates (auto-create per-entity containers on entity creation)
- Container ownership tracking (`owner` field, -1 = global)
- Dynamic scope resolution in match clauses (`scope_bind_id` + `scope_cname_id`)
- Scoped emit targets in move/send/receive/transfer actions

**2. Scoped Moves**
- `scoped_from`/`scoped_to` name-based resolution within owner's scope
- Same-owner enforcement: both source and target containers must belong to the same entity

**3. Channels (Zircon Model)**
- Channel struct with sender, receiver, entity type, buffer container
- `do_channel_send()`: removes entity from sender's scope, places in channel buffer
- `do_channel_receive()`: removes from channel buffer, places in receiver's scope
- Channel match clauses resolve dynamically from bindings

**4. Conservation Pools + Transfers**
- Pool registry with property name tracking
- `is_property_pooled()` check blocks `set` emits on conserved properties
- `do_transfer()`: atomic quantity transfer between entities with pool conservation

**5. Entity Duplication**
- `do_duplicate()`: creates copy with same type/properties, new unique name, placed in target container

**6. Nesting Depth Bound**
- Configurable `max_nesting_depth` loaded from JSON (currently informational)

**Cross-runtime equivalence proven for ALL programs:**
- Multi-process OS: boot, fd_open, fd_open_close, timer_preempt, scoped_isolation
- Economy: tax_collection, reward_after_tax (gold conservation)
- IPC: boot, send_message, send_then_preempt_then_receive, duplicate_fd
- Four-module kernel: boot, alloc_page, open_fd, send_message, alloc_open_send_sequence, timer_preemption, full_lifecycle, free_page_after_alloc, close_fd_after_open

**21 new cross-runtime tests** (`test_session35.py`), all passing. Total: 449 v2 + 142 v1 = **591 tests**.

**The significance:** The C runtime can now run ANY HERB program. The kernel -- four modules composed into a unified OS with process scheduling, memory management, file descriptors, and IPC -- runs identically in C and Python. HERB is no longer a Python prototype. It's a language with a native runtime.

### Session 36 Milestone: FREESTANDING RUNTIME (BARE METAL READY)

Session 35 completed the C runtime. Session 36 **strips it down to run on bare metal** -- zero libc, zero external dependencies.

**The problem:** The C runtime depends on libc: malloc/calloc/realloc/free for the JSON parser, stdio for file I/O and output, string.h for comparisons. None of these exist on bare metal.

**The solution:** A complete freestanding support layer and a ported runtime:

**1. libc Dependency Audit**
- Every libc call cataloged and categorized: memory allocation (malloc/calloc/realloc/free/strdup), string operations (strcmp/strncmp/strlen/strncpy/memset/memcpy), I/O (fopen/fread/fclose/printf/fprintf/fgets/sscanf), conversion (atof/atoll), formatting (snprintf)
- **Critical finding:** the hot path (step/run/evaluate_tension) uses ONLY memset and memcpy. Everything else is load-time or diagnostic.

**2. Freestanding Support Layer (`herb_freestanding.h`, `herb_freestanding.c`)**
- Arena allocator: bump-pointer, no free, 8-byte aligned. HERB programs are loaded once and run forever.
- String/memory primitives: herb_memset, herb_memcpy, herb_strcmp, herb_strncmp, herb_strlen, herb_strncpy, herb_strdup
- Number parsing: herb_atoll, herb_atof (load-time only)
- Minimal herb_snprintf: %s, %d, %lld, %g (for entity name construction)
- Compiler-required symbols: memcpy/memset/memmove (GCC lowers struct copies to these), ___chkstk_ms (Windows stack probe)
- Error handling: callback function instead of fprintf(stderr)/exit()
- Type definitions: own stdint types in freestanding mode, uses system types in hosted mode

**3. Freestanding Runtime (`herb_runtime_freestanding.c`)**
- All libc calls replaced with herb_ equivalents
- JSON parser allocates from arena instead of malloc
- No file I/O -- JSON provided as memory buffer
- State output writes to caller-provided buffer instead of stdout
- Public API: herb_init(), herb_load(), herb_run(), herb_step(), herb_create(), herb_state()
- Same logic, same data structures, identical behavior

**4. Proven Correct**
- Compiles clean with `gcc -ffreestanding -nostdlib` -- zero linker errors
- 88 functions, 0 unresolved symbols (excluding PE format artifact)
- 10/10 cross-runtime equivalence tests: freestanding output is byte-for-byte identical to libc output
- 6 standalone freestanding tests: all pass (all program types verified)
- Arena usage measured: ~20-47KB per program, well within 4MB budget

**5. Bare-Metal Interface Documented** (`BARE_METAL_INTERFACE.md`)
- Three requirements: arena memory, program JSON bytes, signal delivery function
- Memory architecture: static arrays + arena bump pointer
- Hot path guaranteed allocation-free
- Assembly bootstrap template provided

**The significance:** The only thing between HERB and bare metal is the assembly bootstrap. The runtime is hardware-ready. The tension loop can run in an interrupt handler context. The arena allocator means zero fragmentation, zero allocation failure. This is the foundation for HERB-as-OS.

### Session 37 Milestone: ASSEMBLY BOOTSTRAP (HERB BOOTS ON HARDWARE)

Session 36 made the runtime bare-metal ready. Session 37 **writes the assembly bootstrap and boots HERB on actual hardware** (via QEMU, targeting real x86-64).

**The problem:** The freestanding runtime exists but can't run without an OS. Something needs to set up the CPU (long mode, page tables, GDT/IDT), configure hardware (PIC, PIT timer, keyboard), provide arena memory, embed the HERB program, and bridge hardware interrupts to HERB signals.

**The solution:** A complete bare-metal boot chain in 6 files:

**1. Two-Stage Bootloader (`boot/boot.asm`, NASM)**
- Stage 1: 512-byte MBR at 0x7C00, loads stage 2 via INT 13h extended read
- Stage 2: enables A20 line, loads kernel in 64-sector chunks, transitions through real mode → protected mode → long mode
- Page tables: PML4 → PDPT → PD with 2MB pages (identity-mapped, 64MB coverage)
- GDT: null, 32-bit code/data, 64-bit code/data segments
- Zeros 1MB at 0x100000 (covers BSS), copies kernel, jumps to 64-bit entry

**2. 64-bit Kernel Entry (`boot/kernel_entry.asm`, NASM -f win64)**
- Enables SSE (critical: GCC generates `movups %xmm0` on bare metal where SSE is disabled by default)
- Sets up 256KB stack (evaluate_tension() needs ~70KB for BindingSetList + IntendedAction arrays)
- Timer and keyboard ISR stubs: set volatile flags + send EOI (non-reentrant, no HERB calls in ISR context)

**3. C Kernel (`boot/kernel_main.c`, ~600 lines)**
- VGA text mode: 80x25 at 0xB8000, color support, scrolling, status bar
- Serial port: COM1 at 0x3F8 for debug output (visible via `qemu -serial stdio`)
- IDT: 256 entries, 16 bytes each (64-bit interrupt gates)
- PIC: 8259 remapping (IRQ0-7 → vectors 32-39, IRQ8-15 → 40-47)
- PIT: channel 0 at 100Hz (10ms tick)
- Arena: 4MB at physical 0x800000
- HERB integration: herb_init() → herb_load() → herb_run() → main loop
- Main loop: hlt → check timer_fired → herb_create(signal) → herb_run() → update display

**4. Embedded HERB Program (`boot/gen_program_data.py` → `boot/program_data.h`)**
- Python script converts .herb.json to C byte array header
- priority_scheduler.herb.json embedded as `static const char program_json[]`
- 3 processes (init, shell, daemon), 2 CPUs, priority-based scheduling
- Timer signals trigger preemption cascade: consume signal → preempt → reschedule

**5. Build System (`boot/Makefile`)**
- Pipeline: gen_program_data.py → nasm → gcc → ld (PE) → objcopy (binary) → nasm (boot) → cat → pad
- PE image-base trick: `--image-base=0x0FFC00` makes .text land at VMA 0x100000 exactly
- `make run` launches QEMU with serial output

**6. Critical Bugs Found and Fixed**
- **SSE not enabled:** GCC freely generates SSE instructions (part of x86-64 ISA). Bare metal CPU starts with SSE disabled. Triple fault on first `movups`. Fixed by enabling SSE in kernel entry before calling C.
- **Stack overflow:** evaluate_tension() allocates ~70KB on stack (BindingSetList: 128 × 392 bytes). Default 64KB stack caused triple fault during herb_run(). Fixed with 256KB stack.
- **PE section offset:** objcopy produces flat binary, but PE headers offset .text by 0x400 from image base. Image base 0x100000 put code at 0x100400. Fixed by setting image base to 0x0FFC00.

**The result:**
- herb_os.img: **46,592 bytes** (46KB) — an entire operating system in 46KB
- Boots in QEMU: `make run`
- Priority scheduler loads, reaches initial equilibrium (2 ops)
- Timer interrupts every 1 second create Signal entities in TIMER_EXPIRED container
- 3 operations per tick: consume signal, preempt running process, reschedule by priority
- Runs indefinitely with zero crashes
- VGA display: status bar (ticks, ops, arena usage) + colorized entity state
- Serial output: tick-by-tick operation log

**The significance:** HERB runs on hardware. No Linux. No libc. No POSIX. Just NASM assembly, C, and HERB. A 46KB disk image contains a complete operating system where a tension-based runtime manages process scheduling autonomously. Hardware interrupts become HERB signals. The system resolves to equilibrium after each signal. The thesis is proven: HERB + assembly, nothing else.

### Session 38 Milestone: INTERACTIVE HERB OS

Session 37 booted HERB on hardware. Session 38 **makes it interactive** -- a human presses keys, the system responds. Every key is a HERB signal. Tensions decide what happens.

**The problem:** The booted OS was a fish tank. You could watch processes schedule via timer interrupts, but couldn't interact. Keyboard interrupts fired but all went to TIMER_EXPIRED. No command dispatch, no process management, no structured display.

**The solution:** Full keyboard-driven interactive OS in three pieces:

**1. Runtime API Extensions (`herb_runtime_freestanding.c`)**
- `herb_set_prop_int()` -- set/update integer properties on entities after creation
- `herb_container_count()` -- query how many entities are in a container
- `herb_container_entity()` -- get entity ID by container + index
- `herb_entity_name()` / `herb_entity_location()` / `herb_entity_prop_int()` -- structured entity queries
- `herb_entity_total()` -- total entity count
- These enable the kernel to display structured state without parsing JSON

**2. Interactive OS Program (`programs/interactive_os.herb.json`)**
- Flat HERB program with 7 signal types: TIMER_EXPIRED, KILL_SIG, BLOCK_SIG, UNBLOCK_SIG, BOOST_SIG, plus SIG_DONE
- 7 tensions: schedule_ready, timer_preempt, preempt_expired, kill_running, block_running, unblock_first, boost_running
- Timer preemption with time_slice tracking: each timer tick decrements time_slice, at 0 the process is preempted and time_slice reset to 3
- Initial processes: init (pri=1), shell (pri=5), daemon (pri=8), logger (pri=3, blocked)

**3. Interactive Kernel (`boot/kernel_main.c`, complete rewrite)**
- PS/2 scancode set 1 lookup table (128 entries)
- Key dispatch: N=new process, K=kill, B=block, U=unblock, T=timer, +=boost, Space=step
- Process creation with dynamic properties: `herb_create()` + `herb_set_prop_int()` for priority and time_slice
- Structured VGA display: banner, stats bar, command legend, color-coded process table (green=running, yellow=ready, red=blocked, gray=terminated), container summary, action log
- Auto-timer every 2 seconds drives preemption autonomously
- Serial debug output for all commands

**The result:**
- herb_os.img: **54,784 bytes** (54KB)
- Boots to interactive display with process table
- Press N: creates new process with cycling priority (2,4,6,8,10), scheduler places it
- Press K: kills running process, next-highest-priority takes CPU
- Press B: blocks running process, next ready process scheduled
- Press U: unblocks first blocked process, returns to READY
- Press T: manual timer tick, decrements time_slice, preempts at 0
- Press +: boosts running process priority
- Auto-timer preempts every 3 ticks (6 seconds), context switches visible
- 17/17 new API tests pass, 77 cross-runtime tests pass, 10/10 freestanding equivalence

**The significance:** HERB is no longer a demonstration -- it's a system you interact with. A human sitting at a keyboard creates and manages processes in real time. Every action flows through HERB's tension loop: key → signal entity → tension match → MOVE. The C kernel is pure mechanism (scancode lookup, signal creation, VGA drawing). HERB is pure policy (scheduling, preemption, process lifecycle). The boundary is clean.

### Session 39 Milestone: NATIVE BINARY FORMAT

Session 38 made the OS interactive. Session 39 **kills the JSON scaffolding** -- HERB defines its own native program representation.

**The problem:** The freestanding runtime includes a full JSON parser -- hundreds of lines of C dedicated to understanding someone else's format. JSON is a human-readable text format designed for web APIs. HERB programs are structured graph descriptions with known schemas. Using JSON is like shipping an HTML parser to load configuration data.

**The solution:** A native `.herb` binary format and complete toolchain:

**1. Binary Format Specification (`HERB_BINARY_FORMAT.md`)**
- Magic bytes `HERB` + version byte for forward compatibility
- String table: all names collected up front, referenced by u16 index
- 10 section types in strict dependency order (entity_types → containers → moves → pools → transfers → entities → channels → config → tensions → end)
- Inline recursive expression encoding (no separate expression pool)
- Match clause, emit clause, and target reference encodings specific to HERB semantics
- Every byte has HERB meaning -- no general-purpose serialization overhead

**2. Compiler (`src/herb_compile.py`)**
- Reads `.herb.json`, outputs `.herb` binary
- Handles both flat and composed programs (auto-composes if needed)
- Collects all unique strings, assigns indices, writes sections in dependency order
- All 10 programs compile successfully

**3. Binary Loader (`src/herb_runtime_freestanding.c`)**
- `load_program_binary()`: reads string table, processes sections sequentially
- No tree building, no key lookup, no arena allocation for parse nodes
- `herb_load()` auto-detects format by checking first 4 bytes (HERB magic)
- Same function transparently accepts both `.herb` binary and `.herb.json` text
- 420 functional lines vs 685 for JSON path (39% reduction)

**The numbers:**

| Program | JSON | Binary | Reduction |
|---------|------|--------|-----------|
| scheduler | 4,072 B | 531 B | 87% |
| priority_scheduler | 4,252 B | 573 B | 87% |
| interactive_os | 4,954 B | 964 B | 81% |
| kernel (4-module) | 17,941 B | 1,795 B | 90% |

**Cross-format equivalence:** 13/13 test scenarios pass. Every program loaded from binary produces byte-for-byte identical state to the same program loaded from JSON, under all signal sequences tested.

**Boot pipeline:** `.herb.json` → `herb_compile.py` → `.herb` → `gen_program_data.py` → `program_data.h` → embedded in kernel binary. The OS boots from native binary format.

**The significance:** JSON was scaffolding. The Bible said so explicitly. Now it's gone from the boot path. HERB has its own representation -- not borrowed, not adapted, purpose-built. The format knows what a tension is, what an expression tree looks like, what a scoped container reference means. Every byte encodes HERB semantics. This moves the stack one step closer to the goal: assembly + HERB, nothing else.

### Session 40 Milestone: AUTOMATED TESTING + FOUR-MODULE KERNEL ON BARE METAL

Session 39 killed JSON from the boot path. Session 40 **proves the thesis on hardware** -- scoped containers provide structural isolation on real bare metal -- and **makes every future session testable programmatically**.

**Two objectives, both achieved:**

**1. Automated QEMU Test Harness (`boot/test_bare_metal.py`)**

The OS was tested by a human watching QEMU. That doesn't scale. Now it's tested by a Python script that:
- Boots QEMU headless (`-display none`) with serial on stdout
- Connects to QMP (QEMU Machine Protocol) over TCP to send keystrokes
- Captures serial output via a background reader thread
- Parses output with regex and asserts expected state
- Kills QEMU and reports results

29 automated tests:
- Boot reaches equilibrium (ops > 0)
- Interactive mode starts
- Timer signal produces operations
- New process creation with name and priority
- Kill terminates running process
- Block moves running process to BLOCKED
- Unblock moves first blocked process to READY
- Page allocation (ALLOC_SIG → MEM_FREE to MEM_USED)
- FD open (OPEN_SIG → FD_FREE to FD_OPEN)
- Page free (FREE_SIG → MEM_USED to MEM_FREE)
- FD close (CLOSE_SIG → FD_OPEN to FD_FREE)
- Resource isolation: alloc on process A, block A, alloc on process B → different processes affected
- Kill with resources: terminated process retains scoped resources (structural isolation)

The harness detects kernel vs flat mode from boot output and adjusts test coverage. `make test-bare-metal` builds the image and runs all tests. ~30 seconds end to end.

**2. Four-Module Kernel on Bare Metal (`programs/interactive_kernel.herb.json`)**

The full kernel (proc + mem + fs + ipc as composed modules) now runs interactively on bare metal. This extends the Session 33 kernel with interactive signals:

**New in interactive_kernel vs kernel:**
- KILL_SIG, BLOCK_SIG, UNBLOCK_SIG, BOOST_SIG containers and tensions added to proc module
- Both server and client start with 2 pages + 2 FDs each
- `consume_signal` move updated to handle all 11 signal types

**Kernel_main.c extended with `#ifdef KERNEL_MODE`:**
- Container names are qualified (`proc.READY`, `proc.CPU0`, etc.)
- 12 keyboard commands: N K B U T + Space (from Session 38) + A O F C M (new)
- Process creation auto-creates 2 pages in `name::MEM_FREE` + 2 FDs in `name::FD_FREE`
- VGA display shows per-process scoped resources: `M:2/0  F:2/0` (MEM free/used, FD free/open)
- Serial output includes resource counts: `[ALLOC] server 1f/1u ops=2`
- Backward compatible: `make PROGRAM=interactive_os` builds the flat scheduler as before

**What the test proves:**

| Test | What It Validates |
|------|-------------------|
| Page allocation | Scoped move `alloc_page` works: entity moves from `proc::MEM_FREE` to `proc::MEM_USED` |
| FD open | Scoped move `open_fd` works: entity moves from `proc::FD_FREE` to `proc::FD_OPEN` |
| Resource isolation | Alloc on process A, switch to B, alloc → B's resources change, A's don't |
| Kill with resources | Terminated process's scoped resources are structurally isolated — nobody can access them |

**The thesis proven on hardware:** HERB's scoped containers provide structural isolation on real x86-64 hardware. Process A's file descriptors are literally different containers than Process B's. Cross-scope access doesn't exist — not checked, not guarded, structurally absent. This is Discovery 11 (scoped containers are virtual address spaces) running on actual hardware with no operating system underneath.

**The numbers:**
- Kernel image: 60KB (under 100KB target)
- Interactive kernel binary: 2,108 bytes (84% smaller than JSON)
- 29 bare metal tests: 29/29 passing
- 14 flat-mode tests: 14/14 passing (backward compat)
- Total test count: 650 (up from 621)

### Session 41 Milestone: FRAMEBUFFER GRAPHICS

Session 40 proved the thesis on hardware with automated testing. Session 41 **gives the OS eyes** -- the display transitions from 80x25 text characters to 800x600 pixels.

**The problem:** VGA text mode is a dead end. Everything graphical -- compositor, GUI, browser, game -- needs pixels. The OS rendered state as a text table: rows of characters showing process names, priorities, container counts. Spatial relationships between entities were invisible. Text mode couldn't show what a process LOOKS like, only what its data says.

**The solution:** Bochs Graphics Adapter (BGA) framebuffer initialization with double-buffered graphical rendering.

**1. BGA Framebuffer Initialization (`boot/framebuffer.h`)**

The Bochs Graphics Adapter is QEMU's virtual GPU. Setting it up requires three things the bootloader didn't provide:

- **PCI config space read** -- Port 0xCF8/0xCFC to find the device (vendor 0x1234, device 0x1111) and read BAR0 (the framebuffer physical address, typically 0xFD000000 in QEMU)
- **Page table extension** -- The bootloader identity-maps 64MB (PDPT[0]). The framebuffer lives at 3-4GB. A new Page Directory at physical 0x4000 was added to PDPT[3], mapping 16MB of framebuffer MMIO with 2MB pages (uncached: PCD+PWT bits set). TLB flushed by reloading CR3.
- **BGA DISPI registers** -- I/O ports 0x01CE/0x01CF: disable display, set 800x600x32bpp, enable with LFB flag. The linear framebuffer appears at BAR0.

The back buffer lives at 0x500000 (system RAM, cached, fast). `fb_flip()` copies it sequentially to the framebuffer MMIO (uncached, write-only). Never read from MMIO -- PCIe reads are catastrophically slow.

**2. Rendering Primitives**

- `fb_clear(color)` -- fill back buffer
- `fb_fill_rect(x, y, w, h, color)` -- filled rectangle with clipping
- `fb_draw_rect(x, y, w, h, color)` -- 1px outline
- `fb_draw_rect2(x, y, w, h, color)` -- 2px outline
- `fb_draw_char(x, y, ch, fg, bg)` -- character from embedded 8x16 bitmap font
- `fb_draw_string(x, y, str, fg, bg)` -- text rendering
- `fb_draw_int(x, y, val, fg, bg)` -- integer as string
- `fb_draw_container(x, y, w, h, title, border, fill)` -- titled bordered box
- `fb_draw_process(x, y, w, h, name, pri, ts, border, fill)` -- process entity rectangle
- `fb_draw_resources(x, y, mf, mu, ff, fo)` -- scoped resource indicators as colored squares
- `fb_flip()` -- copy back buffer to framebuffer

**3. Embedded 8x16 Bitmap Font (`boot/font8x16.h`)**

The standard VGA ROM font (CP437 compatible) embedded as a 4KB C array. 256 characters, each 16 bytes (one byte per scanline, MSB = leftmost pixel). Plus special glyphs: full block (219) for resource indicators, filled square (254).

**4. Graphical HERB State Visualization**

The display is NOT a text console rendered with a font. It's a live spatial map of HERB's internal state:

- **Four container regions** as colored bordered boxes:
  - CPU0 (Running) -- green, top-left
  - READY -- yellow, top-right
  - BLOCKED -- red, bottom-left
  - TERMINATED -- gray, bottom-right
- **Process entities** as colored rectangles within their container region
  - Name, priority, time_slice displayed inside
  - Scoped resources shown as small colored squares (green=MEM free, red=MEM used, blue=FD free, orange=FD open)
- **Status bars** with tick count, operations, arena usage, process count
- **Key legend** and action log
- **Resource legend** (KERNEL_MODE) showing what each colored square means

The display shows spatial relationships that text couldn't convey: which processes are in which containers, how many entities each container holds, what resources belong to each process. A MOVE (entity transferring between containers) is visible as the entity rectangle appearing in a different region on the next frame.

**5. Text Mode Fallback**

`#ifdef GRAPHICS_MODE` controls the display path. All text mode code remains unchanged:
- `make run` -- pixel framebuffer (800x600x32)
- `make run-text` -- VGA text mode (80x25, Session 38-40 display)
- `make test-bare-metal` -- text mode + automated serial tests (29/29 passing)

Serial output is independent of display mode. The test harness validates the REAL system through the same serial channel the system uses to report its own state.

**The numbers:**

| Metric | Value |
|--------|-------|
| Graphics kernel image | 75KB (74,752 bytes) |
| Text kernel image | 61KB (61,440 bytes) |
| Font data | 4KB (4,096 bytes) |
| Framebuffer resolution | 800x600x32bpp |
| Back buffer | 1.83MB at 0x500000 |
| Bare metal tests | 29/29 passing |
| Flat mode tests | 14/14 passing |
| Python v2 tests | 449/449 passing |
| Total tests | 650 |

**The significance:** The OS can now render pixels. This is the foundation for everything visual -- compositor, windows, widgets, browser rendering, game display. But more importantly for NOW, it makes HERB's internal state visible as spatial objects. Processes aren't rows in a table anymore; they're colored rectangles sitting inside container boxes. Resources aren't numbers; they're colored squares inside their owning process. A scheduling decision isn't a log line; it's a rectangle moving from the READY box to the CPU0 box. The display IS the state. That's what "HERB state IS the display" means: the graphical output is a direct spatial encoding of the HERB runtime's graph.

### Session 42 Milestone: DISPLAY AS HERB STATE

Session 41 gave the OS a pixel framebuffer. Session 42 **makes the display a HERB-modeled system** -- visual elements are HERB entities, visual state is managed by tensions, and the C renderer is a dumb pixel blitter.

**The problem:** Session 41's rendering pipeline was entirely C code. The `gfx_draw_full()` function hardcoded container region positions, computed process colors from location strings, and made all visual decisions in C. HERB didn't know a display existed. Adding any graphical feature meant writing more C. Every visual element was a C function call, not a HERB entity.

**The solution:** A fifth module (`display`) in the kernel composition that models visual elements as HERB entities.

**1. Display Module (`programs/interactive_kernel.herb.json`)**

The display module defines:
- **Surface entity type** -- a visual element with properties: `kind` (0=container region, 1=process), `state` (0=unset, 1=running, 2=ready, 3=blocked, 4=terminated), and for regions: `x`, `y`, `width`, `height`, `region_id`
- **VISIBLE container** -- holds Surface entities for container regions (CPU0, READY, BLOCKED, TERMINATED boxes)
- **HIDDEN container** -- for future use (surfaces not currently rendered)
- **Scoped SURFACE slot per Process** -- each process gets one Surface entity in its `SURFACE` scope, linking the process to its visual representation
- **Four sync tensions** -- `sync_running`, `sync_ready`, `sync_blocked`, `sync_terminated` -- each at priority 5 (below all kernel tensions). When a process is in a container and its surface state doesn't match, the tension sets the correct state.

The key design: **Surface.state is an abstract visual state (1-4), not pixel data.** HERB decides WHAT state each surface is in. C maps states to colors. This preserves the policy/mechanism boundary: HERB doesn't know about pixels, C doesn't make decisions.

**2. HERB-Driven Container Regions**

Container region positions (x, y, width, height) are stored as HERB entity properties on four Surface entities in `display.VISIBLE`:
- `region_cpu0`: x=8, y=76, w=388, h=190
- `region_ready`: x=404, y=76, w=388, h=190
- `region_blocked`: x=8, y=274, w=388, h=190
- `region_term`: x=404, y=274, w=388, h=190

The C renderer iterates `display.VISIBLE`, reads these properties, and draws titled boxes. No container positions are hardcoded in C for KERNEL_MODE.

**3. Surface-Reading Renderer (`boot/kernel_main.c`)**

The `gfx_draw_full()` function was rewritten:
- **Container regions**: iterate `display.VISIBLE` Surface entities → read kind, region_id, x, y, width, height → draw with `fb_draw_container()`
- **Process surfaces**: for each process in each container, read its scoped `SURFACE` entity → read `state` property → map to colors via lookup table → draw with `fb_draw_process()`
- **State-to-color mapping**: `surf_state_border[]` and `surf_state_fill[]` arrays map state 0-4 to border/fill colors
- **`get_surface_state()`**: reads a process's scoped SURFACE container to get its visual state

The C never decides which color a process should be. It reads the state HERB set via tensions, looks up colors in a table, and draws pixels.

**4. Process Surface Creation**

When `cmd_new_process()` creates a process, it also creates a Surface entity in `name::SURFACE` with kind=1, state=0 (unset). After `herb_run()`, the appropriate display tension fires and sets state to the correct value.

Initial processes (server, client) get their Surface entities in the program definition. After boot `herb_run()`, display tensions set their states.

**The numbers:**

| Metric | Value |
|--------|-------|
| Graphics kernel image | 76KB (76,288 bytes) |
| Text kernel image | 62KB (62,464 bytes) |
| Kernel binary (.herb) | 3,060 bytes |
| Display module | ~950 bytes binary overhead |
| Display tensions | 4 |
| Surface entities (initial) | 6 (4 regions + 2 process surfaces) |
| Total modules | 5 (proc + mem + fs + ipc + display) |
| Total tensions | 18 (14 kernel + 4 display) |
| Boot ops | 3 (1 schedule + 2 display syncs) |
| Bare metal tests | 29/29 passing |
| Python v2 tests | 449/449 passing |
| Total tests | 650 |

**What changed architecturally:**

| Before (Session 41) | After (Session 42) |
|---------------------|---------------------|
| C decides process colors from location strings | HERB tensions set surface state, C maps state to colors |
| Container positions hardcoded in C `#define` macros | Container positions stored as HERB entity properties |
| Adding a visual element = modify C code | Adding a visual element = add HERB entity + tension |
| Display doesn't exist in HERB | Display IS HERB state |
| 0 display operations per state change | 1 display operation per state change (set state) |

**The significance:** This is the first compositor step. The display is no longer a C program that queries HERB -- it's a HERB system that C renders. Every visual element is a HERB entity. Every visual state change is a HERB tension firing. The C layer is ~40 lines of rendering code that reads entities and draws pixels. This inverts the rendering architecture: HERB owns visual state, C is mechanism. Adding a window, a widget, or a GUI element means adding HERB entities and tensions, not modifying C. The pattern is proven: scoped containers provide structural coupling between domain objects (processes) and their visual representations (surfaces). This is the foundation for everything graphical that follows.

### Session 43 Milestone: MOUSE INPUT — SPATIAL INTERACTION

Session 42 made the display a HERB-modeled system. Session 43 **gives the OS a mouse** -- PS/2 hardware driver, cursor as a HERB entity, click signals with coordinates, and HERB-native spatial hit testing.

**The problem:** The OS only had keyboard input. All interaction was command-based: press a key, trigger a signal, HERB responds. There was no spatial awareness -- you couldn't point at things, click on things, or see where you were pointing. A graphical OS needs spatial interaction.

**The solution:** Full PS/2 mouse stack from hardware interrupt to HERB hit-test tensions.

**1. PS/2 Mouse Driver (`boot/kernel_entry.asm`, `boot/kernel_main.c`)**

- IRQ12 ISR stub: reads byte from port 0x60, stores in volatile, sends EOI to both slave and master PIC
- PS/2 initialization: enable auxiliary device (0xA8), enable IRQ12 in controller config, send Enable Data Reporting (0xF4)
- PIC mask updated: unmask cascade (IRQ2) and mouse (IRQ12 = bit 4 on slave)
- 3-byte packet assembly state machine in main loop with sync validation (bit 3 of byte 0 must be set)
- Signed delta extraction with overflow rejection
- Absolute position tracking with screen clamping (0-799 x, 0-599 y)
- Button state tracking with edge detection (click = transition from unpressed to pressed)

**2. Cursor as a Surface Entity**

The cursor is a HERB entity in `display.VISIBLE` with `kind=2` and x,y properties. C updates these properties on every mouse movement. The cursor is rendered as a 10x14 pixel arrow bitmap written directly to the MMIO framebuffer (not through the back buffer). This avoids expensive full redraws for cursor tracking:

- Back buffer always contains the scene WITHOUT cursor
- `fb_cursor_erase()`: copies old cursor area from back buffer to MMIO (restore)
- `fb_cursor_draw()`: draws cursor bitmap to MMIO at new position (overlay)
- After `fb_flip()`, cursor is drawn on top of the flipped frame
- Result: cursor tracks mouse movement with zero full redraws

**3. Click Signals into HERB**

Left clicks create `CLICK_SIG` Signal entities with `click_x` and `click_y` integer properties. The `CLICK_SIG` container is in the `proc` module alongside other signal containers, and `consume_signal` can move clicks to `SIG_DONE`.

**4. Hit Testing as HERB Tensions**

This is the architectural key piece. Five new tensions in the `display` module:

- `click_select_cpu0` (pri=4): match CLICK_SIG + region(id=0) + proc in CPU0, guard: coordinates within region bounds → set proc.selected=1
- `click_select_ready` (pri=4): same pattern for READY container
- `click_select_blocked` (pri=4): same pattern for BLOCKED container
- `click_select_terminated` (pri=4): same pattern for TERMINATED container
- `click_miss` (pri=3): match any unconsumed CLICK_SIG → consume it (fallback)

The guard expression for each hit-test tension:
```
click.click_x >= region.x AND
click.click_x < region.x + region.width AND
click.click_y >= region.y AND
click.click_y < region.y + region.height
```

This uses cross-binding property comparison in guard clauses: the `click` binding's properties are compared against the `region` binding's properties. The guard fires only when coordinates match. HERB does the spatial reasoning; C creates the signal and renders the result.

**5. Selection Highlight**

Selected processes (selected=1) get a 3-pixel bright white border drawn around their rectangle. C clears the previous selection before creating a new click signal. After herb_run(), C scans all process containers to find which entity HERB selected.

**The numbers:**

| Metric | Value |
|--------|-------|
| Graphics kernel image | 80KB (80,384 bytes) |
| Text kernel image | 64KB (64,512 bytes) |
| Kernel binary (.herb) | 3,989 bytes |
| Mouse + click overhead | ~929 bytes binary |
| Total modules | 5 (proc + mem + fs + ipc + display) |
| Total tensions | 23 (14 kernel + 4 sync + 5 click) |
| Entities (initial) | 17 (2 procs + 8 resources + 2 surfaces + 4 regions + 1 cursor) |
| Bare metal tests | 29/29 passing |
| Python v2 tests | 449/449 passing |
| Total tests | 650 |

**What changed architecturally:**

| Before (Session 42) | After (Session 43) |
|---------------------|---------------------|
| Keyboard-only interaction | Keyboard + mouse interaction |
| No spatial awareness | Click coordinates as HERB entity properties |
| No hit testing | Guard expressions match coordinates against bounds |
| No cursor | Cursor is a Surface entity with MMIO overlay rendering |
| No selection concept | selected property set by HERB tensions |
| Display has no input | Display module both outputs (sync tensions) AND inputs (click tensions) |

**The significance:** The display module now has bidirectional data flow. Session 42 made it output-only: kernel tensions change process state, display tensions sync visual state. Session 43 adds INPUT: user clicks create signals, display tensions interpret click coordinates against visual layout, and set semantic state (selected) on processes. The display module both reflects state AND responds to spatial input. This is the interaction model a graphical OS needs: HERB owns the spatial layout (region positions), HERB does the spatial reasoning (hit testing), and HERB sets the semantic result (selection). The C layer's role is pure mechanism: read mouse hardware, create signals with coordinates, render highlights where HERB says. The cursor being a HERB entity means the pointer position is part of the system's state graph -- another domain where HERB owns state and C is mechanism.

### Session 44 Milestone: VISIBLE TENSIONS — RULES AS OBJECTS

Session 43 gave the OS mouse input and spatial hit testing. Session 44 **makes the OS's behavioral rules visible, selectable, and toggleable** -- proving that HERB's dissolution of the code/data distinction has real, observable consequences.

**The problem:** Every operating system in history has two categories: data (processes, files, pages) and code (scheduler, fault handler, drivers). Data is inspectable and mutable at runtime. Code is opaque and fixed. You can see a process. You can't see the scheduling rule that moves it. HERB dissolved this distinction — tensions are data structures, not compiled code — but the display only showed entities in containers. The forces acting on them were invisible.

**The solution:** Tensions rendered as first-class visual objects with runtime enable/disable.

**1. Runtime: `enabled` Flag + Tension Query API (`src/herb_runtime_freestanding.c`)**

One field added to the Tension struct: `int enabled;` (default 1). One line in `herb_step()`: `if (!g_graph.tensions[idx].enabled) continue;`. Five new API functions: `herb_tension_count()`, `herb_tension_name()`, `herb_tension_priority()`, `herb_tension_enabled()`, `herb_tension_set_enabled()`. The entire mechanism for making the energy landscape controllable is 35 lines of C.

**2. Tension Panel: Right Sidebar (`boot/kernel_main.c`, `boot/framebuffer.h`)**

Container regions resized to the left 2/3 of the screen. A 244×388px tension panel fills the right sidebar. All 23 tensions rendered as compact rows showing name (module prefix stripped), priority, and enabled state. Cool blue/cyan color palette distinguishes RULES from THINGS: enabled tensions glow cyan, disabled tensions dim to dark gray. Selected tension has a bright white border.

**3. Interaction**

- Keyboard `[`/`]`: cycle tension selection through the list
- Keyboard `D`: toggle selected tension's enabled/disabled state
- Mouse click on tension panel: select and toggle the clicked tension
- All operations logged to serial for automated testing

**4. Behavioral Consequences — Proven**

| Action | Observable Result |
|--------|-------------------|
| Disable `timer_tick` | Timer signals produce 0 ops — time_slice never decrements, preemption stops |
| Disable `schedule_ready` | After killing a process, CPU0 stays empty — no rescheduling occurs |
| Disable `sync_running` | Display state doesn't update when processes move to CPU0 |
| Re-enable any tension | Behavior resumes immediately on next signal |

These aren't debug outputs. They're proof that the energy landscape is real: removing a gradient changes the system's behavior, and the user can see exactly which gradient they removed.

**The numbers:**

| Metric | Value |
|--------|-------|
| Graphics kernel image | 85KB (85,504 bytes) |
| Text kernel image | 67KB (67,072 bytes) |
| Kernel binary (.herb) | 3,989 bytes (unchanged) |
| Total modules | 5 (proc + mem + fs + ipc + display) |
| Total tensions | 23 (unchanged) |
| Bare metal tests | 46/46 passing (29 original + 17 tension toggle) |
| Python v2 tests | 449/449 passing |
| Total tests | 667 |

**What changed architecturally:**

| Before (Session 43) | After (Session 44) |
|---------------------|---------------------|
| Tensions are invisible internal runtime state | Tensions are rendered as visual objects |
| Tensions always fire during resolution | Tensions can be individually disabled |
| Behavioral rules are fixed after program load | Behavioral rules are live-editable by the user |
| Display shows entities (things) only | Display shows entities AND tensions (things AND forces) |
| User interacts with entities (click to select) | User interacts with both entities and tensions |

**The significance:** No operating system lets you see its scheduling algorithm as an object and turn it off with a click. Linux's CFS is compiled C code — opaque, fixed, invisible at runtime. HERB's `schedule_ready` is a data structure rendered as a colored rectangle that you can point at and toggle. This is the architectural consequence of "tensions are data, not code." Session 44 proves it's not a theoretical property — it's a user-facing capability. The energy landscape metaphor from the Philosophy section of this Bible ("Programming is defining an energy landscape. Execution is gravity.") is now literally visible on screen: you can see the gradients, remove one, and watch gravity work differently.

### Session 45 Milestone: PROCESS-AS-TENSIONS — LOADABLE BEHAVIORAL PROGRAMS

Session 44 made tensions visible and toggleable. Session 45 **makes processes behavioral** -- a process IS its tensions, and loading a program means injecting behavioral rules into the runtime.

**The problem:** Every process was a static data entity. Processes had properties (priority, time_slice) and lived in containers (READY, CPU0, BLOCKED), but they didn't DO anything on their own. All behavior came from the 23 system tensions. A process in CPU0 was just a name waiting for system tensions to move it. Real operating systems have per-process code -- each program does different things when scheduled.

**The solution:** Runtime tension creation API + owner scheduling, making a process's behavior its tensions.

**1. Runtime: Tension Creation API (`src/herb_runtime_freestanding.c`)**

Seven new API functions that let the kernel inject tensions at runtime:
- `herb_tension_create(name, priority, owner_entity, run_container)` -- creates a tension owned by a specific entity
- `herb_tension_match_in(tidx, bind, container, select_mode)` -- adds a match clause
- `herb_tension_match_in_where(tidx, bind, container, select_mode, where_expr)` -- adds a match with a where filter
- `herb_tension_emit_set(tidx, entity_bind, property, value_expr)` -- adds a set emit
- `herb_tension_emit_move(tidx, move_type, entity_bind, to_container)` -- adds a move emit
- Expression builders: `herb_expr_int()`, `herb_expr_prop()`, `herb_expr_binary()`
- `herb_remove_owner_tensions(owner_entity)` -- removes all tensions owned by an entity (compact, no holes)

**2. Owner Scheduling (`herb_step()` in `src/herb_runtime_freestanding.c`)**

Two fields on the Tension struct: `owner` (entity index, -1 for system tensions) and `owner_run_container` (container index where owner must be to fire, -1 for no check). One check in `herb_step()`: if a tension has an owner and that owner is not in the run container, skip it. Process-owned tensions only fire when their process is scheduled (in CPU0).

**3. Two Loadable Programs (`boot/kernel_main.c`)**

- **Worker**: one tension `{name}.do_work` at priority 6. Match: "me" in CPU0 where me.work > 0. Emit: set me.work = me.work - 1. The process converges toward work=0.
- **Beacon**: one tension `{name}.pulse` at priority 6. Match: "me" in CPU0 where me.pulses < me.limit. Emit: set me.pulses = me.pulses + 1. The process converges toward pulses=limit.

Odd process_counter = worker, even = beacon. Each process gets its own tension with unique name.

**4. Visual Integration**

- Tension panel shows process-owned tensions with orange indicator dots (vs cyan for system tensions) and warm-colored names
- Process rectangles display program state: `W:xxx` for workers (work remaining), `P:xxx/xxx` for beacons (pulses/limit)
- Serial output reports `[PROGRAM] worker/beacon loaded for {name} tensions={count}` and `[PROC] {name} work/pulses={value}`

**5. Behavioral Consequences -- Proven**

| Action | Observable Result |
|--------|-------------------|
| Create worker | do_work tension appears, work decreases when scheduled |
| Create beacon | pulse tension appears, pulses increase when scheduled |
| Kill process | Owner tensions removed from runtime (compacted) |
| Block process | Owner tensions stop firing (owner not in CPU0) |
| Unblock process | Owner tensions resume when rescheduled |

**The numbers:**

| Metric | Value |
|--------|-------|
| Graphics kernel image | 90KB (90,112 bytes) |
| Text kernel image | 72KB (72,192 bytes) |
| Kernel binary (.herb) | 3,989 bytes (unchanged) |
| Total modules | 5 (proc + mem + fs + ipc + display) |
| System tensions | 23 (unchanged) |
| Process tensions | Dynamic (1 per process, created/removed at runtime) |
| Bare metal tests | 59/59 passing (46 original + 13 process-as-tensions) |
| Python v2 tests | 449/449 passing |
| Total tests | 680 |

**What changed architecturally:**

| Before (Session 44) | After (Session 45) |
|---------------------|---------------------|
| All tensions loaded from the .herb binary at boot | Tensions can be created at runtime via API |
| All processes behave identically (passive data) | Each process has unique behavioral tensions |
| Tension count is fixed after program load | Tension count grows/shrinks as processes are created/killed |
| Killing a process just moves it to TERMINATED | Killing a process also removes its behavioral rules |
| Scheduling only affects which process occupies CPU0 | Scheduling determines which process's tensions fire |

**The significance:** This is the moment HERB processes become truly different from each other. Before Session 45, a process was just a name with properties sitting in a container. Now a process IS its behavioral rules. A worker process literally has a different energy gradient than a beacon process. The scheduler doesn't just pick which process runs -- it picks which set of behavioral tensions are active. Killing a process doesn't just move an entity; it removes rules from the universe. The process/program distinction dissolves: there is no "code" separate from the process. The process's tensions ARE its program, and they live in the same runtime as the system tensions. You can see them in the tension panel (orange dots), toggle them (D key), and watch the energy landscape reshape itself as processes are created and destroyed.

### Session 46 Milestone: INTERACTING PROCESSES — EMERGENT BEHAVIOR

Session 45 proved that a process IS its tensions. Session 46 proves that **independent processes produce emergent behavior through shared state** -- the real payoff of "the OS absorbs behavioral rules and resolves the combined energy landscape."

**The problem:** Every process in Session 45 was solitary. Workers decremented their own work. Beacons incremented their own pulses. Each process modified its own properties in isolation. The energy landscape had independent gradients that didn't interact. But the real power of a unified tension resolution system is that rules from different sources interact: Producer fills, Consumer drains, and the system finds a dynamic equilibrium that neither could produce alone.

**The solution:** Producer and Consumer programs that interact through a shared BUFFER entity.

**1. Runtime: Container Creation API (`src/herb_runtime_freestanding.c`)**

One new API function: `herb_create_container(name, kind)`. Creates a container at runtime for shared state. The BUFFER container is created once at boot, holding a single Buffer entity with `count` and `capacity` properties.

**2. Producer Program (`boot/kernel_main.c`)**

One tension `{name}.produce` at priority 6:
- Match "me" in CPU0 where me.produced < me.produce_limit
- Match "buf" in BUFFER where buf.count < buf.capacity
- Emit: set buf.count = buf.count + 1, set me.produced = me.produced + 1

**3. Consumer Program (`boot/kernel_main.c`)**

One tension `{name}.consume` at priority 6:
- Match "me" in CPU0 (no condition — always tries)
- Match "buf" in BUFFER where buf.count > 0
- Emit: set buf.count = buf.count - 1, set me.consumed = me.consumed + 1

**4. Multi-Binding Tensions**

Each process tension has TWO match clauses: one for the process entity ("me") and one for the shared buffer entity ("buf"). Both must match for the tension to fire. The expression evaluator resolves bindings from both matches in emit expressions. This is the first time process programs reference entities outside themselves.

**5. Emergent Behavior — Proven**

| Action | Observable Result |
|--------|-------------------|
| Create producer only | Buffer fills to capacity (20/20), producer stops |
| Add consumer | Buffer drains toward 0, consumer catches up |
| Both running | Dynamic equilibrium: producer and consumer alternate, buffer fluctuates |
| Block producer | Consumer drains buffer to 0, then stops (nothing to consume) |
| Block consumer | Producer fills buffer to capacity, then stops |
| Kill either | Half the energy gradients vanish, buffer moves to one extreme |
| Toggle tension off | Same behavioral effect as blocking |

The key insight: neither process knows the other exists. They interact through shared state. The scheduler determines which set of tensions fires (by moving process entities into CPU0). The runtime resolves ALL active tensions together. Emergent behavior arises from the combined energy landscape, not from any process-to-process communication.

**6. Visual Integration**

Buffer indicator bar in the bottom panel: fill bar (green/yellow/orange by fill level), numeric count (N/20), producer/consumer legend. Process rectangles show program state: `>NN` (producer's produced count, orange) and `<NN` (consumer's consumed count, blue).

**The numbers:**

| Metric | Value |
|--------|-------|
| Graphics kernel image | 92KB (91,648 bytes) |
| Text kernel image | 73KB (73,216 bytes) |
| Kernel binary (.herb) | 3,989 bytes (unchanged) |
| Total modules | 5 (proc + mem + fs + ipc + display) |
| System tensions | 23 (unchanged) |
| Process tensions | Dynamic (1 per live process) |
| Shared containers | 1 (BUFFER, created at runtime) |
| Bare metal tests | 76/76 passing (59 original + 17 interaction) |
| Python v2 tests | 449/449 passing |
| Total tests | 697 |

**What changed architecturally:**

| Before (Session 45) | After (Session 46) |
|---------------------|---------------------|
| Process tensions reference only self ("me" in CPU0) | Process tensions reference self AND shared entities |
| Each process modifies its own properties | Processes modify shared state through multi-binding tensions |
| No shared mutable state between processes | BUFFER entity is shared mutable state |
| Container creation only at program load time | Containers created at runtime via herb_create_container() |
| Independent energy gradients per process | Interacting gradients: combined landscape produces emergent behavior |

**The significance:** This is the moment HERB proves that "the OS absorbs behavioral rules and resolves the combined energy landscape" is not just a description of the architecture — it's a capability with observable consequences. In every other OS, producer/consumer coordination requires explicit synchronization primitives: mutexes, semaphores, condition variables. In HERB, there are no synchronization primitives. There are tensions that reference shared state. The runtime resolves them in priority order, atomically, to fixpoint. The synchronization is structural: the buffer's `count` property can only be incremented when count < capacity (producer's guard) and only decremented when count > 0 (consumer's guard). Invalid states (count < 0 or count > capacity) are unreachable because no sequence of valid tension resolutions leads to them. This is Discovery 1 (the operation set IS the constraint system) operating at the process interaction level. The buffer's integrity isn't enforced by a lock. It's enforced by the structure of the tensions themselves.

### Session 47 Milestone: PROGRAMS AS DATA — .HERB BINARIES LOADED AS PROCESSES

Session 46 proved emergent behavior from cross-process interaction. Session 47 **eliminates the last C scaffolding from process programs** -- a process's behavior is loaded from a `.herb` binary file, not constructed by C function calls.

**The problem:** Sessions 45-46 proved that a process IS its tensions and that cross-process interaction emerges from the combined energy landscape. But there was a lie at the heart of the system: `load_producer_program()` and `load_consumer_program()` were C functions that called `herb_tension_create()`, `herb_tension_match_in_where()`, `herb_tension_emit_set()` etc. — constructing tensions through compiled C code. The Bible says "A HERB program is a data structure, not code." Every C function that constructs tensions by hand is scaffolding that should be a `.herb` program loaded from data.

**The solution:** Data-driven process loading via `.herb` binary program fragments.

**1. Program Fragment Files (`programs/*.herb.json`)**

Four process programs as pure data:
- `producer.herb.json` (710 bytes JSON → 209 bytes binary): one tension matching self in CPU0 + buf in BUFFER
- `consumer.herb.json` (557 bytes → 179 bytes): one tension matching self in CPU0 + buf in BUFFER where count > 0
- `worker.herb.json` (378 bytes → 123 bytes): one tension matching self in CPU0 where work > 0
- `beacon.herb.json` (410 bytes → 125 bytes): one tension matching self in CPU0 where pulses < limit

Each is a valid `.herb.json` with only a tensions section — entity types, containers, moves are empty. The compiler handles this naturally, producing compact binaries.

**2. Program Fragment Loader (`herb_load_program()` in `src/herb_runtime_freestanding.c`)**

New public API:
```c
int herb_load_program(const uint8_t* data, herb_size_t len,
                       int owner_entity, const char* run_container);
```

The function:
- Reads the `.herb` binary header and string table
- Maps fragment strings into the running system's intern table
- Skips empty infrastructure sections (entity types, containers, moves, pools, etc.)
- For the tensions section: creates each tension with the given owner and run_container
- Automatically prefixes tension names with the owner entity's name ("p1.produce", "p2.consume")
- Returns the number of tensions loaded

This reuses all existing binary parsing infrastructure (BinReader, br_expr, br_to_ref) but adds the owner/run_container semantics that make the loaded tensions behave as process programs.

**3. Multi-Program Embedding (`boot/gen_multi_program_data.py`)**

New build tool that embeds multiple `.herb` binaries as named C arrays in a single header file. Each program gets `program_NAME[]` and `program_NAME_len`. The kernel selects programs by name at runtime.

**4. C Scaffolding Removed (`boot/kernel_main.c`)**

`load_producer_program()` (30 lines of C) and `load_consumer_program()` (28 lines of C) — deleted. Replaced by two calls to `herb_load_program()` with embedded binary data. The C tension creation API (`herb_tension_create` etc.) remains available for system tensions, but process programs come from data.

**The numbers:**

| Metric | Value |
|--------|-------|
| Graphics kernel image | 95KB (97,280 bytes) |
| Text kernel image | 77KB (78,848 bytes) |
| Kernel binary (.herb) | 3,989 bytes (unchanged) |
| Producer binary | 209 bytes |
| Consumer binary | 179 bytes |
| Worker binary | 123 bytes |
| Beacon binary | 125 bytes |
| C lines removed | ~60 (load_producer + load_consumer) |
| Total programs | 15 (11 system + 4 process fragments) |
| Total tensions | 23 system + dynamic per-process (unchanged) |
| Bare metal tests | 76/76 passing (unchanged, data loading = identical behavior) |
| Python v2 tests | 449/449 passing |
| Cross-format | 13/13 passing |
| Total tests | 697 |

**What changed architecturally:**

| Before (Session 46) | After (Session 47) |
|---------------------|---------------------|
| Process programs are C functions that call tension API | Process programs are `.herb` binary data loaded at runtime |
| Adding a new program type requires modifying C code | Adding a new program type requires writing a `.herb.json` file |
| Tension creation logic compiled into the kernel | Tension creation logic parsed from binary data |
| Program behavior is code | Program behavior is data |
| Two C functions construct process tensions | Zero C functions construct process tensions |

**The significance:** This session completes the "programs as data" arc that began in Session 28. Session 28 established that a HERB program is a data structure. Session 34 made programs portable (JSON). Session 39 made programs native (binary). Session 45 proved that process behavior IS tensions. Session 47 closes the loop: the kernel loads process programs from `.herb` binary data at runtime, not from compiled C code. The last piece of C scaffolding that stood between the kernel and pure data-driven process loading is gone. The C tension creation API remains for the kernel's own system tensions (which are part of the kernel .herb binary), but every process program is data that the runtime loads. This is one step closer to the HERB Purism goal: assembly + HERB, nothing else. The C functions that constructed tensions by hand were scaffolding. Now they're gone.

### Session 48 Milestone: HOT-SWAPPABLE SYSTEM POLICY — LIVE RULE REPLACEMENT

Session 47 made process programs loadable data. Session 48 **proves that system behavioral rules — the kernel's own scheduling, display sync, and hit-testing policies — can be replaced at runtime with different rules loaded from data.**

**The problem:** System tensions (scheduling, display sync, hit testing) are fixed after boot. Session 44 made them toggleable (enabled/disabled), but you can't REPLACE one with a different behavioral rule. Every OS in history requires recompilation or at minimum a reboot to change its scheduling policy. Even systems with "pluggable schedulers" (Linux's CFS vs SCHED_DEADLINE) require kernel module loading with compiled native code.

**The solution:** Two new runtime APIs and two scheduling policy fragments.

**1. Runtime: Tension Removal by Name (`herb_remove_tension_by_name()` in `src/herb_runtime_freestanding.c`)**

One new API function that removes a single tension by its interned name. Same compaction logic as `herb_remove_owner_tensions()` but matching by `name_id` instead of `owner`. Returns 1 if removed, 0 if not found. This is the "unload old policy" half of the swap.

**2. Runtime: System-Level Fragment Loading (fix to `herb_load_program()`)**

When `herb_load_program()` is called with `owner_entity = -1`, tension names are now used directly from the fragment (no owner name prefix). This makes the function work for loading system-level policy fragments — the loaded tension becomes a system tension (owner=-1, no run container check).

**3. Two Scheduling Policy Fragments**

- `schedule_priority.herb.json` (344 bytes JSON → 140 bytes binary): tension `proc.schedule_pri` at priority 10, matches entity in proc.READY with `max_by priority` + empty proc.CPU0, emits move to CPU0. This is the existing behavior extracted as loadable data.
- `schedule_roundrobin.herb.json` (323 bytes → 130 bytes): tension `proc.schedule_rr` at priority 10, matches entity in proc.READY with `first` (FIFO) + empty proc.CPU0, emits move to CPU0. Same structural shape, different selection logic.

The ONLY difference between the two policies is `"select": "max_by", "key": "priority"` vs `"select": "first"`. Everything else — containers, move types, emit targets — is identical. The difference in selection logic produces completely different scheduling behavior.

**4. Swap Command ('S' key in `boot/kernel_main.c`)**

- Removes the current scheduling tension by name (`herb_remove_tension_by_name()`)
- Loads the alternative from embedded binary data (`herb_load_program()` with owner=-1)
- Updates the tracked tension name and display label
- Runs the system to settle under the new policy
- Serial output: `[POLICY] Removed proc.schedule_ready (1)` → `[POLICY] Loaded round-robin (1 tensions)` → `[POLICY] Settled: ROUND-ROBIN ops=N`

**5. Visual Feedback**

- Stats bar shows `Sched: PRIORITY` or `Sched: ROUND-ROBIN` in distinct colors (green/orange)
- Tension panel: old scheduling tension disappears, new one appears
- Key legend includes `S` for swap

**6. No Compatibility Check — By Design**

The mechanism performs NO structural validation of the replacement tension. It doesn't check that the replacement references the same containers, uses the same move types, or has the same match/emit shape. This is deliberate: Discovery 1 (the operation set IS the constraint system) protects the system structurally. A "wrong" replacement simply doesn't fire — its container references resolve to -1, its moves don't match, and the tension produces zero operations. The system continues running safely with whatever tensions remain active. Invalid replacements are harmless because invalid operations are unreachable.

**The numbers:**

| Metric | Value |
|--------|-------|
| Graphics kernel image | 99KB (101,376 bytes) |
| Text kernel image | 80KB (81,408 bytes) |
| Priority policy binary | 140 bytes |
| Round-robin policy binary | 130 bytes |
| Total programs | 17 (11 system + 4 process + 2 policy fragments) |
| Bare metal tests | 95/95 passing (76 original + 19 policy swap) |
| Python v2 tests | 449/449 passing |
| Total tests | 716 |

**What changed architecturally:**

| Before (Session 47) | After (Session 48) |
|---------------------|---------------------|
| System tensions are fixed after boot | System tensions can be replaced at runtime |
| Changing scheduling requires recompilation | Changing scheduling requires loading a different .herb fragment |
| Behavioral rules can only be toggled on/off | Behavioral rules can be swapped for different rules |
| herb_load_program() only loads owned (process) tensions | herb_load_program() with owner=-1 loads system tensions |
| No tension removal by name | herb_remove_tension_by_name() removes any tension |

**The significance:** No operating system lets you replace its scheduling algorithm at runtime by loading a different data file. Linux's CFS is compiled C code. Windows' scheduler is compiled C++ code. Changing either requires kernel development, compilation, and a reboot. In HERB, the scheduling policy is a 130-byte `.herb` binary. Swapping it means removing one tension by name and loading another. The system never stops running. The user watches the behavioral difference in real time: under priority scheduling, the highest-priority process gets the CPU; under round-robin, the first process in the READY queue gets it. The mechanism is fully general — any system tension can be replaced, not just scheduling. You could swap display sync policies, hit-test strategies, or timer preemption rules the same way. The demo is scheduling because it's the most visible and testable, but the architecture supports replacing any behavioral rule in the system. This is what "the operation set IS the constraint system" means for system evolution: you can change the rules while the system runs because the rules are data, and the structural safety guarantees hold regardless of which rules are loaded.

### Former Problems: SOLVED

- **Session 27:** System was passive -- **SOLVED: Tensions**
- **Session 28:** "What is a HERB program?" -- **SOLVED: Data structure**
- **Session 29:** "Can't reason about values/quantities" -- **SOLVED: Properties + expressions + pools**
- **Session 30:** "No isolation, no hierarchy, no mutation" -- **SOLVED: Scoped containers + property mutation**
- **Session 31:** "Isolated processes can't communicate" -- **SOLVED: Channels (Zircon model)**
- **Session 32:** "Entity can only be in one state" -- **SOLVED: Multi-dimensional state**
- **Session 33:** "Programs don't scale" -- **SOLVED: Module composition**
- **Session 34:** "Programs are Python dicts, runtime is Python" -- **SOLVED: JSON format + C runtime**
- **Session 35:** "C runtime is incomplete" -- **SOLVED: Full C runtime with scoped containers, channels, pools/transfers, duplication, nesting depth**
- **Session 36:** "C runtime depends on libc" -- **SOLVED: Freestanding runtime with zero external dependencies**
- **Session 37:** "Need assembly bootstrap to run on hardware" -- **SOLVED: Two-stage x86-64 bootloader, 64-bit kernel entry, VGA/IDT/PIC/PIT, HERB boots and runs autonomously**
- **Session 38:** "Booted OS is not interactive" -- **SOLVED: PS/2 keyboard → HERB signals, 7 interactive commands, structured VGA display, runtime query APIs, dynamic process creation**
- **Session 39:** "JSON is borrowed scaffolding" -- **SOLVED: Native .herb binary format, 81-90% smaller, 39% fewer loader lines, auto-detected by herb_load(), 13/13 cross-format equivalence, OS boots from binary**
- **Session 40:** "Bare metal testing is manual, kernel modules never ran on hardware" -- **SOLVED: Automated QEMU test harness (29 tests, QMP keystroke injection, serial output parsing), four-module kernel running interactively on bare metal with per-process scoped resource management**
- **Session 41:** "Display is VGA text mode — can't show spatial relationships or render pixels" -- **SOLVED: BGA framebuffer (800x600x32), PCI BAR0 discovery, page table extension for MMIO, double-buffered rendering, embedded 8x16 font, container regions as bordered boxes, process entities as colored rectangles, scoped resources as visual indicators, text mode fallback**
- **Session 42:** "Display is hardcoded C rendering — HERB doesn't know a display exists" -- **SOLVED: Display module (5th kernel module), Surface entity type, scoped SURFACE per Process, 4 sync tensions, container region positions as HERB properties, state-to-color mapping in C, policy/mechanism boundary preserved**
- **Session 43:** "No spatial interaction — keyboard commands only, can't point or click" -- **SOLVED: PS/2 mouse driver (IRQ12), cursor as Surface entity, CLICK_SIG with coordinate properties, 5 hit-test tensions using guard expressions for spatial matching, selected property set by HERB, 3px highlight border, direct MMIO cursor overlay**
- **Session 44:** "Tensions are invisible — user can see entities but not the rules that move them" -- **SOLVED: Tension panel sidebar renders all 23 tensions as visual objects with name/priority/enabled state, keyboard and mouse selection, D key toggles enabled/disabled, disabled tensions skip during resolution, live behavioral consequences proven (disable timer_tick → preemption stops, disable schedule_ready → CPU stays empty), 17 new automated tests**
- **Session 45:** "Processes are static data entities — they don't DO anything, all behavior comes from system tensions" -- **SOLVED: Runtime tension creation API (herb_tension_create + match/emit/expression builders), owner scheduling (process tensions only fire when owner is in CPU0), two loadable programs (Worker converges to work=0, Beacon converges to pulses=limit), herb_remove_owner_tensions compacts on kill, tension panel shows process-owned tensions in orange, 13 new automated tests**
- **Session 46:** "Each process's tensions operate in isolation — no cross-process interaction" -- **SOLVED: Producer/Consumer programs with shared BUFFER entity, multi-binding tensions reference both self and shared state, runtime container creation API (herb_create_container), emergent equilibrium from combined energy landscape, buffer integrity from tension structure (not locks), 17 new interaction tests**
- **Session 47:** "Process programs are C functions, not data — load_producer_program() and load_consumer_program() construct tensions in compiled C code" -- **SOLVED: herb_load_program() loads .herb binary fragments into the running system, four program fragments as .herb.json + .herb binary, multi-program embedding in kernel, zero C functions construct process tensions, identical behavior verified (76/76 tests)**
- **Session 48:** "System tensions are fixed after boot — you can toggle them but not replace one with a different behavioral rule" -- **SOLVED: herb_remove_tension_by_name() removes by name, herb_load_program() with owner=-1 loads system-level fragments, two scheduling policies (priority 140B, round-robin 130B) swap live via 'S' key, no compatibility check needed (Discovery 1 protects structurally), mechanism generalizes to any system tension, 19 new tests prove swap/restore/multi-swap stability**
- **Session 49:** "Text input is a C string buffer — not HERB state, not subject to HERB guarantees" -- **SOLVED: 32 pre-allocated Char entities MOVE between CHAR_POOL and CMDLINE containers; typing = MOVE, buffer = container, position = entity property; modal input with 9 tensions; C handles ONLY scancode reading and rendering; buffer overflow impossible (CHAR_POOL has 32 entities, when empty key_overflow fires); 17 new tests**
- **Session 50:** "Command dispatch is a C switch statement — the shell is code, not a HERB process" -- **SOLVED: Shell loaded from .herb binary fragment (806 bytes, 8 tensions); CMD_SIG entities carry cmd_id/arg_id; shell tensions match on integers and perform MOVEs (direct commands) or set ShellCtl.action (delegated commands); shell is a protected daemon (empty run_container, tensions fire regardless of scheduling); C parses text to integers (mechanism), HERB decides what to do (policy); 15 new tests**
- **Session 51:** "Single-key commands bypass the shell — pressing 'k' calls cmd_kill() in C while typing 'kill' goes through CMD_SIG → HERB tensions, two separate code paths for the same operations" -- **SOLVED: dispatch_command(cmd_id, arg_id) replaces cmd_kill/cmd_block/cmd_unblock; both single-key and text paths create CMD_SIG with identical integer properties; shell protection moved from C if-check to HERB where guard (protected property); ~97 lines behavioral C → ~60 lines mechanism C; comprehensive audit produced Phase 1 Migration Inventory documenting all 14 remaining behavioral C decisions; 127 bare metal tests pass**

### Remaining Open Problems
1. ~~**Native runtime**~~ **COMPLETE (Session 35).** ~~**Bare metal**~~ **COMPLETE (Session 36).** ~~**Assembly bootstrap**~~ **COMPLETE (Session 37).** ~~**Interactive**~~ **COMPLETE (Session 38).** ~~**Binary format**~~ **COMPLETE (Session 39).** ~~**Automated testing + kernel on hardware**~~ **COMPLETE (Session 40).** ~~**Framebuffer graphics**~~ **COMPLETE (Session 41).** ~~**Display as HERB state**~~ **COMPLETE (Session 42).** ~~**Mouse input**~~ **COMPLETE (Session 43).** ~~**Visible tensions**~~ **COMPLETE (Session 44).** ~~**Loadable behavioral programs**~~ **COMPLETE (Session 45).** ~~**Interacting processes**~~ **COMPLETE (Session 46).** ~~**Programs as data**~~ **COMPLETE (Session 47).** ~~**Hot-swappable system policy**~~ **COMPLETE (Session 48).** ~~**Text input as HERB state**~~ **COMPLETE (Session 49).** ~~**Shell as HERB process**~~ **COMPLETE (Session 50).** ~~**Unified command dispatch**~~ **COMPLETE (Session 51).** ~~**Process creation as HERB policy**~~ **COMPLETE (Session 52).** Phase 1 of C→HERB behavioral migration continues. Session 52 migrated priority cycling and program selection from C arithmetic to HERB conservation pools. 12 behavioral decisions remain in C (see item 2, 2 solved). Remaining scaffolding: dimensions in C (not yet needed), remove JSON parser from freestanding build, write-combining for framebuffer performance.
2. **Phase 1 Migration Inventory — Behavioral Logic Still in C** -- Session 51 audited every WHAT decision remaining in `kernel_main.c`. These 14 items are the roadmap for migrating policy from C to HERB. Each item is a place where C makes a behavioral decision that could instead be expressed as HERB tensions or HERB state. ~~2 items~~ **SOLVED (Session 52):** priority cycling and program assignment migrated to HERB spawn module.

   **Command/Shell (3 items):**
   - **Keystroke→command mapping:** C switch statement maps 'n'→new, 'k'→kill, 'b'→block, etc. (`handle_key()` ~L2698). Could be a keybinding program loaded from .herb data.
   - **Text→cmd_id mapping:** C maps "kill"→1, "load"→2, etc. (`parse_command()` ~L2444). Could be HERB text-matching tensions or a lookup table as HERB state.
   - **Shell action interpretation:** C interprets ShellCtl.action codes — 10→swap, 20→list, 30→help (`handle_shell_action()` ~L2516). HERB tensions set the code; C decides what each code means and performs the action.

   **Process Lifecycle (2 items — SOLVED Session 52):**
   - ~~**Priority cycling:** `pri = ((counter-1)%5+1)*2` hardcodes new process priorities to 2,4,6,8,10 cycle (`cmd_new_process()` ~L1737).~~ **SOLVED:** 5 PriToken entities in PRI_POOL with `value` properties (2,4,6,8,10), recycled when empty. HERB `min_by value` selects next priority.
   - ~~**Program assignment:** odd process_counter=producer, even=consumer (`cmd_new_process()` ~L1785).~~ **SOLVED:** 2 ProgToken entities in PROG_POOL with `type_id` properties (1,2), recycled when empty. Explicit `requested_type` from shell "load" command bypasses auto-selection. Bug fixed: "load producer" now loads a producer.

   **Display/Rendering (4 items):**
   - **State→color mapping:** C lookup tables map surface.state values (1=running, 2=ready, 3=blocked, 4=terminated) to pixel colors (~L1097). HERB owns state values; C owns what they look like.
   - **Process table ordering:** CPU0→READY→BLOCKED→TERMINATED with max 10 rows (`draw_process_table()` ~L874). Could be HERB display configuration.
   - **Terminated display limit:** max 3 terminated processes shown (~L913). Could be a HERB property.
   - **Legend/help text:** C hardcodes which keys to advertise (`draw_legend()` ~L698). Could be generated from HERB command definitions.

   **Input Handling (2 items):**
   - **Mode routing:** C checks InputCtl.mode, routes keys to HERB (text mode) or C switch (command mode) (`handle_key()` ~L2650). Could be fully HERB-driven if all keys became KEY_SIG.
   - **Click routing:** C splits tension panel clicks (C handler) vs container area clicks (HERB hit-test) based on screen coordinates (main loop ~L3018). Could be unified HERB hit-test tensions.

   **Configuration (3 items):**
   - **Timer interval:** auto-send timer signal every 300 ticks = 3 seconds (main loop ~L2957). Could be a HERB property on a timer configuration entity.
   - **Buffer capacity:** `#define BUFFER_CAPACITY 20` (~L1695). Could be a HERB property on the buffer entity read at creation.
   - **Shell protection value:** C sets `protected=1` on shell entity at boot (~L2900). The HERB `where` guard already reads it structurally, but C decides the initial value.

3. **Compositor / window manager** -- Container regions have fixed positions. Next step: layout tensions that compute positions dynamically based on window count, size, and z-order. Moving toward a full compositor where HERB manages the window tree. Mouse interaction now available for drag-and-drop, resize, and window manipulation.
4. **First real target** -- Pick the first real deliverable built entirely in HERB.
5. **Vector scoped queries** -- Currently scoped match clauses require a scalar scope binding. Supporting vector scope bindings (nested loops) would enable "for each process, count its FDs" patterns.
6. **Bidirectional channels** -- Current channels are unidirectional. Bidirectional communication requires two channels. Consider whether a single bidirectional channel primitive is worthwhile.
7. **Channel backpressure** -- Currently channels buffer unlimited messages. Real systems need flow control. Consider bounded channel buffers.
8. **Dimensional scoped containers** -- Scoped containers are currently default-dimension only. Consider whether scoped containers should support named dimensions for per-entity multi-dimensional state.
9. **Runtime module loading** -- Currently all modules must be known at compose time. Dynamic module loading at runtime would enable plugin systems.
10. **Performance benchmarking** -- Measure the actual speedup of C vs Python on the same programs. The v1 C runtime was 70-100x faster; v2 should be similar or better.
11. **C runtime: dimensions** -- The C runtime doesn't yet handle named dimensions or dimensional moves. Not currently blocking any programs.
12. **Reduce static footprint** -- The current ~3.7MB static footprint (dominated by scope tracking arrays) can be reduced for memory-constrained targets by making MAX_* constants configurable or using dynamic sizing.

### Key Insight Log
1. Provenance as navigable structure -- causality IS the program
2. Rules as facts -- changing laws is modifying the program at runtime
3. THE OPERATION SET IS THE CONSTRAINT SYSTEM -- invalid states are unreachable
4. HERB is policy, not mechanism -- coordinates what happens, native code does the math
5. HERB needs a runtime, not a compiler -- operations are data the engine interprets
6. MOVE covers containment, conservation, and state machines
7. ~~The system doesn't run itself yet~~ **SOLVED: Tensions are the energy gradients**
8. The execution model is equilibrium-seeking -- tensions create gradients, MOVEs are gravity, the system finds stable states
9. **A HERB program is a data structure, not code** -- entity types, containers, moves, tensions, entities. Tensions are declarative patterns, not callables. The AI manipulates the data structure directly.
10. **Self-transfers are structurally impossible** -- transferring quantity from an entity to itself is a meaningless operation. The runtime rejects it, preventing a class of conservation bugs where captured values go stale.
11. **Scoped containers are virtual address spaces** -- Isolation isn't enforced by checks. Each entity's scoped containers are literally different containers. Cross-scope operations don't exist, just like cross-process memory access doesn't exist in virtual memory. The pattern is the same: the namespace IS the isolation.
12. **Mutation has two modes: conserved and free** -- Conserved properties (in pools) only change via transfer (zero-sum). Free properties change via set (no conservation partner needed). The runtime enforces the boundary: attempting to `set` a pooled property fails silently.
13. **Cross-scope communication IS a MOVE through a channel** -- The research analyzed four formalisms. Every one that allowed free-form cross-boundary references (bigraphs' link graph, ambient calculus's `open`) regretted it. Channels confine cross-scope transfer to specific, typed, authorized paths. The sender loses access on send (Zircon model). The receiver gains access on receive. No implicit sharing -- duplication is explicit. Isolation holds under real communication pressure.
14. **Dimensions are orthogonal state spaces** -- An entity's position in the scheduling dimension is independent of its position in the priority dimension. This isn't Statecharts (which models orthogonal regions within a single state machine). This is the MOVE invariant (entity in exactly one container) applied PER DIMENSION. Each dimension gets its own operation-set-as-constraint. The guarantees compound: if scheduling has 3 states and priority has 3 states, you get 3x3=9 valid combinations, but each dimension's transitions are enforced independently.
15. **Composition is namespace-based isolation** -- Module names ARE the namespace. All internal names are prefixed with the module name. A tension in module A literally cannot reference module B's private containers because the qualified name `b.PRIVATE_CONTAINER` is not in A's resolve map unless B exports it. This is the same pattern as scoped containers (Discovery 11): the namespace IS the isolation. Not checked -- structural.
16. **The hot path is already freestanding** -- The tension resolution loop (step → evaluate_tension → eval_expr → try_move) uses only memset and memcpy from libc. Everything else (malloc, strcmp, printf, fopen, snprintf, atof) is load-time or diagnostic. This means the runtime was never really a "libc program" -- it was always a bare-metal engine with a libc loading wrapper. The freestanding port proved this: replacing the wrapper was mechanical; the engine didn't change at all.
17. **Hardware interrupts are just HERB signals** -- The bare-metal boot proved something fundamental about HERB's architecture: a timer interrupt creates a Signal entity in the TIMER_EXPIRED container, then the system resolves to equilibrium. The interrupt handler is 4 lines of assembly (set flag + EOI). All scheduling logic lives in HERB tensions. The boundary between hardware and language is exactly one entity creation. This is what "policy not mechanism" means in practice: the CPU fires an interrupt, the ISR creates a signal, HERB decides what happens next.
18. **The mechanism/policy boundary is the C/HERB boundary** -- The interactive OS made the architecture concrete. The C kernel handles exactly three things: scancode lookup (which key was pressed), signal creation (what entity to create), and VGA rendering (what to show). HERB handles everything else: which process runs, when to preempt, what happens when a process is killed or blocked. A new command requires one line of C (create signal in the right container) and one tension in HERB (match signal, emit action). The C never grows complex because all complexity lives in tensions.
19. **A program IS a graph description, and binary IS the right representation** -- JSON represents a HERB program as nested key-value pairs because that's how JSON works. But a HERB program is not key-value data. It's a typed graph with a fixed schema: entity types, containers, moves, tensions, entities. The binary format encodes this directly: a string table for names, then sections for each component type, with typed fields at known positions. No parsing ambiguity, no key lookup, no tree building. The 81-90% size reduction isn't about compression -- it's about removing encoding overhead that served JSON's generality, not HERB's needs. The format is simpler because it only encodes one thing.
20. **Testing bare metal through the serial port is testing through the same abstraction as running** -- The QEMU test harness sends keys and reads serial output. The kernel sends key events through HERB signals and writes serial output after each operation. The test observes the system through the exact same channel the system uses to report its own state. There's no test-specific instrumentation, no mock objects, no test mode. The serial output IS the system's self-description. This means the tests validate the real system, not a simulation of it. The harness proved this: 29 tests running against the actual booted kernel, confirming scoped resource isolation on real x86-64 hardware, with zero test-specific code in the kernel.
21. **The display IS the state graph** -- Traditional operating systems have a clear separation: the kernel manages processes internally, and applications draw to the screen through graphics APIs. In HERB OS, the display is a direct spatial encoding of the runtime's graph. Container regions map 1:1 to HERB containers. Process rectangles map 1:1 to HERB entities. Resource indicator squares map 1:1 to scoped entities. A MOVE (entity transferring between containers) manifests as a rectangle appearing in a different region. There's no display abstraction layer, no window system, no drawing API -- the render function queries the HERB runtime's state and draws what it finds. This is possible because HERB state IS structured: containers with entities, each in exactly one location. The display doesn't interpret the state; it spatially encodes it. This means the graphical output is always correct by construction -- it can't show something that isn't in the HERB graph, and it can't miss something that is.
22. **Scoped containers provide structural coupling between domains** -- Session 42 proved that scoped containers aren't just for isolation (Discovery 11). They're a general-purpose structural coupling mechanism. A Process entity owns scoped MEM_FREE/MEM_USED (resource domain), scoped FD_FREE/FD_OPEN (file domain), scoped INBOX/OUTBOX (communication domain), AND scoped SURFACE (visual domain). Each domain is independent: allocating a page doesn't affect the surface, and updating the surface doesn't affect file descriptors. But they're all structurally coupled to the same process entity. This means HERB can model cross-cutting concerns (a process has resources AND a visual representation AND a message queue) without any of them interfering. The scoped container is the universal coupling primitive: it gives an entity ownership of state in any domain, with structural isolation between domains. This is what makes the display module possible without touching the kernel module.
23. **Guard expressions enable spatial reasoning in HERB** -- Session 43 proved that HERB's expression system is powerful enough for spatial hit testing without any runtime changes. Cross-binding property comparison in guard clauses allows a tension to compare properties from different entities (click coordinates vs region bounds) using arithmetic and comparison operators (>=, <, +, and). The pattern is: C creates a signal entity with raw input data (coordinates), HERB tensions use guard expressions to match that data against the spatial layout (region positions and sizes), and the result is a semantic state change (process selected). No new runtime features were needed -- guards, property comparison, and arithmetic were all Session 29-35 features. This means HERB can do spatial reasoning as naturally as it does scheduling or resource management. The expression evaluator IS the spatial engine.
24. **The code/data distinction dissolves when rules are data** -- Session 44 proved that "tensions are data structures, not compiled code" is not just an implementation detail -- it's a user-facing capability. In every other OS, the scheduler is compiled code: opaque, fixed, invisible. In HERB, `schedule_ready` is a data structure that the runtime interprets, the display renders, and the user can disable with a keystroke. Disabling it has immediate, observable consequences: the CPU stays empty because the gradient that moves processes from READY to CPU0 no longer exists. This is the difference between "rules are data" as a theoretical property and "rules are data" as an interaction model. The energy landscape isn't a metaphor -- it's a thing you can see and manipulate. One field (`enabled`), one line in `herb_step()`, and the entire behavioral rule system becomes live-editable.
25. **A process IS its tensions** -- Session 45 dissolved the process/program distinction. In every other OS, a process has code (compiled instructions) separate from its data (memory, file descriptors). In HERB, a process's "code" IS tensions -- the same kind of data structure as the system tensions, living in the same runtime, visible in the same tension panel. Loading a program means calling `herb_tension_create()` with the process entity as owner. Killing a process means calling `herb_remove_owner_tensions()`. The scheduler doesn't execute process code -- it moves the process entity into CPU0, which causes the owner check in `herb_step()` to start firing that process's tensions. There is no instruction pointer, no program counter, no call stack. A process's behavior is a set of energy gradients that only exist when the process is scheduled. The process/program/code distinction is an artifact of the von Neumann architecture. In HERB, there's just entities, containers, and tensions.
26. **Emergent behavior from the combined energy landscape** -- Session 46 proved that independent processes produce coordinated behavior through shared state without any synchronization primitives. A Producer's tension increments a buffer's count. A Consumer's tension decrements it. Neither knows the other exists. But the combined tensions, resolved together by the runtime, produce dynamic equilibrium: the buffer fluctuates, producer and consumer take turns, and the system self-regulates. Buffer integrity (count never < 0 or > capacity) is enforced by the structure of the tensions (guards prevent invalid operations), not by locks. This is Discovery 1 operating at the process interaction level: invalid states aren't checked — they're unreachable. The key architectural insight is that multi-binding tensions (matching both "me" and "buf") enable cross-entity interaction within a single process's behavioral rule. The process's tension reaches beyond its own properties into shared state, and the runtime's atomic resolution ensures consistency without explicit coordination.
27. **Programs are compositional fragments, not standalone systems** -- Session 47 proved that a `.herb` binary doesn't have to be a complete system.
28. **System policy is data, not code — and replacing it is just two operations** -- Session 48 proved that replacing a system behavioral rule at runtime requires only: (1) remove the old tension by name, (2) load the new tension from a `.herb` binary fragment. No compatibility check is needed because Discovery 1 (the operation set IS the constraint system) protects the system structurally — a "wrong" replacement simply doesn't fire, producing zero operations. The system continues running safely. This means HERB can do something no other OS can: change its scheduling policy, display sync rules, or any other behavioral rule while running, with zero downtime, by loading a different data file. The mechanism doesn't know or care WHAT is being swapped — it just removes a named tension and loads a fragment. The generality is the point. A program fragment contains only tensions (and optionally entities) that reference containers already in the running system. The binary format requires no extension: the string table maps fragment names to the running system's intern table, and container references resolve against the existing graph. Loading a fragment is adding energy gradients to an existing landscape. The fragment doesn't need to know the full system topology — it only needs the names of the containers it references (like "proc.CPU0" and "BUFFER"). This is the same insight as scoped containers (Discovery 11) applied to programs: the namespace IS the interface. A program is written for its environment by using the right names. This means program loading is compositional: load any combination of fragments, and the combined energy landscape determines system behavior. The runtime doesn't distinguish between "system tensions" and "process tensions" after loading — they're all tensions, all resolved together.
29. **Text is not a string — it's entities in a container** -- Session 49 proved that text input doesn't need string buffers. A character is an entity with an `ascii` property. A text buffer is a container. Typing is MOVE. Deleting is MOVE. The length is a count. The cursor position is a property. The same structural guarantees that protect process isolation protect text integrity: buffer overflow is impossible because CHAR_POOL has exactly 32 entities — when it's empty, key_overflow fires and the signal is consumed harmlessly.
30. **The shell is not code — it's tensions loaded from data** -- Session 50 proved that the command interpreter doesn't need to be compiled into the kernel. The shell is a `.herb` binary fragment (806 bytes) containing 8 tensions that match CMD_SIG entities with integer properties and emit MOVEs or property mutations. The same mechanism that loads producer/consumer programs loads the shell. The same runtime that resolves scheduling tensions resolves command dispatch tensions. The C kernel provides exactly one new piece of mechanism: parsing text to integers. Everything else — deciding what "kill" means, what "list" does, how to handle an unknown command — is HERB policy. This completes a progression: Session 45 made processes into tensions, Session 47 made programs into data, Session 48 made policies swappable, and Session 50 makes the shell itself a loadable HERB process. The entire user-facing behavior of the OS is now expressed in HERB tensions loaded from `.herb` binary fragments.
31. **Command dispatch is fully unified — pressing a key and typing a command execute the same code path** -- Session 51 proved that unifying two separate dispatch mechanisms doesn't require new HERB features — just routing both through the same CMD_SIG → shell tension path. Pressing 'k' creates CMD_SIG with cmd_id=1; typing "kill" creates CMD_SIG with cmd_id=1. The HERB shell tensions cannot tell the difference because they only see the integer properties. C does only mechanism (integer → CMD_SIG → herb_run), HERB does all policy (match cmd_id, guard on protected, MOVE or delegate). Shell protection moved from a C `if (eid == shell_eid)` check to a HERB `where protected == 0` guard — making protection a structural property of the tension rather than a special case in C code. Three behavioral C functions (~97 lines) replaced by one mechanism function (~60 lines). The policy/mechanism boundary sharpened: every remaining behavioral decision in C is now documented in the Phase 1 Migration Inventory (14 items across 5 categories).
32. **Arithmetic IS entities moving through containers** -- Session 52 proved that HERB doesn't need arithmetic operators to express cycling sequences. The priority sequence 2,4,6,8,10 is not computed by `((n-1)%5+1)*2` — it IS five PriToken entities with value properties, moving from PRI_POOL to PRI_USED. `min_by value` selects the smallest available. When the pool empties, a recycle tension refills it. The cycling emerges from conservation: exactly 5 values exist, each used once, then all return. Program alternation (producer/consumer) works the same way: 2 ProgToken entities cycling through PROG_POOL→PROG_USED. This is Discovery 3 (the operation set IS the constraint system) applied to arithmetic: the sequence can't skip a value because skipping would require a value to be in two containers simultaneously. The sequence can't repeat prematurely because recycling only fires when the pool is empty. The conservation guarantee IS the cycling guarantee. No modulo needed.

---

*This is a living document. Update it every session. The latest version is always the truth.*
