# HERB Archive

This document contains the full session history and v1 implementation details from the original HERB Bible. It exists for reference. It is NOT required reading for new sessions.

**For what HERB is now, read HERB-BIBLE.md.**

---

## THE PIVOT (Session 21)

HERB v1 was a well-executed Datalog variant. Every component — temporal facts, forward-chaining rules, stratified derivation, provenance — existed by 1990. The combination was good, but it wasn't genuinely new.

HARD_QUESTION.md confronts this honestly. GRAPH_DESIGN.md proposes the graph/constraint/delta direction. Sessions 23-24 discovered that constraint-checking was fundamentally broken (see STRESS_TEST_FINDINGS.md) and pivoted to MOVE — the operation set IS the constraint system.

---

## v1 IMPLEMENTATION DETAILS

### Python Runtime (`herb_core.py`)
- Temporal facts with provenance
- Pattern matching with variable unification
- Conjunctive queries across multiple patterns
- Derivation rules (forward chaining to fixpoint)
- Arithmetic in rule templates
- RETRACT semantics
- Multiple templates per rule (THEN a AND b)
- N-phase stratification (Datalog-style)
- Functional relations (§12) — auto-retract on update
- Deferred rules (§14) — micro-iterations within ticks
- Once-per-tick rules (§15) — action limiting for agents
- Stratified aggregation (sum, count, max, min)
- Guards (§10) — IF condition filters
- Negation (§11) — not-exists absence checks
- Multi-World architecture (§13) — Verse with inheritance, exports, messaging
- Compound indices for O(1) lookup
- Time-travel queries, explain(), history()

### Native Runtime (`herb_runtime.c`, `herb_runtime_ext.c`)
- Facts as 3-integer triples (12 bytes each, cache-friendly)
- Pattern matching with recursive backtracking
- Hash indices for existence and iteration
- 70-100x faster than Python interpreter
- ~900 lines extended with FUNCTIONAL, EPHEMERAL, DEFERRED, ONCE_PER_TICK
- Expression support (arithmetic in templates)
- Guard support (comparison operators)

### Language (`herb_lang.py`)
- Tokenizer and parser for `.herb` files
- Compiles to World objects
- Parses FUNCTIONAL, aggregates, guards, negation

### Test Suite (131 tests across 16 files, all passing)
- test_arithmetic.py, test_retract.py, test_combat_chain.py
- test_aggregation.py, test_parser_aggregate.py, test_guards.py
- test_negation.py, test_phase3.py, test_functional.py
- test_boolean.py, test_operators.py, test_multiworld.py
- test_deferred.py, test_once_per_tick.py, test_move_act.py
- test_pathfinding.py

### Performance (benchmark.py, Session 5)
- Damage application (O(N)): 100 entities in 2ms
- Combat proximity (O(N²)): 100 entities in 320ms (after 7x speedup from compound indices)
- 100 entities meets 600ms target for Common Herb tick rate

---

## v2 IMPLEMENTATION DETAILS

### Graph Approach (Sessions 21-23, superseded by MOVE)
- `herb_graph.py` — Core Graph class with primordial entities, relation types, tuples, deltas
- Resolution loop with pending delta queue, priority ordering, precondition/postcondition checking
- Derived constraints and maintenance constraints
- Tests passing but STRESS_TEST_FINDINGS.md revealed fundamental flaws (double-spend bug)

### MOVE Approach (Sessions 24-25, current)
- `herb_move.py` — MoveGraph with containers, MoveTypes, GoalPursuit
- Operation existence determines validity (not constraint checking)
- Tested: process scheduling, double-spend prevention, memory regions, file descriptors, DOM positioning
- 19 formal tests in test_goal_pursuit.py

---

## SESSION HISTORY

### Session 1-4: v1 Foundation
- Basic fact store, pattern matching, rules, derivation
- Guards, arithmetic, retraction semantics
- First combat demos

### Session 5: Performance + Negation
- Compound indices (7x speedup)
- not-exists expressions
- First Common Herb combat port
- Binding re-validation for consume-and-update races

### Session 6: Post-Aggregate Derivation
- Phase 3 for aggregate → RETRACT patterns
- Dependency-aware rule classification

### Session 7: N-Phase Stratification + Functional Relations
- Datalog-style arbitrary strata
- FUNCTIONAL auto-retract (eliminates RETRACT boilerplate)

### Session 8: Economy System
- Boolean literal consistency
- Multiple templates per rule
- Common Herb economy port (shops, jurisdictions, taxes)

### Session 9: Political System
- abs/mod operators
- Citizens, ideology, elections, voting

### Session 10: Election Completion
- Winner declaration with aggregation
- Treasury aggregation
- 5-stratum stratification

### Session 11: Legislation
- Tax bill lifecycle
- Transform relation handling (false cycle prevention)

