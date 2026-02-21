"""
HERB Combat — Live Loop with EPHEMERAL Commands

Common Herb combat ported to the live text adventure:
- EPHEMERAL commands (attack)
- FUNCTIONAL hp (changes over time)
- Aggregation for equipment bonuses
- Death triggers loot transfer
- Runs across multiple ticks

Session 14.5 — February 4, 2026
"""

import time
from herb_core import World, Var, Expr, AggregateExpr, NotExistsExpr

X, Y, Z = Var('x'), Var('y'), Var('z')
LOC, DIR, DEST = Var('loc'), Var('dir'), Var('dest')
TARGET, DMG, HP = Var('target'), Var('dmg'), Var('hp')
ITEM, BONUS, SLOT = Var('item'), Var('bonus'), Var('slot')
ATTACKER, VICTIM = Var('attacker'), Var('victim')


def bootstrap_world() -> World:
    """Create world with combat system."""
    world = World("combat_adventure")

    # =========================================================================
    # RELATION DECLARATIONS
    # =========================================================================
    world.declare_functional("location")
    world.declare_functional("hp")
    world.declare_functional("max_hp")
    world.declare_functional("base_damage")
    world.declare_functional("gold")
    world.declare_ephemeral("command")
    world.declare_functional("pending_damage")  # Damage to be applied (one value per target)

    # =========================================================================
    # ROOMS
    # =========================================================================
    world.assert_fact("entrance", "is_a", "room")
    world.assert_fact("entrance", "description", "a torch-lit entrance hall")

    world.assert_fact("corridor", "is_a", "room")
    world.assert_fact("corridor", "description", "a long dark corridor")

    world.assert_fact("goblin_den", "is_a", "room")
    world.assert_fact("goblin_den", "description", "a foul-smelling cave with bones scattered about")

    world.assert_fact("armory", "is_a", "room")
    world.assert_fact("armory", "description", "racks of weapons line the walls")

    # Connections
    world.assert_fact("entrance", "north", "corridor")
    world.assert_fact("corridor", "south", "entrance")
    world.assert_fact("corridor", "east", "goblin_den")
    world.assert_fact("goblin_den", "west", "corridor")
    world.assert_fact("corridor", "west", "armory")
    world.assert_fact("armory", "east", "corridor")

    # Directions
    for d in ["north", "south", "east", "west"]:
        world.assert_fact(d, "is_a", "direction")

    # =========================================================================
    # PLAYER
    # =========================================================================
    world.assert_fact("player", "is_a", "combatant")
    world.assert_fact("player", "location", "entrance")
    world.assert_fact("player", "hp", 100)
    world.assert_fact("player", "max_hp", 100)
    world.assert_fact("player", "base_damage", 5)
    world.assert_fact("player", "gold", 0)
    world.assert_fact("player", "is_alive", True)

    # =========================================================================
    # EQUIPMENT — items with stat bonuses
    # =========================================================================
    # Sword in armory
    world.assert_fact("iron_sword", "is_a", "weapon")
    world.assert_fact("iron_sword", "in_room", "armory")
    world.assert_fact("iron_sword", "damage_bonus", 10)
    world.assert_fact("iron_sword", "description", "an iron sword")
    world.assert_fact("iron_sword", "slot", "weapon")

    # Shield in armory
    world.assert_fact("wooden_shield", "is_a", "armor")
    world.assert_fact("wooden_shield", "in_room", "armory")
    world.assert_fact("wooden_shield", "defense_bonus", 3)
    world.assert_fact("wooden_shield", "description", "a wooden shield")
    world.assert_fact("wooden_shield", "slot", "shield")

    # Health potion in entrance
    world.assert_fact("health_potion", "is_a", "consumable")
    world.assert_fact("health_potion", "in_room", "entrance")
    world.assert_fact("health_potion", "heal_amount", 30)
    world.assert_fact("health_potion", "description", "a red health potion")

    # =========================================================================
    # GOBLIN — the enemy
    # =========================================================================
    world.assert_fact("goblin", "is_a", "combatant")
    world.assert_fact("goblin", "is_a", "enemy")
    world.assert_fact("goblin", "location", "goblin_den")
    world.assert_fact("goblin", "hp", 30)
    world.assert_fact("goblin", "max_hp", 30)
    world.assert_fact("goblin", "base_damage", 8)
    world.assert_fact("goblin", "gold", 25)
    world.assert_fact("goblin", "is_alive", True)
    world.assert_fact("goblin", "name", "a snarling goblin")

    # =========================================================================
    # MOVEMENT RULES
    # =========================================================================
    world.add_derivation_rule(
        "player_move",
        [("input", "command", DIR),
         (DIR, "is_a", "direction"),
         ("player", "location", LOC),
         (LOC, DIR, DEST)],
        templates=[("player", "location", DEST), ("output", "moved", DEST)]
    )

    # =========================================================================
    # LOOK RULES
    # =========================================================================
    world.add_derivation_rule(
        "look_room",
        [("input", "command", "look"),
         ("player", "location", LOC),
         (LOC, "description", X)],
        ("output", "room_desc", X)
    )

    # Show items in room
    world.add_derivation_rule(
        "look_items",
        [("input", "command", "look"),
         ("player", "location", LOC),
         (ITEM, "in_room", LOC),
         (ITEM, "description", X)],
        ("output", "item_here", X)
    )

    # Show enemies in room
    world.add_derivation_rule(
        "look_enemies",
        [("input", "command", "look"),
         ("player", "location", LOC),
         (TARGET, "is_a", "enemy"),
         (TARGET, "location", LOC),
         (TARGET, "is_alive", True),
         (TARGET, "name", X)],
        ("output", "enemy_here", X)
    )

    # =========================================================================
    # TAKE RULES
    # =========================================================================
    world.add_derivation_rule(
        "take_item",
        [("input", "command", "take"),
         ("input", "arg", ITEM),
         ("player", "location", LOC),
         (ITEM, "in_room", LOC)],
        templates=[("player", "has", ITEM), ("output", "took", ITEM)],
        retractions=[(ITEM, "in_room", LOC)]
    )

    # =========================================================================
    # EQUIP RULES
    # =========================================================================
    world.add_derivation_rule(
        "equip_item",
        [("input", "command", "equip"),
         ("input", "arg", ITEM),
         ("player", "has", ITEM),
         (ITEM, "slot", SLOT)],
        templates=[("player", "equipped", ITEM), ("output", "equipped", ITEM)],
        retractions=[("player", "has", ITEM)]
    )

    # =========================================================================
    # USE RULES (potions)
    # =========================================================================
    world.add_derivation_rule(
        "use_potion",
        [("input", "command", "use"),
         ("input", "arg", ITEM),
         ("player", "has", ITEM),
         (ITEM, "is_a", "consumable"),
         (ITEM, "heal_amount", X),
         ("player", "hp", HP),
         ("player", "max_hp", Y)],
        templates=[("player", "hp", Expr('min', [Expr('+', [HP, X]), Y])),
                   ("output", "healed", X)],
        retractions=[("player", "has", ITEM)]
    )

    # =========================================================================
    # COMBAT RULES — the core of Common Herb
    # =========================================================================

    # Attack (armed): base + weapon bonus — listed first for priority
    # When weapon equipped, this fires and consumes the EPHEMERAL command
    world.add_derivation_rule(
        "player_attack_armed",
        [("input", "command", "attack"),
         ("player", "location", LOC),
         (TARGET, "is_a", "enemy"),
         (TARGET, "location", LOC),
         (TARGET, "is_alive", True),
         ("player", "base_damage", DMG),
         ("player", "equipped", Var('weapon')),
         (Var('weapon'), "damage_bonus", BONUS)],
        templates=[(TARGET, "pending_damage", Expr('+', [DMG, BONUS])),
                   ("output", "attacked", TARGET)]
    )

    # Attack (unarmed): base damage only
    # Only fires if no weapon equipped (armed rule consumes command first)
    world.add_derivation_rule(
        "player_attack_unarmed",
        [("input", "command", "attack"),
         ("player", "location", LOC),
         (TARGET, "is_a", "enemy"),
         (TARGET, "location", LOC),
         (TARGET, "is_alive", True),
         ("player", "base_damage", DMG)],
        templates=[(TARGET, "pending_damage", DMG),
                   ("output", "attacked", TARGET)]
    )

    # Apply pending damage to HP, then retract pending_damage
    # Also marks that damage was applied this tick for death check
    world.add_derivation_rule(
        "apply_damage",
        [(TARGET, "pending_damage", DMG),
         (TARGET, "hp", HP),
         (TARGET, "is_alive", True)],
        templates=[(TARGET, "hp", Expr('-', [HP, DMG])),
                   (TARGET, "took_damage", True),
                   ("output", "damage_dealt", DMG)],
        retractions=[(TARGET, "pending_damage", DMG)]  # Consume the damage
    )

    # Check for death after damage applied (stratum 3)
    # Patterns on took_damage to ensure it runs after apply_damage
    world.add_derivation_rule(
        "check_death",
        [(TARGET, "took_damage", True),
         (TARGET, "hp", HP),
         (TARGET, "is_alive", True)],
        templates=[(TARGET, "is_alive", False),
                   ("output", "died", TARGET)],
        retractions=[(TARGET, "took_damage", True)],
        guard=Expr('<=', [HP, 0])
    )

    # Clean up took_damage if not dead
    world.add_derivation_rule(
        "clear_took_damage",
        [(TARGET, "took_damage", True),
         (TARGET, "hp", HP),
         (TARGET, "is_alive", True)],
        templates=[],
        retractions=[(TARGET, "took_damage", True)],
        guard=Expr('>', [HP, 0])
    )

    # Clear took_damage on death (different stratum due to patterns)
    world.add_derivation_rule(
        "clear_took_damage_dead",
        [(TARGET, "took_damage", True),
         (TARGET, "is_alive", False)],
        templates=[],
        retractions=[(TARGET, "took_damage", True)]
    )

    # Drop gold on death
    world.add_derivation_rule(
        "drop_gold_on_death",
        [(TARGET, "is_alive", False),
         (TARGET, "gold", X),
         (TARGET, "location", LOC),
         ("player", "gold", Y)],
        templates=[("player", "gold", Expr('+', [X, Y])),
                   ("output", "looted_gold", X)],
        retractions=[(TARGET, "gold", X)],
        guard=Expr('>', [X, 0])
    )

    # =========================================================================
    # ENEMY AI — goblin attacks when player enters their room
    # Only triggers once per room entry via "enemy_noticed" marker
    # =========================================================================
    # Note: Full counterattack system needs phase separation.
    # For now, enemy attacks are triggered by player movement, not attacks.

    # =========================================================================
    # STATUS RULES
    # =========================================================================
    world.add_derivation_rule(
        "status_hp",
        [("input", "command", "status"),
         ("player", "hp", HP),
         ("player", "max_hp", X)],
        ("output", "player_hp", HP)
    )

    world.add_derivation_rule(
        "status_gold",
        [("input", "command", "status"),
         ("player", "gold", X)],
        ("output", "player_gold", X)
    )

    world.add_derivation_rule(
        "status_equipped",
        [("input", "command", "status"),
         ("player", "equipped", ITEM),
         (ITEM, "description", X)],
        ("output", "player_equipped", X)
    )

    world.add_derivation_rule(
        "status_inventory",
        [("input", "command", "status"),
         ("player", "has", ITEM),
         (ITEM, "description", X)],
        ("output", "player_has", X)
    )

    # =========================================================================
    # HELP
    # =========================================================================
    world.add_derivation_rule(
        "show_help",
        [("input", "command", "help")],
        ("output", "help", "Commands: look, north/south/east/west, take <item>, equip <item>, use <item>, attack, status, quit")
    )

    return world


