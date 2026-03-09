"""
Run the equipment demo and show aggregation results.
"""

from herb_lang import load_herb_file, compile_program
from herb_core import var


def main():
    print("=" * 60)
    print("HERB Equipment System Demo - Stratified Aggregation")
    print("=" * 60)

    # Load and compile
    program = load_herb_file("equipment_demo.herb")
    print(f"\nLoaded: {len(program.facts)} facts, {len(program.rules)} rules")

    world = compile_program(program)

    # Show rule classification
    base_rules = [r for r in world._derivation_rules if not r.is_aggregate()]
    agg_rules = [r for r in world._derivation_rules if r.is_aggregate()]

    print(f"\nPhase 1 (base) rules: {[r.name for r in base_rules]}")
    print(f"Phase 2 (aggregate) rules: {[r.name for r in agg_rules]}")

    # Before advance
    print("\n--- Before derivation ---")
    X, B = var('x'), var('b')
    print("  Equipped items:", [b['item'] for b in world.query(("hero", "equipped", var('item')))])

    # Advance (runs derivation)
    print("\n--- Running stratified derivation ---")
    world.advance()

    # Show intermediate facts (Phase 1 results)
    print("\n--- Phase 1 results (individual bonuses) ---")
    attack_bonuses = world.query(("hero", "has_attack_bonus", B))
    defense_bonuses = world.query(("hero", "has_defense_bonus", B))
    weights = world.query(("hero", "carries_weight", B))

    print(f"  Attack bonuses: {[b['b'] for b in attack_bonuses]}")
    print(f"  Defense bonuses: {[b['b'] for b in defense_bonuses]}")
    print(f"  Carry weights: {[b['b'] for b in weights]}")

    # Show aggregate results (Phase 2 results)
    print("\n--- Phase 2 results (aggregates) ---")
    total_attack = world.query(("hero", "total_attack", B))
    total_defense = world.query(("hero", "total_defense", B))
    total_weight = world.query(("hero", "total_carry_weight", B))
    item_count = world.query(("hero", "equipped_items", B))

    print(f"  Total attack: {total_attack[0]['b'] if total_attack else 'N/A'}")
    print(f"  Total defense: {total_defense[0]['b'] if total_defense else 'N/A'}")
    print(f"  Total carry weight: {total_weight[0]['b'] if total_weight else 'N/A'}")
    print(f"  Equipped items: {item_count[0]['b'] if item_count else 'N/A'}")

    # Verify calculations
    print("\n--- Verification ---")
    # Hero has: iron_sword (atk+5, w=3), leather_armor (def+3, w=4), ring_of_power (atk+2, def+1, w=0)
    # Base attack: 10
    # Attack bonuses: 5 + 2 = 7
    # Total attack: 10 + 7 = 17
    # Defense bonuses: 3 + 1 = 4
    # Weights: 3 + 4 + 0 = 7
    # Items: 3

    expected_attack = 17  # 10 base + 5 + 2
    expected_defense = 4  # 3 + 1
    expected_weight = 7  # 3 + 4 + 0
    expected_items = 3

    actual_attack = total_attack[0]['b'] if total_attack else None
    actual_defense = total_defense[0]['b'] if total_defense else None
    actual_weight = total_weight[0]['b'] if total_weight else None
    actual_items = item_count[0]['b'] if item_count else None

    all_pass = True

    if actual_attack == expected_attack:
        print(f"  PASS: Total attack = {actual_attack}")
    else:
        print(f"  FAIL: Total attack: expected {expected_attack}, got {actual_attack}")
        all_pass = False

    if actual_defense == expected_defense:
        print(f"  PASS: Total defense = {actual_defense}")
    else:
        print(f"  FAIL: Total defense: expected {expected_defense}, got {actual_defense}")
        all_pass = False

    if actual_weight == expected_weight:
        print(f"  PASS: Total weight = {actual_weight}")
    else:
        print(f"  FAIL: Total weight: expected {expected_weight}, got {actual_weight}")
        all_pass = False

    if actual_items == expected_items:
        print(f"  PASS: Equipped items = {actual_items}")
    else:
        print(f"  FAIL: Equipped items: expected {expected_items}, got {actual_items}")
        all_pass = False

    # Provenance
    print("\n--- Provenance: Why is total_attack 17? ---")
    explanation = world.explain("hero", "total_attack", 17)
    if explanation:
        def print_exp(exp, indent=0):
            prefix = "  " * indent
            print(f"{prefix}{exp['fact']}")
            if exp['cause'] != 'asserted':
                print(f"{prefix}  <- {exp['cause']}")
            for dep in exp['depends_on']:
                print_exp(dep, indent + 1)
        print_exp(explanation)

    print("\n" + "=" * 60)
    if all_pass:
        print("DEMO PASSED - Stratified aggregation works correctly!")
    else:
        print("DEMO FAILED - Some calculations were wrong")
    print("=" * 60)


if __name__ == "__main__":
    main()
