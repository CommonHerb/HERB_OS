# Session 18 Findings: Movement and Pathfinding

**Date:** February 4, 2026

## The Question

Can HERB express A* pathfinding as rules, or does it belong in the native layer?

A* is iterative (expand frontier, track costs, backtrack). HERB is reactive (facts trigger rules). This is HERB's first algorithmic challenge.

## What We Tried

### Approach 1: Wave Expansion (BFS as Rules)

The idea: goal emits distance 0, each tile derives distance from neighbors, movement follows decreasing distance.

**First attempt failed:** Using `not-exists` to check "tile doesn't have a distance yet" creates a negative self-dependency cycle. The rule patterns on `distance_to_goal`, produces `distance_to_goal`, and negates on `distance_to_goal` (via checking absence). Stratification correctly rejects this.

**Working solution:** Initialize ALL tiles with "infinite" distance (999999), use FUNCTIONAL auto-retract, and only improve if `neighbor_dist + 1 < current_dist`. No negation needed.

```python
world.add_derivation_rule(
    "wave_expand",
    patterns=[
        (T, "is_a", "tile"),
        (T, "distance_to_goal", D2),      # My current distance
        (T, "adjacent", ADJACENT),
        (ADJACENT, "distance_to_goal", D), # Neighbor's distance
    ],
    template=(T, "distance_to_goal", Expr('+', [D, 1])),
    guard=Expr('<', [Expr('+', [D, 1]), D2]),  # Only if improvement
    deferred=True  # Wave expands in micro-iterations
)
```

This WORKS! Distances computed correctly:
- 5x5 grid: 11ms wave expansion
- 10x10 grid: 142ms
- 20x20 grid: 1469ms ❌ (exceeds 600ms budget)

### Approach 2: Movement Following Gradient

Once distances are computed, NPCs follow the gradient:

```python
world.add_derivation_rule(
    "npc_step_toward_goal",
    patterns=[(N, "location", LOC), (LOC, "adjacent", ADJACENT), ...],
    template=(N, "location", ADJACENT),
    guard=Expr('<', [D2, D]),  # Adjacent has lower distance
    once_per_tick=True,
    once_key_vars=['n']  # One move per NPC per tick (critical!)
)
```

**Key discovery:** Without `once_key_vars=['n']`, NPCs teleport to destination. The rule fires, NPC moves, bindings change, rule fires again with new binding. The key vars fix limits firing to one move per NPC per tick.

Movement ticks are FAST: 1-2ms for 5x5, 37ms for 20x20.

### Approach 3: Native A* + HERB Movement

Compute paths in Python, inject `(npc, path_next, tile)` facts, let HERB rules handle movement.

**Results:**

| Metric | Native A* | Rule-Based BFS |
|--------|-----------|----------------|
| 5x5 grid | 0.23ms | 11ms (47x slower) |
| 20x20 grid | 2.2ms | 1469ms (669x slower) |
| 30x30 grid | 7.2ms | est. 5000ms |

**Large scale test (50x50 grid, 50 NPCs):**
- Path computation: 60ms for ALL 50 paths
- Movement ticks: 240-340ms per tick ✓

## Paradigm Boundaries Discovered

### 1. Negative Self-Dependency

Cannot use `not-exists` on a relation produced by the same rule. This is a fundamental stratification constraint, not a bug.

**Workaround:** Initialize with infinity, check for improvement instead of absence.

### 2. BFS/Dijkstra as Rules Doesn't Scale

Rule-based wave expansion is O(N × iterations) where each iteration is O(N) rule matching. This is intrinsically slower than native O(N log N) algorithms.

**Conclusion:** Pathfinding is algorithmic computation, not reactive policy. It belongs in the native layer.

### 3. once_key_vars is Essential

Without specifying which variables form the "once per tick" key, moving NPCs generate new bindings that bypass the limit. This is not a bug — it's the expected behavior — but it's a footgun.

**Rule:** Any rule that modifies part of its own pattern MUST use `once_key_vars` with the invariant parts.

## Recommended Architecture for Common Herb

```
┌─────────────────────────────────────────┐
│            HERB LAYER                    │
│  - Movement rules (validate, execute)   │
│  - Collision avoidance                   │
│  - NPC behavior (once_per_tick)          │
│  - Combat, trading, etc.                 │
└─────────────────────────────────────────┘
                    ↑
           (npc, path_next, tile)
                    ↑
┌─────────────────────────────────────────┐
│          NATIVE LAYER                    │
│  - A* pathfinding                        │
│  - PathManager tracks paths              │
│  - Computes once, injects each tick      │
└─────────────────────────────────────────┘
```

**Performance budget for 600ms tick:**
- Pathfinding: 60ms (50 NPCs, 50x50 grid)
- Movement rules: 340ms
- Combat/behavior: 200ms remaining ✓

## Files Created

- `pathfinding.py` — Rule-based wave expansion (working but slow)
- `pathfinding_native.py` — Native A* with HERB movement (recommended)

## Key Takeaways

1. **HERB CAN express pathfinding** — The paradigm is expressive enough to implement BFS as rules with the infinity-and-improvement pattern.

2. **Performance is the limiting factor** — Rule evaluation is O(N²) compared to native O(N log N). For algorithms with known efficient implementations, use native code.

3. **The boundary is clean** — Native computes WHERE to go, HERB decides IF and HOW to move. This follows the "policy vs mechanism" split from OS experiments.

4. **once_key_vars is powerful** — Combined with deferred rules, it enables complex multi-agent behaviors where each agent acts once per tick but actions can chain.

5. **FUNCTIONAL + improvement guards** replace negation for iterative algorithms. This is a general pattern worth documenting in HERB-SPEC.

## Next Steps

1. Integrate PathManager into npc_adventure.py
2. Add tests for pathfinding modules
3. Document the "infinity and improvement" pattern in HERB-SPEC
4. Consider pre-computing distance fields for static goals (towns, waypoints)
