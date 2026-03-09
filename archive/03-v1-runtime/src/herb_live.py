"""
HERB Live — The Thinnest Runnable Thing

This crosses the boundary from "batch computation over a fact store" to
"living system that responds to the world."

A text adventure where HERB is the brain:
- You type commands
- Commands become facts
- Rules derive consequences
- Output facts become text
- State persists

The "program" is the rules, not this Python code.
This Python is just the nervous system — I/O and the tick loop.

Session 14.5 — February 4, 2026
"""

import sys
from herb_core import World, Verse, Var, Expr

X, Y, Z = Var('x'), Var('y'), Var('z')
LOC, DIR, ITEM = Var('loc'), Var('dir'), Var('item')


def try_parse(s: str):
    """Try to parse as number, otherwise return as string."""
    try:
        return int(s)
    except ValueError:
        try:
            return float(s)
        except ValueError:
            return s.lower()


def bootstrap_world() -> World:
    """
    Create a world with a tiny adventure game.

    The game logic is ENTIRELY in HERB rules.
    Python just does I/O.
    """
    world = World("adventure")

    # =========================================================================
    # WORLD STATE — the map and items
    # =========================================================================

    # Rooms
    world.assert_fact("entrance", "is_a", "room")
    world.assert_fact("entrance", "description", "a stone entrance hall, torches flickering on the walls")

    world.assert_fact("corridor", "is_a", "room")
    world.assert_fact("corridor", "description", "a long dark corridor stretching into shadow")

    world.assert_fact("treasury", "is_a", "room")
    world.assert_fact("treasury", "description", "a vault filled with glittering gold and ancient artifacts")

    world.assert_fact("dungeon", "is_a", "room")
    world.assert_fact("dungeon", "description", "a damp cell with chains on the walls")

    # Connections (bidirectional)
    world.assert_fact("entrance", "north", "corridor")
    world.assert_fact("corridor", "south", "entrance")
    world.assert_fact("corridor", "east", "treasury")
    world.assert_fact("treasury", "west", "corridor")
    world.assert_fact("corridor", "west", "dungeon")
    world.assert_fact("dungeon", "east", "corridor")

    # Items in rooms
    world.assert_fact("torch", "in_room", "entrance")
    world.assert_fact("torch", "is_a", "item")
    world.assert_fact("torch", "description", "a burning torch")

    world.assert_fact("key", "in_room", "dungeon")
    world.assert_fact("key", "is_a", "item")
    world.assert_fact("key", "description", "a rusty iron key")

    world.assert_fact("gold", "in_room", "treasury")
    world.assert_fact("gold", "is_a", "item")
    world.assert_fact("gold", "description", "a pile of gold coins")

    # Locked door
    world.assert_fact("treasury", "locked", True)

    # =========================================================================
    # PLAYER STATE
    # =========================================================================

    world.declare_functional("location")
    world.assert_fact("player", "location", "entrance")

    # =========================================================================
    # RULES — the game logic, all in HERB
    # =========================================================================

    # --- LOOK command ---
    world.add_derivation_rule(
        "look_room",
        [("input", "command", "look"),
         ("player", "location", LOC),
         (LOC, "description", X)],
        ("output", "message", X)
    )

    # Show items in room when looking
    world.add_derivation_rule(
        "look_items",
        [("input", "command", "look"),
         ("player", "location", LOC),
         (ITEM, "in_room", LOC),
         (ITEM, "description", X)],
        ("output", "item_here", X)
    )

    # --- MOVEMENT commands ---
    # Generic movement rule with guard to check destination is not locked
    from herb_core import NotExistsExpr

    # Go north (check not locked)
    world.add_derivation_rule(
        "go_north",
        [("input", "command", "north"),
         ("player", "location", LOC),
         (LOC, "north", Y)],
        templates=[("player", "location", Y), ("output", "moved", Y)],
        guard=NotExistsExpr([(Y, "locked", True)])
    )

    # Go south (check not locked)
    world.add_derivation_rule(
        "go_south",
        [("input", "command", "south"),
         ("player", "location", LOC),
         (LOC, "south", Y)],
        templates=[("player", "location", Y), ("output", "moved", Y)],
        guard=NotExistsExpr([(Y, "locked", True)])
    )

    # Go east (check not locked)
    world.add_derivation_rule(
        "go_east",
        [("input", "command", "east"),
         ("player", "location", LOC),
         (LOC, "east", Y)],
        templates=[("player", "location", Y), ("output", "moved", Y)],
        guard=NotExistsExpr([(Y, "locked", True)])
    )

    # Go west (check not locked)
    world.add_derivation_rule(
        "go_west",
        [("input", "command", "west"),
         ("player", "location", LOC),
         (LOC, "west", Y)],
        templates=[("player", "location", Y), ("output", "moved", Y)],
        guard=NotExistsExpr([(Y, "locked", True)])
    )

    # Blocked by locked door
    world.add_derivation_rule(
        "blocked_north",
        [("input", "command", "north"),
         ("player", "location", LOC),
         (LOC, "north", Y),
         (Y, "locked", True)],
        ("output", "blocked", "The door is locked!")
    )

    world.add_derivation_rule(
        "blocked_south",
        [("input", "command", "south"),
         ("player", "location", LOC),
         (LOC, "south", Y),
         (Y, "locked", True)],
        ("output", "blocked", "The door is locked!")
    )

    world.add_derivation_rule(
        "blocked_east",
        [("input", "command", "east"),
         ("player", "location", LOC),
         (LOC, "east", Y),
         (Y, "locked", True)],
        ("output", "blocked", "The door is locked!")
    )

    world.add_derivation_rule(
        "blocked_west",
        [("input", "command", "west"),
         ("player", "location", LOC),
         (LOC, "west", Y),
         (Y, "locked", True)],
        ("output", "blocked", "The door is locked!")
    )

    # --- TAKE command ---
    world.add_derivation_rule(
        "take_item",
        [("input", "command", "take"),
         ("input", "arg0", ITEM),
         ("player", "location", LOC),
         (ITEM, "in_room", LOC)],
        templates=[("player", "has", ITEM), ("output", "took", ITEM)],
        retractions=[(ITEM, "in_room", LOC)]
    )

    # --- INVENTORY command ---
    world.add_derivation_rule(
        "inventory_item",
        [("input", "command", "inventory"),
         ("player", "has", ITEM)],
        ("output", "carrying", ITEM)
    )

    # --- UNLOCK command ---
    world.add_derivation_rule(
        "unlock_treasury",
        [("input", "command", "unlock"),
         ("player", "has", "key"),
         ("treasury", "locked", True)],
        templates=[("output", "unlocked", "treasury")],
        retractions=[("treasury", "locked", True)]
    )

    # --- HELP command ---
    world.add_derivation_rule(
        "show_help",
        [("input", "command", "help")],
        ("output", "help", "Commands: look, north, south, east, west, take <item>, inventory, unlock, quit")
    )

    return world


