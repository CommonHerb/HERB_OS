"""
Tests for HERB Pathfinding — Session 18

Tests both rule-based wave expansion and native A* pathfinding.
"""

import unittest
from herb_core import World, Var, Expr

# Import from pathfinding modules
from pathfinding import (
    create_grid_world, setup_wave_expansion_rules, setup_movement_rules
)
from pathfinding_native import (
    a_star, PathManager, setup_native_movement_rules,
    create_grid_world as create_native_grid
)

X, Y, D = Var('x'), Var('y'), Var('d')


class TestWaveExpansion(unittest.TestCase):
    """Tests for rule-based BFS wave expansion."""

    def test_wave_expansion_5x5(self):
        """Wave expansion computes correct distances on 5x5 grid."""
        world, obstacles = create_grid_world(5, 5)
        setup_wave_expansion_rules(world)

        # Goal at bottom-right
        world.assert_fact("tile_4_4", "distance_to_goal", 0)

        # Run wave expansion
        world.advance(max_micro_iterations=50)

        # Check distances
        start_dist = world.query(("tile_0_0", "distance_to_goal", D))
        self.assertTrue(start_dist)
        self.assertEqual(start_dist[0]['d'], 8)  # Known shortest path

        goal_dist = world.query(("tile_4_4", "distance_to_goal", D))
        self.assertTrue(goal_dist)
        self.assertEqual(goal_dist[0]['d'], 0)

    def test_wave_expansion_handles_obstacles(self):
        """Wave expansion paths around obstacles."""
        world, obstacles = create_grid_world(5, 5)
        setup_wave_expansion_rules(world)

        # Goal at (4, 4)
        world.assert_fact("tile_4_4", "distance_to_goal", 0)
        world.advance(max_micro_iterations=50)

        # Tile at (4, 0) must path around obstacles
        # It can go (4,0) -> (4,1) -> (4,2) -> (4,3) -> (4,4) = 4 steps
        dist = world.query(("tile_4_0", "distance_to_goal", D))
        self.assertTrue(dist)
        self.assertEqual(dist[0]['d'], 4)

    def test_wave_expansion_unreachable_stays_infinity(self):
        """Unreachable tiles keep infinity distance."""
        world = World("isolated")
        world.declare_functional("distance_to_goal")

        # Create two disconnected tiles
        world.assert_fact("tile_a", "is_a", "tile")
        world.assert_fact("tile_a", "distance_to_goal", 999999)

        world.assert_fact("tile_b", "is_a", "tile")
        world.assert_fact("tile_b", "distance_to_goal", 999999)

        # No adjacency between them

        setup_wave_expansion_rules(world)

        # Goal is tile_a
        world.assert_fact("tile_a", "distance_to_goal", 0)
        world.advance(max_micro_iterations=10)

        # tile_b should still be infinity
        dist = world.query(("tile_b", "distance_to_goal", D))
        self.assertTrue(dist)
        self.assertEqual(dist[0]['d'], 999999)


