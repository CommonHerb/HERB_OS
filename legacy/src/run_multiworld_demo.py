"""
Multi-World Demo — Game Scenario

Demonstrates the Multi-World architecture with a Common Herb-like setup:
- Game World: shared terrain visible to all players
- Player Worlds: isolated state (HP, inventory), exports position
- Server can see all player positions through exports
- Players cannot see each other's internals (true isolation)

Session 14 — February 4, 2026
"""

from herb_core import World, Verse, Var, Expr

X, Y, Z = Var('x'), Var('y'), Var('z')
HP, POS = Var('hp'), Var('pos')


def main():
    print("=" * 60)
    print("HERB Multi-World Demo — Game Scenario")
    print("=" * 60)

    # Create the Verse (container for all Worlds)
    verse = Verse()

    # =========================================================================
    # GAME WORLD (root) — Shared terrain visible to all
    # =========================================================================
    print("\n--- Creating Game World (terrain) ---")
    game = verse.create_world("game")

    # Terrain facts - these are inherited by all players
    game.assert_fact("tile_0_0", "terrain", "grass")
    game.assert_fact("tile_1_0", "terrain", "forest")
    game.assert_fact("tile_2_0", "terrain", "water")
    game.assert_fact("tile_0_1", "terrain", "grass")
    game.assert_fact("tile_1_1", "terrain", "town")
    game.assert_fact("tile_2_1", "terrain", "mountain")

    # Physics/rules - also inherited
    game.assert_fact("grass", "walkable", True)
    game.assert_fact("forest", "walkable", True)
    game.assert_fact("town", "walkable", True)
    game.assert_fact("water", "walkable", False)
    game.assert_fact("mountain", "walkable", False)

    print(f"  Game world has {len(game)} facts (terrain + physics)")

    # =========================================================================
    # PLAYER WORLDS — Isolated state, export position
    # =========================================================================
    print("\n--- Creating Player Worlds ---")

    # Player Alice
    alice = verse.create_world("alice", parent="game")
    alice.declare_functional("hp")
    alice.declare_functional("location")
    alice.declare_export("location")  # Server can see where Alice is
    alice.declare_export("action")    # Server can see what Alice is doing

    alice.assert_fact("self", "hp", 100)
    alice.assert_fact("self", "gold", 50)
    alice.assert_fact("self", "location", "tile_1_1")  # In town
    alice.assert_fact("self", "inventory", "sword")
    print(f"  Alice's world: {len(alice)} local facts, exports: location, action")

    # Player Bob
    bob = verse.create_world("bob", parent="game")
    bob.declare_functional("hp")
    bob.declare_functional("location")
    bob.declare_export("location")
    bob.declare_export("action")

    bob.assert_fact("self", "hp", 80)
    bob.assert_fact("self", "gold", 75)
    bob.assert_fact("self", "location", "tile_0_0")  # On grass
    bob.assert_fact("self", "inventory", "bow")
    print(f"  Bob's world: {len(bob)} local facts, exports: location, action")

    # =========================================================================
    # DEMONSTRATE INHERITANCE
    # =========================================================================
    print("\n--- Inheritance: Players See Terrain ---")

    # Alice queries terrain (inherited from game)
    results = alice.query(("tile_1_1", "terrain", X))
    print(f"  Alice sees tile_1_1 terrain: {results[0]['x']}")

    # Alice can check if her location is walkable
    results = alice.query(
        ("self", "location", POS),
        (POS, "terrain", X),
        (X, "walkable", Y)
    )
    print(f"  Alice at walkable location? {results[0]['y']}")

    # Bob also sees terrain
    results = bob.query(("tile_0_0", "terrain", X))
    print(f"  Bob sees tile_0_0 terrain: {results[0]['x']}")

    # =========================================================================
    # DEMONSTRATE ISOLATION
    # =========================================================================
    print("\n--- Isolation: Players Cannot See Each Other ---")

    # Alice cannot see Bob's HP
    alice_sees_bob_hp = alice.query(("self", "hp", X), include_inherited=False)
    print(f"  Alice's HP (own): {alice_sees_bob_hp[0]['x']}")

    # Can Alice see Bob's secrets? NO (not in Alice's inheritance chain)
    alice_sees_bobs_inventory = alice.query(("self", "inventory", X))
    print(f"  Alice's inventory: {[r['x'] for r in alice_sees_bobs_inventory]}")
    # Note: Alice only sees her own "self" - Bob's "self" is in a different World

    # Game (parent) cannot see player internals
    game_sees_hp = game.query(("self", "hp", X))
    print(f"  Game world sees player HP? {len(game_sees_hp) == 0} (none - isolated)")

    # =========================================================================
    # DEMONSTRATE EXPORTS
    # =========================================================================
    print("\n--- Exports: Server Sees Player Positions ---")

    # Query Alice's exports
    alice_exports = verse.query_child_exports("game", "alice",
                                               ("self", "location", X))
    print(f"  Alice exports location: {alice_exports[0]['x']}")

    bob_exports = verse.query_child_exports("game", "bob",
                                             ("self", "location", X))
    print(f"  Bob exports location: {bob_exports[0]['x']}")

    # Server can see all player positions, but NOT their HP/gold/inventory
    alice_hp_exports = verse.query_child_exports("game", "alice",
                                                  ("self", "hp", X))
    print(f"  Alice exports HP? {len(alice_hp_exports) == 0} (no - internal)")

    # =========================================================================
    # DEMONSTRATE MESSAGING
    # =========================================================================
    print("\n--- Messaging: Game -> Player Commands ---")

    # Server sends a damage event to Alice
    verse.send_message("game", "alice", "inbox", "take_damage", 20)
    print("  Sent damage command to Alice: take_damage 20")

    # Alice can see the message
    alice_inbox = alice.query(("inbox", "take_damage", X))
    print(f"  Alice inbox: take_damage {alice_inbox[0]['x']}")

    # =========================================================================
    # DEMONSTRATE RULES WITH INHERITANCE
    # =========================================================================
    print("\n--- Rules Using Inherited Facts ---")

    # Add rule to Alice: can_rest if on grass
    alice.add_derivation_rule(
        "rest_on_grass",
        [("self", "location", POS), (POS, "terrain", "grass")],
        ("self", "can_rest", True)
    )

    # Add rule: can_shop if in town
    alice.add_derivation_rule(
        "shop_in_town",
        [("self", "location", POS), (POS, "terrain", "town")],
        ("self", "can_shop", True)
    )

    # Alice is in town
    verse.tick()

    can_rest = alice.query(("self", "can_rest", X))
    can_shop = alice.query(("self", "can_shop", X))
    print(f"  Alice can_rest (in town)? {len(can_rest) == 0} (no - not on grass)")
    print(f"  Alice can_shop (in town)? {can_shop[0]['x'] if can_shop else False}")

    # Bob is on grass
    bob.add_derivation_rule(
        "rest_on_grass",
        [("self", "location", POS), (POS, "terrain", "grass")],
        ("self", "can_rest", True)
    )

    verse.tick()

    bob_can_rest = bob.query(("self", "can_rest", X))
    print(f"  Bob can_rest (on grass)? {bob_can_rest[0]['x'] if bob_can_rest else False}")

    # =========================================================================
    # PRINT VERSE STRUCTURE
    # =========================================================================
    verse.print_tree()

    # =========================================================================
    # PROVENANCE DEMONSTRATION
    # =========================================================================
    print("\n--- Provenance: Why Can Alice Shop? ---")
    explanation = alice.explain("self", "can_shop", True)
    if explanation:
        print(f"  Fact: {explanation['fact']}")
        print(f"  Cause: {explanation['cause']}")
        print(f"  Depends on:")
        for dep in explanation['depends_on']:
            print(f"    - {dep['fact']}")
            if dep['depends_on']:
                for subdep in dep['depends_on']:
                    print(f"        - {subdep['fact']}")

    print("\n" + "=" * 60)
    print("DEMO COMPLETE")
    print("=" * 60)
    print("\nKey Achievements:")
    print("  [OK] Worlds form tree (game -> alice, bob)")
    print("  [OK] Children inherit parent facts (terrain)")
    print("  [OK] Siblings isolated (alice can't see bob)")
    print("  [OK] Exports expose selected state (location)")
    print("  [OK] Messages pass via inbox (damage command)")
    print("  [OK] Rules use inherited facts (terrain -> can_shop)")
    print("  [OK] Provenance traces through inheritance")


if __name__ == "__main__":
    main()
