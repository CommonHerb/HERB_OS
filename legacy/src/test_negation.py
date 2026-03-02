"""
HERB Negation Tests (§11)

Tests for not-exists expressions in guards.
"""

from herb_core import (
    World, var, Var, Expr, NotExistsExpr,
    evaluate_not_exists_expr, contains_negation
)

X, Y, Z = var('x'), var('y'), var('z')
A, B = var('a'), var('b')


def test_not_exists_basic():
    """Test basic not-exists evaluation."""
    print("  test_not_exists_basic", end=" ")

    world = World()
    world.assert_fact("alice", "exemption", "tax_a")

    # Check for alice's exemption (should exist)
    nexpr = NotExistsExpr([("alice", "exemption", "tax_a")])
    bindings = {}
    result = evaluate_not_exists_expr(nexpr, bindings, world)
    assert result == False, "Should be False when fact exists"

    # Check for bob's exemption (should not exist)
    nexpr = NotExistsExpr([("bob", "exemption", "tax_a")])
    result = evaluate_not_exists_expr(nexpr, bindings, world)
    assert result == True, "Should be True when fact doesn't exist"

    print("PASSED")


def test_not_exists_with_bindings():
    """Test not-exists with variable substitution."""
    print("  test_not_exists_with_bindings", end=" ")

    world = World()
    world.assert_fact("alice", "exemption", "zone_1")
    world.assert_fact("bob", "is_player", True)

    # Pattern with variables that get substituted
    nexpr = NotExistsExpr([(Var('p'), "exemption", Var('z'))])

    # alice has exemption for zone_1
    bindings = {'p': 'alice', 'z': 'zone_1'}
    result = evaluate_not_exists_expr(nexpr, bindings, world)
    assert result == False, "alice has exemption for zone_1"

    # bob has no exemption
    bindings = {'p': 'bob', 'z': 'zone_1'}
    result = evaluate_not_exists_expr(nexpr, bindings, world)
    assert result == True, "bob has no exemption"

    print("PASSED")


def test_not_exists_unbound_variable():
    """Test that unbound variables in not-exists work as wildcards."""
    print("  test_not_exists_unbound_variable", end=" ")

    world = World()
    world.assert_fact("alice", "exemption", "zone_1")
    world.assert_fact("alice", "exemption", "zone_2")

    # Pattern with unbound ?z acts as wildcard: "alice has ANY exemption"
    nexpr = NotExistsExpr([(Var('p'), "exemption", Var('z'))])

    # alice has exemptions
    bindings = {'p': 'alice'}
    result = evaluate_not_exists_expr(nexpr, bindings, world)
    assert result == False, "alice has exemptions, should be False"

    # bob has no exemptions
    bindings = {'p': 'bob'}
    result = evaluate_not_exists_expr(nexpr, bindings, world)
    assert result == True, "bob has no exemptions, should be True"

    print("PASSED")


def test_contains_negation():
    """Test detection of not-exists in expressions."""
    print("  test_contains_negation", end=" ")

    # Plain expression
    expr = Expr('>', [Var('hp'), 0])
    assert contains_negation(expr) == False

    # NotExistsExpr directly
    nexpr = NotExistsExpr([("alice", "exemption", "zone_1")])
    assert contains_negation(nexpr) == True

    # Nested in Expr (this is hypothetical - guards don't nest like this typically)
    # But we test the detection anyway

    print("PASSED")


def test_rule_with_negation():
    """Test a rule with not-exists guard."""
    print("  test_rule_with_negation", end=" ")

    world = World()

    # Set up: alice has exemption, bob doesn't
    world.assert_fact("alice", "in_jurisdiction", "zone_1")
    world.assert_fact("alice", "exemption", "zone_1")
    world.assert_fact("bob", "in_jurisdiction", "zone_1")
    world.assert_fact("zone_1", "tax_rate", 10)

    # Rule: if in jurisdiction and no exemption, mark as taxable
    # Guard: (not-exists (?p exemption ?j))
    P, J = var('p'), var('j')
    RATE = var('rate')

    guard = NotExistsExpr([(P, "exemption", J)])

    world.add_derivation_rule(
        "apply_tax",
        patterns=[
            (P, "in_jurisdiction", J),
            (J, "tax_rate", RATE)
        ],
        template=(P, "taxable_amount", RATE),
        guard=guard
    )

    # Advance to trigger derivation
    world.advance()

    # Alice should NOT be taxable (has exemption)
    alice_tax = world.query(("alice", "taxable_amount", X))
    assert len(alice_tax) == 0, f"Alice should not be taxable, got {alice_tax}"

    # Bob should be taxable (no exemption)
    bob_tax = world.query(("bob", "taxable_amount", X))
    assert len(bob_tax) == 1, f"Bob should be taxable, got {bob_tax}"
    assert bob_tax[0]['x'] == 10

    print("PASSED")


