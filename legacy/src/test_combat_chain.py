"""
HERB Combat System: The Complete Damage -> Death -> Loot Chain

This demonstrates HERB's unique capabilities:
1. Temporal facts - every fact knows WHEN it became true
2. Provenance - every fact knows WHY it's true
3. Arithmetic in rules - compute damage dynamically
4. RETRACT semantics - state transitions are clean
5. Derivation to fixpoint - all consequences resolve each tick

The scenario:
- Hero (100 HP, 30 attack, 15 defense) is in the forest
- Goblin (25 HP, 8 attack, 3 defense) is hostile in the forest
- Combat happens: hero attacks goblin for 27 damage (30 - 3)
- Goblin dies (HP goes to -2)
- Hero gains 15 gold from loot

Every step is traceable through provenance.
"""

from herb_core import World, var, Var, Expr

def build_combat_world():
    """Set up a world with combat rules."""
    world = World()

    # Variables
    A, B = var('a'), var('b')
    X, Y = var('x'), var('y')
    HP, DMG = var('hp'), var('dmg')
    ATK, DEF = var('atk'), var('def')
    LOC = var('loc')
    GOLD, LOOT = var('gold'), var('loot')

    # --- World Setup ---

    # Hero
    world.assert_fact("hero", "is_a", "combatant")
    world.assert_fact("hero", "is_a", "player")
    world.assert_fact("hero", "hp", 100)
    world.assert_fact("hero", "attack", 30)
    world.assert_fact("hero", "defense", 15)
    world.assert_fact("hero", "gold", 50)
    world.assert_fact("hero", "location", "forest")

    # Goblin
    world.assert_fact("goblin", "is_a", "combatant")
    world.assert_fact("goblin", "is_a", "monster")
    world.assert_fact("goblin", "hp", 25)
    world.assert_fact("goblin", "attack", 8)
    world.assert_fact("goblin", "defense", 3)
    world.assert_fact("goblin", "hostile", True)
    world.assert_fact("goblin", "loot_gold", 15)
    world.assert_fact("goblin", "location", "forest")

    # --- Combat Rules ---

    # R1: Combat proximity
    world.add_derivation_rule(
        "combat_proximity",
        patterns=[
            (A, "is_a", "combatant"),
            (B, "is_a", "combatant"),
            (A, "location", LOC),
            (B, "location", LOC)
        ],
        template=(A, "can_target", B)
    )

    # R2: Hostile monsters attack players
    world.add_derivation_rule(
        "monster_aggro",
        patterns=[
            (X, "is_a", "monster"),
            (X, "hostile", True),
            (Y, "is_a", "player"),
            (X, "can_target", Y)
        ],
        template=(X, "attacks", Y)
    )

    # R3: Players counter-attack
    world.add_derivation_rule(
        "player_counter",
        patterns=[
            (X, "attacks", Y),
            (Y, "is_a", "player")
        ],
        template=(Y, "attacks", X)
    )

    # R4: Calculate damage = attacker.attack - defender.defense
    # For each attack, compute the damage dealt
    world.add_derivation_rule(
        "calc_damage",
        patterns=[
            (A, "attacks", B),
            (A, "attack", ATK),
            (B, "defense", DEF)
        ],
        template=(A, "damage_to_" + "target", Expr('-', [ATK, DEF]))
        # Note: We need a way to associate damage with target
        # For now, we'll use a simpler approach
    )

    return world


