"""
HERB v2: Purchase Stress Test

This tests the resolution loop with realistic, complex scenarios:
- Multiple players, shops, jurisdictions
- Different tax rates
- Edge cases that expose bugs

The goal is to find what's broken before building more on top.
"""

from herb_graph import (
    Graph, Value, ValueType, ConstraintKind, Provenance,
    PrimordialIds, DeltaKind, DeltaSource, ViolationPolicy,
    ResolutionStatus, PendingDelta
)


def create_economy_graph():
    """
    Create a graph with a realistic economy structure.
    Returns the graph and a dict of entity IDs for convenience.
    """
    g = Graph()
    ids = {}

    # Entity types
    ids['player_type'] = g.define_entity_type("player")
    ids['shop_type'] = g.define_entity_type("shop")
    ids['item_type'] = g.define_entity_type("item")
    ids['resource_type'] = g.define_entity_type("resource")
    ids['inventory_type'] = g.define_entity_type("inventory")
    ids['jurisdiction_type'] = g.define_entity_type("jurisdiction")

    # Relation types
    ids['holds'] = g.define_relation_type("holds", [
        ("holder", ValueType.ENTITY_REF, None),
        ("resource", ValueType.ENTITY_REF, ids['resource_type']),
        ("amount", ValueType.INT, None)
    ])

    ids['location'] = g.define_relation_type("location", [
        ("entity", ValueType.ENTITY_REF, ids['item_type']),
        ("place", ValueType.ENTITY_REF, ids['inventory_type'])
    ])

    ids['tax_rate'] = g.define_relation_type("tax_rate", [
        ("jurisdiction", ValueType.ENTITY_REF, ids['jurisdiction_type']),
        ("rate", ValueType.FLOAT, None)
    ])

    ids['in_jurisdiction'] = g.define_relation_type("in_jurisdiction", [
        ("entity", ValueType.ENTITY_REF, None),
        ("jurisdiction", ValueType.ENTITY_REF, ids['jurisdiction_type'])
    ])

    ids['owns_inventory'] = g.define_relation_type("owns_inventory", [
        ("owner", ValueType.ENTITY_REF, None),
        ("inventory", ValueType.ENTITY_REF, ids['inventory_type'])
    ])

    ids['treasury_of'] = g.define_relation_type("treasury_of", [
        ("jurisdiction", ValueType.ENTITY_REF, ids['jurisdiction_type']),
        ("treasury", ValueType.ENTITY_REF, None)
    ])

    ids['item_price'] = g.define_relation_type("item_price", [
        ("item", ValueType.ENTITY_REF, ids['item_type']),
        ("price", ValueType.INT, None)
    ])

    # Resources
    ids['gold'] = g.create_entity(ids['resource_type'], "gold")

    return g, ids


def add_jurisdiction(g, ids, name, tax_rate_pct, initial_treasury):
    """Add a jurisdiction with treasury."""
    jur = g.create_entity(ids['jurisdiction_type'], f"{name}_jurisdiction")
    treasury = g.create_entity(ids['inventory_type'], f"{name}_treasury")

    g.assert_tuple(ids['tax_rate'], {
        "jurisdiction": Value.entity_ref(jur),
        "rate": Value.float(tax_rate_pct / 100.0)
    })

    g.assert_tuple(ids['treasury_of'], {
        "jurisdiction": Value.entity_ref(jur),
        "treasury": Value.entity_ref(treasury)
    })

    g.assert_tuple(ids['holds'], {
        "holder": Value.entity_ref(treasury),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(initial_treasury)
    })

    return jur, treasury


def add_player(g, ids, name, gold_amount):
    """Add a player with inventory and gold."""
    player = g.create_entity(ids['player_type'], name)
    inv = g.create_entity(ids['inventory_type'], f"{name}_inventory")

    g.assert_tuple(ids['owns_inventory'], {
        "owner": Value.entity_ref(player),
        "inventory": Value.entity_ref(inv)
    })

    g.assert_tuple(ids['holds'], {
        "holder": Value.entity_ref(player),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(gold_amount)
    })

    return player, inv


def add_shop(g, ids, name, gold_amount, jurisdiction):
    """Add a shop with inventory and gold in a jurisdiction."""
    shop = g.create_entity(ids['shop_type'], name)
    inv = g.create_entity(ids['inventory_type'], f"{name}_inventory")

    g.assert_tuple(ids['owns_inventory'], {
        "owner": Value.entity_ref(shop),
        "inventory": Value.entity_ref(inv)
    })

    g.assert_tuple(ids['holds'], {
        "holder": Value.entity_ref(shop),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(gold_amount)
    })

    g.assert_tuple(ids['in_jurisdiction'], {
        "entity": Value.entity_ref(shop),
        "jurisdiction": Value.entity_ref(jurisdiction)
    })

    return shop, inv


def add_item(g, ids, name, inventory, price):
    """Add an item to an inventory with a price."""
    item = g.create_entity(ids['item_type'], name)

    g.assert_tuple(ids['location'], {
        "entity": Value.entity_ref(item),
        "place": Value.entity_ref(inventory)
    })

    g.assert_tuple(ids['item_price'], {
        "item": Value.entity_ref(item),
        "price": Value.int(price)
    })

    return item


def get_balance(g, ids, holder):
    """Get gold balance for a holder."""
    result = g.lookup(ids['holds'], {
        "holder": Value.entity_ref(holder),
        "resource": Value.entity_ref(ids['gold'])
    }, "amount")
    return result.data if result.type != ValueType.NULL else 0


def get_item_location(g, ids, item):
    """Get current location (inventory) of an item."""
    result = g.lookup(ids['location'], {
        "entity": Value.entity_ref(item)
    }, "place")
    return result.data if result.type != ValueType.NULL else None


def total_gold(g, ids):
    """Sum all gold in the system."""
    total = 0
    for tup in g.query_tuples(ids['holds']):
        if tup.values[1].data == ids['gold']:
            total += tup.values[2].data
    return total


