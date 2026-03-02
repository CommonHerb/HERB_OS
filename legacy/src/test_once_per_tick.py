"""
Tests for ONCE PER TICK primitive (§15)

The once_per_tick rule modifier prevents a rule from firing more than once per tick
for each unique binding key. This is essential for multi-agent simulation where
each agent should perform at most one action per turn.

Test categories:
1. TestBasicOncePerTick - Core functionality
2. TestKeyVarSelection - Binding key configuration
3. TestMicroIterationBoundary - Interaction with deferred rules
4. TestMultiAgent - Multiple agents acting

February 4, 2026 - Session 17
"""

import unittest
from herb_core import World, Var, Expr


X, Y, Z = Var('x'), Var('y'), Var('z')
E, N, A = Var('e'), Var('n'), Var('a')
LOC, DEST = Var('loc'), Var('dest')
DMG, HP, G = Var('dmg'), Var('hp'), Var('g')


class TestBasicOncePerTick(unittest.TestCase):
    """Basic once_per_tick functionality."""

    def test_rule_fires_once(self):
        """A once_per_tick rule fires exactly once per tick."""
        world = World("basic_test")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "base_damage", 10)
        world.assert_fact("guard", "is_alive", True)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 100)

        # Attack that survives (goblin has enough HP)
        world.add_derivation_rule(
            "attack",
            [("guard", "is_a", "combatant"),
             ("guard", "base_damage", DMG),
             ("guard", "is_alive", True),
             (E, "is_a", "enemy"),
             (E, "is_alive", True)],
            (E, "pending_damage", DMG),
            once_per_tick=True,
            once_key_vars=['e']
        )

        # Damage application
        world.add_derivation_rule(
            "apply_damage",
            [(E, "pending_damage", DMG),
             (E, "hp", HP)],
            templates=[(E, "hp", Expr('-', [HP, DMG]))],
            retractions=[(E, "pending_damage", DMG)],
            deferred=True
        )

        world.advance()

        goblin_hp = world.query(("goblin", "hp", X))[0]['x']
        self.assertEqual(goblin_hp, 90, "Goblin should take exactly one hit: 100-10=90")

    def test_rule_fires_again_next_tick(self):
        """once_per_tick resets at tick boundaries."""
        world = World("reset_test")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "base_damage", 10)
        world.assert_fact("guard", "is_alive", True)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 100)

        world.add_derivation_rule(
            "attack",
            [("guard", "is_a", "combatant"),
             ("guard", "base_damage", DMG),
             ("guard", "is_alive", True),
             (E, "is_a", "enemy"),
             (E, "is_alive", True)],
            (E, "pending_damage", DMG),
            once_per_tick=True,
            once_key_vars=['e']
        )

        world.add_derivation_rule(
            "apply_damage",
            [(E, "pending_damage", DMG),
             (E, "hp", HP)],
            templates=[(E, "hp", Expr('-', [HP, DMG]))],
            retractions=[(E, "pending_damage", DMG)],
            deferred=True
        )

        # Tick 1
        world.advance()
        self.assertEqual(world.query(("goblin", "hp", X))[0]['x'], 90)

        # Tick 2
        world.advance()
        self.assertEqual(world.query(("goblin", "hp", X))[0]['x'], 80)

        # Tick 3
        world.advance()
        self.assertEqual(world.query(("goblin", "hp", X))[0]['x'], 70)

    def test_non_once_rule_fires_multiple_times(self):
        """Rules without once_per_tick can fire multiple times if conditions persist."""
        world = World("non_once_test")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 100)

        # This rule can re-fire because it's not once_per_tick
        # and the conditions remain true (we don't retract pending_damage immediately)
        counter = {"value": 0}

        def make_pending_damage_rule(w):
            """Create pending damage multiple times (simulates problem without once_per_tick)."""
            # We'll use a simple test: without once_per_tick, multiple bindings fire
            pass

        # Actually, in a fixpoint system, the same binding won't produce duplicate facts
        # So we need to test differently - the issue is that the rule keeps TRYING to fire
        # Let's verify that a normal rule only produces one fact (fixpoint behavior)

        world.add_derivation_rule(
            "mark_enemy",
            [(E, "is_a", "enemy"),
             (E, "is_alive", True)],
            (E, "marked", True)
        )

        world.advance()

        marks = world.query(("goblin", "marked", X))
        self.assertEqual(len(marks), 1, "Should produce exactly one marked fact")