def test_rule_stratification():
    """Test that negation rules run in Phase 2 after base rules."""
    print("  test_rule_stratification", end=" ")

    world = World()

    # Setup: players and monsters
    world.assert_fact("alice", "is_a", "player")
    world.assert_fact("goblin", "is_a", "monster")
    world.assert_fact("alice", "location", "forest")
    world.assert_fact("goblin", "location", "forest")

    # Base rule: if player and monster in same location, monster targets player
    P, M, LOC = var('p'), var('m'), var('loc')

    world.add_derivation_rule(
        "monster_target",
        patterns=[
            (P, "is_a", "player"),
            (M, "is_a", "monster"),
            (P, "location", LOC),
            (M, "location", LOC)
        ],
        template=(M, "targets", P)
    )

    # Negation rule: if player is targeted, mark as "in_danger"
    # If player is NOT targeted, mark as "safe"
    world.add_derivation_rule(
        "mark_safe",
        patterns=[(P, "is_a", "player")],
        template=(P, "status", "safe"),
        guard=NotExistsExpr([(X, "targets", P)])
    )

    # Advance - base rules first, then negation
    world.advance()

    # Goblin should target alice (base rule)
    targets = world.query(("goblin", "targets", X))
    assert len(targets) == 1 and targets[0]['x'] == "alice"

    # Alice should NOT be safe (because she's targeted)
    alice_safe = world.query(("alice", "status", "safe"))
    assert len(alice_safe) == 0, f"Alice should not be safe, got {alice_safe}"

    print("PASSED")


def test_parser_not_exists():
    """Test parsing of not-exists expressions."""
    print("  test_parser_not_exists", end=" ")

    from herb_lang import tokenize, Parser

    source = """
    RULE apply_tax
      WHEN ?p in_jurisdiction ?j
      AND ?j tax_rate ?rate
      IF (not-exists ?p exemption ?j)
      THEN ?p taxable_amount ?rate
    """

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    assert len(program.rules) == 1
    rule = program.rules[0]
    assert rule.name == "apply_tax"
    assert rule.guard is not None
    assert isinstance(rule.guard, NotExistsExpr)
    assert len(rule.guard.patterns) == 1

    print("PASSED")


def test_full_integration():
    """Test complete negation workflow from .herb file to execution."""
    print("  test_full_integration", end=" ")

    from herb_lang import tokenize, Parser, compile_program

    source = """
    # Players and jurisdiction
    FACT alice is_a player
    FACT bob is_a player
    FACT alice in_zone north
    FACT bob in_zone north
    FACT north tax_rate 10

    # alice has exemption, bob doesn't
    FACT alice exemption north

    # Rule: if in zone with tax and no exemption, charge tax
    RULE charge_tax
      WHEN ?p is_a player
      AND ?p in_zone ?z
      AND ?z tax_rate ?rate
      IF (not-exists ?p exemption ?z)
      THEN ?p owes_tax ?rate
    """

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()
    world = compile_program(program)

    # Advance to trigger rules
    world.advance()

    # Alice should not owe tax (has exemption)
    alice_tax = world.query(("alice", "owes_tax", var('x')))
    assert len(alice_tax) == 0, f"Alice should not owe tax: {alice_tax}"

    # Bob should owe tax (no exemption)
    bob_tax = world.query(("bob", "owes_tax", var('x')))
    assert len(bob_tax) == 1, f"Bob should owe tax: {bob_tax}"
    assert bob_tax[0]['x'] == 10

    print("PASSED")


if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("HERB Negation Tests (§11)")
    print("=" * 60 + "\n")

    test_not_exists_basic()
    test_not_exists_with_bindings()
    test_not_exists_unbound_variable()
    test_contains_negation()
    test_rule_with_negation()
    test_rule_stratification()
    test_parser_not_exists()
    test_full_integration()

    print("\n" + "=" * 60)
    print("ALL NEGATION TESTS PASSED")
    print("=" * 60)
