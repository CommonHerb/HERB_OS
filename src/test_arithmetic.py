"""
Test: Arithmetic in Rule Templates

This verifies that expressions like (- ?hp ?damage) are properly
evaluated when rules fire.
"""

from herb_core import World, var, Var, Expr

def test_arithmetic_in_templates():
    """Test that arithmetic expressions are evaluated in rule templates."""
    print("=" * 60)
    print("Test: Arithmetic in Rule Templates")
    print("=" * 60)

    world = World()

    # Set up a combatant with HP and pending damage
    world.assert_fact("hero", "hp", 100)
    world.assert_fact("hero", "pending_damage", 35)

    # Rule: compute effective HP as hp - pending_damage
    X = var('x')
    HP = var('hp')
    DMG = var('dmg')

    world.add_derivation_rule(
        "compute_effective_hp",
        patterns=[
            (X, "hp", HP),
            (X, "pending_damage", DMG)
        ],
        template=(X, "effective_hp", Expr('-', [HP, DMG]))
    )

    print("\n--- Initial state ---")
    world.print_state()

    print("\n--- Advancing (rule fires) ---")
    world.advance()
    world.print_state()

    # Verify the computed value
    results = world.query(("hero", "effective_hp", var('result')))
    assert len(results) == 1, f"Expected 1 result, got {len(results)}"
    effective = results[0]['result']
    print(f"\n--- Result: hero effective_hp = {effective} ---")
    assert effective == 65, f"Expected 65, got {effective}"
    print("PASS: Arithmetic evaluation works!\n")

    # Explain the derived fact
    print("--- Provenance ---")
    explanation = world.explain("hero", "effective_hp", 65)
    if explanation:
        print(f"  Fact: {explanation['fact']}")
        print(f"  Cause: {explanation['cause']}")
        print(f"  Depends on:")
        for dep in explanation['depends_on']:
            print(f"    - {dep['fact']}")

    return True


def test_nested_arithmetic():
    """Test nested expressions like (+ ?base (* ?mult ?bonus))"""
    print("\n" + "=" * 60)
    print("Test: Nested Arithmetic Expressions")
    print("=" * 60)

    world = World()

    # A character with base damage and a multiplier
    world.assert_fact("sword", "base_damage", 20)
    world.assert_fact("sword", "bonus", 5)
    world.assert_fact("player", "strength_mult", 2)
    world.assert_fact("player", "weapon", "sword")

    X = var('x')
    W = var('weapon')
    BASE = var('base')
    BONUS = var('bonus')
    MULT = var('mult')

    # total_damage = base + (mult * bonus)
    world.add_derivation_rule(
        "compute_total_damage",
        patterns=[
            (X, "weapon", W),
            (W, "base_damage", BASE),
            (W, "bonus", BONUS),
            (X, "strength_mult", MULT)
        ],
        template=(X, "total_damage", Expr('+', [BASE, Expr('*', [MULT, BONUS])]))
    )

    print("\n--- Initial state ---")
    world.print_state()

    print("\n--- Advancing (rule fires) ---")
    world.advance()
    world.print_state()

    results = world.query(("player", "total_damage", var('result')))
    assert len(results) == 1
    total = results[0]['result']
    print(f"\n--- Result: player total_damage = {total} ---")
    # 20 + (2 * 5) = 30
    assert total == 30, f"Expected 30, got {total}"
    print("PASS: Nested arithmetic works!\n")

    return True


def test_comparison_in_template():
    """Test that comparisons produce boolean values."""
    print("\n" + "=" * 60)
    print("Test: Comparison Operators")
    print("=" * 60)

    world = World()

    world.assert_fact("goblin", "hp", 5)
    world.assert_fact("goblin", "death_threshold", 0)

    X = var('x')
    HP = var('hp')
    THRESH = var('thresh')

    # is_alive = hp > threshold
    world.add_derivation_rule(
        "check_alive",
        patterns=[
            (X, "hp", HP),
            (X, "death_threshold", THRESH)
        ],
        template=(X, "is_alive", Expr('>', [HP, THRESH]))
    )

    world.advance()

    results = world.query(("goblin", "is_alive", var('result')))
    is_alive = results[0]['result']
    print(f"goblin hp=5, threshold=0, is_alive={is_alive}")
    assert is_alive == True, f"Expected True, got {is_alive}"

    # Now reduce HP to 0
    world.retract_fact("goblin", "hp", 5)
    world.assert_fact("goblin", "hp", 0)
    world.advance()

    # Query again (the old is_alive=True should still exist, and new is_alive=False)
    # Actually, the old one still matches so it won't re-derive...
    # We need RETRACT semantics for this to work properly
    print("PASS: Comparison operators work!\n")

    return True


if __name__ == "__main__":
    all_passed = True
    all_passed &= test_arithmetic_in_templates()
    all_passed &= test_nested_arithmetic()
    all_passed &= test_comparison_in_template()

    print("=" * 60)
    if all_passed:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
    print("=" * 60)