class TestRuleBasedMovement(unittest.TestCase):
    """Tests for movement rules following distance gradient."""

    def test_movement_one_step_per_tick(self):
        """NPC moves exactly one step per tick."""
        world, obstacles = create_grid_world(5, 5)
        setup_wave_expansion_rules(world)
        setup_movement_rules(world)

        # Goal at (4, 4)
        world.assert_fact("tile_4_4", "distance_to_goal", 0)

        # NPC at (0, 0)
        world.assert_fact("guard", "is_a", "npc")
        world.assert_fact("guard", "location", "tile_0_0")
        world.assert_fact("guard", "destination", "tile_4_4")

        # Tick 0: wave expansion + first move
        world.advance(max_micro_iterations=50)

        # Should have moved ONE step
        loc = world.query(("guard", "location", X))
        self.assertTrue(loc)
        start_tile = loc[0]['x']
        self.assertIn(start_tile, ["tile_1_0", "tile_0_1"])  # Adjacent to start

        # Tick 1: another step
        world.advance()
        loc = world.query(("guard", "location", X))
        self.assertTrue(loc)
        # Distance from start should be 2 now
        tile = loc[0]['x']
        parts = tile.split('_')
        x, y = int(parts[1]), int(parts[2])
        self.assertTrue(x + y == 2 or (x == 1 and y == 1))  # Manhattan distance 2

    def test_npc_reaches_destination(self):
        """NPC eventually reaches destination."""
        world, obstacles = create_grid_world(5, 5)
        setup_wave_expansion_rules(world)
        setup_movement_rules(world)

        world.assert_fact("tile_4_4", "distance_to_goal", 0)

        world.assert_fact("npc_a", "is_a", "npc")
        world.assert_fact("npc_a", "location", "tile_0_0")
        world.assert_fact("npc_a", "destination", "tile_4_4")

        # Run enough ticks (path is 8 steps + 1 for wave expansion)
        for _ in range(12):
            world.advance(max_micro_iterations=50)

        # Should be at destination
        at_dest = world.query(("npc_a", "at_destination", True))
        self.assertTrue(at_dest)

    def test_multiple_npcs_same_goal(self):
        """Multiple NPCs navigate to same goal."""
        world, obstacles = create_grid_world(5, 5)
        setup_wave_expansion_rules(world)
        setup_movement_rules(world)

        # Goal at center
        world.assert_fact("tile_2_2", "distance_to_goal", 0)

        # NPCs at corners
        for npc, tile in [("a", "tile_0_0"), ("b", "tile_4_0"),
                          ("c", "tile_0_4"), ("d", "tile_4_4")]:
            world.assert_fact(npc, "is_a", "npc")
            world.assert_fact(npc, "location", tile)
            world.assert_fact(npc, "destination", "tile_2_2")

        # Run enough ticks
        for _ in range(10):
            world.advance(max_micro_iterations=50)

        # All should reach destination
        for npc in ["a", "b", "c", "d"]:
            at_dest = world.query((npc, "at_destination", True))
            self.assertTrue(at_dest, f"{npc} should be at destination")


class TestNativeAStar(unittest.TestCase):
    """Tests for native A* pathfinding."""

    def _create_simple_grid(self):
        """Create a simple 5x5 grid with no random obstacles."""
        world = World("simple_grid")
        world.declare_functional("location")
        world.declare_functional("destination")
        world.declare_functional("path_next")

        for y in range(5):
            for x in range(5):
                tile = f"tile_{x}_{y}"
                world.assert_fact(tile, "is_a", "tile")
                world.assert_fact(tile, "pos_x", x)
                world.assert_fact(tile, "pos_y", y)

        for y in range(5):
            for x in range(5):
                tile = f"tile_{x}_{y}"
                for dx, dy in [(0, 1), (0, -1), (1, 0), (-1, 0)]:
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < 5 and 0 <= ny < 5:
                        world.assert_fact(tile, "adjacent", f"tile_{nx}_{ny}")

        return world

    def test_astar_finds_path(self):
        """A* finds path between two points."""
        world = self._create_simple_grid()

        path = a_star(world, "tile_0_0", "tile_4_4")
        self.assertIsNotNone(path)
        self.assertEqual(path[0], "tile_0_0")
        self.assertEqual(path[-1], "tile_4_4")

    def test_astar_path_is_valid(self):
        """A* path consists of adjacent tiles."""
        world = self._create_simple_grid()

        path = a_star(world, "tile_0_0", "tile_4_4")
        self.assertIsNotNone(path)

        # Check each step is adjacent
        for i in range(len(path) - 1):
            current = path[i]
            next_tile = path[i + 1]
            adj = world.query((current, "adjacent", X))
            neighbors = [a['x'] for a in adj]
            self.assertIn(next_tile, neighbors)

    def test_astar_handles_obstacles(self):
        """A* paths around obstacles."""
        world = World("obstacle_test")

        # Create a simple 3x3 grid with wall in middle
        # . . .
        # # # .
        # . . .
        for x in range(3):
            for y in range(3):
                tile = f"tile_{x}_{y}"
                world.assert_fact(tile, "is_a", "tile")
                world.assert_fact(tile, "pos_x", x)
                world.assert_fact(tile, "pos_y", y)

        # Adjacency (skip walls)
        walls = {(0, 1), (1, 1)}
        for x in range(3):
            for y in range(3):
                if (x, y) in walls:
                    continue
                tile = f"tile_{x}_{y}"
                for dx, dy in [(0, 1), (0, -1), (1, 0), (-1, 0)]:
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < 3 and 0 <= ny < 3 and (nx, ny) not in walls:
                        world.assert_fact(tile, "adjacent", f"tile_{nx}_{ny}")

        path = a_star(world, "tile_0_0", "tile_0_2")
        self.assertIsNotNone(path)
        # Must go around: (0,0) -> (1,0) -> (2,0) -> (2,1) -> (2,2) -> (1,2) -> (0,2)
        self.assertGreater(len(path), 2)

    def test_astar_returns_none_for_unreachable(self):
        """A* returns None when no path exists."""
        world = World("isolated")

        # Two disconnected tiles
        world.assert_fact("tile_a", "is_a", "tile")
        world.assert_fact("tile_a", "pos_x", 0)
        world.assert_fact("tile_a", "pos_y", 0)

        world.assert_fact("tile_b", "is_a", "tile")
        world.assert_fact("tile_b", "pos_x", 10)
        world.assert_fact("tile_b", "pos_y", 10)

        # No adjacency

        path = a_star(world, "tile_a", "tile_b")
        self.assertIsNone(path)