def process_output(world: World):
    """Read output facts and print them, then clean up."""

    # Messages (room descriptions)
    for m in world.query(("output", "message", X)):
        print(f"  You are in {m['x']}.")

    # Items visible
    items = world.query(("output", "item_here", X))
    if items:
        print(f"  You see: {', '.join(i['x'] for i in items)}")

    # Movement
    for m in world.query(("output", "moved", X)):
        print(f"  You walk to the {m['x']}.")

    # Blocked
    for m in world.query(("output", "blocked", X)):
        print(f"  {m['x']}")

    # Took item
    for m in world.query(("output", "took", X)):
        print(f"  You pick up the {m['x']}.")

    # Inventory
    inv = world.query(("output", "carrying", X))
    if inv:
        print(f"  You are carrying: {', '.join(i['x'] for i in inv)}")
    elif world.query(("input", "command", "inventory")):
        print("  You are carrying nothing.")

    # Unlocked
    for m in world.query(("output", "unlocked", X)):
        print(f"  You unlock the {m['x']}!")

    # Help
    for m in world.query(("output", "help", X)):
        print(f"  {m['x']}")

    # Clean up output facts for next tick
    for pattern in [("output", "message", X), ("output", "item_here", X),
                    ("output", "moved", X), ("output", "blocked", X),
                    ("output", "took", X), ("output", "carrying", X),
                    ("output", "unlocked", X), ("output", "help", X)]:
        for m in world.query(pattern):
            for key, val in m.items():
                world.retract_fact("output", pattern[1], val)


def clear_input(world: World, cmd: str, args: list):
    """Clean up input facts for next iteration."""
    world.retract_fact("input", "command", cmd)
    for i, arg in enumerate(args):
        world.retract_fact("input", f"arg{i}", arg)


def main():
    print("=" * 50)
    print("HERB Live — A Living System")
    print("=" * 50)
    print()
    print("You awaken in a dark place...")
    print("Type 'help' for commands, 'quit' to exit.")
    print()

    world = bootstrap_world()

    # Show initial location
    loc = world.query(("player", "location", X))[0]['x']
    desc = world.query((loc, "description", X))[0]['x']
    print(f"  You are in {desc}.")
    items = world.query((Y, "in_room", loc))
    if items:
        item_descs = []
        for i in items:
            item_desc = world.query((i['y'], "description", X))
            if item_desc:
                item_descs.append(item_desc[0]['x'])
        if item_descs:
            print(f"  You see: {', '.join(item_descs)}")

    # Main loop — the heartbeat
    while True:
        try:
            line = input("\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nFarewell.")
            break

        if not line:
            continue

        parts = line.lower().split()
        cmd = parts[0]
        args = [try_parse(p) for p in parts[1:]]

        if cmd == "quit":
            print("Farewell.")
            break

        # === THE BOUNDARY ===
        # External input becomes facts
        world.assert_fact("input", "command", cmd)
        for i, arg in enumerate(args):
            world.assert_fact("input", f"arg{i}", arg)

        # HERB derivation runs — this is the brain thinking
        world.advance()

        # Output facts become visible results
        process_output(world)

        # Clean up for next iteration
        clear_input(world, cmd, args)

    # Final stats
    print(f"\nFinal state: {len(world)} facts, tick {world.tick}")


if __name__ == "__main__":
    main()
