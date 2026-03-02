"""
Run the guards demo and show results.

This demonstrates:
1. (not= ?a ?b) guards for preventing self-matches
2. (> ?hp 0) guards for alive-only rules
3. (<= ?hp 0) guards for dead checks
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from herb_lang import load_herb_file, compile_program
from herb_core import var


def main():
    print("=" * 60)
    print("HERB Guards Demo")
    print("=" * 60)

    # Load and compile
    program = load_herb_file(os.path.join(os.path.dirname(__file__), "guards_demo.herb"))
    world = compile_program(program)

    print(f"\nLoaded {len(program.facts)} facts and {len(program.rules)} rules")

    # Show rules with guards
    print("\n--- Rules ---")
    for rule in program.rules:
        guard_str = f" IF {rule.guard}" if rule.guard else ""
        print(f"  {rule.name}: {len(rule.when_patterns)} patterns{guard_str}")

    # Initial state
    print("\n--- Initial State ---")
    for r in world.query((var('e'), "hp", var('hp'))):
        print(f"  {r['e']} hp {r['hp']}")

    # Advance to run derivation
    print("\n--- Advancing (derivation runs) ---")
    world.advance()

    # Show visibility results
    print("\n--- Visibility (same location, different entity) ---")
    sees = world.query((var('a'), "sees", var('b')))
    for r in sorted(sees, key=lambda x: (x['a'], x['b'])):
        print(f"  {r['a']} sees {r['b']}")

    # Show combat results
    print("\n--- Combat Engagement (living players vs monsters) ---")
    combat = world.query((var('p'), "in_combat_with", var('m')))
    if combat:
        for r in sorted(combat, key=lambda x: x['p']):
            print(f"  {r['p']} in_combat_with {r['m']}")
    else:
        print("  (no combat)")

    # Show status results
    print("\n--- Status (alive if hp > 0, dead if hp <= 0) ---")
    status = world.query((var('e'), "status", var('s')))
    for r in sorted(status, key=lambda x: (x['s'], x['e'])):
        print(f"  {r['e']}: {r['s']}")

    # Key insights
    print("\n--- Key Results ---")
    print("  * alice sees bob and goblin (same location, different entities)")
    print("  * bob sees alice and goblin (visibility works even when dead)")
    print("  * alice in_combat_with goblin (alice is alive, hp=100)")
    print("  * bob NOT in_combat_with goblin (bob is dead, hp=0)")
    print("  * carol NOT in combat (different location)")
    print("  * Guards filter bindings AFTER pattern matching")

    print("\n" + "=" * 60)
    print("Demo complete!")
    print("=" * 60)


if __name__ == "__main__":
    main()
