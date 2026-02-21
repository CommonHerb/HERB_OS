"""
HERB Stratified Aggregation Tests

Tests the aggregate expression system:
- sum, count, max, min with WHERE patterns
- Stratified execution (Phase 2 after base rules reach fixpoint)
- Static validation (aggregate rules can't have retractions)
- Aggregate rules see stable fact base

Spec reference: §4.3, §5.4, §6.1, §6.3
"""

from herb_core import (
    World, var, Var, Expr, AggregateExpr,
    evaluate_expr, evaluate_aggregate_expr, contains_aggregate
)


def test_aggregate_expr_evaluation():
    """Test direct evaluation of aggregate expressions."""
    print("=" * 60)
    print("Test: Aggregate Expression Evaluation")
    print("=" * 60)

    world = World()
    X, B = var('x'), var('b')

    # Set up: player has multiple bonuses
    world.assert_fact("player", "is_a", "entity")
    world.assert_fact("player", "has_bonus", 10)
    world.assert_fact("player", "has_bonus", 5)
    world.assert_fact("player", "has_bonus", 3)

    # Test sum
    agg_sum = AggregateExpr('sum', B, [("player", "has_bonus", B)])
    result = evaluate_aggregate_expr(agg_sum, {}, world)
    print(f"  sum of bonuses: {result}")
    assert result == 18, f"Expected 18, got {result}"

    # Test count
    agg_count = AggregateExpr('count', None, [("player", "has_bonus", B)])
    result = evaluate_aggregate_expr(agg_count, {}, world)
    print(f"  count of bonuses: {result}")
    assert result == 3, f"Expected 3, got {result}"

    # Test max
    agg_max = AggregateExpr('max', B, [("player", "has_bonus", B)])
    result = evaluate_aggregate_expr(agg_max, {}, world)
    print(f"  max bonus: {result}")
    assert result == 10, f"Expected 10, got {result}"

    # Test min
    agg_min = AggregateExpr('min', B, [("player", "has_bonus", B)])
    result = evaluate_aggregate_expr(agg_min, {}, world)
    print(f"  min bonus: {result}")
    assert result == 3, f"Expected 3, got {result}"

    print("  PASSED")


def test_contains_aggregate():
    """Test detection of aggregate expressions in values."""
    print("\n" + "=" * 60)
    print("Test: Contains Aggregate Detection")
    print("=" * 60)

    B = var('b')

    # Plain value - no aggregate
    assert not contains_aggregate(10)
    assert not contains_aggregate("hello")
    assert not contains_aggregate(B)
    print("  Plain values: PASSED")

    # Plain Expr - no aggregate
    plain_expr = Expr('+', [10, 5])
    assert not contains_aggregate(plain_expr)
    print("  Plain expression: PASSED")

    # Aggregate expression
    agg = AggregateExpr('sum', B, [("player", "has_bonus", B)])
    assert contains_aggregate(agg)
    print("  AggregateExpr: PASSED")

    # Nested aggregate in Expr
    nested = Expr('+', [10, agg])
    assert contains_aggregate(nested)
    print("  Nested aggregate: PASSED")


def test_stratified_derivation():
    """Test that aggregate rules run in Phase 2 after base rules reach fixpoint."""
    print("\n" + "=" * 60)
    print("Test: Stratified Derivation (Phase 1 then Phase 2)")
    print("=" * 60)

    world = World()

    X, Y, B, T = var('x'), var('y'), var('b'), var('t')

    # Base facts
    world.assert_fact("player", "is_a", "entity")
    world.assert_fact("sword", "is_a", "equipment")
    world.assert_fact("sword", "bonus", 5)
    world.assert_fact("shield", "is_a", "equipment")
    world.assert_fact("shield", "bonus", 3)
    world.assert_fact("player", "equipped", "sword")
    world.assert_fact("player", "equipped", "shield")

    # Base rule: derive has_bonus from equipment
    # This runs in Phase 1
    world.add_derivation_rule(
        "equipment_bonus",
        patterns=[
            (X, "is_a", "entity"),
            (X, "equipped", Y),
            (Y, "bonus", B)
        ],
        template=(X, "has_bonus", B)
    )

    # Aggregate rule: sum all bonuses
    # This runs in Phase 2, sees the stable result of Phase 1
    world.add_derivation_rule(
        "total_bonus",
        patterns=[(X, "is_a", "entity")],
        template=(X, "total_bonus", AggregateExpr('sum', B, [(X, "has_bonus", B)]))
    )

    print("  Before advance:")
    print(f"    has_bonus facts: {world.query((X, 'has_bonus', B))}")
    print(f"    total_bonus facts: {world.query((X, 'total_bonus', T))}")

    # Advance - this should run Phase 1 (derive has_bonus) then Phase 2 (aggregate)
    world.advance()

    print("  After advance:")
    has_bonuses = world.query((X, "has_bonus", B))
    print(f"    has_bonus facts: {has_bonuses}")

    total = world.query(("player", "total_bonus", T))
    print(f"    total_bonus: {total}")

    # Verify
    assert len(has_bonuses) == 2, f"Expected 2 has_bonus facts, got {len(has_bonuses)}"

    bonus_values = {b['b'] for b in has_bonuses}
    assert bonus_values == {5, 3}, f"Expected {{5, 3}}, got {bonus_values}"

    assert len(total) == 1, f"Expected 1 total_bonus fact, got {len(total)}"
    assert total[0]['t'] == 8, f"Expected total_bonus = 8, got {total[0]['t']}"

    print("  PASSED")


