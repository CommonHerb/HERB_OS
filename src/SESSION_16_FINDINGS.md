# Session 16 Findings: Multi-Agent Action Gap

**Date:** February 4, 2026

## The Experiment

Add 3-4 autonomous NPCs to the combat live loop. Test whether FUNCTIONAL + EPHEMERAL + deferred rules compose under multi-agent load.

## What Happened

The NPCs immediately exposed a fundamental gap in HERB's execution model. Every tick entered an infinite micro-iteration loop because:

1. Guard sees hostile → Guard attacks (creates pending_damage)
2. pending_damage consumed → HP updated
3. Hostile still alive → Guard attacks again
4. GOTO 1

## Why Patches Failed

Every workaround attempted the same thing: prevent a rule from firing more than once per tick. Every one failed:

| Approach | Why It Failed |
|----------|---------------|
| **Ephemeral tick_trigger** | Consumed by first rule that matches; other rules don't see it |
| **Not-exists guard** | Rule produces X and negates X → stratification rejects as negative cycle |
| **Marker facts + cleanup** | Markers get retracted, letting rule fire again; cleanup is manual/verbose |
| **"hits" relation** | If consumed, attacker can hit again; if persisted, rule keeps firing |

The core issue: **Datalog fixpoint derivation is monotonic.** It converges when no new facts can be derived. But agent actions are non-monotonic — they change the world in ways that re-enable their own preconditions. The attack succeeds, the target survives, and the attack conditions are still true.

## The Gap

HERB has no primitive for: "this rule should fire at most once per tick per binding."

Current tools:
- **FUNCTIONAL** — single value per subject (doesn't help with action limiting)
- **EPHEMERAL** — consumed after first rule matches (too coarse, affects all rules)
- **Deferred** — delays effects to next micro-iter (doesn't prevent re-firing)
- **Not-exists** — stratification prevents self-referential use

None of these express "I, this specific rule, with this specific binding, should not fire again this tick."

## The Solution: ONCE PER TICK

Add a rule modifier that the engine enforces:

```herb
RULE guard_attacks ONCE PER TICK
  WHEN guard location ?loc, hostile location ?loc, hostile is_alive true
  THEN guard hits hostile
```

### Semantics

The engine maintains a set of `(rule_name, binding_key)` pairs that have fired this tick. When a rule marked `ONCE PER TICK` finds a binding:

1. Compute binding_key from the bound variables
2. Check if `(rule_name, binding_key)` is in the fired set
3. If yes, skip this binding
4. If no, fire the rule and add to fired set
5. Clear fired set at end of tick

### Why This Works

- **Declarative** — Rule says WHAT should happen, engine handles WHEN
- **No negative cycles** — Engine constraint, not a derived fact
- **Precise** — Per-rule, per-binding; doesn't affect other rules
- **Matches game semantics** — One action per agent per turn

### Binding Key Design

The binding_key should include variables that identify "this is the same action":
- For attacks: `(attacker, target)` — guard can attack goblin once and wolf once
- For movement: `(mover)` — guard moves once per tick
- For trade offers: `(merchant, customer)` — one offer per pair per tick

Could be explicit (`ONCE PER TICK KEY ?attacker ?target`) or inferred from pattern variables.

## Implementation Notes

In `herb_core.py`:

```python
@dataclass
class DerivationRule:
    name: str
    patterns: list[tuple]
    templates: list[tuple]
    # ...existing fields...
    once_per_tick: bool = False  # NEW
    once_key_vars: list[str] = None  # Variables to include in binding key

class World:
    def __init__(self, ...):
        # ...existing...
        self._fired_this_tick: set[tuple] = set()  # (rule_name, binding_key)

    def advance(self, ...):
        self._fired_this_tick = set()  # Clear at start of tick
        # ...derivation loop...

    # In rule application:
    # if rule.once_per_tick:
    #     key = (rule.name, tuple(bindings[v] for v in rule.once_key_vars))
    #     if key in world._fired_this_tick:
    #         continue
    #     world._fired_this_tick.add(key)
```

## Broader Implications

This isn't just about NPCs. The same issue affects any system where:
- Multiple agents act autonomously
- Actions have effects that don't disable their preconditions
- Turn-based semantics require "one action per turn"

Examples:
- **Combat**: Each combatant attacks once per tick
- **Movement**: Each entity moves once per tick
- **Economy**: Each merchant makes one trade per tick
- **Politics**: Each citizen casts one vote per election

The `ONCE PER TICK` primitive is fundamental to modeling agent behavior in HERB.

## What We Learned

1. **Fixpoint derivation ≠ agent simulation.** HERB's core model assumes monotonic convergence. Agent actions are inherently non-monotonic.

2. **Engine-level primitives beat rule-level hacks.** Markers, guards, and clever fact structures can't cleanly express "fire once" because they're derived facts subject to the same derivation rules.

3. **The pain point was the deliverable.** The session's goal was to "find where it breaks." It broke immediately, clearly, and instructively. The NPCs succeeded as a diagnostic tool.

## Next Steps

1. Implement `ONCE PER TICK` in herb_core.py
2. Add syntax support in herb_lang.py
3. Add §15 to HERB-SPEC.md documenting the semantics
4. Revisit NPC demo with the new primitive
5. Consider if other "once per X" variants are needed (ONCE PER MICRO_ITER?)

---

*This finding changes how we think about HERB's execution model. Fixpoint derivation works for deriving facts from facts. For deriving actions from states, we need action budgets.*
