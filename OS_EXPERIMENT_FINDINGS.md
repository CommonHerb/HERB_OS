# HERB OS Stress Test — Session 12 Findings

**Date:** February 4, 2026
**Goal:** Test whether HERB's temporal-provenance paradigm generalizes from game logic to OS primitives.

---

## Executive Summary

HERB's paradigm **partially** generalizes to OS concepts. State machines, resource allocation, permission derivation, and event handling all work naturally. However, there are **critical gaps** that would prevent building a real operating system:

1. **No process isolation** — single shared fact store
2. **Logical time vs physical time** — can't meet real-time requirements
3. **Triple-only facts** — awkward for operations needing 4+ parameters
4. **Missing primitives** — bitwise ops, current-tick, deterministic tie-breaking

The paradigm works for **OS policy** (what should happen) but not **OS mechanism** (how to make it happen efficiently). This suggests HERB could be the "brain" of an OS (scheduler policy, permission checks, resource allocation logic) while lower-level code handles the "nervous system" (interrupt handling, memory management, I/O).

---

## Experiment 1: Process Scheduler

### What Worked

**State machines are natural:**
```herb
FUNCTIONAL state          # Each process has exactly one state
FACT proc_a state ready
# Rule transitions: ready -> running -> blocked -> terminated
```

Process state transitions (ready → running → blocked) work perfectly with FUNCTIONAL relations and RETRACT. No mutex primitives needed — FUNCTIONAL enforces single-state naturally.

**Aggregates express scheduling policy:**
```herb
# Find highest priority among ready processes
THEN ?cpu max_ready_priority (max ?p WHERE ?proc is_a process ?proc state ready ?proc priority ?p)
```

Priority scheduling (find max priority, then oldest waiter among ties) is expressible through aggregate chains.

**Provenance traces scheduling decisions:**
```
Why is proc_a running?
  Cause: rule:assign_cpu
    <- (proc_a selected_for cpu0) (cause: rule:select_to_run)
    <- (proc_a state ready) (cause: asserted)
```

### What Didn't Work

**Aggregate chains are verbose:**
One scheduling decision requires:
- Stratum 1: Find max priority (aggregate)
- Stratum 2: Identify candidates + cleanup
- Stratum 3: Find oldest waiter (aggregate)
- Stratum 4: Select + assign + cleanup

That's **9 rules across 5 strata** for round-robin priority scheduling. Real schedulers do this in a few lines of C.

**Tie-breaking is non-deterministic:**
When multiple processes have the same priority and wait time, HERB selects ALL of them. The FUNCTIONAL `assigned_to` relation then picks one arbitrarily (last one wins). This is technically valid but not controllable.

**Time is logical, not physical:**
HERB ticks are derivation cycles. A "time quantum" of 10ms has no meaning — it would be 10 ticks, but each tick's wall-clock duration is undefined. Real scheduling needs timer interrupts and sub-microsecond preemption.

---

## Experiment 2: File System

### What Worked

**Hierarchical structure is natural:**
```herb
FACT home parent root
FACT root contains home
FACT alice_home parent home
```

Directory containment works perfectly. Bidirectional relations (parent/contains) enable different query patterns.

**Permissions as derived facts:**
```herb
RULE owner_can_read
  WHEN ?user is_owner_of ?file
  THEN ?user can_read ?file
```

"Can user X access file Y?" becomes a derived fact with full provenance. Traceable, explainable, auditable.

**File locks via FUNCTIONAL + negation:**
```herb
FUNCTIONAL lock_holder    # Only one writer at a time

RULE grant_open_write
  WHEN ?proc open_request ?file write
  IF (not-exists ?file lock_holder ?any)
  IF (not-exists ?file reader ?any)
  THEN ?proc has_open_fd ?file write
  AND ?file lock_holder ?proc
```

### What Didn't Work

**No bitwise operations:**
Unix permissions are bit masks (mode 644 = rw-r--r--). Checking "can group read?" means `(mode & 040) != 0`. HERB has `mod` but no bitwise AND/OR/XOR. Had to use hacks like `(>= ?m 640)`.

**No string operations:**
Path "/home/alice/notes.txt" can't be parsed, split, or compared. Path resolution requires pre-structuring paths as linked facts — extremely verbose.

**Triples are limiting:**
`open(file, mode)` needs 3 parameters: process, file, mode. But HERB facts are triples (subject, relation, object). Options:
1. Reification: `(req_001 is_a open_request)`, `(req_001 file notes.txt)`, `(req_001 mode read)`
2. Compound relations: `(proc1 open_request_read notes_txt)`
3. N-ary facts (not supported)

**No current_tick primitive:**
`(file modified_at (current-tick))` doesn't work. Timestamps in templates require access to world.tick, which doesn't exist as an expression.

---

## Experiment 3: Process Isolation

### The Fundamental Problem

HERB has ONE World. All facts are visible to all rules. This is a **shared-everything** model.

OS isolation is the **opposite**: different views of reality for different actors. Process A's memory is invisible to Process B. Container namespaces see different /etc/hosts files.

```python
# Demonstration of the problem:
world.assert_fact("proc_a", "secret", "password123")
world.assert_fact("proc_b", "secret", "hunter2")

# Process B can see Process A's secret!
result = world.query(("proc_a", "secret", X))
# Returns: {'x': 'password123'}
```

### Proposed Solutions

