"""
DEMO: Autonomous Process Scheduler

This demonstrates HERB's core breakthrough: the system runs itself.

External code provides:
  1. Initial state (processes, CPUs, containers)
  2. Signals (timer expiry, I/O completion)

Everything else emerges from tensions resolving against the operation set.
The scheduler decides what to run, preempts processes, handles blocking
and unblocking — ALL autonomously.

No scheduler loop. No if/else logic driving behavior.
Just tensions (energy gradients) and MOVEs (gravity).
"""

from herb_move import MoveGraph, ContainerKind, IntendedMove


def build_scheduler():
    """
    Build an autonomous process scheduler.
    
    3 processes, 2 CPUs. Tensions handle all scheduling decisions.
    """
    g = MoveGraph()

    # === Entity Types ===
    proc_type = g.define_entity_type("Process")
    signal_type = g.define_entity_type("Signal")

    # === Process Containers (states) ===
    ready = g.define_container("READY_QUEUE", entity_type=proc_type)
    cpu0 = g.define_container("CPU0", ContainerKind.SLOT, entity_type=proc_type)
    cpu1 = g.define_container("CPU1", ContainerKind.SLOT, entity_type=proc_type)
    blocked = g.define_container("BLOCKED", entity_type=proc_type)
    terminated = g.define_container("TERMINATED", entity_type=proc_type)

    # === Signal Containers ===
    timer_expired = g.define_container("TIMER_EXPIRED", entity_type=signal_type)
    io_complete = g.define_container("IO_COMPLETE", entity_type=signal_type)
    signal_done = g.define_container("SIGNAL_DONE", entity_type=signal_type)

    # === Operation Set (valid moves) ===
    g.define_move("schedule",
        from_containers=[ready],
        to_containers=[cpu0, cpu1],
        entity_type=proc_type)

    g.define_move("preempt",
        from_containers=[cpu0, cpu1],
        to_containers=[ready],
        entity_type=proc_type)

    g.define_move("block",
        from_containers=[cpu0, cpu1],
        to_containers=[blocked],
        entity_type=proc_type)

    g.define_move("unblock",
        from_containers=[blocked],
        to_containers=[ready],
        entity_type=proc_type)

    g.define_move("exit_process",
        from_containers=[cpu0, cpu1],
        to_containers=[terminated],
        entity_type=proc_type)

    g.define_move("consume_signal",
        from_containers=[timer_expired, io_complete],
        to_containers=[signal_done],
        entity_type=signal_type)

    # === Create Processes ===
    p_init = g.create_entity(proc_type, "init", ready)
    p_shell = g.create_entity(proc_type, "shell", ready)
    p_daemon = g.create_entity(proc_type, "daemon", ready)

    cpus = [cpu0, cpu1]

    # === TENSIONS (the scheduler's brain) ===

    # Tension 1: Schedule — if a CPU is idle and READY has processes, schedule one
    def tension_schedule(graph):
        moves = []
        ready_procs = sorted(graph.contents_of(ready))  # Deterministic order
        if not ready_procs:
            return []
        
        proc_idx = 0
        for cpu_id in cpus:
            cpu = graph.containers[cpu_id]
            if cpu.is_empty() and proc_idx < len(ready_procs):
                moves.append(IntendedMove("schedule", ready_procs[proc_idx], cpu_id))
                proc_idx += 1
        return moves

    g.define_tension("schedule_ready", tension_schedule, priority=10)

    # Tension 2: Timer preemption — when timer expires, preempt running process
    def tension_timer_preempt(graph):
        timer_signals = list(graph.contents_of(timer_expired))
        if not timer_signals:
            return []
        
        moves = []
        # Consume the signal
        moves.append(IntendedMove("consume_signal", timer_signals[0], signal_done))
        
        # Preempt CPU0's process (simple round-robin)
        cpu0_procs = list(graph.contents_of(cpu0))
        if cpu0_procs:
            moves.append(IntendedMove("preempt", cpu0_procs[0], ready))
        
        return moves

    g.define_tension("timer_preempt", tension_timer_preempt, priority=5)

    # Tension 3: I/O completion — unblock waiting processes
    def tension_io_complete(graph):
        io_signals = list(graph.contents_of(io_complete))
        if not io_signals:
            return []
        
        moves = []
        # Consume the signal
        moves.append(IntendedMove("consume_signal", io_signals[0], signal_done))
        
        # Unblock first blocked process
        blocked_procs = sorted(graph.contents_of(blocked))
        if blocked_procs:
            moves.append(IntendedMove("unblock", blocked_procs[0], ready))
        
        return moves

    g.define_tension("io_unblock", tension_io_complete, priority=5)

    return g, {
        'proc_type': proc_type,
        'signal_type': signal_type,
        'ready': ready,
        'cpu0': cpu0,
        'cpu1': cpu1,
        'blocked': blocked,
        'terminated': terminated,
        'timer_expired': timer_expired,
        'io_complete': io_complete,
        'signal_done': signal_done,
        'p_init': p_init,
        'p_shell': p_shell,
        'p_daemon': p_daemon,
    }


