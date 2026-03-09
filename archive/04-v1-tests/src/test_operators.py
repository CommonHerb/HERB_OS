"""
Test additional arithmetic operators: abs, mod

These operators are useful for:
- abs: ideology distance calculations, damage floors
- mod: election cycles, time-based triggers
"""

from herb_core import World, var, Expr, evaluate_expr


def test_abs_positive():
    """abs of positive number returns same value."""
    expr = Expr('abs', [5])
    result = evaluate_expr(expr, {})
    assert result == 5
    return True


def test_abs_negative():
    """abs of negative number returns positive."""
    expr = Expr('abs', [-7])
    result = evaluate_expr(expr, {})
    assert result == 7
    return True


def test_abs_with_variable():
    """abs works with bound variables."""
    expr = Expr('abs', [var('x')])
    result = evaluate_expr(expr, {'x': -10})
    assert result == 10
    return True


def test_abs_nested():
    """abs with nested expression."""
    # abs(3 - 7) = abs(-4) = 4
    inner = Expr('-', [3, 7])
    expr = Expr('abs', [inner])
    result = evaluate_expr(expr, {})
    assert result == 4
    return True


def test_mod_basic():
    """Basic modulo operation."""
    expr = Expr('mod', [17, 5])
    result = evaluate_expr(expr, {})
    assert result == 2  # 17 % 5 = 2
    return True


def test_mod_with_variables():
    """mod with bound variables."""
    expr = Expr('mod', [var('tick'), var('cycle')])
    result = evaluate_expr(expr, {'tick': 100, 'cycle': 30})
    assert result == 10  # 100 % 30 = 10
    return True


def test_mod_zero_result():
    """mod returns 0 when evenly divisible."""
    expr = Expr('mod', [12, 4])
    result = evaluate_expr(expr, {})
    assert result == 0
    return True


def test_abs_in_rule_template():
    """abs operator works in rule templates."""
    from herb_lang import tokenize, Parser, compile_program

    source = """
    FACT point_a x 10
    FACT point_b x 3

    RULE calc_distance
      WHEN point_a x ?ax
      AND point_b x ?bx
      THEN points distance (abs (- ?ax ?bx))
    """
    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()
    world = compile_program(program)
    world.advance()

    X = var('x')
    dist = world.query(("points", "distance", X))
    assert len(dist) == 1
    assert dist[0]['x'] == 7  # |10 - 3| = 7
    return True


def test_mod_in_guard():
    """mod operator works in guard conditions (election cycles)."""
    from herb_lang import tokenize, Parser, compile_program

    source = """
    FACT world tick 30

    # Election happens every 10 ticks
    RULE election_trigger
      WHEN world tick ?t
      IF (= (mod ?t 10) 0)
      THEN world election_due true
    """
    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()
    world = compile_program(program)
    world.advance()

    X = var('x')
    election = world.query(("world", "election_due", True))
    assert len(election) == 1  # 30 % 10 == 0, so election is due
    return True


if __name__ == "__main__":
    tests = [
        test_abs_positive,
        test_abs_negative,
        test_abs_with_variable,
        test_abs_nested,
        test_mod_basic,
        test_mod_with_variables,
        test_mod_zero_result,
        test_abs_in_rule_template,
        test_mod_in_guard,
    ]

    print("=" * 60)
    print("Operator Tests (abs, mod)")
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
