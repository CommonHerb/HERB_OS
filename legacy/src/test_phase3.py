"""
HERB Phase 3 Tests — Aggregate + RETRACT Integration

Tests that rules with RETRACT can consume facts produced by aggregate rules.
This is the key unlock for combat systems: calculate damage with aggregates,
then apply damage with RETRACT.

Phase classification:
- Phase 1: Base rules (no aggregate/negation, don't depend on Phase 2 outputs)
- Phase 2: Aggregate + Negation rules (NO RETRACT)
- Phase 3: Rules with RETRACT that pattern on Phase 2 output relations
"""

from herb_core import World, Var, Expr, AggregateExpr


def test_aggregate_then_retract():
    """
    Test the core use case: aggregate calculates a value, then a RETRACT rule consumes it.

    Scenario: Equipment bonuses are summed (Phase 2), then applied to base attack (Phase 3).
    """
    print("\n" + "=" * 60)
    print("Test: Aggregate then RETRACT")
    print("=" * 60)

    w = World()

    # Player with base attack
    w.assert_fact("player", "is_a", "combatant")
    w.assert_fact("player", "base_attack", 10)

    # Equipment bonuses
    w.assert_fact("player", "has_bonus", 5)   # sword
    w.assert_fact("player", "has_bonus", 3)   # ring
    w.assert_fact("player", "has_bonus", 2)   # amulet

    # Phase 2 rule: Sum all bonuses
    P = Var('p')
    B = Var('b')
    w.add_derivation_rule(
        "calculate_total_bonus",
        [(P, "is_a", "combatant")],
        (P, "total_bonus", AggregateExpr('sum', B, [(P, "has_bonus", B)]))
    )

    # Phase 3 rule: Apply total bonus to base attack (has RETRACT, patterns on total_bonus)
    BASE = Var('base')
    BONUS = Var('bonus')
    w.add_derivation_rule(
        "apply_bonus_to_attack",
        [(P, "base_attack", BASE), (P, "total_bonus", BONUS)],
        (P, "final_attack", Expr('+', [BASE, BONUS])),
        retractions=[(P, "total_bonus", BONUS)]  # Consume the intermediate value
    )

    print("\nBefore advance:")
    print(f"  base_attack: {w.query(('player', 'base_attack', Var('x')))}")
    print(f"  has_bonus: {w.query(('player', 'has_bonus', Var('x')))}")

    # Advance once - should run Phase 1, Phase 2, Phase 3 in order
    w.advance()

    print("\nAfter advance:")
    total_bonus = w.query(('player', 'total_bonus', Var('x')))
    final_attack = w.query(('player', 'final_attack', Var('x')))
    print(f"  total_bonus: {total_bonus}")  # Should be empty (retracted)
    print(f"  final_attack: {final_attack}")  # Should be 20

    # Verify
    assert len(total_bonus) == 0, "total_bonus should be retracted"
    assert len(final_attack) == 1, "final_attack should exist"
    assert final_attack[0]['x'] == 20, f"Expected 20, got {final_attack[0]['x']}"

    print("  PASSED")


def test_combat_damage_with_aggregates():
    """
    Test full combat flow: aggregate equipment, calculate damage, apply to HP.
    """
    print("\n" + "=" * 60)
    print("Test: Combat Damage with Aggregates")
    print("=" * 60)

    w = World()

    # Attacker with equipment bonuses
    w.assert_fact("hero", "is_a", "combatant")
    w.assert_fact("hero", "attack_bonus", 10)
    w.assert_fact("hero", "attack_bonus", 5)
    w.assert_fact("hero", "attacking", "goblin")

    # Target with HP and defense bonuses
    w.assert_fact("goblin", "is_a", "combatant")
    w.assert_fact("goblin", "hp", 30)
    w.assert_fact("goblin", "defense_bonus", 3)
    w.assert_fact("goblin", "defense_bonus", 2)

    A = Var('a')
    T = Var('t')
    B = Var('b')
    ATK = Var('atk')
    DEF = Var('def')
    HP = Var('hp')
    DMG = Var('dmg')

    # Phase 2: Calculate total attack (aggregate)
    w.add_derivation_rule(
        "calc_attack",
        [(A, "attacking", T)],
        (A, "total_attack", AggregateExpr('sum', B, [(A, "attack_bonus", B)]))
    )

    # Phase 2: Calculate total defense (aggregate)
    w.add_derivation_rule(
        "calc_defense",
        [(A, "attacking", T)],
        (T, "total_defense", AggregateExpr('sum', B, [(T, "defense_bonus", B)]))
    )

    # Phase 3: Calculate net damage (depends on Phase 2, has RETRACT)
    w.add_derivation_rule(
        "calc_damage",
        [(A, "attacking", T), (A, "total_attack", ATK), (T, "total_defense", DEF)],
        (T, "pending_damage", Expr('-', [ATK, DEF])),
        retractions=[
            (A, "total_attack", ATK),  # Consume aggregated values
            (T, "total_defense", DEF)
        ]
    )

    # Phase 3: Apply damage to HP (depends on Phase 3 calc_damage)
    w.add_derivation_rule(
        "apply_damage",
        [(T, "pending_damage", DMG), (T, "hp", HP)],
        (T, "hp", Expr('-', [HP, DMG])),
        retractions=[
            (T, "hp", HP),
            (T, "pending_damage", DMG)
        ]
    )

    print("\nBefore advance:")
    print(f"  hero attack_bonus: {w.query(('hero', 'attack_bonus', Var('x')))}")
    print(f"  goblin defense_bonus: {w.query(('goblin', 'defense_bonus', Var('x')))}")
    print(f"  goblin hp: {w.query(('goblin', 'hp', Var('x')))}")

    # Single advance should run all phases
    w.advance()

    print("\nAfter advance:")
    hp = w.query(('goblin', 'hp', Var('x')))
    total_attack = w.query(('hero', 'total_attack', Var('x')))
    total_defense = w.query(('goblin', 'total_defense', Var('x')))
    pending_damage = w.query(('goblin', 'pending_damage', Var('x')))

    print(f"  total_attack: {total_attack} (should be empty - consumed)")
    print(f"  total_defense: {total_defense} (should be empty - consumed)")
    print(f"  pending_damage: {pending_damage} (should be empty - consumed)")
    print(f"  goblin hp: {hp}")

    # Verify: attack=15, defense=5, damage=10, hp=30-10=20
    assert len(hp) == 1, "HP should exist"
    assert hp[0]['x'] == 20, f"Expected HP=20 (30-10), got {hp[0]['x']}"
    assert len(total_attack) == 0, "total_attack should be consumed"
    assert len(total_defense) == 0, "total_defense should be consumed"
    assert len(pending_damage) == 0, "pending_damage should be consumed"

    print("  PASSED")