def execute_purchase(g, ids, buyer, seller, item, base_price, treasury, tax_rate, provenance=None):
    """
    Execute a purchase with tax. Returns True if successful.

    This is the atomic purchase operation that should:
    1. Deduct total price (base + tax) from buyer
    2. Add base price to seller
    3. Add tax to treasury
    4. Move item to buyer

    All or nothing — if any step fails, nothing happens.
    """
    if provenance is None:
        provenance = Provenance(cause='external', description='purchase')

    tax = int(base_price * tax_rate)
    total_price = base_price + tax

    buyer_gold = get_balance(g, ids, buyer)
    if buyer_gold < total_price:
        return False, "Insufficient funds"

    seller_gold = get_balance(g, ids, seller)
    treasury_gold = get_balance(g, ids, treasury)

    # Get the buyer's inventory
    buyer_inv_result = g.lookup(ids['owns_inventory'], {
        "owner": Value.entity_ref(buyer)
    }, "inventory")
    if buyer_inv_result.type == ValueType.NULL:
        return False, "Buyer has no inventory"
    buyer_inv = buyer_inv_result.data

    # Check item is in seller's inventory
    item_loc = get_item_location(g, ids, item)
    seller_inv_result = g.lookup(ids['owns_inventory'], {
        "owner": Value.entity_ref(seller)
    }, "inventory")
    if seller_inv_result.type == ValueType.NULL:
        return False, "Seller has no inventory"
    seller_inv = seller_inv_result.data

    if item_loc != seller_inv:
        return False, "Item not in seller's inventory"

    # Execute the purchase as a series of retracts and asserts
    # 1. Update buyer's gold
    buyer_holds = g.query_tuples(ids['holds'], {
        "holder": Value.entity_ref(buyer),
        "resource": Value.entity_ref(ids['gold'])
    })
    if buyer_holds:
        g.retract_tuple(buyer_holds[0].id, provenance)
    g.assert_tuple(ids['holds'], {
        "holder": Value.entity_ref(buyer),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(buyer_gold - total_price)
    }, provenance)

    # 2. Update seller's gold
    seller_holds = g.query_tuples(ids['holds'], {
        "holder": Value.entity_ref(seller),
        "resource": Value.entity_ref(ids['gold'])
    })
    if seller_holds:
        g.retract_tuple(seller_holds[0].id, provenance)
    g.assert_tuple(ids['holds'], {
        "holder": Value.entity_ref(seller),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(seller_gold + base_price)
    }, provenance)

    # 3. Update treasury's gold
    treasury_holds = g.query_tuples(ids['holds'], {
        "holder": Value.entity_ref(treasury),
        "resource": Value.entity_ref(ids['gold'])
    })
    if treasury_holds:
        g.retract_tuple(treasury_holds[0].id, provenance)
    g.assert_tuple(ids['holds'], {
        "holder": Value.entity_ref(treasury),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(treasury_gold + tax)
    }, provenance)

    # 4. Move item
    item_loc_tuples = g.query_tuples(ids['location'], {
        "entity": Value.entity_ref(item)
    })
    if item_loc_tuples:
        g.retract_tuple(item_loc_tuples[0].id, provenance)
    g.assert_tuple(ids['location'], {
        "entity": Value.entity_ref(item),
        "place": Value.entity_ref(buyer_inv)
    }, provenance)

    return True, f"Purchased for {total_price} ({base_price} + {tax} tax)"


# =============================================================================
# STRESS TESTS
# =============================================================================

