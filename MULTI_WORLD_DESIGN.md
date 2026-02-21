# Multi-World Architecture Design

**Session 13 — February 4, 2026**

---

## The Problem

HERB has one World. All facts are visible to all rules. This is a **shared-everything** model.

```python
world.assert_fact("process_a", "secret", "password123")
world.assert_fact("process_b", "is_a", "process")

# Process B's rules can see Process A's secrets!
result = world.query(("process_a", "secret", X))
# Returns: {'x': 'password123'}
```

Isolation requires **different views of reality for different actors**. Process A's memory is invisible to Process B. Tab A's DOM is invisible to Tab B. Player A's private state is invisible to Player B (sometimes).

This isn't a missing feature. It's a structural incompatibility.

---

## The Deep Question

HERB's foundational insight: **causality is structure**. Every fact knows WHEN it became true and WHY. The provenance graph IS the program, not something reconstructed from logs.

Does this survive Multi-World?

If World A causes World B to derive a fact:
1. A sends message M
2. B receives M, rule fires
3. B asserts fact F with cause "rule:handle_message"

What's F's complete provenance? Can it trace back into A's reasoning? Should it?

**Three possible answers:**

1. **Provenance stops at boundary.** F's trace shows "received message from A" but nothing about A's internals. Isolation is preserved but causality is fragmented.

2. **Provenance crosses boundary.** F's trace includes what caused M in A. Complete causality but no isolation — B can inspect A's reasoning.

3. **Boundary records linkage, hides internals.** F's trace shows "received message M from A" and M's provenance records "sent to B from rule:send_message". You can trace causality THROUGH the boundary (A caused B) without seeing INTO the other World (how A decided). Both isolation and causality survive in weakened forms.

Option 3 feels like the right balance. It preserves the novel insight — causality as structure — while adding real isolation. The boundary is itself a causal fact.

---

## Design Requirements

From OS experiments (Session 12):

1. **True isolation** — Process A cannot pattern-match on Process B's facts. Period.
2. **Kernel visibility** — Kernel sees process metadata (pid, state, resources) without seeing internals (memory contents).
3. **IPC mechanism** — Processes can send messages to each other (via kernel or directly).
4. **Preserved provenance** — "Why did A get signal?" should trace back to sender, even across Worlds.
5. **Stratification must work** — Derivation phases can't deadlock across World boundaries.

From Common Herb:

1. **Server authority** — Server sees all state. Clients see filtered views.
2. **Shared visible state** — Terrain, buildings, NPCs are visible to all players.
3. **Private invisible state** — Player A's exact HP/mana/inventory might be private to A.
4. **Coordinated actions** — Trading requires both parties to agree; can't be unilateral.

These suggest different topology needs:
- OS: Tree (kernel at root, processes as children)
- Game: Star (server sees all, players see filtered)

The design should support both.

---

## Option 1: Hierarchical Projection Model

### Concept

Worlds form a tree. Each World has at most one parent. Children export facts to parents; parents send commands to children. No horizontal visibility between siblings.

```
Kernel World (root)
├── Process A World
├── Process B World
└── Process C World
```

### Mechanics

**Exports:** A World declares which relations are visible to its parent.

```herb
WORLD proc_123 PARENT kernel

EXPORT state      # Parent can see (self state ?s) facts
EXPORT resources  # Parent can see (self resources ?r) facts
INTERNAL memory   # Parent cannot see memory facts
```

**Projection:** Parent sees child's exported facts as if they were its own facts, prefixed by child identity.

```herb
# In kernel's world, can pattern-match on child exports:
RULE find_runnable
  WHEN ?proc WORLD_EXPORTS state ready  # Special syntax for child facts
  THEN ?proc runnable true
```

**Commands:** Parent sends commands to children via special assertion.

```herb
# In kernel
RULE preempt_process
  WHEN ?proc state running AND ?proc time_quantum_exceeded true
  SEND ?proc command preempt  # Becomes fact in child's world
```

