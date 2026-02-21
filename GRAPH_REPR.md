# HERB v2: The Graph Representation

Working through what the graph looks like IN MEMORY. Not as text. As data structures
that the AI manipulates directly.

---

## THE CORE INSIGHT

The representation must support ONE fundamental operation: **applying a delta and
checking if the result is valid**.

Everything else — queries, views, provenance — is derived from this. If we get delta
application right, we get everything.

---

## WHAT WE'RE REPRESENTING

Five things:
1. **Entities** — things that exist
2. **Relations** — connections between entities (including current state)
3. **Deltas** — changes (the primitive; relations are derived by applying deltas)
4. **Constraints** — what must be true
5. **Goals** — what we want to become true

Let's build up from the bottom.

---

## PRIMITIVE 1: VALUES

Before entities, we need values. These are the atoms:

```
Value =
  | Int(i64)
  | Float(f64)
  | String(str)
  | Bool(bool)
  | EntityRef(entity_id)
  | Null
```

That's it. No complex nested structures. If you need a list, that's a relation.
If you need a map, that's a set of relations.

Why so minimal? Because constraints need to reason about values, and the simpler
the value domain, the more tractable constraint solving becomes.

---

## PRIMITIVE 2: ENTITIES

An entity is just an ID with a type:

```
Entity {
  id: u64,           # unique, immutable, assigned by system
  type_id: u64,      # reference to an EntityType (which is also an entity!)
  level: u8          # 0=instance, 1=type, 2=meta-type, 3=system
}
```

That's all. An entity doesn't "have" properties. It participates in relations.

The ID is opaque. The AI refers to entities by their IDs, not by names. Names are
just relations: `name(entity_42, "player_1")`.

### Entity Levels

Level 0: Concrete instances
  - player_42 (a specific player)
  - sword_17 (a specific sword)
  - purchase_2847 (a specific purchase event)

Level 1: Types
  - player_type (the concept of a player)
  - sword_type (the concept of a sword)
  - purchase_type (the concept of a purchase)

Level 2: Meta-types
  - entity_type (the concept of an entity type)
  - relation_type (the concept of a relation type)
  - constraint_type (the concept of a constraint)

Level 3: System
  - the_graph (the graph itself, for self-reference)
  - the_resolver (the execution engine)

The `type_id` of a Level-N entity points to a Level-(N+1) entity.
The Level-3 entities are their own types (self-referential).

---

## PRIMITIVE 3: RELATION TYPES

A relation type defines a kind of connection between entities:

```
RelationType {
  id: u64,                          # this is an entity at Level 2
  name: String,                     # human-readable name
  roles: Vec<(String, TypeConstraint)>,  # named slots with type constraints
  arity: u8                         # number of roles (cached from roles.len())
}

TypeConstraint {
  required_type: Option<u64>,       # must be instance of this type (or subtype)
  required_level: Option<u8>,       # must be at this level
  value_type: Option<ValueType>     # for non-entity slots: Int, Float, String, Bool
}
```

Example relation types:

```
holds: RelationType {
  name: "holds",
  roles: [
    ("holder", TypeConstraint { required_type: Some(entity_type), ... }),
    ("resource", TypeConstraint { required_type: Some(resource_type), ... }),
    ("amount", TypeConstraint { value_type: Some(Int), ... })
  ]
}

location: RelationType {
  name: "location",
  roles: [
    ("entity", TypeConstraint { required_type: Some(entity_type), ... }),
    ("place", TypeConstraint { required_type: Some(location_type), ... })
  ]
}

purchase: RelationType {
  name: "purchase",
  roles: [
    ("buyer", TypeConstraint { required_type: Some(player_type), ... }),
    ("seller", TypeConstraint { required_type: Some(shop_type), ... }),
    ("item", TypeConstraint { required_type: Some(item_type), ... }),
    ("base_price", TypeConstraint { value_type: Some(Int), ... }),
    ("currency", TypeConstraint { required_type: Some(resource_type), ... }),
    ("jurisdiction", TypeConstraint { required_type: Some(jurisdiction_type), ... }),
    ("at", TypeConstraint { value_type: Some(Int), ... })  # timestamp
  ]
}
```

