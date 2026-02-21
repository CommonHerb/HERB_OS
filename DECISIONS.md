# HERB Technical Decisions

This document captures WHY specific design choices were made. The Bible says what HERB is. STATUS says what's been done. This is the case law — the reasoning that future Claude instances should understand before relitigating.

---

## Settled Decisions

### 1. Facts are temporal with provenance (not flat triples)

**Date:** February 4, 2026

**Context:** Started with flat (subject, relation, object) triples like RDF. Realized this is just a graph database with triggers — nothing novel.

**Decision:** Every fact has:
- `from_tick`: when it became true
- `to_tick`: when it stopped being true (None = still true)
- `cause`: what created it ("asserted", "rule:combat_starts", etc.)
- `cause_facts`: tuple of FactIDs this was derived from

**Why:** This makes causality the structure itself, not something reconstructed from logs. You can ask "why is this true?" and get the full provenance chain. You can ask "what was true at tick 5?" and get consistent historical state. This is genuinely novel — not just Prolog/RDF with new syntax.

**What was tried:** Flat triples first. Worked but wasn't differentiated from existing systems.

**Status:** Implemented and working. `world.explain()` and `world.history()` both function.

---

### 2. Rules are facts (stored in the fact store)

**Date:** February 4, 2026

**Decision:** When you add a derivation rule, it's also asserted as facts:
```
(rule_name, is_a, derivation_rule)
(rule_name, pattern_count, N)
```

**Why:** This means rules are queryable and modifiable at runtime. A legislature voting to change tax law is literally modifying the program. Game mechanics and game state become the same thing. This collapses the code/data distinction in a philosophically clean way.

**Status:** Partially implemented. Rules are stored as facts but can't yet be modified at runtime to affect behavior.

---

### 3. Forgetting is a fact (not silent deletion)

**Date:** February 4, 2026

**Decision:** When the forgetting policy removes old facts, it first asserts:
```
(forgotten:F17, was, "(player x 50)")
```

**Why:** The system should be self-describing all the way down. Even its limitations are expressed in its own paradigm. You can query "what did the system forget?" This maintains auditability even under memory pressure.

**Status:** Implemented in `herb_serialize.py` forgetting policies.

---

### 4. Weight/inertia on facts (not all facts are equal)

**Date:** February 4, 2026

**Decision:** Facts can have a `weight` annotation: `FACT hero is_a player [weight: 1000]`

High weight = important (laws, schema, births, deaths). Survives forgetting.
Low weight = ephemeral (position updates, visibility). Forgotten first.

**Why:** A constitutional amendment and a position update at tick 4,217 are fundamentally different kinds of knowledge. The system should know this intrinsically.

**Status:** Parser handles the syntax. Weight stored as metadata fact. Forgetting policy doesn't use it yet.

---

### 5. .herb notation for source code

**Date:** February 4, 2026

**Decision:**
```
FACT subject relation object [weight: N]
RULE name
  WHEN ?var relation ?var2
  AND pattern...
  THEN ?var new_relation ?var2
```

**Why:** Concrete notation is required. "No source code" was philosophically clean but practically useless. This notation is:
- Machine-readable (easy to parse)
- AI-writable (clear structure, no ambiguity)
- Human-inspectable (when needed)

**What was tried:** Considered pure JSON, considered "no source at all just world snapshots." Both failed the authoring test — when you sit down to define combat rules, you need to write SOMETHING.

**Status:** Parser works. Compiles to World objects. Successfully runs combat_simple.herb.

---

### 6. Aggregation via explicit primitive (Session 3)

**Date:** February 4, 2026

**Problem:** "Sum of all equipment bonuses" can't be expressed cleanly. Sequential rules are order-dependent (breaks the paradigm).

**Decision:** Option 1 — explicit aggregate primitives: `(sum ?bonus WHERE ?p has_bonus ?bonus)`

**Why:** It's honest about what's happening. Aggregate rules run in a later stratum after base rules reach fixpoint, ensuring they see stable data.

**Status:** ✅ IMPLEMENTED. `sum`, `count`, `max`, `min` with WHERE patterns. N-phase stratification handles arbitrary aggregate chains.

---

### 7. RETRACT happens after assertions, within binding (Session 3-6)

**Date:** February 4, 2026

**Problem:** Rules that remove facts can cause cascading retractions. Need clear semantics.

**Decision:** Within a single binding:
1. All template assertions happen first
2. Then all retractions happen
3. New derivation iteration checks if bindings still valid

**Why:** This allows `THEN ?e hp (- ?old ?dmg) RETRACT ?e hp ?old` — new HP asserted before old HP retracted. Binding re-validation prevents stale data races.

**Status:** ✅ IMPLEMENTED. Spec §5.3 and §6.1.

---

### 8. Arithmetic evaluates at rule firing (Session 3)

**Date:** February 4, 2026

**Problem:** `THEN ?defender hp (- ?current ?damage)` — when does the subtraction happen?

**Decision:** Expressions in templates are evaluated when the rule fires and all variables are bound. The result is a concrete value that gets asserted.

**Status:** ✅ IMPLEMENTED. Full arithmetic and comparison operators including `abs`, `mod`.

---

### 9. HERB is policy, not mechanism (Session 12)

**Date:** February 4, 2026

**Context:** OS stress-testing revealed HERB's paradigm boundaries.

**Decision:** HERB excels at expressing WHAT should happen (scheduler policy, permission derivation, resource allocation logic) but not HOW to make it happen efficiently (microsecond interrupt handling, memory management, I/O).

**Why:**
- HERB ticks are logical, not physical — can't meet real-time requirements
- Single derivation cycle might take milliseconds — too slow for interrupt handling
- The paradigm's strength is declarative policy with provenance, not efficiency-critical mechanism

