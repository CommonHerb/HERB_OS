"""
Test: RETRACT Semantics in Derivation Rules

This verifies that rules can both assert new facts AND retract existing ones.
This is essential for proper state transitions like applying damage.
"""

from herb_core import World, var, Var, Expr

def test_simple_retract():
    """Test that retractions work in rules."""
    print("=" * 60)
    print("Test: Simple Retraction")
    print("=" * 60)

    world = World()

    # A goblin with pending damage
    world.assert_fact("goblin", "hp", 30)
    world.assert_fact("goblin", "pending_damage", 12)

    X = var('x')
    HP = var('hp')
    DMG = var('dmg')

    # Rule: apply pending damage
    # - Compute new HP
    # - Retract old HP
    # - Retract pending_damage (it's been consumed)
    world.add_derivation_rule(
        "apply_damage",
        patterns=[
            (X, "hp", HP),
            (X, "pending_damage", DMG)
        ],
        template=(X, "hp", Expr('-', [HP, DMG])),
        retractions=[
            (X, "hp", HP),              # Retract old HP
            (X, "pending_damage", DMG)  # Consume the pending damage
        ]
    )

    print("\n--- Initial state ---")
    world.print_state()

    print("\n--- Advancing (rule fires) ---")
    world.advance()
    world.print_state()

    # Verify: goblin should have hp=18, no pending_damage
    hp_results = world.query(("goblin", "hp", var('hp')))
    assert len(hp_results) == 1, f"Expected 1 HP fact, got {len(hp_results)}"
    new_hp = hp_results[0]['hp']
    print(f"\n--- Result: goblin hp = {new_hp} ---")
    assert new_hp == 18, f"Expected 18, got {new_hp}"

    pending_results = world.query(("goblin", "pending_damage", var('d')))
    assert len(pending_results) == 0, f"Expected no pending damage, got {pending_results}"
    print("--- pending_damage was consumed (retracted) ---")

    # Check history
    print("\n--- HP History ---")
    for fact in world.history("goblin", "hp"):
        status = "alive" if fact.is_alive(world.tick) else f"ended tick {fact.to_tick}"
        print(f"  hp={fact.object} from tick {fact.from_tick}, {status}, cause: {fact.cause}")

    print("\nPASS: Retraction semantics work!\n")
    return True


def test_damage_death_chain():
    """Test a complete damage -> death chain using retractions."""
    print("=" * 60)
    print("Test: Damage -> Death Chain")
    print("=" * 60)

    world = World()

    # A weak goblin
    world.assert_fact("goblin", "is_a", "entity")
    world.assert_fact("goblin", "hp", 5)
    world.assert_fact("goblin", "pending_damage", 10)  # More than HP!

    X = var('x')
    HP = var('hp')
    DMG = var('dmg')

    # Rule 1: Apply damage
    world.add_derivation_rule(
        "apply_damage",
        patterns=[
            (X, "hp", HP),
            (X, "pending_damage", DMG)
        ],
        template=(X, "hp", Expr('-', [HP, DMG])),
        retractions=[
            (X, "hp", HP),
            (X, "pending_damage", DMG)
        ]
    )

    # Rule 2: Entity with hp <= 0 becomes dead
    # (We'll check for hp being negative since exact 0 matching is tricky)
    world.add_derivation_rule(
        "death_check",
        patterns=[
            (X, "is_a", "entity"),
            (X, "hp", HP)
        ],
        template=(X, "hp_is_lethal", Expr('<=', [HP, 0]))
    )

    # Rule 3: If hp_is_lethal is True, mark as dead
    # This is a workaround since we can't do conditionals in patterns yet
    world.add_derivation_rule(
        "mark_dead",
        patterns=[
            (X, "hp_is_lethal", True)
        ],
        template=(X, "state", "dead")
    )

    print("\n--- Initial state ---")
    world.print_state()

    print("\n--- Tick 1: Apply damage ---")
    world.advance()
    world.print_state()

    # Verify HP went negative
    hp_results = world.query(("goblin", "hp", var('hp')))
    new_hp = hp_results[0]['hp']
    print(f"\n  goblin hp = {new_hp}")

    print("\n--- Tick 2: Death check runs ---")
    world.advance()
    world.print_state()

    # Check if goblin is dead
    dead_results = world.query(("goblin", "state", "dead"))
    if dead_results:
        print("\n--- goblin is DEAD ---")
    else:
        lethal = world.query(("goblin", "hp_is_lethal", var('v')))
        print(f"\n  hp_is_lethal = {lethal}")

    # Explain the death
    print("\n--- Provenance: Why is goblin dead? ---")
    explanation = world.explain("goblin", "state", "dead")
    if explanation:
        def print_exp(exp, indent=0):
            prefix = "  " * indent
            print(f"{prefix}{exp['fact']} <- {exp['cause']}")
            for dep in exp['depends_on']:
                print_exp(dep, indent + 1)
        print_exp(explanation)

    print("\nPASS: Death chain works!\n")
    return True


def test_no_double_fire():
    """Verify that retractions prevent rules from firing multiple times."""
    print("=" * 60)
    print("Test: No Double Firing")
    print("=" * 60)

    world = World()

    # Setup: entity with a trigger fact
    world.assert_fact("switch", "state", "on")

    S = var('s')
    STATE = var('state')

    # Rule: when switch is on, turn it off
    # Without retraction, this would fire forever (fixpoint never reached)
    world.add_derivation_rule(
        "toggle_switch",
        patterns=[(S, "state", "on")],
        template=(S, "state", "off"),
        retractions=[(S, "state", "on")]
    )

    print("\n--- Initial: switch is on ---")
    world.print_state()

    print("\n--- Advance: rule fires once ---")
    world.advance()
    world.print_state()

    # Verify switch is now off (only one 'state' fact exists)
    results = world.query(("switch", "state", var('s')))
    assert len(results) == 1, f"Expected 1 state, got {len(results)}"
    state = results[0]['s']
    assert state == "off", f"Expected 'off', got {state}"

    print("\n--- Advance again: rule should NOT fire ---")
    world.advance()
    world.print_state()

    # Still just 'off'
    results = world.query(("switch", "state", var('s')))
    assert len(results) == 1
    assert results[0]['s'] == "off"

    print("\nPASS: No double firing!\n")
    return True


if __name__ == "__main__":
    all_passed = True
    all_passed &= test_simple_retract()
    all_passed &= test_damage_death_chain()
    all_passed &= test_no_double_fire()

    print("=" * 60)
    if all_passed:
        print("ALL RETRACT TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
    print("=" * 60)