def show_state(g, ids, label=""):
    """Print current process locations."""
    if label:
        print(f"\n  --- {label} ---")
    
    for name in ['p_init', 'p_shell', 'p_daemon']:
        eid = ids[name]
        loc = g.where_is_named(eid)
        print(f"    {g.entities[eid].name:10s} -> {loc}")


def main():
    print("=" * 60)
    print("  HERB Autonomous Process Scheduler")
    print("  The system runs itself. External code only sends signals.")
    print("=" * 60)

    g, ids = build_scheduler()

    # === BOOT ===
    print("\n>>> BOOT: run() — tensions fill idle CPUs")
    total = g.run()
    print(f"  Moves executed: {total}")
    show_state(g, ids, "After boot")

    # === Timer preemption ===
    print("\n>>> SIGNAL: Timer expired (round-robin preemption)")
    timer_sig = g.create_entity(ids['signal_type'], "timer_1", ids['timer_expired'])
    total = g.run()
    print(f"  Moves executed: {total}")
    show_state(g, ids, "After timer preemption")

    # === Block shell for I/O ===
    print("\n>>> Block shell for I/O")
    op = g.move("block", ids['p_shell'], ids['blocked'], cause='io_request')
    total = g.run()
    print(f"  Tension moves: {total}")
    show_state(g, ids, "After shell blocked")

    # === I/O complete ===
    print("\n>>> SIGNAL: I/O complete (unblock shell)")
    io_sig = g.create_entity(ids['signal_type'], "io_1", ids['io_complete'])
    total = g.run()
    print(f"  Moves executed: {total}")
    show_state(g, ids, "After I/O complete")

    # === Another timer ===
    print("\n>>> SIGNAL: Timer expired again")
    timer_sig2 = g.create_entity(ids['signal_type'], "timer_2", ids['timer_expired'])
    total = g.run()
    print(f"  Moves executed: {total}")
    show_state(g, ids, "After second timer")

    # === Summary ===
    print(f"\n{'='*60}")
    print(f"  Total operations: {len(g.operations)}")
    print(f"  Tensions defined: {len(g.tensions)}")
    print(f"  ALL scheduling was autonomous — no external scheduler logic.")
    print(f"{'='*60}")

    # === Provenance ===
    print("\n  Provenance for 'init':")
    for op in g.why(ids['p_init']):
        from_c = op.params.get('from_container')
        to_c = op.params.get('to_container')
        from_name = g.containers[from_c].name if from_c else '?'
        to_name = g.containers[to_c].name
        print(f"    [{op.op_type}] {from_name} -> {to_name} (cause: {op.cause})")


if __name__ == "__main__":
    main()
