"""
HERB Performance Benchmark

Tests derivation performance with varying entity counts.
Target: handle 100+ NPCs at 600ms tick rate (Common Herb requirement).
"""

import time
from herb_core import World, var, Var, Expr

def benchmark_combat_proximity(entity_count: int) -> dict:
    """
    Benchmark: N entities in same location, derive can_target relations.

    This is O(N²) — every pair of combatants gets a can_target fact.
    """
    world = World()

    A, B = var('a'), var('b')
    LOC = var('loc')

    # Create entities
    for i in range(entity_count):
        world.assert_fact(f"entity_{i}", "is_a", "combatant")
        world.assert_fact(f"entity_{i}", "location", "arena")

    # Add proximity rule
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

    # Time the derivation
    start = time.perf_counter()
    world.advance()
    elapsed = time.perf_counter() - start

    # Count derived facts
    can_target_count = len(world.query((var('x'), "can_target", var('y'))))

    return {
        'entities': entity_count,
        'derived_facts': can_target_count,
        'total_facts': len(world),
        'time_ms': elapsed * 1000,
        'expected_pairs': entity_count * entity_count  # N² including self
    }


def benchmark_damage_chain(entity_count: int) -> dict:
    """
    Benchmark: N entities each with pending damage, apply damage rule.

    This tests arithmetic evaluation and retraction at scale.
    """
    world = World()

    X = var('x')
    HP, DMG = var('hp'), var('dmg')

    # Create entities with HP and pending damage
    for i in range(entity_count):
        world.assert_fact(f"entity_{i}", "hp", 100)
        world.assert_fact(f"entity_{i}", "pending_damage", 25)

    # Add damage application rule
    world.add_derivation_rule(
        "apply_damage",
        patterns=[
            (X, "hp", HP),
            (X, "pending_damage", DMG)
        ],
        template=(X, "hp", Expr('-', [HP, DMG])),
        retractions=[
            (X, "hp", HP),
            (X, "pending_damage", DMG)
        ]
    )

    # Time the derivation
    start = time.perf_counter()
    world.advance()
    elapsed = time.perf_counter() - start

    # Verify damage was applied
    hp_facts = world.query((var('e'), "hp", var('v')))

    return {
        'entities': entity_count,
        'hp_facts': len(hp_facts),
        'total_facts': len(world),
        'time_ms': elapsed * 1000,
        'correct_hp': all(f['v'] == 75 for f in hp_facts)
    }


def run_benchmarks():
    print("=" * 70)
    print("HERB Performance Benchmarks")
    print("=" * 70)

    # Combat proximity (O(N²) behavior)
    print("\n--- Benchmark: Combat Proximity (O(N²)) ---")
    print(f"{'Entities':>10} {'Derived':>10} {'Time (ms)':>12} {'Facts/ms':>10}")
    print("-" * 50)

    for n in [10, 25, 50, 75, 100, 150, 200]:
        result = benchmark_combat_proximity(n)
        facts_per_ms = result['derived_facts'] / result['time_ms'] if result['time_ms'] > 0 else 0
        print(f"{result['entities']:>10} {result['derived_facts']:>10} {result['time_ms']:>12.2f} {facts_per_ms:>10.0f}")

    # Damage chain (O(N) behavior)
    print("\n--- Benchmark: Damage Application (O(N)) ---")
    print(f"{'Entities':>10} {'Time (ms)':>12} {'Correct':>10}")
    print("-" * 40)

    for n in [100, 500, 1000, 2000, 5000]:
        result = benchmark_damage_chain(n)
        print(f"{result['entities']:>10} {result['time_ms']:>12.2f} {str(result['correct_hp']):>10}")

    # Target check: can we do 100 entities in < 600ms?
    print("\n--- Target Check: 100 entities, 600ms budget ---")
    result = benchmark_combat_proximity(100)
    status = "PASS" if result['time_ms'] < 600 else "FAIL"
    print(f"  Combat proximity (100 entities): {result['time_ms']:.2f}ms [{status}]")

    result = benchmark_damage_chain(100)
    status = "PASS" if result['time_ms'] < 600 else "FAIL"
    print(f"  Damage application (100 entities): {result['time_ms']:.2f}ms [{status}]")

    print("\n" + "=" * 70)


if __name__ == "__main__":
    run_benchmarks()
