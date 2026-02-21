# HERB v2: The Constraint Language

The constraint language is the heart of expressiveness. It determines what we can
say about the graph, what invariants we can enforce, what goals we can pursue.

This document specifies the language precisely.

---

## DESIGN PRINCIPLES

1. **Decidable** — Every constraint can be checked in finite time
2. **Incremental** — Changes can be checked without rechecking everything
3. **Explainable** — When a constraint fails, we can say WHY
4. **Unified** — Same language for invariants, preconditions, goals, queries

To achieve decidability, we restrict to:
- Finite domains (quantifiers range over existing entities, not infinite sets)
- No arbitrary recursion (stratified dependencies only)
- Arithmetic over bounded integers (or rationals)

---

## THE EXPRESSION LANGUAGE

Expressions compute values. They appear inside constraints and in delta effects.

### Syntax (Abstract)

```
Expr ::=
    -- Literals
    | Int(i64)
    | Float(f64)
    | String(string)
    | Bool(bool)
    | Null
    | EntityRef(entity_id)

    -- Variables (bound by quantifiers or in scope)
    | Var(name)

    -- Tuple access
    | Role(tuple_expr, role_name)        -- t.buyer, t.amount

    -- Relation lookup (returns value or Null if not found)
    | Lookup(relation_type, bindings, result_role)
        -- Example: Lookup(holds, {holder: Var("p"), resource: gold}, "amount")
        -- Returns the amount in holds(p, gold, ?) or Null if no such tuple

    -- Arithmetic
    | Add(Expr, Expr)
    | Sub(Expr, Expr)
    | Mul(Expr, Expr)
    | Div(Expr, Expr)
    | Mod(Expr, Expr)
    | Neg(Expr)
    | Abs(Expr)
    | Min(Expr, Expr)
    | Max(Expr, Expr)

    -- Conditionals
    | IfThenElse(ConstraintExpr, Expr, Expr)

    -- Aggregates (compute over sets)
    | Sum(var, domain, value_expr)           -- sum of value_expr over domain
    | Count(var, domain, filter)             -- count of domain elements where filter is true
    | Min(var, domain, value_expr)           -- minimum value_expr over domain
    | Max(var, domain, value_expr)           -- maximum value_expr over domain
    | Collect(var, domain, value_expr)       -- list of value_expr over domain
```

### Domain Specifications

Domains define what a quantifier or aggregate ranges over:

```
Domain ::=
    | AllEntities                            -- every entity in the graph
    | EntitiesOfType(type_id)                -- entities of a specific type
    | AllTuples                              -- every tuple in the graph
    | TuplesOfType(relation_type_id)         -- tuples of a specific relation
    | TuplesMatching(relation_type, partial_bindings)
        -- tuples matching a pattern, e.g., TuplesMatching(holds, {resource: gold})
    | Explicit(list_of_values)               -- an explicit list
    | Range(start, end)                      -- integers in [start, end)
```

All domains are FINITE. `AllEntities` means all entities that currently exist,
not all possible entities. This is what makes quantifiers decidable.

---

## THE CONSTRAINT LANGUAGE

Constraints express conditions that must hold (invariants) or should hold (goals).

### Syntax (Abstract)

```
ConstraintExpr ::=
    -- Comparisons
    | Eq(Expr, Expr)                         -- e1 == e2
    | Ne(Expr, Expr)                         -- e1 != e2
    | Lt(Expr, Expr)                         -- e1 < e2
    | Le(Expr, Expr)                         -- e1 <= e2
    | Gt(Expr, Expr)                         -- e1 > e2
    | Ge(Expr, Expr)                         -- e1 >= e2

    -- Null checks
    | IsNull(Expr)
    | IsNotNull(Expr)

    -- Set membership
    | In(Expr, Domain)                       -- value in domain
    | NotIn(Expr, Domain)

    -- Logical connectives
    | And(ConstraintExpr, ConstraintExpr)
    | Or(ConstraintExpr, ConstraintExpr)
    | Not(ConstraintExpr)
    | Implies(ConstraintExpr, ConstraintExpr)  -- p → q  (equivalent to ¬p ∨ q)

    -- Quantifiers
    | ForAll(var, Domain, ConstraintExpr)    -- ∀x ∈ D. P(x)
    | Exists(var, Domain, ConstraintExpr)    -- ∃x ∈ D. P(x)

    -- Cardinality constraints
    | Unique(var, Domain, ConstraintExpr)    -- exactly one x where P(x)
    | AtMostOne(var, Domain, ConstraintExpr) -- at most one x where P(x)
    | AtLeastN(n, var, Domain, ConstraintExpr)
    | AtMostN(n, var, Domain, ConstraintExpr)
    | ExactlyN(n, var, Domain, ConstraintExpr)

    -- Aggregate constraints
    | SumIs(var, Domain, value_expr, expected)      -- sum equals expected
    | SumLe(var, Domain, value_expr, bound)         -- sum <= bound
    | SumGe(var, Domain, value_expr, bound)         -- sum >= bound

    -- Relation existence
    | TupleExists(relation_type, bindings)          -- there exists such a tuple
    | NoTuple(relation_type, bindings)              -- no such tuple exists

    -- Boolean literals
    | True
    | False
```

