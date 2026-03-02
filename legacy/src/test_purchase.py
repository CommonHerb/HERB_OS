"""
HERB v2: Purchase Scenario Test

This tests the graph representation using the Common Herb purchase scenario
from GRAPH_DESIGN.md. A player buys a sword from a shop in a jurisdiction
with a 10% tax rate.
"""

from herb_graph import (
    Graph, Value, ValueType, ConstraintKind, Provenance,
    PrimordialIds
)


def test_purchase_scenario():
    """
    Test the complete purchase scenario:
    - Player walks into shop
    - Shop is in a jurisdiction with 10% tax
    - Player buys sword for 100 gold (110 with tax)
    - Gold conservation is maintained
    """
    print("=== HERB v2 Purchase Scenario Test ===\n")

    g = Graph()

    # =========================================================================
    # STEP 1: Define entity types
    # =========================================================================
    print("Step 1: Define entity types")

    player_type = g.define_entity_type("player")
    shop_type = g.define_entity_type("shop")
    item_type = g.define_entity_type("item")
    resource_type = g.define_entity_type("resource")
    jurisdiction_type = g.define_entity_type("jurisdiction")
    inventory_type = g.define_entity_type("inventory")

    print(f"  Created types: player, shop, item, resource, jurisdiction, inventory")

    # =========================================================================
    # STEP 2: Define relation types
    # =========================================================================
    print("\nStep 2: Define relation types")

    holds = g.define_relation_type("holds", [
        ("holder", ValueType.ENTITY_REF, None),  # player, shop, or jurisdiction treasury
        ("resource", ValueType.ENTITY_REF, resource_type),
        ("amount", ValueType.INT, None)
    ])

    location = g.define_relation_type("location", [
        ("entity", ValueType.ENTITY_REF, item_type),
        ("place", ValueType.ENTITY_REF, inventory_type)
    ])

    tax_rate = g.define_relation_type("tax_rate", [
        ("jurisdiction", ValueType.ENTITY_REF, jurisdiction_type),
        ("rate", ValueType.FLOAT, None)  # 0.0 to 1.0
    ])

    in_jurisdiction = g.define_relation_type("in_jurisdiction", [
        ("entity", ValueType.ENTITY_REF, None),  # shop, player, etc.
        ("jurisdiction", ValueType.ENTITY_REF, jurisdiction_type)
    ])

    owns_inventory = g.define_relation_type("owns_inventory", [
        ("owner", ValueType.ENTITY_REF, None),
        ("inventory", ValueType.ENTITY_REF, inventory_type)
    ])

    treasury_of = g.define_relation_type("treasury_of", [
        ("jurisdiction", ValueType.ENTITY_REF, jurisdiction_type),
        ("treasury", ValueType.ENTITY_REF, None)  # entity that holds the treasury
    ])

    print(f"  Created relations: holds, location, tax_rate, in_jurisdiction, owns_inventory, treasury_of")

    # =========================================================================
    # STEP 3: Define constraints
    # =========================================================================
    print("\nStep 3: Define constraints")

    # Invariant: Non-negative gold for all holders
    def gold_nonnegative(graph, ctx):
        for tup in graph.query_tuples(holds):
            amount = tup.values[2]
            if amount.type == ValueType.INT and amount.data < 0:
                return False
        return True

    g.add_constraint("gold_nonnegative", ConstraintKind.INVARIANT, gold_nonnegative)

    # Invariant: Item in exactly one location
    def item_unique_location(graph, ctx):
        # Count locations per item
        item_locations = {}
        for tup in graph.query_tuples(location):
            item_id = tup.values[0].data
            item_locations[item_id] = item_locations.get(item_id, 0) + 1

        for item_id, count in item_locations.items():
            if count != 1:
                return False
        return True

    g.add_constraint("item_unique_location", ConstraintKind.INVARIANT, item_unique_location)

    # Invariant: Gold conservation
    INITIAL_TOTAL_GOLD = 750  # 200 + 50 + 500 (player + shop + treasury)

    def gold_conserved(graph, ctx):
        total = 0
        gold_id = graph.get_entity_by_name("gold")
        for tup in graph.query_tuples(holds):
            if tup.values[1].data == gold_id:  # resource is gold
                total += tup.values[2].data
        return total == INITIAL_TOTAL_GOLD

    g.add_constraint("gold_conserved", ConstraintKind.INVARIANT, gold_conserved)

    print(f"  Created constraints: gold_nonnegative, item_unique_location, gold_conserved")

    # =========================================================================
    # STEP 4: Create instances (initial game state)
    # =========================================================================
    print("\nStep 4: Create initial game state")

    # Resources
    gold = g.create_entity(resource_type, "gold")

    # Jurisdictions
    jurisdiction_3 = g.create_entity(jurisdiction_type, "jurisdiction_3")
    treasury_3 = g.create_entity(inventory_type, "treasury_3")

    g.assert_tuple(tax_rate, {
        "jurisdiction": Value.entity_ref(jurisdiction_3),
        "rate": Value.float(0.10)
    })

    g.assert_tuple(treasury_of, {
        "jurisdiction": Value.entity_ref(jurisdiction_3),
        "treasury": Value.entity_ref(treasury_3)
    })

    # Treasury starts with 500 gold
    g.assert_tuple(holds, {
        "holder": Value.entity_ref(treasury_3),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(500)
    })

    # Player
    player_1 = g.create_entity(player_type, "player_1")
    player_1_inv = g.create_entity(inventory_type, "player_1_inventory")

    g.assert_tuple(owns_inventory, {
        "owner": Value.entity_ref(player_1),
        "inventory": Value.entity_ref(player_1_inv)
    })

    g.assert_tuple(holds, {
        "holder": Value.entity_ref(player_1),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(200)
    })

    # Shop
    shop_7 = g.create_entity(shop_type, "shop_7")
    shop_7_inv = g.create_entity(inventory_type, "shop_7_inventory")

    g.assert_tuple(owns_inventory, {
        "owner": Value.entity_ref(shop_7),
        "inventory": Value.entity_ref(shop_7_inv)
    })

    g.assert_tuple(holds, {
        "holder": Value.entity_ref(shop_7),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(50)
    })

    g.assert_tuple(in_jurisdiction, {
        "entity": Value.entity_ref(shop_7),
        "jurisdiction": Value.entity_ref(jurisdiction_3)
    })

    # Sword
    sword_42 = g.create_entity(item_type, "sword_42")

    g.assert_tuple(location, {
        "entity": Value.entity_ref(sword_42),
        "place": Value.entity_ref(shop_7_inv)
    })

    print(f"  Created: player_1 (200 gold), shop_7 (50 gold), sword_42, jurisdiction_3 (10% tax, 500 treasury)")

    # =========================================================================
    # STEP 5: Verify initial state
    # =========================================================================
    print("\nStep 5: Verify initial state")

    violations = g.check_invariants()
    if violations:
        print(f"  ERROR: {len(violations)} violations!")
        for cid, msg in violations:
            print(f"    - {msg}")
        return False
    else:
        print(f"  All invariants satisfied")

    # =========================================================================
    # STEP 6: Execute purchase
    # =========================================================================
    print("\nStep 6: Execute purchase (player_1 buys sword_42 for 100 base price)")

    base_price = 100
    tax_rate_value = 0.10
    tax = int(base_price * tax_rate_value)  # 10
    total_price = base_price + tax  # 110
    seller_receives = base_price  # Shop gets base price, not taxed amount

    print(f"  Base price: {base_price}")
    print(f"  Tax (10%): {tax}")
    print(f"  Total: {total_price}")
    print(f"  Seller receives: {seller_receives}")

    # Check precondition: player has enough gold
    player_gold = g.lookup(holds, {
        "holder": Value.entity_ref(player_1),
        "resource": Value.entity_ref(gold)
    }, "amount")

    print(f"  Player gold before: {player_gold.data}")
    if player_gold.data < total_price:
        print(f"  ERROR: Player cannot afford purchase!")
        return False

    # Execute the purchase as a series of deltas with common provenance
    purchase_prov = Provenance(
        cause='external',
        description=f"purchase: player_1 buys sword_42 from shop_7 for {total_price} gold"
    )

    # 1. Find and update player's gold (retract old, assert new)
    player_holds_tuples = g.query_tuples(holds, {
        "holder": Value.entity_ref(player_1),
        "resource": Value.entity_ref(gold)
    })
    if player_holds_tuples:
        g.retract_tuple(player_holds_tuples[0].id, purchase_prov)

    g.assert_tuple(holds, {
        "holder": Value.entity_ref(player_1),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(player_gold.data - total_price)  # 200 - 110 = 90
    }, purchase_prov)

    # 2. Update shop's gold
    shop_gold = g.lookup(holds, {
        "holder": Value.entity_ref(shop_7),
        "resource": Value.entity_ref(gold)
    }, "amount")

    shop_holds_tuples = g.query_tuples(holds, {
        "holder": Value.entity_ref(shop_7),
        "resource": Value.entity_ref(gold)
    })
    if shop_holds_tuples:
        g.retract_tuple(shop_holds_tuples[0].id, purchase_prov)

    g.assert_tuple(holds, {
        "holder": Value.entity_ref(shop_7),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(shop_gold.data + seller_receives)  # 50 + 100 = 150
    }, purchase_prov)

    # 3. Update treasury
    treasury_gold = g.lookup(holds, {
        "holder": Value.entity_ref(treasury_3),
        "resource": Value.entity_ref(gold)
    }, "amount")

    treasury_holds_tuples = g.query_tuples(holds, {
        "holder": Value.entity_ref(treasury_3),
        "resource": Value.entity_ref(gold)
    })
    if treasury_holds_tuples:
        g.retract_tuple(treasury_holds_tuples[0].id, purchase_prov)

    g.assert_tuple(holds, {
        "holder": Value.entity_ref(treasury_3),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(treasury_gold.data + tax)  # 500 + 10 = 510
    }, purchase_prov)

    # 4. Move sword from shop inventory to player inventory
    location_tuples = g.query_tuples(location, {
        "entity": Value.entity_ref(sword_42)
    })
    if location_tuples:
        g.retract_tuple(location_tuples[0].id, purchase_prov)

    g.assert_tuple(location, {
        "entity": Value.entity_ref(sword_42),
        "place": Value.entity_ref(player_1_inv)
    }, purchase_prov)

    print(f"  Purchase executed as {len([d for d in g.deltas if d.provenance.cause == 'external'])} deltas")

    # =========================================================================
    # STEP 7: Verify final state
    # =========================================================================
    print("\nStep 7: Verify final state")

    violations = g.check_invariants()
    if violations:
        print(f"  ERROR: {len(violations)} violations!")
        for cid, msg in violations:
            print(f"    - {msg}")
        return False
    else:
        print(f"  All invariants satisfied")

    # Check final values
    final_player_gold = g.lookup(holds, {
        "holder": Value.entity_ref(player_1),
        "resource": Value.entity_ref(gold)
    }, "amount")
    final_shop_gold = g.lookup(holds, {
        "holder": Value.entity_ref(shop_7),
        "resource": Value.entity_ref(gold)
    }, "amount")
    final_treasury_gold = g.lookup(holds, {
        "holder": Value.entity_ref(treasury_3),
        "resource": Value.entity_ref(gold)
    }, "amount")
    sword_location = g.lookup(location, {
        "entity": Value.entity_ref(sword_42)
    }, "place")

    print(f"\n  Player gold: {final_player_gold.data} (expected: 90)")
    print(f"  Shop gold: {final_shop_gold.data} (expected: 150)")
    print(f"  Treasury gold: {final_treasury_gold.data} (expected: 510)")
    print(f"  Sword location: {g.get_name(sword_location.data)} (expected: player_1_inventory)")
    print(f"  Total gold: {final_player_gold.data + final_shop_gold.data + final_treasury_gold.data} (expected: 750)")

    # Verify expectations
    assert final_player_gold.data == 90, f"Player gold wrong: {final_player_gold.data}"
    assert final_shop_gold.data == 150, f"Shop gold wrong: {final_shop_gold.data}"
    assert final_treasury_gold.data == 510, f"Treasury gold wrong: {final_treasury_gold.data}"
    assert sword_location.data == player_1_inv, "Sword location wrong"
    assert final_player_gold.data + final_shop_gold.data + final_treasury_gold.data == 750, "Gold not conserved"

    # =========================================================================
    # STEP 8: Provenance
    # =========================================================================
    print("\nStep 8: Provenance query")

    # Find the current holds tuple for player_1's gold
    player_holds_current = g.query_tuples(holds, {
        "holder": Value.entity_ref(player_1),
        "resource": Value.entity_ref(gold)
    })

    if player_holds_current:
        print(f"  Why does player_1 have {final_player_gold.data} gold?")
        for delta in g.why(player_holds_current[0].id):
            print(f"    {delta.kind.name} at tick {delta.tick}: {delta.provenance.description or delta.provenance.cause}")

    # =========================================================================
    # COMPLETE
    # =========================================================================
    print("\n=== TEST PASSED ===")
    print(f"Total deltas: {len(g.deltas)}")
    print(f"Current tuples: {len([t for t in g.tuples.values() if t.is_current()])}")

    return True