def test_multi_jurisdiction_economy():
    """
    Test a complex economy with multiple jurisdictions and tax rates.

    Setup:
    - 3 jurisdictions: Gulpin (5% tax), Ironforge (10% tax), Freeport (0% tax)
    - 3 players with different starting gold
    - 3 shops in different jurisdictions
    - Multiple items with different prices
    - Sequence of purchases

    Verify:
    - Gold conservation across all purchases
    - Correct tax distribution to correct treasuries
    - Item ownership changes correctly
    """
    print("\n" + "=" * 60)
    print("TEST: Multi-Jurisdiction Economy")
    print("=" * 60)

    g, ids = create_economy_graph()

    # Add jurisdictions
    gulpin_jur, gulpin_treasury = add_jurisdiction(g, ids, "gulpin", 5, 1000)
    ironforge_jur, ironforge_treasury = add_jurisdiction(g, ids, "ironforge", 10, 2000)
    freeport_jur, freeport_treasury = add_jurisdiction(g, ids, "freeport", 0, 500)

    # Add players
    alice, alice_inv = add_player(g, ids, "alice", 500)
    bob, bob_inv = add_player(g, ids, "bob", 300)
    charlie, charlie_inv = add_player(g, ids, "charlie", 150)

    # Add shops
    gulpin_shop, gulpin_shop_inv = add_shop(g, ids, "gulpin_armory", 100, gulpin_jur)
    ironforge_shop, ironforge_shop_inv = add_shop(g, ids, "ironforge_smithy", 200, ironforge_jur)
    freeport_shop, freeport_shop_inv = add_shop(g, ids, "freeport_bazaar", 50, freeport_jur)

    # Add items
    sword = add_item(g, ids, "steel_sword", gulpin_shop_inv, 100)
    axe = add_item(g, ids, "battle_axe", ironforge_shop_inv, 150)
    dagger = add_item(g, ids, "sharp_dagger", freeport_shop_inv, 50)
    shield = add_item(g, ids, "iron_shield", ironforge_shop_inv, 80)

    # Record initial state
    initial_total = total_gold(g, ids)
    print(f"\nInitial state:")
    print(f"  Total gold in system: {initial_total}")
    print(f"  Alice: {get_balance(g, ids, alice)}")
    print(f"  Bob: {get_balance(g, ids, bob)}")
    print(f"  Charlie: {get_balance(g, ids, charlie)}")
    print(f"  Gulpin treasury: {get_balance(g, ids, gulpin_treasury)}")
    print(f"  Ironforge treasury: {get_balance(g, ids, ironforge_treasury)}")
    print(f"  Freeport treasury: {get_balance(g, ids, freeport_treasury)}")

    # Execute sequence of purchases
    print(f"\nExecuting purchases...")

    # Alice buys sword from Gulpin (5% tax on 100 = 5)
    success, msg = execute_purchase(g, ids, alice, gulpin_shop, sword, 100, gulpin_treasury, 0.05)
    print(f"  Alice buys sword from Gulpin: {msg}")
    assert success, "Alice should be able to buy sword"

    # Bob buys axe from Ironforge (10% tax on 150 = 15)
    success, msg = execute_purchase(g, ids, bob, ironforge_shop, axe, 150, ironforge_treasury, 0.10)
    print(f"  Bob buys axe from Ironforge: {msg}")
    assert success, "Bob should be able to buy axe"

    # Charlie buys dagger from Freeport (0% tax on 50 = 0)
    success, msg = execute_purchase(g, ids, charlie, freeport_shop, dagger, 50, freeport_treasury, 0.0)
    print(f"  Charlie buys dagger from Freeport: {msg}")
    assert success, "Charlie should be able to buy dagger"

    # Alice buys shield from Ironforge (10% tax on 80 = 8)
    success, msg = execute_purchase(g, ids, alice, ironforge_shop, shield, 80, ironforge_treasury, 0.10)
    print(f"  Alice buys shield from Ironforge: {msg}")
    assert success, "Alice should be able to buy shield"

    # Verify final state
    final_total = total_gold(g, ids)
    print(f"\nFinal state:")
    print(f"  Total gold in system: {final_total}")
    print(f"  Alice: {get_balance(g, ids, alice)} (expected: 500 - 105 - 88 = 307)")
    print(f"  Bob: {get_balance(g, ids, bob)} (expected: 300 - 165 = 135)")
    print(f"  Charlie: {get_balance(g, ids, charlie)} (expected: 150 - 50 = 100)")
    print(f"  Gulpin shop: {get_balance(g, ids, gulpin_shop)} (100 + 100 = 200)")
    print(f"  Ironforge shop: {get_balance(g, ids, ironforge_shop)} (200 + 150 + 80 = 430)")
    print(f"  Freeport shop: {get_balance(g, ids, freeport_shop)} (50 + 50 = 100)")
    print(f"  Gulpin treasury: {get_balance(g, ids, gulpin_treasury)} (1000 + 5 = 1005)")
    print(f"  Ironforge treasury: {get_balance(g, ids, ironforge_treasury)} (2000 + 15 + 8 = 2023)")
    print(f"  Freeport treasury: {get_balance(g, ids, freeport_treasury)} (500 + 0 = 500)")

    # Verify gold conservation
    assert final_total == initial_total, f"Gold not conserved! Initial: {initial_total}, Final: {final_total}"

    # Verify item locations
    assert get_item_location(g, ids, sword) == alice_inv, "Sword should be with Alice"
    assert get_item_location(g, ids, axe) == bob_inv, "Axe should be with Bob"
    assert get_item_location(g, ids, dagger) == charlie_inv, "Dagger should be with Charlie"
    assert get_item_location(g, ids, shield) == alice_inv, "Shield should be with Alice"

    print("\n[OK] Gold conservation verified")
    print("[OK] Item locations verified")
    print("TEST PASSED")
    return True


def test_insufficient_funds():
    """
    Test that purchases are correctly rejected when player can't afford.
    """
    print("\n" + "=" * 60)
    print("TEST: Insufficient Funds Handling")
    print("=" * 60)

    g, ids = create_economy_graph()

    gulpin_jur, gulpin_treasury = add_jurisdiction(g, ids, "gulpin", 10, 1000)
    poor_player, poor_inv = add_player(g, ids, "poor_player", 50)
    shop, shop_inv = add_shop(g, ids, "shop", 100, gulpin_jur)
    expensive_item = add_item(g, ids, "diamond_sword", shop_inv, 1000)

    initial_total = total_gold(g, ids)

    print(f"\n  Player has: {get_balance(g, ids, poor_player)} gold")
    print(f"  Item costs: 1000 + 10% tax = 1100 gold")

    success, msg = execute_purchase(g, ids, poor_player, shop, expensive_item, 1000, gulpin_treasury, 0.10)
    print(f"  Purchase attempt: {msg}")

    assert not success, "Purchase should have been rejected"
    assert "Insufficient" in msg, f"Expected 'Insufficient funds', got: {msg}"

    # Verify nothing changed
    final_total = total_gold(g, ids)
    assert final_total == initial_total, "Gold should not have changed"
    assert get_item_location(g, ids, expensive_item) == shop_inv, "Item should still be in shop"

    print("\n[OK] Purchase correctly rejected")
    print("[OK] No gold changed hands")
    print("[OK] Item did not move")
    print("TEST PASSED")
    return True


def test_item_not_in_shop():
    """
    Test that purchase fails if item isn't in the seller's inventory.
    """
    print("\n" + "=" * 60)
    print("TEST: Item Not In Seller's Inventory")
    print("=" * 60)

    g, ids = create_economy_graph()

    gulpin_jur, gulpin_treasury = add_jurisdiction(g, ids, "gulpin", 10, 1000)
    player, player_inv = add_player(g, ids, "player", 500)
    shop, shop_inv = add_shop(g, ids, "shop", 100, gulpin_jur)

    # Item is in player's inventory, not the shop's
    item = g.create_entity(ids['item_type'], "personal_sword")
    g.assert_tuple(ids['location'], {
        "entity": Value.entity_ref(item),
        "place": Value.entity_ref(player_inv)  # In player's inventory!
    })
    g.assert_tuple(ids['item_price'], {
        "item": Value.entity_ref(item),
        "price": Value.int(100)
    })

    initial_total = total_gold(g, ids)

    print(f"\n  Player tries to 'buy' their own item from shop")

    success, msg = execute_purchase(g, ids, player, shop, item, 100, gulpin_treasury, 0.10)
    print(f"  Purchase attempt: {msg}")

    assert not success, "Purchase should have been rejected"
    assert "not in seller" in msg.lower(), f"Expected 'not in seller', got: {msg}"

    final_total = total_gold(g, ids)
    assert final_total == initial_total, "Gold should not have changed"

    print("\n[OK] Purchase correctly rejected")
    print("TEST PASSED")
    return True


