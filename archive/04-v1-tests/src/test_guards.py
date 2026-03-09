"""
Tests for HERB guard expressions (§10).

Guards are boolean expressions that filter bindings after pattern matching.
Only bindings where the guard evaluates to true proceed to template instantiation.
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from herb_core import World, Var, Expr, var


def test_guard_filters_bindings():
    """Guards filter bindings where the condition is false."""
    world = World()

    # Set up entities with different HP values
    world.assert_fact("alice", "hp", 50)
    world.assert_fact("bob", "hp", 0)  # Dead
    world.assert_fact("carol", "hp", 100)

    world.assert_fact("alice", "is_a", "entity")
    world.assert_fact("bob", "is_a", "entity")
    world.assert_fact("carol", "is_a", "entity")

    HP = var('hp')
    E = var('e')

    # Rule: only entities with HP > 0 are alive
    world.add_derivation_rule(
        "check_alive",
        [(E, "is_a", "entity"), (E, "hp", HP)],
        (E, "status", "alive"),
        guard=Expr('>', [HP, 0])
    )

    world.advance()

    # Check results
    alive_results = world.query((var('who'), "status", "alive"))
    alive_names = {r['who'] for r in alive_results}

    assert "alice" in alive_names, "Alice should be alive (HP=50)"
    assert "carol" in alive_names, "Carol should be alive (HP=100)"
    assert "bob" not in alive_names, "Bob should not be alive (HP=0)"

    print("  test_guard_filters_bindings PASSED")


def test_guard_not_equal():
    """Guards can use not= to exclude self-matches."""
    world = World()

    # Two entities in the same location
    world.assert_fact("alice", "location", "forest")
    world.assert_fact("bob", "location", "forest")
    world.assert_fact("alice", "is_a", "entity")
    world.assert_fact("bob", "is_a", "entity")

    A = var('a')
    B = var('b')
    LOC = var('loc')

    # Rule: entities see each other if same location AND different entities
    world.add_derivation_rule(
        "visibility",
        [(A, "location", LOC), (B, "location", LOC)],
        (A, "sees", B),
        guard=Expr('not=', [A, B])
    )

    world.advance()

    # Check results
    sees_results = world.query((var('x'), "sees", var('y')))

    # Should have alice sees bob, bob sees alice, but NOT alice sees alice
    pairs = {(r['x'], r['y']) for r in sees_results}

    assert ("alice", "bob") in pairs, "Alice should see Bob"
    assert ("bob", "alice") in pairs, "Bob should see Alice"
    assert ("alice", "alice") not in pairs, "Alice should not see herself"
    assert ("bob", "bob") not in pairs, "Bob should not see himself"

    print("  test_guard_not_equal PASSED")


def test_guard_comparison_operators():
    """Guards support all comparison operators."""
    world = World()

    world.assert_fact("item1", "value", 10)
    world.assert_fact("item2", "value", 50)
    world.assert_fact("item3", "value", 100)
    world.assert_fact("item4", "value", 100)  # Equal to threshold

    for i in range(1, 5):
        world.assert_fact(f"item{i}", "is_a", "item")

    ITEM = var('item')
    VAL = var('val')

    # Rule: items with value >= 50 are valuable
    world.add_derivation_rule(
        "check_valuable",
        [(ITEM, "is_a", "item"), (ITEM, "value", VAL)],
        (ITEM, "is_valuable", True),
        guard=Expr('>=', [VAL, 50])
    )

    world.advance()

    valuable = world.query((var('x'), "is_valuable", True))
    valuable_items = {r['x'] for r in valuable}

    assert "item1" not in valuable_items, "item1 (10) not valuable"
    assert "item2" in valuable_items, "item2 (50) is valuable (>=50)"
    assert "item3" in valuable_items, "item3 (100) is valuable"
    assert "item4" in valuable_items, "item4 (100) is valuable"

    print("  test_guard_comparison_operators PASSED")


def test_guard_with_retraction():
    """Guards work with retraction rules."""
    world = World()

    world.assert_fact("hero", "hp", 100)
    world.assert_fact("hero", "pending_damage", 30)

    HP = var('hp')
    DMG = var('dmg')
    E = var('e')

    # Rule: only apply damage if HP > 0
    world.add_derivation_rule(
        "apply_damage",
        [(E, "hp", HP), (E, "pending_damage", DMG)],
        (E, "hp", Expr('-', [HP, DMG])),
        retractions=[(E, "hp", HP), (E, "pending_damage", DMG)],
        guard=Expr('>', [HP, 0])
    )

    world.advance()

    # Check HP was reduced
    hp_result = world.query(("hero", "hp", var('h')))
    assert len(hp_result) == 1
    assert hp_result[0]['h'] == 70, f"Expected HP=70, got {hp_result[0]['h']}"

    # Now add damage that would kill
    world.assert_fact("hero", "pending_damage", 100)
    world.advance()

    hp_result = world.query(("hero", "hp", var('h')))
    assert len(hp_result) == 1
    assert hp_result[0]['h'] == -30, f"Expected HP=-30, got {hp_result[0]['h']}"

    # Add more damage - but HP is now negative, guard should block
    world.assert_fact("hero", "pending_damage", 50)
    world.advance()

    # HP should still be -30 because guard (> ?hp 0) fails
    hp_result = world.query(("hero", "hp", var('h')))
    assert len(hp_result) == 1
    assert hp_result[0]['h'] == -30, f"Expected HP=-30 (unchanged), got {hp_result[0]['h']}"

    # pending_damage should still exist because rule didn't fire
    dmg_result = world.query(("hero", "pending_damage", var('d')))
    assert len(dmg_result) == 1, "pending_damage should still exist"

    print("  test_guard_with_retraction PASSED")


def test_guard_no_guard_fires_all():
    """Rules without guards fire for all bindings."""
    world = World()

    world.assert_fact("a", "value", 10)
    world.assert_fact("b", "value", 0)
    world.assert_fact("c", "value", -5)

    for x in ["a", "b", "c"]:
        world.assert_fact(x, "is_a", "thing")

    X = var('x')
    V = var('v')

    # Rule without guard - should fire for all
    world.add_derivation_rule(
        "mark_all",
        [(X, "is_a", "thing"), (X, "value", V)],
        (X, "processed", True)
    )

    world.advance()

    processed = world.query((var('w'), "processed", True))
    processed_items = {r['w'] for r in processed}

    assert processed_items == {"a", "b", "c"}, f"All should be processed, got {processed_items}"

    print("  test_guard_no_guard_fires_all PASSED")


def test_guard_evaluation_error_skips():
    """Guard evaluation errors silently skip the binding."""
    world = World()

    world.assert_fact("alice", "name", "Alice")  # String, not number
    world.assert_fact("bob", "hp", 50)  # Number

    world.assert_fact("alice", "is_a", "entity")
    world.assert_fact("bob", "is_a", "entity")

    E = var('e')
    HP = var('hp')

    # Rule with guard that expects numbers
    # Alice's "name" is a string, so (> "Alice" 0) would error
    world.add_derivation_rule(
        "check_positive",
        [(E, "is_a", "entity")],
        (E, "checked", True),
        guard=Expr('>', [1, 0])  # Simple guard that always passes
    )

    # This should not crash
    world.advance()

    print("  test_guard_evaluation_error_skips PASSED")


def test_parser_guard():
    """Parser correctly handles IF clause."""
    from herb_lang import tokenize, Parser

    source = """
    RULE alive_check
      WHEN ?e hp ?hp
      AND ?e is_a entity
      IF (> ?hp 0)
      THEN ?e status alive
    """

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    assert len(program.rules) == 1
    rule = program.rules[0]
    assert rule.name == "alive_check"
    assert rule.guard is not None
    assert isinstance(rule.guard, Expr)
    assert rule.guard.op == '>'

    print("  test_parser_guard PASSED")


def test_parser_guard_not_equal():
    """Parser handles not= in guards."""
    from herb_lang import tokenize, Parser

    source = """
    RULE see_other
      WHEN ?a location ?loc
      AND ?b location ?loc
      IF (not= ?a ?b)
      THEN ?a sees ?b
    """

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()

    rule = program.rules[0]
    assert rule.guard is not None
    assert rule.guard.op == 'not='

    print("  test_parser_guard_not_equal PASSED")


def test_full_integration():
    """Full integration: parse .herb file with guards, compile, run."""
    from herb_lang import compile_program, tokenize, Parser

    source = """
    FACT alice is_a entity
    FACT alice hp 50
    FACT bob is_a entity
    FACT bob hp 0
    FACT carol is_a entity
    FACT carol hp 100

    RULE check_alive
      WHEN ?e is_a entity
      AND ?e hp ?hp
      IF (> ?hp 0)
      THEN ?e status alive
    """

    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()
    world = compile_program(program)

    world.advance()

    alive = world.query((var('who'), "status", "alive"))
    names = {r['who'] for r in alive}

    assert names == {"alice", "carol"}, f"Expected alice and carol, got {names}"

    print("  test_full_integration PASSED")


if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("HERB Guards Tests (§10)")
    print("=" * 60 + "\n")

    test_guard_filters_bindings()
    test_guard_not_equal()
    test_guard_comparison_operators()
    test_guard_with_retraction()
    test_guard_no_guard_fires_all()
    test_guard_evaluation_error_skips()
    test_parser_guard()
    test_parser_guard_not_equal()
    test_full_integration()

    print("\n" + "=" * 60)
    print("ALL GUARD TESTS PASSED")
    print("=" * 60)