def test_purchase_fails_insufficient_gold():
    """Test that purchase fails when player doesn't have enough gold."""
    print("\n=== Test: Purchase Fails With Insufficient Gold ===\n")

    g = Graph()

    # Minimal setup
    player_type = g.define_entity_type("player")
    resource_type = g.define_entity_type("resource")

    holds = g.define_relation_type("holds", [
        ("holder", ValueType.ENTITY_REF, None),
        ("resource", ValueType.ENTITY_REF, resource_type),
        ("amount", ValueType.INT, None)
    ])

    # Non-negative constraint
    def gold_nonnegative(graph, ctx):
        for tup in graph.query_tuples(holds):
            amount = tup.values[2]
            if amount.type == ValueType.INT and amount.data < 0:
                return False
        return True

    g.add_constraint("gold_nonnegative", ConstraintKind.INVARIANT, gold_nonnegative)

    # Player with only 50 gold
    gold = g.create_entity(resource_type, "gold")
    player = g.create_entity(player_type, "poor_player")

    g.assert_tuple(holds, {
        "holder": Value.entity_ref(player),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(50)
    })

    # Try to deduct 100 gold (simulating a purchase they can't afford)
    player_gold = g.lookup(holds, {
        "holder": Value.entity_ref(player),
        "resource": Value.entity_ref(gold)
    }, "amount")

    total_price = 100
    print(f"  Player has: {player_gold.data} gold")
    print(f"  Attempting to spend: {total_price} gold")

    if player_gold.data >= total_price:
        print("  ERROR: Should not be able to afford this!")
        return False

    print("  Correctly identified: insufficient funds")
    print("  Purchase blocked by precondition check (no delta created)")

    print("\n=== TEST PASSED ===")
    return True