**Implication:** For OS work, HERB should be the "brain" (high-level policy) while native code handles the "nervous system" (drivers, interrupts, memory). The I/O boundary is clean: drivers assert events as facts, HERB rules process them, drivers read commands and execute.

**Status:** DECIDED. Documented in `OS_EXPERIMENT_FINDINGS.md`.

---

### 10. Single World cannot model process isolation (Session 12)

**Date:** February 4, 2026

**Context:** OS stress-testing revealed a critical architectural gap.

**Decision:** HERB's single-World, all-facts-visible model is fundamentally incompatible with OS process isolation. Two processes should not see each other's memory/facts.

**Options for future:**
1. Multi-World architecture (Verse containing multiple Worlds)
2. Visibility metadata on facts
3. Capability tokens (convention-based scoping)

**Leaning toward:** Option 1 (Multi-World). It provides true structural isolation while preserving provenance within each context.

**Status:** GAP IDENTIFIED. Design completed Session 13. Implementation pending.

---

### 11. Nested Worlds with Inheritance and Exports (Session 13)

**Date:** February 4, 2026

**Context:** Designing Multi-World architecture to enable isolation for OS/game.

**Decision:** Adopt "Nested Worlds" model:
- Worlds form a tree (parent-child relationships)
- Children inherit parent facts (read-only downward visibility)
- Children export selected facts to parent (controlled upward visibility)
- Siblings cannot see each other (true isolation)
- Messages via inbox/SEND mechanism

**Options considered:**

1. **Hierarchical Projection** — Parent sees child exports, no inheritance. Good for OS but awkward for shared visible state (terrain).

2. **Shared-Nothing Channels** — Peer Worlds with explicit channels. Most flexible but requires too much boilerplate. Like Erlang.

3. **Layered Visibility** — Single fact store with access control. Simplest but not true isolation — facts still exist globally. Like RBAC.

4. **Nested Worlds (chosen)** — Combines inheritance (shared visible state) with exports (controlled visibility). Fits both OS and game patterns.

**Why Nested Worlds:**

- **Inheritance solves shared visible state.** Game terrain, shared libraries — things multiple actors should see read-only. Children see parent facts automatically.

- **Exports solve controlled visibility.** Parent (kernel/server) sees only what children declare as exported. No accidental leakage.

- **Tree structure is universal.** OS: kernel→process. Game: server→player. Both fit naturally.

- **Provenance survives.** Within a World: full provenance. Across boundaries: "exported from X" or "received from X" without exposing internals. Causality remains navigable structure.

**Key design choices:**

1. **Downward inheritance is read-only.** Child cannot retract parent facts.

2. **Upward export is declared.** EXPORTS relation lists what parent can see.

3. **Messages via inbox.** SEND creates fact in child's inbox. Child patterns on inbox, RETRACT after handling.

4. **No sibling visibility.** Process A cannot see Process B. Must go through parent.

5. **Per-World stratification.** Each World derives independently. Order: parent first, then children.

6. **Provenance at boundaries only.** Parent sees "exported from child" but not child's internal derivation chain. Isolation preserved.

**What this enables:**

- OS: Kernel sees process metadata without seeing memory. Processes share libraries through inheritance.
- Game: Players see terrain (inherited), export positions, can't see each other's HP/inventory.

**Status:** DESIGNED. See `MULTI_WORLD_DESIGN.md` for full details. Implementation pending.

---

## Open Questions (Not Yet Decided)

### A. When does HERB stop being Python?

**Problem:** The Bible says "from scratch" for the OS. Python can't be load-bearing forever.

**Current stance:** Python is scaffolding, not foundation. The semantics must be clean enough to compile to native code later. For now, prototyping the paradigm matters more than the implementation language.

**Not urgent but:** Don't design features that inherently require Python's runtime (reflection, dynamic typing abuse, etc.).

**Status:** Deferred. Revisit when paradigm is proven.

---

### B. Multi-World architecture for isolation

**Problem:** Single World can't model process isolation (see Settled Decision #10).

**Options:**
1. Verse class containing multiple Worlds with visibility rules
2. World layers (child sees parent, parent doesn't see child)
3. Fact visibility metadata (query-time filtering)

**Leaning toward:** Option 1. Clean structural isolation.

**Key questions:**
- Where do shared facts live (hardware state, kernel)?
- How do Worlds communicate (message channels)?
- How does a scheduler see all Worlds to manage them?

**Status:** Unresolved. Sketched in `os_isolation.herb`. Critical for OS mission.

---

### C. Missing operators for OS work

**Problem:** OS experiments revealed missing primitives (Session 12).

**Needed:**
- Bitwise: `(band a b)`, `(bor a b)`, `(bxor a b)`, `(bnot a)` — for permission masks
- Time: `(current-tick)` — for timestamps in templates
- Deterministic tie-breaking — for scheduling when multiple candidates equal

**Status:** Unresolved. Should be straightforward to add to expression evaluator.

---

## Anti-Patterns (Things We Tried That Failed)

### Flat triples without temporal extent
Just a graph database with triggers. Not novel. Abandoned in favor of temporal facts.

### "No source code" philosophy
Philosophically elegant, practically useless. You need an authoring format. Settled on .herb notation.

### Variables as first-class values stored in facts
Considered storing `?x` in the fact store. Rejected — variables are query-time bindings, not persistent values.

### Using not-exists to set default values (Session 12)
Tried: `IF (not-exists ?dev status ?any) THEN ?dev status initializing`
This creates a negative cycle — rule reads `status` and writes `status`. Datalog stratification correctly rejects it. Use explicit initial facts instead, or a different trigger pattern.

---

*Update this document every session. Future Claude instances will thank you.*
