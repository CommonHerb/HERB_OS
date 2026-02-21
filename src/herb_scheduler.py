"""
HERB Scheduler Program — Pure Data

This is the autonomous process scheduler from demo_scheduler.py,
expressed as a HERB program. No Python callables. No arbitrary code.
Just a data structure that declares what exists, what can happen,
and what the system wants.

The runtime interprets this structure and produces the same behavior
as the hand-coded Python version.

This is the proof that HERB is a language, not a library.
"""

SCHEDULER = {
    # =====================================================================
    # ENTITY TYPES — what kinds of things exist
    # =====================================================================
    "entity_types": [
        {"name": "Process"},
        {"name": "Signal"},
    ],

    # =====================================================================
    # CONTAINERS — where things can be
    #
    # For state machines, states ARE containers. A process being READY
    # means the process entity is IN the READY_QUEUE container.
    # =====================================================================
    "containers": [
        # Process states
        {"name": "READY_QUEUE", "kind": "simple", "entity_type": "Process"},
        {"name": "CPU0",        "kind": "slot",   "entity_type": "Process"},
        {"name": "CPU1",        "kind": "slot",   "entity_type": "Process"},
        {"name": "BLOCKED",     "kind": "simple", "entity_type": "Process"},
        {"name": "TERMINATED",  "kind": "simple", "entity_type": "Process"},

        # Signal containers
        {"name": "TIMER_EXPIRED", "kind": "simple", "entity_type": "Signal"},
        {"name": "IO_COMPLETE",   "kind": "simple", "entity_type": "Signal"},
        {"name": "SIGNAL_DONE",   "kind": "simple", "entity_type": "Signal"},
    ],

    # =====================================================================
    # MOVES — the operation set
    #
    # This IS the constraint system. If a transition isn't here,
    # it doesn't exist. Not "fails" — doesn't exist.
    # =====================================================================
    "moves": [
        {"name": "schedule",
         "from": ["READY_QUEUE"],
         "to": ["CPU0", "CPU1"],
         "entity_type": "Process"},

        {"name": "preempt",
         "from": ["CPU0", "CPU1"],
         "to": ["READY_QUEUE"],
         "entity_type": "Process"},

        {"name": "block",
         "from": ["CPU0", "CPU1"],
         "to": ["BLOCKED"],
         "entity_type": "Process"},

        {"name": "unblock",
         "from": ["BLOCKED"],
         "to": ["READY_QUEUE"],
         "entity_type": "Process"},

        {"name": "exit_process",
         "from": ["CPU0", "CPU1"],
         "to": ["TERMINATED"],
         "entity_type": "Process"},

        {"name": "consume_signal",
         "from": ["TIMER_EXPIRED", "IO_COMPLETE"],
         "to": ["SIGNAL_DONE"],
         "entity_type": "Signal"},
    ],

    # =====================================================================
    # TENSIONS — the energy gradients
    #
    # Each tension declares: when this pattern matches, emit these moves.
    # The runtime resolves all tensions to fixpoint (equilibrium).
    # Tensions can ONLY trigger moves in the operation set above.
    #
    # Match clauses query graph state. Emit clauses produce moves.
    # No Python. No lambdas. Just patterns and actions.
    # =====================================================================
    "tensions": [
        # -----------------------------------------------------------------
        # SCHEDULE: Fill idle CPUs with ready processes
        #
        # Pattern: processes waiting in READY + empty CPU slots
        # Action: move each ready process to an empty CPU (paired by zip)
        # -----------------------------------------------------------------
        {
            "name": "schedule_ready",
            "priority": 10,
            "match": [
                {"bind": "proc", "in": "READY_QUEUE", "select": "each"},
                {"bind": "cpu",  "empty_in": ["CPU0", "CPU1"], "select": "each"},
            ],
            "pair": "zip",
            "emit": [
                {"move": "schedule", "entity": "proc", "to": "cpu"},
            ],
        },

        # -----------------------------------------------------------------
        # TIMER PREEMPTION: When timer expires, preempt CPU0
        #
        # Pattern: signal in TIMER_EXPIRED, optionally a process on CPU0
        # Action: consume signal + preempt CPU0 process (if present)
        #
        # The CPU0 match is optional (required: false). If CPU0 is empty,
        # the signal is still consumed but no preemption happens.
        # -----------------------------------------------------------------
        {
            "name": "timer_preempt",
            "priority": 5,
            "match": [
                {"bind": "sig",  "in": "TIMER_EXPIRED", "select": "first"},
                {"bind": "proc", "in": "CPU0", "select": "first", "required": False},
            ],
            "emit": [
                {"move": "consume_signal", "entity": "sig", "to": "SIGNAL_DONE"},
                {"move": "preempt", "entity": "proc", "to": "READY_QUEUE"},
            ],
        },

        # -----------------------------------------------------------------
        # I/O COMPLETION: When I/O completes, unblock a process
        #
        # Pattern: signal in IO_COMPLETE, optionally a blocked process
        # Action: consume signal + unblock process (if present)
        # -----------------------------------------------------------------
        {
            "name": "io_unblock",
            "priority": 5,
            "match": [
                {"bind": "sig",  "in": "IO_COMPLETE", "select": "first"},
                {"bind": "proc", "in": "BLOCKED", "select": "first", "required": False},
            ],
            "emit": [
                {"move": "consume_signal", "entity": "sig",  "to": "SIGNAL_DONE"},
                {"move": "unblock",        "entity": "proc", "to": "READY_QUEUE"},
            ],
        },
    ],

    # =====================================================================
    # INITIAL ENTITIES — the starting state of the world
    # =====================================================================
    "entities": [
        {"name": "init",   "type": "Process", "in": "READY_QUEUE"},
        {"name": "shell",  "type": "Process", "in": "READY_QUEUE"},
        {"name": "daemon", "type": "Process", "in": "READY_QUEUE"},
    ],
}
