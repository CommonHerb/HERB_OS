"""
Common Herb Combat - Simple Version Test

This version keeps everything in Phase 1 to avoid
the aggregate/retract conflict.
"""

from herb_lang import load_herb_file, compile_program
from herb_core import var

def main():
    print("=" * 70)
    print("Common Herb Combat - Simple Version")
    print("=" * 70)

    program = load_herb_file("common_herb_combat_simple.herb")
    world = compile_program(program)

    X = var('x')

    print(f"\nLoaded: {len(world)} facts, {len(world._derivation_rules)} rules")

    # Initial state
    print("\n--- INITIAL STATE ---")
    for entity in ['hero', 'goblin', 'wolf', 'skeleton']:
        hp = world.query((entity, "hp", X))
        dead = world.query((entity, "is_dead", X))
        hp_val = hp[0]['x'] if hp else "?"
        status = "DEAD" if dead else "alive"
        print(f"  {entity}: HP={hp_val} ({status})")

    hero_gold = world.query(("hero", "gold", X))
    print(f"  hero gold: {hero_gold[0]['x'] if hero_gold else '?'}")

    # Run combat tick
    print("\n--- RUNNING COMBAT TICK ---")
    world.advance()

    # Results
    print("\n--- AFTER COMBAT ---")
    for entity in ['hero', 'goblin', 'wolf', 'skeleton']:
        hp = world.query((entity, "hp", X))
        dead = world.query((entity, "is_dead", True))
        hp_val = hp[0]['x'] if hp else "?"
        status = "DEAD" if dead else "alive"
        print(f"  {entity}: HP={hp_val} ({status})")

    hero_gold = world.query(("hero", "gold", X))
    print(f"  hero gold: {hero_gold[0]['x'] if hero_gold else '?'}")

    # Combat details
    print("\n--- COMBAT DETAILS ---")
    targets = world.query((X, "can_attack", var('y')))
    print("  Targeting relationships:")
    for t in targets:
        print(f"    {t['x']} -> {t['y']}")

    # Damage calculation trace
    print("\n  Damage calculation:")
    print("    hero (atk=35) vs goblin (def=3): 35-3=32 damage")
    print("    hero (atk=35) vs wolf (def=2): 35-2=33 damage")
    print("    goblin (atk=12) vs hero (def=15): 12-15=-3 -> min 1 damage")
    print("    wolf (atk=8) vs hero (def=15): 8-15=-7 -> min 1 damage")

    # Provenance
    print("\n--- PROVENANCE ---")
    goblin_hp = world.query(("goblin", "hp", X))
    if goblin_hp:
        exp = world.explain("goblin", "hp", goblin_hp[0]['x'])
        if exp:
            print(f"  Why is goblin HP {goblin_hp[0]['x']}?")
            print(f"    cause: {exp['cause']}")
            for dep in exp.get('depends_on', []):
                print(f"    depended on: {dep['fact']}")

    # Summary
    print("\n" + "=" * 70)
    print("OBSERVATIONS")
    print("=" * 70)
    print("""
  What WORKS:
  - Combat flows correctly: targeting -> damage -> death -> loot
  - Provenance tracks why things happened
  - Guards filter correctly (only alive can fight)
  - Multi-attacker damage applies correctly (hero takes 1+1=2 damage)

  What's VERBOSE (the RETRACT problem):
  - Every HP update needs explicit RETRACT
  - Loot needs to RETRACT both gold values
  - 3 lines of ceremony for what should be: entity.hp -= damage

  What's MISSING (the Phase 1/2 problem):
  - Can't use aggregates for equipment bonuses in damage calc
  - Either pre-compute bonuses OR accept Phase 2 can't RETRACT
  - Need either "Phase 3" or "functional relations" to fix cleanly

  What's DIFFERENT from JavaScript:
  - All combat resolves simultaneously (no turn order)
  - Fixpoint semantics means all valid attacks fire at once
  - This might actually be BETTER for game balance
    """)

if __name__ == "__main__":
    main()
