"""
HERB NPC Adventure — Session 16

Tests FUNCTIONAL + EPHEMERAL + deferred + ONCE_PER_TICK under multi-agent load.

4 NPCs with jobs:
- Guard: patrols between rooms, attacks enemies on sight
- Merchant: stays in market, offers trade when player nearby
- Wanderer: moves randomly, flees from danger
- Bandit: lurks in cave, attacks player on sight

All behavior is HERB rules, not Python code.

Key discovery this session: Multi-agent actions require ONCE PER TICK primitive.
Fixpoint derivation keeps firing rules while preconditions hold. For agent actions
that don't disable their own preconditions (guard attacks, target survives, guard
can attack again), we need the engine to enforce "one action per tick per binding."

Session 16 — February 4, 2026
"""

import time
from herb_core import World, Var, Expr

# Variables
X, Y, Z = Var('x'), Var('y'), Var('z')
E, N = Var('e'), Var('n')  # Entity, NPC
A = Var('a')  # Attacker
DMG, HP, G = Var('dmg'), Var('hp'), Var('g')
LOC, DEST = Var('loc'), Var('dest')


def bootstrap_adventure_world() -> World:
    """
    Create an adventure world with player, enemies, and NPCs.

    Rooms: forest, town, market, cave
    NPCs: guard, merchant, wanderer, bandit
    """
    world = World("adventure")

    # =========================================================================
    # DECLARATIONS
    # =========================================================================

    # Functional relations (single-valued)
    world.declare_functional("hp")
    world.declare_functional("location")
    world.declare_functional("is_alive")
    world.declare_functional("gold")
    world.declare_functional("patrol_target")

    # Ephemeral relations (consumed after first rule matches)
    world.declare_ephemeral("attack_cmd")
    world.declare_ephemeral("move_cmd")

    # =========================================================================
    # WORLD TOPOLOGY
    # =========================================================================

    connections = [
        ("forest", "town"),
        ("town", "market"),
        ("forest", "cave"),
    ]
    for a, b in connections:
        world.assert_fact(a, "connects_to", b)
        world.assert_fact(b, "connects_to", a)

    world.assert_fact("town", "is_safe", True)
    world.assert_fact("market", "is_safe", True)

    # =========================================================================
    # PLAYER
    # =========================================================================

    world.assert_fact("player", "is_a", "player")
    world.assert_fact("player", "is_a", "combatant")
    world.assert_fact("player", "hp", 100)
    world.assert_fact("player", "base_damage", 15)
    world.assert_fact("player", "location", "forest")
    world.assert_fact("player", "is_alive", True)
    world.assert_fact("player", "gold", 50)

    # =========================================================================
    # ENEMIES
    # =========================================================================

    world.assert_fact("goblin", "is_a", "enemy")
    world.assert_fact("goblin", "is_a", "combatant")
    world.assert_fact("goblin", "hp", 25)
    world.assert_fact("goblin", "base_damage", 8)
    world.assert_fact("goblin", "location", "forest")
    world.assert_fact("goblin", "is_alive", True)
    world.assert_fact("goblin", "gold", 25)

    world.assert_fact("wolf", "is_a", "enemy")
    world.assert_fact("wolf", "is_a", "combatant")
    world.assert_fact("wolf", "hp", 30)
    world.assert_fact("wolf", "base_damage", 6)
    world.assert_fact("wolf", "location", "forest")
    world.assert_fact("wolf", "is_alive", True)
    world.assert_fact("wolf", "gold", 10)

    # =========================================================================
    # NPCs
    # =========================================================================

    # Guard — patrols forest<->town, attacks enemies
    world.assert_fact("guard", "is_a", "npc")
    world.assert_fact("guard", "is_a", "combatant")
    world.assert_fact("guard", "job", "patrol")
    world.assert_fact("guard", "hp", 80)
    world.assert_fact("guard", "base_damage", 12)
    world.assert_fact("guard", "location", "town")
    world.assert_fact("guard", "is_alive", True)
    world.assert_fact("guard", "gold", 5)
    world.assert_fact("guard", "patrol_target", "forest")

    # Merchant — offers trade when player nearby
    world.assert_fact("merchant", "is_a", "npc")
    world.assert_fact("merchant", "job", "merchant")
    world.assert_fact("merchant", "hp", 30)
    world.assert_fact("merchant", "base_damage", 0)
    world.assert_fact("merchant", "location", "market")
    world.assert_fact("merchant", "is_alive", True)
    world.assert_fact("merchant", "gold", 100)

    # Wanderer — flees danger
    world.assert_fact("wanderer", "is_a", "npc")
    world.assert_fact("wanderer", "job", "idle")
    world.assert_fact("wanderer", "hp", 20)
    world.assert_fact("wanderer", "base_damage", 0)
    world.assert_fact("wanderer", "location", "town")
    world.assert_fact("wanderer", "is_alive", True)
    world.assert_fact("wanderer", "gold", 3)

    # Bandit — attacks player on sight
    world.assert_fact("bandit", "is_a", "npc")
    world.assert_fact("bandit", "is_a", "combatant")
    world.assert_fact("bandit", "is_a", "hostile")
    world.assert_fact("bandit", "job", "bandit")
    world.assert_fact("bandit", "hp", 40)
    world.assert_fact("bandit", "base_damage", 10)
    world.assert_fact("bandit", "location", "cave")
    world.assert_fact("bandit", "is_alive", True)
    world.assert_fact("bandit", "gold", 50)

    # =========================================================================
    # PLAYER RULES
    # =========================================================================

    # Player moves
    world.add_derivation_rule(
        "player_moves",
        [("input", "move_cmd", DEST),
         ("player", "location", LOC),
         (LOC, "connects_to", DEST),
         ("player", "is_alive", True)],
        ("player", "location", DEST)
    )

    # Player attacks enemies (ONCE PER TICK per target)
    world.add_derivation_rule(
        "player_attacks_enemy",
        [("input", "attack_cmd", True),
         ("player", "location", LOC),
         ("player", "base_damage", DMG),
         ("player", "is_alive", True),
         (E, "is_a", "enemy"),
         (E, "location", LOC),
         (E, "is_alive", True)],
        (E, "pending_damage", DMG),
        once_per_tick=True,
        once_key_vars=['e']  # One attack per target
    )

    # Player attacks hostile NPCs (ONCE PER TICK per target)
    world.add_derivation_rule(
        "player_attacks_hostile",
        [("input", "attack_cmd", True),
         ("player", "location", LOC),
         ("player", "base_damage", DMG),
         ("player", "is_alive", True),
         (N, "is_a", "npc"),
         (N, "is_a", "hostile"),
         (N, "location", LOC),
         (N, "is_alive", True)],
        (N, "pending_damage", DMG),
        once_per_tick=True,
        once_key_vars=['n']
    )

    # =========================================================================
    # GUARD BEHAVIOR
    # =========================================================================

    # Guard moves toward patrol target (ONCE PER TICK)
    world.add_derivation_rule(
        "guard_moves",
        [("guard", "job", "patrol"),
         ("guard", "location", LOC),
         ("guard", "patrol_target", DEST),
         (LOC, "connects_to", DEST),
         ("guard", "is_alive", True)],
        ("guard", "location", DEST),
        guard=Expr('not=', [LOC, DEST]),
        once_per_tick=True
    )

    # Guard swaps patrol target when reaching destination
    world.add_derivation_rule(
        "guard_swaps_patrol_forest",
        [("guard", "location", "forest"),
         ("guard", "patrol_target", "forest")],
        ("guard", "patrol_target", "town"),
        once_per_tick=True
    )

    world.add_derivation_rule(
        "guard_swaps_patrol_town",
        [("guard", "location", "town"),
         ("guard", "patrol_target", "town")],
        ("guard", "patrol_target", "forest"),
        once_per_tick=True
    )

    # Guard attacks enemies in same location (ONCE PER TICK per target)
    world.add_derivation_rule(
        "guard_attacks",
        [("guard", "is_a", "combatant"),
         ("guard", "location", LOC),
         ("guard", "base_damage", DMG),
         ("guard", "is_alive", True),
         (E, "is_a", "enemy"),
         (E, "location", LOC),
         (E, "is_alive", True)],
        (E, "pending_damage", DMG),
        once_per_tick=True,
        once_key_vars=['e']
    )

    # =========================================================================
    # MERCHANT BEHAVIOR
    # =========================================================================

    # Merchant offers trade when player nearby
    world.add_derivation_rule(
        "merchant_offers_trade",
        [("merchant", "job", "merchant"),
         ("merchant", "location", LOC),
         ("merchant", "is_alive", True),
         ("player", "location", LOC),
         ("player", "is_alive", True)],
        ("output", "trade_available", "merchant"),
        once_per_tick=True
    )

    # =========================================================================
    # WANDERER BEHAVIOR
    # =========================================================================

    # Wanderer flees if enemy present (ONCE PER TICK)
    world.add_derivation_rule(
        "wanderer_flees",
        [("wanderer", "job", "idle"),
         ("wanderer", "location", LOC),
         ("wanderer", "is_alive", True),
         (E, "is_a", "enemy"),
         (E, "location", LOC),
         (E, "is_alive", True),
         (LOC, "connects_to", DEST)],
        ("wanderer", "location", DEST),
        once_per_tick=True
    )

    # =========================================================================
    # BANDIT BEHAVIOR
    # =========================================================================

    # Bandit attacks player on sight (ONCE PER TICK)
    world.add_derivation_rule(
        "bandit_attacks",
        [("bandit", "job", "bandit"),
         ("bandit", "location", LOC),
         ("bandit", "base_damage", DMG),
         ("bandit", "is_alive", True),
         ("player", "location", LOC),
         ("player", "is_alive", True)],
        ("player", "pending_damage", DMG),
        once_per_tick=True
    )

    # =========================================================================
    # COMBAT RESOLUTION
    # =========================================================================

    # Apply pending damage (DEFERRED — after all attacks planned)
    world.add_derivation_rule(
        "apply_damage",
        [(E, "pending_damage", DMG),
         (E, "hp", HP),
         (E, "is_alive", True)],
        templates=[(E, "hp", Expr('-', [HP, DMG]))],
        retractions=[(E, "pending_damage", DMG)],
        deferred=True
    )

    # Check for death (DEFERRED — after HP updated)
    world.add_derivation_rule(
        "check_death",
        [(E, "hp", HP),
         (E, "is_alive", True)],
        (E, "is_alive", False),
        guard=Expr('<=', [HP, 0]),
        deferred=True
    )

    # Drop loot on death (DEFERRED)
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

    # Enemy counterattack (ONCE PER TICK per enemy)
    world.add_derivation_rule(
        "enemy_counterattacks",
        [("input", "attack_cmd", True),
         (E, "is_a", "enemy"),
         (E, "location", LOC),
         (E, "is_alive", True),
         (E, "base_damage", DMG),
         ("player", "location", LOC),
         ("player", "is_alive", True)],
        ("player", "pending_damage", DMG),
        once_per_tick=True,
        once_key_vars=['e']
    )

    return world


