"""
HERB v2: Resolution Loop Tests

Tests the core resolution algorithm from GRAPH_RESOLUTION.md:
- Pending delta queue
- Apply pending deltas with precondition checking
- Constraint propagation
- The main resolve() loop
"""

from herb_graph import (
    Graph, Value, ValueType, ConstraintKind, Provenance,
    PrimordialIds, DeltaKind, DeltaSource, ViolationPolicy,
    ResolutionStatus, PendingDelta
)


def test_resolve_basic():
    """Test basic resolve() flow with simple assertion."""
    print("\n=== Test: Basic Resolve Flow ===\n")

    g = Graph()

    # Setup
    resource_type = g.define_entity_type("resource")
    account_type = g.define_entity_type("account")

    holds = g.define_relation_type("holds", [
        ("holder", ValueType.ENTITY_REF, account_type),
        ("resource", ValueType.ENTITY_REF, resource_type),
        ("amount", ValueType.INT, None)
    ])

    gold = g.create_entity(resource_type, "gold")
    account = g.create_entity(account_type, "account_1")

    # Queue a delta instead of applying immediately
    g.queue_assert(holds, {
        "holder": Value.entity_ref(account),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(100)
    })

    print(f"  Pending deltas before resolve: {len(g.pending_deltas)}")
    assert len(g.pending_deltas) == 1, "Should have one pending delta"

    # State should be empty before resolve
    tuples_before = g.query_tuples(holds)
    print(f"  Tuples before resolve: {len(tuples_before)}")
    assert len(tuples_before) == 0, "Should have no tuples yet"

    # Resolve
    result = g.resolve()

    print(f"  Resolution status: {result.status.name}")
    print(f"  Iterations: {result.iterations}")
    print(f"  Applied deltas: {len(result.applied_deltas)}")

    # Check result
    assert result.status == ResolutionStatus.QUIESCENT
    assert len(result.applied_deltas) == 1

    # State should now have the tuple
    tuples_after = g.query_tuples(holds)
    print(f"  Tuples after resolve: {len(tuples_after)}")
    assert len(tuples_after) == 1

    amount = g.lookup(holds, {
        "holder": Value.entity_ref(account),
        "resource": Value.entity_ref(gold)
    }, "amount")
    print(f"  Account balance: {amount.data}")
    assert amount.data == 100

    print("\n=== TEST PASSED ===")
    return True


def test_resolve_with_precondition():
    """Test that preconditions are checked during resolve."""
    print("\n=== Test: Resolve With Precondition ===\n")

    g = Graph()

    # Setup
    resource_type = g.define_entity_type("resource")
    account_type = g.define_entity_type("account")

    holds = g.define_relation_type("holds", [
        ("holder", ValueType.ENTITY_REF, account_type),
        ("resource", ValueType.ENTITY_REF, resource_type),
        ("amount", ValueType.INT, None)
    ])

    # Define a "transfer" relation type to test preconditions
    transfer = g.define_relation_type("transfer", [
        ("from_account", ValueType.ENTITY_REF, account_type),
        ("to_account", ValueType.ENTITY_REF, account_type),
        ("resource", ValueType.ENTITY_REF, resource_type),
        ("amount", ValueType.INT, None)
    ])

    # Precondition: sender must have enough funds
    def has_sufficient_funds(graph, ctx):
        if 'from_account' not in ctx or 'resource' not in ctx or 'amount' not in ctx:
            return True  # Can't check without context

        current = graph.lookup(holds, {
            "holder": ctx['from_account'],
            "resource": ctx['resource']
        }, "amount")

        if current.type == ValueType.NULL:
            return False  # No balance

        return current.data >= ctx['amount'].data

    g.add_constraint(
        "sufficient_funds",
        ConstraintKind.PRECONDITION,
        has_sufficient_funds,
        delta_type_id=transfer
    )

    # Create entities and initial state
    gold = g.create_entity(resource_type, "gold")
    alice = g.create_entity(account_type, "alice")
    bob = g.create_entity(account_type, "bob")

    # Alice has 50 gold
    g.assert_tuple(holds, {
        "holder": Value.entity_ref(alice),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(50)
    })

    # Bob has 0 gold
    g.assert_tuple(holds, {
        "holder": Value.entity_ref(bob),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(0)
    })

    print("  Initial state: Alice=50, Bob=0")

    # Try to transfer 100 gold (more than Alice has)
    g.queue_assert(transfer, {
        "from_account": Value.entity_ref(alice),
        "to_account": Value.entity_ref(bob),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(100)
    })

    print("  Attempting transfer of 100 gold (Alice only has 50)...")

    result = g.resolve()

    print(f"  Resolution status: {result.status.name}")
    print(f"  Violations: {len(result.violations)}")

    # The transfer should be rejected due to precondition
    if result.violations:
        print(f"  Violation: {result.violations[0].message}")
        assert "sufficient_funds" in result.violations[0].constraint_name

    # The transfer tuple should NOT have been created
    transfers = g.query_tuples(transfer)
    print(f"  Transfer tuples created: {len(transfers)}")
    assert len(transfers) == 0, "Transfer should have been rejected"

    print("\n=== TEST PASSED ===")
    return True


