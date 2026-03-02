"""
Tests for Multi-World architecture (Verse, inheritance, exports, messaging).

Session 14 — February 4, 2026
"""

import unittest
from herb_core import World, Verse, Var, X, Y, Z


class TestVerse(unittest.TestCase):
    """Test Verse container basics."""

    def test_create_root_world(self):
        """Can create a root World in a Verse."""
        verse = Verse()
        root = verse.create_world("kernel")

        self.assertIsNotNone(root)
        self.assertEqual(root.name, "kernel")
        self.assertIsNone(root.parent)
        self.assertIs(verse.root, root)

    def test_create_child_world(self):
        """Can create child Worlds with parent."""
        verse = Verse()
        verse.create_world("kernel")
        proc_a = verse.create_world("proc_a", parent="kernel")

        self.assertEqual(proc_a.name, "proc_a")
        self.assertIs(proc_a.parent, verse.root)

    def test_duplicate_name_rejected(self):
        """Cannot create World with duplicate name."""
        verse = Verse()
        verse.create_world("kernel")

        with self.assertRaises(ValueError):
            verse.create_world("kernel")

    def test_missing_parent_rejected(self):
        """Cannot create child with nonexistent parent."""
        verse = Verse()

        with self.assertRaises(ValueError):
            verse.create_world("proc_a", parent="kernel")

    def test_multiple_roots_rejected(self):
        """Cannot create multiple root Worlds."""
        verse = Verse()
        verse.create_world("root1")

        with self.assertRaises(ValueError):
            verse.create_world("root2")


class TestInheritance(unittest.TestCase):
    """Test child inheriting parent facts."""

    def test_child_sees_parent_facts(self):
        """Child World can query facts from parent."""
        verse = Verse()
        parent = verse.create_world("game")
        child = verse.create_world("player_a", parent="game")

        # Assert fact in parent
        parent.assert_fact("tile_0_0", "terrain", "grass")
        parent.assert_fact("tile_1_0", "terrain", "forest")

        # Child should see parent's facts
        results = child.query(("tile_0_0", "terrain", X))
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['x'], "grass")

        # Child should see all parent terrain
        results = child.query((Y, "terrain", X))
        self.assertEqual(len(results), 2)

    def test_child_local_facts_visible(self):
        """Child's own facts are visible in queries."""
        verse = Verse()
        parent = verse.create_world("game")
        child = verse.create_world("player_a", parent="game")

        # Child asserts its own fact
        child.assert_fact("self", "hp", 100)

        # Child sees its own fact
        results = child.query(("self", "hp", X))
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['x'], 100)

    def test_child_sees_both_local_and_inherited(self):
        """Child sees both its own facts and inherited facts."""
        verse = Verse()
        parent = verse.create_world("game")
        child = verse.create_world("player_a", parent="game")

        parent.assert_fact("world", "is_a", "terrain_holder")
        child.assert_fact("self", "is_a", "player")

        # Query for all is_a facts
        results = child.query((X, "is_a", Y))
        self.assertEqual(len(results), 2)

        entities = {r['x'] for r in results}
        self.assertIn("world", entities)
        self.assertIn("self", entities)

    def test_parent_does_not_see_child_facts(self):
        """Parent cannot see child's non-exported facts."""
        verse = Verse()
        parent = verse.create_world("game")
        child = verse.create_world("player_a", parent="game")

        child.assert_fact("self", "hp", 100)

        # Parent should NOT see child's hp
        results = parent.query(("self", "hp", X))
        self.assertEqual(len(results), 0)

    def test_siblings_isolated(self):
        """Sibling Worlds cannot see each other's facts."""
        verse = Verse()
        parent = verse.create_world("kernel")
        proc_a = verse.create_world("proc_a", parent="kernel")
        proc_b = verse.create_world("proc_b", parent="kernel")

        proc_a.assert_fact("secret", "password", "abc123")
        proc_b.assert_fact("other", "data", "xyz789")

        # proc_a cannot see proc_b's facts
        results = proc_a.query(("other", "data", X))
        self.assertEqual(len(results), 0)

        # proc_b cannot see proc_a's facts
        results = proc_b.query(("secret", "password", X))
        self.assertEqual(len(results), 0)

    def test_disable_inheritance(self):
        """Can disable inheritance with include_inherited=False."""
        verse = Verse()
        parent = verse.create_world("game")
        child = verse.create_world("player_a", parent="game")

        parent.assert_fact("world", "is_a", "terrain_holder")
        child.assert_fact("self", "is_a", "player")

        # Without inheritance, only local facts visible
        results = child.query((X, "is_a", Y), include_inherited=False)
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['x'], "self")


