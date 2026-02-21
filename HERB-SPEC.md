# HERB Language Specification

**Version:** 0.1 (Draft)
**Date:** February 4, 2026

This document defines HERB's semantics independently of any implementation. A conforming implementation must behave as described here. Where the reference Python implementation differs, this spec takes precedence.

---

## 1. Core Concepts

### 1.1 Values

A **value** is one of:
- An **atom**: a symbol (e.g., `hero`, `forest`, `hp`)
- A **number**: an integer or floating-point value
- A **boolean**: `true` or `false`
- A **fact-id**: a reference to a specific fact instance

Values are immutable and have no identity beyond their content. Two atoms with the same name are the same atom.

### 1.2 Facts

A **fact** is a statement that something is true during some interval of time.

A fact consists of:
- **subject**: a value (typically an atom identifying an entity)
- **relation**: a value (typically an atom naming the relationship)
- **object**: a value (the related value)
- **from_tick**: the tick at which this fact became true
- **to_tick**: the tick at which this fact ceased to be true (or ⊥ if still true)
- **cause**: why this fact is true (see §3)
- **cause_facts**: the facts this was derived from (may be empty)

A fact is **alive** at tick T if: `from_tick ≤ T` and (`to_tick = ⊥` or `T < to_tick`).

**Notation:** We write facts as `(subject relation object)`. For example: `(hero hp 100)`.

### 1.3 Fact Identity

Two facts are **identical** if they have the same subject, relation, object, and from_tick.

Two facts are **equivalent** if they have the same subject, relation, and object (regardless of temporal bounds).

**Key semantic choice:** Relations are **multi-valued**. An entity may have multiple alive facts with the same subject and relation but different objects. For example, `(hero equipped sword)` and `(hero equipped shield)` can coexist.

For relations that should be single-valued (like `hp`), the programmer must use RETRACT to remove old values before asserting new ones. The runtime does not enforce single-valuedness.

*Rationale:* Making all relations multi-valued is simpler and more general. Single-valued relations are a constraint, not the default. This matches RDF semantics and avoids implicit overwrites.

### 1.4 The World

A **world** is:
- A set of facts (including historical/retracted facts)
- A current tick (non-negative integer)
- A set of derivation rules
- A set of reaction rules (future extension)

The world is the complete state of a HERB program.

---

## 2. Patterns and Matching

### 2.1 Variables

A **variable** is written `?name`. Variables match any value and bind to it.

### 2.2 Patterns

A **pattern** is a triple `(subject relation object)` where each position is either:
- A concrete value, or
- A variable

### 2.3 Matching

A pattern **matches** a fact under bindings B if:
- For each position that is a concrete value, the fact's value equals it
- For each position that is a variable:
  - If the variable is already bound in B, the fact's value equals the bound value
  - If the variable is unbound, it becomes bound to the fact's value

Matching produces extended bindings or fails.

### 2.4 Conjunctive Queries

A **query** is a sequence of patterns. The query succeeds with bindings B if there exist facts f₁, f₂, ... such that:
- Pattern 1 matches f₁ producing bindings B₁
- Pattern 2 matches f₂ under B₁ producing bindings B₂
- ... and so on

The result of a query is the set of all such complete bindings.

---

## 3. Provenance

Every fact has a **cause** explaining why it exists:

- `"asserted"`: The fact was directly asserted (initial state or external action)
- `"rule:NAME"`: The fact was derived by the rule named NAME
- `"updated"`: The fact replaced a previous fact with the same subject and relation
- `"retracted:REASON"`: A tombstone indicating the fact was retracted (future extension)

Every derived fact also records **cause_facts**: the specific fact instances (by fact-id) that the derivation depended on. This enables full provenance tracing.

---

## 4. Expressions

### 4.1 Syntax

An **expression** is:
- A value (number, atom, boolean)
- A variable
- A compound: `(op arg₁ arg₂ ...)`

### 4.2 Evaluation

Expressions are evaluated with respect to bindings B:
- A value evaluates to itself
- A variable evaluates to its binding in B (error if unbound)
- A compound evaluates its arguments, then applies the operator

### 4.3 Operators

