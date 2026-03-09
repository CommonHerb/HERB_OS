"""
OS Experiments Runner — Session 12

Tests HERB against OS concepts to discover paradigm boundaries.
"""

import sys
sys.path.insert(0, '.')
from herb_core import World, Var, var
from herb_lang import run_herb_file

X, Y, Z = var('x'), var('y'), var('z')
A, B, C = var('a'), var('b'), var('c')
P, N = var('p'), var('n')


def separator(title):
    print(f"\n{'='*60}")
    print(f" {title}")
    print('='*60)


def run_scheduler_experiment():
    """Test the process scheduler model."""
    separator("EXPERIMENT 1: PROCESS SCHEDULER")

    world = run_herb_file("os_scheduler.herb")

    print(f"\nInitial state ({len(world)} facts):")

    # Show processes and their states
    print("\nProcesses:")
    for binding in world.query((X, "is_a", "process")):
        proc = binding['x']
        state_q = world.query((proc, "state", Y))
        prio_q = world.query((proc, "priority", Y))
        wait_q = world.query((proc, "waiting_since", Y))
        state = state_q[0]['y'] if state_q else "unknown"
        prio = prio_q[0]['y'] if prio_q else "?"
        wait = wait_q[0]['y'] if wait_q else "?"
        print(f"  {proc}: state={state}, priority={prio}, waiting_since={wait}")

    # Show CPU state
    cpu_state = world.query(("cpu0", "state", X))
    print(f"\nCPU: state={cpu_state[0]['x'] if cpu_state else 'unknown'}")

    # Run derivation
    print("\n--- Running scheduler derivation ---")
    try:
        world.advance()
        world.print_stratification()
    except Exception as e:
        print(f"ERROR: {e}")
        return

    # Check results
    print(f"\nAfter derivation ({len(world)} facts):")

    # Who got the CPU?
    assigned = world.query(("cpu0", "assigned_to", X))
    if assigned:
        print(f"\nCPU assigned to: {assigned[0]['x']}")
    else:
        print("\nCPU not assigned (no running process)")

    # New process states
    print("\nProcess states after scheduling:")
    for binding in world.query((X, "is_a", "process")):
        proc = binding['x']
        state_q = world.query((proc, "state", Y))
        state = state_q[0]['y'] if state_q else "unknown"
        print(f"  {proc}: {state}")

    # Check max priority intermediate fact
    max_prio = world.query(("cpu0", "max_ready_priority", X))
    if max_prio:
        print(f"\n[DEBUG] max_ready_priority = {max_prio[0]['x']}")

    candidates = list(world.query((X, "is_candidate", True)))
    if candidates:
        print(f"[DEBUG] candidates: {[c['x'] for c in candidates]}")

    oldest = world.query(("cpu0", "oldest_wait_time", X))
    if oldest:
        print(f"[DEBUG] oldest_wait_time = {oldest[0]['x']}")

    selected = list(world.query((X, "selected_for", Y)))
    if selected:
        print(f"[DEBUG] selected: {[(s['x'], s['y']) for s in selected]}")

    # Provenance
    if assigned:
        proc = assigned[0]['x']
        print(f"\n--- Explaining why {proc} is running ---")
        exp = world.explain(proc, "state", "running")
        if exp:
            print(f"  Cause: {exp['cause']}")
            for dep in exp.get('depends_on', []):
                print(f"    <- {dep['fact']} (cause: {dep['cause']})")


