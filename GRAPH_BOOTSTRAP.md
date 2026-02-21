# HERB v2: The Bootstrap Problem

If the graph IS the program and there's no source text, how do you create the
first graph?

This isn't a minor implementation detail. It's fundamental to what HERB v2 IS.

---

## THE PARADOX

To create an entity, you need to specify its type.
To specify its type, the type must exist as an entity.
To create the type entity, you need to specify ITS type.
Turtles all the way down.

Every self-describing system faces this. How do we resolve it?

---

## THE ANSWER: PRIMORDIAL STRUCTURE

Some structure exists before any program. It's not created — it just IS.

This is like how a computer has a BIOS before an OS, or how a language has
primitives before libraries. There's a minimal fixed foundation that everything
else builds on.

### The Primordial Entities

These exist in every HERB v2 graph, from the moment of creation:

```
Level 3 (System):
    SYSTEM          -- the graph itself
    RESOLVER        -- the resolution engine

Level 2 (Meta-types):
    ENTITY_TYPE     -- the type of entity types
    RELATION_TYPE   -- the type of relation types
    CONSTRAINT_TYPE -- the type of constraints
    DELTA_TYPE      -- the type of delta types
    GOAL_TYPE       -- the type of goals
    VALUE_TYPE      -- the type of value types (Int, Float, String, Bool)

Level 2 (Value types):
    INT             -- integer value type
    FLOAT           -- floating point value type
    STRING          -- string value type
    BOOL            -- boolean value type
    ENTITY_REF      -- reference to an entity
    NULL_TYPE       -- the null value type
```

These ~15 entities are hardcoded. They exist in the empty graph before the AI
does anything.

### The Primordial Relations

These relation types also exist primordially:

```
-- Type hierarchy
instance_of(entity, type)           -- entity is an instance of type
subtype_of(subtype, supertype)      -- subtype inherits from supertype

-- Naming (for human interaction)
name(entity, string)                -- human-readable name

-- Relation type structure
has_role(relation_type, role_name, type_constraint)

-- Constraint attachment
constraint_on(constraint, target)   -- what the constraint applies to

-- Temporal
created_at(entity, timestamp)
valid_from(tuple, timestamp)
valid_to(tuple, timestamp)          -- null if still valid
```

### The Primordial Constraints

A few invariants are always enforced:

```
-- Every entity has exactly one type
ForAll(e, AllEntities, Unique(t, instance_of, Eq(Role(t, "entity"), e)))

-- Type hierarchy is acyclic
-- (expressed via stratification, not a simple constraint)

-- Relation roles have valid type constraints
ForAll(r, EntitiesOfType(RELATION_TYPE),
    ForAll(role, has_role matching r,
        IsNotNull(Role(role, "type_constraint"))
    )
)
```

---

## BUILDING FROM THE FOUNDATION

The AI starts with the primordial graph and builds up.

### Step 1: Define Entity Types

```python
# AI operation: create a new entity type
player_type = graph.create_entity(
    type=ENTITY_TYPE,
    name="player"
)

shop_type = graph.create_entity(
    type=ENTITY_TYPE,
    name="shop"
)

item_type = graph.create_entity(
    type=ENTITY_TYPE,
    name="item"
)
```

### Step 2: Define Relation Types

```python
# AI operation: create a new relation type
holds_relation = graph.create_entity(type=RELATION_TYPE, name="holds")
graph.assert_tuple(has_role, {
    relation_type: holds_relation,
    role_name: "holder",
    type_constraint: player_type,
    value_type: ENTITY_REF
})
graph.assert_tuple(has_role, {
    relation_type: holds_relation,
    role_name: "resource",
    type_constraint: resource_type,
    value_type: ENTITY_REF
})
graph.assert_tuple(has_role, {
    relation_type: holds_relation,
    role_name: "amount",
    type_constraint: None,
    value_type: INT
})
```

### Step 3: Define Constraints

```python
# AI operation: create a constraint
gold_nonneg = graph.create_entity(type=CONSTRAINT_TYPE, name="gold_non_negative")
graph.set_constraint_expression(gold_nonneg,
    ForAll("p", EntitiesOfType(player_type),
        Ge(Lookup(holds_relation, {"holder": Var("p"), "resource": gold}, "amount"),
           Int(0))
    )
)
graph.set_constraint_kind(gold_nonneg, Invariant)
```

### Step 4: Create Instances

```python
# AI operation: create entities and relationships
player_1 = graph.create_entity(type=player_type, name="player_1")
gold = graph.create_entity(type=resource_type, name="gold")
graph.assert_tuple(holds_relation, {
    holder: player_1,
    resource: gold,
    amount: 200
})
```

---

## THE BOOTSTRAP API

The AI interacts with the graph through a minimal API:

