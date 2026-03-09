"""
HERB Stress Test — Push the Live Loop Until It Breaks

Three tests:
1. Direction duplication solved with variable-in-relation
2. Multiple NPCs acting every tick
3. Tick budget timing

Session 14.5 — February 4, 2026
"""

import time
import random
from herb_core import World, Var, Expr, NotExistsExpr

X, Y, Z = Var('x'), Var('y'), Var('z')
LOC, DIR, DEST = Var('loc'), Var('dir'), Var('dest')
ITEM, NPC, TARGET = Var('item'), Var('npc'), Var('target')


def bootstrap_world(num_npcs: int = 0) -> World:
    """Create world with unified movement rule and optional NPCs."""
    world = World("stress_test")

    # =========================================================================
    # ROOMS — same as before
    # =========================================================================
    rooms = ["entrance", "corridor", "treasury", "dungeon", "armory", "library"]

    world.assert_fact("entrance", "is_a", "room")
    world.assert_fact("entrance", "description", "a stone entrance hall")

    world.assert_fact("corridor", "is_a", "room")
    world.assert_fact("corridor", "description", "a long dark corridor")

    world.assert_fact("treasury", "is_a", "room")
    world.assert_fact("treasury", "description", "a vault of gold")
    world.assert_fact("treasury", "locked", True)  # Locked until unlocked

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

    # =========================================================================
    # DIRECTIONS — key insight: directions are facts, not hardcoded
    # =========================================================================
    world.assert_fact("north", "is_a", "direction")
    world.assert_fact("south", "is_a", "direction")
    world.assert_fact("east", "is_a", "direction")
    world.assert_fact("west", "is_a", "direction")

    # =========================================================================
    # PLAYER
    # =========================================================================
    world.declare_functional("location")
    world.assert_fact("player", "is_a", "actor")
    world.assert_fact("player", "location", "entrance")

    # =========================================================================
    # NPCs — citizens that act every tick
    # =========================================================================
    for i in range(num_npcs):
        npc_name = f"citizen_{i}"
        world.assert_fact(npc_name, "is_a", "npc")
        world.assert_fact(npc_name, "is_a", "actor")
        # Start in random room
        start_room = random.choice(rooms)
        world.assert_fact(npc_name, "location", start_room)
        # Give them a random wander direction for this tick
        world.assert_fact(npc_name, "wants_to_go", random.choice(["north", "south", "east", "west"]))

    # =========================================================================
    # UNIFIED MOVEMENT RULE — the key insight
    # =========================================================================
    # Instead of 4 separate rules for north/south/east/west,
    # use a variable in the relation position

    # Player movement — consume input first to prevent double-firing
    #
    # The problem: if we check (player location ?loc) and then update location,
    # the rule pattern matches AGAIN with the new location.
    #
    # Solution: consume the input command immediately in a separate rule,
    # then subsequent rules work on "player wants_to_move ?dir" which only exists once.

    # Step 1: Consume direction command, create wants_to_move
    world.add_derivation_rule(
        "player_consume_direction",
        [("input", "command", DIR),
         (DIR, "is_a", "direction")],
        ("player", "wants_to_move", DIR),
        retractions=[("input", "command", DIR)]
    )

    # Step 2: Check if move is valid (Phase 2 - has negation)
    world.add_derivation_rule(
        "player_move_valid",
        [("player", "wants_to_move", DIR),
         ("player", "location", LOC),
         (LOC, DIR, DEST)],
        ("player", "pending_move", DEST),
        guard=NotExistsExpr([(DEST, "locked", True)])
    )

    # Step 3: Execute pending move (Phase 3 - depends on Phase 2 output)
    world.add_derivation_rule(
        "player_move_execute",
        [("player", "pending_move", DEST),
         ("player", "wants_to_move", DIR)],  # Need DIR to retract
        templates=[("player", "location", DEST), ("output", "moved", DEST)],
        retractions=[("player", "pending_move", DEST), ("player", "wants_to_move", DIR)]
    )

    # Step 2b: Blocked by locked door (parallel to Step 2, no retraction)
    world.add_derivation_rule(
        "player_blocked",
        [("player", "wants_to_move", DIR),
         ("player", "location", LOC),
         (LOC, DIR, DEST),
         (DEST, "locked", True)],
        ("output", "blocked", "The door is locked!")
    )

    # NPC movement: each NPC tries to go their wants_to_go direction
    world.add_derivation_rule(
        "npc_move",
        [(NPC, "is_a", "npc"),
         (NPC, "wants_to_go", DIR),
         (NPC, "location", LOC),
         (LOC, DIR, DEST)],
        templates=[(NPC, "location", DEST), (NPC, "did_move", True)],
        guard=NotExistsExpr([(DEST, "locked", True)])
    )

    # NPC picks new random direction after moving (or failing)
    # This runs after movement to prepare next tick
    world.add_derivation_rule(
        "npc_new_direction",
        [(NPC, "is_a", "npc"),
         (NPC, "wants_to_go", DIR)],
        templates=[(NPC, "needs_new_direction", True)],
        retractions=[(NPC, "wants_to_go", DIR)]
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

    # Show NPCs in same room
    world.add_derivation_rule(
        "look_npcs",
        [("input", "command", "look"),
         ("player", "location", LOC),
         (NPC, "is_a", "npc"),
         (NPC, "location", LOC)],
        ("output", "npc_here", NPC)
    )

    # =========================================================================
    # STATUS command - show all actor locations
    # =========================================================================
    world.add_derivation_rule(
        "status_actors",
        [("input", "command", "status"),
         (X, "is_a", "actor"),
         (X, "location", LOC)],
        ("output", "actor_at", X)
    )

    return world


def give_npcs_new_directions(world: World):
    """Give each NPC that moved a new random direction."""
    directions = ["north", "south", "east", "west"]
    npcs_needing_direction = world.query((NPC, "needs_new_direction", True))
    for binding in npcs_needing_direction:
        npc = binding['npc']
        world.retract_fact(npc, "needs_new_direction", True)
        new_dir = random.choice(directions)
        world.assert_fact(npc, "wants_to_go", new_dir)


def process_output(world: World):
    """Read and print output facts."""
    # Messages
    for m in world.query(("output", "message", X)):
        print(f"  {m['x']}")

    # Movement
    for m in world.query(("output", "moved", X)):
        print(f"  You move to {m['x']}.")

    # Blocked
    for m in world.query(("output", "blocked", X)):
        print(f"  {m['x']}")

    # NPCs here
    npcs = world.query(("output", "npc_here", X))
    if npcs:
        print(f"  NPCs here: {', '.join(n['x'] for n in npcs)}")

    # Status
    actors = world.query(("output", "actor_at", X))
    if actors:
        for a in actors:
            loc = world.query((a['x'], "location", Y))
            if loc:
                print(f"  {a['x']} is at {loc[0]['y']}")


def clear_output(world: World):
    """Clean up output facts for next tick."""
    patterns = [
        ("output", "message", X),
        ("output", "moved", X),
        ("output", "blocked", X),
        ("output", "npc_here", X),
        ("output", "actor_at", X),
    ]
    for pattern in patterns:
        for m in world.query(pattern):
            for key, val in m.items():
                world.retract_fact("output", pattern[1], val)


def clear_input(world: World, cmd: str):
    """Clean up input facts (may already be consumed by rules)."""
    world.retract_fact("input", "command", cmd)
    # Also clean up wants_to_move if blocked (not consumed by move)
    for m in world.query(("player", "wants_to_move", X)):
        world.retract_fact("player", "wants_to_move", m['x'])


def clear_npc_did_move(world: World):
    """Clean up NPC movement markers."""
    for m in world.query((NPC, "did_move", True)):
        world.retract_fact(m['npc'], "did_move", True)


def run_interactive(num_npcs: int = 3):
    """Run interactive session with NPCs."""
    print("=" * 50)
    print(f"HERB Stress Test — {num_npcs} NPCs")
    print("=" * 50)
    print("Commands: look, north/south/east/west, status, tick, quit")
    print()

    world = bootstrap_world(num_npcs)

    # Show starting location
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

        if line == "tick":
            # Just advance NPCs without player input
            world.advance()
            give_npcs_new_directions(world)
            clear_npc_did_move(world)
            print(f"  Tick {world.tick}")
            continue

        # Player command
        world.assert_fact("input", "command", line)

        # Time the derivation
        start = time.perf_counter()
        world.advance()
        derive_time = (time.perf_counter() - start) * 1000

        # Give NPCs new directions
        give_npcs_new_directions(world)

        # Output
        process_output(world)
        print(f"  [derive: {derive_time:.2f}ms, facts: {len(world)}, tick: {world.tick}]")

        # Cleanup
        clear_output(world)
        clear_input(world, line)
        clear_npc_did_move(world)


def run_benchmark(num_npcs: int, num_ticks: int = 100):
    """Benchmark tick time with varying NPC counts."""
    print(f"\nBenchmark: {num_npcs} NPCs, {num_ticks} ticks")

    world = bootstrap_world(num_npcs)

    times = []
    for i in range(num_ticks):
        # Simulate a player command each tick
        world.assert_fact("input", "command", "look")

        start = time.perf_counter()
        world.advance()
        derive_time = (time.perf_counter() - start) * 1000
        times.append(derive_time)

        # Cleanup
        give_npcs_new_directions(world)
        clear_npc_did_move(world)
        for m in world.query(("output", X, Y)):
            world.retract_fact("output", m['x'], m['y'])
        world.retract_fact("input", "command", "look")

    avg = sum(times) / len(times)
    max_t = max(times)
    min_t = min(times)

    print(f"  Avg: {avg:.2f}ms, Min: {min_t:.2f}ms, Max: {max_t:.2f}ms")
    print(f"  Facts: {len(world)}, Rules: {len(world._derivation_rules)}")

    return avg


def find_the_wall():
    """Find how many NPCs before tick budget breaks."""
    print("=" * 50)
    print("Finding the Wall — 600ms tick budget")
    print("=" * 50)

    target_ms = 600

    for num_npcs in [0, 10, 25, 50, 100, 200, 500, 1000]:
        avg = run_benchmark(num_npcs, num_ticks=50)
        status = "OK" if avg < target_ms else "OVER BUDGET"
        print(f"  {num_npcs} NPCs: {avg:.2f}ms — {status}")
        if avg > target_ms:
            print(f"\n  WALL FOUND: somewhere between {num_npcs//2} and {num_npcs} NPCs")
            break


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1:
        if sys.argv[1] == "bench":
            find_the_wall()
        elif sys.argv[1] == "wall":
            find_the_wall()
        else:
            try:
                num = int(sys.argv[1])
                run_interactive(num)
            except ValueError:
                print("Usage: python herb_stress.py [num_npcs | bench | wall]")
    else:
        run_interactive(3)