def process_output(world: World):
    """Read and print output facts."""
    # Room description
    for m in world.query(("output", "room_desc", X)):
        print(f"  You are in {m['x']}.")

    # Items
    items = world.query(("output", "item_here", X))
    if items:
        print(f"  You see: {', '.join(i['x'] for i in items)}")

    # Enemies
    enemies = world.query(("output", "enemy_here", X))
    if enemies:
        for e in enemies:
            print(f"  {e['x'].capitalize()} is here!")

    # Movement
    for m in world.query(("output", "moved", X)):
        print(f"  You move to the {m['x']}.")

    # Take
    for m in world.query(("output", "took", X)):
        print(f"  You pick up the {m['x']}.")

    # Equip
    for m in world.query(("output", "equipped", X)):
        print(f"  You equip the {m['x']}.")

    # Heal
    for m in world.query(("output", "healed", X)):
        print(f"  You heal for {m['x']} HP.")

    # Attack
    for m in world.query(("output", "attacked", X)):
        print(f"  You attack the {m['x']}!")

    # Damage dealt
    for m in world.query(("output", "damage_dealt", X)):
        print(f"  You deal {m['x']} damage!")
        # Debug: show goblin HP
        goblin_hp = world.query(("goblin", "hp", Y))
        if goblin_hp:
            print(f"  [Goblin HP: {goblin_hp[0]['y']}]")

    # Enemy attacked
    for m in world.query(("output", "enemy_attacked", X)):
        print(f"  The {m['x']} attacks you!")

    # Death
    for m in world.query(("output", "died", X)):
        if m['x'] == "player":
            print("  YOU DIED!")
        else:
            print(f"  The {m['x']} collapses!")

    # Looted gold
    for m in world.query(("output", "looted_gold", X)):
        print(f"  You loot {m['x']} gold!")

    # Status
    hp = world.query(("output", "player_hp", X))
    if hp:
        max_hp = world.query(("player", "max_hp", X))
        max_val = max_hp[0]['x'] if max_hp else "?"
        print(f"  HP: {hp[0]['x']}/{max_val}")

    gold = world.query(("output", "player_gold", X))
    if gold:
        print(f"  Gold: {gold[0]['x']}")

    equipped = world.query(("output", "player_equipped", X))
    if equipped:
        print(f"  Equipped: {', '.join(e['x'] for e in equipped)}")

    has = world.query(("output", "player_has", X))
    if has:
        print(f"  Inventory: {', '.join(h['x'] for h in has)}")

    # Help
    for m in world.query(("output", "help", X)):
        print(f"  {m['x']}")


