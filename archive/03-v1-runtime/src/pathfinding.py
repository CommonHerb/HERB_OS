"""
HERB Pathfinding Experiments — Session 18

Exploring whether A* / pathfinding can be expressed as HERB rules,
or if it belongs in the native layer.

Key insight to test: A* is iterative (expand frontier, track costs, backtrack).
HERB is reactive (facts trigger rules trigger facts). Can we bridge this gap?

Approach 1: Wave Expansion (BFS as rules)
- Goal emits distance 0
- Each tile derives distance from adjacent tiles
- Movement follows decreasing distance
- Pro: Pure HERB, no native code
- Con: May need many micro-iterations, expensive for large grids

Approach 2: Pre-computed distance fields
- For static obstacles, compute distances once
- Store as facts: (tile, dist_to, goal, distance)
- Movement rules just follow the gradient
- Pro: Fast runtime
- Con: O(N²) facts for N tiles × goals

Approach 3: Native A*, HERB movement
- Python computes path, injects (npc, next_step, tile) facts
- HERB rules handle the movement
- Pro: Fast, handles complex pathfinding
- Con: Breaks "everything is rules" purity

Session 18 — February 4, 2026
"""

import time
from typing import Optional
from herb_core import World, Var, Expr, NotExistsExpr

# Variables
X, Y, Z = Var('x'), Var('y'), Var('z')
T, D, D2 = Var('t'), Var('d'), Var('d2')
N, LOC, DEST = Var('n'), Var('loc'), Var('dest')
ADJACENT = Var('adjacent')


def create_grid_world(width: int = 5, height: int = 5) -> World:
    """
    Create a 5x5 grid world with some obstacles.

    Grid layout (. = passable, # = obstacle):
        0   1   2   3   4
      +---+---+---+---+---+
    0 | . | . | . | # | . |
      +---+---+---+---+---+
    1 | . | # | . | # | . |
      +---+---+---+---+---+
    2 | . | # | . | . | . |
      +---+---+---+---+---+
    3 | . | . | . | # | . |
      +---+---+---+---+---+
    4 | . | . | . | . | . |
      +---+---+---+---+---+

    Start: (0, 0) - top left
    Goal:  (4, 4) - bottom right
    """
    world = World("grid")

    # Declare functional relations
    world.declare_functional("location")
    world.declare_functional("destination")
    world.declare_functional("distance_to_goal")  # For wave expansion

    # Obstacles at specific positions
    obstacles = {(3, 0), (1, 1), (3, 1), (1, 2), (3, 3)}

    # Create tiles (initialize with "infinite" distance for wave expansion)
    INFINITY = 999999
    for y in range(height):
        for x in range(width):
            tile = f"tile_{x}_{y}"
            if (x, y) not in obstacles:
                world.assert_fact(tile, "is_a", "tile")
                world.assert_fact(tile, "pos_x", x)
                world.assert_fact(tile, "pos_y", y)
                world.assert_fact(tile, "distance_to_goal", INFINITY)
            else:
                world.assert_fact(tile, "is_a", "obstacle")

    # Create adjacency (4-directional, only between passable tiles)
    for y in range(height):
        for x in range(width):
            if (x, y) in obstacles:
                continue
            tile = f"tile_{x}_{y}"

            # Check all 4 directions
            for dx, dy in [(0, 1), (0, -1), (1, 0), (-1, 0)]:
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height:
                    if (nx, ny) not in obstacles:
                        neighbor = f"tile_{nx}_{ny}"
                        world.assert_fact(tile, "adjacent", neighbor)

    return world, obstacles