class TestExports(unittest.TestCase):
    """Test child exporting facts to parent."""

    def test_declare_export(self):
        """Can declare relations as exported."""
        verse = Verse()
        parent = verse.create_world("game")
        child = verse.create_world("player_a", parent="game")

        child.declare_export("position")
        self.assertTrue(child.is_exported("position"))
        self.assertFalse(child.is_exported("hp"))

    def test_get_exported_facts(self):
        """get_exported_facts returns only exported relations."""
        verse = Verse()
        parent = verse.create_world("game")
        child = verse.create_world("player_a", parent="game")

        child.declare_export("position")
        child.assert_fact("self", "position", "tile_5_5")
        child.assert_fact("self", "hp", 100)  # Not exported

        exported = child.get_exported_facts()
        self.assertEqual(len(exported), 1)
        self.assertEqual(exported[0].relation, "position")

    def test_query_child_exports(self):
        """Parent can query child's exported facts."""
        verse = Verse()
        parent = verse.create_world("game")
        child = verse.create_world("player_a", parent="game")

        child.declare_export("position")
        child.declare_export("action")
        child.assert_fact("self", "position", "tile_5_5")
        child.assert_fact("self", "action", "walking")
        child.assert_fact("self", "hp", 100)  # Not exported

        # Query exports
        results = verse.query_child_exports("game", "player_a",
                                            ("self", "position", X))
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['x'], "tile_5_5")


class TestMessaging(unittest.TestCase):
    """Test inbox/SEND message passing."""

    def test_parent_to_child_message(self):
        """Parent can send message to child."""
        verse = Verse()
        parent = verse.create_world("kernel")
        child = verse.create_world("proc_a", parent="kernel")

        # Send message
        verse.send_message("kernel", "proc_a", "inbox", "command", "run")

        # Child should have the message as a fact
        results = child.query(("inbox", "command", X))
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['x'], "run")

    def test_child_to_parent_message(self):
        """Child can send message to parent."""
        verse = Verse()
        parent = verse.create_world("kernel")
        child = verse.create_world("proc_a", parent="kernel")

        # Send message from child to parent
        verse.send_message("proc_a", "kernel", "inbox", "syscall", "exit")

        # Parent should have the message
        results = parent.query(("inbox", "syscall", X))
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['x'], "exit")

    def test_sibling_message_rejected(self):
        """Siblings cannot message each other directly."""
        verse = Verse()
        parent = verse.create_world("kernel")
        proc_a = verse.create_world("proc_a", parent="kernel")
        proc_b = verse.create_world("proc_b", parent="kernel")

        # Should fail - not parent-child
        with self.assertRaises(ValueError):
            verse.send_message("proc_a", "proc_b", "inbox", "data", "hello")

    def test_message_provenance(self):
        """Messages have provenance indicating sender."""
        verse = Verse()
        parent = verse.create_world("kernel")
        child = verse.create_world("proc_a", parent="kernel")

        verse.send_message("kernel", "proc_a", "inbox", "command", "run")

        # Check provenance
        facts = child.all_facts()
        msg_fact = [f for f in facts if f.relation == "command"][0]
        self.assertIn("received_from:kernel", msg_fact.cause)


class TestVerseTick(unittest.TestCase):
    """Test coordinated tick across Worlds."""

    def test_verse_tick_advances_all(self):
        """Verse.tick() advances all Worlds."""
        verse = Verse()
        parent = verse.create_world("game")
        child = verse.create_world("player_a", parent="game")

        # Add some facts
        parent.assert_fact("world", "is_a", "game_world")
        child.assert_fact("self", "hp", 100)

        # Tick the verse
        verse.tick()

        # Global tick advanced
        self.assertEqual(verse._global_tick, 1)

    def test_child_derives_with_inherited_facts(self):
        """Child rules can use inherited facts."""
        verse = Verse()
        parent = verse.create_world("game")
        child = verse.create_world("player_a", parent="game")

        # Parent has terrain
        parent.assert_fact("tile_5_5", "terrain", "grass")

        # Child has position and rule
        child.assert_fact("self", "location", "tile_5_5")

        # Child rule: if I'm at a grass tile, I can rest
        child.add_derivation_rule(
            "can_rest_on_grass",
            [("self", "location", X), (X, "terrain", "grass")],
            ("self", "can_rest", True)
        )

        # Tick - should derive can_rest from inherited terrain
        verse.tick()

        results = child.query(("self", "can_rest", X))
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['x'], True)


class TestStandaloneWorld(unittest.TestCase):
    """Ensure standalone World (no Verse) still works."""

    def test_standalone_world_basic(self):
        """World without Verse works as before."""
        world = World()
        world.assert_fact("alice", "is_a", "person")
        world.assert_fact("alice", "hp", 100)

        results = world.query(("alice", "hp", X))
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['x'], 100)

    def test_standalone_world_derivation(self):
        """Standalone World derivation works."""
        world = World()
        world.assert_fact("alice", "is_a", "person")
        world.assert_fact("bob", "is_a", "person")

        world.add_derivation_rule(
            "all_people_are_mortal",
            [(X, "is_a", "person")],
            (X, "is_a", "mortal")
        )

        world.advance()

        results = world.query((X, "is_a", "mortal"))
        self.assertEqual(len(results), 2)


if __name__ == "__main__":
    unittest.main()