def print_world_state(world: World, label: str = ""):
    """Print current game state."""
    print(f"\n{'='*60}")
    if label:
        print(f"  {label}")
    print(f"  Tick: {world.tick}")
    print(f"{'='*60}")

    player_loc = world.query(("player", "location", X))
    player_hp = world.query(("player", "hp", X))
    player_gold = world.query(("player", "gold", X))
    player_alive = world.query(("player", "is_alive", X))

    loc = player_loc[0]['x'] if player_loc else "?"
    hp = player_hp[0]['x'] if player_hp else "?"
    gold = player_gold[0]['x'] if player_gold else 0
    alive = player_alive[0]['x'] if player_alive else "?"
    status = "ALIVE" if alive == True else "DEAD"

    print(f"\n  PLAYER @ {loc} | HP: {hp} | Gold: {gold} | {status}")

    print(f"\n  Room: {loc}")
    connections = world.query((loc, "connects_to", X))
    exits = [c['x'] for c in connections]
    print(f"  Exits: {', '.join(exits)}")

    entities_here = world.query((X, "location", loc))
    others = [e['x'] for e in entities_here if e['x'] != "player"]

    if others:
        print(f"\n  Entities here:")
        for ent in others:
            ent_hp = world.query((ent, "hp", X))
            ent_alive = world.query((ent, "is_alive", X))
            ent_job = world.query((ent, "job", X))
            ent_hostile = world.query((ent, "is_a", "hostile"))
            ent_enemy = world.query((ent, "is_a", "enemy"))

            hp = ent_hp[0]['x'] if ent_hp else "?"
            alive = ent_alive[0]['x'] if ent_alive else False
            job = ent_job[0]['x'] if ent_job else None
            hostile = len(ent_hostile) > 0 or len(ent_enemy) > 0

            if alive == True:
                job_str = f" ({job})" if job else ""
                hostile_str = " [HOSTILE]" if hostile else ""
                print(f"    - {ent}{job_str}{hostile_str} | HP: {hp}")
            else:
                print(f"    - {ent} [DEAD]")

    pending = world.query((X, "pending_damage", Y))
    if pending:
        print(f"\n  Pending damage:")
        for p in pending:
            print(f"    {p['x']} takes {p['y']} damage")

    trade = world.query(("output", "trade_available", X))
    if trade:
        print(f"\n  >> Trade available with {trade[0]['x']}!")

    looted = world.query(("output", "looted", X))
    if looted:
        for l in looted:
            print(f"\n  >> Looted {l['x']}!")