def print_grid(world: World, width: int = 5, height: int = 5,
               npc_locations: dict = None, show_distances: bool = False):
    """Print the grid state."""
    obstacles = set()
    for y in range(height):
        for x in range(width):
            tile = f"tile_{x}_{y}"
            is_obs = world.query((tile, "is_a", "obstacle"))
            if is_obs:
                obstacles.add((x, y))

    # Get NPC locations
    npc_pos = {}
    if npc_locations:
        for npc, (nx, ny) in npc_locations.items():
            npc_pos[(nx, ny)] = npc[0].upper()  # First letter

    # Get distances
    distances = {}
    if show_distances:
        for y in range(height):
            for x in range(width):
                tile = f"tile_{x}_{y}"
                dist_results = world.query((tile, "distance_to_goal", D))
                if dist_results:
                    distances[(x, y)] = dist_results[0]['d']

    print(f"\n    {'   '.join(str(i) for i in range(width))}")
    print("  +" + "---+" * width)

    for y in range(height):
        row = f"{y} |"
        for x in range(width):
            if (x, y) in obstacles:
                cell = " # "
            elif (x, y) in npc_pos:
                cell = f" {npc_pos[(x, y)]} "
            elif show_distances and (x, y) in distances:
                d = distances[(x, y)]
                cell = f" {d:1} " if d < 10 else f"{d:2} "
            else:
                cell = " . "
            row += cell + "|"
        print(row)
        print("  +" + "---+" * width)


# =============================================================================
# APPROACH 1: Wave Expansion (BFS as rules within a single tick)
# =============================================================================

def setup_wave_expansion_rules(world: World):
    """
    Set up rules for BFS-style wave expansion from goal.

    KEY INSIGHT: We CAN'T use not-exists on the same relation we produce —
    that creates a negative self-dependency cycle in stratification.

    Solution: Initialize ALL tiles with "infinite" distance (999999), then
    improve. The rule only fires if the new distance is strictly smaller.
    No negation needed!

    This is Dijkstra/Bellman-Ford style: relax edges until no improvement.
    FUNCTIONAL auto-retracts old distances when new ones are asserted.
    Terminates when fixpoint reached (no more improvements possible).

    The DEFERRED modifier creates wave-like propagation across micro-iterations.
    """

    # Rule: Propagate distance to adjacent tiles
    # If adjacent tile has distance D, and D+1 < my distance, improve
    world.add_derivation_rule(
        "wave_expand",
        patterns=[
            (T, "is_a", "tile"),
            (T, "distance_to_goal", D2),  # My current distance
            (T, "adjacent", ADJACENT),
            (ADJACENT, "distance_to_goal", D),  # Neighbor's distance
        ],
        template=(T, "distance_to_goal", Expr('+', [D, 1])),
        # Only improve if neighbor + 1 is strictly better
        guard=Expr('<', [Expr('+', [D, 1]), D2]),
        deferred=True  # Wave expands in micro-iterations
    )


def run_wave_expansion_demo():
    """
    Demo: BFS wave expansion from goal to all tiles.

    This tests whether HERB can compute shortest paths using rules.
    """
    print("=" * 60)
    print("WAVE EXPANSION DEMO (BFS as rules)")
    print("=" * 60)

    world, obstacles = create_grid_world()
    setup_wave_expansion_rules(world)

    # Goal is bottom-right (override infinity with 0)
    goal_tile = "tile_4_4"
    world.assert_fact(goal_tile, "distance_to_goal", 0)

    print("\nInitial grid (G = goal):")
    print_grid(world, show_distances=True)

    # Run one tick — this should expand the wave fully
    start = time.perf_counter()
    world.advance(max_micro_iterations=50)  # Might need many micro-iters
    elapsed = time.perf_counter() - start

    print(f"\nAfter wave expansion ({elapsed*1000:.2f}ms):")
    print_grid(world, show_distances=True)

    # Check if start is reachable
    start_tile = "tile_0_0"
    start_dist = world.query((start_tile, "distance_to_goal", D))

    if start_dist:
        print(f"\nPath length from (0,0) to (4,4): {start_dist[0]['d']} steps")
    else:
        print("\nStart tile not reachable!")

    return elapsed


# =============================================================================
# APPROACH 2: Movement following the gradient
# =============================================================================