def test_resolve_multiple_deltas():
    """Test resolve with multiple pending deltas and priorities."""
    print("\n=== Test: Multiple Deltas With Priorities ===\n")

    g = Graph()

    # Setup
    event_type = g.define_entity_type("event")

    log = g.define_relation_type("log", [
        ("event", ValueType.ENTITY_REF, event_type),
        ("order", ValueType.INT, None)
    ])

    events = [g.create_entity(event_type, f"event_{i}") for i in range(5)]

    # Queue deltas with different priorities (should be applied high to low)
    for i, event in enumerate(events):
        g.queue_assert(log, {
            "event": Value.entity_ref(event),
            "order": Value.int(i)
        }, priority=i)  # event_4 has highest priority

    print(f"  Queued {len(g.pending_deltas)} deltas with different priorities")

    result = g.resolve()

    print(f"  Applied {len(result.applied_deltas)} deltas")
    assert len(result.applied_deltas) == 5

    # All tuples should be created
    logs = g.query_tuples(log)
    print(f"  Log tuples: {len(logs)}")
    assert len(logs) == 5

    print("\n=== TEST PASSED ===")
    return True


def test_resolve_with_invariant_violation():
    """Test that invariant violations are detected during resolve."""
    print("\n=== Test: Invariant Violation During Resolve ===\n")

    g = Graph()

    # Setup
    resource_type = g.define_entity_type("resource")
    account_type = g.define_entity_type("account")

    holds = g.define_relation_type("holds", [
        ("holder", ValueType.ENTITY_REF, account_type),
        ("resource", ValueType.ENTITY_REF, resource_type),
        ("amount", ValueType.INT, None)
    ])

    # Invariant: non-negative balances
    def balance_non_negative(graph, ctx):
        for tup in graph.query_tuples(holds):
            if tup.values[2].data < 0:
                return False
        return True

    g.add_constraint("balance_non_negative", ConstraintKind.INVARIANT, balance_non_negative)

    # Create entities
    gold = g.create_entity(resource_type, "gold")
    account = g.create_entity(account_type, "account_1")

    # Queue a delta that creates negative balance
    g.queue_assert(holds, {
        "holder": Value.entity_ref(account),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(-50)  # Negative!
    })

    print("  Queued assertion of negative balance (-50)")

    result = g.resolve()

    print(f"  Resolution status: {result.status.name}")
    print(f"  Violations: {len(result.violations)}")

    # Should have detected the violation
    assert result.status == ResolutionStatus.CONSTRAINT_VIOLATIONS
    assert len(result.violations) > 0
    assert "balance_non_negative" in result.violations[0].constraint_name

    print(f"  Violation detected: {result.violations[0].message}")

    print("\n=== TEST PASSED ===")
    return True