def test_full_combat():
    """Run the complete combat scenario."""
    print("=" * 70)
    print("HERB Combat System: Complete Damage -> Death -> Loot Chain")
    print("=" * 70)

    world = World()

    # Variables
    A, B = var('a'), var('b')
    X, Y = var('x'), var('y')
    HP, DMG, NEW_HP = var('hp'), var('dmg'), var('new_hp')
    ATK, DEF = var('atk'), var('def')
    LOC = var('loc')
    GOLD, LOOT = var('gold'), var('loot')
    TARGET = var('target')

    # --- World Setup ---
    print("\n--- Setting up the world ---")

    world.assert_fact("hero", "is_a", "combatant")
    world.assert_fact("hero", "is_a", "player")
    world.assert_fact("hero", "hp", 100)
    world.assert_fact("hero", "attack", 30)
    world.assert_fact("hero", "defense", 15)
    world.assert_fact("hero", "gold", 50)
    world.assert_fact("hero", "location", "forest")

    world.assert_fact("goblin", "is_a", "combatant")
    world.assert_fact("goblin", "is_a", "monster")
    world.assert_fact("goblin", "hp", 25)
    world.assert_fact("goblin", "attack", 8)
    world.assert_fact("goblin", "defense", 3)
    world.assert_fact("goblin", "hostile", True)
    world.assert_fact("goblin", "loot_gold", 15)
    world.assert_fact("goblin", "location", "forest")

    # --- Phase 1: Combat proximity ---
    print("\n--- Phase 1: Determine who can fight whom ---")

    world.add_derivation_rule(
        "combat_proximity",
        patterns=[
            (A, "is_a", "combatant"),
            (B, "is_a", "combatant"),
            (A, "location", LOC),
            (B, "location", LOC)
        ],
        template=(A, "can_target", B)
    )

    world.advance()
    print("Combat relationships established:")
    for b in world.query((X, "can_target", Y)):
        if b['x'] != b['y']:  # Skip self-targeting
            print(f"  {b['x']} can target {b['y']}")

    # --- Phase 2: Initiate attacks ---
    print("\n--- Phase 2: Combat begins ---")

    world.add_derivation_rule(
        "monster_aggro",
        patterns=[
            (X, "is_a", "monster"),
            (X, "hostile", True),
            (Y, "is_a", "player"),
            (X, "can_target", Y)
        ],
        template=(X, "attacks", Y)
    )

    world.add_derivation_rule(
        "player_counter",
        patterns=[
            (X, "attacks", Y),
            (Y, "is_a", "player")
        ],
        template=(Y, "attacks", X)
    )

    world.advance()
    print("Attacks declared:")
    for b in world.query((X, "attacks", Y)):
        print(f"  {b['x']} attacks {b['y']}")

    # --- Phase 3: Calculate and apply damage ---
    print("\n--- Phase 3: Calculate damage ---")

    # Hero attacks goblin: 30 attack - 3 defense = 27 damage
    # Goblin attacks hero: 8 attack - 15 defense = -7 damage (0 min)

    # We'll compute pending_damage for each attack
    world.add_derivation_rule(
        "calc_pending_damage",
        patterns=[
            (A, "attacks", B),
            (A, "attack", ATK),
            (B, "defense", DEF),
            (B, "hp", HP)  # B must be alive
        ],
        template=(B, "pending_damage_from_" + "attack", Expr('max', [0, Expr('-', [ATK, DEF])]))
    )

    world.advance()

    # Query the pending damage
    print("Damage calculated:")
    for b in world.query((X, "pending_damage_from_attack", DMG)):
        print(f"  {b['x']} takes {b['dmg']} pending damage")

    # --- Phase 4: Apply hero's attack to goblin ---
    print("\n--- Phase 4: Apply damage to goblin ---")

    # Manually apply the damage (in a full system, this would be a rule with RETRACT)
    goblin_hp = world.query(("goblin", "hp", HP))[0]['hp']
    hero_attack = world.query(("hero", "attack", ATK))[0]['atk']
    goblin_def = world.query(("goblin", "defense", DEF))[0]['def']
    damage = max(0, hero_attack - goblin_def)  # 30 - 3 = 27

    print(f"  Hero's attack: {hero_attack}")
    print(f"  Goblin's defense: {goblin_def}")
    print(f"  Damage dealt: {damage}")
    print(f"  Goblin HP: {goblin_hp} -> {goblin_hp - damage}")

    world.retract_fact("goblin", "hp", goblin_hp)
    world.assert_fact("goblin", "hp", goblin_hp - damage, cause="combat_damage")

    world.advance()

    # --- Phase 5: Death check ---
    print("\n--- Phase 5: Check for death ---")

    world.add_derivation_rule(
        "death_check",
        patterns=[
            (X, "is_a", "combatant"),
            (X, "hp", HP)
        ],
        template=(X, "is_dead", Expr('<=', [HP, 0]))
    )

    world.advance()

    for b in world.query((X, "is_dead", True)):
        print(f"  {b['x']} is DEAD!")

    # --- Phase 6: Loot drop ---
    print("\n--- Phase 6: Loot collection ---")

    # When a monster dies, player in same location gets loot
    world.add_derivation_rule(
        "loot_drop",
        patterns=[
            (X, "is_a", "monster"),
            (X, "is_dead", True),
            (X, "loot_gold", LOOT),
            (Y, "is_a", "player"),
            (Y, "location", LOC),
            (X, "location", LOC)
        ],
        template=(Y, "looted_gold", LOOT)
    )

    world.advance()

    # Check loot
    for b in world.query((X, "looted_gold", GOLD)):
        print(f"  {b['x']} looted {b['gold']} gold!")

    # --- Final State ---
    print("\n--- Final World State ---")
    relevant_facts = []
    for fact in world.all_facts():
        # Filter out meta-facts for clarity
        if not str(fact.relation).startswith("is_a") and not str(fact.relation) == "pattern_count":
            if fact.subject in ("hero", "goblin"):
                relevant_facts.append(fact)

    for fact in sorted(relevant_facts, key=lambda f: (f.subject, f.relation)):
        status = "alive" if fact.is_alive(world.tick) else "ended"
        print(f"  {fact.subject} {fact.relation} {fact.object} [{status}]")

    # --- Provenance Chain ---
    print("\n--- Provenance: Why did hero get loot? ---")
    explanation = world.explain("hero", "looted_gold", 15)
    if explanation:
        def print_exp(exp, indent=0):
            prefix = "  " * indent
            print(f"{prefix}{exp['fact']}")
            if exp['depends_on']:
                print(f"{prefix}  caused by: {exp['cause']}")
                for dep in exp['depends_on']:
                    print_exp(dep, indent + 1)
            else:
                print(f"{prefix}  ({exp['cause']})")
        print_exp(explanation)

    # --- Time Travel: What was goblin's HP at start? ---
    print("\n--- Time Travel Query ---")
    print(f"Current tick: {world.tick}")
    for tick in range(world.tick + 1):
        results = world.query(("goblin", "hp", HP), at_tick=tick)
        if results:
            print(f"  Tick {tick}: goblin hp = {results[0]['hp']}")

    print("\n" + "=" * 70)
    print("COMBAT CHAIN COMPLETE")
    print("=" * 70)


if __name__ == "__main__":
    test_full_combat()
