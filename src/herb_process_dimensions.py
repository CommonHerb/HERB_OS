"""
HERB Demo: Multi-Dimensional Process Manager

Processes have TWO independent state dimensions:
  1. Scheduling (default): READY -> RUNNING -> BLOCKED -> READY
  2. Priority (named):     PRIO_LOW -> PRIO_MED -> PRIO_HIGH

Tensions:
  - Schedule the highest-priority READY process to the CPU
  - When the CPU is occupied and a higher-priority process is ready, preempt
  - Auto-promote processes that have been waiting (aging)

This demonstrates Session 32's key feature: multi-dimensional state.
A process is simultaneously in a scheduling state AND a priority level.
Moving in one dimension doesn't affect the other. Both dimensions have
structural guarantees -- invalid transitions don't exist.
"""

PROGRAM = {
    "dimensions": ["priority"],

    "entity_types": [
        {"name": "Process"},
        {"name": "Signal"},
    ],

    "containers": [
        # === Scheduling dimension (default) ===
        {"name": "READY"},
        {"name": "CPU_0", "kind": "slot", "entity_type": "Process"},
        {"name": "BLOCKED"},

        # === Priority dimension ===
        {"name": "PRIO_LOW", "dimension": "priority", "entity_type": "Process"},
        {"name": "PRIO_MED", "dimension": "priority", "entity_type": "Process"},
        {"name": "PRIO_HIGH", "dimension": "priority", "entity_type": "Process"},

        # === Signal containers ===
        {"name": "TIMER_EXPIRED"},
        {"name": "IO_COMPLETE"},
        {"name": "PROMOTE_REQUEST"},
        {"name": "SIGNAL_DONE"},
    ],

    "moves": [
        # --- Scheduling moves (default dimension) ---
        {"name": "schedule", "from": ["READY"], "to": ["CPU_0"],
         "entity_type": "Process"},
        {"name": "preempt", "from": ["CPU_0"], "to": ["READY"],
         "entity_type": "Process"},
        {"name": "block_io", "from": ["CPU_0"], "to": ["BLOCKED"],
         "entity_type": "Process"},
        {"name": "unblock", "from": ["BLOCKED"], "to": ["READY"],
         "entity_type": "Process"},

        # --- Priority moves (priority dimension) ---
        {"name": "promote_to_med", "from": ["PRIO_LOW"], "to": ["PRIO_MED"]},
        {"name": "promote_to_high", "from": ["PRIO_MED"], "to": ["PRIO_HIGH"]},
        {"name": "demote_to_med", "from": ["PRIO_HIGH"], "to": ["PRIO_MED"]},
        {"name": "demote_to_low", "from": ["PRIO_MED"], "to": ["PRIO_LOW"]},

        # --- Signal moves ---
        {"name": "consume_signal", "from": ["TIMER_EXPIRED", "IO_COMPLETE", "PROMOTE_REQUEST"],
         "to": ["SIGNAL_DONE"], "entity_type": "Signal"},
    ],

    "entities": [
        # Processes with scheduling state + priority
        {"name": "kernel_task", "type": "Process", "in": "READY",
         "also_in": {"priority": "PRIO_HIGH"},
         "properties": {"wait_ticks": 0}},
        {"name": "user_app", "type": "Process", "in": "READY",
         "also_in": {"priority": "PRIO_MED"},
         "properties": {"wait_ticks": 0}},
        {"name": "background_job", "type": "Process", "in": "READY",
         "also_in": {"priority": "PRIO_LOW"},
         "properties": {"wait_ticks": 0}},
    ],

    "tensions": [
        # === SCHEDULING TENSIONS ===

        # 1. Schedule highest-priority ready process (PRIO_HIGH)
        {
            "name": "schedule_high",
            "priority": 30,
            "match": [
                {"bind": "proc", "in": "READY",
                 "where": {"in": "PRIO_HIGH", "of": "proc"}},
                {"bind": "slot", "empty_in": ["CPU_0"]},
            ],
            "emit": [
                {"move": "schedule", "entity": "proc", "to": "slot"},
            ],
        },

        # 2. Schedule medium-priority ready process (PRIO_MED)
        {
            "name": "schedule_med",
            "priority": 20,
            "match": [
                {"bind": "proc", "in": "READY",
                 "where": {"in": "PRIO_MED", "of": "proc"}},
                {"bind": "slot", "empty_in": ["CPU_0"]},
            ],
            "emit": [
                {"move": "schedule", "entity": "proc", "to": "slot"},
            ],
        },

        # 3. Schedule low-priority ready process (PRIO_LOW)
        {
            "name": "schedule_low",
            "priority": 10,
            "match": [
                {"bind": "proc", "in": "READY",
                 "where": {"in": "PRIO_LOW", "of": "proc"}},
                {"bind": "slot", "empty_in": ["CPU_0"]},
            ],
            "emit": [
                {"move": "schedule", "entity": "proc", "to": "slot"},
            ],
        },

        # 4. Preempt: if a HIGH proc is READY but CPU is occupied by lower priority
        {
            "name": "preempt_for_high",
            "priority": 35,
            "match": [
                # There's a high-priority process waiting in READY
                {"bind": "waiting", "in": "READY",
                 "where": {"in": "PRIO_HIGH", "of": "waiting"}},
                # CPU is occupied by a non-HIGH process
                {"bind": "running", "in": "CPU_0",
                 "where": {"op": "not", "arg": {"in": "PRIO_HIGH", "of": "running"}}},
            ],
            "emit": [
                {"move": "preempt", "entity": "running", "to": "READY"},
            ],
        },

        # === SIGNAL HANDLING ===

        # 5. Timer expired -> preempt running process
        {
            "name": "handle_timer",
            "priority": 40,
            "match": [
                {"bind": "sig", "in": "TIMER_EXPIRED"},
                {"bind": "running", "in": "CPU_0"},
            ],
            "emit": [
                {"move": "preempt", "entity": "running", "to": "READY"},
                {"move": "consume_signal", "entity": "sig", "to": "SIGNAL_DONE"},
            ],
        },

        # 6. IO complete -> unblock the blocked process
        {
            "name": "handle_io",
            "priority": 40,
            "match": [
                {"bind": "sig", "in": "IO_COMPLETE"},
                {"bind": "proc", "in": "BLOCKED"},
            ],
            "emit": [
                {"move": "unblock", "entity": "proc", "to": "READY"},
                {"move": "consume_signal", "entity": "sig", "to": "SIGNAL_DONE"},
            ],
        },

        # === PRIORITY PROMOTION ===

        # 7. Promote request signal -> promote a LOW process to MED
        {
            "name": "handle_promote",
            "priority": 25,
            "match": [
                {"bind": "sig", "in": "PROMOTE_REQUEST"},
                {"bind": "proc", "in": "PRIO_LOW"},
            ],
            "emit": [
                {"move": "promote_to_med", "entity": "proc", "to": "PRIO_MED"},
                {"move": "consume_signal", "entity": "sig", "to": "SIGNAL_DONE"},
            ],
        },
    ],
}


