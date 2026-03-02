"""
HERB Pathfinding — Native A* with HERB Movement

Session 18 Finding: BFS-as-rules works but doesn't scale (1.5s for 20x20 grid).
Solution: Compute paths in Python, inject next_step facts into HERB.

This is the "HERB as policy, native as mechanism" pattern from OS experiments.
- Native layer: A* pathfinding (fast, algorithmic)
- HERB layer: Movement rules, collision avoidance, NPC behavior (declarative)

The boundary is clean: native computes WHERE to go, HERB decides IF and HOW to move.

Session 18 — February 4, 2026
"""

import time
import heapq
from typing import Optional
from herb_core import World, Var, Expr

# Variables
X, Y, Z = Var('x'), Var('y'), Var('z')
N, LOC, DEST = Var('n'), Var('loc'), Var('dest')
NEXT = Var('next')


# =============================================================================
# NATIVE A* PATHFINDING
# =============================================================================

def a_star(world: World, start: str, goal: str) -> Optional[list[str]]:
    """
    Native A* pathfinding implementation.

    Reads grid from world facts:
    - (tile, is_a, tile) — passable tiles
    - (tile, adjacent, neighbor) — adjacency
    - (tile, pos_x, x), (tile, pos_y, y) — for heuristic

    Returns path as list of tiles [start, ..., goal], or None if unreachable.
    """
    # Get goal position for heuristic
    goal_pos = _get_tile_pos(world, goal)
    if goal_pos is None:
        return None

    # A* data structures
    open_set = [(0, start)]  # (f_score, tile)
    came_from = {}
    g_score = {start: 0}
    f_score = {start: _heuristic(world, start, goal_pos)}
    closed_set = set()

    while open_set:
        _, current = heapq.heappop(open_set)

        if current == goal:
            # Reconstruct path
            path = [current]
            while current in came_from:
                current = came_from[current]
                path.append(current)
            return list(reversed(path))

        if current in closed_set:
            continue
        closed_set.add(current)

        # Get neighbors
        for neighbor_binding in world.query((current, "adjacent", Var('n'))):
            neighbor = neighbor_binding['n']
            if neighbor in closed_set:
                continue

            tentative_g = g_score[current] + 1  # All edges cost 1

            if tentative_g < g_score.get(neighbor, float('inf')):
                came_from[neighbor] = current
                g_score[neighbor] = tentative_g
                f = tentative_g + _heuristic(world, neighbor, goal_pos)
                f_score[neighbor] = f
                heapq.heappush(open_set, (f, neighbor))

    return None  # No path found


def _get_tile_pos(world: World, tile: str) -> Optional[tuple[int, int]]:
    """Get (x, y) position of a tile."""
    x_res = world.query((tile, "pos_x", Var('x')))
    y_res = world.query((tile, "pos_y", Var('y')))
    if x_res and y_res:
        return (x_res[0]['x'], y_res[0]['y'])
    return None


def _heuristic(world: World, tile: str, goal_pos: tuple[int, int]) -> float:
    """Manhattan distance heuristic."""
    pos = _get_tile_pos(world, tile)
    if pos is None:
        return float('inf')
    return abs(pos[0] - goal_pos[0]) + abs(pos[1] - goal_pos[1])


# =============================================================================
# HERB INTEGRATION: PATH INJECTION
# =============================================================================

def inject_path_step(world: World, npc: str, path: list[str]):
    """
    Inject next step from path into world as a fact.

    The NPC's path is stored, and each tick we inject the next step.
    HERB rules handle the actual movement.
    """
    if len(path) < 2:
        return  # Already at destination or invalid path

    # Current position is path[0], next position is path[1]
    next_tile = path[1]

    # Retract old next_step if exists
    old_next = world.query((npc, "path_next", Var('t')))
    if old_next:
        world.retract_fact(npc, "path_next", old_next[0]['t'])

    # Assert new next step
    world.assert_fact(npc, "path_next", next_tile)


