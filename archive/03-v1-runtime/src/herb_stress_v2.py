"""
HERB Stress Test v2 — With EPHEMERAL

The three-phase dance is gone. Movement is now a single rule.

Session 14.5 — February 4, 2026
"""

import time
import random
from herb_core import World, Var, Expr, NotExistsExpr

X, Y, Z = Var('x'), Var('y'), Var('z')
LOC, DIR, DEST = Var('loc'), Var('dir'), Var('dest')
NPC = Var('npc')


def bootstrap_world(num_npcs: int = 0) -> World:
    """Create world with EPHEMERAL-based movement."""
    world = World("stress_test")

    # =========================================================================
    # RELATION DECLARATIONS
    # =========================================================================
    world.declare_functional("location")
    world.declare_ephemeral("command")      # Player commands - consumed after match
    world.declare_ephemeral("wants_to_go")  # NPC intents - consumed after match

    # =========================================================================
    # ROOMS
    # =========================================================================
    rooms = ["entrance", "corridor", "treasury", "dungeon", "armory", "library"]

    world.assert_fact("entrance", "is_a", "room")
    world.assert_fact("entrance", "description", "a stone entrance hall")

    world.assert_fact("corridor", "is_a", "room")
    world.assert_fact("corridor", "description", "a long dark corridor")

    world.assert_fact("treasury", "is_a", "room")
    world.assert_fact("treasury", "description", "a vault of gold")
    world.assert_fact("treasury", "locked", True)

    world.assert_fact("dungeon", "is_a", "room")
    world.assert_fact("dungeon", "description", "a damp cell")

    world.assert_fact("armory", "is_a", "room")
    world.assert_fact("armory", "description", "racks of weapons")

    world.assert_fact("library", "is_a", "room")
    world.assert_fact("library", "description", "dusty tomes everywhere")

    # Connections
    world.assert_fact("entrance", "north", "corridor")
    world.assert_fact("corridor", "south", "entrance")
    world.assert_fact("corridor", "east", "treasury")
    world.assert_fact("treasury", "west", "corridor")
    world.assert_fact("corridor", "west", "dungeon")
    world.assert_fact("dungeon", "east", "corridor")
    world.assert_fact("corridor", "north", "armory")
    world.assert_fact("armory", "south", "corridor")
    world.assert_fact("armory", "east", "library")
    world.assert_fact("library", "west", "armory")

    # Directions
    world.assert_fact("north", "is_a", "direction")
    world.assert_fact("south", "is_a", "direction")
    world.assert_fact("east", "is_a", "direction")
    world.assert_fact("west", "is_a", "direction")

    # =========================================================================
    # PLAYER
    # =========================================================================
    world.assert_fact("player", "is_a", "actor")
    world.assert_fact("player", "location", "entrance")

    # =========================================================================
    # NPCs
    # =========================================================================
    for i in range(num_npcs):
        npc_name = f"citizen_{i}"
        world.assert_fact(npc_name, "is_a", "npc")
        world.assert_fact(npc_name, "is_a", "actor")
        start_room = random.choice(rooms)
        world.assert_fact(npc_name, "location", start_room)
        world.assert_fact(npc_name, "wants_to_go", random.choice(["north", "south", "east", "west"]))

    # =========================================================================
    # MOVEMENT RULES — THE SIMPLE VERSION
    # =========================================================================

    # Player movement: single rule!
    # EPHEMERAL command is consumed after match, preventing double-firing
    world.add_derivation_rule(
        "player_move",
        [("input", "command", DIR),
         (DIR, "is_a", "direction"),
         ("player", "location", LOC),
         (LOC, DIR, DEST)],
        templates=[("player", "location", DEST), ("output", "moved", DEST)],
        guard=NotExistsExpr([(DEST, "locked", True)])
    )

    # Player blocked
    world.add_derivation_rule(
        "player_blocked",
        [("input", "command", DIR),
         (DIR, "is_a", "direction"),
         ("player", "location", LOC),
         (LOC, DIR, DEST),
         (DEST, "locked", True)],
        ("output", "blocked", "The door is locked!")
    )

    # NPC movement: single rule!
    # EPHEMERAL wants_to_go is consumed after match
    world.add_derivation_rule(
        "npc_move",
        [(NPC, "wants_to_go", DIR),
         (DIR, "is_a", "direction"),
         (NPC, "location", LOC),
         (LOC, DIR, DEST)],
        (NPC, "location", DEST),
        guard=NotExistsExpr([(DEST, "locked", True)])
    )

    # =========================================================================
    # LOOK command
    # =========================================================================
    world.add_derivation_rule(
        "look_room",
        [("input", "command", "look"),
         ("player", "location", LOC),
         (LOC, "description", X)],
        ("output", "message", X)
    )

    world.add_derivation_rule(
        "look_npcs",
        [("input", "command", "look"),
         ("player", "location", LOC),
         (NPC, "is_a", "npc"),
         (NPC, "location", LOC)],
        ("output", "npc_here", NPC)
    )

    # =========================================================================
    # STATUS command
    # =========================================================================
    world.add_derivation_rule(
        "status_actors",
        [("input", "command", "status"),
         (X, "is_a", "actor"),
         (X, "location", LOC)],
        ("output", "actor_at", X)
    )

    return world, rooms