Arithmetic (return numbers):
- `(+ a b ...)` — sum
- `(- a b)` — difference (or negation if one argument)
- `(* a b ...)` — product
- `(/ a b)` — quotient
- `(abs a)` — absolute value
- `(mod a b)` — modulo (remainder)
- `(max a b ...)` — maximum of arguments
- `(min a b ...)` — minimum of arguments

Comparison (return booleans):
- `(= a b)` — equality
- `(not= a b)` — inequality
- `(< a b)`, `(> a b)`, `(<= a b)`, `(>= a b)` — ordering

Aggregation (return values, see §6.3):
- `(sum ?var WHERE pattern ...)` — sum of ?var across all matches
- `(count WHERE pattern ...)` — count of matches
- `(max ?var WHERE pattern ...)` — maximum
- `(min ?var WHERE pattern ...)` — minimum

**Restriction:** Aggregate expressions may only appear in **aggregate rules** (see §5.4). A rule containing any aggregate expression in its template is automatically an aggregate rule and runs in Phase 2. Aggregate expressions in non-aggregate rules are a static error.

---

## 5. Rules

### 5.1 Derivation Rules

A **derivation rule** consists of:
- **name**: identifier for the rule
- **patterns**: a conjunctive query (the "when" clause)
- **guard**: an optional boolean expression filtering bindings (see §10)
- **template**: a fact template to assert (the "then" clause)
- **retractions**: fact templates to retract (optional)

**Syntax:**
```
RULE name
  WHEN pattern [AND pattern ...] [IF condition]
  THEN template
  [RETRACT template ...]
```

### 5.2 Rule Firing

A rule **fires** when:
1. The patterns match against alive facts, producing bindings B
2. If a guard exists, it is evaluated with B and must return `true`
3. The template is instantiated with B (expressions evaluated)
4. The instantiated template is not already an alive fact

When a rule fires:
1. The template fact is asserted with cause `"rule:NAME"` and cause_facts set to the matched facts
2. Each retraction template is instantiated with B and retracted

### 5.3 Firing Semantics

**Important:** A rule fires *at most once* per unique binding within a single derivation phase. If the same binding would fire the rule again (because the template already exists), it does not fire.

Retractions happen *after* the assertion for a given binding. This allows rules like:
```
RULE apply_damage
  WHEN ?e hp ?old AND ?e pending_damage ?dmg
  THEN ?e hp (- ?old ?dmg)
  RETRACT ?e hp ?old
  RETRACT ?e pending_damage ?dmg
```

The new HP is asserted before the old HP is retracted.

### 5.4 Aggregate Rules

A rule is an **aggregate rule** if its template contains any aggregate expression (`sum`, `count`, `max`, `min` with `WHERE`).

Aggregate rules:
- Run only in Phase 2 (after base rules reach fixpoint)
- See a stable set of facts to aggregate over
- Cannot have retractions (static error)
- Cannot be in dependency cycles with base rules

Example:
```
RULE total_equipment_bonus
  WHEN ?player is_a player
  THEN ?player total_bonus (sum ?b WHERE ?player has_bonus ?b)
```

This rule runs after all `has_bonus` facts are derived, sums them, and asserts the total.

---

## 6. Derivation and Time

### 6.1 Tick Semantics

A **tick** is one step of world evolution. Within a tick:

**N-Phase Stratification**

Rules are organized into **strata** (numbered 0, 1, 2, ...) based on their dependencies. Each stratum runs to fixpoint before the next begins. This is Datalog-style stratification.

Within each stratum:
1. For each rule in the stratum, find all valid bindings
2. For each binding, in arbitrary order:
   a. Check if the binding still matches (patterns still satisfied)
   b. If yes, execute the firing (assert template, then process retractions)
   c. If no (a prior firing invalidated it), skip this binding
3. Repeat from step 1 until no new firings occur (fixpoint)
4. Advance to next stratum

**Atomicity:** Firings are atomic per-binding. A single binding's assertion and retractions complete together. But bindings found in the same scan may be invalidated by earlier bindings in that scan. This means rule order within a scan can affect which firings occur — another reason programs must not depend on rule ordering.

