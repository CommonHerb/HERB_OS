# Session 17 Findings: once_per_tick Stress Test

**Date:** February 4, 2026

## The Experiment

Stress-test `once_per_tick` against move+act composition:
- Guard starts in town (no hostiles)
- Guard has a DEFERRED move rule (fires at micro-iter 0, effect at micro-iter 1)
- Guard has an attack rule (once_per_tick) that should fire in micro-iter 1+
- Question: Does the guard get exactly ONE attack in the new room?

## What Worked

**Everything worked correctly on first try.**

The `_fired_this_tick` set persists across all micro-iterations within a tick. This is exactly the right behavior:

1. **Tick 1, Micro-iter 0:** guard_moves fires (deferred), queues move to forest
2. **Tick 1, Micro-iter 1:** Move effect applied. guard_attacks sees goblin, fires once. `_fired_this_tick` now contains `('guard_attacks', ('goblin',))`
3. **Tick 1, Micro-iter 2+:** Damage processed. `_fired_this_tick` prevents re-attack.
4. **Tick 2 start:** `_fired_this_tick` cleared. Guard can attack again.

The key insight: `_fired_this_tick` is:
- **Cleared at the START of each tick** (line 1326 in herb_core.py: `self._fired_this_tick = set()`)
- **Persists across all micro-iterations** (never cleared during micro-iteration loop)
- **Checked on every binding** before firing

## Test Results

7 move+act composition tests pass:
- `test_deferred_move_then_attack` — Core scenario
- `test_deferred_move_no_infinite_attacks` — Survival doesn't cause infinite attacks
- `test_move_and_attack_same_tick` — Both actions in one tick
- `test_once_per_tick_resets_between_ticks` — Tick boundary reset
- `test_multiple_targets_same_tick` — Key vars allow multiple different targets
- `test_no_key_vars_all_bindings` — Without key_vars, all bindings form key
- `test_full_combat_chain` — Full damage→death→loot with once_per_tick

13 once_per_tick unit tests pass (new test file):
- Basic functionality (fires once, resets between ticks)
- Key var selection (subset, none, empty)
- Micro-iteration boundary (tracking persists, deferred chains)
- Multi-agent scenarios (multiple attackers, different bindings)
- Edge cases (guards, empty keys, retractions)

## Key Discovery: Behavior of once_key_vars

| once_key_vars | Behavior |
|---------------|----------|
| `None` (not specified) | All pattern variables form the key. Each unique binding fires once. |
| `['e']` | Only variable 'e' forms the key. Same attacker can hit multiple targets (different 'e' values). |
| `['a', 'e']` | Attacker+target pair forms key. Multiple attackers can each hit multiple targets. |
| `[]` (empty list) | No variables in key. Rule fires exactly ONCE per tick, regardless of bindings. |

This provides fine-grained control:
- `once_per_tick=True` with no key_vars: One action per unique situation
- `once_per_tick=True, once_key_vars=['agent']`: One action per agent
- `once_per_tick=True, once_key_vars=[]`: One action total per tick

## Why This Matters

The `once_per_tick` primitive solves the fundamental tension between:
1. **Fixpoint derivation** — Rules fire until no new facts can be derived (monotonic convergence)
2. **Agent actions** — Each agent should perform at most one action per turn (action budgets)

Without `once_per_tick`, agent rules that don't disable their own preconditions (e.g., attacking a target that survives) would fire infinitely within a tick.

With `once_per_tick`, the engine enforces the "one action per turn" constraint at the rule level, without requiring marker facts, cleanup rules, or other scaffolding.

## Architecture Validation

The implementation is clean:
- **No changes needed** — The existing implementation handles micro-iteration correctly
- **No special cases** — The fired set persists naturally across micro-iterations
- **No performance impact** — Set lookup is O(1)

The `once_per_tick` + `deferred` combination enables complex multi-phase action resolution:
1. Planning phase (micro-iter 0): All agents decide their actions
2. Resolution phase (micro-iter 1+): Effects apply in causal order
3. Tracking persists: No agent acts twice, even across phases

## Tests Created

**`test_move_act.py`** — 7 tests for move+act composition
**`test_once_per_tick.py`** — 13 comprehensive unit tests

Total test count: 57 tests across all files (was 37 before this session).

## Conclusion

The `once_per_tick` primitive works correctly across micro-iteration boundaries. No fixes needed — the design was right from the start. The clean primitive beats rule-level hacks.

---

*Session 17 validates that `once_per_tick` composes correctly with deferred rules. The semantics are stable and ready for more pressure.*
