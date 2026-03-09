"""
Test: Move + Act Composition Across Micro-Iteration Boundaries

Session 17 Stress Test

Question: Does once_per_tick tracking work correctly across micro-iteration boundaries?

Scenario:
- Guard starts in town (no hostiles)
- Goblin is in forest
- Guard has a DEFERRED move rule that puts them in forest at micro-iter 1
- Guard has an attack rule (once_per_tick) that should see the new location at micro-iter 2
- Expected: Guard gets exactly ONE attack in the new room, not zero, not infinite

The _fired_this_tick set should persist across all micro-iterations within a tick.
If it were cleared between micro-iterations, the attack could fire multiple times.
If it weren't checked properly, the attack might not fire at all.

February 4, 2026 - Session 17
"""

import unittest
from herb_core import World, Var, Expr


X, Y, Z = Var('x'), Var('y'), Var('z')
E, N = Var('e'), Var('n')
LOC, DEST = Var('loc'), Var('dest')
DMG, HP = Var('dmg'), Var('hp')


class TestMoveActComposition(unittest.TestCase):
    """Test move + act within a single tick using deferred rules."""

    def test_deferred_move_then_attack(self):
        """
        Guard moves (deferred) into room with goblin, then attacks (once_per_tick).

        Micro-iteration timeline:
        - Iter 0: guard_moves fires (deferred), queues move to forest
        - Iter 1: move effect applied, guard now in forest
                  guard_attacks sees goblin, fires once
        - Iter 2+: pending_damage processed (also deferred)
        - Result: exactly one attack
        """
        world = World("move_act_test")

        # Functional relations
        world.declare_functional("location")
        world.declare_functional("hp")
        world.declare_functional("patrol_target")
        world.declare_functional("is_alive")

        # Topology
        world.assert_fact("town", "connects_to", "forest")
        world.assert_fact("forest", "connects_to", "town")

        # Guard starts in town
        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "location", "town")
        world.assert_fact("guard", "patrol_target", "forest")
        world.assert_fact("guard", "base_damage", 12)
        world.assert_fact("guard", "is_alive", True)
        world.assert_fact("guard", "hp", 80)

        # Goblin is in forest
        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "location", "forest")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 30)

        # Guard DEFERRED move - this is the key!
        # Effects queue for next micro-iteration
        world.add_derivation_rule(
            "guard_moves_deferred",
            [("guard", "location", LOC),
             ("guard", "patrol_target", DEST),
             (LOC, "connects_to", DEST),
             ("guard", "is_alive", True)],
            ("guard", "location", DEST),
            guard=Expr('not=', [LOC, DEST]),
            deferred=True,  # KEY: move is deferred
            once_per_tick=True
        )

        # Guard attacks enemies - NOT deferred, but once_per_tick
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

        # Damage application (deferred)
        world.add_derivation_rule(
            "apply_damage",
            [(E, "pending_damage", DMG),
             (E, "hp", HP)],
            templates=[(E, "hp", Expr('-', [HP, DMG]))],
            retractions=[(E, "pending_damage", DMG)],
            deferred=True
        )

        # BEFORE
        guard_loc_before = world.query(("guard", "location", X))[0]['x']
        self.assertEqual(guard_loc_before, "town")

        # RUN ONE TICK
        world.advance()

        # AFTER
        guard_loc_after = world.query(("guard", "location", X))[0]['x']
        self.assertEqual(guard_loc_after, "forest", "Guard should have moved to forest")

        # Goblin should have taken damage exactly once (12 damage)
        goblin_hp = world.query(("goblin", "hp", X))[0]['x']
        self.assertEqual(goblin_hp, 18, "Goblin should have 30-12=18 HP (one attack)")

        # No pending damage should remain
        pending = world.query((X, "pending_damage", Y))
        self.assertEqual(len(pending), 0, "No pending damage should remain")

    def test_deferred_move_no_infinite_attacks(self):
        """
        Verify guard doesn't attack infinitely even when target survives.

        Without once_per_tick, the guard could attack multiple times per tick
        because the goblin surviving keeps the attack conditions true.
        """
        world = World("no_infinite_test")

        world.declare_functional("location")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "location", "forest")
        world.assert_fact("guard", "base_damage", 5)  # Low damage so goblin survives
        world.assert_fact("guard", "is_alive", True)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "location", "forest")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 100)  # High HP to survive

        # Attack rule with once_per_tick
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

        # Damage application (deferred)
        world.add_derivation_rule(
            "apply_damage",
            [(E, "pending_damage", DMG),
             (E, "hp", HP)],
            templates=[(E, "hp", Expr('-', [HP, DMG]))],
            retractions=[(E, "pending_damage", DMG)],
            deferred=True
        )

        # Run tick
        world.advance()

        # Should be exactly 5 damage (one attack), not 0 or infinite
        goblin_hp = world.query(("goblin", "hp", X))[0]['x']
        self.assertEqual(goblin_hp, 95, "Goblin should take exactly 5 damage (one attack)")

    def test_move_and_attack_same_tick(self):
        """
        Guard does BOTH move AND attack in the same tick.

        This tests whether once_per_tick tracking works when:
        1. Move fires in micro-iter 0 (deferred)
        2. Move effect applies at micro-iter 1
        3. Attack fires in micro-iter 1 (sees new location)
        4. Both rules are once_per_tick

        The tracking must persist across micro-iterations but reset at tick boundary.
        """
        world = World("move_and_attack_test")

        world.declare_functional("location")
        world.declare_functional("hp")
        world.declare_functional("patrol_target")
        world.declare_functional("is_alive")

        world.assert_fact("town", "connects_to", "forest")
        world.assert_fact("forest", "connects_to", "town")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "location", "town")
        world.assert_fact("guard", "patrol_target", "forest")
        world.assert_fact("guard", "base_damage", 12)
        world.assert_fact("guard", "is_alive", True)
        world.assert_fact("guard", "hp", 80)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "location", "forest")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 30)

        # DEFERRED move with once_per_tick
        world.add_derivation_rule(
            "guard_moves",
            [("guard", "location", LOC),
             ("guard", "patrol_target", DEST),
             (LOC, "connects_to", DEST),
             ("guard", "is_alive", True)],
            ("guard", "location", DEST),
            guard=Expr('not=', [LOC, DEST]),
            deferred=True,
            once_per_tick=True
        )

        # Attack with once_per_tick (NOT deferred - should fire in same micro-iter)
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

        # Damage application (deferred)
        world.add_derivation_rule(
            "apply_damage",
            [(E, "pending_damage", DMG),
             (E, "hp", HP)],
            templates=[(E, "hp", Expr('-', [HP, DMG]))],
            retractions=[(E, "pending_damage", DMG)],
            deferred=True
        )

        # TICK 1
        world.advance()

        # Check results
        guard_loc = world.query(("guard", "location", X))[0]['x']
        goblin_hp = world.query(("goblin", "hp", X))[0]['x']

        self.assertEqual(guard_loc, "forest", "Guard should be in forest after move")
        self.assertEqual(goblin_hp, 18, "Goblin should have 30-12=18 HP (one attack)")

    def test_once_per_tick_resets_between_ticks(self):
        """
        once_per_tick tracking should reset at tick boundaries.

        Tick 1: guard attacks goblin (HP 30 -> 18)
        Tick 2: guard attacks goblin again (HP 18 -> 6)
        """
        world = World("reset_test")

        world.declare_functional("location")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "location", "forest")
        world.assert_fact("guard", "base_damage", 12)
        world.assert_fact("guard", "is_alive", True)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "location", "forest")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 30)

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

        # TICK 1
        world.advance()
        goblin_hp_tick1 = world.query(("goblin", "hp", X))[0]['x']
        self.assertEqual(goblin_hp_tick1, 18, "After tick 1: 30-12=18")

        # TICK 2
        world.advance()
        goblin_hp_tick2 = world.query(("goblin", "hp", X))[0]['x']
        self.assertEqual(goblin_hp_tick2, 6, "After tick 2: 18-12=6")

    def test_multiple_targets_same_tick(self):
        """
        Guard can attack multiple different targets in the same tick.

        once_per_tick with once_key_vars=['e'] means one attack per TARGET,
        not one attack total.
        """
        world = World("multi_target_test")

        world.declare_functional("location")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "location", "forest")
        world.assert_fact("guard", "base_damage", 12)
        world.assert_fact("guard", "is_alive", True)

        # Two enemies in same location
        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "location", "forest")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 30)

        world.assert_fact("wolf", "is_a", "enemy")
        world.assert_fact("wolf", "location", "forest")
        world.assert_fact("wolf", "is_alive", True)
        world.assert_fact("wolf", "hp", 25)

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
            once_key_vars=['e']  # One attack PER TARGET
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

        self.assertEqual(goblin_hp, 18, "Goblin takes one hit: 30-12=18")
        self.assertEqual(wolf_hp, 13, "Wolf takes one hit: 25-12=13")