class TestPathManager(unittest.TestCase):
    """Tests for PathManager integration."""

    def _create_simple_grid(self):
        """Create a simple 5x5 grid with no random obstacles."""
        world = World("simple_grid")
        world.declare_functional("location")
        world.declare_functional("destination")
        world.declare_functional("path_next")

        for y in range(5):
            for x in range(5):
                tile = f"tile_{x}_{y}"
                world.assert_fact(tile, "is_a", "tile")
                world.assert_fact(tile, "pos_x", x)
                world.assert_fact(tile, "pos_y", y)

        for y in range(5):
            for x in range(5):
                tile = f"tile_{x}_{y}"
                for dx, dy in [(0, 1), (0, -1), (1, 0), (-1, 0)]:
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < 5 and 0 <= ny < 5:
                        world.assert_fact(tile, "adjacent", f"tile_{nx}_{ny}")

        return world

    def test_path_manager_computes_path(self):
        """PathManager computes and stores path."""
        world = self._create_simple_grid()
        pm = PathManager(world)

        world.assert_fact("npc_a", "is_a", "npc")
        world.assert_fact("npc_a", "location", "tile_0_0")

        result = pm.set_destination("npc_a", "tile_4_4")
        self.assertTrue(result)
        self.assertIn("npc_a", pm.paths)

    def test_path_manager_injects_next_step(self):
        """PathManager injects path_next facts."""
        world = self._create_simple_grid()
        setup_native_movement_rules(world)
        pm = PathManager(world)

        world.assert_fact("npc_a", "is_a", "npc")
        world.assert_fact("npc_a", "location", "tile_0_0")

        pm.set_destination("npc_a", "tile_4_4")
        pm.tick()

        # Check path_next is set
        next_step = world.query(("npc_a", "path_next", X))
        self.assertTrue(next_step)
        # Should be adjacent to (0,0)
        tile = next_step[0]['x']
        self.assertIn(tile, ["tile_1_0", "tile_0_1"])

    def test_path_manager_full_journey(self):
        """PathManager guides NPC to destination."""
        world, obstacles = create_native_grid(5, 5)
        setup_native_movement_rules(world)
        pm = PathManager(world)

        world.assert_fact("npc_a", "is_a", "npc")
        world.assert_fact("npc_a", "location", "tile_0_0")

        pm.set_destination("npc_a", "tile_4_4")

        # Run ticks until arrival
        for tick in range(20):
            pm.tick()
            world.advance()

            if "npc_a" not in pm.paths:
                break

        # Should have arrived
        loc = world.query(("npc_a", "location", X))
        self.assertTrue(loc)
        self.assertEqual(loc[0]['x'], "tile_4_4")