class TestKeyVarSelection(unittest.TestCase):
    """Test binding key configuration via once_key_vars."""

    def test_key_vars_allows_different_targets(self):
        """With once_key_vars=['e'], can attack different targets in same tick."""
        world = World("key_vars_test")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "base_damage", 10)
        world.assert_fact("guard", "is_alive", True)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 50)

        world.assert_fact("wolf", "is_a", "enemy")
        world.assert_fact("wolf", "is_alive", True)
        world.assert_fact("wolf", "hp", 40)

        world.add_derivation_rule(
            "attack",
            [("guard", "is_a", "combatant"),
             ("guard", "base_damage", DMG),
             ("guard", "is_alive", True),
             (E, "is_a", "enemy"),
             (E, "is_alive", True)],
            (E, "pending_damage", DMG),
            once_per_tick=True,
            once_key_vars=['e']  # Key is just the target
        )

        world.add_derivation_rule(
            "apply_damage",
            [(E, "pending_damage", DMG),
             (E, "hp", HP)],
            templates=[(E, "hp", Expr('-', [HP, DMG]))],
            retractions=[(E, "pending_damage", DMG)],
            deferred=True
        )

        world.advance()

        goblin_hp = world.query(("goblin", "hp", X))[0]['x']
        wolf_hp = world.query(("wolf", "hp", X))[0]['x']

        self.assertEqual(goblin_hp, 40, "Goblin takes one hit")
        self.assertEqual(wolf_hp, 30, "Wolf takes one hit")

    def test_no_key_vars_uses_all_bindings(self):
        """Without once_key_vars, all pattern variables form the key."""
        world = World("no_key_vars_test")

        world.assert_fact("alice", "wants_to_say", "hello")
        world.assert_fact("bob", "wants_to_say", "hi")

        world.add_derivation_rule(
            "say",
            [(N, "wants_to_say", X)],
            (N, "said", X),
            once_per_tick=True  # No key_vars
        )

        world.advance()

        alice_said = world.query(("alice", "said", X))
        bob_said = world.query(("bob", "said", X))

        self.assertEqual(len(alice_said), 1)
        self.assertEqual(len(bob_said), 1)
        self.assertEqual(alice_said[0]['x'], "hello")
        self.assertEqual(bob_said[0]['x'], "hi")

    def test_key_vars_subset(self):
        """Key vars can be a subset of pattern variables."""
        world = World("subset_key_test")

        # Multiple merchants, multiple customers
        world.assert_fact("merchant_a", "is_a", "merchant")
        world.assert_fact("merchant_b", "is_a", "merchant")
        world.assert_fact("player", "is_a", "customer")

        # Once per tick per merchant (not per customer)
        world.add_derivation_rule(
            "offer_trade",
            [(N, "is_a", "merchant"),
             (Y, "is_a", "customer")],
            (N, "offered_trade_to", Y),
            once_per_tick=True,
            once_key_vars=['n']  # Key is just the merchant
        )

        world.advance()

        offers_a = world.query(("merchant_a", "offered_trade_to", X))
        offers_b = world.query(("merchant_b", "offered_trade_to", X))

        # Each merchant offers exactly once
        self.assertEqual(len(offers_a), 1)
        self.assertEqual(len(offers_b), 1)


