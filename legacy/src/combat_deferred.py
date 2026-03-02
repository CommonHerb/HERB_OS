"""
HERB Combat with Deferred Rules — The Right Way

Combat rules using =>> (deferred) semantics:
- attack => pending_damage (instant)
- pending_damage =>> hp update (deferred - after attack settles)
- hp =>> death check (deferred - after hp settles)
- death =>> loot drop (deferred - after death settles)

5 rules. No markers. No cleanup. Ordering emerges from the arrows.

Session 15 — February 4, 2026
"""

from herb_core import World, Var, Expr, NotExistsExpr

# Variables
X, Y, Z = Var('x'), Var('y'), Var('z')
E, P = Var('e'), Var('p')  # Entity, Player
DMG, HP, G = Var('dmg'), Var('hp'), Var('g')  # Damage, HP, Gold
LOC = Var('loc')


def bootstrap_combat_world() -> World:
    """
    Create a combat world using deferred rules.

    The key insight: =>> means "this conclusion happens in the next
    micro-iteration, not immediately." This creates causal ordering
    without marker facts.
    """
    world = World("combat")

    # Declare functional relations (single-valued)
    world.declare_functional("hp")
    world.declare_functional("location")
    world.declare_functional("is_alive")
    world.declare_functional("gold")

    # Ephemeral command: consumed after ALL bindings processed (area attack)
    world.declare_ephemeral("attack_cmd")

    # =========================================================================
    # WORLD STATE
    # =========================================================================

    # Player
    world.assert_fact("player", "is_a", "combatant")
    world.assert_fact("player", "is_a", "player")
    world.assert_fact("player", "hp", 100)
    world.assert_fact("player", "base_damage", 15)
    world.assert_fact("player", "location", "forest")
    world.assert_fact("player", "is_alive", True)
    world.assert_fact("player", "gold", 0)

    # Goblin (weak - will die in 2 hits)
    world.assert_fact("goblin", "is_a", "combatant")
    world.assert_fact("goblin", "is_a", "enemy")
    world.assert_fact("goblin", "hp", 25)  # Dies after 2 hits (25 - 15 - 15 = -5)
    world.assert_fact("goblin", "base_damage", 8)
    world.assert_fact("goblin", "location", "forest")
    world.assert_fact("goblin", "is_alive", True)
    world.assert_fact("goblin", "gold", 25)

    # Wolf (tougher - will die in 3 hits)
    world.assert_fact("wolf", "is_a", "combatant")
    world.assert_fact("wolf", "is_a", "enemy")
    world.assert_fact("wolf", "hp", 40)  # Dies after 3 hits (40 - 15 - 15 - 15 = -5)
    world.assert_fact("wolf", "base_damage", 5)
    world.assert_fact("wolf", "location", "forest")
    world.assert_fact("wolf", "is_alive", True)
    world.assert_fact("wolf", "gold", 10)

    # =========================================================================
    # COMBAT RULES — Using Deferred (=>>) Semantics
    # =========================================================================

    # RULE 1: Attack command creates pending damage (INSTANT)
    # When player attacks, calculate damage for all enemies in same location
    world.add_derivation_rule(
        "player_attacks",
        [("input", "attack_cmd", True),
         ("player", "location", LOC),
         ("player", "base_damage", DMG),
         (E, "is_a", "enemy"),
         (E, "location", LOC),
         (E, "is_alive", True)],
        (E, "pending_damage", DMG)
    )

    # RULE 2: Apply pending damage to HP (DEFERRED)
    # Runs after attack rule settles, updates HP
    world.add_derivation_rule(
        "apply_damage",
        [(E, "pending_damage", DMG),
         (E, "hp", HP),
         (E, "is_alive", True)],
        templates=[(E, "hp", Expr('-', [HP, DMG]))],
        retractions=[(E, "pending_damage", DMG)],
        deferred=True  # NEW: This rule's effects are deferred
    )

    # RULE 3: Check for death (DEFERRED)
    # Runs after HP update settles
    world.add_derivation_rule(
        "check_death",
        [(E, "hp", HP),
         (E, "is_alive", True)],
        (E, "is_alive", False),
        guard=Expr('<=', [HP, 0]),
        deferred=True
    )

    # RULE 4: Drop loot on death (DEFERRED)
    # Runs after death check settles
    world.add_derivation_rule(
        "drop_loot",
        [(E, "is_alive", False),
         (E, "gold", G),
         ("player", "gold", X)],
        templates=[("player", "gold", Expr('+', [X, G])),
                   ("output", "looted", E)],
        retractions=[(E, "gold", G)],
        guard=Expr('>', [G, 0]),
        deferred=True
    )

    # RULE 5: Enemies counterattack (DEFERRED)
    # Commented out for now to debug the basic chain
    # world.add_derivation_rule(
    #     "enemy_counterattack",
    #     [("input", "attack_cmd", True),
    #      (E, "is_a", "enemy"),
    #      (E, "location", LOC),
    #      (E, "is_alive", True),
    #      (E, "base_damage", DMG),
    #      ("player", "location", LOC)],
    #     ("player", "pending_damage", DMG),
    #     deferred=True
    # )

    return world