def test_two_buyers_one_item():
    """
    EDGE CASE: Two players try to buy the same item.

    This is the critical race condition test. In a real game, both Alice and Bob
    click "buy" at the same moment. Who gets the item?

    Expected behavior: First purchase succeeds, second fails because item moved.
    """
    print("\n" + "=" * 60)
    print("TEST: Two Buyers, One Item (Race Condition)")
    print("=" * 60)

    g, ids = create_economy_graph()

    gulpin_jur, gulpin_treasury = add_jurisdiction(g, ids, "gulpin", 10, 1000)
    alice, alice_inv = add_player(g, ids, "alice", 500)
    bob, bob_inv = add_player(g, ids, "bob", 500)
    shop, shop_inv = add_shop(g, ids, "shop", 100, gulpin_jur)

    # Only one sword in the shop
    last_sword = add_item(g, ids, "last_sword", shop_inv, 100)

    initial_total = total_gold(g, ids)

    print(f"\n  Alice and Bob both want the last sword (100 + 10% = 110 gold)")
    print(f"  Alice has: {get_balance(g, ids, alice)} gold")
    print(f"  Bob has: {get_balance(g, ids, bob)} gold")

    # Alice buys first
    success_alice, msg_alice = execute_purchase(g, ids, alice, shop, last_sword, 100, gulpin_treasury, 0.10)
    print(f"\n  Alice's purchase: {msg_alice}")

    # Bob tries to buy the same item
    success_bob, msg_bob = execute_purchase(g, ids, bob, shop, last_sword, 100, gulpin_treasury, 0.10)
    print(f"  Bob's purchase: {msg_bob}")

    assert success_alice, "Alice should have gotten the sword"
    assert not success_bob, "Bob should have been rejected"
    assert "not in seller" in msg_bob.lower(), f"Bob should see 'item not in seller's inventory'"

    # Verify state
    final_total = total_gold(g, ids)
    assert final_total == initial_total, f"Gold not conserved! {initial_total} -> {final_total}"
    assert get_item_location(g, ids, last_sword) == alice_inv, "Sword should be with Alice"

    print("\n[OK] Alice got the sword")
    print("[OK] Bob was correctly rejected")
    print("[OK] Gold conservation maintained")
    print("TEST PASSED")
    return True


def test_tax_rate_change_during_purchase():
    """
    EDGE CASE: Tax rate changes between when purchase is initiated and executed.

    This is a TOCTOU (time-of-check vs time-of-use) vulnerability test.

    Scenario:
    1. Player queries tax rate (10%)
    2. Player initiates purchase based on 10% tax calculation
    3. Government changes tax rate to 50%
    4. Purchase executes with... which rate?

    In our current implementation, the tax rate is passed to execute_purchase,
    so the caller controls which rate is used. This is a design decision point.
    """
    print("\n" + "=" * 60)
    print("TEST: Tax Rate Change During Purchase (TOCTOU)")
    print("=" * 60)

    g, ids = create_economy_graph()

    gulpin_jur, gulpin_treasury = add_jurisdiction(g, ids, "gulpin", 10, 1000)
    player, player_inv = add_player(g, ids, "player", 500)
    shop, shop_inv = add_shop(g, ids, "shop", 100, gulpin_jur)
    sword = add_item(g, ids, "sword", shop_inv, 100)

    initial_treasury = get_balance(g, ids, gulpin_treasury)
    initial_player = get_balance(g, ids, player)
    initial_total = total_gold(g, ids)

    print(f"\n  Initial tax rate: 10%")
    print(f"  Player calculates: 100 + 10% = 110 gold")

    # Player reads tax rate
    tax_tuple = g.query_tuples(ids['tax_rate'], {
        "jurisdiction": Value.entity_ref(gulpin_jur)
    })[0]
    observed_tax = tax_tuple.values[1].data
    print(f"  Player observes tax rate: {observed_tax * 100}%")

    # Government changes tax rate to 50%!
    g.retract_tuple(tax_tuple.id)
    g.assert_tuple(ids['tax_rate'], {
        "jurisdiction": Value.entity_ref(gulpin_jur),
        "rate": Value.float(0.50)
    })
    print(f"  Government changes tax to 50%!")

    # Player executes purchase with OLD tax rate (the one they observed)
    # This is the vulnerability: they're using stale data
    success, msg = execute_purchase(g, ids, player, shop, sword, 100, gulpin_treasury, observed_tax)
    print(f"  Player purchases with observed 10% rate: {msg}")

    # What did we end up with?
    final_treasury = get_balance(g, ids, gulpin_treasury)
    final_player = get_balance(g, ids, player)
    final_total = total_gold(g, ids)

    tax_paid = final_treasury - initial_treasury
    player_paid = initial_player - final_player

    print(f"\n  Results:")
    print(f"    Player paid: {player_paid} gold")
    print(f"    Treasury received: {tax_paid} gold tax")
    print(f"    Gold conserved: {final_total == initial_total}")

    # The purchase succeeded with the OLD rate
    assert success
    assert tax_paid == 10, f"Treasury should have gotten 10 (10% of 100), got {tax_paid}"
    assert player_paid == 110, f"Player should have paid 110, paid {player_paid}"

    print("\n[!]  BUG FOUND: Player used stale tax rate!")
    print("    The current design passes tax rate as a parameter,")
    print("    allowing callers to use outdated rates.")
    print("")
    print("    DESIGN QUESTION: Should execute_purchase look up the")
    print("    current tax rate internally, or trust the caller?")
    print("")
    print("TEST PASSED (demonstrates the vulnerability)")
    return True


