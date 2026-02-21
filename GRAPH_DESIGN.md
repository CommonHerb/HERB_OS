# HERB v2: THE GRAPH

Working through what the graph representation actually IS, using a concrete
scenario from Common Herb as the test case.

---

## THE TEST CASE

A player walks into a shop in a jurisdiction with a 10% tax rate. They buy a
sword. The shopkeeper receives gold. Tax is collected. The player's inventory
updates. Their gold decreases. If they can't afford it, the purchase fails.

In current HERB, this is ~15 rules, several FUNCTIONAL declarations, reified
purchase requests, aggregation for tax totals, negation for tax exemptions,
provenance for "why did this cost 110 gold?"

In the new model, what is it?

---

## PRIMITIVE 1: ENTITIES

Everything that EXISTS is an entity. Not "everything that has state" — everything
that the system needs to reason about.

  player_1        — a player
  shop_7          — a shop
  sword_template  — the concept of a sword
  sword_instance  — THIS specific sword
  jurisdiction_3  — a political region
  gold            — the concept of gold (a resource type)
  tax_policy_3    — the tax policy for jurisdiction_3
  purchase_event  — the event of buying

Entities don't "have properties." They participate in relations. There is no
player_1.gold = 200. There is a relation connecting player_1 to 200 through
the concept of gold.

But wait — is this just triples again? player_1 --gold--> 200?

No. Because:

### Entities are TYPED

Not "type-tagged" like an OOP class. Typed in the sense that the entity's type
constrains what relations it can participate in. A player can hold gold. A
jurisdiction cannot. A shop can contain items. A sword cannot contain items.

The type system isn't checked after the fact. It's structural: the graph itself
cannot be constructed in a way that violates types. This is closer to dependent
types than nominal types — the validity of a relation depends on the entities
it connects AND the current state of those entities.

### Entities exist at LEVELS

Level 0: concrete things (player_1, sword_instance_42)
Level 1: types/templates (player_type, sword_template)
Level 2: meta-types (entity_type, relation_type)
Level 3: the system itself (the executor, the constraint solver)

This isn't academic. It means:
- A game designer (the AI) works at Level 1, defining types and constraints
- The game runtime works at Level 0, creating instances and processing events
- The meta-system at Level 2 can modify Level 1 (changing game rules at runtime)
- Level 3 is the self-reflective layer (the system reasoning about itself)

For Common Herb: game rules live at Level 1. "Swords do damage" is Level 1.
"Player_1 has sword_42" is Level 0. "The legislature changed the tax rate" is
Level 0 modifying Level 1 — which is exactly what HERB's "rules as facts"
insight was getting at, but now it's structural.

---

## PRIMITIVE 2: RELATIONS (EDGES)

A relation connects entities. But NOT limited to binary (subject-verb-object).

A purchase connects: buyer, seller, item, price, currency, jurisdiction, time.
That's SEVEN participants. In triples, this requires reification — inventing a
fake entity (purchase_event_1) and hanging attributes off it. Reification works
but it's a workaround for a representational limitation.

In the graph: a HYPEREDGE connects any number of entities with named roles.

  purchase {
    buyer: player_1,
    seller: shop_7,
    item: sword_instance_42,
    base_price: 100,
    currency: gold,
    jurisdiction: jurisdiction_3,
    at: tick_2847
  }

This isn't a "fact" — it's a DELTA. The purchase is a change event. Before it,
the player had gold and no sword. After it, the player has a sword and less gold.

### Relations have TYPES too

  relation_type purchase {
    roles: {
      buyer: player_type,
      seller: shop_type,
      item: item_type,
      base_price: number,
      currency: resource_type,
      jurisdiction: jurisdiction_type,
      at: time
    },
    constraints: [
      buyer.holds(currency) >= final_price(base_price, jurisdiction),
      seller.inventory contains item,
      buyer != seller
    ],
    effects: [
      buyer.holds(currency) -= final_price(base_price, jurisdiction),
      seller.holds(currency) += final_price(base_price, jurisdiction),
      seller.inventory.remove(item),
      buyer.inventory.add(item),
      jurisdiction.treasury += tax(base_price, jurisdiction)
    ]
  }

Look at what just happened. The relation type defines:
- What entities participate (with type constraints)
- What must be true BEFORE it can happen (constraints/preconditions)
- What changes WHEN it happens (effects/deltas)

