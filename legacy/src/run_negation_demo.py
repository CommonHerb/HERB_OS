"""
HERB Negation Demo Runner

Demonstrates not-exists for absence checks in game logic:
- Tax exemptions
- Faction hostility
- Default NPC behavior
"""

from herb_lang import load_herb_file, compile_program
from herb_core import var

def main():
    print("=" * 60)
    print("HERB Negation Demo - Absence Checks")
    print("=" * 60)

    # Load and compile
    program = load_herb_file("negation_demo.herb")
    world = compile_program(program)

    # Count rules by phase
    base_rules = [r for r in world._derivation_rules if not r.is_phase2()]
    phase2_rules = [r for r in world._derivation_rules if r.is_phase2()]

    print(f"\nLoaded: {len(world)} facts, {len(world._derivation_rules)} rules")
    print(f"Phase 1 (base) rules: {[r.name for r in base_rules]}")
    print(f"Phase 2 (negation) rules: {[r.name for r in phase2_rules]}")

    print("\n--- Before derivation ---")
    X = var('x')
    Y = var('y')

    # Run derivation
    print("\n--- Running stratified derivation ---")
    world.advance()

    # === Tax Results ===
    print("\n--- Tax Results (not-exists exemption) ---")

    tax_facts = world.query((X, "owes_tax", Y))
    if tax_facts:
        for f in tax_facts:
            print(f"  {f['x']} owes tax: {f['y']}")
    else:
        print("  No one owes tax")

    # Check exemptions
    print("\n  Exemptions:")
    for player in ['alice', 'bob', 'charlie']:
        exemption = world.query((player, "exemption", X))
        if exemption:
            print(f"    {player}: has exemption for {exemption[0]['x']}")
        else:
            print(f"    {player}: no exemption")

    # === Guard Hostility ===
    print("\n--- Guard Hostility (not-exists allied_with) ---")

    hostile_facts = world.query((X, "hostile_to", Y))
    if hostile_facts:
        for f in hostile_facts:
            print(f"  {f['x']} is hostile to {f['y']}")
    else:
        print("  No guards hostile to anyone")

    # Check alliances
    print("\n  Alliances:")
    for player in ['alice', 'bob', 'charlie']:
        alliance = world.query((player, "allied_with", X))
        if alliance:
            print(f"    {player}: allied with {alliance[0]['x']}")
        else:
            print(f"    {player}: no alliance")

    # === NPC Behavior ===
    print("\n--- NPC Behavior (not-exists has_quest) ---")

    behavior_facts = world.query((X, "behavior", Y))
    for f in behavior_facts:
        print(f"  {f['x']}: {f['y']}")

    # === Summary ===
    print("\n--- Summary ---")
    print("  * alice: has exemption -> NOT taxed")
    print("  * bob: no exemption -> taxed (15)")
    print("  * charlie: no exemption but no rule matches (wrong loc? check)")
    print("  * alice: allied with royal -> guards NOT hostile")
    print("  * bob: not allied -> guards ARE hostile")
    print("  * charlie: allied with royal -> guards NOT hostile")
    print("  * merchant: no quest -> idle")
    print("  * questgiver: has quest -> quest_ready")

    print("\n" + "=" * 60)
    print("Demo complete!")
    print("=" * 60)


if __name__ == "__main__":
    main()