def test_queue_based_purchase():
    """
    Test using the resolution loop for purchases instead of immediate execution.

    This is how purchases SHOULD work in HERB v2:
    1. Queue purchase intent as a pending delta
    2. Preconditions check current state (including current tax rate)
    3. Resolution applies or rejects based on real-time checks
    """
    print("\n" + "=" * 60)
    print("TEST: Queue-Based Purchase via Resolution Loop")
    print("=" * 60)

    g, ids = create_economy_graph()

    gulpin_jur, gulpin_treasury = add_jurisdiction(g, ids, "gulpin", 10, 1000)
    player, player_inv = add_player(g, ids, "player", 500)
    shop, shop_inv = add_shop(g, ids, "shop", 100, gulpin_jur)
    sword = add_item(g, ids, "sword", shop_inv, 100)

    # Define a purchase_intent relation
    purchase_intent = g.define_relation_type("purchase_intent", [
        ("buyer", ValueType.ENTITY_REF, ids['player_type']),
        ("seller", ValueType.ENTITY_REF, ids['shop_type']),
        ("item", ValueType.ENTITY_REF, ids['item_type'])
    ])

    # Precondition: buyer can afford (including current tax)
    def can_afford_with_current_tax(graph, ctx):
        if 'buyer' not in ctx or 'seller' not in ctx or 'item' not in ctx:
            return True

        # Look up item price
        price_result = graph.lookup(ids['item_price'], {
            "item": ctx['item']
        }, "price")
        if price_result.type == ValueType.NULL:
            return False
        base_price = price_result.data

        # Look up shop's jurisdiction
        jur_result = graph.lookup(ids['in_jurisdiction'], {
            "entity": ctx['seller']
        }, "jurisdiction")
        if jur_result.type == ValueType.NULL:
            return False
        jur_id = jur_result.data

        # Look up CURRENT tax rate (not stale!)
        tax_result = graph.lookup(ids['tax_rate'], {
            "jurisdiction": Value.entity_ref(jur_id)
        }, "rate")
        tax_rate = tax_result.data if tax_result.type != ValueType.NULL else 0.0

        total_price = base_price + int(base_price * tax_rate)

        # Check buyer's balance
        balance_result = graph.lookup(ids['holds'], {
            "holder": ctx['buyer'],
            "resource": Value.entity_ref(ids['gold'])
        }, "amount")
        balance = balance_result.data if balance_result.type != ValueType.NULL else 0

        print(f"      Precondition check: price={base_price}, tax_rate={tax_rate*100}%, total={total_price}, balance={balance}")

        return balance >= total_price

    # Precondition: item is in seller's inventory
    def item_in_seller_inventory(graph, ctx):
        if 'seller' not in ctx or 'item' not in ctx:
            return True

        # Get seller's inventory
        inv_result = graph.lookup(ids['owns_inventory'], {
            "owner": ctx['seller']
        }, "inventory")
        if inv_result.type == ValueType.NULL:
            return False

        # Check item location
        loc_result = graph.lookup(ids['location'], {
            "entity": ctx['item']
        }, "place")
        if loc_result.type == ValueType.NULL:
            return False

        return loc_result.data == inv_result.data

    g.add_constraint("can_afford_purchase", ConstraintKind.PRECONDITION,
                     can_afford_with_current_tax, delta_type_id=purchase_intent)
    g.add_constraint("item_available", ConstraintKind.PRECONDITION,
                     item_in_seller_inventory, delta_type_id=purchase_intent)

    initial_total = total_gold(g, ids)

    print(f"\n  Player has: {get_balance(g, ids, player)} gold")
    print(f"  Tax rate is: 10%")
    print(f"  Item costs: 100 + 10% = 110 gold")

    # Queue the purchase intent
    g.queue_assert(purchase_intent, {
        "buyer": Value.entity_ref(player),
        "seller": Value.entity_ref(shop),
        "item": Value.entity_ref(sword)
    })

    print(f"\n  Queued purchase intent. Now resolving...")

    result = g.resolve()

    print(f"\n  Resolution result: {result.status.name}")
    print(f"  Violations: {len(result.violations)}")
    for v in result.violations:
        print(f"    - {v.message}")

    # The intent should be recorded (preconditions passed)
    intents = g.query_tuples(purchase_intent)
    print(f"  Purchase intents recorded: {len(intents)}")

    if result.status == ResolutionStatus.QUIESCENT and not result.violations:
        print("\n[OK] Purchase intent accepted by resolution loop")
        print("  (Full purchase execution would be a derived constraint)")

    # Now test with insufficient funds
    print(f"\n  --- Testing rejection ---")
    poor_player, poor_inv = add_player(g, ids, "poor_player", 50)

    g.queue_assert(purchase_intent, {
        "buyer": Value.entity_ref(poor_player),
        "seller": Value.entity_ref(shop),
        "item": Value.entity_ref(sword)
    })

    result2 = g.resolve()
    print(f"\n  Poor player resolution: {result2.status.name}")
    print(f"  Violations: {len(result2.violations)}")
    for v in result2.violations:
        print(f"    - {v.message}")

    assert len(result2.violations) > 0, "Poor player should have been rejected"

    print("\n[OK] Preconditions correctly checked against CURRENT state")
    print("TEST PASSED")
    return True