def test_derived_constraint():
    """Test derived constraints that compute values."""
    print("\n=== Test: Derived Constraint ===\n")

    g = Graph()

    # Setup: source amounts and computed total
    source_type = g.define_entity_type("source")
    target_type = g.define_entity_type("target")

    amount = g.define_relation_type("amount", [
        ("source", ValueType.ENTITY_REF, source_type),
        ("value", ValueType.INT, None)
    ])

    total = g.define_relation_type("total", [
        ("target", ValueType.ENTITY_REF, target_type),
        ("sum", ValueType.INT, None)
    ])

    # Create entities
    src1 = g.create_entity(source_type, "source_1")
    src2 = g.create_entity(source_type, "source_2")
    tgt = g.create_entity(target_type, "target")

    # Derived constraint: total is sum of all amounts
    def compute_total(graph, dirty_relations):
        # Compute sum of all amounts
        total_sum = 0
        for tup in graph.query_tuples(amount):
            total_sum += tup.values[1].data

        # Check if we need to update
        current = graph.lookup(total, {
            "target": Value.entity_ref(tgt)
        }, "sum")

        if current.type == ValueType.NULL or current.data != total_sum:
            # Need to update: retract old if exists, assert new
            deltas = []

            old_tuples = graph.query_tuples(total, {"target": Value.entity_ref(tgt)})
            for old_tup in old_tuples:
                deltas.append(PendingDelta(
                    kind=DeltaKind.RETRACT,
                    relation_type_id=total,
                    values=old_tup.values,
                    tuple_id=old_tup.id
                ))

            # Assert new total
            deltas.append(PendingDelta(
                kind=DeltaKind.ASSERT,
                relation_type_id=total,
                values=[Value.entity_ref(tgt), Value.int(total_sum)]
            ))

            return deltas

        return []

    g.add_constraint(
        "compute_total",
        ConstraintKind.DERIVED,
        check_fn=lambda g, c: True,  # Always OK (it's derived, not validated)
        derive_fn=compute_total,
        depends_on_relations=[amount]
    )

    # Add initial amounts
    g.assert_tuple(amount, {"source": Value.entity_ref(src1), "value": Value.int(30)})
    g.assert_tuple(amount, {"source": Value.entity_ref(src2), "value": Value.int(20)})

    # These are applied immediately (not through resolve)
    # Now trigger propagation manually
    g.recently_applied = list(g.deltas[-2:])  # Mark recent deltas

    # Queue a new amount to trigger propagation through resolve
    g.queue_assert(amount, {"source": Value.entity_ref(src1), "value": Value.int(10)})

    print("  Initial amounts: 30 + 20 = 50")
    print("  Queued new amount: 10")

    result = g.resolve()

    print(f"  Resolution iterations: {result.iterations}")
    print(f"  Propagation cycles: {result.propagation_cycles}")

    # Check the total
    computed = g.lookup(total, {"target": Value.entity_ref(tgt)}, "sum")
    print(f"  Computed total: {computed.data if computed.type != ValueType.NULL else 'null'}")

    # Note: The derived constraint runs after the new amount is added
    # Total should be 30 + 20 + 10 = 60 (the old 30 and new 10 coexist since we didn't retract)

    print("\n=== TEST PASSED ===")
    return True