```python
class Graph:
    # Entity operations
    def create_entity(self, type: EntityId, name: str = None) -> EntityId
    def delete_entity(self, entity: EntityId)

    # Tuple operations (these create Assert deltas internally)
    def assert_tuple(self, relation_type: EntityId, bindings: Dict[str, Value]) -> TupleId
    def retract_tuple(self, tuple_id: TupleId)
    def modify_tuple(self, tuple_id: TupleId, changes: Dict[str, Value])

    # Type definition helpers (convenience wrappers)
    def define_entity_type(self, name: str, parent: EntityId = None) -> EntityId
    def define_relation_type(self, name: str, roles: List[RoleDef]) -> EntityId
    def add_constraint(self, name: str, expr: ConstraintExpr, kind: ConstraintKind) -> EntityId

    # Query
    def query(self, pattern: QueryPattern) -> List[Tuple]
    def lookup(self, relation_type: EntityId, bindings: Dict[str, Value], result_role: str) -> Value
    def get_entity(self, entity_id: EntityId) -> Entity

    # Execution
    def resolve(self) -> ResolutionResult
    def tick(self, external_inputs: List[Delta] = [])

    # Provenance
    def why(self, tuple_id: TupleId) -> List[Delta]
    def why_not(self, relation_type: EntityId, bindings: Dict[str, Value]) -> Explanation
```

This API is what Claude uses to build programs. There is no parser, no compiler,
no source files. Just operations on the graph.

---

## TEXT AS A VIEW

But humans need to SEE what's in the graph. And sometimes we want to save/load
graphs to files.

Text formats are VIEWS — serializations of the graph for specific purposes:

### View 1: HERB v1 Syntax (Compatibility)

```
-- Rendered from graph, not the source
ENTITY player_type
ENTITY shop_type
ENTITY item_type

RELATION holds(holder: player, resource: resource, amount: int)

FUNCTIONAL holds ON holder, resource

INVARIANT gold_non_negative:
    FOR ALL p IN player: p.holds(gold).amount >= 0

FACT player_1 : player
FACT gold : resource
FACT holds(player_1, gold, 200)
```

This is generated FROM the graph, not parsed INTO it.

### View 2: JSON (Interchange)

```json
{
  "entities": [
    {"id": 100, "type": 10, "name": "player_type"},
    {"id": 101, "type": 10, "name": "shop_type"},
    {"id": 200, "type": 100, "name": "player_1"}
  ],
  "tuples": [
    {"id": 1001, "type": 50, "values": {"holder": 200, "resource": 300, "amount": 200}}
  ],
  "constraints": [
    {"id": 400, "name": "gold_non_negative", "kind": "invariant", "expr": {...}}
  ]
}
```

This can be loaded to reconstruct a graph. But it's still a view — the JSON is
derived from graph operations, and loading is graph operations in reverse.

### View 3: Visual (Debugging)

A node-edge diagram showing entities and their relationships. Generated for
human inspection, not for the AI.

---

## THE CREATION STORY

When HERB v2 starts:

1. **The primordial graph exists** — ~15 entities, ~10 relation types, ~5 constraints
2. **The AI receives intent** — "build a game with players, items, and purchases"
3. **The AI issues operations** — creating types, relations, constraints, entities
4. **The graph grows** — from primordial structure to full program
5. **Resolution runs** — deltas apply, constraints check, goals pursue
6. **Views render** — humans see text/visuals, the AI sees the graph

There is no separate "compile" step because there is no source language. The
graph IS the executable representation. Building the graph IS programming.

---

## IMPLICATIONS

### 1. No Syntax Errors

You can't have syntax errors because there's no syntax. You can have:
- Type errors (wrong type for a role)
- Constraint violations (invalid state)
- Missing entities (reference to non-existent ID)

But not "unexpected token on line 47."

### 2. Always Runnable

The graph is always in a runnable state (possibly invalid, but structurally
coherent). You don't need to "finish writing" before you can test.

### 3. Incremental by Nature

Adding a constraint doesn't require recompiling. It just adds an entity and
starts checking. Modifying behavior is modifying the graph.

### 4. Version Control is Deltas

Instead of diffing text files, you diff delta logs. "What changed between
version 1 and version 2?" = "What deltas were applied?"

### 5. The AI is the IDE

There's no separate IDE because the AI IS the interface. Claude looks at the
graph, decides what to add/change, issues operations. The human sees views.

---

## BOOTSTRAPPING A COMMON HERB GAME

Concretely, how would we build the Common Herb purchase scenario?