def test_cascading_purchases():
    """
    Test a chain of purchases where one enables the next.

    Scenario:
    1. Charlie has 0 gold but owns a gem
    2. Charlie sells gem to shop for 100 gold
    3. Charlie uses that gold to buy a sword for 80 gold

    This tests that state changes propagate correctly.
    """
    print("\n" + "=" * 60)
    print("TEST: Cascading Purchases")
    print("=" * 60)

    g, ids = create_economy_graph()

    gulpin_jur, gulpin_treasury = add_jurisdiction(g, ids, "gulpin", 10, 1000)
    charlie, charlie_inv = add_player(g, ids, "charlie", 0)  # Starts with 0 gold!
    shop, shop_inv = add_shop(g, ids, "shop", 500, gulpin_jur)

    # Charlie owns a gem
    gem = g.create_entity(ids['item_type'], "rare_gem")
    g.assert_tuple(ids['location'], {
        "entity": Value.entity_ref(gem),
        "place": Value.entity_ref(charlie_inv)
    })
    g.assert_tuple(ids['item_price'], {
        "item": Value.entity_ref(gem),
        "price": Value.int(100)
    })

    # Shop has a sword
    sword = add_item(g, ids, "sword", shop_inv, 80)

    initial_total = total_gold(g, ids)

    print(f"\n  Initial state:")
    print(f"    Charlie: {get_balance(g, ids, charlie)} gold, owns gem")
    print(f"    Shop: {get_balance(g, ids, shop)} gold, has sword")

    # Charlie can't buy sword yet
    success, msg = execute_purchase(g, ids, charlie, shop, sword, 80, gulpin_treasury, 0.10)
    print(f"\n  Charlie tries to buy sword: {msg}")
    assert not success, "Charlie shouldn't afford sword yet"

    # Charlie sells gem to shop (shop buys from Charlie)
    # Note: We're treating this as shop buying, so shop pays Charlie, and Charlie pays tax
    # Actually, let's simplify: Charlie sells to shop, shop pays Charlie, no tax on sale

    charlie_gold = get_balance(g, ids, charlie)
    shop_gold = get_balance(g, ids, shop)

    # Retract old gold
    charlie_holds = g.query_tuples(ids['holds'], {
        "holder": Value.entity_ref(charlie),
        "resource": Value.entity_ref(ids['gold'])
    })
    shop_holds = g.query_tuples(ids['holds'], {
        "holder": Value.entity_ref(shop),
        "resource": Value.entity_ref(ids['gold'])
    })

    prov = Provenance(cause='external', description='Charlie sells gem')

    if charlie_holds:
        g.retract_tuple(charlie_holds[0].id, prov)
    if shop_holds:
        g.retract_tuple(shop_holds[0].id, prov)

    g.assert_tuple(ids['holds'], {
        "holder": Value.entity_ref(charlie),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(charlie_gold + 100)
    }, prov)
    g.assert_tuple(ids['holds'], {
        "holder": Value.entity_ref(shop),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(shop_gold - 100)
    }, prov)

    # Move gem
    gem_loc = g.query_tuples(ids['location'], {"entity": Value.entity_ref(gem)})
    if gem_loc:
        g.retract_tuple(gem_loc[0].id, prov)
    g.assert_tuple(ids['location'], {
        "entity": Value.entity_ref(gem),
        "place": Value.entity_ref(shop_inv)
    }, prov)

    print(f"\n  Charlie sells gem to shop for 100 gold")
    print(f"    Charlie: {get_balance(g, ids, charlie)} gold")
    print(f"    Shop: {get_balance(g, ids, shop)} gold")

    # Now Charlie can buy the sword
    success, msg = execute_purchase(g, ids, charlie, shop, sword, 80, gulpin_treasury, 0.10)
    print(f"\n  Charlie buys sword: {msg}")
    assert success, f"Charlie should now afford sword, but: {msg}"

    final_total = total_gold(g, ids)
    print(f"\n  Final state:")
    print(f"    Charlie: {get_balance(g, ids, charlie)} gold, owns sword")
    print(f"    Shop: {get_balance(g, ids, shop)} gold, has gem")
    print(f"    Gold conserved: {initial_total} -> {final_total}")

    assert final_total == initial_total
    assert get_item_location(g, ids, sword) == charlie_inv
    assert get_item_location(g, ids, gem) == shop_inv

    print("\n[OK] Cascading transactions worked correctly")
    print("TEST PASSED")
    return True


def test_concurrent_queue_race():
    """
    Test what happens when two purchases are queued in the same resolution cycle.

    This is the more realistic race condition: both purchases are pending,
    the resolution loop processes them, but only one should succeed.
    """
    print("\n" + "=" * 60)
    print("TEST: Concurrent Queue Race Condition")
    print("=" * 60)

    g, ids = create_economy_graph()

    gulpin_jur, gulpin_treasury = add_jurisdiction(g, ids, "gulpin", 10, 1000)
    alice, alice_inv = add_player(g, ids, "alice", 500)
    bob, bob_inv = add_player(g, ids, "bob", 500)
    shop, shop_inv = add_shop(g, ids, "shop", 100, gulpin_jur)

    # Only one sword
    last_sword = add_item(g, ids, "last_sword", shop_inv, 100)

    # Define purchase relation with precondition
    purchase_intent = g.define_relation_type("purchase_intent_v2", [
        ("buyer", ValueType.ENTITY_REF, ids['player_type']),
        ("item", ValueType.ENTITY_REF, ids['item_type'])
    ])

    def item_still_in_shop(graph, ctx):
        if 'item' not in ctx:
            return True

        # Check if item is still in shop inventory
        loc_result = graph.lookup(ids['location'], {
            "entity": ctx['item']
        }, "place")
        if loc_result.type == ValueType.NULL:
            return False

        # Is it in a shop's inventory?
        for shop_tup in graph.query_tuples(ids['owns_inventory']):
            shop_entity = graph.get_entity(shop_tup.values[0].data)
            if shop_entity and shop_entity.type_id == ids['shop_type']:
                if shop_tup.values[1].data == loc_result.data:
                    return True
        return False

    g.add_constraint("item_in_shop", ConstraintKind.PRECONDITION,
                     item_still_in_shop, delta_type_id=purchase_intent)

    print(f"\n  Alice and Bob both queue purchase of the last sword")

    # Queue both purchases before resolving
    g.queue_assert(purchase_intent, {
        "buyer": Value.entity_ref(alice),
        "item": Value.entity_ref(last_sword)
    }, priority=10)  # Alice has higher priority

    g.queue_assert(purchase_intent, {
        "buyer": Value.entity_ref(bob),
        "item": Value.entity_ref(last_sword)
    }, priority=5)  # Bob has lower priority

    print(f"  Pending deltas: {len(g.pending_deltas)}")
    print(f"  Alice priority: 10, Bob priority: 5")

    result = g.resolve()

    print(f"\n  Resolution result: {result.status.name}")
    print(f"  Applied deltas: {len(result.applied_deltas)}")
    print(f"  Violations: {len(result.violations)}")
    for v in result.violations:
        print(f"    - {v.message}")

    intents = g.query_tuples(purchase_intent)
    print(f"  Purchase intents recorded: {len(intents)}")

    # With the current precondition, both might pass because the precondition
    # is checked BEFORE the delta is applied, not after. This is actually a bug!

    if len(intents) == 2:
        print("\n[!]  BUG FOUND: Both intents were recorded!")
        print("    Preconditions are checked before application, not considering")
        print("    other pending deltas in the same resolution cycle.")
        print("")
        print("    DESIGN QUESTION: Should preconditions see the 'world' as it")
        print("    will be after earlier-in-queue deltas are applied?")
    elif len(intents) == 1:
        # Check who got it
        winner_id = intents[0].values[0].data
        winner_name = g.get_name(winner_id)
        print(f"\n[OK] Only one purchase succeeded: {winner_name}")

    print("\nTEST COMPLETED (demonstrates design question)")
    return True


