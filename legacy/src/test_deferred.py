"""
HERB Deferred Rules Tests (§14)

Tests for the =>> (deferred) rule semantics that create causal ordering
within a single tick via micro-iterations.

Session 15 — February 4, 2026
"""

import unittest
from herb_core import World, Var, Expr

X, Y, Z = Var('x'), Var('y'), Var('z')
A, B = Var('a'), Var('b')


class TestDeferredBasics(unittest.TestCase):
    """Basic deferred rule functionality."""

    def test_deferred_delays_effects(self):
        """Deferred rule effects happen in next micro-iteration."""
        world = World()
        world.declare_functional("hp")

        world.assert_fact("hero", "hp", 100)
        world.assert_fact("hero", "damage", 20)

        # Deferred rule: damage =>> hp update (must retract trigger!)
        world.add_derivation_rule(
            "apply_damage",
            [("hero", "damage", X), ("hero", "hp", Y)],
            templates=[("hero", "hp", Expr('-', [Y, X]))],
            retractions=[("hero", "damage", X)],  # Consume the damage
            deferred=True
        )

        world.advance()

        # HP should be updated
        hp = world.query(("hero", "hp", X))
        self.assertEqual(hp[0]['x'], 80)

        # Check micro-iteration in provenance
        hp_fact = None
        for f in world._all_facts.values():
            if f.subject == "hero" and f.relation == "hp" and f.object == 80:
                hp_fact = f
                break
        self.assertIsNotNone(hp_fact)
        self.assertEqual(hp_fact.micro_iter, 1)  # Created in micro-iter 1

    def test_deferred_chain(self):
        """Multiple deferred rules chain correctly across micro-iterations."""
        world = World()
        world.declare_functional("state")

        world.assert_fact("entity", "state", "start")

        # Chain: start -> step1 -> step2 -> done
        world.add_derivation_rule(
            "step1",
            [("entity", "state", "start")],
            ("entity", "state", "step1"),
            deferred=True
        )
        world.add_derivation_rule(
            "step2",
            [("entity", "state", "step1")],
            ("entity", "state", "step2"),
            deferred=True
        )
        world.add_derivation_rule(
            "done",
            [("entity", "state", "step2")],
            ("entity", "state", "done"),
            deferred=True
        )

        world.advance()

        state = world.query(("entity", "state", X))
        self.assertEqual(state[0]['x'], "done")

        # Verify micro-iterations
        history = world.history("entity", "state")
        states = [(f.object, f.micro_iter) for f in history if f.is_alive(world.tick) or True]
        # Should have: start@0, step1@1, step2@2, done@3
        self.assertTrue(any(s == "start" and m == 0 for s, m in states))
        self.assertTrue(any(s == "done" and m == 3 for s, m in states))

    def test_deferred_with_retraction(self):
        """Deferred rules can have retractions."""
        world = World()

        world.assert_fact("event", "pending", "action")

        # Deferred rule: process pending event
        world.add_derivation_rule(
            "process_event",
            [("event", "pending", X)],
            templates=[("event", "processed", X)],
            retractions=[("event", "pending", X)],
            deferred=True
        )

        world.advance()

        pending = world.query(("event", "pending", X))
        processed = world.query(("event", "processed", X))

        self.assertEqual(len(pending), 0)  # Retracted
        self.assertEqual(processed[0]['x'], "action")  # Created


class TestDeferredAndInstant(unittest.TestCase):
    """Interaction between instant and deferred rules."""

    def test_instant_then_deferred(self):
        """Instant rules complete before deferred effects apply."""
        world = World()
        world.declare_functional("hp")
        world.declare_ephemeral("fire")  # Trigger consumed after firing

        world.assert_fact("trigger", "fire", True)
        world.assert_fact("hero", "hp", 100)

        # Instant: trigger creates damage marker (trigger is ephemeral)
        world.add_derivation_rule(
            "create_damage",
            [("trigger", "fire", True)],
            ("hero", "damage", 20)
        )

        # Deferred: damage marker =>> hp update
        world.add_derivation_rule(
            "apply_damage",
            [("hero", "damage", X), ("hero", "hp", Y)],
            templates=[("hero", "hp", Expr('-', [Y, X]))],
            retractions=[("hero", "damage", X)],
            deferred=True
        )

        world.advance()

        hp = world.query(("hero", "hp", X))
        self.assertEqual(hp[0]['x'], 80)

        damage = world.query(("hero", "damage", X))
        self.assertEqual(len(damage), 0)  # Consumed

    def test_instant_no_refire_after_deferred(self):
        """Instant rules that created facts don't re-fire after deferred effects."""
        world = World()

        world.assert_fact("cmd", "attack", True)
        world.assert_fact("enemy", "hp", 50)
        world.declare_functional("hp")
        world.declare_ephemeral("attack")  # Consumed after all bindings

        # Instant: attack creates pending_damage
        world.add_derivation_rule(
            "do_attack",
            [("cmd", "attack", True)],
            ("enemy", "pending_damage", 10)
        )

        # Deferred: apply pending damage
        world.add_derivation_rule(
            "apply_damage",
            [("enemy", "pending_damage", X), ("enemy", "hp", Y)],
            templates=[("enemy", "hp", Expr('-', [Y, X]))],
            retractions=[("enemy", "pending_damage", X)],
            deferred=True
        )

        world.advance()

        hp = world.query(("enemy", "hp", X))
        self.assertEqual(hp[0]['x'], 40)  # Only one hit, not multiple