def cleanup_outputs(world: World):
    """Remove output facts after rendering."""
    for m in world.query(("output", X, Y)):
        world.retract_fact("output", m['x'], m['y'])


def run_npc_adventure():
    """Run the NPC adventure demo."""
    print("=" * 60)
    print("HERB NPC Adventure — Session 16")
    print("=" * 60)
    print()
    print("Testing ONCE_PER_TICK primitive for multi-agent actions.")
    print()

    world = bootstrap_adventure_world()
    tick_times = []

    print_world_state(world, "INITIAL STATE")

    # TICK 1: Player attacks
    print("\n" + "~" * 60)
    print("  TICK 1: Player attacks!")
    print("~" * 60)

    start = time.perf_counter()
    world.assert_fact("input", "attack_cmd", True)
    world.advance()
    tick_times.append(time.perf_counter() - start)

    print_world_state(world, "AFTER TICK 1")
    cleanup_outputs(world)

    # TICK 2: Player attacks again
    print("\n" + "~" * 60)
    print("  TICK 2: Player attacks again!")
    print("~" * 60)

    start = time.perf_counter()
    world.assert_fact("input", "attack_cmd", True)
    world.advance()
    tick_times.append(time.perf_counter() - start)

    print_world_state(world, "AFTER TICK 2")
    cleanup_outputs(world)

    # TICK 3: Player moves to town
    print("\n" + "~" * 60)
    print("  TICK 3: Player moves to town")
    print("~" * 60)

    start = time.perf_counter()
    world.assert_fact("input", "move_cmd", "town")
    world.advance()
    tick_times.append(time.perf_counter() - start)

    print_world_state(world, "AFTER TICK 3")
    cleanup_outputs(world)

    # TICK 4: Player moves to market
    print("\n" + "~" * 60)
    print("  TICK 4: Player moves to market")
    print("~" * 60)

    start = time.perf_counter()
    world.assert_fact("input", "move_cmd", "market")
    world.advance()
    tick_times.append(time.perf_counter() - start)

    print_world_state(world, "AFTER TICK 4")
    cleanup_outputs(world)

    # TICK 5-6: Go to cave
    print("\n" + "~" * 60)
    print("  TICK 5-6: Player goes to cave via town/forest")
    print("~" * 60)

    world.assert_fact("input", "move_cmd", "town")
    world.advance()
    world.assert_fact("input", "move_cmd", "forest")
    world.advance()
    world.assert_fact("input", "move_cmd", "cave")
    world.advance()

    print_world_state(world, "AFTER REACHING CAVE")
    cleanup_outputs(world)

    # Fight bandit
    for i in range(4):
        print("\n" + "~" * 60)
        print(f"  TICK {7+i}: Player attacks bandit!")
        print("~" * 60)

        start = time.perf_counter()
        world.assert_fact("input", "attack_cmd", True)
        world.advance()
        tick_times.append(time.perf_counter() - start)

        print_world_state(world, f"AFTER TICK {7+i}")
        cleanup_outputs(world)

        bandit_alive = world.query(("bandit", "is_alive", True))
        if not bandit_alive:
            break

    # Summary
    print("\n" + "=" * 60)
    print("  SUMMARY")
    print("=" * 60)

    player_hp = world.query(("player", "hp", X))
    player_gold = world.query(("player", "gold", X))
    print(f"\n  Final player HP: {player_hp[0]['x'] if player_hp else '?'}")
    print(f"  Final player gold: {player_gold[0]['x'] if player_gold else '?'}")

    print("\n  NPC States:")
    for npc in ["guard", "merchant", "wanderer", "bandit", "goblin", "wolf"]:
        npc_alive = world.query((npc, "is_alive", X))
        npc_loc = world.query((npc, "location", X))
        alive = npc_alive[0]['x'] if npc_alive else False
        loc = npc_loc[0]['x'] if npc_loc else "?"
        status = "ALIVE" if alive == True else "DEAD"
        print(f"    {npc:10} | {status:5} | Location: {loc}")

    print(f"\n  Tick times (ms):")
    for i, t in enumerate(tick_times):
        print(f"    Tick {i+1}: {t*1000:.2f}ms")

    avg_time = sum(tick_times) / len(tick_times) * 1000 if tick_times else 0
    max_time = max(tick_times) * 1000 if tick_times else 0
    print(f"\n  Average: {avg_time:.2f}ms")
    print(f"  Max: {max_time:.2f}ms")
    print(f"  Target (600ms tick): {'PASS' if max_time < 600 else 'FAIL'}")

    print(f"\n  Total rules: {len(world._derivation_rules)}")


if __name__ == "__main__":
    run_npc_adventure()