### Session 12: OS Experiments
- Process scheduler, file system, isolation, I/O as facts
- KEY INSIGHT: HERB is policy, not mechanism
- I/O boundary is clean (drivers assert events, HERB processes, drivers execute)
- Critical gaps: no isolation, no bitwise ops, triples limiting

### Session 13: Multi-World Design
- Nested Worlds with inheritance + exports
- Provenance survives World boundaries

### Session 14: Multi-World Implementation
- Verse class, inheritance, exports, messaging
- 22 new tests, 2 demos

### Session 15: Deferred Rules
- Micro-iterations for causal ordering
- Combat expressible in 5 clean rules
- Ephemeral consumption fix

### Session 16: Once-Per-Tick
- Action limiting for multi-agent simulation
- Boolean logic operators (and, or, not)
- KEY INSIGHT: Fixpoint derivation ≠ agent simulation

### Session 17: Move+Act Composition
- Once-per-tick persists across micro-iterations
- once_key_vars behavior documented

### Session 18: Pathfinding
- Rule-based BFS works but O(N²) vs native A* O(N log N)
- Native A* + HERB movement recommended
- KEY INSIGHT: Paradigm boundary (algorithm performance)

### Session 19: Runtime, Not Compiler
- HERB doesn't need a compiler — rules are DATA
- Native C runtime: 70-100x faster than Python
- This IS the kernel foundation

### Session 20: Four Primitives in C
- FUNCTIONAL, EPHEMERAL, DEFERRED, ONCE_PER_TICK in native runtime
- Expression and guard support in C
- 131 tests passing

### Session 21: The Pivot
- Acknowledged v1 is "very good Datalog variant"
- Created GRAPH_REPR.md, GRAPH_RESOLUTION.md, GRAPH_CONSTRAINTS.md, GRAPH_BOOTSTRAP.md
- Implemented core Graph class with typed entities, relation types, tuples, deltas

### Session 22: Resolution Loop
- Pending delta queue with priority and dependencies
- Precondition/postcondition checking
- Derived and maintenance constraints
- Main resolve() loop with quiescence detection

### Session 23: Stress Testing (CRITICAL)
- Double-spend bug found (both players get same item)
- Invariants detect but don't prevent corruption
- Tax rate TOCTOU vulnerability
- KEY INSIGHT: Constraint checking is fundamentally broken

### Session 24: THE BREAKTHROUGH
- THE OPERATION SET IS THE CONSTRAINT SYSTEM
- MOVE primitive covers containment, conservation, state machines
- Invalid moves don't exist (not "fail" — don't exist)
- herb_move.py implemented with 4 passing demos

### Session 25: Goal Pursuit
- GoalPursuit class with BFS, slot occupancy, nested blocking
- 19 tests passing
- DOM positioning and cascading preemption examples

### Session 26: Bible Rewrite
- Identified that HERB is a passive data structure, not a language
- REACT primitive proposed as the missing piece
- Bible rewritten to be vision-driven, not history-driven

---

## KEY INSIGHTS (Chronological)

1. Provenance as navigable structure (Session 1)
2. Rules as facts — changing laws IS modifying the program (Session 2)
3. Forgetting is a fact (Session 2)
4. RETRACT enables state transitions (Session 5)
5. Stratification keeps aggregates pure (Session 7)
6. Transform relations break false cycles (Session 11)
7. HERB is policy, not mechanism (Session 12)
8. I/O boundary is clean (Session 12)
9. Provenance survives Multi-World (Session 13)
10. Deferred rules solve combat sequencing (Session 15)
11. Multi-agent actions require ONCE PER TICK (Session 16)
12. Pathfinding: paradigm boundary (Session 18)
13. HERB needs a runtime, not a compiler (Session 19)
14. THE OPERATION SET IS THE CONSTRAINT SYSTEM (Session 24)
15. MOVE covers containment, conservation, state machines (Session 24)
16. REACT is what turns HERB from a library into a language (Session 26)

---

## DESIGN DOCUMENTS INDEX

- `HARD_QUESTION.md` — Why v1 wasn't novel enough
- `GRAPH_DESIGN.md` — Graph/constraint/delta direction
- `GRAPH_REPR.md` — In-memory representation
- `GRAPH_RESOLUTION.md` — Execution algorithm
- `GRAPH_CONSTRAINTS.md` — Constraint language spec
- `GRAPH_BOOTSTRAP.md` — Primordial structure
- `MOVE_PRIMITIVE.md` — The MOVE breakthrough
- `MULTI_WORLD_DESIGN.md` — Multi-World architecture
- `STRESS_TEST_FINDINGS.md` — Why constraint-checking broke
- `OS_EXPERIMENT_FINDINGS.md` — HERB vs OS concepts
- `SESSION_18_FINDINGS.md` — Pathfinding paradigm boundary
- `SESSION_19_FINDINGS.md` — Runtime vs compiler
- `SESSION_20_FINDINGS.md` — Native runtime primitives

---

*This archive is for reference. The living document is HERB-BIBLE.md.*