def run_filesystem_experiment():
    """Test the file system model."""
    separator("EXPERIMENT 2: FILE SYSTEM")

    world = run_herb_file("os_filesystem.herb")

    print(f"\nInitial state ({len(world)} facts):")

    # Show directory structure
    print("\nDirectory structure:")
    for binding in world.query((X, "is_a", "directory")):
        d = binding['x']
        name_q = world.query((d, "name", Y))
        parent_q = world.query((d, "parent", Y))
        name = name_q[0]['y'] if name_q else "/"
        parent = parent_q[0]['y'] if parent_q else "(root)"
        print(f"  {d}: {name} (parent: {parent})")

    # Show files
    print("\nFiles:")
    for binding in world.query((X, "is_a", "file")):
        f = binding['x']
        name_q = world.query((f, "name", Y))
        owner_q = world.query((f, "owner", Y))
        mode_q = world.query((f, "mode", Y))
        name = name_q[0]['y'] if name_q else "?"
        owner = owner_q[0]['y'] if owner_q else "?"
        mode = mode_q[0]['y'] if mode_q else "?"
        print(f"  {f}: {name} (owner: {owner}, mode: {mode})")

    # Run derivation to compute permissions
    print("\n--- Running permission derivation ---")
    world.advance()
    world.print_stratification()

    # Check derived permissions
    print("\nDerived permissions:")
    for binding in world.query((X, "can_read", Y)):
        user = binding['x']
        file = binding['y']
        print(f"  {user} can_read {file}")

    for binding in world.query((X, "can_write", Y)):
        user = binding['x']
        file = binding['y']
        print(f"  {user} can_write {file}")

    # Simulate an open request
    print("\n--- Simulating open(notes_txt, read) by proc1 ---")
    world.assert_fact("proc1", "open_request", "notes_txt")
    # Need to also specify mode - but our pattern expects (proc open_request file mode)
    # Let's adjust to simpler form: just assert the request differently

    # Actually our rules expect: ?proc open_request ?file read
    # Let's manually assert the triple form
    world.retract_fact("proc1", "open_request", "notes_txt")

    # We need to model this as: (proc1 open_request notes_txt read)
    # But HERB facts are triples, not quads. This reveals a modeling issue!

    print("\n[DISCOVERY] HERB facts are TRIPLES (s, r, o).")
    print("File open needs QUADS: (proc, open_request, file, mode)")
    print("Options:")
    print("  1. Reify: (req_001 is_a open_request), (req_001 proc proc1), ...")
    print("  2. Compound relation: (proc1 open_request_read notes_txt)")
    print("  3. Extend HERB to support n-ary facts")

    # Let's try compound relation approach
    print("\n--- Using compound relation: open_request_read ---")
    world.assert_fact("proc1", "open_request_read", "notes_txt")

    # Need to modify our rules too... but let's see what happens
    # Actually we can't modify rules dynamically. This shows the friction.

    print("[RESULT] Can't easily add new operation without modifying .herb file rules")


def run_isolation_experiment():
    """Test isolation concepts (conceptual only)."""
    separator("EXPERIMENT 3: PROCESS ISOLATION")

    print("\nThis experiment is CONCEPTUAL - HERB can't currently model isolation.")
    print("\nDemonstrating the problem:")

    # Create a world with two "processes" worth of facts
    world = World()

    # "Process A" facts
    world.assert_fact("proc_a", "hp", 100)
    world.assert_fact("proc_a", "secret", "password123")

    # "Process B" facts
    world.assert_fact("proc_b", "hp", 200)
    world.assert_fact("proc_b", "secret", "hunter2")

    print("\nAll facts in world:")
    for f in world.all_facts():
        print(f"  {f}")

    print("\nPROBLEM: Any query can see all facts.")
    print("Process B could query for Process A's secret:")

    result = world.query(("proc_a", "secret", X))
    if result:
        print(f"  proc_a's secret: {result[0]['x']}")
        print("  THIS SHOULD NOT BE POSSIBLE IN ISOLATED PROCESSES!")

    print("\nPossible solutions (not implemented):")
    print("  1. Multiple World instances with controlled visibility")
    print("  2. Fact metadata with visibility tags")
    print("  3. Capability tokens for scoped queries")
    print("  4. Query-time namespace filtering")