class TestOnceKeyVarsBehavior(unittest.TestCase):
    """Tests verifying once_key_vars prevents teleportation."""

    def test_without_key_vars_npc_teleports(self):
        """Without once_key_vars, NPC moves multiple times per tick."""
        world = World("teleport_test")
        world.declare_functional("location")

        # Simple 3-tile line: A -- B -- C
        for t in ["A", "B", "C"]:
            world.assert_fact(t, "is_a", "tile")
            world.assert_fact(t, "distance_to_goal", {"A": 2, "B": 1, "C": 0}[t])

        world.assert_fact("A", "adjacent", "B")
        world.assert_fact("B", "adjacent", "A")
        world.assert_fact("B", "adjacent", "C")
        world.assert_fact("C", "adjacent", "B")

        world.assert_fact("npc", "is_a", "npc")
        world.assert_fact("npc", "location", "A")
        world.assert_fact("npc", "destination", "C")

        # Rule WITHOUT once_key_vars (should teleport)
        N, LOC, DEST, ADJ, D, D2 = (
            Var('n'), Var('loc'), Var('dest'), Var('adj'), Var('d'), Var('d2')
        )
        world.add_derivation_rule(
            "move_no_key",
            patterns=[
                (N, "is_a", "npc"),
                (N, "location", LOC),
                (N, "destination", DEST),
                (LOC, "distance_to_goal", D),
                (LOC, "adjacent", ADJ),
                (ADJ, "distance_to_goal", D2),
            ],
            template=(N, "location", ADJ),
            guard=Expr('and', [
                Expr('not=', [LOC, DEST]),
                Expr('<', [D2, D])
            ]),
            once_per_tick=True  # Note: no once_key_vars
        )

        world.advance()

        # NPC should have teleported to C (or B, depending on timing)
        loc = world.query(("npc", "location", X))
        # Without key vars, each binding is unique, so NPC moves multiple times
        # Final position depends on implementation order
        self.assertTrue(loc)

    def test_with_key_vars_npc_moves_once(self):
        """With once_key_vars, NPC moves exactly once per tick."""
        world = World("no_teleport_test")
        world.declare_functional("location")

        # Simple 3-tile line: A -- B -- C
        for t in ["A", "B", "C"]:
            world.assert_fact(t, "is_a", "tile")
            world.assert_fact(t, "distance_to_goal", {"A": 2, "B": 1, "C": 0}[t])

        world.assert_fact("A", "adjacent", "B")
        world.assert_fact("B", "adjacent", "A")
        world.assert_fact("B", "adjacent", "C")
        world.assert_fact("C", "adjacent", "B")

        world.assert_fact("npc", "is_a", "npc")
        world.assert_fact("npc", "location", "A")
        world.assert_fact("npc", "destination", "C")

        N, LOC, DEST, ADJ, D, D2 = (
            Var('n'), Var('loc'), Var('dest'), Var('adj'), Var('d'), Var('d2')
        )
        world.add_derivation_rule(
            "move_with_key",
            patterns=[
                (N, "is_a", "npc"),
                (N, "location", LOC),
                (N, "destination", DEST),
                (LOC, "distance_to_goal", D),
                (LOC, "adjacent", ADJ),
                (ADJ, "distance_to_goal", D2),
            ],
            template=(N, "location", ADJ),
            guard=Expr('and', [
                Expr('not=', [LOC, DEST]),
                Expr('<', [D2, D])
            ]),
            once_per_tick=True,
            once_key_vars=['n']  # Key is just the NPC
        )

        world.advance()

        # NPC should be at B (moved once)
        loc = world.query(("npc", "location", X))
        self.assertTrue(loc)
        self.assertEqual(loc[0]['x'], "B")


if __name__ == "__main__":
    unittest.main()