**Provenance Across Boundary:**

When child exports fact F:
- Parent sees F with cause "exported from:proc_123"
- Parent can trace to child's export declaration, not child's internal derivation

When parent sends command C:
- Child sees C with cause "received from:kernel"
- Child cannot trace into parent's reasoning

### Advantages

- Clean tree structure matches OS hierarchy
- Explicit exports prevent accidental leakage
- Provenance preserved at boundaries (origin tracked, internals hidden)
- Stratification works: each World derives independently, exports flow upward after fixpoint

### Disadvantages

- No direct sibling communication (A can't message B without going through kernel)
- Tree is inflexible — what about peer processes sharing memory?
- What about shared libraries visible to multiple processes?

### OS Fit: Good

Kernel→process hierarchy matches Unix. IPC through kernel is standard.

### Game Fit: Mediocre

Server-as-parent works, but "shared visible state" doesn't fit cleanly. Terrain isn't a sibling — it's something all players inherit.

---

## Option 2: Shared-Nothing Channels Model

### Concept

Worlds are peers. No hierarchy. Communication only through explicit bidirectional channels. Each channel defines what fact-patterns flow in each direction.

```
     ┌─────────────┐
     │   Kernel    │
     └──────┬──────┘
      ch_a/ │ \ch_b
     ┌─────┐ ┌─────┐
     │Proc │ │Proc │
     │  A  │ │  B  │
     └──────┘ └─────┘
       ch_ab (if needed)
```

### Mechanics

**Channels:** Defined independently of Worlds.

```herb
CHANNEL kernel_to_proc_a
  FROM kernel: command, signal
  TO kernel: syscall, state_update
```

**Sending:** Explicit send into channel.

```herb
# In kernel
RULE dispatch_signal
  WHEN ?proc pending_signal ?sig
  SEND CHANNEL kernel_to_?proc signal ?sig
```

**Receiving:** Rules pattern-match on received facts.

```herb
# In proc_a
RULE handle_signal
  WHEN RECEIVED signal ?sig
  THEN ...
```

**Provenance:**

Facts received through channel have cause "received via:channel_name from:sender". Sender's internal provenance is opaque.

### Advantages

- Extremely flexible topology (arbitrary peer-to-peer)
- Channels are explicit contracts — easy to audit what crosses boundaries
- Worlds are fully independent; no implicit visibility

### Disadvantages

- Lots of boilerplate for simple hierarchies (define channel per pair)
- Shared state (like terrain) requires replication to all Worlds
- No natural "one World sees all" — server would need channels to every client
- Stratification across channels is tricky (when does a channel deliver?)

### OS Fit: Mediocre

Kernel-to-process works but requires N channels for N processes. Shared memory between processes requires complex channel semantics.

### Game Fit: Poor

Server would need separate channel to each player. Shared terrain means duplicating facts or creating a "terrain channel" that broadcasts to all.

---

## Option 3: Layered Visibility Model

### Concept

Single fact store (like now), but facts have visibility layers. A World is defined by which layers it can see. This is access control, not isolation — facts still exist globally, just filtered at query time.

```herb
LAYER kernel_internal [visible_to: kernel]
LAYER process_metadata [visible_to: kernel, processes]
LAYER shared_world [visible_to: all]
LAYER proc_a_private [visible_to: proc_a]
```

### Mechanics

**Assertion with layer:**

```herb
FACT proc_a state ready [layer: process_metadata]
FACT proc_a memory_page_0 0xDEADBEEF [layer: proc_a_private]
```

**Query filtering:**

When World X queries, only facts in layers X can see are matched.

**Derivation:**

Rules derive into a layer based on their outputs. Aggregate/negation sees only accessible layers.

### Advantages

- Minimal change to current model
- Single stratification (one fact store)
- Easy to implement
- Good for game (shared_world layer for terrain)

### Disadvantages

- **Not true isolation.** The facts EXIST, they're just hidden. A bug or escape could expose them.
- Doesn't model actual OS isolation — processes share address space conceptually.
- Visibility checking on every query (performance cost).
- Layer proliferation as system grows.

### OS Fit: Poor

This is permission checking, not process isolation. Not suitable for real OS security model.

### Game Fit: Good

Players see shared_world + their own layer. Server sees all layers. Clean.

---

## Option 4: Nested Worlds (Scoped Inheritance)

### Concept

Worlds can be nested. Inner World sees outer World's facts (inherited scope). Outer World sees only inner's exports. Like lexical scoping for facts.

```
Global World (terrain, physics constants)
├── Server World (sees Global + internal server state)
│   ├── Player A World (sees Global + own state, exports position/actions)
│   └── Player B World (sees Global + own state, exports position/actions)
└── Admin World (sees Global + everything)
```

### Mechanics

**Nesting declaration:**

```herb
WORLD player_a INHERITS global EXPORTS position, actions
```

**Inheritance:** All facts in `global` are visible in `player_a` as read-only. Can pattern-match but not retract.

**Export:** Facts matching export relations become visible to parent.

**Derivation:** Each World derives independently. Inherited facts are stable (global reaches fixpoint first, then children derive).

### Provenance

- Facts derived from inherited patterns have cause_facts pointing to global facts
- This crosses boundary but is read-only (child didn't cause global facts)
- Exported facts have child provenance; parent sees "exported from child" + child's derivation chain? Or just "exported from child"?

Key question: Does parent see child's internal provenance through exports?

**Option A: Parent sees full export provenance**
- Export includes the derivation chain
- Parent can trace why child exported that value
- Breaks isolation slightly (parent knows child's reasoning)

**Option B: Parent sees only export boundary**
- Export is a fact with cause "exported by child"
- Child's internal reasoning is opaque
- True isolation but weaker provenance

**Recommendation: Option B** — isolation is the goal. Parent can ask child for provenance if needed (via message).

### Advantages

- Inheritance handles shared visible state beautifully (global terrain)
- Exports handle "what server needs to see"
- Tree structure is flexible (can have sub-nested Worlds)
- Matches both OS and game patterns

### Disadvantages

- More complex than Options 1-3
- Derivation order matters (parent before children, or parallel with sync?)
- What happens if child and parent both have rules producing the same relation?

### OS Fit: Good

Kernel as outer World, processes as inner. Processes inherit shared libraries/system state, export metadata.

### Game Fit: Excellent

Global for terrain, nested player Worlds inherit it, export positions. Server sees all exports.

---

## Comparative Analysis

| Criterion | Option 1 (Hierarchy) | Option 2 (Channels) | Option 3 (Layers) | Option 4 (Nested) |
|-----------|---------------------|---------------------|-------------------|-------------------|
| True isolation | Yes | Yes | No | Yes |
| Shared visible state | Awkward | Replication | Natural | Natural |
| Provenance preserved | Boundary only | Boundary only | Full | Boundary only |
| OS fit | Good | Mediocre | Poor | Good |
| Game fit | Mediocre | Poor | Good | Excellent |
| Implementation complexity | Medium | High | Low | High |
| Novel | Somewhat | No (Erlang-like) | No (RBAC-like) | Yes |

**Key tradeoffs:**

- **Option 3** is simplest but doesn't solve the real problem (isolation)
- **Option 2** is most flexible but requires too much boilerplate
- **Option 1** fits OS well but struggles with shared state
- **Option 4** handles both use cases but is most complex

---

## Recommendation: Option 4 (Nested Worlds) with Elements of Option 1

### The Hybrid

Take Option 4's inheritance (child sees parent) and Option 1's explicit exports (parent sees only declared exports from child).

**Key principles:**

1. **Worlds form a tree.** Every World has at most one parent (except root).

2. **Downward inheritance.** Child automatically sees all parent facts (read-only).

3. **Upward export.** Child declares which relations are exported. Parent sees exports as child-prefixed facts.

4. **Commands as facts.** Parent sends commands via assertion to child's "inbox" relation. Child patterns on inbox.

5. **Provenance at boundaries.** Exports carry "exported from X" provenance. Parent doesn't see child's internal derivation chain.

6. **Per-World stratification.** Each World derives independently. Order: root first, then children (parallelize siblings). This ensures inherited facts are stable before children derive.

### Why This Works

**For OS:**
```
Kernel World
├── Shared Libraries World (inherited by all processes)
├── Process A World (inherits Kernel + Libs, exports state/resources)
└── Process B World (inherits Kernel + Libs, exports state/resources)
```

Process A and B both inherit shared libs. Kernel sees their exports. They can't see each other (no sibling visibility). IPC goes through kernel inbox/outbox.

**For Common Herb:**
```
Game World (terrain, items on ground, NPC positions)
├── Player A World (inherits Game, exports position/actions)
├── Player B World (inherits Game, exports position/actions)
└── Server World (inherits Game + special visibility of all exports)
```

Players inherit shared terrain. Server sees their positions. Players can't see each other's internals. Trading goes through server mediation.

### The Provenance Story

HERB's core insight survives:

1. **Within a World:** Full provenance. Every fact traces back to its causes.

2. **Across boundaries downward:** Child's fact caused by inherited parent fact has full chain (child sees into parent's causality).

3. **Across boundaries upward:** Parent sees "exported from X" and X's export declaration. Parent does NOT see X's internal derivation. Isolation preserved.

4. **Messages:** Received message has cause "received from X via inbox". Can trace to sender's outbox assertion but not sender's reasoning.

This is weaker than single-World provenance but preserves the key property: **causality is navigable structure**. You can always answer "why is this true?" The answer sometimes includes "because another World sent this" without revealing that World's internals.

---

## Notation Sketch

### World Declaration

```herb
# Root World (no parent)
WORLD kernel

# Child World with inheritance and exports
WORLD proc_123
  PARENT kernel
  INHERITS shared_libs          # Optional: inherit from sibling too?
  EXPORTS state, resources
  INTERNAL memory, registers

# Multi-level nesting
WORLD thread_001
  PARENT proc_123
  EXPORTS tid, thread_state
```

### Export/Internal Declaration

```herb
# Inside a World definition
EXPORTS state           # Parent sees (child_id state ?s)
EXPORTS resources       # Parent sees (child_id resources ?r)
INTERNAL memory         # Never visible outside
INTERNAL registers
```

### Sending Commands

```herb
# In parent (kernel)
RULE dispatch_signal
  WHEN ?proc pending_signal ?sig
  SEND ?proc signal ?sig   # Creates (inbox signal ?sig) in proc's World
  RETRACT ?proc pending_signal ?sig
```

### Receiving Commands

```herb
# In child (process)
RULE handle_signal
  WHEN inbox signal ?sig
  THEN self received_signal ?sig
  RETRACT inbox signal ?sig
```

### Pattern Matching on Child Exports

```herb
# In parent (kernel)
RULE schedule_ready
  WHEN ?child EXPORTS state ready   # Match on any child's export
  THEN ?child runnable true
```

Or with explicit child reference:

```herb
RULE check_process
  WHEN CHILD proc_123 EXPORTS state ?s
  THEN proc_123 known_state ?s
```

### Sibling Inheritance (Optional Extension)

```herb
WORLD proc_a
  PARENT kernel
  INHERITS shared_libs  # shared_libs is sibling World
  EXPORTS state
```

This allows "shared libraries" pattern — a World that multiple processes inherit from. Requires careful derivation ordering.

---

## Syntax Example: OS Scheduler

```herb
# kernel.herb

WORLD kernel

FUNCTIONAL current_process   # Only one running at a time

# Aggregate over all children's exports
RULE find_highest_priority
  WHEN ?proc EXPORTS state ready
  THEN ready_pool has ?proc

RULE select_next
  WHEN ready_pool has ?proc
  AND ?proc EXPORTS priority ?prio
  THEN scheduling candidate ?proc priority ?prio

RULE pick_winner
  WHEN scheduling candidate ?proc priority (max ?p WHERE scheduling candidate ?any priority ?p)
  THEN scheduler selected ?proc
  RETRACT scheduling candidate ?proc priority ?prio

RULE dispatch
  WHEN scheduler selected ?proc
  THEN current_process assigned_to ?proc
  SEND ?proc command run
  RETRACT scheduler selected ?proc
```

```herb
# process.herb (template for each process)

WORLD proc_$PID
  PARENT kernel
  EXPORTS state, priority
  INTERNAL memory, program_counter

FUNCTIONAL state
FUNCTIONAL priority

FACT self state ready
FACT self priority 10

RULE handle_run
  WHEN inbox command run
  THEN self state running
  RETRACT inbox command run

RULE handle_preempt
  WHEN inbox command preempt
  THEN self state ready
  RETRACT inbox command preempt
```

---

## Syntax Example: Common Herb Game

```herb
# game_world.herb

WORLD game

# Terrain is in root World — visible to all children
FACT tile_0_0 terrain grass
FACT tile_1_0 terrain forest
FACT town_center is_a building
FACT town_center location tile_5_5
```

```herb
# player.herb (template)

WORLD player_$ID
  PARENT game
  EXPORTS position, action, visible_state
  INTERNAL hp, mana, inventory, quest_progress

FUNCTIONAL hp
FUNCTIONAL mana
FUNCTIONAL position

# Player sees terrain from game World (inherited)
# Player sees their own hp, mana, etc.
# Server sees position (exported)

RULE move_requested
  WHEN inbox movement_request ?dir
  AND self position ?current
  THEN self position (move ?current ?dir)   # Assuming move function
  RETRACT inbox movement_request ?dir

RULE export_position
  WHEN self position ?pos
  THEN visible_state position ?pos  # Automatically exported
```

```herb
# server.herb

WORLD server
  PARENT game
  # Server has special privilege: sees all children's exports

RULE broadcast_positions
  WHEN ?player EXPORTS visible_state position ?pos
  THEN world_state has_player ?player at ?pos

RULE handle_trade
  WHEN ?p1 EXPORTS action trade_request ?p2 ?item
  AND ?p2 EXPORTS action trade_accept ?p1 ?item
  THEN trade_completed between ?p1 ?p2 for ?item
  SEND ?p1 trade_result success ?item
  SEND ?p2 trade_result success ?item
```

---

## Implementation Impact

### Changes to herb_core.py

**New classes:**

```python
class Verse:
    """Container for multiple Worlds with parent-child relationships."""

    def __init__(self):
        self.worlds: dict[str, World] = {}
        self.parent_of: dict[str, str] = {}  # child -> parent
        self.children_of: dict[str, list[str]] = {}  # parent -> [children]

    def create_world(self, name: str, parent: str = None) -> World:
        """Create a new World, optionally as child of parent."""
        ...

    def tick(self):
        """Advance all Worlds. Order: root first, then children."""
        ...

class World:
    # Existing fields...

    # New fields
    parent: 'World' = None
    exports: set[str] = set()  # Exported relations
    internals: set[str] = set()  # Explicitly internal relations
    inbox: list[tuple] = []  # Received messages
```

**Modified methods:**

```python
def query(self, pattern, *, at_tick=None, include_inherited=True):
    """Query facts. If include_inherited, also search parent's facts."""
    results = self._query_local(pattern, at_tick)
    if include_inherited and self.parent:
        results.extend(self.parent.query(pattern, at_tick=at_tick))
    return results

def get_child_exports(self, child_name: str):
    """Get exported facts from a child World."""
    child = self.verse.worlds[child_name]
    return [f for f in child.alive_facts() if f.relation in child.exports]
```

**Derivation changes:**

```python
def derive(self):
    """Run derivation. For child Worlds, inherited facts are read-only."""
    # Can pattern-match on parent facts
    # Cannot retract parent facts
    # Exports become visible to parent after derivation
    ...
```

### New syntax in herb_lang.py

```python
# Parse WORLD declarations
# Parse PARENT, EXPORTS, INTERNAL declarations
# Parse SEND commands
# Parse CHILD/EXPORTS pattern matching
# Parse inbox patterns
```

### Stratification across Worlds

Each World stratifies independently. The Verse-level tick:

1. Root World derives to fixpoint
2. Root's derivation may include SEND commands
3. Messages delivered to children's inboxes
4. Children derive to fixpoint (can parallelize siblings)
5. Children's exports collected
6. Root can see new exports on next tick

This is effectively a two-phase per-tick: derive, then communicate.

---

## Open Questions

### 1. Can children send to each other directly?

Current proposal: No. All IPC goes through parent (like Unix kernel mediation).

Alternative: Allow direct channels between sibling Worlds. Adds complexity.

Recommendation: Start with parent-mediated. Add direct channels later if needed.

### 2. What happens to FUNCTIONAL across inheritance?

If parent declares `FUNCTIONAL location` and child inherits it, does the child respect that constraint?

Recommendation: Yes. Inherited FUNCTIONAL declarations apply to inherited facts. Child can also declare its own FUNCTIONAL relations for its internal facts.

### 3. Can a fact exist in multiple Worlds?

Current proposal: No. Facts live in exactly one World. Child sees parent's facts through inheritance (read-only view), not copies.

Alternative: Allow fact replication with sync. Much more complex.

Recommendation: No replication. Single authoritative location per fact.

### 4. How does time work?

Does each World have its own tick counter? Or one global tick?

Recommendation: One global tick managed by Verse. All Worlds see the same tick value. Derivation happens per-World but synchronized at tick boundaries.

### 5. What if derivation in one World depends on another's exports?

Example: Kernel rule patterns on process exports, which are derived at same tick.

Solution: Two-phase tick: (1) all Worlds derive to fixpoint, (2) exports become visible. Rules that need exports run on NEXT tick's export values.

This matches the "stable base for aggregation" principle — you aggregate over the PREVIOUS tick's state, not the evolving current state.

---

## Summary

**Recommendation:** Nested Worlds with parent-child inheritance and explicit exports.

**Key properties:**
- True isolation (children can't see siblings)
- Shared visible state through inheritance (children see parent)
- Explicit exports (parent sees declared child facts)
- Provenance preserved at boundaries (traceable but opaque)
- Fits both OS (kernel/process) and game (server/player) patterns

**What makes it HERB:**
- Causality remains structure, not reconstruction
- Facts still have temporal extent and provenance
- Rules still derive facts from patterns
- Just with scoped visibility instead of global visibility

**The insight survives:** Splitting the universe into isolated regions doesn't break the fundamental idea that state and causality are the same thing. Each World is a complete causal domain. Boundaries are explicit causal events (messages, exports) that link domains without exposing internals.

---

## Next Steps

1. **Prototype Verse class** — Minimal implementation with World creation and parent-child linking
2. **Implement inheritance** — Child queries search parent facts
3. **Implement exports** — Parent can query child exports
4. **Implement inbox/SEND** — Message passing across boundaries
5. **Test with OS scheduler** — Verify isolation works
6. **Test with game scenario** — Verify inheritance works

Do NOT implement everything at once. Start with inheritance (read-only parent visibility), verify it works, then add exports, then messages.

---

*This document captures design reasoning. Implementation comes next session (or later). The design may evolve as we prototype.*