def run_io_experiment():
    """Test I/O event handling."""
    separator("EXPERIMENT 4: I/O AS FACTS")

    world = run_herb_file("os_io.herb")

    print(f"\nInitial state ({len(world)} facts):")

    # Show devices
    print("\nDevices:")
    for binding in world.query((X, "is_a", "device")):
        dev = binding['x']
        type_q = world.query((dev, "type", Y))
        dtype = type_q[0]['y'] if type_q else "?"
        print(f"  {dev}: type={dtype}")

    # Run derivation to initialize devices
    print("\n--- Running device initialization ---")
    world.advance()

    # Check device status
    print("\nDevice status after init:")
    for binding in world.query((X, "is_a", "device")):
        dev = binding['x']
        status_q = world.query((dev, "status", Y))
        status = status_q[0]['y'] if status_q else "none"
        print(f"  {dev}: status={status}")

    # Simulate keyboard event (external driver assertion)
    print("\n--- Simulating keyboard driver assertion ---")
    print("(External: keyboard driver detects keypress)")
    world.assert_fact("keyboard", "key_pressed", "a")

    print(f"\nBefore derivation - key_pressed fact exists:")
    kp = world.query(("keyboard", "key_pressed", X))
    print(f"  key_pressed: {kp[0]['x'] if kp else 'none'}")

    # Run derivation
    print("\n--- Running I/O handling derivation ---")
    world.advance()

    # Check results
    print("\nAfter derivation:")
    kp = world.query(("keyboard", "key_pressed", X))
    lk = world.query(("keyboard", "last_key", X))
    print(f"  key_pressed: {kp[0]['x'] if kp else 'consumed'}")
    print(f"  last_key: {lk[0]['x'] if lk else 'none'}")

    # Provenance
    if lk:
        print("\n--- Explaining last_key ---")
        exp = world.explain("keyboard", "last_key", lk[0]['x'])
        if exp:
            print(f"  Cause: {exp['cause']}")
            for dep in exp.get('depends_on', []):
                print(f"    <- {dep['fact']}")


def main():
    print("="*60)
    print(" HERB OS STRESS TEST — Session 12")
    print(" Testing paradigm boundaries against OS concepts")
    print("="*60)

    run_scheduler_experiment()
    run_filesystem_experiment()
    run_isolation_experiment()
    run_io_experiment()

    separator("SUMMARY")
    print("""
KEY FINDINGS:

1. STATE MACHINES WORK
   Process states, file descriptors, device status — all clean.
   FUNCTIONAL relations + RETRACT handle transitions naturally.

2. AGGREGATES FOR SCHEDULING WORK (but verbose)
   max priority, min wait time — expressible but requires
   4+ rules and cleanup for one scheduling decision.

3. TIE-BREAKING IS NON-DETERMINISTIC
   Multiple processes with same priority/wait -> all selected.
   FUNCTIONAL picks one arbitrarily. No controlled tie-break.

4. TRIPLES ARE LIMITING
   (proc, open_request, file) needs a mode too -> reification or
   compound relations. N-ary facts would be cleaner.

5. NO ISOLATION
   Single World sees all facts. Can't model process isolation.
   CRITICAL GAP for OS work. Needs multi-world architecture.

6. TIME IS LOGICAL, NOT PHYSICAL
   HERB ticks are derivation cycles. Real-time scheduling needs
   sub-microsecond response. Mismatch is fundamental.

7. NO BITWISE OPERATIONS
   Permissions need bit masks. HERB has +,-,*,/,mod but not AND/OR/XOR.

8. I/O BOUNDARY IS CLEAN
   External drivers assert events -> HERB processes -> drivers execute.
   This model works. HERB is policy, drivers are mechanism.

PROPOSED LANGUAGE ADDITIONS:
- BITWISE: (band a b), (bor a b), (bnot a)
- TIME: (current-tick) in templates
- N-ARY: facts with more than 3 components (or standard reification sugar)
- TIE-BREAK: deterministic selection from sets
- ISOLATION: Multi-world or visibility metadata

ARCHITECTURAL ADDITIONS NEEDED:
- Multi-World / Verse for isolation
- Driver interface for I/O boundary
- Blob/binary type for buffers
""")


if __name__ == "__main__":
    main()