```python
# Claude builds the game

# 1. Create entity types
player_type = graph.define_entity_type("player")
shop_type = graph.define_entity_type("shop")
item_type = graph.define_entity_type("item")
resource_type = graph.define_entity_type("resource")
jurisdiction_type = graph.define_entity_type("jurisdiction")

# 2. Create relation types
holds = graph.define_relation_type("holds", [
    ("holder", ENTITY_REF, player_type),
    ("resource", ENTITY_REF, resource_type),
    ("amount", INT, None)
])

location = graph.define_relation_type("location", [
    ("entity", ENTITY_REF, item_type),
    ("place", ENTITY_REF, None)  # shop inventory, player inventory, ground, etc.
])

tax_rate = graph.define_relation_type("tax_rate", [
    ("jurisdiction", ENTITY_REF, jurisdiction_type),
    ("rate", FLOAT, None)
])

inventory = graph.define_relation_type("inventory", [
    ("owner", ENTITY_REF, None),  # player or shop
    ("inventory_id", ENTITY_REF, None)
])

# 3. Create delta types
purchase_delta = graph.define_delta_type("purchase", [
    ("buyer", ENTITY_REF, player_type),
    ("seller", ENTITY_REF, shop_type),
    ("item", ENTITY_REF, item_type),
    ("base_price", INT, None),
    ("currency", ENTITY_REF, resource_type),
    ("jurisdiction", ENTITY_REF, jurisdiction_type)
])

# 4. Add precondition
graph.add_constraint(
    "purchase_precondition",
    Ge(
        Lookup(holds, {"holder": Var("buyer"), "resource": Var("currency")}, "amount"),
        # base_price * (1 + tax_rate)
        Mul(Var("base_price"), Add(Float(1.0), Lookup(tax_rate, {"jurisdiction": Var("jurisdiction")}, "rate")))
    ),
    Precondition(purchase_delta)
)

# 5. Add delta effects
graph.set_delta_effects(purchase_delta, [
    # Buyer loses gold
    Modify(holds, {"holder": Var("buyer"), "resource": Var("currency")},
           "amount", Sub(Current("amount"), computed_price)),
    # Seller gains gold (minus tax)
    Modify(holds, {"holder": Var("seller"), "resource": Var("currency")},
           "amount", Add(Current("amount"), Sub(computed_price, tax_amount))),
    # Treasury gains tax
    Modify(holds, {"holder": Lookup(treasury, {"jurisdiction": Var("jurisdiction")}), "resource": Var("currency")},
           "amount", Add(Current("amount"), tax_amount)),
    # Item moves to buyer
    Modify(location, {"entity": Var("item")},
           "place", Lookup(inventory, {"owner": Var("buyer")}, "inventory_id"))
])

# 6. Add invariants
graph.add_constraint("gold_nonnegative",
    ForAll("p", EntitiesOfType(player_type),
        Ge(Lookup(holds, {"holder": Var("p"), "resource": gold}, "amount"), Int(0))
    ),
    Invariant
)

graph.add_constraint("gold_conservation",
    SumIs("t", TuplesOfType(holds),
        Role(Var("t"), "amount"),
        Int(INITIAL_GOLD)
    ),
    Invariant
)

# 7. Create instances
player_1 = graph.create_entity(player_type, "player_1")
shop_7 = graph.create_entity(shop_type, "shop_7")
sword_42 = graph.create_entity(item_type, "sword_42")
gold = graph.create_entity(resource_type, "gold")
jurisdiction_3 = graph.create_entity(jurisdiction_type, "jurisdiction_3")

# Initial state
graph.assert_tuple(holds, {"holder": player_1, "resource": gold, "amount": 200})
graph.assert_tuple(holds, {"holder": shop_7, "resource": gold, "amount": 50})
graph.assert_tuple(tax_rate, {"jurisdiction": jurisdiction_3, "rate": 0.10})
graph.assert_tuple(location, {"entity": sword_42, "place": shop_7_inventory})
```

This is what "writing a program" looks like in HERB v2. Claude issues these
operations. The graph builds up. Then `graph.tick()` runs the game.

---

## PERSISTENCE

Graphs need to be saved and loaded.

### Option A: Delta Log Persistence

Save the entire delta log. Loading replays all deltas to reconstruct the graph.
- Pro: Complete history preserved
- Con: Load time grows with history

### Option B: Snapshot + Recent Deltas

Save materialized state at checkpoints, plus deltas since last checkpoint.
- Pro: Fast load
- Con: Old history requires replaying from older snapshots

### Option C: Hybrid

Snapshot for current state (fast load), plus compressed delta log for history
(provenance queries).

We'll use Option C. Snapshots are JSON (View 2). Delta logs are append-only
binary for efficiency.

---

## WHAT'S NEXT

Bootstrap is specified. The AI can now build graphs from the primordial foundation.

Remaining:
1. **Implementation** — Build the Graph class in Python
2. **Validation** — Port Common Herb purchase, verify it works
3. **Views** — Implement HERB v1 syntax view for readability
4. **Performance** — Optimize for real game scale

---

*From nothing, structure. From structure, programs. From programs, worlds.*