class TestOncePerTickWithoutKeyVars(unittest.TestCase):
    """Test once_per_tick when no key_vars specified (uses all bindings)."""

    def test_no_key_vars_all_bindings(self):
        """
        Without once_key_vars, the entire binding is used as the key.
        This means each unique (attacker, target) pair fires once.
        """
        world = World("no_key_vars_test")

        world.declare_functional("location")
        world.declare_functional("hp")
        world.declare_functional("is_alive")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "location", "forest")
        world.assert_fact("guard", "base_damage", 10)
        world.assert_fact("guard", "is_alive", True)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "location", "forest")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 50)

        # once_per_tick without once_key_vars
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
            once_per_tick=True  # No once_key_vars - uses all bindings
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
        self.assertEqual(goblin_hp, 40, "Goblin takes exactly one hit: 50-10=40")


class TestOncePerTickWithDeferredChain(unittest.TestCase):
    """Test once_per_tick combined with multi-step deferred chains."""

    def test_full_combat_chain(self):
        """
        Full combat chain:
        - Micro-iter 0: attack fires (once_per_tick), creates pending_damage
        - Micro-iter 1: apply_damage (deferred) updates HP
        - Micro-iter 2: check_death (deferred) sets is_alive=False if HP<=0
        - Micro-iter 3: drop_loot (deferred) transfers gold

        once_per_tick should track through entire chain.
        """
        world = World("full_chain_test")

        world.declare_functional("location")
        world.declare_functional("hp")
        world.declare_functional("is_alive")
        world.declare_functional("gold")

        world.assert_fact("guard", "is_a", "combatant")
        world.assert_fact("guard", "location", "forest")
        world.assert_fact("guard", "base_damage", 50)  # One-shot kill
        world.assert_fact("guard", "is_alive", True)
        world.assert_fact("guard", "gold", 0)

        world.assert_fact("goblin", "is_a", "enemy")
        world.assert_fact("goblin", "location", "forest")
        world.assert_fact("goblin", "is_alive", True)
        world.assert_fact("goblin", "hp", 30)
        world.assert_fact("goblin", "gold", 25)

        # Attack (once_per_tick)
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

        # Apply damage (deferred)
        world.add_derivation_rule(
            "apply_damage",
            [(E, "pending_damage", DMG),
             (E, "hp", HP)],
            templates=[(E, "hp", Expr('-', [HP, DMG]))],
            retractions=[(E, "pending_damage", DMG)],
            deferred=True
        )

        # Check death (deferred)
        world.add_derivation_rule(
            "check_death",
            [(E, "hp", HP),
             (E, "is_alive", True)],
            (E, "is_alive", False),
            guard=Expr('<=', [HP, 0]),
            deferred=True
        )

        # Drop loot (deferred) - gold goes to "loot_pile" for simplicity
        G = Var('g')
        world.add_derivation_rule(
            "drop_loot",
            [(E, "is_alive", False),
             (E, "gold", G)],
            templates=[("loot_pile", "gold", G)],
            retractions=[(E, "gold", G)],
            guard=Expr('>', [G, 0]),
            deferred=True
        )

        world.advance()

        # Verify entire chain completed
        goblin_alive = world.query(("goblin", "is_alive", X))
        self.assertEqual(goblin_alive[0]['x'], False, "Goblin should be dead")

        goblin_hp = world.query(("goblin", "hp", X))[0]['x']
        self.assertEqual(goblin_hp, -20, "Goblin HP should be 30-50=-20")

        loot = world.query(("loot_pile", "gold", X))
        self.assertTrue(len(loot) > 0, "Loot should exist")
        self.assertEqual(loot[0]['x'], 25, "Loot should be 25 gold")


if __name__ == "__main__":
    unittest.main()