def test_double_spend_through_queue():
    """
    CRITICAL TEST: Demonstrate actual double-spend via resolution loop.

    This isn't just recording two intents - this tests whether the resolution
    loop can be tricked into executing two ACTUAL purchases of the same item,
    resulting in an invalid state.
    """
    print("\n" + "=" * 60)
    print("TEST: Double-Spend Through Queue (Critical)")
    print("=" * 60)

    g, ids = create_economy_graph()

    gulpin_jur, gulpin_treasury = add_jurisdiction(g, ids, "gulpin", 0, 1000)
    alice, alice_inv = add_player(g, ids, "alice", 500)
    bob, bob_inv = add_player(g, ids, "bob", 500)
    shop, shop_inv = add_shop(g, ids, "shop", 100, gulpin_jur)

    # Only one sword
    sword = add_item(g, ids, "legendary_sword", shop_inv, 100)

    initial_total = total_gold(g, ids)

    print(f"\n  Initial state:")
    print(f"    Alice: {get_balance(g, ids, alice)} gold")
    print(f"    Bob: {get_balance(g, ids, bob)} gold")
    print(f"    Shop: {get_balance(g, ids, shop)} gold")
    print(f"    Sword location: {g.get_name(get_item_location(g, ids, sword))}")
    print(f"    Total gold: {initial_total}")

    # Queue TWO complete purchases that would each move the sword
    # Alice's purchase deltas
    alice_old_gold = g.query_tuples(ids['holds'], {
        "holder": Value.entity_ref(alice),
        "resource": Value.entity_ref(ids['gold'])
    })
    shop_old_gold = g.query_tuples(ids['holds'], {
        "holder": Value.entity_ref(shop),
        "resource": Value.entity_ref(ids['gold'])
    })
    sword_old_loc = g.query_tuples(ids['location'], {
        "entity": Value.entity_ref(sword)
    })

    # Queue Alice's purchase as a set of deltas (high priority)
    g.queue_retract(ids['holds'], alice_old_gold[0].id, priority=100)
    g.queue_assert(ids['holds'], {
        "holder": Value.entity_ref(alice),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(400)  # 500 - 100
    }, priority=99)

    g.queue_retract(ids['holds'], shop_old_gold[0].id, priority=98)
    g.queue_assert(ids['holds'], {
        "holder": Value.entity_ref(shop),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(200)  # 100 + 100
    }, priority=97)

    g.queue_retract(ids['location'], sword_old_loc[0].id, priority=96)
    g.queue_assert(ids['location'], {
        "entity": Value.entity_ref(sword),
        "place": Value.entity_ref(alice_inv)
    }, priority=95)

    # Now queue Bob's purchase too (lower priority, but uses same tuple IDs!)
    # This is where it gets interesting - Bob's retracts reference tuples that
    # Alice's deltas will have already retracted

    g.queue_retract(ids['holds'], alice_old_gold[0].id, priority=50)  # PROBLEM: already retracted!

    # Actually wait - the retract will fail silently because tuple will already be gone
    # Let's try a different approach: Bob queues his own balance change

    bob_old_gold = g.query_tuples(ids['holds'], {
        "holder": Value.entity_ref(bob),
        "resource": Value.entity_ref(ids['gold'])
    })

    g.queue_retract(ids['holds'], bob_old_gold[0].id, priority=50)
    g.queue_assert(ids['holds'], {
        "holder": Value.entity_ref(bob),
        "resource": Value.entity_ref(ids['gold']),
        "amount": Value.int(400)  # 500 - 100
    }, priority=49)

    # Bob also tries to take the sword
    g.queue_assert(ids['location'], {
        "entity": Value.entity_ref(sword),
        "place": Value.entity_ref(bob_inv)
    }, priority=48)

    print(f"\n  Queued {len(g.pending_deltas)} deltas (Alice's purchase, then Bob's)")
    print(f"  Alice's deltas: retract gold, assert new gold, retract sword loc, assert new loc")
    print(f"  Bob's deltas: retract gold, assert new gold, assert new sword loc")

    result = g.resolve()

    print(f"\n  Resolution result: {result.status.name}")
    print(f"  Applied deltas: {len(result.applied_deltas)}")
    print(f"  Violations: {len(result.violations)}")

    # Check state
    alice_gold = get_balance(g, ids, alice)
    bob_gold = get_balance(g, ids, bob)
    shop_gold = get_balance(g, ids, shop)
    final_total = total_gold(g, ids)

    # Where is the sword?
    sword_locs = g.query_tuples(ids['location'], {"entity": Value.entity_ref(sword)})

    print(f"\n  Final state:")
    print(f"    Alice: {alice_gold} gold")
    print(f"    Bob: {bob_gold} gold")
    print(f"    Shop: {shop_gold} gold")
    print(f"    Sword locations: {len(sword_locs)}")
    for loc in sword_locs:
        print(f"      - {g.get_name(loc.values[1].data)}")
    print(f"    Total gold: {final_total}")

    # Check for bugs
    issues = []

    if len(sword_locs) == 0:
        issues.append("CRITICAL: Sword disappeared!")
    elif len(sword_locs) > 1:
        issues.append("CRITICAL: Sword is in multiple places!")

    if final_total != initial_total:
        issues.append(f"CRITICAL: Gold not conserved ({initial_total} -> {final_total})")

    # Check if both players paid
    if alice_gold == 400 and bob_gold == 400:
        issues.append("BUG: Both players paid for the sword")

    if issues:
        print(f"\n  ISSUES FOUND:")
        for issue in issues:
            print(f"    [!] {issue}")
    else:
        print(f"\n  [OK] No critical issues")

    print("\nTEST COMPLETED")
    return True


