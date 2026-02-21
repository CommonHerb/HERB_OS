# Session 19 Findings: The Runtime, Not The Compiler

**Date:** February 5, 2026

## The Reframe

Started this session thinking "build a compiler." Ben interrupted with the right question: why are we following the human path? HERB isn't a language in the conventional sense. It's a rule engine. Rule engines don't need compilers — they need fast runtimes.

The compiler framing came from training data. Languages get compiled. But HERB has none of the complexity that makes compilers hard:
- No call stack (no functions calling functions)
- No register allocation (no complex expressions)
- No control flow (no if/else trees)
- No variable scoping (bindings are ephemeral per-rule)

What HERB actually needs:
1. Store facts (three integers)
2. Match patterns (index lookups)
3. Loop rules until nothing changes

That's a data structure problem, not a compiler problem.

## What We Built

`herb_runtime.c` — A native HERB engine in ~400 lines of C.

**Data structures:**
- `Fact` = 3 integers (subject, relation, object) — 12 bytes
- `Pattern` = 3 integers (-1 for variable slots)
- `Rule` = patterns + template as data (not generated code)
- `World` = facts array + rules array + hash indices

**Algorithm:**
- Pattern matching via recursive backtracking
- Index selection: (r,o) index for `(?, R, O)`, (s,r) index for `(S, R, ?)`
- Derivation = while loop over rules until fixpoint

**Key insight:** Rules are DATA, not code. The runtime interprets them. No code generation needed.

## Benchmark Results

| Entities | Facts Derived | Python | C | Speedup |
|----------|---------------|--------|---|---------|
| 100 | 1000 | 109 ms | 1 ms | **109x** |
| 200 | 4000 | 550 ms | 8 ms | **69x** |

Same algorithm. Same data structures. 70-100x faster just from:
- No Python object overhead
- Integers are integers (not PyObject wrappers)
- Contiguous arrays (cache-friendly)
- No garbage collector

## This IS The Kernel Foundation

An operating system is:
- **World state**: processes, files, devices, memory as facts
- **Rules**: scheduling policy, permissions, event handlers
- **Derivation**: tick the system forward

The hard parts of an OS — interrupts, memory protection, device drivers — need hardware-specific code. But the POLICY layer — who gets CPU next, who can access what, how events propagate — is expressible as HERB rules on this runtime.

The `herb_runtime.c` we just wrote isn't a stepping stone to a kernel. It IS the kernel's policy engine. Add:
- Interrupt handlers that assert event facts
- Memory-mapped I/O that reads command facts
- Boot code that loads initial rules

And you have an OS where policy is declarative and mechanism is native.

## What Python Taught Us

The Python interpreter (`herb_core.py`) was essential. It proved:
- The semantics work (72 tests passing)
- Stratification handles complex dependencies
- Deferred rules solve ordering problems
- Multi-world enables isolation

Python let us iterate on semantics without worrying about memory management. Now that semantics are stable, the C runtime gives us speed.

## Architecture

```
┌─────────────────────────────────────────┐
│          HERB RULES (DATA)              │
│  - Loaded at boot or runtime            │
│  - Scheduling, permissions, handlers    │
└─────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────┐
│        NATIVE RUNTIME (herb_runtime.c)  │
│  - Fact store (arrays + indices)        │
│  - Pattern matching (recursive)         │
│  - Derivation loop                      │
└─────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────┐
│           NATIVE MECHANISM              │
│  - Interrupt handlers → assert facts    │
│  - Device drivers → read command facts  │
│  - Memory management → native code      │
└─────────────────────────────────────────┘
```

## Files Created

- `herb_runtime.c` — Native HERB runtime (~400 lines)
- `herb_compiler.py` — Code generator (superseded by runtime approach)
- `benchmark_python.py` — Python benchmark for comparison

## What's Next

1. **Add FUNCTIONAL to runtime** — Auto-retract for single-valued relations
2. **Add rule loading from file** — Parse .herb to runtime format
3. **Boot sequence** — Load rules, assert initial facts, enter derivation loop
4. **Interrupt integration** — Handler that asserts event facts

The runtime exists. The kernel is no longer theoretical.

## Key Insight

> We don't need a compiler because HERB rules are already data.
> We just need an engine that interprets them fast.
> That engine IS the kernel.
