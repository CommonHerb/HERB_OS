"""
HERB Functional Relations Tests

Tests that FUNCTIONAL declarations work correctly:
- Auto-retract on assert
- Eliminates RETRACT boilerplate
- Parser support
"""

from herb_core import World, Var, Expr
from herb_lang import tokenize, Parser, compile_program


def test_functional_basic():
    """Test basic functional relation behavior."""
    print("\n" + "=" * 60)
    print("Test: Functional Relations - Basic")
    print("=" * 60)

    w = World()
    w.declare_functional("hp")

    # Assert initial HP
    w.assert_fact("hero", "hp", 100)
    result = w.query(("hero", "hp", Var('x')))
    assert len(result) == 1 and result[0]['x'] == 100, f"Expected hp=100, got {result}"
    print("  Initial hp=100: PASS")

    # Assert new HP - should auto-retract old value
    w.assert_fact("hero", "hp", 80)
    result = w.query(("hero", "hp", Var('x')))
    assert len(result) == 1 and result[0]['x'] == 80, f"Expected hp=80 (auto-retract), got {result}"
    print("  Updated hp=80 (auto-retract): PASS")

    # Assert same value again - should not duplicate
    w.assert_fact("hero", "hp", 80)
    result = w.query(("hero", "hp", Var('x')))
    assert len(result) == 1, f"Expected single hp value, got {result}"
    print("  Same value no duplicate: PASS")

    # Non-functional relation should allow multiple values
    w.assert_fact("hero", "bonus", 5)
    w.assert_fact("hero", "bonus", 10)
    result = w.query(("hero", "bonus", Var('x')))
    assert len(result) == 2, f"Expected 2 bonus values, got {result}"
    print("  Non-functional allows multi-values: PASS")

    print("  PASSED")


def test_functional_in_rules():
    """Test functional relations with derivation rules - no RETRACT needed."""
    print("\n" + "=" * 60)
    print("Test: Functional Relations - Rules Without RETRACT")
    print("=" * 60)

    w = World()
    w.declare_functional("hp")
    w.declare_functional("gold")

    # Setup
    w.assert_fact("hero", "hp", 100)
    w.assert_fact("hero", "pending_damage", 20)

    # Rule WITHOUT explicit RETRACT - hp is functional so auto-retract
    HP = Var('hp')
    DMG = Var('dmg')
    E = Var('e')
    w.add_derivation_rule(
        "apply_damage_functional",
        [(E, "hp", HP), (E, "pending_damage", DMG)],
        (E, "hp", Expr('-', [HP, DMG])),
        retractions=[(E, "pending_damage", DMG)]  # Still need to retract pending_damage
        # NOTE: No (E, "hp", HP) retraction needed - functional auto-retracts
    )

    print(f"  Before advance: hp = {w.query(('hero', 'hp', Var('x')))}")
    w.advance()
    print(f"  After advance: hp = {w.query(('hero', 'hp', Var('x')))}")

    result = w.query(("hero", "hp", Var('x')))
    # Should have hp=80 (100-20), NOT both 100 and 80
    assert len(result) == 1, f"Expected single hp (functional), got {result}"
    assert result[0]['x'] == 80, f"Expected hp=80, got {result}"

    print("  PASSED")


def test_functional_parser():
    """Test parsing FUNCTIONAL declarations."""
    print("\n" + "=" * 60)
    print("Test: Functional Relations - Parser")
    print("=" * 60)

    source = '''
    FUNCTIONAL hp
    FUNCTIONAL location
    FUNCTIONAL gold

    FACT hero hp 100
    FACT hero location town
    FACT hero gold 50

    RULE spend_gold
      WHEN ?p gold ?g
      AND ?p wants_to_buy ?item
      AND ?item cost ?c
      THEN ?p gold (- ?g ?c)
    '''

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    assert len(program.functional) == 3, f"Expected 3 functional decls, got {len(program.functional)}"
    func_rels = [f.relation for f in program.functional]
    assert "hp" in func_rels, "hp should be functional"
    assert "location" in func_rels, "location should be functional"
    assert "gold" in func_rels, "gold should be functional"
    print(f"  Parsed functional relations: {func_rels}")

    # Compile and verify
    world = compile_program(program)
    assert world.is_functional("hp"), "hp should be functional in world"
    assert world.is_functional("location"), "location should be functional in world"
    assert not world.is_functional("wants_to_buy"), "wants_to_buy should not be functional"

    print("  PASSED")