def setup_movement_rules(world: World):
    """
    Rules for NPCs to move toward goals following the distance gradient.

    Each tick, NPC moves to adjacent tile with lower distance_to_goal.
    """

    # NPC is done moving when at destination
    world.add_derivation_rule(
        "reached_destination",
        patterns=[
            (N, "is_a", "npc"),
            (N, "location", LOC),
            (N, "destination", LOC),  # Same location = arrived
        ],
        template=(N, "at_destination", True),
        once_per_tick=True
    )

    # NPC moves toward goal (picks adjacent tile with lower distance)
    # This is greedy descent on the distance field
    # CRITICAL: once_key_vars=['n'] means "one move per NPC per tick"
    # Without this, moving changes bindings, allowing more moves
    world.add_derivation_rule(
        "npc_step_toward_goal",
        patterns=[
            (N, "is_a", "npc"),
            (N, "location", LOC),
            (N, "destination", DEST),
            (LOC, "distance_to_goal", D),
            (LOC, "adjacent", ADJACENT),
            (ADJACENT, "distance_to_goal", D2),
        ],
        template=(N, "location", ADJACENT),
        guard=Expr('and', [
            Expr('not=', [LOC, DEST]),  # Not at destination
            Expr('<', [D2, D])          # Adjacent has lower distance
        ]),
        once_per_tick=True,
        once_key_vars=['n']  # One move per NPC per tick
    )


def run_movement_demo():
    """
    Demo: NPC follows pre-computed distance gradient to goal.
    """
    print("\n" + "=" * 60)
    print("MOVEMENT DEMO (following gradient)")
    print("=" * 60)

    world, obstacles = create_grid_world()
    setup_wave_expansion_rules(world)
    setup_movement_rules(world)

    # Goal is bottom-right (override infinity with 0)
    goal_tile = "tile_4_4"
    world.assert_fact(goal_tile, "distance_to_goal", 0)

    # Create NPC at start
    world.assert_fact("guard", "is_a", "npc")
    world.assert_fact("guard", "location", "tile_0_0")
    world.assert_fact("guard", "destination", goal_tile)

    # Run wave expansion first
    print("\nStep 0: Computing distances...")
    world.advance(max_micro_iterations=50)

    # Get guard location
    def get_npc_location(world, npc):
        loc = world.query((npc, "location", X))
        if loc:
            tile = loc[0]['x']
            # Parse tile_X_Y
            parts = tile.split('_')
            return (int(parts[1]), int(parts[2]))
        return None

    print_grid(world, npc_locations={"guard": get_npc_location(world, "guard")})

    # Move NPC step by step
    tick_times = []
    for step in range(15):  # Max steps
        start = time.perf_counter()
        world.advance()
        tick_times.append(time.perf_counter() - start)

        loc = get_npc_location(world, "guard")
        at_dest = world.query(("guard", "at_destination", True))

        print(f"\nStep {step + 1}: Guard at {loc}")
        print_grid(world, npc_locations={"guard": loc})

        if at_dest:
            print("\n*** Guard reached destination! ***")
            break

    print(f"\nTick times (ms): {[f'{t*1000:.2f}' for t in tick_times]}")
    print(f"Average: {sum(tick_times)/len(tick_times)*1000:.2f}ms")


# =============================================================================
# APPROACH 3: Multiple NPCs, shared distance field
# =============================================================================