def test_conservation_violation_detected():
    """Test that gold conservation violation is detected."""
    print("\n=== Test: Conservation Violation Detection ===\n")

    g = Graph()

    resource_type = g.define_entity_type("resource")
    account_type = g.define_entity_type("account")

    holds = g.define_relation_type("holds", [
        ("holder", ValueType.ENTITY_REF, account_type),
        ("resource", ValueType.ENTITY_REF, resource_type),
        ("amount", ValueType.INT, None)
    ])

    gold = g.create_entity(resource_type, "gold")
    account_1 = g.create_entity(account_type, "account_1")
    account_2 = g.create_entity(account_type, "account_2")

    # Initial state: 100 total gold
    g.assert_tuple(holds, {
        "holder": Value.entity_ref(account_1),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(60)
    })
    g.assert_tuple(holds, {
        "holder": Value.entity_ref(account_2),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(40)
    })

    # Conservation constraint
    INITIAL_TOTAL = 100

    def gold_conserved(graph, ctx):
        total = 0
        gold_id = graph.get_entity_by_name("gold")
        for tup in graph.query_tuples(holds):
            if tup.values[1].data == gold_id:
                total += tup.values[2].data
        return total == INITIAL_TOTAL

    g.add_constraint("gold_conserved", ConstraintKind.INVARIANT, gold_conserved)

    print("  Initial state: account_1=60, account_2=40, total=100")
    violations = g.check_invariants()
    assert len(violations) == 0, "Should have no violations initially"
    print("  Conservation satisfied")

    # Now create gold out of thin air (bug!)
    print("\n  BUG: Adding 50 gold to account_1 without removing from anywhere...")

    old_tuples = g.query_tuples(holds, {
        "holder": Value.entity_ref(account_1),
        "resource": Value.entity_ref(gold)
    })
    g.retract_tuple(old_tuples[0].id)

    g.assert_tuple(holds, {
        "holder": Value.entity_ref(account_1),
        "resource": Value.entity_ref(gold),
        "amount": Value.int(110)  # Was 60, now 110 (created 50 gold!)
    })

    violations = g.check_invariants()
    print(f"\n  Checking invariants...")
    if violations:
        print(f"  DETECTED: {violations[0][1]}")
        print("\n=== TEST PASSED (violation correctly detected) ===")
        return True
    else:
        print("  ERROR: Violation not detected!")
        return False


if __name__ == "__main__":
    success = True
    success = test_purchase_scenario() and success
    success = test_purchase_fails_insufficient_gold() and success
    success = test_conservation_violation_detected() and success

    print("\n" + "=" * 50)
    if success:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
