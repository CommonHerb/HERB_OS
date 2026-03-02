"""
DEMO: Autonomous Scheduler — From Pure HERB Program

This loads the scheduler from herb_scheduler.py (pure data, no Python
callables) and runs it. The system behavior is IDENTICAL to the
hand-coded demo_scheduler.py.

The difference: demo_scheduler.py defines tensions as Python lambdas.
This demo loads them from a data structure. The scheduler IS the data.

External code only provides:
  1. Loading the program
  2. Sending signals (creating signal entities at runtime)

Everything else — scheduling, preemption, blocking, unblocking —
emerges from the declarative tensions resolving against the operation set.
"""

from herb_program import HerbProgram
from herb_scheduler import SCHEDULER


def main():
    print("=" * 60)
    print("  HERB Autonomous Scheduler — From Pure Data Program")
    print("  No Python callables. No lambdas. Just data.")
    print("=" * 60)

    # Load the program
    program = HerbProgram(SCHEDULER)
    g = program.load()

    def show_state(label=""):
        if label:
            print(f"\n  --- {label} ---")
        for name in ['init', 'shell', 'daemon']:
            loc = program.where_is(name)
            print(f"    {name:10s} -> {loc}")

    # === BOOT ===
    print("\n>>> BOOT: run() — tensions fill idle CPUs")
    total = g.run()
    print(f"  Moves executed: {total}")
    show_state("After boot")

    # === Timer preemption ===
    print("\n>>> SIGNAL: Timer expired (round-robin preemption)")
    program.create_entity("timer_1", "Signal", "TIMER_EXPIRED")
    total = g.run()
    print(f"  Moves executed: {total}")
    show_state("After timer preemption")

    # === Block shell for I/O ===
    print("\n>>> Block shell for I/O")
    op = g.move("block", program.entity_id("shell"),
                program.container_id("BLOCKED"), cause='io_request')
    total = g.run()
    print(f"  Tension moves: {total}")
    show_state("After shell blocked")

    # === I/O complete ===
    print("\n>>> SIGNAL: I/O complete (unblock shell)")
    program.create_entity("io_1", "Signal", "IO_COMPLETE")
    total = g.run()
    print(f"  Moves executed: {total}")
    show_state("After I/O complete")

    # === Another timer ===
    print("\n>>> SIGNAL: Timer expired again")
    program.create_entity("timer_2", "Signal", "TIMER_EXPIRED")
    total = g.run()
    print(f"  Moves executed: {total}")
    show_state("After second timer")

    # === Summary ===
    print(f"\n{'='*60}")
    print(f"  Total operations: {len(g.operations)}")
    print(f"  Tensions defined: {len(g.tensions)}")
    print(f"  ALL scheduling was autonomous — no external scheduler logic.")
    print(f"  Program is PURE DATA — no Python callables anywhere.")
    print(f"{'='*60}")

    # === Provenance ===
    print("\n  Provenance for 'init':")
    for op in g.why(program.entity_id("init")):
        from_c = op.params.get('from_container')
        to_c = op.params.get('to_container')
        from_name = g.containers[from_c].name if from_c else '?'
        to_name = g.containers[to_c].name
        print(f"    [{op.op_type}] {from_name} -> {to_name} (cause: {op.cause})")


if __name__ == "__main__":
    main()