---

## EXAMPLES

### Example 1: Non-negative resources

"Every player's gold is at least 0."

```
ForAll(p, EntitiesOfType(player_type),
    Ge(
        Lookup(holds, {holder: Var("p"), resource: gold_entity}, "amount"),
        Int(0)
    )
)
```

Or, handling the case where the player might not have a holds tuple:

```
ForAll(p, EntitiesOfType(player_type),
    Or(
        IsNull(Lookup(holds, {holder: Var("p"), resource: gold_entity}, "amount")),
        Ge(Lookup(holds, {holder: Var("p"), resource: gold_entity}, "amount"), Int(0))
    )
)
```

### Example 2: Item location uniqueness

"Every item is in exactly one location."

```
ForAll(i, EntitiesOfType(item_type),
    Unique(t, TuplesOfType(location_relation),
        Eq(Role(Var("t"), "entity"), Var("i"))
    )
)
```

### Example 3: Conservation of gold

"Total gold in the system is constant."

```
SumIs(t, TuplesOfType(holds),
    Role(Var("t"), "amount"),
    Int(INITIAL_TOTAL_GOLD)
)
```

(This assumes all gold is tracked via `holds` tuples. Real system would include
treasury, banks, etc.)

### Example 4: Purchase precondition

"Buyer has enough gold to afford the item (including tax)."

```
-- This would be associated with the purchase delta type
Ge(
    Lookup(holds, {holder: Var("buyer"), resource: gold_entity}, "amount"),
    Add(
        Var("base_price"),
        Mul(Var("base_price"), Lookup(tax_rate, {jurisdiction: Var("jurisdiction")}, "rate"))
    )
)
```

### Example 5: Spatial adjacency

"Two tiles are adjacent if their coordinates differ by at most 1 in each dimension."

```
-- Definition of adjacent(tile1, tile2)
ForAll(t1, EntitiesOfType(tile_type),
    ForAll(t2, EntitiesOfType(tile_type),
        Implies(
            TupleExists(adjacent, {tile1: Var("t1"), tile2: Var("t2")}),
            And(
                Le(Abs(Sub(Lookup(position, {entity: Var("t1")}, "x"),
                           Lookup(position, {entity: Var("t2")}, "x"))), Int(1)),
                Le(Abs(Sub(Lookup(position, {entity: Var("t1")}, "y"),
                           Lookup(position, {entity: Var("t2")}, "y"))), Int(1))
            )
        )
    )
)
```

### Example 6: Goal — acquire sword

"Player 1 has sword 42 in their inventory."

```
TupleExists(inventory_contains, {
    inventory: Lookup(inventory, {owner: player_1_entity}, "inventory_id"),
    item: sword_42_entity
})
```

### Example 7: Scheduling constraint (OS)

"No two processes are running on the same CPU simultaneously."

```
ForAll(cpu, EntitiesOfType(cpu_type),
    AtMostOne(p, TuplesOfType(process_state),
        And(
            Eq(Role(Var("p"), "cpu"), Var("cpu")),
            Eq(Role(Var("p"), "state"), running_state)
        )
    )
)
```

### Example 8: Layout constraint (Browser)

"Child widths don't exceed parent width."

```
ForAll(parent, EntitiesOfType(element_type),
    Le(
        Sum(child, TuplesMatching(parent_child, {parent: Var("parent")}),
            Lookup(dimensions, {element: Role(Var("child"), "child")}, "width")
        ),
        Lookup(dimensions, {element: Var("parent")}, "width")
    )
)
```

---

## SEMANTIC DETAILS

### Null Handling

`Lookup` returns `Null` if no matching tuple exists. Arithmetic with `Null`
propagates: `Null + 5 = Null`, `Null < 5 = False`.

Null comparisons:
- `Eq(Null, Null) = True`
- `Eq(Null, anything_else) = False`
- `Lt(Null, x) = False` (Null is not less than anything)
- `Gt(Null, x) = False` (Null is not greater than anything)

Use `IsNull`/`IsNotNull` for explicit null checks.

### Quantifier Semantics

- `ForAll(x, D, P)` is True if P is true for every element of D
- `ForAll(x, EmptyDomain, P)` is True (vacuous truth)
- `Exists(x, D, P)` is True if P is true for at least one element of D
- `Exists(x, EmptyDomain, P)` is False

### Aggregate over Empty Domain

