"""
Test HERB parser aggregate syntax.

Verifies that the parser correctly handles:
- (sum ?var WHERE pattern ...)
- (count WHERE pattern ...)
- (max ?var WHERE pattern ...)
- (min ?var WHERE pattern ...)
"""

from herb_lang import tokenize, Parser, compile_program
from herb_core import World, var, AggregateExpr


def test_parse_sum_aggregate():
    """Test parsing sum aggregate in a rule template."""
    print("=" * 60)
    print("Test: Parse sum aggregate")
    print("=" * 60)

    source = '''
    FACT player is_a entity
    FACT player has_bonus 10
    FACT player has_bonus 5

    RULE total_bonus
      WHEN ?p is_a entity
      THEN ?p total_bonus (sum ?b WHERE ?p has_bonus ?b)
    '''

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    assert len(program.rules) == 1
    rule = program.rules[0]
    print(f"  Rule: {rule.name}")
    print(f"  Template: {rule.then_templates[0]}")

    # Check that the object is an AggregateExpr
    template = rule.then_templates[0]
    assert isinstance(template.object, AggregateExpr), f"Expected AggregateExpr, got {type(template.object)}"
    assert template.object.op == 'sum'
    assert template.object.var.name == 'b'

    print("  PASSED")


def test_parse_count_aggregate():
    """Test parsing count aggregate (no variable)."""
    print("\n" + "=" * 60)
    print("Test: Parse count aggregate")
    print("=" * 60)

    source = '''
    RULE item_count
      WHEN ?p is_a entity
      THEN ?p item_count (count WHERE ?p has_item ?i)
    '''

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    rule = program.rules[0]
    template = rule.then_templates[0]
    print(f"  Template object: {template.object}")

    assert isinstance(template.object, AggregateExpr)
    assert template.object.op == 'count'
    assert template.object.var is None  # count has no variable

    print("  PASSED")


def test_parse_multi_pattern_aggregate():
    """Test aggregate with multiple WHERE patterns."""
    print("\n" + "=" * 60)
    print("Test: Parse multi-pattern aggregate")
    print("=" * 60)

    source = '''
    RULE carry_weight
      WHEN ?p is_a player
      THEN ?p total_weight (sum ?w WHERE ?p equipped ?item ?item weight ?w)
    '''

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    rule = program.rules[0]
    template = rule.then_templates[0]
    agg = template.object

    print(f"  Aggregate: {agg}")
    print(f"  Patterns: {agg.patterns}")

    assert isinstance(agg, AggregateExpr)
    assert len(agg.patterns) == 2  # Two patterns in WHERE clause

    print("  PASSED")


def test_compile_aggregate_rule():
    """Test full compilation and execution of aggregate rule."""
    print("\n" + "=" * 60)
    print("Test: Compile and run aggregate rule")
    print("=" * 60)

    source = '''
    FACT player is_a entity
    FACT player has_bonus 10
    FACT player has_bonus 5
    FACT player has_bonus 3

    RULE total_bonus
      WHEN ?p is_a entity
      THEN ?p total_bonus (sum ?b WHERE ?p has_bonus ?b)
    '''

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    world = compile_program(program)
    print(f"  Facts before advance: {len(world)} alive")

    world.advance()

    B = var('b')
    result = world.query(("player", "total_bonus", B))
    print(f"  total_bonus: {result}")

    assert len(result) == 1
    assert result[0]['b'] == 18, f"Expected 18, got {result[0]['b']}"

    print("  PASSED")


def test_non_aggregate_max_min():
    """Test that max/min without WHERE are still regular expressions."""
    print("\n" + "=" * 60)
    print("Test: Non-aggregate max/min")
    print("=" * 60)

    source = '''
    FACT hero hp 100
    FACT hero pending_damage 120

    RULE calc_effective
      WHEN ?e hp ?hp AND ?e pending_damage ?dmg
      THEN ?e effective_hp (max 0 (- ?hp ?dmg))
    '''

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    rule = program.rules[0]
    template = rule.then_templates[0]
    print(f"  Template object: {template.object}")

    # This should be a regular Expr, not AggregateExpr
    from herb_core import Expr
    assert isinstance(template.object, Expr), f"Expected Expr, got {type(template.object)}"
    assert template.object.op == 'max'

    # And it should work
    world = compile_program(program)
    world.advance()

    HP = var('hp')
    result = world.query(("hero", "effective_hp", HP))
    print(f"  effective_hp: {result}")

    assert result[0]['hp'] == 0  # max(0, 100-120) = max(0, -20) = 0

    print("  PASSED")


def run_all_tests():
    """Run all parser aggregate tests."""
    test_parse_sum_aggregate()
    test_parse_count_aggregate()
    test_parse_multi_pattern_aggregate()
    test_compile_aggregate_rule()
    test_non_aggregate_max_min()

    print("\n" + "=" * 60)
    print("ALL PARSER AGGREGATE TESTS PASSED")
    print("=" * 60)


if __name__ == "__main__":
    run_all_tests()