def test_functional_combat_demo():
    """Test functional relations in combat scenario - much cleaner than explicit RETRACT."""
    print("\n" + "=" * 60)
    print("Test: Functional Relations - Combat Demo (Reduced RETRACT)")
    print("=" * 60)

    w = World()

    # Declare functional relations
    w.declare_functional("hp")
    w.declare_functional("total_attack")
    w.declare_functional("total_defense")
    w.declare_functional("pending_damage")

    # Setup
    w.assert_fact("hero", "attack_bonus", 15)
    w.assert_fact("hero", "attack_bonus", 5)
    w.assert_fact("hero", "attack_bonus", 3)
    w.assert_fact("hero", "attacking", "goblin")

    w.assert_fact("goblin", "hp", 40)
    w.assert_fact("goblin", "defense_bonus", 5)
    w.assert_fact("goblin", "defense_bonus", 2)

    # Variables
    from herb_core import AggregateExpr
    A = Var('a')
    T = Var('t')
    B = Var('b')
    ATK = Var('atk')
    DEF = Var('def')
    DMG = Var('dmg')
    HP = Var('hp')

    # Aggregate rules (still in Phase 2, no RETRACT)
    w.add_derivation_rule(
        "calc_attack",
        [(A, "attacking", T)],
        (A, "total_attack", AggregateExpr('sum', B, [(A, "attack_bonus", B)]))
    )
    w.add_derivation_rule(
        "calc_defense",
        [(A, "attacking", T)],
        (T, "total_defense", AggregateExpr('sum', B, [(T, "defense_bonus", B)]))
    )

    # Post-aggregate rules - functional relations mean less RETRACT!
    # total_attack and total_defense are functional - but we still need to "consume" them
    # The win is for things like hp where we repeatedly update
    w.add_derivation_rule(
        "calc_damage",
        [(A, "attacking", T), (A, "total_attack", ATK), (T, "total_defense", DEF)],
        (T, "pending_damage", Expr('-', [ATK, DEF])),
        # Still retract consumed values to prevent re-firing
        retractions=[(A, "total_attack", ATK), (T, "total_defense", DEF)]
    )

    # Apply damage - hp is functional, so NO RETRACT needed for hp!
    w.add_derivation_rule(
        "apply_damage",
        [(T, "pending_damage", DMG), (T, "hp", HP)],
        (T, "hp", Expr('-', [HP, DMG])),
        # Only retract pending_damage, not hp!
        retractions=[(T, "pending_damage", DMG)]
    )

    print("  Before advance:")
    print(f"    goblin hp: {w.query(('goblin', 'hp', Var('x')))}")

    w.advance()

    print("  After advance:")
    hp_result = w.query(('goblin', 'hp', Var('x')))
    print(f"    goblin hp: {hp_result}")

    # Expected: 23 attack - 7 defense = 16 damage, 40 - 16 = 24 hp
    assert len(hp_result) == 1, f"Functional hp should have single value, got {hp_result}"
    assert hp_result[0]['x'] == 24, f"Expected hp=24, got {hp_result}"

    print("  PASSED")


def run_all_tests():
    test_functional_basic()
    test_functional_in_rules()
    test_functional_parser()
    test_functional_combat_demo()

    print("\n" + "=" * 60)
    print("ALL FUNCTIONAL RELATION TESTS PASSED")
    print("=" * 60)


if __name__ == "__main__":
    run_all_tests()
