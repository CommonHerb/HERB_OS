"""
Combat Aggregate Demo — Phase 2 → Phase 3 Pattern

Demonstrates the key unlock from Session 6:
- Phase 2: Calculate total damage using aggregates (sum of bonuses)
- Phase 3: Apply damage to HP using RETRACT

This was impossible before Phase 3 because aggregate rules couldn't have RETRACT.
"""

from herb_lang import run_herb_file
from herb_core import Var

def main():
    print("=" * 70)
    print("HERB Combat with Aggregate Damage Calculation")
    print("=" * 70)

    # Load and compile the demo
    world = run_herb_file("combat_aggregate_demo.herb")

    # Show rule stratification (N-phase)
    strata = world._stratify_rules()
    print("\n--- Rule Stratification ---")
    for i, stratum_rules in enumerate(strata):
        print(f"Stratum {i}: {[r.name for r in stratum_rules]}")

    # Show initial state
    print("\n--- Initial State ---")
    X = Var('x')
    print(f"hero hp: {world.query(('hero', 'hp', X))}")
    print(f"hero attack_bonus: {world.query(('hero', 'attack_bonus', X))}")
    print(f"goblin hp: {world.query(('goblin', 'hp', X))}")
    print(f"goblin defense_bonus: {world.query(('goblin', 'defense_bonus', X))}")

    # Advance one tick - all phases run
    print("\n--- Advancing (Phase 1 -> 2 -> 3) ---")
    world.advance()

    # Show results
    print("\n--- After Single Advance ---")

    # Aggregates should be consumed
    total_atk = world.query(('hero', 'total_attack', X))
    total_def = world.query(('goblin', 'total_defense', X))
    pending = world.query(('goblin', 'pending_damage', X))

    print(f"total_attack: {total_atk} (consumed)")
    print(f"total_defense: {total_def} (consumed)")
    print(f"pending_damage: {pending} (consumed)")

    # HP should be updated
    hp = world.query(('goblin', 'hp', X))
    is_dead = world.query(('goblin', 'is_dead', X))

    print(f"\ngoblin hp: {hp}")
    print(f"goblin is_dead: {is_dead}")

    # Calculate expected values
    # attack: 15 + 5 + 3 = 23
    # defense: 5 + 2 = 7
    # damage: 23 - 7 = 16
    # hp: 40 - 16 = 24
    print("\n--- Calculation ---")
    print("  hero attack_bonus: 15 + 5 + 3 = 23")
    print("  goblin defense_bonus: 5 + 2 = 7")
    print("  net damage: 23 - 7 = 16")
    print("  goblin hp: 40 - 16 = 24")

    # Verify
    if len(hp) == 1 and hp[0]['x'] == 24:
        print("\nPASS: Damage applied correctly!")
    else:
        print(f"\nFAIL: Expected hp=24, got {hp}")

    # Show provenance
    print("\n--- Provenance: Why is goblin hp 24? ---")
    explanation = world.explain('goblin', 'hp', 24)
    if explanation:
        def print_exp(exp, indent=0):
            prefix = "  " * indent
            print(f"{prefix}{exp['fact']}")
            print(f"{prefix}  cause: {exp['cause']}")
            for dep in exp.get('depends_on', []):
                print_exp(dep, indent + 1)
        print_exp(explanation)

    print("\n" + "=" * 70)
    print("COMBAT AGGREGATE DEMO COMPLETE")
    print("=" * 70)


if __name__ == "__main__":
    main()