Note: relation types are themselves entities (at Level 2). This means we can have
relations ABOUT relation types. Meta-programming is just more relations.

---

## PRIMITIVE 4: RELATION INSTANCES (TUPLES)

A relation instance is a specific connection:

```
Tuple {
  id: u64,              # unique identifier for this tuple
  type_id: u64,         # which RelationType
  values: Vec<Value>    # one value per role, in role order
}
```

Example tuples:

```
# player_1 holds 200 gold
Tuple {
  id: 1001,
  type_id: holds.id,
  values: [EntityRef(player_1.id), EntityRef(gold.id), Int(200)]
}

# sword_42 is located in shop_7's inventory
Tuple {
  id: 1002,
  type_id: location.id,
  values: [EntityRef(sword_42.id), EntityRef(shop_7_inventory.id)]
}
```

**IMPORTANT**: These tuples represent the CURRENT STATE of the graph. But state is
derived from deltas. We need to distinguish:

- **Base tuples**: The current derived state (materialized for fast query)
- **Delta tuples**: Changes that have occurred (the source of truth)

---

## PRIMITIVE 5: DELTAS

A delta is a change. It's the actual primitive — base tuples are derived by
replaying deltas.

```
Delta {
  id: u64,                    # unique identifier
  delta_type: DeltaKind,      # what kind of change
  tuple: Tuple,               # the tuple being added/removed/modified
  timestamp: Timestamp,       # causal position
  provenance: Provenance      # why this delta happened
}

DeltaKind {
  Assert,                     # add this tuple
  Retract,                    # remove this tuple
  Modify {                    # change specific values in a tuple
    old_values: Vec<Value>,
    new_values: Vec<Value>,
    changed_indices: Vec<u8>
  }
}

Timestamp {
  tick: u64,                  # logical time (tick number)
  micro: u32,                 # sub-tick ordering (for deferred effects)
  causal_deps: Vec<u64>       # IDs of deltas this depends on
}

Provenance {
  cause: ProvCause,
  rule_id: Option<u64>,       # if caused by a rule
  goal_id: Option<u64>,       # if caused by goal pursuit
  constraint_id: Option<u64>  # if caused by constraint maintenance
}

ProvCause {
  External,                   # player input, sensor data, etc.
  Derived,                    # rule/constraint application
  GoalPursuit,                # working toward a goal
  Initialization             # initial state setup
}
```

The delta log is the source of truth. Base tuples are a materialized view that
can be reconstructed by replaying deltas.

---

## PRIMITIVE 6: CONSTRAINTS