1. **Multi-World Architecture (Verse)**
   - Each process/namespace gets its own World
   - Shared "kernel" World visible to all
   - Explicit channels for inter-world communication
   - **Cleanest but requires major refactoring**

2. **Visibility Metadata**
   - Facts have `[visible_to: ns1]` annotations
   - Query engine filters by visibility
   - Still capability-based, not true isolation

3. **Capability Tokens**
   - Prefix all facts with namespace token
   - Rules must explicitly pattern on their namespace
   - Error-prone but works within current model

### Verdict

**HERB cannot currently model OS isolation.** This is a critical gap. Without isolation, HERB cannot be an OS — it's fundamentally a single-address-space system.

---

## Experiment 4: I/O as Facts

### What Worked

**Event-as-fact model is clean:**
```python
# External driver asserts event
world.assert_fact("keyboard", "key_pressed", "a")

# HERB rule processes it
RULE handle_keypress
  WHEN keyboard key_pressed ?key
  THEN keyboard last_key ?key
  RETRACT keyboard key_pressed ?key
```

Events arrive as facts, rules process them, RETRACT consumes them. This is elegant.

**Driver boundary is well-defined:**
- Drivers are external code (Python/C/Rust)
- They receive hardware interrupts
- They assert events into World
- They read command facts from World
- They execute commands on hardware

HERB is the "brain" (policy). Drivers are the "nervous system" (mechanism).

**Provenance works for I/O:**
```
Why is last_key "a"?
  Cause: rule:handle_keypress
    <- (keyboard key_pressed a)
```

### What Didn't Work

**Real-time requirements unmet:**
Hardware events arrive with nanosecond precision. HERB ticks are logical, not timed. Processing one tick might take 1ms of real time — events during that tick queue for the next. This adds unacceptable latency for OS-level I/O.

**Negative cycles with defaults:**
Wanted to write:
```herb
RULE device_init
  WHEN ?dev is_a device
  IF (not-exists ?dev status ?any)
  THEN ?dev status initializing
```

This creates a negative cycle: reads `status` (via not-exists), writes `status`. Datalog stratification correctly rejects it. Had to use explicit initial facts instead.

**No blob/binary type:**
Network packets, framebuffers, disk blocks are binary data. HERB facts are (atom, atom, atom). Can't efficiently represent 4KB blocks as facts.

---

## Categorized Feature Gaps

### Missing Operators

| Feature | Use Case | Priority |
|---------|----------|----------|
| `(band a b)`, `(bor a b)` | Permission bit masks | HIGH |
| `(current-tick)` | Timestamps in templates | HIGH |
| `(concat a b)` | String building | MEDIUM |
| `(split str delim)` | Path parsing | MEDIUM |

### Missing Types

| Feature | Use Case | Priority |
|---------|----------|----------|
| Blob/binary | Packets, buffers, blocks | HIGH for OS |
| N-ary facts | Operations with 4+ params | MEDIUM |

### Architectural Gaps

| Feature | Use Case | Priority |
|---------|----------|----------|
| Multi-World (Verse) | Process isolation | **CRITICAL for OS** |
| Driver interface | Hardware boundary | HIGH |
| Deterministic tie-break | Scheduling | MEDIUM |
| Real-time tick mode | Interrupt handling | LOW (maybe out of scope) |

---

## Honest Assessment

### Does HERB's paradigm generalize to OS?

**Partially.** The temporal-provenance-as-structure model works beautifully for:
- Policy logic (what SHOULD happen given current state)
- Permission derivation (can X do Y?)
- State machines (process lifecycle, file descriptors)
- Audit trails (why did X happen?)

It breaks down for:
- Isolation (fundamentally incompatible with single World)
- Real-time requirements (logical time vs wall-clock time)
- Low-level operations (bit manipulation, binary data)
- Efficiency-critical paths (scheduling in microseconds)

### What would it take to build an OS?

1. **Multi-World architecture** — non-negotiable for isolation
2. **Hybrid execution** — HERB for policy, native code for mechanism
3. **Accept latency tradeoffs** — HERB manages high-level state, drivers handle interrupts directly
4. **Add missing primitives** — bitwise ops, current-tick, blob type

### Is this still HERB's mission?

The Bible says: "Build an operating system from scratch."

Two interpretations:
1. **HERB replaces all OS code** — This requires solving the gaps above. Major engineering.
2. **HERB is the policy layer** — Native drivers + HERB scheduler policy + HERB permission system. More tractable.

Option 2 feels more realistic. HERB is powerful for expressing WHAT should happen. Making it happen efficiently at hardware speeds is a different problem.

---

## Files Created

- `os_scheduler.herb` — Process scheduler model
- `os_filesystem.herb` — File system model
- `os_isolation.herb` — Isolation exploration (conceptual)
- `os_io.herb` — I/O event handling
- `run_os_experiments.py` — Test runner
- `OS_EXPERIMENT_FINDINGS.md` — This document

---

## Next Steps

1. **Design Multi-World architecture** — Sketch `Verse` class containing multiple Worlds
2. **Add bitwise operators** — `band`, `bor`, `bxor`, `bnot` to expression evaluator
3. **Add current-tick primitive** — Expose world.tick in templates
4. **Continue Common Herb port** — Movement/pathfinding proves the paradigm for games
5. **Revisit OS mission** — Consider "policy layer" interpretation

---

*The paradigm is genuinely novel. It doesn't break against OS concepts — it reveals where it belongs in the stack. HERB is a language for expressing and reasoning about policy, not for writing interrupt handlers.*
