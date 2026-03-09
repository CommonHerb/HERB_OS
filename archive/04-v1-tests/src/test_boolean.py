"""
Test boolean literal consistency.

HERB spec §2 defines `true` and `false` as boolean primitives.
This test verifies that:
1. Parser converts `true`/`false` atoms to Python booleans
2. Facts created from .herb files match queries using Python booleans
3. Facts asserted with Python booleans work consistently
"""

from herb_lang import tokenize, Parser, compile_program, load_herb_file
from herb_core import World, var


def test_parser_converts_true_to_python_bool():
    """Parser should convert `true` atom to Python True."""
    source = "FACT goblin hostile true"
    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    assert len(program.facts) == 1
    fact = program.facts[0]
    assert fact.object is True  # Python bool, not string "true"
    assert fact.object != "true"
    assert type(fact.object) is bool
    return True


def test_parser_converts_false_to_python_bool():
    """Parser should convert `false` atom to Python False."""
    source = "FACT player is_dead false"
    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    assert len(program.facts) == 1
    fact = program.facts[0]
    assert fact.object is False  # Python bool
    assert fact.object != "false"
    assert type(fact.object) is bool
    return True


def test_compiled_facts_match_python_bool_queries():
    """Facts from .herb source should match queries using Python bools."""
    source = """
    FACT goblin hostile true
    FACT player friendly true
    FACT skeleton is_dead false
    """
    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()
    world = compile_program(program)

    # Query using Python True
    X = var('x')
    hostile = world.query((X, "hostile", True))
    assert len(hostile) == 1
    assert hostile[0]['x'] == "goblin"

    # Query using Python False
    not_dead = world.query((X, "is_dead", False))
    assert len(not_dead) == 1
    assert not_dead[0]['x'] == "skeleton"
    return True


def test_python_bool_facts_work():
    """Facts asserted directly with Python bools should work."""
    world = World()
    world.assert_fact("wolf", "aggressive", True)
    world.assert_fact("bunny", "aggressive", False)

    X = var('x')
    aggressive = world.query((X, "aggressive", True))
    assert len(aggressive) == 1
    assert aggressive[0]['x'] == "wolf"
    return True


def test_rule_patterns_match_booleans():
    """Rules should correctly match boolean values in patterns."""
    source = """
    FACT wolf aggressive true
    FACT bunny aggressive false
    FACT wolf hp 50
    FACT bunny hp 10

    RULE target_aggressive
      WHEN ?e aggressive true
      AND ?e hp ?hp
      THEN ?e is_target true
    """
    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()
    world = compile_program(program)
    world.advance()

    X = var('x')
    targets = world.query((X, "is_target", True))
    assert len(targets) == 1
    assert targets[0]['x'] == "wolf"
    return True


def test_boolean_in_retract():
    """RETRACT patterns should correctly match boolean values."""
    source = """
    FACT player is_alive true
    FACT player hp 0

    RULE death
      WHEN ?e hp ?hp
      AND ?e is_alive true
      IF (<= ?hp 0)
      THEN ?e is_dead true
      RETRACT ?e is_alive true
    """
    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()
    world = compile_program(program)
    world.advance()

    X = var('x')
    alive = world.query((X, "is_alive", True))
    dead = world.query((X, "is_dead", True))

    assert len(alive) == 0, "Player should no longer be alive"
    assert len(dead) == 1, "Player should be dead"
    assert dead[0]['x'] == "player"
    return True


if __name__ == "__main__":
    tests = [
        test_parser_converts_true_to_python_bool,
        test_parser_converts_false_to_python_bool,
        test_compiled_facts_match_python_bool_queries,
        test_python_bool_facts_work,
        test_rule_patterns_match_booleans,
        test_boolean_in_retract,
    ]

    print("=" * 60)
    print("Boolean Consistency Tests")
    print("=" * 60)

    passed = 0
    failed = 0

    for test in tests:
        try:
            result = test()
            if result:
                print(f"  PASS: {test.__name__}")
                passed += 1
            else:
                print(f"  FAIL: {test.__name__} - returned False")
                failed += 1
        except Exception as e:
            print(f"  FAIL: {test.__name__} - {e}")
            failed += 1

    print()
    print(f"Results: {passed} passed, {failed} failed")

    if failed > 0:
        exit(1)