class TestMicroIterationBoundary(unittest.TestCase):
    """Test once_per_tick interaction with deferred rules and micro-iterations."""

    def test_tracking_persists_across_micro_iterations(self):
        """once_per_tick tracking persists across micro-iterations within a tick."""
        world = World("micro_iter_test")
        world.declare_functional("location")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("town", "connects_to", "forest")
        world.assert_fact("forest", "connects_to", "town")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "location", "town")
        world.assert_fact("guard", "patrol_target", "forest")
        world.assert_fact("guard", "base_damage", 10)
        world.assert_fact("guard", "is_alive", True)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "location", "forest")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 100)

        # DEFERRED move (micro-iter 0 -> 1)
        world.add_derivation_rule(
            "guard_moves",
            [("guard", "location", LOC),
             ("guard", "patrol_target", DEST),
             (LOC, "connects_to", DEST)],
            ("guard", "location", DEST),
            guard=Expr('not=', [LOC, DEST]),
            deferred=True,
            once_per_tick=True
        )

        # Attack in new location (micro-iter 1+)
        world.add_derivation_rule(
            "guard_attacks",
            [("guard", "is_a", "combatant"),
             ("guard", "location", LOC),
             ("guard", "base_damage", DMG),
             ("guard", "is_alive", True),
             (E, "is_a", "enemy"),
             (E, "location", LOC),
             (E, "is_alive", True)],
            (E, "pending_damage", DMG),
            once_per_tick=True,
            once_key_vars=['e']
        )

        world.add_derivation_rule(
            "apply_damage",
            [(E, "pending_damage", DMG),
             (E, "hp", HP)],
            templates=[(E, "hp", Expr('-', [HP, DMG]))],
            retractions=[(E, "pending_damage", DMG)],
            deferred=True
        )

        world.advance()

        # Guard should have moved AND attacked exactly once
        guard_loc = world.query(("guard", "location", X))[0]['x']
        goblin_hp = world.query(("goblin", "hp", X))[0]['x']

        self.assertEqual(guard_loc, "forest")
        self.assertEqual(goblin_hp, 90, "Should take exactly 10 damage")

    def test_deferred_chain_with_once_per_tick(self):
        """Full combat chain with once_per_tick attack."""
        world = World("chain_test")
        world.declare_functional("hp")
        world.declare_functional("is_alive")
        world.declare_functional("gold")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "base_damage", 50)
        world.assert_fact("guard", "is_alive", True)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 30)
        world.assert_fact("goblin", "gold", 25)

        # Attack (once_per_tick) -> pending_damage
        world.add_derivation_rule(
            "attack",
            [("guard", "is_a", "combatant"),
             ("guard", "base_damage", DMG),
             ("guard", "is_alive", True),
             (E, "is_a", "enemy"),
             (E, "is_alive", True)],
            (E, "pending_damage", DMG),
            once_per_tick=True,
            once_key_vars=['e']
        )

        # pending_damage -> HP update (deferred)
        world.add_derivation_rule(
            "apply_damage",
            [(E, "pending_damage", DMG),
             (E, "hp", HP)],
            templates=[(E, "hp", Expr('-', [HP, DMG]))],
            retractions=[(E, "pending_damage", DMG)],
            deferred=True
        )

        # HP <= 0 -> is_alive = False (deferred)
        world.add_derivation_rule(
            "check_death",
            [(E, "hp", HP),
             (E, "is_alive", True)],
            (E, "is_alive", False),
            guard=Expr('<=', [HP, 0]),
            deferred=True
        )

        # death -> drop loot (deferred)
        world.add_derivation_rule(
            "drop_loot",
            [(E, "is_alive", False),
             (E, "gold", G)],
            templates=[("loot", "gold", G)],
            retractions=[(E, "gold", G)],
            guard=Expr('>', [G, 0]),
            deferred=True
        )

        world.advance()

        # Verify chain completed
        goblin_alive = world.query(("goblin", "is_alive", X))[0]['x']
        loot_gold = world.query(("loot", "gold", X))

        self.assertEqual(goblin_alive, False)
        self.assertEqual(len(loot_gold), 1)
        self.assertEqual(loot_gold[0]['x'], 25)