def setup_native_movement_rules(world: World):
    """
    HERB rules for movement using native-computed paths.

    The native layer computes paths and injects (npc, path_next, tile).
    HERB rules handle:
    - Movement execution
    - Collision avoidance
    - Destination checking
    """
    world.declare_functional("location")
    world.declare_functional("path_next")
    world.declare_functional("destination")

    # Rule: Move to path_next if valid
    world.add_derivation_rule(
        "follow_path",
        patterns=[
            (N, "is_a", "npc"),
            (N, "location", LOC),
            (N, "path_next", NEXT),
            (LOC, "adjacent", NEXT),  # Verify adjacency
        ],
        template=(N, "location", NEXT),
        once_per_tick=True,
        once_key_vars=['n']
    )

    # Rule: Clear path_next after moving (deferred to ensure move happens first)
    world.add_derivation_rule(
        "clear_path_next",
        patterns=[
            (N, "is_a", "npc"),
            (N, "location", LOC),
            (N, "path_next", LOC),  # We're at the next step
        ],
        templates=[(N, "path_next", None)],  # Clear it
        retractions=[(N, "path_next", LOC)],
        deferred=True
    )

    # Rule: Detect arrival
    world.add_derivation_rule(
        "check_arrival",
        patterns=[
            (N, "is_a", "npc"),
            (N, "location", LOC),
            (N, "destination", LOC),
        ],
        template=(N, "at_destination", True),
        once_per_tick=True
    )


# =============================================================================
# PATH MANAGER: TRACKS PATHS AND INJECTS STEPS
# =============================================================================

class PathManager:
    """
    Manages NPC paths and injects next steps each tick.

    Usage:
        pm = PathManager(world)
        pm.set_destination(npc, goal)  # Computes path
        pm.tick()  # Injects next step for all NPCs
    """

    def __init__(self, world: World):
        self.world = world
        self.paths: dict[str, list[str]] = {}  # npc -> remaining path

    def set_destination(self, npc: str, goal: str) -> bool:
        """
        Set destination and compute path for NPC.
        Returns True if path found, False otherwise.
        """
        # Get current location
        loc = self.world.query((npc, "location", Var('l')))
        if not loc:
            return False

        start = loc[0]['l']
        path = a_star(self.world, start, goal)

        if path is None:
            return False

        self.paths[npc] = path
        self.world.assert_fact(npc, "destination", goal)
        return True

    def tick(self):
        """
        Inject next step for all NPCs with active paths.
        Call this BEFORE world.advance().
        """
        for npc in list(self.paths.keys()):
            path = self.paths[npc]

            # Update path based on current position
            loc = self.world.query((npc, "location", Var('l')))
            if not loc:
                continue

            current = loc[0]['l']

            # Trim path to current position
            if current in path:
                idx = path.index(current)
                path = path[idx:]
                self.paths[npc] = path

            if len(path) < 2:
                # At destination
                del self.paths[npc]
                continue

            # Inject next step
            inject_path_step(self.world, npc, path)


# =============================================================================
# DEMO: NATIVE A* + HERB MOVEMENT
# =============================================================================