def run_multi_npc_demo():
    """
    Demo: Multiple NPCs navigating to same goal.

    Tests performance with multiple simultaneous pathfinders.
    """
    print("\n" + "=" * 60)
    print("MULTI-NPC DEMO (shared distance field)")
    print("=" * 60)

    world, obstacles = create_grid_world()
    setup_wave_expansion_rules(world)
    setup_movement_rules(world)

    # Goal is center (override infinity with 0)
    goal_tile = "tile_2_2"
    world.assert_fact(goal_tile, "distance_to_goal", 0)

    # Create 4 NPCs at corners
    npcs = [
        ("npc_a", "tile_0_0"),
        ("npc_b", "tile_4_0"),
        ("npc_c", "tile_0_4"),
        ("npc_d", "tile_4_4"),
    ]

    for npc, start in npcs:
        world.assert_fact(npc, "is_a", "npc")
        world.assert_fact(npc, "location", start)
        world.assert_fact(npc, "destination", goal_tile)

    # Run wave expansion first
    print("\nStep 0: Computing distances...")
    start = time.perf_counter()
    world.advance(max_micro_iterations=50)
    wave_time = time.perf_counter() - start
    print(f"Wave expansion: {wave_time*1000:.2f}ms")

    def get_npc_location(world, npc):
        loc = world.query((npc, "location", X))
        if loc:
            tile = loc[0]['x']
            parts = tile.split('_')
            return (int(parts[1]), int(parts[2]))
        return None

    npc_locs = {npc: get_npc_location(world, npc) for npc, _ in npcs}
    print_grid(world, npc_locations=npc_locs, show_distances=True)

    # Move all NPCs
    tick_times = []
    for step in range(10):
        start = time.perf_counter()
        world.advance()
        tick_times.append(time.perf_counter() - start)

        npc_locs = {npc: get_npc_location(world, npc) for npc, _ in npcs}

        print(f"\nStep {step + 1}:")
        for npc, loc in npc_locs.items():
            at_dest = world.query((npc, "at_destination", True))
            status = " (ARRIVED)" if at_dest else ""
            print(f"  {npc}: {loc}{status}")

        # Check if all arrived
        all_arrived = all(
            world.query((npc, "at_destination", True))
            for npc, _ in npcs
        )
        if all_arrived:
            print("\n*** All NPCs reached destination! ***")
            break

    print(f"\nTick times (ms): {[f'{t*1000:.2f}' for t in tick_times]}")
    print(f"Average: {sum(tick_times)/len(tick_times)*1000:.2f}ms")
    print(f"Max: {max(tick_times)*1000:.2f}ms")
    print(f"Target (600ms): {'PASS' if max(tick_times) < 0.6 else 'FAIL'}")


# =============================================================================
# APPROACH 4: Dynamic pathfinding (goal changes)
# =============================================================================

def run_dynamic_goal_demo():
    """
    Demo: NPC destination changes mid-journey.

    Tests if the system handles changing goals gracefully.
    This requires re-computing the distance field when the goal changes.
    """
    print("\n" + "=" * 60)
    print("DYNAMIC GOAL DEMO (goal changes)")
    print("=" * 60)

    world, obstacles = create_grid_world()
    setup_wave_expansion_rules(world)
    setup_movement_rules(world)

    # Initial goal (override infinity with 0)
    world.assert_fact("tile_4_4", "distance_to_goal", 0)

    # Create NPC
    world.assert_fact("guard", "is_a", "npc")
    world.assert_fact("guard", "location", "tile_0_0")
    world.assert_fact("guard", "destination", "tile_4_4")

    # Compute initial distances
    print("\nStep 0: Initial goal at (4,4)")
    world.advance(max_micro_iterations=50)

    def get_npc_location(world, npc):
        loc = world.query((npc, "location", X))
        if loc:
            tile = loc[0]['x']
            parts = tile.split('_')
            return (int(parts[1]), int(parts[2]))
        return None

    # Move 3 steps toward original goal
    for step in range(3):
        world.advance()
        loc = get_npc_location(world, "guard")
        print(f"Step {step + 1}: Guard at {loc}")

    # Change goal!
    print("\n*** Goal changes to (4,0)! ***")

    # Reset all distances to infinity
    INFINITY = 999999
    for dist in world.query((T, "distance_to_goal", D)):
        world.assert_fact(dist['t'], "distance_to_goal", INFINITY)

    # Set new goal (override infinity with 0)
    world.assert_fact("tile_4_0", "distance_to_goal", 0)

    # Update NPC destination
    old_dest = world.query(("guard", "destination", X))
    if old_dest:
        world.retract_fact("guard", "destination", old_dest[0]['x'])
    world.assert_fact("guard", "destination", "tile_4_0")

    # Recompute distances
    world.advance(max_micro_iterations=50)

    # Continue moving
    for step in range(10):
        world.advance()
        loc = get_npc_location(world, "guard")
        at_dest = world.query(("guard", "at_destination", True))
        print(f"Step {step + 4}: Guard at {loc}")

        if at_dest:
            print("\n*** Guard reached new destination! ***")
            break