def run_demo():
    """Run the multi-dimensional process manager demo."""
    from herb_program import HerbProgram

    print("=" * 70)
    print("HERB Demo: Multi-Dimensional Process Manager")
    print("=" * 70)
    print()
    print("Processes have TWO independent state dimensions:")
    print("  Scheduling: READY -> RUNNING -> BLOCKED -> READY")
    print("  Priority:   PRIO_LOW -> PRIO_MED -> PRIO_HIGH")
    print()

    prog = HerbProgram(PROGRAM)
    g = prog.load()

    def show_state(label):
        print(f"\n--- {label} ---")
        for name in ["kernel_task", "user_app", "background_job"]:
            eid = prog.entity_id(name)
            sched = prog.where_is(name)
            prio = g.where_is_in_named(eid, "priority")
            print(f"  {name:20s}  sched={sched:10s}  prio={prio}")

    show_state("Initial State (all READY)")

    # Phase 1: Initial scheduling
    print("\n>>> Phase 1: Run to equilibrium")
    ops = g.run()
    print(f"    {ops} operations executed")
    show_state("After initial scheduling")
    # kernel_task should be on CPU (highest priority)

    # Phase 2: Timer expires -> preempt and reschedule
    print("\n>>> Phase 2: Timer expires (preempt + reschedule)")
    timer_sig = prog.create_entity("timer_1", "Signal", "TIMER_EXPIRED")
    ops = g.run()
    print(f"    {ops} operations executed")
    show_state("After timer preemption")
    # kernel_task preempted -> goes to READY -> re-scheduled (still highest prio)

    # Phase 3: kernel blocks on IO
    print("\n>>> Phase 3: kernel_task does blocking I/O")
    kid = prog.entity_id("kernel_task")
    blocked = prog.container_id("BLOCKED")
    g.move("block_io", kid, blocked)
    ops = g.run()
    print(f"    {ops} operations executed")
    show_state("After kernel blocks")
    # CPU freed -> user_app scheduled (PRIO_MED > PRIO_LOW)

    # Phase 4: Promote background_job from LOW to MED
    print("\n>>> Phase 4: Promote background_job (LOW -> MED)")
    promo_sig = prog.create_entity("promo_1", "Signal", "PROMOTE_REQUEST")
    ops = g.run()
    print(f"    {ops} operations executed")
    show_state("After promotion")
    # background_job now PRIO_MED

    # Phase 5: IO completes -> kernel unblocked -> preemption cascade
    print("\n>>> Phase 5: IO completes (kernel unblocked)")
    io_sig = prog.create_entity("io_1", "Signal", "IO_COMPLETE")
    ops = g.run()
    print(f"    {ops} operations executed")
    show_state("After IO completion")
    # kernel unblocked -> READY -> preempts user_app (kernel is PRIO_HIGH)

    # Summary
    print("\n" + "=" * 70)
    print("KEY INSIGHT: Scheduling state and priority are INDEPENDENT dimensions.")
    print("Moving kernel from RUNNING->BLOCKED didn't change its priority (PRIO_HIGH).")
    print("Promoting background_job to PRIO_MED didn't change its scheduling (READY).")
    print("Each dimension has its own structural guarantees -- invalid transitions")
    print("don't exist in either dimension.")
    print(f"\nTotal operations logged: {len(g.operations)}")
    print("=" * 70)


if __name__ == "__main__":
    run_demo()