def create_grid_world(width: int = 10, height: int = 10) -> tuple[World, set]:
    """Create a grid world for testing."""
    import random
    random.seed(42)

    world = World("native_pathfinding")
    world.declare_functional("location")
    world.declare_functional("destination")
    world.declare_functional("path_next")

    # 10% obstacles
    obstacles = set()
    for _ in range(width * height // 10):
        x, y = random.randint(0, width-1), random.randint(0, height-1)
        if (x, y) != (0, 0) and (x, y) != (width-1, height-1):
            obstacles.add((x, y))

    # Create tiles
    for y in range(height):
        for x in range(width):
            tile = f"tile_{x}_{y}"
            if (x, y) not in obstacles:
                world.assert_fact(tile, "is_a", "tile")
                world.assert_fact(tile, "pos_x", x)
                world.assert_fact(tile, "pos_y", y)

    # Create adjacency
    for y in range(height):
        for x in range(width):
            if (x, y) in obstacles:
                continue
            tile = f"tile_{x}_{y}"
            for dx, dy in [(0, 1), (0, -1), (1, 0), (-1, 0)]:
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height:
                    if (nx, ny) not in obstacles:
                        neighbor = f"tile_{nx}_{ny}"
                        world.assert_fact(tile, "adjacent", neighbor)

    return world, obstacles


def run_native_pathfinding_demo():
    """Demo: Native A* + HERB movement."""
    print("=" * 60)
    print("NATIVE A* + HERB MOVEMENT DEMO")
    print("=" * 60)

    world, obstacles = create_grid_world(10, 10)
    setup_native_movement_rules(world)
    pm = PathManager(world)

    # Create NPCs
    npcs = ["npc_a", "npc_b", "npc_c", "npc_d", "npc_e"]
    starts = ["tile_0_0", "tile_9_0", "tile_0_9", "tile_9_9", "tile_5_5"]
    goal = "tile_5_5"

    for npc, start in zip(npcs, starts):
        world.assert_fact(npc, "is_a", "npc")
        world.assert_fact(npc, "location", start)

    # Compute paths (one-time cost)
    print("\nComputing paths with native A*...")
    start_time = time.perf_counter()

    for npc in npcs:
        if npc != "npc_e":  # npc_e starts at goal
            pm.set_destination(npc, goal)

    path_time = time.perf_counter() - start_time
    print(f"Path computation: {path_time*1000:.2f}ms for {len(npcs)-1} NPCs")

    # Report path lengths
    for npc in npcs:
        if npc in pm.paths:
            print(f"  {npc}: {len(pm.paths[npc])-1} steps")

    # Run movement ticks
    print("\nMovement ticks:")
    tick_times = []

    for tick in range(20):
        pm.tick()  # Inject next steps

        start_time = time.perf_counter()
        world.advance()
        tick_times.append(time.perf_counter() - start_time)

        # Check if all done
        all_done = all(npc not in pm.paths for npc in npcs)
        if all_done:
            print(f"  All NPCs reached destination at tick {tick + 1}")
            break

    print(f"\nTick times (ms): {[f'{t*1000:.2f}' for t in tick_times[:10]]}")
    print(f"Average: {sum(tick_times)/len(tick_times)*1000:.2f}ms")
    print(f"Max: {max(tick_times)*1000:.2f}ms")
    print(f"Target (600ms): {'PASS' if max(tick_times) < 0.6 else 'FAIL'}")


def run_large_scale_test():
    """Test native pathfinding at scale."""
    print("\n" + "=" * 60)
    print("LARGE SCALE TEST: 50x50 grid, 50 NPCs")
    print("=" * 60)

    import random
    random.seed(42)

    world, obstacles = create_grid_world(50, 50)
    setup_native_movement_rules(world)
    pm = PathManager(world)

    # Create 50 NPCs at random positions
    npc_count = 50
    for i in range(npc_count):
        npc = f"npc_{i}"
        while True:
            x, y = random.randint(0, 49), random.randint(0, 49)
            tile = f"tile_{x}_{y}"
            if (x, y) not in obstacles:
                world.assert_fact(npc, "is_a", "npc")
                world.assert_fact(npc, "location", tile)
                break

    goal = "tile_25_25"

    # Compute paths
    print("\nComputing paths...")
    start_time = time.perf_counter()

    for i in range(npc_count):
        npc = f"npc_{i}"
        pm.set_destination(npc, goal)

    path_time = time.perf_counter() - start_time
    print(f"Path computation: {path_time*1000:.2f}ms for {npc_count} NPCs")

    # Run a few movement ticks
    print("\nMovement ticks:")
    tick_times = []

    for tick in range(10):
        pm.tick()

        start_time = time.perf_counter()
        world.advance()
        tick_times.append(time.perf_counter() - start_time)

    print(f"Tick times (ms): {[f'{t*1000:.2f}' for t in tick_times]}")
    print(f"Average: {sum(tick_times)/len(tick_times)*1000:.2f}ms")
    print(f"Max: {max(tick_times)*1000:.2f}ms")
    print(f"Target (600ms): {'PASS' if max(tick_times) < 0.6 else 'FAIL'}")


def compare_approaches():
    """Compare native vs rule-based pathfinding."""
    print("\n" + "=" * 60)
    print("PERFORMANCE COMPARISON: Native vs Rule-Based")
    print("=" * 60)

    import random

    for grid_size in [5, 10, 20, 30]:
        random.seed(42)

        # Native approach
        world, obstacles = create_grid_world(grid_size, grid_size)
        start = time.perf_counter()
        path = a_star(world, "tile_0_0", f"tile_{grid_size-1}_{grid_size-1}")
        native_time = time.perf_counter() - start

        path_len = len(path) - 1 if path else "N/A"

        print(f"\n{grid_size}x{grid_size} grid ({grid_size*grid_size} tiles):")
        print(f"  Native A*: {native_time*1000:.2f}ms, path length: {path_len}")

        # Note: Rule-based times from earlier tests
        # 5x5: ~11ms, 10x10: ~142ms, 20x20: ~1469ms
        rule_times = {5: 11, 10: 142, 20: 1469, 30: "est. 5000+"}
        rule_time = rule_times.get(grid_size, "N/A")
        print(f"  Rule-based: ~{rule_time}ms")

        if isinstance(rule_time, int) and native_time > 0:
            speedup = rule_time / (native_time * 1000)
            print(f"  Speedup: {speedup:.0f}x")


# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    run_native_pathfinding_demo()
    run_large_scale_test()
    compare_approaches()