# =============================================================================
# PERFORMANCE TEST: Larger grid
# =============================================================================

def run_performance_test(grid_size: int = 10):
    """
    Test pathfinding performance on a larger grid.
    """
    print("\n" + "=" * 60)
    print(f"PERFORMANCE TEST ({grid_size}x{grid_size} grid)")
    print("=" * 60)

    world = World("perf_test")
    world.declare_functional("location")
    world.declare_functional("destination")
    world.declare_functional("distance_to_goal")

    # Create grid with scattered obstacles (10% density)
    import random
    random.seed(42)
    obstacles = set()
    for _ in range(grid_size * grid_size // 10):
        x, y = random.randint(0, grid_size-1), random.randint(0, grid_size-1)
        if (x, y) != (0, 0) and (x, y) != (grid_size-1, grid_size-1):
            obstacles.add((x, y))

    # Create tiles (initialize with "infinite" distance)
    INFINITY = 999999
    for y in range(grid_size):
        for x in range(grid_size):
            tile = f"tile_{x}_{y}"
            if (x, y) not in obstacles:
                world.assert_fact(tile, "is_a", "tile")
                world.assert_fact(tile, "pos_x", x)
                world.assert_fact(tile, "pos_y", y)
                world.assert_fact(tile, "distance_to_goal", INFINITY)

    # Create adjacency
    for y in range(grid_size):
        for x in range(grid_size):
            if (x, y) in obstacles:
                continue
            tile = f"tile_{x}_{y}"
            for dx, dy in [(0, 1), (0, -1), (1, 0), (-1, 0)]:
                nx, ny = x + dx, y + dy
                if 0 <= nx < grid_size and 0 <= ny < grid_size:
                    if (nx, ny) not in obstacles:
                        neighbor = f"tile_{nx}_{ny}"
                        world.assert_fact(tile, "adjacent", neighbor)

    setup_wave_expansion_rules(world)
    setup_movement_rules(world)

    # Set goal (override infinity with 0)
    goal_tile = f"tile_{grid_size-1}_{grid_size-1}"
    world.assert_fact(goal_tile, "distance_to_goal", 0)

    # Measure wave expansion
    print(f"\nTiles: {grid_size * grid_size - len(obstacles)}")
    print(f"Obstacles: {len(obstacles)}")

    start = time.perf_counter()
    world.advance(max_micro_iterations=grid_size * 2)
    wave_time = time.perf_counter() - start
    print(f"\nWave expansion: {wave_time*1000:.2f}ms")

    # Verify start is reachable
    start_tile = "tile_0_0"
    start_dist = world.query((start_tile, "distance_to_goal", D))
    if start_dist:
        print(f"Path length: {start_dist[0]['d']} steps")
    else:
        print("Start not reachable!")
        return

    # Test multi-NPC movement
    npc_count = 10
    for i in range(npc_count):
        npc = f"npc_{i}"
        # Random start positions
        while True:
            x, y = random.randint(0, grid_size-1), random.randint(0, grid_size-1)
            if (x, y) not in obstacles:
                break
        world.assert_fact(npc, "is_a", "npc")
        world.assert_fact(npc, "location", f"tile_{x}_{y}")
        world.assert_fact(npc, "destination", goal_tile)

    print(f"\nNPCs: {npc_count}")

    # Measure movement ticks
    tick_times = []
    for _ in range(5):
        start = time.perf_counter()
        world.advance()
        tick_times.append(time.perf_counter() - start)

    print(f"Movement tick times (ms): {[f'{t*1000:.2f}' for t in tick_times]}")
    print(f"Average: {sum(tick_times)/len(tick_times)*1000:.2f}ms")
    print(f"Max: {max(tick_times)*1000:.2f}ms")
    print(f"Target (600ms): {'PASS' if max(tick_times) < 0.6 else 'FAIL'}")


# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    # Run all demos
    run_wave_expansion_demo()
    run_movement_demo()
    run_multi_npc_demo()
    run_dynamic_goal_demo()
    run_performance_test(10)
    run_performance_test(20)