**Stratum Classification:**

Rules are automatically assigned to strata based on dependencies:

- **Stratum 0**: Base rules that don't depend on aggregate/negation outputs
- **Stratum N**: Rules that aggregate/negate over stratum N-1 relations
- **Stratum N+1**: Rules that pattern on stratum N outputs (consumers of aggregates)

The key constraints are:
- **Positive dependency**: If rule R patterns on relation A and produces relation B, then stratum(B) >= stratum(A)
- **Negative dependency**: If rule R aggregates/negates over relation A and produces B, then stratum(B) > stratum(A)
- **Aggregate consumer**: If relation A is produced by an aggregate rule and rule R patterns on A, then R goes in a strictly later stratum

This enables arbitrarily deep aggregate chains:
```
# Stratum 1: Aggregate equipment bonuses
RULE calc_attack
  WHEN ?a attacking ?t
  THEN ?a total_attack (sum ?b WHERE ?a attack_bonus ?b)

# Stratum 2: Consume aggregate, can RETRACT
RULE apply_bonus
  WHEN ?a total_attack ?atk AND ?a base_damage ?base
  THEN ?a final_damage (+ ?base ?atk)
  RETRACT ?a total_attack ?atk

# Stratum 3 (if needed): Aggregate over stratum 2 outputs
RULE total_damage_dealt
  WHEN ?battle is_a battle
  THEN ?battle damage_log (sum ?d WHERE ?a final_damage ?d)
```

**After all strata:**
1. Reaction rules run on accumulated changes
2. Tick counter increments
3. Change tracking clears

### 6.2 Fixpoint

Derivation continues until a **fixpoint** is reached: no rule can fire to produce a new fact. This is guaranteed to terminate if:
- Rules only assert facts (no unbounded generation)
- Retraction removes facts that would cause re-firing

If derivation does not terminate within a limit (implementation-defined), it is an error.

### 6.3 Aggregate Rules

Aggregate rules are stratified: they run only after base rules reach fixpoint. This ensures they see a stable set of facts to aggregate over.

An aggregate expression like `(sum ?bonus WHERE ?e has_bonus ?bonus)`:
1. Evaluates the WHERE patterns as a query
2. Collects all bindings
3. Extracts the specified variable from each binding
4. Applies the aggregate function

Aggregate rules cannot be in dependency cycles with non-aggregate rules.

---

## 7. Time Travel

### 7.1 Historical Queries

A query may specify `at_tick: T` to query the world as it was at tick T. This matches only facts that were alive at that tick.

### 7.2 Provenance Queries

Given a fact, its provenance can be traced:
- `explain(s, r, o)` returns the cause and cause_facts
- Recursively following cause_facts builds a complete derivation tree

### 7.3 History Queries

Given a subject and relation, the complete history can be retrieved:
- All facts ever true for that (subject, relation) pair
- Ordered by from_tick

---

## 8. Conflict Resolution

### 8.1 No Implicit Conflicts

Because relations are multi-valued, asserting `(hero hp 50)` when `(hero hp 100)` exists does not conflict — both facts coexist.

### 8.2 Programmer-Managed Single Values

For relations that should be single-valued, the programmer must explicitly retract old values:
```
RULE update_hp
  WHEN ?e hp ?old AND ?e damage_taken ?dmg
  THEN ?e hp (- ?old ?dmg)
  RETRACT ?e hp ?old
```

### 8.3 Non-Determinism