This is constraints + transformations in one structure. We didn't need separate
rules for "check if player can afford," "deduct gold," "add item," "collect tax."
They're all part of the same relation definition.

And provenance is automatic. "Why does player_1 have 90 gold?" → "Because of
purchase #2847, which deducted 110 gold (100 base + 10 tax in jurisdiction_3)."

---

## PRIMITIVE 3: CONSTRAINTS

Constraints are relations that must ALWAYS hold (invariants) or must hold
BEFORE something can happen (preconditions).

Types of constraints:

### Invariants — always true
  invariant: player.holds(gold) >= 0
  invariant: item.location is exactly one of [inventory, shop, ground, bank]
  invariant: jurisdiction.tax_rate in [0.0, 1.0]

### Preconditions — checked before a delta applies
  precondition for purchase: buyer.holds(currency) >= final_price(...)

### Postconditions — must be true after a delta applies
  postcondition for purchase: buyer.inventory contains item

### Conservation — things are neither created nor destroyed
  conservation: gold  -- total gold in system is constant (it moves, doesn't appear)
  conservation: items  -- items move between inventories, not duplicated

### Relationships — structural truths
  relationship: every shop is in exactly one jurisdiction
  relationship: every jurisdiction has at most one active tax_policy

Constraints serve three purposes:
1. **Validation** — reject invalid states/deltas
2. **Inference** — derive values that satisfy constraints
3. **Explanation** — "why can't I buy this?" → "because constraint X is violated"

Note: invariants subsume HERB's FUNCTIONAL relations. "hp is functional" is just
"every entity has at most one hp value" — a constraint.

---

## PRIMITIVE 4: GOALS

A goal is a desired state. The system finds a path (sequence of deltas) to
achieve it.

  goal: player_1 has sword_instance_42

The system works backward: what delta could achieve this? A purchase. What are
the preconditions? Player has enough gold, shop has the item, etc. Are they met?
If not, can we achieve THEM? (Player needs gold → can they sell something? Mine?)

This is planning. It's how pathfinding works (goal: be at location X).
It's how NPC behavior works (goal: do my job). It's how the OS works
(goal: all ready processes get CPU time fairly).

Current HERB can't express goals at all. Rules fire when patterns match —
they're reactive, not goal-directed. Adding goals gives us both:
- Reactive: "when damage happens, apply it" (rules/constraints)
- Proactive: "find a way to get to the market" (goals/planning)

### Goal decomposition

  goal: npc_farmer completes daily_routine
    subgoal: go to field
      subgoal: find path from current_location to field
        → pathfinding (A*)
    subgoal: harvest crops
      precondition: at field, has tool, crops are ready
    subgoal: go to market
    subgoal: sell crops

This is hierarchical task planning (HTN). It exists as a technique. What's new
is making it a PRIMITIVE of the language rather than something you implement
on top.

---

## PRIMITIVE 5: VIEWS

The graph is the truth. But different consumers need different perspectives.

  view player_status(p: player) {
    render: {
      name: p->name,
      hp: p->hp / p->max_hp,  -- normalized
      gold: p->holds(gold),
      location: p->location->name,
      inventory: p->inventory->items->name
    }
  }

  view .herb_syntax(w: world) {
    -- renders the graph as .herb text for human inspection
    for each entity e in w:
      for each relation r involving e:
        emit "FACT {e.id} {r.type} {r.other(e)}"
    for each constraint c in w:
      emit c as RULE syntax
  }

Views are:
- Read-only projections of the graph
- Computable (can include derived values)
- Typed (the view has a schema)
- Composable (views of views)

The current .herb file format becomes one specific view. The game UI is another
view. The admin dashboard is another. The debugger is another. All looking at
the same graph.

---

## HOW EXECUTION WORKS

This is where it gets hard. Current HERB has a clear execution model: each tick,
derive to fixpoint, advance. What replaces that?

### The execution model is RESOLUTION

The system has:
- A graph (current state)
- Pending deltas (things trying to happen)
- Active constraints (things that must remain true)
- Active goals (things trying to become true)

Resolution is:
1. Check pending deltas against preconditions
2. Apply valid deltas (updating the graph)
3. Check invariants (reject deltas that violate them)
4. Propagate constraint consequences (if delta X happened and constraint Y
   involves X, recheck Y and derive any necessary adjustments)
5. Advance goals (did any delta move us closer? are new subgoals needed?)
6. Repeat until stable (fixpoint, but over constraints + goals, not just rules)

This subsumes current HERB's tick-based derivation. A "tick" is one round of
resolution. Deferred rules become deltas queued for the next resolution round.
Stratification becomes constraint-dependency ordering. Aggregation becomes
constraint-driven summarization.

### Multiple strategies

The resolver doesn't use one algorithm for everything:
- Simple propagation for local constraints (like HERB's current rule firing)
- Arc consistency for CSP-style constraints (like layout)
- A* or BFS for pathfinding goals
- Fixpoint iteration for recursive derivation
- Priority queues for scheduling constraints

The system CHOOSES the strategy based on the structure of the subproblem.
This is the "domain-adaptive execution" from the HARD_QUESTION doc.

Is this implementable? In full generality, no — choosing optimal strategies
is itself NP-hard. But with domain annotations (this constraint is "spatial,"
this goal is "planning," this delta is "immediate"), the system has enough
information to pick reasonable strategies.

---

## THE PURCHASE, REVISITED

In the new model, buying a sword looks like:

1. Player intends to buy → creates a pending delta:
   purchase { buyer: player_1, seller: shop_7, item: sword_42, ... }

2. Resolver checks preconditions:
   - player_1.holds(gold) >= 110? Yes (player has 200)
   - shop_7.inventory contains sword_42? Yes
   - player_1 != shop_7? Yes

3. Delta applies:
   - player_1.holds(gold): 200 → 90 (delta: -110)
   - shop_7.holds(gold): 50 → 160 (delta: +110)
   - sword_42.location: shop_7.inventory → player_1.inventory
   - jurisdiction_3.treasury: 500 → 510 (delta: +10)

4. Invariants checked:
   - player_1.holds(gold) >= 0? Yes (90 >= 0)
   - sword_42 is in exactly one location? Yes (player_1.inventory)
   - Conservation of gold? 200+50+500 = 750 before, 90+160+510 = 760...

   Wait. Tax CREATED gold. That violates conservation. Unless the tax comes
   FROM the purchase price, not in addition to it.

   The constraint caught a design error. In current HERB, this bug would be
   a wrong number that you'd only find by running the demo and checking manually.
   Here, the conservation constraint catches it structurally.

   Fix: the shop receives (base_price - tax), not base_price.
   player: -110, shop: +100, treasury: +10. Total unchanged: 750 = 750. ✓

5. Provenance: every delta records which purchase event caused it,
   which constraints validated it, which preconditions were checked.

---

## WHAT THIS MEANS CONCRETELY

The primitives are:
1. **Entities** (typed, leveled)
2. **Relations/Deltas** (typed hyperedges with preconditions and effects)
3. **Constraints** (invariants, preconditions, postconditions, conservation)
4. **Goals** (desired states with decomposition into subgoals)
5. **Views** (read-only projections for different consumers)

The execution model is:
- **Resolution** — applying deltas, checking constraints, advancing goals
- **Multi-strategy** — different algorithms for different subproblem structures
- **Causal ordering** — deltas ordered by dependency, not a global clock

What HERB v1 concepts map to:
- Facts → entities + relations (at a point in time)
- Rules → delta types with preconditions and effects
- FUNCTIONAL → uniqueness constraints
- Aggregation → constraint-driven summarization
- Negation → constraint checking (absence is a violable condition)
- Provenance → inherent in delta-chain representation
- Multi-World → entity isolation boundaries (constraints on visibility)
- Ticks → resolution rounds (but not necessarily uniform)

---

## NEXT: WHAT I NEED TO FIGURE OUT

1. **The representation format** — What does the graph look like in memory?
   Not as text. As a data structure. What does the AI actually manipulate?

2. **The constraint language** — How are constraints expressed? This needs to be
   rich enough for CSS layout AND game invariants AND OS scheduling. What's
   the minimal constraint language that covers all three?

3. **The resolution algorithm** — Concretely, how does the resolver work?
   What's the actual algorithm, not just "check constraints and propagate"?

4. **Performance** — Can this be fast enough? Constraint checking on every delta
   sounds expensive. How do we make it practical?

5. **The bootstrap** — How does the first program get written? If text isn't the
   source, what is?

---

*This is design, not implementation. Nothing is code yet. But it's getting concrete.*