- `Sum(x, EmptyDomain, e)` = 0
- `Count(x, EmptyDomain, P)` = 0
- `Min(x, EmptyDomain, e)` = +∞ (or Null, design choice)
- `Max(x, EmptyDomain, e)` = -∞ (or Null)

### Variable Scoping

Variables are bound by the innermost enclosing quantifier or aggregate:

```
ForAll(p, Players,              -- p bound here
    Exists(t, Tuples,           -- t bound here
        And(
            Eq(Role(Var("t"), "holder"), Var("p")),  -- p from outer, t from inner
            Gt(Role(Var("t"), "amount"), Int(0))
        )
    )
)
```

Free variables are errors (caught at constraint definition time).

---

## CONSTRAINT CATEGORIES

Constraints are categorized by when they're checked:

### Invariants

Checked after every delta. If violated, the delta is rejected (or repair is triggered).

```
Constraint {
    kind: Invariant,
    expression: ...,
    scope: Global  // or TypeScoped, EntityScoped
}
```

### Preconditions

Checked BEFORE a delta is applied. If violated, the delta is not applied.

```
Constraint {
    kind: Precondition { delta_type: purchase_delta_type },
    expression: Ge(buyer_gold, total_price),
    scope: Global
}
```

The constraint expression has access to delta variables (buyer, seller, etc.)
bound from the pending delta.

### Postconditions

Checked AFTER a delta is applied. If violated, the delta is rolled back OR
repair is triggered.

```
Constraint {
    kind: Postcondition { delta_type: purchase_delta_type },
    expression: TupleExists(inventory_contains, {inventory: buyer_inventory, item: item}),
    scope: Global
}
```

### Derived

Not checked, but used to COMPUTE values. When inputs change, outputs are recomputed.

```
Constraint {
    kind: Derived {
        target_relation: total_damage,
        computation: Sum(d, TuplesMatching(damage, {target: Var("entity")}),
                         Role(Var("d"), "amount"))
    },
    scope: TypeScoped { type_id: entity_type }
}
```

### Maintenance

When the condition becomes false, the repair action is triggered.

```
Constraint {
    kind: Maintenance {
        condition: Ge(Lookup(hp, {entity: Var("e")}, "value"), Int(0)),
        repair: AssertDelta(death_delta, {entity: Var("e")})
    },
    scope: TypeScoped { type_id: living_entity_type }
}
```

---

## INCREMENTAL CHECKING

We don't recheck all constraints on every delta. We track dependencies:

```
ConstraintDependencies {
    // Which relation types does this constraint read from?
    reads_from: HashSet<RelationTypeId>,

    // Which entity types does this constraint quantify over?
    quantifies_over: HashSet<EntityTypeId>,

    // Is this constraint affected by adding/removing entities?
    entity_sensitive: bool
}
```

When a delta touches relation R, we only check constraints where R ∈ reads_from.

This is computed once when the constraint is defined, not at runtime.

---

## COMPLEXITY

### Checking Complexity

For a constraint with:
- q quantifiers (ForAll, Exists, etc.)
- Domains of size n

Worst case: O(n^q) — exponential in number of nested quantifiers.

Mitigations:
1. Most constraints have few quantifiers (1-2)
2. Indices make lookup O(1), reducing inner loop cost
3. Early termination (Exists can stop at first match, ForAll at first failure)
4. Incremental checking (only recheck affected constraints)

### What We Forbid

To keep constraints decidable:
- No infinite domains (quantifiers must range over finite sets)
- No unguarded recursion (can't define constraint in terms of itself)
- No higher-order quantification (can't quantify over constraints)

These restrictions are acceptable because:
- Real programs have finite entities
- Recursion is handled by stratified derivation, not single constraints
- Higher-order is rarely needed for game/OS/browser constraints

---

## TEXTUAL SYNTAX (For Human Readability)

The abstract syntax above is what the system manipulates. For human-readable
representation (a view), we could use something like:

```
-- Invariant: non-negative gold
INVARIANT gold_non_negative:
    FOR ALL p IN players:
        p.holds(gold).amount >= 0 OR p.holds(gold) IS NULL

-- Precondition: can afford purchase
PRECONDITION FOR purchase:
    buyer.holds(currency).amount >= base_price * (1 + jurisdiction.tax_rate)

-- Conservation law
INVARIANT gold_conserved:
    SUM t IN holds: t.amount = 10000

-- Goal
GOAL acquire_sword FOR player_1:
    player_1.inventory CONTAINS sword_42
```

This is just a view. The AI manipulates the abstract syntax directly.

---

## WHAT'S NEXT

The constraint language is specified. Remaining:

1. **The Bootstrap Problem** — How is the initial graph created?
2. **Implementation** — Constraint evaluator in Python/Rust
3. **Validation** — Express Common Herb's rules as constraints, verify equivalence
4. **Optimization** — Efficient incremental checking

---

*Constraints are the rules of the universe. The graph obeys them.*