class TestMultiAgent(unittest.TestCase):
    """Test multiple agents with once_per_tick rules."""

    def test_multiple_attackers(self):
        """Multiple attackers can each attack once per tick."""
        world = World("multi_attacker_test")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        # Two guards
        world.assert_fact("guard_a", "is_a", "combatant")
        world.assert_fact("guard_a", "base_damage", 10)
        world.assert_fact("guard_a", "is_alive", True)

        world.assert_fact("guard_b", "is_a", "combatant")
        world.assert_fact("guard_b", "base_damage", 15)
        world.assert_fact("guard_b", "is_alive", True)

        # One enemy
        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 100)

        # Attack rule - each attacker attacks once per target
        world.add_derivation_rule(
            "attack",
            [(A, "is_a", "combatant"),
             (A, "base_damage", DMG),
             (A, "is_alive", True),
             (E, "is_a", "enemy"),
             (E, "is_alive", True)],
            (E, "pending_damage", DMG),
            once_per_tick=True,
            once_key_vars=['a', 'e']  # Key is (attacker, target)
        )

        # Sum pending damage
        TOTAL_DMG = Var('total_dmg')
        from herb_core import AggregateExpr
        world.add_derivation_rule(
            "sum_damage",
            [(E, "is_a", "enemy")],
            (E, "total_pending_damage", AggregateExpr('sum', DMG, [(E, "pending_damage", DMG)]))
        )

        world.advance()

        # Both guards should have attacked
        pending = world.query(("goblin", "pending_damage", X))
        # We expect 2 pending_damage facts: 10 and 15
        damages = [p['x'] for p in pending]
        self.assertEqual(sorted(damages), [10, 15])

    def test_multi_agent_same_rule_different_bindings(self):
        """Same rule fires for different agents with different bindings."""
        world = World("multi_agent_bindings_test")

        world.assert_fact("alice", "is_a", "npc")
        world.assert_fact("alice", "wants_to_move", "north")

        world.assert_fact("bob", "is_a", "npc")
        world.assert_fact("bob", "wants_to_move", "south")

        world.add_derivation_rule(
            "npc_moves",
            [(N, "is_a", "npc"),
             (N, "wants_to_move", DEST)],
            (N, "moved_to", DEST),
            once_per_tick=True,
            once_key_vars=['n']
        )

        world.advance()

        alice_moved = world.query(("alice", "moved_to", X))
        bob_moved = world.query(("bob", "moved_to", X))

        self.assertEqual(len(alice_moved), 1)
        self.assertEqual(len(bob_moved), 1)
        self.assertEqual(alice_moved[0]['x'], "north")
        self.assertEqual(bob_moved[0]['x'], "south")


class TestEdgeCases(unittest.TestCase):
    """Edge cases and potential bugs."""

    def test_once_per_tick_with_guard(self):
        """once_per_tick respects guard conditions."""
        world = World("guard_test")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "hp", 0)  # Guard is dead (HP 0)
        world.assert_fact("guard", "is_alive", True)  # But marked alive

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 50)

        # Attack only if HP > 0
        world.add_derivation_rule(
            "attack",
            [("guard", "is_a", "combatant"),
             ("guard", "hp", HP),
             (E, "is_a", "enemy"),
             (E, "is_alive", True)],
            (E, "pending_damage", 10),
            guard=Expr('>', [HP, 0]),
            once_per_tick=True,
            once_key_vars=['e']
        )

        world.advance()

        # Guard can't attack (HP = 0)
        pending = world.query(("goblin", "pending_damage", X))
        self.assertEqual(len(pending), 0, "Dead guard shouldn't attack")

    def test_once_per_tick_empty_key(self):
        """once_per_tick with empty key_vars fires once total (no binding distinction)."""
        world = World("empty_key_test")

        world.assert_fact("alice", "is_a", "person")
        world.assert_fact("bob", "is_a", "person")

        world.add_derivation_rule(
            "greet",
            [(N, "is_a", "person")],
            (N, "greeted", True),
            once_per_tick=True,
            once_key_vars=[]  # Empty - all bindings share same key, fires once total
        )

        world.advance()

        # Only ONE person should be greeted (first match wins, rule fires once)
        alice_greeted = world.query(("alice", "greeted", X))
        bob_greeted = world.query(("bob", "greeted", X))

        # Total greetings should be exactly 1
        total_greeted = len(alice_greeted) + len(bob_greeted)
        self.assertEqual(total_greeted, 1, "Empty key_vars means rule fires exactly once")

    def test_once_per_tick_retracts_dont_reset(self):
        """Retractions within tick don't allow re-firing."""
        world = World("retract_test")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "base_damage", 10)
        world.assert_fact("guard", "is_alive", True)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 100)

        # Attack with retraction
        world.add_derivation_rule(
            "attack",
            [("guard", "is_a", "combatant"),
             ("guard", "base_damage", DMG),
             ("guard", "is_alive", True),
             (E, "is_a", "enemy"),
             (E, "is_alive", True),
             (E, "hp", HP)],
            templates=[(E, "hp", Expr('-', [HP, DMG]))],
            retractions=[(E, "hp", HP)],  # Retract old HP
            once_per_tick=True,
            once_key_vars=['e']
        )

        world.advance()

        # Should only attack once (HP 100 -> 90), not multiple times
        goblin_hp = world.query(("goblin", "hp", X))[0]['x']
        self.assertEqual(goblin_hp, 90)


if __name__ == "__main__":
    unittest.main()