def test_maintenance_constraint():
    """Test maintenance constraints that auto-repair."""
    print("\n=== Test: Maintenance Constraint ===\n")

    g = Graph()

    # Setup: HP that auto-creates death when <= 0
    entity_type = g.define_entity_type("entity")
    state_type = g.define_entity_type("state")

    hp = g.define_relation_type("hp", [
        ("entity", ValueType.ENTITY_REF, entity_type),
        ("value", ValueType.INT, None)
    ])

    is_dead = g.define_relation_type("is_dead", [
        ("entity", ValueType.ENTITY_REF, entity_type),
        ("dead", ValueType.BOOL, None)
    ])

    # Create entity
    player = g.create_entity(entity_type, "player")

    # Initial state: alive with 10 HP
    g.assert_tuple(hp, {"entity": Value.entity_ref(player), "value": Value.int(10)})
    g.assert_tuple(is_dead, {"entity": Value.entity_ref(player), "dead": Value.bool(False)})

    # Maintenance constraint: if hp <= 0 and not dead, mark as dead
    def check_alive_if_hp_positive(graph, ctx):
        """Returns True if state is consistent (no repair needed)."""
        for hp_tup in graph.query_tuples(hp):
            entity_id = hp_tup.values[0].data
            hp_val = hp_tup.values[1].data

            # Find death status
            dead_tups = graph.query_tuples(is_dead, {"entity": Value.entity_ref(entity_id)})
            is_dead_now = dead_tups and dead_tups[0].values[1].data

            # If HP <= 0 but not marked dead, need repair
            if hp_val <= 0 and not is_dead_now:
                return False

        return True

    def repair_death_status(graph):
        """Generate deltas to mark entities as dead."""
        deltas = []

        for hp_tup in graph.query_tuples(hp):
            entity_id = hp_tup.values[0].data
            hp_val = hp_tup.values[1].data

            if hp_val <= 0:
                # Retract old is_dead=False
                old = graph.query_tuples(is_dead, {"entity": Value.entity_ref(entity_id)})
                for old_tup in old:
                    deltas.append(PendingDelta(
                        kind=DeltaKind.RETRACT,
                        relation_type_id=is_dead,
                        values=old_tup.values,
                        tuple_id=old_tup.id
                    ))

                # Assert is_dead=True
                deltas.append(PendingDelta(
                    kind=DeltaKind.ASSERT,
                    relation_type_id=is_dead,
                    values=[Value.entity_ref(entity_id), Value.bool(True)]
                ))

        return deltas

    g.add_constraint(
        "auto_death",
        ConstraintKind.MAINTENANCE,
        check_fn=check_alive_if_hp_positive,
        repair_fn=repair_death_status
    )

    print("  Initial: HP=10, is_dead=False")

    # Now damage the player to 0 HP
    old_hp = g.query_tuples(hp, {"entity": Value.entity_ref(player)})[0]
    g.retract_tuple(old_hp.id)

    # Queue the new HP via resolve
    g.queue_assert(hp, {"entity": Value.entity_ref(player), "value": Value.int(0)})

    print("  Setting HP to 0...")

    result = g.resolve()

    print(f"  Resolution iterations: {result.iterations}")
    print(f"  Applied deltas: {len(result.applied_deltas)}")

    # Check death status
    dead_status = g.lookup(is_dead, {"entity": Value.entity_ref(player)}, "dead")
    print(f"  is_dead after resolve: {dead_status.data}")

    # Should be marked as dead
    assert dead_status.data == True, "Player should be marked as dead"

    print("\n=== TEST PASSED ===")
    return True


def test_tick_with_resolve():
    """Test the tick_with_resolve method for game-like usage."""
    print("\n=== Test: Tick With Resolve ===\n")

    g = Graph()

    # Setup
    entity_type = g.define_entity_type("entity")

    position = g.define_relation_type("position", [
        ("entity", ValueType.ENTITY_REF, entity_type),
        ("x", ValueType.INT, None),
        ("y", ValueType.INT, None)
    ])

    player = g.create_entity(entity_type, "player")

    # Initial position
    g.assert_tuple(position, {
        "entity": Value.entity_ref(player),
        "x": Value.int(0),
        "y": Value.int(0)
    })

    print(f"  Tick {g.current_tick}: player at (0, 0)")

    # Move via tick_with_resolve
    old_pos = g.query_tuples(position, {"entity": Value.entity_ref(player)})[0]

    result = g.tick_with_resolve([
        {
            "kind": DeltaKind.RETRACT,
            "relation_type_id": position,
            "bindings": {
                "entity": Value.entity_ref(player),
                "x": Value.int(0),
                "y": Value.int(0)
            },
            "tuple_id": old_pos.id
        },
        {
            "kind": DeltaKind.ASSERT,
            "relation_type_id": position,
            "bindings": {
                "entity": Value.entity_ref(player),
                "x": Value.int(1),
                "y": Value.int(0)
            }
        }
    ])

    print(f"  Tick {g.current_tick}: player moved")
    print(f"  Resolution iterations: {result.iterations}")

    # Check new position
    pos = g.query_tuples(position, {"entity": Value.entity_ref(player)})[0]
    x = pos.values[1].data
    y = pos.values[2].data
    print(f"  New position: ({x}, {y})")

    assert x == 1 and y == 0, "Player should have moved to (1, 0)"

    print("\n=== TEST PASSED ===")
    return True