def give_npcs_new_directions(world: World):
    """Give each NPC a new random direction for next tick."""
    directions = ["north", "south", "east", "west"]
    # Find all NPCs
    npcs = world.query((NPC, "is_a", "npc"))
    for binding in npcs:
        npc = binding['npc']
        # Check if they still need a direction (wants_to_go was consumed)
        existing = world.query((npc, "wants_to_go", X))
        if not existing:
            world.assert_fact(npc, "wants_to_go", random.choice(directions))


def process_output(world: World):
    """Read and print output facts."""
    for m in world.query(("output", "message", X)):
        print(f"  {m['x']}")
    for m in world.query(("output", "moved", X)):
        print(f"  You move to {m['x']}.")
    for m in world.query(("output", "blocked", X)):
        print(f"  {m['x']}")
    npcs = world.query(("output", "npc_here", X))
    if npcs:
        print(f"  NPCs here: {', '.join(n['x'] for n in npcs)}")
    actors = world.query(("output", "actor_at", X))
    if actors:
        for a in actors:
            loc = world.query((a['x'], "location", Y))
            if loc:
                print(f"  {a['x']} is at {loc[0]['y']}")


def clear_output(world: World):
    """Clean up output facts."""
    for pattern in [("output", "message", X), ("output", "moved", X),
                    ("output", "blocked", X), ("output", "npc_here", X),
                    ("output", "actor_at", X)]:
        for m in world.query(pattern):
            for key, val in m.items():
                world.retract_fact("output", pattern[1], val)


def run_interactive(num_npcs: int = 3):
    """Run interactive session with NPCs."""
    print("=" * 50)
    print(f"HERB Stress Test v2 — EPHEMERAL — {num_npcs} NPCs")
    print("=" * 50)
    print("Commands: look, north/south/east/west, status, quit")
    print()

    world, rooms = bootstrap_world(num_npcs)

    loc = world.query(("player", "location", X))[0]['x']
    print(f"  You are at {loc}.")

    while True:
        try:
            line = input("\n> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            break

        if not line:
            continue

        if line == "quit":
            break

        # Player command (EPHEMERAL - will be consumed)
        world.assert_fact("input", "command", line)

        start = time.perf_counter()
        world.advance()
        derive_time = (time.perf_counter() - start) * 1000

        # Give NPCs new directions
        give_npcs_new_directions(world)

        process_output(world)
        print(f"  [derive: {derive_time:.2f}ms, facts: {len(world)}, tick: {world.tick}]")

        clear_output(world)


def run_benchmark(num_npcs: int, num_ticks: int = 100):
    """Benchmark tick time."""
    print(f"\nBenchmark: {num_npcs} NPCs, {num_ticks} ticks")

    world, rooms = bootstrap_world(num_npcs)

    times = []
    for i in range(num_ticks):
        world.assert_fact("input", "command", "look")

        start = time.perf_counter()
        world.advance()
        derive_time = (time.perf_counter() - start) * 1000
        times.append(derive_time)

        give_npcs_new_directions(world)
        for m in world.query(("output", X, Y)):
            world.retract_fact("output", m['x'], m['y'])

    avg = sum(times) / len(times)
    max_t = max(times)
    min_t = min(times)

    print(f"  Avg: {avg:.2f}ms, Min: {min_t:.2f}ms, Max: {max_t:.2f}ms")
    print(f"  Facts: {len(world)}, Rules: {len(world._derivation_rules)}")

    return avg


def find_the_wall():
    """Find how many NPCs before tick budget breaks."""
    print("=" * 50)
    print("Finding the Wall v2 — EPHEMERAL — 600ms target")
    print("=" * 50)

    for num_npcs in [0, 10, 25, 50, 100, 200, 500, 1000]:
        avg = run_benchmark(num_npcs, num_ticks=50)
        status = "OK" if avg < 600 else "OVER BUDGET"
        print(f"  {num_npcs} NPCs: {avg:.2f}ms — {status}")
        if avg > 600:
            print(f"\n  WALL FOUND at {num_npcs} NPCs")
            break


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1:
        if sys.argv[1] == "bench" or sys.argv[1] == "wall":
            find_the_wall()
        else:
            try:
                num = int(sys.argv[1])
                run_interactive(num)
            except ValueError:
                print("Usage: python herb_stress_v2.py [num_npcs | bench]")
    else:
        run_interactive(3)
