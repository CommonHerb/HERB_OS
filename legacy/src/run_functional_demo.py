"""
Functional Relations Demo Runner

Demonstrates how FUNCTIONAL declarations reduce RETRACT boilerplate.
"""

from herb_lang import run_herb_file
from herb_core import Var


def main():
    print("=" * 70)
    print("HERB Functional Relations Demo")
    print("=" * 70)

    world = run_herb_file("functional_demo.herb")

    # Show functional relations
    print("\n--- Functional Relations ---")
    func_rels = ["hp", "location", "gold", "pending_damage"]
    for rel in func_rels:
        is_func = world.is_functional(rel)
        print(f"  {rel}: {'FUNCTIONAL' if is_func else 'multi-valued'}")

    # Show rule stratification
    strata = world._stratify_rules()
    print("\n--- Rule Stratification ---")
    for i, stratum_rules in enumerate(strata):
        if stratum_rules:
            print(f"Stratum {i}: {[r.name for r in stratum_rules]}")

    # Show initial state
    print("\n--- Initial State ---")
    X = Var('x')
    print(f"hero hp: {world.query(('hero', 'hp', X))}")
    print(f"goblin hp: {world.query(('goblin', 'hp', X))}")
    print(f"hero attack_bonus: {world.query(('hero', 'attack_bonus', X))}")
    print(f"goblin defense_bonus: {world.query(('goblin', 'defense_bonus', X))}")

    # Advance
    print("\n--- Advancing (all strata) ---")
    world.advance()

    # Show results
    print("\n--- After Advance ---")
    hero_hp = world.query(('hero', 'hp', X))
    goblin_hp = world.query(('goblin', 'hp', X))
    is_dead = world.query(('goblin', 'is_dead', X))

    print(f"hero hp: {hero_hp}")
    print(f"goblin hp: {goblin_hp}")
    print(f"goblin is_dead: {is_dead}")

    # Verify single hp value (functional)
    if len(goblin_hp) == 1:
        print("\n--- Functional Relation Working ---")
        print("  goblin has exactly ONE hp value (functional auto-retract)")
        print(f"  hp = {goblin_hp[0]['x']} (40 - (23-7) = 24)")
    else:
        print(f"\nFAIL: Expected single hp, got {goblin_hp}")

    # Compare to non-functional
    bonuses = world.query(('hero', 'attack_bonus', X))
    print(f"\n  hero has {len(bonuses)} attack_bonus values (multi-valued)")

    print("\n" + "=" * 70)
    print("FUNCTIONAL DEMO COMPLETE")
    print("=" * 70)


if __name__ == "__main__":
    main()