def test_aggregate_rule_validation():
    """Test that aggregate rules with retractions are rejected."""
    print("\n" + "=" * 60)
    print("Test: Aggregate Rule Validation")
    print("=" * 60)

    world = World()
    X, B, T = var('x'), var('b'), var('t')

    # Try to add aggregate rule with retraction - should fail
    try:
        world.add_derivation_rule(
            "invalid_rule",
            patterns=[(X, "is_a", "entity")],
            template=(X, "total", AggregateExpr('sum', B, [(X, "has_bonus", B)])),
            retractions=[(X, "old_total", T)]  # Invalid!
        )
        assert False, "Should have raised ValueError"
    except ValueError as e:
        print(f"  Correctly rejected: {e}")
        assert "cannot have RETRACT" in str(e)

    print("  PASSED")


def test_count_aggregate():
    """Test count aggregate in a rule."""
    print("\n" + "=" * 60)
    print("Test: Count Aggregate")
    print("=" * 60)

    world = World()
    X, I, C = var('x'), var('i'), var('c')

    # Player has multiple items
    world.assert_fact("player", "is_a", "entity")
    world.assert_fact("player", "has_item", "sword")
    world.assert_fact("player", "has_item", "shield")
    world.assert_fact("player", "has_item", "potion")
    world.assert_fact("player", "has_item", "key")

    # Rule to count items
    world.add_derivation_rule(
        "count_items",
        patterns=[(X, "is_a", "entity")],
        template=(X, "item_count", AggregateExpr('count', None, [(X, "has_item", I)]))
    )

    world.advance()

    result = world.query(("player", "item_count", C))
    print(f"  item_count: {result}")

    assert len(result) == 1
    assert result[0]['c'] == 4, f"Expected 4, got {result[0]['c']}"

    print("  PASSED")


def test_aggregate_with_join():
    """Test aggregate that joins multiple patterns."""
    print("\n" + "=" * 60)
    print("Test: Aggregate with Multi-Pattern Join")
    print("=" * 60)

    world = World()
    P, I, W, T = var('p'), var('i'), var('w'), var('t')

    # Two players with different equipment
    world.assert_fact("alice", "is_a", "player")
    world.assert_fact("bob", "is_a", "player")

    world.assert_fact("alice", "equipped", "iron_sword")
    world.assert_fact("alice", "equipped", "iron_shield")
    world.assert_fact("bob", "equipped", "steel_sword")

    # Equipment weights
    world.assert_fact("iron_sword", "weight", 5)
    world.assert_fact("iron_shield", "weight", 8)
    world.assert_fact("steel_sword", "weight", 7)

    # Rule: calculate carry weight for each player
    # This aggregate joins player -> equipped -> item -> weight
    world.add_derivation_rule(
        "carry_weight",
        patterns=[(P, "is_a", "player")],
        template=(
            P, "carry_weight",
            AggregateExpr('sum', W, [
                (P, "equipped", I),
                (I, "weight", W)
            ])
        )
    )

    world.advance()

    alice_weight = world.query(("alice", "carry_weight", T))
    bob_weight = world.query(("bob", "carry_weight", T))

    print(f"  alice carry_weight: {alice_weight}")
    print(f"  bob carry_weight: {bob_weight}")

    assert alice_weight[0]['t'] == 13, f"Expected alice=13, got {alice_weight[0]['t']}"
    assert bob_weight[0]['t'] == 7, f"Expected bob=7, got {bob_weight[0]['t']}"

    print("  PASSED")


def test_base_and_aggregate_ordering():
    """Verify aggregates see results of base rules, not intermediate states."""
    print("\n" + "=" * 60)
    print("Test: Base Rules Complete Before Aggregates")
    print("=" * 60)

    world = World()
    X, Y, B, T = var('x'), var('y'), var('b'), var('t')

    # Fact: player has raw_power
    world.assert_fact("player", "is_a", "entity")
    world.assert_fact("player", "raw_power", 10)

    # Base rule 1: derive power from raw_power
    world.add_derivation_rule(
        "base_power",
        patterns=[(X, "is_a", "entity"), (X, "raw_power", B)],
        template=(X, "power", B)
    )

    # Base rule 2: power amplifier adds +5
    world.add_derivation_rule(
        "amplify_power",
        patterns=[(X, "is_a", "entity"), (X, "raw_power", B)],
        template=(X, "power", Expr('+', [B, 5]))
    )

    # Aggregate rule: count power facts (should see BOTH base rule results)
    world.add_derivation_rule(
        "power_count",
        patterns=[(X, "is_a", "entity")],
        template=(X, "power_sources", AggregateExpr('count', None, [(X, "power", Y)]))
    )

    world.advance()

    power_facts = world.query(("player", "power", B))
    print(f"  power facts: {[b['b'] for b in power_facts]}")

    count = world.query(("player", "power_sources", T))
    print(f"  power_sources: {count[0]['t']}")

    # Should have 2 power facts (10 and 15)
    assert len(power_facts) == 2
    assert count[0]['t'] == 2

    print("  PASSED")


def run_all_tests():
    """Run all aggregation tests."""
    test_aggregate_expr_evaluation()
    test_contains_aggregate()
    test_stratified_derivation()
    test_aggregate_rule_validation()
    test_count_aggregate()
    test_aggregate_with_join()
    test_base_and_aggregate_ordering()

    print("\n" + "=" * 60)
    print("ALL AGGREGATION TESTS PASSED")
    print("=" * 60)


if __name__ == "__main__":
    run_all_tests()
