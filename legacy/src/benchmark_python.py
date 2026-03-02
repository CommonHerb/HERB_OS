"""
Benchmark: Python HERB interpreter vs Native runtime

Same workload as herb_runtime.c:
- 100 entities
- Each is_a person
- Each in one of 10 zones
- Rule: persons in same zone see each other
- Expected: 1000 "sees" facts derived
"""

import time
from herb_core import World, Var

def benchmark_python():
    print("HERB Python Interpreter Benchmark")
    print("=" * 40)

    world = World()
    X, Y, Z = Var('x'), Var('y'), Var('z')

    # Assert initial facts
    print("\nAsserting 100 entities...")
    for i in range(100):
        world.assert_fact(f"entity_{i}", "is_a", "person")
        world.assert_fact(f"entity_{i}", "location", f"zone_{i % 10}")

    print(f"Initial facts: {len(world)}")

    # Add visibility rule
    world.add_derivation_rule(
        "visibility",
        patterns=[
            (X, "is_a", "person"),
            (Y, "is_a", "person"),
            (X, "location", Z),
            (Y, "location", Z)
        ],
        template=(X, "sees", Y)
    )
    print("Added visibility rule (4 patterns)\n")

    # Derive
    print("Running derivation...")
    start = time.perf_counter()
    world.advance()
    end = time.perf_counter()

    ms = (end - start) * 1000

    # Count sees facts
    sees_facts = world.query((X, "sees", Y))
    sees_count = len(sees_facts)

    print(f"Time: {ms:.3f} ms")
    print(f"Total 'sees' facts: {sees_count}")
    print(f"Expected: 1000")
    print(f"\nFinal fact count: {len(world)}")

    return ms


def benchmark_larger():
    """Larger benchmark to see scaling."""
    print("\n" + "=" * 40)
    print("LARGER BENCHMARK (200 entities)")
    print("=" * 40)

    world = World()
    X, Y, Z = Var('x'), Var('y'), Var('z')

    for i in range(200):
        world.assert_fact(f"entity_{i}", "is_a", "person")
        world.assert_fact(f"entity_{i}", "location", f"zone_{i % 10}")

    world.add_derivation_rule(
        "visibility",
        patterns=[
            (X, "is_a", "person"),
            (Y, "is_a", "person"),
            (X, "location", Z),
            (Y, "location", Z)
        ],
        template=(X, "sees", Y)
    )

    print(f"Initial facts: {len(world)}")

    start = time.perf_counter()
    world.advance()
    end = time.perf_counter()

    ms = (end - start) * 1000

    sees_facts = world.query((X, "sees", Y))
    print(f"Derived {len(sees_facts)} 'sees' facts")
    print(f"Time: {ms:.3f} ms")
    print(f"Expected: 200 * 20 = 4000 sees facts")

    return ms


if __name__ == "__main__":
    ms_100 = benchmark_python()
    ms_200 = benchmark_larger()

    print("\n" + "=" * 40)
    print("SUMMARY")
    print("=" * 40)
    print(f"100 entities: {ms_100:.3f} ms (Python)")
    print(f"200 entities: {ms_200:.3f} ms (Python)")
    print(f"\nCompare to C runtime:")
    print(f"100 entities: ~1 ms (C)")