If two rules could fire in either order and would produce different results, the behavior is **implementation-defined**. A conforming implementation may:
- Fire rules in any consistent order
- Fire rules in parallel (if they don't conflict)
- Choose arbitrarily between orderings

Programs should not depend on rule ordering. If ordering matters, use explicit sequencing through fact dependencies.

---

## 9. Notation Summary

```
# Comments start with #

# Facts
FACT subject relation object [weight: N]

# Rules
RULE name
  WHEN pattern [AND pattern ...] [IF condition]
  THEN template
  [RETRACT template ...]

# Patterns and Templates
?variable    # Matches/binds any value
atom         # Matches exactly this atom
123          # Matches exactly this number
"string"     # Matches exactly this string

# Expressions (in templates)
(+ a b)      # Arithmetic
(- a b)
(* a b)
(/ a b)
(> a b)      # Comparison
(< a b)
(= a b)
(sum ?x WHERE patterns)  # Aggregation
```

---

## 10. Guards

### 10.1 Syntax

A rule may include a **guard** after its patterns:

```
RULE name
  WHEN pattern [AND pattern ...] [IF condition]
  THEN template
  [RETRACT template ...]
```

The `condition` is an expression (§4) that must evaluate to `true` for the rule to fire.

### 10.2 Semantics

Guards filter bindings after pattern matching:

1. Pattern matching produces a set of bindings
2. For each binding B, the guard expression is evaluated with B
3. If the result is `true`, the binding proceeds to template instantiation
4. If the result is `false`, the binding is discarded
5. If the result is not a boolean, it is an error

### 10.3 Examples

```
# Only apply damage if entity is alive
RULE apply_damage
  WHEN ?e hp ?hp AND ?e pending_damage ?dmg IF (> ?hp 0)
  THEN ?e hp (- ?hp ?dmg)
  RETRACT ?e hp ?hp
  RETRACT ?e pending_damage ?dmg

# Combat only between different entities
RULE combat_proximity
  WHEN ?a location ?loc AND ?b location ?loc IF (not= ?a ?b)
  THEN ?a sees ?b

# Tax applies only above threshold
RULE apply_tax
  WHEN ?shop sale_amount ?amt IF (>= ?amt 100)
  THEN ?shop taxable true
```

### 10.4 Guards vs. Patterns

Guards complement patterns — they don't replace them. Use patterns for structural matching (which facts exist) and guards for value constraints (what relationships hold between bound values).

**Pattern** | **Guard**
------------|----------
`?e hp ?hp` (binds ?hp to whatever HP is) | `(> ?hp 0)` (filters to positive HP)
`?a location ?loc` (binds location) | `(not= ?a ?b)` (ensures different entities)

---

## 11. Negation

### 11.1 Syntax

Negation uses the `not-exists` expression in guards:

```
RULE name
  WHEN patterns
  IF (not-exists (?s ?r ?o))
  THEN template
```

The `not-exists` expression takes a pattern and succeeds if **no** alive fact matches that pattern.

### 11.2 Variable Binding

Variables in negated patterns work as follows:
- **Bound variables** (from preceding patterns) are substituted
- **Unbound variables** act as wildcards (match any value)

This allows two useful patterns:

**Specific check** (all variables bound):
```
RULE apply_tax
  WHEN ?shop in_jurisdiction ?j AND ?j tax_rate ?rate
  IF (not-exists (?shop exemption ?j))
  THEN ?shop effective_tax ?rate
```
Here `?shop` and `?j` are bound. Checks: "does this shop have an exemption for this specific jurisdiction?"

**Existential check** (some variables unbound):
```
RULE default_behavior
  WHEN ?npc is_a npc
  IF (not-exists (?npc has_quest ?any))
  THEN ?npc behavior idle
```
Here `?any` is unbound (wildcard). Checks: "does this npc have ANY quest at all?"

Negation cannot introduce new bindings to the outer query — it only tests for absence.

### 11.3 Semantics

`(not-exists (pattern))` succeeds if:
1. The pattern is ground (all variables substituted from bindings)
2. No alive fact matches the ground pattern

It fails (returns false) if any alive fact matches.

### 11.4 Stratification

Rules containing `not-exists` are evaluated in Phase 2, after base rules reach fixpoint. This ensures negated predicates have stabilized before NOT rules evaluate.

**Derivation Phases:**
1. **Phase 1 (Base):** Rules without negation/aggregation that don't depend on later phases
2. **Phase 2 (Negation + Aggregate):** Rules with `not-exists` or aggregates run over stable base (NO RETRACT)
3. **Phase 3 (Post-Aggregate):** Rules that depend on Phase 2/3 outputs (can have RETRACT)
4. **Phase 4 (Reactions):** Reaction rules run on changes
5. **Phase 5 (Advance):** Tick counter increments

*Note:* Negation and aggregate rules run in Phase 2 because both require a stable base and neither can have RETRACT. Phase 3 enables consuming aggregate results with RETRACT.

### 11.5 Restrictions

1. Rules with `not-exists` cannot have RETRACT clauses (same as aggregates)
2. `not-exists` is only valid in guard expressions, not patterns
3. All variables in the negated pattern must be bound

### 11.6 Examples

```
# Combat targeting: can't attack allies
RULE combat_targeting
  WHEN ?a is_a combatant AND ?b is_a combatant
  AND ?a location ?loc AND ?b location ?loc
  IF (not= ?a ?b)
  IF (not-exists (?a allied_with ?b))
  THEN ?a can_attack ?b

# Safe zone: no monsters present
RULE mark_safe_zone
  WHEN ?zone is_a zone
  IF (not-exists (?m location ?zone) (?m is_a monster))
  THEN ?zone status safe

# Default behavior when no override
RULE default_behavior
  WHEN ?npc is_a npc
  IF (not-exists (?npc has_quest true))
  THEN ?npc behavior idle
```

### 11.7 Design Rationale

Negation in guard expressions (rather than patterns) keeps the semantics simple:
- Guards are evaluated after all patterns match
- Guards don't introduce new bindings
- The `not-exists` is just another guard condition

This avoids the complexity of negation-as-failure in patterns while providing the common use cases: "if X doesn't exist, do Y."

---

## 12. Functional Relations

### 12.1 Syntax

A relation may be declared as **functional** (single-valued):

```
FUNCTIONAL hp
FUNCTIONAL location
FUNCTIONAL gold
```

### 12.2 Semantics

Functional relations can have at most one object per subject. When asserting a new value for a functional relation, any existing value is automatically retracted.

```
world.declare_functional("hp")
world.assert_fact("hero", "hp", 100)
world.assert_fact("hero", "hp", 80)  # Auto-retracts (hero hp 100)
```

This is equivalent to:
```
world.retract_fact("hero", "hp", 100)
world.assert_fact("hero", "hp", 80)
```

### 12.3 Use Cases

Functional relations eliminate RETRACT boilerplate for single-valued attributes:

**Without FUNCTIONAL:**
```
RULE apply_damage
  WHEN ?t pending_damage ?dmg AND ?t hp ?hp
  THEN ?t hp (- ?hp ?dmg)
  RETRACT ?t hp ?hp           # <-- Must explicitly retract old HP
  RETRACT ?t pending_damage ?dmg
```

**With FUNCTIONAL:**
```
FUNCTIONAL hp

RULE apply_damage
  WHEN ?t pending_damage ?dmg AND ?t hp ?hp
  THEN ?t hp (- ?hp ?dmg)
  RETRACT ?t pending_damage ?dmg  # Only retract the trigger
  # hp auto-retracted because it's functional
```

### 12.4 Declaration Order

Functional declarations must appear before any facts using that relation. This ensures all assertions respect the functional constraint from the start.

---

## 13. Multi-World Architecture

HERB supports multiple isolated Worlds within a Verse container. This enables process isolation (OS), player isolation (games), and other scenarios requiring separate fact stores with controlled visibility.

### 13.1 Verse

A **verse** is:
- A container for multiple Worlds
- A global tick counter
- A tree structure where each World has at most one parent

```
VERSE
  WORLD kernel              # Root World
  WORLD proc_a PARENT kernel
  WORLD proc_b PARENT kernel
```

### 13.2 World Tree

Worlds form a tree:
- **Root**: A World with no parent (exactly one per Verse)
- **Children**: Worlds that inherit from a parent
- **Siblings**: Children of the same parent (cannot see each other)

### 13.3 Inheritance

A child World **inherits** its parent's facts:
- Child queries automatically include parent facts (unless `include_inherited=false`)
- Inherited facts are **read-only**: child cannot retract parent facts
- Inheritance is transitive: grandchildren see grandparent facts

**Semantics**: When querying in a child World, the engine first searches local facts, then recursively searches parent facts.

```
WORLD game
  FACT tile_0_0 terrain grass  # Visible to all children

WORLD player_a PARENT game
  # Can query (tile_0_0 terrain ?x) -> binds x = grass
```

### 13.4 Exports

A World **exports** selected relations to its parent:
- Only exported facts are visible to the parent
- Internal facts remain hidden (true isolation)
- Export declarations are per-World

**Declaration:**
```
WORLD proc_a PARENT kernel
  EXPORTS state
  EXPORTS priority
  INTERNAL memory  # Explicitly marks as hidden (documentation)
```

**Querying exports**: Parent can query child exports via `query_child_exports(parent, child, patterns)`.

### 13.5 Messaging (inbox/SEND)

Worlds communicate through explicit messages:
- **SEND**: Parent sends to child's inbox (or child sends to parent)
- **inbox**: Messages arrive as facts that rules can pattern-match
- **No sibling messaging**: Siblings cannot message directly (must go through parent)

**Semantics**:
```
# In parent
SEND proc_a command run   # Becomes (inbox command run) in proc_a

# In child
RULE handle_run
  WHEN inbox command run
  THEN self state running
  RETRACT inbox command run
```

### 13.6 Provenance at Boundaries

Provenance is preserved but respects isolation:

- **Within World**: Full provenance chain
- **Inherited facts**: Child's derived fact can trace to parent fact (readable)
- **Exported facts**: Parent sees "exported from child" but NOT child's internal derivation
- **Messages**: Cause is "received_from:sender" without sender's reasoning

This enables answering "why is this true?" while preserving isolation. The boundary is itself a causal fact.

### 13.7 Verse Tick Semantics

`verse.tick()` advances all Worlds:

1. Root derives to fixpoint
2. Children derive to fixpoint (siblings can parallelize)
3. Recurse to grandchildren
4. Global tick increments

**Ordering guarantee**: Parent reaches fixpoint before children derive. This ensures inherited facts are stable.

### 13.8 Key Properties

| Property | Behavior |
|----------|----------|
| Parent sees child | Only exported facts |
| Child sees parent | All facts (inherited, read-only) |
| Sibling sees sibling | Nothing (full isolation) |
| Messages | Via inbox, parent-child only |
| Provenance | Traced but opaque at boundaries |

---

## 14. Deferred Rules (Micro-Iterations)

### 14.1 Motivation

HERB has fixpoint semantics: all rules run simultaneously until no new facts are derived. But some domains require **causal ordering within a single tick**. Combat is the canonical example:

```
attack -> pending_damage -> hp_update -> death_check -> loot_drop
```

Without ordering, death might be checked before damage is applied. Marker facts and cleanup rules are a workaround, but they're verbose and error-prone.

**Deferred rules** provide causal ordering within a tick via **micro-iterations**.

### 14.2 Syntax

A rule is **deferred** if its effects should happen in the next micro-iteration rather than immediately.

```herb
# Instant rule (default)
attack(?a, ?b), damage(?a, ?d) => pending_damage(?b, ?d).

# Deferred rule: effects happen in next micro-iteration
pending_damage(?e, ?d), hp(?e, ?h) =>> hp(?e, ?h - ?d), RETRACT pending_damage(?e, ?d).
```

The `=>>` arrow indicates a deferred rule.

### 14.3 Semantics

A **tick** consists of one or more **micro-iterations**:

1. **Micro-iteration 0**: Run all rules (instant and deferred) to fixpoint
   - Instant rules apply their effects immediately
   - Deferred rules **queue** their effects for the next micro-iteration
2. If deferred effects were queued:
   - Apply all queued effects (assertions and retractions)
   - Increment micro-iteration counter
   - Run all rules to fixpoint again
3. Repeat until no deferred effects are queued
4. Advance tick counter

### 14.4 Effect Queuing

When a deferred rule fires:

1. Its template facts are **queued** rather than asserted
2. Its retractions are **queued** rather than executed
3. The rule tracks what it has queued to prevent duplicate processing

Queued effects become active facts at the start of the next micro-iteration.

### 14.5 Preventing Duplicate Processing

A deferred rule with retractions must not process the same input facts multiple times. When a deferred rule queues a retraction, it records this, and subsequent matches against the same facts in the same micro-iteration are skipped.

This prevents scenarios like:
```
# Without protection:
# Micro-iter 0: hp(goblin, 30), pending_damage(goblin, 15)
# apply_damage fires, queues hp(goblin, 15), queues retract pending_damage
# apply_damage fires AGAIN (pending_damage still exists!), queues hp(goblin, 0)
# ...infinite damage
```

### 14.6 Provenance

Facts created by deferred rules have a **micro_iter** field in their provenance:

```
(goblin is_alive False)
  cause: rule:check_death
  tick: 5
  micro_iter: 2
  depends_on:
    (goblin hp 0)
      cause: rule:apply_damage
      tick: 5
      micro_iter: 1
```

This makes the causal ordering **visible structure** rather than implicit control flow.

### 14.7 Interaction with Other Features

| Feature | Interaction |
|---------|-------------|
| FUNCTIONAL | Auto-retracts still happen immediately during deferred effect application |
| EPHEMERAL | Consumed after ALL bindings processed (allows area effects) |
| Aggregation | Deferred effects become visible to aggregate queries in next micro-iter |
| Negation | Deferred effects become visible to not-exists in next micro-iter |
| Stratification | Deferred rules participate normally in stratification |

### 14.8 Limits

The implementation enforces a maximum number of micro-iterations per tick (default: 20). If this limit is exceeded, it indicates an infinite deferred chain — likely a bug in rule design.

### 14.9 Design Rationale

Deferred rules solve the "ordered effects" problem without:
- Manual marker facts and cleanup rules
- Explicit phase declarations
- Imperative sequencing

The causal structure emerges from the rules themselves. The provenance graph shows exactly how each effect led to the next.

---

## 15. Open Questions

These are not yet specified and require design decisions:

1. ~~**Functional relations**~~ — IMPLEMENTED (§12)

2. ~~**Multi-World isolation**~~ — IMPLEMENTED (§13)

3. ~~**Deferred rules (causal ordering)**~~ — IMPLEMENTED (§14)

4. **Types:** Nothing prevents `(hero hp sword)`. Should relations have type constraints? e.g., `RELATION hp : entity -> number`. Would catch errors at rule-definition time.

5. **Events:** Should there be transient facts that exist for exactly one tick?

6. **Forgetting:** What are the semantics of forgetting old facts? (windowing, weight-based)

7. **Meta-rules:** Can rules derive other rules?

8. **Static analysis:** For a language AI writes, lint tools should flag order-dependent rule sets before runtime.

9. **Negative provenance:** HERB can answer "why is this fact true?" — what if it could also answer "why isn't this fact true?" A rule matched 5 bindings, guard rejected 3 — that's explainable structure, not void. "Why isn't the goblin dead?" is as valid a question as "why is the goblin dead?" Every existing language treats "nothing happened" as silence. HERB could treat absence as a fact with navigable causes.

---

## Appendix A: Differences from Reference Implementation

The Python reference implementation (`herb_core.py`) has these known deviations:

1. **Rule ordering:** Python implementation fires rules in list order. Spec says order is implementation-defined but programs must not depend on it.

**Implemented per spec:**
- N-phase stratified derivation (§6.1) — Datalog-style stratification computes arbitrary strata
- Dependency-aware rule classification — Rules automatically assigned to strata based on pattern dependencies
- Functional relations (§12) — Single-valued relations with auto-retract
- Multi-World architecture (§13) — Verse container with inheritance, exports, messaging
- Deferred rules (§14) — Micro-iterations for causal ordering within ticks
- Iteration limits (§6.2) — max_iterations parameter prevents infinite loops
- Static validation — Aggregate/negation rules with RETRACT rejected at rule creation
- Guards (§10) — IF clause filters bindings after pattern matching
- Negation (§11) — `not-exists` expression in guards for absence checks
- Compound indices — O(1) lookup by (subject,relation), (relation,object), and exact triple
- Binding re-validation (§6.1) — Bindings invalidated by earlier firings are skipped
- Stratification diagnostics — `print_stratification()` shows rule classification
- Micro-iteration provenance — Facts track which micro-iteration created them

---

*This specification is a living document. It will be updated as the language evolves.*