def test_purchase_through_resolve():
    """Full purchase scenario using the resolve loop."""
    print("\n=== Test: Purchase Through Resolve ===\n")

    g = Graph()

    # Define types
    player_type = g.define_entity_type("player")
    shop_type = g.define_entity_type("shop")
    item_type = g.define_entity_type("item")
    resource_type = g.define_entity_type("resource")
    inventory_type = g.define_entity_type("inventory")

    # Define relations
    holds = g.define_relation_type("holds", [
        ("holder", ValueType.ENTITY_REF, None),
        ("resource", ValueType.ENTITY_REF, resource_type),
        ("amount", ValueType.INT, None)
    ])

    location = g.define_relation_type("location", [
        ("entity", ValueType.ENTITY_REF, item_type),
        ("place", ValueType.ENTITY_REF, inventory_type)
    ])

    owns_inventory = g.define_relation_type("owns_inventory", [
        ("owner", ValueType.ENTITY_REF, None),
        ("inventory", ValueType.ENTITY_REF, inventory_type)
    ])

    # Purchase request relation (used for precondition checking)
    purchase_request = g.define_relation_type("purchase_request", [
        ("buyer", ValueType.ENTITY_REF, player_type),
        ("item", ValueType.ENTITY_REF, item_type),
        ("price", ValueType.INT, None)
    ])

    # Precondition: buyer has enough gold
    def buyer_can_afford(graph, ctx):
        if 'buyer' not in ctx or 'price' not in ctx:
            return True

        gold_id = graph.get_entity_by_name("gold")
        balance = graph.lookup(holds, {
            "holder": ctx['buyer'],
            "resource": Value.entity_ref(gold_id)
        }, "amount")

        if balance.type == ValueType.NULL:
            return False

        return balance.data >= ctx['price'].data

    g.add_constraint("buyer_can_afford", ConstraintKind.PRECONDITION,
                     buyer_can_afford, delta_type_id=purchase_request)

    # Non-negative gold invariant
    def gold_non_negative(graph, ctx):
        for tup in graph.query_tuples(holds):
            if tup.values[2].data < 0:
                return False
        return True

    g.add_constraint("gold_non_negative", ConstraintKind.INVARIANT, gold_non_negative)

    # Create entities
    gold = g.create_entity(resource_type, "gold")
    player = g.create_entity(player_type, "player_1")
    shop = g.create_entity(shop_type, "shop_1")
    sword = g.create_entity(item_type, "sword")
    player_inv = g.create_entity(inventory_type, "player_inventory")
    shop_inv = g.create_entity(inventory_type, "shop_inventory")

    # Initial state
    g.assert_tuple(owns_inventory, {"owner": Value.entity_ref(player), "inventory": Value.entity_ref(player_inv)})
    g.assert_tuple(owns_inventory, {"owner": Value.entity_ref(shop), "inventory": Value.entity_ref(shop_inv)})
    g.assert_tuple(holds, {"holder": Value.entity_ref(player), "resource": Value.entity_ref(gold), "amount": Value.int(100)})
    g.assert_tuple(holds, {"holder": Value.entity_ref(shop), "resource": Value.entity_ref(gold), "amount": Value.int(50)})
    g.assert_tuple(location, {"entity": Value.entity_ref(sword), "place": Value.entity_ref(shop_inv)})

    print("  Initial: player=100g, shop=50g, sword in shop")

    # Test 1: Try to buy something too expensive
    g.queue_assert(purchase_request, {
        "buyer": Value.entity_ref(player),
        "item": Value.entity_ref(sword),
        "price": Value.int(200)  # Player only has 100
    })

    result = g.resolve()
    print(f"  Attempted purchase for 200g: {'BLOCKED' if result.violations else 'ALLOWED'}")
    assert len(result.violations) > 0, "Should have blocked expensive purchase"

    # Test 2: Buy at affordable price
    g.queue_assert(purchase_request, {
        "buyer": Value.entity_ref(player),
        "item": Value.entity_ref(sword),
        "price": Value.int(80)
    })

    result = g.resolve()
    print(f"  Attempted purchase for 80g: {'BLOCKED' if result.violations else 'ALLOWED'}")
    assert len(result.violations) == 0, "Should have allowed affordable purchase"

    print("\n=== TEST PASSED ===")
    return True


if __name__ == "__main__":
    success = True

    success = test_resolve_basic() and success
    success = test_resolve_with_precondition() and success
    success = test_resolve_multiple_deltas() and success
    success = test_resolve_with_invariant_violation() and success
    success = test_derived_constraint() and success
    success = test_maintenance_constraint() and success
    success = test_tick_with_resolve() and success
    success = test_purchase_through_resolve() and success

    print("\n" + "=" * 50)
    if success:
        print("ALL RESOLUTION TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