def print_combat_state(world: World, label: str = ""):
    """Print current combat state."""
    print(f"\n{'='*50}")
    if label:
        print(f"  {label}")
    print(f"  Tick: {world.tick}")
    print(f"{'='*50}")

    for entity in ["player", "goblin", "wolf"]:
        hp_results = world.query((entity, "hp", X))
        alive_results = world.query((entity, "is_alive", X))
        gold_results = world.query((entity, "gold", X))

        hp = hp_results[0]['x'] if hp_results else "?"
        alive = alive_results[0]['x'] if alive_results else "?"
        gold = gold_results[0]['x'] if gold_results else 0

        status = "ALIVE" if alive == True else "DEAD"
        print(f"  {entity:8} | HP: {hp:>4} | {status:5} | Gold: {gold}")

    # Show any pending damage
    pending = world.query((X, "pending_damage", Y))
    if pending:
        print(f"\n  Pending damage:")
        for p in pending:
            print(f"    {p['x']} takes {p['y']} damage")

    # Show any output
    looted = world.query(("output", "looted", X))
    if looted:
        for l in looted:
            print(f"\n  LOOTED: {l['x']}")


def run_combat_demo():
    """Demonstrate deferred combat rules."""
    print("=" * 60)
    print("HERB Combat — Deferred Rules Demo")
    print("=" * 60)
    print()
    print("This demonstrates combat using =>> (deferred) rules:")
    print("  1. attack => pending_damage (instant)")
    print("  2. pending_damage =>> hp update (micro-iter 1)")
    print("  3. hp <= 0 =>> death (micro-iter 2)")
    print("  4. death =>> loot drop (micro-iter 3)")
    print()

    world = bootstrap_combat_world()
    print_combat_state(world, "INITIAL STATE")

    # Player attacks!
    print("\n" + "~" * 50)
    print("  PLAYER ATTACKS!")
    print("~" * 50)

    world.assert_fact("input", "attack_cmd", True)
    world.advance()

    print_combat_state(world, "AFTER TICK 1")

    # Show provenance for goblin's death (if dead)
    goblin_alive = world.query(("goblin", "is_alive", False))
    if goblin_alive:
        print("\n  Provenance: Why is goblin dead?")
        explanation = world.explain("goblin", "is_alive", False)
        if explanation:
            def print_exp(exp, indent=2):
                prefix = " " * indent
                print(f"{prefix}{exp['fact']}")
                print(f"{prefix}  cause: {exp['cause']} @ tick {exp['from_tick']}")
                # Show micro-iteration if present
                if 'micro_iter' in exp:
                    print(f"{prefix}  micro-iteration: {exp['micro_iter']}")
                for dep in exp.get('depends_on', []):
                    print_exp(dep, indent + 2)
            print_exp(explanation)

    # Second attack (both should take damage, goblin should die)
    print("\n" + "~" * 50)
    print("  PLAYER ATTACKS AGAIN!")
    print("~" * 50)

    world.assert_fact("input", "attack_cmd", True)
    world.advance()

    print_combat_state(world, "AFTER TICK 2")

    # Third attack - wolf should die
    print("\n" + "~" * 50)
    print("  PLAYER ATTACKS AGAIN!")
    print("~" * 50)

    world.assert_fact("input", "attack_cmd", True)
    world.advance()

    print_combat_state(world, "AFTER TICK 3")

    # Clean up output facts
    for m in world.query(("output", "looted", X)):
        world.retract_fact("output", "looted", m['x'])

    print("\n" + "=" * 60)
    print("Final player gold:", world.query(("player", "gold", X))[0]['x'])
    print("=" * 60)

    # Show provenance for goblin's death
    print("\n--- PROVENANCE: Why is goblin dead? ---")
    explanation = world.explain("goblin", "is_alive", False)
    if explanation:
        def print_provenance(exp, indent=0):
            prefix = "  " * indent
            micro = f"@{exp['micro_iter']}" if exp.get('micro_iter', 0) > 0 else ""
            print(f"{prefix}{exp['fact']} [{exp['cause']}]{micro}")
            for dep in exp.get('depends_on', [])[:2]:  # Limit depth
                print_provenance(dep, indent + 1)
        print_provenance(explanation)


if __name__ == "__main__":
    run_combat_demo()