def test_phase_classification():
    """
    Test that rules are correctly classified into phases.
    """
    print("\n" + "=" * 60)
    print("Test: Phase Classification")
    print("=" * 60)

    w = World()

    # Setup minimal facts
    w.assert_fact("x", "is_a", "thing")

    X = Var('x')
    V = Var('v')

    # Phase 1 rule: no aggregate, no RETRACT
    w.add_derivation_rule("phase1_derive", [(X, "is_a", "thing")], (X, "exists", True))

    # Phase 1 rule: has RETRACT but doesn't depend on Phase 2
    w.add_derivation_rule(
        "phase1_retract",
        [(X, "marker", V)],
        (X, "processed_marker", V),
        retractions=[(X, "marker", V)]
    )

    # Phase 2 rule: has aggregate
    w.add_derivation_rule(
        "phase2_aggregate",
        [(X, "is_a", "thing")],
        (X, "total_value", AggregateExpr('sum', V, [(X, "value", V)]))
    )

    # Phase 3 rule: has RETRACT, patterns on Phase 2 output (total_value)
    w.add_derivation_rule(
        "phase3_consume",
        [(X, "total_value", V)],
        (X, "final_value", V),
        retractions=[(X, "total_value", V)]
    )

    # Classify rules using N-phase stratification
    strata = w._stratify_rules()

    print(f"\nStrata count: {len(strata)}")
    for i, stratum_rules in enumerate(strata):
        print(f"Stratum {i}: {[r.name for r in stratum_rules]}")

    # Check stratum assignments via the diagnostic API
    # After stratification, we can query each rule's stratum
    assert w.get_rule_stratum("phase1_derive") == 0, "phase1_derive should be stratum 0"
    assert w.get_rule_stratum("phase1_retract") == 0, "phase1_retract should be stratum 0 (doesn't depend on aggregate)"
    assert w.get_rule_stratum("phase2_aggregate") == 1, "phase2_aggregate should be stratum 1 (has aggregate)"
    assert w.get_rule_stratum("phase3_consume") == 2, "phase3_consume should be stratum 2 (depends on aggregate output)"

    print("  PASSED")


def test_phase3_to_fixpoint():
    """
    Test that Phase 3 runs to fixpoint (multiple rule firings within Phase 3).
    """
    print("\n" + "=" * 60)
    print("Test: Phase 3 to Fixpoint")
    print("=" * 60)

    w = World()

    # Setup: multiple pending damages that need processing
    w.assert_fact("hero", "is_a", "target")
    w.assert_fact("hero", "hp", 100)

    # Phase 2: Create multiple pending_damage facts via aggregate (one per attacker)
    w.assert_fact("goblin", "attacks", "hero")
    w.assert_fact("goblin", "attack_bonus", 10)

    w.assert_fact("orc", "attacks", "hero")
    w.assert_fact("orc", "attack_bonus", 15)

    A = Var('a')
    T = Var('t')
    B = Var('b')
    HP = Var('hp')
    DMG = Var('dmg')

    # Phase 2: Calculate damage for each attacker
    w.add_derivation_rule(
        "calc_attack_damage",
        [(A, "attacks", T)],
        (T, "pending_damage_from", AggregateExpr('sum', B, [(A, "attack_bonus", B)])),
    )

    # Phase 3: Apply all pending damages (should fire multiple times)
    w.add_derivation_rule(
        "apply_pending_damage",
        [(T, "pending_damage_from", DMG), (T, "hp", HP)],
        (T, "hp", Expr('-', [HP, DMG])),
        retractions=[
            (T, "hp", HP),
            (T, "pending_damage_from", DMG)
        ]
    )

    print("\nBefore advance:")
    print(f"  hero hp: {w.query(('hero', 'hp', Var('x')))}")

    w.advance()

    print("\nAfter advance:")
    hp = w.query(('hero', 'hp', Var('x')))
    pending = w.query(('hero', 'pending_damage_from', Var('x')))

    print(f"  pending_damage_from: {pending} (should be empty)")
    print(f"  hero hp: {hp}")

    # HP should be 100 - 10 - 15 = 75
    # Both pending damages should be consumed
    assert len(hp) == 1, "HP should exist"
    assert len(pending) == 0, "All pending damage should be consumed"
    # Note: The order of damage application may vary, but final HP should be 75
    assert hp[0]['x'] == 75, f"Expected HP=75 (100-10-15), got {hp[0]['x']}"

    print("  PASSED")


if __name__ == "__main__":
    test_aggregate_then_retract()
    test_combat_damage_with_aggregates()
    test_phase_classification()
    test_phase3_to_fixpoint()

    print("\n" + "=" * 60)
    print("ALL PHASE 3 TESTS PASSED")
    print("=" * 60)
