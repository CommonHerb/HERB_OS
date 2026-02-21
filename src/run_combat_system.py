"""
Common Herb Combat System Test

This is the first real port of Common Herb game logic to HERB.
Running this reveals what works and what's awkward.
"""

from herb_lang import load_herb_file, compile_program
from herb_core import var

def main():
    print("=" * 70)
    print("Common Herb Combat System - HERB Port Test")
    print("=" * 70)

    # Load and compile
    program = load_herb_file("common_herb_combat.herb")
    world = compile_program(program)

    X, Y = var('x'), var('y')

    # Categorize rules
    base_rules = [r for r in world._derivation_rules if not r.is_phase2()]
    phase2_rules = [r for r in world._derivation_rules if r.is_phase2()]

    print(f"\nLoaded: {len(world)} facts, {len(world._derivation_rules)} rules")
    print(f"Base rules ({len(base_rules)}): {[r.name for r in base_rules]}")
    print(f"Phase 2 rules ({len(phase2_rules)}): {[r.name for r in phase2_rules]}")

    # === INITIAL STATE ===
    print("\n" + "=" * 70)
    print("INITIAL STATE (tick 0)")
    print("=" * 70)

    print("\nCombatants:")
    for entity in ['hero', 'goblin', 'wolf', 'skeleton']:
        hp = world.query((entity, "hp", X))
        loc = world.query((entity, "location", X))
        dead = world.query((entity, "is_dead", X))
        hp_val = hp[0]['x'] if hp else "?"
        loc_val = loc[0]['x'] if loc else "?"
        dead_val = dead[0]['x'] if dead else False
        status = "DEAD" if dead_val else "alive"
        print(f"  {entity}: HP={hp_val}, location={loc_val}, {status}")

    print("\nHero equipment:")
    equipped = world.query(("hero", "equipped", X))
    for e in equipped:
        item = e['x']
        atk = world.query((item, "attack_bonus", Y))
        defe = world.query((item, "defense_bonus", Y))
        if atk:
            print(f"  {item}: +{atk[0]['y']} attack")
        if defe:
            print(f"  {item}: +{defe[0]['y']} defense")

    # === RUN COMBAT TICK ===
    print("\n" + "=" * 70)
    print("RUNNING COMBAT TICK (advance)")
    print("=" * 70)

    world.advance()

    # === RESULTS ===
    print("\n--- Equipment Bonuses (Phase 2 aggregates) ---")
    for stat in ['total_attack_bonus', 'total_defense_bonus', 'effective_attack', 'effective_defense']:
        hero_stat = world.query(("hero", stat, X))
        if hero_stat:
            print(f"  hero {stat}: {hero_stat[0]['x']}")

    print("\n--- Who is alive? ---")
    alive = world.query((X, "is_alive", True))
    for a in alive:
        print(f"  {a['x']} is alive")

    print("\n--- Combat Targeting ---")
    targets = world.query((X, "can_target", Y))
    for t in targets:
        print(f"  {t['x']} can target {t['y']}")

    print("\n--- Damage Applied ---")
    for entity in ['hero', 'goblin', 'wolf', 'skeleton']:
        hp = world.query((entity, "hp", X))
        if hp:
            print(f"  {entity} HP: {hp[0]['x']}")

    print("\n--- Deaths ---")
    dead = world.query((X, "is_dead", True))
    for d in dead:
        print(f"  {d['x']} is dead")

    print("\n--- Loot ---")
    hero_gold = world.query(("hero", "gold", X))
    if hero_gold:
        print(f"  hero gold: {hero_gold[0]['x']}")

    # === OBSERVATIONS ===
    print("\n" + "=" * 70)
    print("OBSERVATIONS")
    print("=" * 70)

    print("""
    Issues found during this port:

    1. RETRACT VERBOSITY
       Every HP update requires explicit RETRACT. The apply_damage rule:
         THEN ?e hp (- ?old_hp ?dmg)
         RETRACT ?e hp ?old_hp
         RETRACT ?e pending_damage ?dmg
       This is 3 lines where JavaScript would be: entity.hp -= dmg

    2. NEGATION STRATIFICATION
       Can't use (not-exists ?e is_dead true) in base rules because
       negation is Phase 2. Had to use positive is_alive tracking instead.
       This works but feels backwards.

    3. MULTIPLE PENDING DAMAGES
       If hero is targeted by both goblin AND wolf, there are TWO
       pending_damage facts. The rule fires twice, but second time
       the old_hp doesn't match. This might cause issues.

    4. TIMING / ORDERING
       All rules fire in one tick. In the real game, damage calculation
       and application are separate phases. HERB's fixpoint-to-completion
       might not match the JavaScript tick model.

    5. LOOT DOUBLE-FIRE
       The loot_drop rule will fire for every (dead monster, player)
       pair that matches. If two players are present, both get loot.
       Need to track "loot claimed" somehow.

    What's BETTER in HERB:
    - Equipment bonuses via aggregation are cleaner than JavaScript loops
    - Provenance tracking means we can explain WHY damage happened
    - Rules are declarative - intent is clear
    """)

    # Show provenance for one damage
    print("\n--- Provenance: Why is goblin's HP what it is? ---")
    goblin_hp = world.query(("goblin", "hp", X))
    if goblin_hp:
        explanation = world.explain("goblin", "hp", goblin_hp[0]['x'])
        if explanation:
            def show_explanation(exp, indent=0):
                print("  " * indent + exp['fact'])
                print("  " * indent + f"  <- {exp['cause']}")
                for dep in exp.get('depends_on', []):
                    show_explanation(dep, indent + 1)
            show_explanation(explanation)


if __name__ == "__main__":
    main()