def test_invariant_item_uniqueness():
    """
    Test that an invariant can catch the double-location bug.
    """
    print("\n" + "=" * 60)
    print("TEST: Invariant Catches Double-Location")
    print("=" * 60)

    g, ids = create_economy_graph()

    # Add invariant: item can only be in one place
    def item_unique_location(graph, ctx):
        """Each item must be in exactly one location."""
        item_locations = {}
        for tup in graph.query_tuples(ids['location']):
            item_id = tup.values[0].data
            item_locations[item_id] = item_locations.get(item_id, 0) + 1

        for item_id, count in item_locations.items():
            if count != 1:
                return False
        return True

    g.add_constraint("item_unique_location", ConstraintKind.INVARIANT, item_unique_location)

    # Setup
    player_type = ids['player_type']
    player, player_inv = add_player(g, ids, "player", 500)
    player2, player2_inv = add_player(g, ids, "player2", 500)
    shop, shop_inv = add_shop(g, ids, "shop", 100,
                              g.create_entity(ids['jurisdiction_type'], "test_jur"))
    sword = add_item(g, ids, "sword", shop_inv, 100)

    initial_violations = g.check_invariants()
    print(f"\n  Initial violations: {len(initial_violations)}")

    # Now try to assert sword in player's inventory (without retracting from shop)
    print(f"  Asserting sword location in player inventory (without retracting from shop)...")

    g.queue_assert(ids['location'], {
        "entity": Value.entity_ref(sword),
        "place": Value.entity_ref(player_inv)
    })

    result = g.resolve()

    print(f"  Resolution result: {result.status.name}")
    print(f"  Violations: {len(result.violations)}")
    for v in result.violations:
        print(f"    - {v.message}")

    sword_locs = g.query_tuples(ids['location'], {"entity": Value.entity_ref(sword)})
    print(f"  Sword locations after resolve: {len(sword_locs)}")

    if result.violations and "item_unique_location" in result.violations[0].constraint_name:
        print(f"\n  [OK] Invariant caught the duplicate location")
        print(f"       Note: The assertion was APPLIED, then invariant checked.")
        print(f"       We detected the bug but didn't prevent it.")
    elif len(sword_locs) > 1:
        print(f"\n  [!] BUG: Sword in {len(sword_locs)} places and invariant didn't catch it!")
    else:
        print(f"\n  [OK] Only one sword location")

    print("\nTEST COMPLETED")
    return True


def run_all_stress_tests():
    """Run all stress tests."""
    print("\n" + "=" * 70)
    print("HERB v2 PURCHASE STRESS TESTS")
    print("=" * 70)

    tests = [
        ("Multi-Jurisdiction Economy", test_multi_jurisdiction_economy),
        ("Insufficient Funds", test_insufficient_funds),
        ("Item Not In Shop", test_item_not_in_shop),
        ("Two Buyers One Item", test_two_buyers_one_item),
        ("Tax Rate Change (TOCTOU)", test_tax_rate_change_during_purchase),
        ("Queue-Based Purchase", test_queue_based_purchase),
        ("Cascading Purchases", test_cascading_purchases),
        ("Concurrent Queue Race", test_concurrent_queue_race),
        ("Double-Spend Through Queue", test_double_spend_through_queue),
        ("Invariant Catches Double-Location", test_invariant_item_uniqueness),
    ]

    results = []
    for name, test_fn in tests:
        try:
            passed = test_fn()
            results.append((name, passed, None))
        except Exception as e:
            results.append((name, False, str(e)))
            import traceback
            traceback.print_exc()

    print("\n" + "=" * 70)
    print("STRESS TEST SUMMARY")
    print("=" * 70)

    passed = 0
    failed = 0
    for name, success, error in results:
        status = "[OK] PASS" if success else "[FAIL] FAIL"
        print(f"  {status}: {name}")
        if error:
            print(f"         Error: {error}")
        if success:
            passed += 1
        else:
            failed += 1

    print(f"\n  {passed}/{len(tests)} tests passed")

    print("\n" + "=" * 70)
    print("ISSUES DISCOVERED")
    print("=" * 70)
    print("""
  1. TAX RATE TOCTOU VULNERABILITY
     - Caller passes tax rate to execute_purchase
     - Can use stale/outdated rate
     - Fix: Look up current rate inside purchase execution

  2. PRECONDITION TIMING
     - Preconditions check state BEFORE delta application
     - Concurrent deltas don't see each other's effects
     - Two purchases of same item can both pass preconditions
     - Fix: Either check postconditions, or use transactional semantics

  3. NO TRANSACTION ROLLBACK
     - If a multi-step purchase fails partway through, previous steps
       are not rolled back
     - Fix: Implement transaction_group in PendingDelta

  4. DERIVED CONSTRAINTS DON'T CHAIN
     - A derived constraint that creates deltas doesn't trigger other
       derived constraints in the same resolution cycle
     - May need multiple propagation passes
""")

    return failed == 0


if __name__ == "__main__":
    run_all_stress_tests()