class TestDeferredCombat(unittest.TestCase):
    """Combat-specific deferred rule tests."""

    def test_damage_death_loot_chain(self):
        """Full combat chain: damage -> death -> loot."""
        world = World()
        world.declare_functional("hp")
        world.declare_functional("is_alive")
        world.declare_functional("gold")

        world.assert_fact("player", "gold", 0)
        world.assert_fact("enemy", "hp", 10)
        world.assert_fact("enemy", "is_alive", True)
        world.assert_fact("enemy", "gold", 50)

        # Pending damage exists
        world.assert_fact("enemy", "pending_damage", 20)

        # Deferred: apply damage
        world.add_derivation_rule(
            "apply_damage",
            [(X, "pending_damage", A), (X, "hp", B), (X, "is_alive", True)],
            templates=[(X, "hp", Expr('-', [B, A]))],
            retractions=[(X, "pending_damage", A)],
            deferred=True
        )

        # Deferred: check death
        world.add_derivation_rule(
            "check_death",
            [(X, "hp", A), (X, "is_alive", True)],
            (X, "is_alive", False),
            guard=Expr('<=', [A, 0]),
            deferred=True
        )

        # Deferred: drop loot
        world.add_derivation_rule(
            "drop_loot",
            [(X, "is_alive", False), (X, "gold", A), ("player", "gold", B)],
            templates=[("player", "gold", Expr('+', [A, B]))],
            retractions=[(X, "gold", A)],
            guard=Expr('>', [A, 0]),
            deferred=True
        )

        world.advance()

        # Enemy should be dead
        alive = world.query(("enemy", "is_alive", X))
        self.assertEqual(alive[0]['x'], False)

        # Enemy HP should be negative
        hp = world.query(("enemy", "hp", X))
        self.assertEqual(hp[0]['x'], -10)

        # Player should have enemy's gold
        gold = world.query(("player", "gold", X))
        self.assertEqual(gold[0]['x'], 50)


class TestDeferredProvenance(unittest.TestCase):
    """Provenance tracking for deferred rules."""

    def test_micro_iter_in_provenance(self):
        """Provenance includes micro-iteration info."""
        world = World()
        world.declare_functional("state")

        world.assert_fact("thing", "state", "a")

        world.add_derivation_rule(
            "a_to_b",
            [("thing", "state", "a")],
            ("thing", "state", "b"),
            deferred=True
        )

        world.advance()

        explanation = world.explain("thing", "state", "b")
        self.assertIsNotNone(explanation)
        self.assertEqual(explanation['micro_iter'], 1)
        self.assertEqual(explanation['cause'], 'rule:a_to_b')


class TestDeferredEdgeCases(unittest.TestCase):
    """Edge cases for deferred rules."""

    def test_no_infinite_micro_iterations(self):
        """Deferred chain terminates correctly."""
        world = World()

        world.assert_fact("counter", "value", 0)

        # This rule would loop if not properly guarded
        world.add_derivation_rule(
            "increment",
            [("counter", "value", X)],
            ("counter", "done", True),
            guard=Expr('>=', [X, 0]),  # Always true, but runs once
            deferred=True
        )

        # Should not hang
        world.advance()

        done = world.query(("counter", "done", True))
        self.assertEqual(len(done), 1)

    def test_deferred_prevents_duplicate_processing(self):
        """Same input fact not processed multiple times by deferred rule."""
        world = World()
        world.declare_functional("count")

        world.assert_fact("input", "value", 5)
        world.assert_fact("output", "count", 0)

        # Deferred rule that would double-fire if not careful
        world.add_derivation_rule(
            "count_up",
            [("input", "value", X), ("output", "count", Y)],
            templates=[("output", "count", Expr('+', [Y, 1]))],
            retractions=[("input", "value", X)],
            deferred=True
        )

        world.advance()

        count = world.query(("output", "count", X))
        self.assertEqual(count[0]['x'], 1)  # Only incremented once


if __name__ == "__main__":
    print("=" * 60)
    print("HERB Deferred Rules Tests (§14)")
    print("=" * 60)
    unittest.main(verbosity=2)
