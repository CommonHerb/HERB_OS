# HERB Bare-Metal Interface

The freestanding runtime has been proven to compile and link with **zero libc dependencies** and to produce **identical output** to the libc-based runtime for all programs.

This document specifies the interface between the HERB freestanding runtime and the external environment (assembly bootstrap, firmware, bootloader).

---

## The Three Requirements

The HERB freestanding runtime needs exactly three things from the outside world:

### 1. A Block of Memory (The Arena)

```c
void herb_init(void* arena_memory, herb_size_t arena_size, HerbErrorFn error_fn);
```

- **arena_memory**: pointer to a contiguous block of memory
- **arena_size**: size in bytes
- **Minimum**: 64KB for simple programs, 4MB recommended for kernel-class programs
- **Alignment**: must be 8-byte aligned

The arena is a bump-pointer allocator. It allocates forward, never frees. This is by design: HERB programs are loaded once and run forever. An OS doesn't deallocate its kernel.

**Memory layout after initialization:**

```
+---------------------------------------------------+
|                    ARENA                            |
| [JSON parser temps] [string dups] [expr arrays]    |
| ^                                                  |
| |-- used after load_program (watermark) ---------->|
|                                                    |
| [runtime entity creation uses remaining space]     |
+---------------------------------------------------+
```

**Arena sizing guide:**
| Program Type | Arena Size | Typical Usage |
|---|---|---|
| Simple scheduler | 64KB | ~20KB |
| DOM layout | 64KB | ~20KB |
| Economy | 128KB | ~20KB |
| Multi-process OS | 128KB | ~35KB |
| IPC (channels) | 128KB | ~47KB |
| Full kernel | 256KB | ~80KB (estimated) |

### 2. The Program JSON (As Bytes in Memory)

```c
int herb_load(const char* json_buf, herb_size_t json_len);
```

- **json_buf**: pointer to null-terminated JSON string
- **json_len**: length in bytes (currently unused; parser reads to null terminator)
- **Returns**: 0 on success, -1 on error

The JSON is the `.herb.json` program file, already in memory. The bootloader is responsible for getting it there. Options:
- **Embedded**: compiled into the binary as a `const char[]`
- **Loaded from disk**: bootloader reads from filesystem/partition
- **Received over network**: bootloader fetches from server
- **Memory-mapped**: at a known physical address (ROM, flash)

The JSON parser operates entirely within the arena. After `herb_load()` returns, the JSON buffer is no longer referenced — the graph has been built in static arrays.

### 3. A Way to Deliver Signals (Function Calls)

```c
int herb_create(const char* name, const char* type, const char* container);
```

- **name**: entity name (e.g., "timer_1")
- **type**: entity type (e.g., "Signal")
- **container**: target container (e.g., "TIMER_EXPIRED")
- **Returns**: entity index, or -1 on error

Signals are how the outside world communicates with the running HERB program. A timer interrupt creates a signal entity. A hardware event creates a signal entity. User input creates a signal entity. The runtime's tension loop reacts to the new entity and resolves to equilibrium.

After creating a signal, call:

```c
int herb_run(int max_steps);
```

This resolves tensions to fixpoint (equilibrium). Returns the total number of operations executed. A return value of 0 means the system is already at equilibrium.

For single-step debugging:

```c
int herb_step(void);
```

One cycle of tension evaluation and execution. Returns the number of operations executed in that step.

---

## Error Handling

```c
typedef void (*HerbErrorFn)(int severity, const char* message);
```

The error callback is provided at init time. Severity levels:
- `HERB_ERR_FATAL` (0): cannot continue (arena exhaustion, parse failure)
- `HERB_ERR_WARN` (1): recoverable (capacity warnings)

If the callback is NULL, errors are silently ignored. On bare metal, the callback can write to a UART, blink an LED, or halt the CPU.

---

## State Inspection

```c
int herb_state(char* buf, int buf_size);
```

Writes the current state as JSON into a caller-provided buffer. Returns the number of characters written. Same format as the libc runtime's stdout output.

```c
herb_size_t herb_arena_usage(void);
herb_size_t herb_arena_total(void);
```

Report arena memory statistics.

---

## Memory Architecture

### Static Allocations (Compile-Time Constants)

The runtime uses fixed-size arrays for all core data structures:

| Structure | Max Count | Size Per | Total |
|---|---|---|---|
| Entities | 512 | ~136B | 68KB |
| Containers | 256 | ~272B | 68KB |
| Move Types | 64 | ~196B | 12KB |
| Tensions | 64 | ~2.5KB | 160KB |
| Strings (intern table) | 1024 | 128B | 128KB |
| Expression pool | 4096 | ~56B | 224KB |
| Entity locations | 512 | 4B | 2KB |
| Scope data | ~3MB | | ~3MB |

**Total static footprint: ~3.7MB** (dominated by scope tracking arrays).

These are the `MAX_*` constants in the source. On a memory-constrained target, they can be reduced. A scheduler with 10 entities and 20 containers needs a fraction of this.

### Dynamic Allocations (Arena Only)

All dynamic allocation occurs during `herb_load()`:
- JSON parser nodes (JsonValue structs)
- JSON string duplication (herb_strdup)
- Array/object growth during parsing

**After load completes, the arena watermark is fixed.** The tension resolution loop performs zero allocations. Entity creation at runtime (signals) uses the arena but never frees — it bumps the watermark forward.

### The Hot Path is Allocation-Free

The functions `herb_step()` / `herb_run()` → `evaluate_tension()` → `eval_expr()` → `try_move()` etc. use only:
- Stack-local variables (arrays of bindings, intended actions)
- Static global arrays (the graph)
- `herb_memset` / `herb_memcpy` (for struct zeroing and binding copies)

No arena allocation. No string allocation. No pointer chasing through dynamically-allocated structures. Everything is arrays indexed by integers.

---

## Assembly Bootstrap Template

For a bare-metal x86-64 target, the bootstrap needs to:

```asm
; 1. Set up a stack (8KB minimum, 64KB recommended)
; 2. Reserve arena memory
; 3. Call herb_init(arena_ptr, arena_size, error_handler)
; 4. Provide JSON in memory
; 5. Call herb_load(json_ptr, json_len)
; 6. Call herb_run(100) for initial boot
; 7. Main loop: wait for interrupt, create signal, call herb_run()
```

The runtime does not use:
- Dynamic memory allocation (no malloc/free)
- Floating-point unit (no FPU instructions in the hot path)
- System calls
- Thread-local storage
- Global constructors/destructors
- C++ runtime features

The runtime DOES use:
- Stack space (several KB for tension evaluation; `char buf[4096]` in JSON parser)
- Static/global variables (the graph, string table, expression pool)
- `__builtin_va_list` (for herb_snprintf, used during entity creation)

---

## Compilation

### Freestanding (proof of zero dependencies)

```bash
gcc -ffreestanding -nostdlib -c herb_freestanding.c
gcc -ffreestanding -nostdlib -c herb_runtime_freestanding.c
gcc -ffreestanding -nostdlib -o herb.elf herb_runtime_freestanding.o herb_freestanding.o -e herb_init
```

### Hosted (test harness)

```bash
gcc -o test test_harness.c herb_runtime_freestanding.c herb_freestanding.c
```

The same source files compile in both modes. In hosted mode, `HERB_HOSTED` is automatically defined (from `__STDC_HOSTED__`), which:
- Uses `<stdint.h>` instead of our own type definitions
- Skips `memcpy`/`memset`/`memmove` definitions (libc provides them)
- Skips `___chkstk_ms` (the C runtime provides it)

---

## What Comes Next

This interface is what the assembly bootstrap will provide. The next step is to write that bootstrap — a minimal x86-64 assembly file that:

1. Sets up the GDT, IDT, page tables
2. Enters long mode
3. Reserves memory for the arena
4. Embeds or loads the HERB program JSON
5. Calls `herb_init()`, `herb_load()`, `herb_run()`
6. Installs an interrupt handler that creates signal entities and calls `herb_run()`

At that point, HERB will be running on bare metal. The operating system IS the HERB program. The tension loop IS the kernel's main loop. Interrupts create signals. Tensions resolve them. The system finds equilibrium. Then it waits.

---

## Proven Equivalence

The freestanding runtime has been tested against the libc runtime with perfect byte-for-byte state equivalence across:

| Program | Signals | Result |
|---|---|---|
| Priority Scheduler | boot | MATCH |
| Priority Scheduler | boot + timer | MATCH |
| FIFO Scheduler | boot | MATCH |
| FIFO Scheduler | boot + timer + IO | MATCH |
| DOM Layout | boot | MATCH |
| Economy | boot | MATCH |
| Economy | boot + tax | MATCH |
| Economy | boot + tax + reward | MATCH |
| Multi-process OS | boot | MATCH |
| IPC (channels) | boot | MATCH |

10/10 tests pass. Zero mismatches.