def clear_output(world: World):
    """Clean up output facts and combat markers."""
    patterns = [
        ("output", "room_desc", X), ("output", "item_here", X),
        ("output", "enemy_here", X), ("output", "moved", X),
        ("output", "took", X), ("output", "equipped", X),
        ("output", "healed", X), ("output", "attacked", X),
        ("output", "damage_dealt", X), ("output", "enemy_attacked", X),
        ("output", "died", X), ("output", "looted_gold", X),
        ("output", "player_hp", X), ("output", "player_gold", X),
        ("output", "player_equipped", X), ("output", "player_has", X),
        ("output", "help", X),
    ]
    for pattern in patterns:
        for m in world.query(pattern):
            world.retract_fact("output", pattern[1], m['x'])

    # Clear combat markers for next tick
    for m in world.query((X, "counterattacked", True)):
        world.retract_fact(m['x'], "counterattacked", True)


def main():
    print("=" * 60)
    print("HERB Combat — Live Loop")
    print("=" * 60)
    print()
    print("You awaken in a dungeon. Rumors speak of a goblin nearby...")
    print("Type 'help' for commands.")
    print()

    world = bootstrap_world()

    # Show starting location
    world.assert_fact("input", "command", "look")
    world.advance()
    process_output(world)
    clear_output(world)

    while True:
        # Check if player is dead
        player_alive = world.query(("player", "is_alive", True))
        if not player_alive:
            print("\n  GAME OVER")
            break

        try:
            line = input("\n> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            break

        if not line:
            continue

        if line == "quit":
            print("Farewell.")
            break

        # Parse command
        parts = line.split()
        cmd = parts[0]

        # Assert command (EPHEMERAL - consumed after match)
        world.assert_fact("input", "command", cmd)

        # Assert argument if present
        if len(parts) > 1:
            arg = parts[1]
            world.assert_fact("input", "arg", arg)

        # Derive
        start = time.perf_counter()
        world.advance()
        derive_time = (time.perf_counter() - start) * 1000

        # Output
        process_output(world)

        # Show derive time for debugging
        hp = world.query(("player", "hp", X))
        hp_val = hp[0]['x'] if hp else "?"
        print(f"  [HP: {hp_val}, derive: {derive_time:.2f}ms, tick: {world.tick}]")

        # Cleanup
        clear_output(world)

        # Clean up arg if it wasn't consumed
        for m in world.query(("input", "arg", X)):
            world.retract_fact("input", "arg", m['x'])


if __name__ == "__main__":
    main()
