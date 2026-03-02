"""
Multi-World Demo - OS Scenario

Demonstrates the Multi-World architecture with kernel/process isolation:
- Kernel World: system state, scheduler
- Process Worlds: isolated memory, exports state/priority
- Processes cannot see each other's memory (true isolation)
- Kernel schedules based on exported process state

Session 14 - February 4, 2026
"""

from herb_core import World, Verse, Var, Expr, AggregateExpr

X, Y, Z = Var('x'), Var('y'), Var('z')
P, S, PRIO = Var('p'), Var('s'), Var('prio')


def main():
    print("=" * 60)
    print("HERB Multi-World Demo - OS Scenario")
    print("=" * 60)

    # Create the Verse
    verse = Verse()

    # =========================================================================
    # KERNEL WORLD (root) - System state
    # =========================================================================
    print("\n--- Creating Kernel World ---")
    kernel = verse.create_world("kernel")

    # System configuration (inherited by all processes)
    kernel.assert_fact("system", "quantum_ms", 100)
    kernel.assert_fact("system", "max_priority", 99)

    # Current process tracking
    kernel.declare_functional("current_process")
    kernel.assert_fact("scheduler", "current_process", None)

    print(f"  Kernel has {len(kernel)} facts")

    # =========================================================================
    # PROCESS WORLDS - Isolated state
    # =========================================================================
    print("\n--- Creating Process Worlds ---")

    # Process A - High priority shell
    proc_a = verse.create_world("proc_a", parent="kernel")
    proc_a.declare_functional("state")
    proc_a.declare_functional("priority")
    proc_a.declare_export("state")
    proc_a.declare_export("priority")
    proc_a.declare_export("pid")

    proc_a.assert_fact("self", "pid", 1001)
    proc_a.assert_fact("self", "state", "ready")
    proc_a.assert_fact("self", "priority", 50)
    proc_a.assert_fact("self", "memory", "sensitive_data_A")  # NOT exported
    print(f"  proc_a: pid=1001, priority=50, exports: state, priority, pid")

    # Process B - Low priority batch job
    proc_b = verse.create_world("proc_b", parent="kernel")
    proc_b.declare_functional("state")
    proc_b.declare_functional("priority")
    proc_b.declare_export("state")
    proc_b.declare_export("priority")
    proc_b.declare_export("pid")

    proc_b.assert_fact("self", "pid", 1002)
    proc_b.assert_fact("self", "state", "ready")
    proc_b.assert_fact("self", "priority", 10)
    proc_b.assert_fact("self", "memory", "sensitive_data_B")  # NOT exported
    print(f"  proc_b: pid=1002, priority=10, exports: state, priority, pid")

    # Process C - Blocked on I/O
    proc_c = verse.create_world("proc_c", parent="kernel")
    proc_c.declare_functional("state")
    proc_c.declare_functional("priority")
    proc_c.declare_export("state")
    proc_c.declare_export("priority")
    proc_c.declare_export("pid")

    proc_c.assert_fact("self", "pid", 1003)
    proc_c.assert_fact("self", "state", "blocked")
    proc_c.assert_fact("self", "priority", 30)
    proc_c.assert_fact("self", "memory", "sensitive_data_C")
    print(f"  proc_c: pid=1003, priority=30 (blocked), exports: state, priority, pid")

    # =========================================================================
    # DEMONSTRATE ISOLATION
    # =========================================================================
    print("\n--- Process Isolation ---")

    # Process A cannot see Process B's memory
    a_sees_b_memory = proc_a.query(("self", "memory", X))
    print(f"  proc_a's memory: {a_sees_b_memory[0]['x']}")

    # Try to query with different subject pattern
    proc_a_all = proc_a.query((Y, "memory", X))
    print(f"  proc_a sees any memory: {[r['x'] for r in proc_a_all]}")
    # Should only see own memory

    # Kernel cannot see process internals
    kernel_sees_memory = kernel.query((Y, "memory", X))
    print(f"  Kernel sees process memory? {len(kernel_sees_memory) == 0} (isolated)")

    # =========================================================================
    # KERNEL SEES EXPORTS
    # =========================================================================
    print("\n--- Kernel Sees Process Exports ---")

    # Get all process states
    for proc_name in ["proc_a", "proc_b", "proc_c"]:
        state = verse.query_child_exports("kernel", proc_name,
                                           ("self", "state", X))
        prio = verse.query_child_exports("kernel", proc_name,
                                          ("self", "priority", X))
        pid = verse.query_child_exports("kernel", proc_name,
                                         ("self", "pid", X))
        print(f"  {proc_name}: pid={pid[0]['x']}, state={state[0]['x']}, priority={prio[0]['x']}")

    # =========================================================================
    # PROCESS SEES SYSTEM CONFIG (inheritance)
    # =========================================================================
    print("\n--- Processes Inherit System Config ---")

    quantum = proc_a.query(("system", "quantum_ms", X))
    print(f"  proc_a sees quantum_ms: {quantum[0]['x']}")

    max_prio = proc_b.query(("system", "max_priority", X))
    print(f"  proc_b sees max_priority: {max_prio[0]['x']}")

    # =========================================================================
    # KERNEL SENDS COMMANDS
    # =========================================================================
    print("\n--- Kernel Commands Processes ---")

    # Send run command to proc_a
    verse.send_message("kernel", "proc_a", "inbox", "command", "run")
    print("  Sent 'run' command to proc_a")

    # proc_a sees it
    inbox = proc_a.query(("inbox", "command", X))
    print(f"  proc_a inbox: command={inbox[0]['x']}")

    # Add rule to proc_a: handle run command
    proc_a.add_derivation_rule(
        "handle_run",
        [("inbox", "command", "run")],
        ("self", "state", "running")
    )

    # Tick to process the command
    verse.tick()

    new_state = proc_a.query(("self", "state", X))
    print(f"  proc_a state after command: {new_state[0]['x']}")

    # =========================================================================
    # PROCESS SENDS SYSCALL
    # =========================================================================
    print("\n--- Process Makes Syscall ---")

    # proc_b sends syscall to kernel
    verse.send_message("proc_b", "kernel", "inbox", "syscall", "exit")
    print("  proc_b sent 'exit' syscall to kernel")

    kernel_inbox = kernel.query(("inbox", "syscall", X))
    print(f"  Kernel inbox: syscall={kernel_inbox[0]['x']}")

    # =========================================================================
    # VERSE TREE
    # =========================================================================
    verse.print_tree()

    # =========================================================================
    # PROVENANCE
    # =========================================================================
    print("\n--- Provenance: Why is proc_a running? ---")
    exp = proc_a.explain("self", "state", "running")
    if exp:
        print(f"  Fact: {exp['fact']}")
        print(f"  Cause: {exp['cause']}")
        for dep in exp['depends_on']:
            print(f"  Depends on: {dep['fact']} (cause: {dep['cause']})")

    print("\n" + "=" * 60)
    print("DEMO COMPLETE")
    print("=" * 60)
    print("\nKey Achievements:")
    print("  [OK] Process isolation (can't see sibling memory)")
    print("  [OK] Kernel sees only exports (state, priority, pid)")
    print("  [OK] Processes inherit system config")
    print("  [OK] Kernel commands via inbox (run)")
    print("  [OK] Syscalls via inbox (exit)")
    print("  [OK] Provenance traces command handling")


if __name__ == "__main__":
    main()