A constraint is a condition that must hold. Constraints are also entities
(at Level 1, defining what's valid at Level 0).

```
Constraint {
  id: u64,                    # entity ID
  name: String,
  kind: ConstraintKind,
  expression: ConstraintExpr,
  scope: ConstraintScope
}

ConstraintKind {
  Invariant,                  # always true
  Precondition { delta_type: u64 },   # must be true before this delta type
  Postcondition { delta_type: u64 },  # must be true after this delta type
  Conservation { resource: u64 }       # this resource is neither created nor destroyed
}

ConstraintScope {
  Global,                     # applies everywhere
  TypeScoped { type_id: u64 }, # applies to instances of this type
  EntityScoped { entity_id: u64 }  # applies to this specific entity
}
```

### The Constraint Expression Language

This is the hard part. We need a language that's:
- Expressive enough for games, OS, and browser constraints
- Decidable (we can always determine if it's satisfied)
- Efficient to check (incrementally, on each delta)

```
ConstraintExpr =
  # Comparisons
  | Eq(Expr, Expr)
  | Ne(Expr, Expr)
  | Lt(Expr, Expr)
  | Le(Expr, Expr)
  | Gt(Expr, Expr)
  | Ge(Expr, Expr)

  # Logical
  | And(ConstraintExpr, ConstraintExpr)
  | Or(ConstraintExpr, ConstraintExpr)
  | Not(ConstraintExpr)
  | Implies(ConstraintExpr, ConstraintExpr)

  # Quantifiers (over finite domains only!)
  | ForAll(var: String, domain: Domain, body: ConstraintExpr)
  | Exists(var: String, domain: Domain, body: ConstraintExpr)
  | Unique(var: String, domain: Domain, body: ConstraintExpr)  # exactly one
  | AtMostOne(var: String, domain: Domain, body: ConstraintExpr)

  # Aggregates (for conservation laws, etc.)
  | SumEq(var: String, domain: Domain, value_expr: Expr, sum_value: Expr)
  | CountEq(var: String, domain: Domain, filter: ConstraintExpr, count: Expr)

Expr =
  | Literal(Value)
  | Var(String)                           # bound variable from quantifier
  | RoleAccess(tuple_var: String, role: String)  # t.buyer, t.amount
  | Lookup(relation: u64, key_roles: Vec<(String, Expr)>, result_role: String)
  | Arith(op: ArithOp, Expr, Expr)
  | Neg(Expr)
  | IfThenElse(ConstraintExpr, Expr, Expr)

Domain =
  | AllEntitiesOfType(type_id: u64)
  | AllTuplesOfType(relation_type_id: u64)
  | Explicit(Vec<Value>)

ArithOp = Add | Sub | Mul | Div | Mod
```

### Example Constraints

**Non-negative gold:**
```
ForAll(p, AllEntitiesOfType(player_type),
  Ge(Lookup(holds, [("holder", Var(p)), ("resource", gold)], "amount"),
     Literal(Int(0))))
```
English: For all players p, the amount in holds(p, gold, ?) >= 0.

**Item in exactly one location:**
```
ForAll(i, AllEntitiesOfType(item_type),
  Unique(t, AllTuplesOfType(location),
    Eq(RoleAccess(t, "entity"), Var(i))))
```
English: For all items i, there is exactly one location tuple with entity=i.

**Conservation of gold:**
```
SumEq(t, AllTuplesOfType(holds),
  RoleAccess(t, "amount"),
  Literal(Int(INITIAL_TOTAL_GOLD)))
```
English: The sum of all amounts in holds tuples equals the initial total.

(Note: this is simplified. Real conservation needs to track treasury, banks, etc.
The point is that conservation IS expressible.)

---

## PRIMITIVE 7: GOALS

A goal is a desired state. Goals are entities (at Level 0, representing active
intentions).

```
Goal {
  id: u64,
  owner: Option<u64>,         # entity pursuing this goal (player, NPC, system)
  target: ConstraintExpr,     # what must become true
  priority: i32,              # for ordering when resources are scarce
  deadline: Option<Timestamp>,
  status: GoalStatus,
  decomposition: Option<GoalDecomposition>
}

GoalStatus {
  Active,
  Achieved,
  Failed { reason: String },
  Suspended
}

GoalDecomposition {
  strategy: DecompStrategy,
  subgoals: Vec<u64>          # IDs of subgoal entities
}

DecompStrategy {
  Sequential,                 # achieve subgoals in order
  Parallel,                   # achieve subgoals in any order
  Alternative                 # achieve any one subgoal
}
```

Goals use the same ConstraintExpr language as constraints. The difference:
- Constraints: "this MUST be true, reject deltas that violate it"
- Goals: "this SHOULD become true, find deltas that achieve it"

---

## THE GRAPH ITSELF

Putting it all together:

```
Graph {
  # Entity storage
  entities: HashMap<u64, Entity>,
  next_entity_id: u64,

  # Type system (entities at Level 1+)
  entity_types: HashMap<u64, EntityType>,
  relation_types: HashMap<u64, RelationType>,

  # Current state (materialized view)
  tuples: HashMap<u64, Tuple>,

  # Indices for fast lookup
  tuples_by_type: HashMap<u64, HashSet<u64>>,              # relation_type -> tuple_ids
  tuples_by_entity: HashMap<u64, HashSet<u64>>,            # entity_id -> tuple_ids involving it
  tuples_by_role: HashMap<(u64, u8, Value), HashSet<u64>>, # (rel_type, role_idx, value) -> tuple_ids

  # Delta log (source of truth)
  deltas: Vec<Delta>,
  current_tick: u64,
  current_micro: u32,

  # Constraints
  constraints: HashMap<u64, Constraint>,
  invariants: Vec<u64>,                    # IDs of invariant constraints (checked always)
  preconditions: HashMap<u64, Vec<u64>>,   # delta_type -> constraint IDs
  postconditions: HashMap<u64, Vec<u64>>,

  # Goals
  goals: HashMap<u64, Goal>,
  active_goals: Vec<u64>
}
```

---

## KEY OPERATIONS

### 1. Apply Delta

The fundamental operation:

```
fn apply_delta(graph: &mut Graph, delta: Delta) -> Result<(), ConstraintViolation> {
    // 1. Type-check the tuple
    type_check(&delta.tuple, &graph.relation_types)?;

    // 2. Check preconditions (if any for this delta type)
    if let Some(preconds) = graph.preconditions.get(&delta.tuple.type_id) {
        for constraint_id in preconds {
            check_constraint(graph, *constraint_id, Some(&delta))?;
        }
    }

    // 3. Apply the change
    match delta.delta_type {
        Assert => {
            graph.tuples.insert(delta.tuple.id, delta.tuple.clone());
            update_indices(graph, &delta.tuple, true);
        }
        Retract => {
            graph.tuples.remove(&delta.tuple.id);
            update_indices(graph, &delta.tuple, false);
        }
        Modify { ref changed_indices, ref new_values, .. } => {
            // Update specific values
            let tuple = graph.tuples.get_mut(&delta.tuple.id).unwrap();
            for (i, &idx) in changed_indices.iter().enumerate() {
                tuple.values[idx as usize] = new_values[i].clone();
            }
            // Reindex
            reindex_tuple(graph, &delta.tuple);
        }
    }

    // 4. Check postconditions
    if let Some(postconds) = graph.postconditions.get(&delta.tuple.type_id) {
        for constraint_id in postconds {
            check_constraint(graph, *constraint_id, Some(&delta))?;
        }
    }

    // 5. Check affected invariants (incrementally, only constraints involving touched entities)
    let affected = get_affected_constraints(graph, &delta);
    for constraint_id in affected {
        check_constraint(graph, constraint_id, None)?;
    }

    // 6. Record delta
    graph.deltas.push(delta);

    Ok(())
}
```

### 2. Query Current State

```
fn query(graph: &Graph, pattern: QueryPattern) -> Vec<Tuple> {
    // Use indices to find matching tuples
    match pattern {
        ByType(type_id) => {
            graph.tuples_by_type.get(&type_id)
                .map(|ids| ids.iter().map(|id| graph.tuples[id].clone()).collect())
                .unwrap_or_default()
        }
        ByEntityInRole(entity_id, type_id, role_idx) => {
            let key = (type_id, role_idx, EntityRef(entity_id));
            graph.tuples_by_role.get(&key)
                .map(|ids| ids.iter().map(|id| graph.tuples[id].clone()).collect())
                .unwrap_or_default()
        }
        // ... other patterns
    }
}
```

### 3. Check Constraint

```
fn check_constraint(graph: &Graph, constraint_id: u64, trigger: Option<&Delta>)
    -> Result<(), ConstraintViolation>
{
    let constraint = &graph.constraints[&constraint_id];

    // Evaluate the constraint expression against current state
    let satisfied = eval_constraint_expr(graph, &constraint.expression, &HashMap::new());

    if satisfied {
        Ok(())
    } else {
        Err(ConstraintViolation {
            constraint_id,
            trigger: trigger.map(|d| d.id),
            // Include diagnostic info about WHY it failed
        })
    }
}
```

### 4. Pursue Goal

```
fn pursue_goal(graph: &mut Graph, goal_id: u64) -> GoalPursuitResult {
    let goal = &graph.goals[&goal_id];

    // Is goal already satisfied?
    if eval_constraint_expr(graph, &goal.target, &HashMap::new()) {
        return GoalPursuitResult::Achieved;
    }

    // Find deltas that could make progress toward goal
    let candidates = find_helpful_deltas(graph, &goal.target);

    if candidates.is_empty() {
        // Decompose into subgoals or report failure
        return try_decompose_or_fail(graph, goal_id);
    }

    // Apply best candidate (heuristic: lowest cost, highest impact)
    let best = select_best_delta(graph, candidates);
    match apply_delta(graph, best) {
        Ok(()) => GoalPursuitResult::Progress,
        Err(violation) => GoalPursuitResult::Blocked { reason: violation }
    }
}
```

---

## WHAT THE AI MANIPULATES

The AI (Claude) works with this graph through operations:

```
# Entity operations
create_entity(type_id) -> entity_id
delete_entity(entity_id)

# Tuple operations (these create deltas internally)
assert_tuple(type_id, values) -> tuple_id
retract_tuple(tuple_id)
modify_tuple(tuple_id, changes)

# Type operations (Level 1)
define_entity_type(name, constraints) -> type_id
define_relation_type(name, roles) -> type_id

# Constraint operations
add_constraint(kind, expression, scope) -> constraint_id
remove_constraint(constraint_id)

# Goal operations
set_goal(target_expr, owner, priority) -> goal_id
cancel_goal(goal_id)

# Query operations
query(pattern) -> Vec<Tuple>
query_provenance(tuple_id) -> Vec<Delta>
query_why_not(constraint_expr) -> Explanation
```

There is no "write source code" operation. The AI manipulates structure directly.

Text (like .herb files) is just one possible VIEW of this structure.

---

## PERFORMANCE CONSIDERATIONS

### Incremental Constraint Checking

We don't check ALL constraints on every delta. We check:
1. Preconditions for the specific delta type
2. Postconditions for the specific delta type
3. Invariants that INVOLVE the touched entities/relations

This requires tracking which constraints reference which relation types. When a
delta touches relation R, we only check constraints that mention R.

### Indices

The index structure is crucial:
- `tuples_by_type`: O(1) lookup of all tuples of a relation type
- `tuples_by_entity`: O(1) lookup of all tuples involving an entity
- `tuples_by_role`: O(1) lookup of tuples with specific value in specific role

These indices are updated incrementally on each delta.

### Materialized State vs Delta Log

We maintain BOTH:
- Delta log: source of truth, append-only, for provenance queries
- Tuples: materialized current state, for fast queries

The materialized state is derivable from the delta log but keeping it
materialized avoids replaying history on every query.

### Goal Pursuit

Goal pursuit is the expensive operation — it's search. We can use:
- A* when there's a good heuristic (spatial goals)
- BFS for small goal spaces
- HTN decomposition for complex goals
- Constraint propagation when goals are constraint-like

The system should choose strategy based on goal structure.

---

## NEXT: THE RESOLUTION ALGORITHM

This document defines the representation. The next document needs to define:

1. **Resolution**: How does a "tick" work? What's the order of operations?
2. **Strategy Selection**: How does the system choose which algorithm to use?
3. **Constraint Propagation**: How do we efficiently propagate constraint consequences?
4. **Goal Planning**: How does backward search from goals work?

---

*This is the foundation. The graph IS the program.*
