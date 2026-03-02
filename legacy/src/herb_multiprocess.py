"""
HERB Multi-Process OS Demo — Scoped Containers + Property Mutation

This is the proof that HERB can model real OS concepts:
- Each process has its own FD table (scoped containers)
- FDs can be opened/closed within a process's scope
- A timer tension decrements each running process's time_slice
- When time_slice hits 0, the process is preempted
- Process isolation is STRUCTURAL: process A literally cannot
  touch process B's FDs — the operation doesn't exist

Key features exercised:
- Scoped containers (entity_type.scoped_containers)
- Scoped moves (scoped_from / scoped_to)
- Scoped match clauses (in: {"scope": "proc", "container": "..."})
- Scoped emit clauses (to: {"scope": "proc", "container": "..."})
- Property mutation (set emit for time_slice countdown)
- Property-aware matching (where clause for time_slice <= 0)
- Priority scheduling (max_by priority)

This is NOT a toy scheduler with a global queue. Each process is
an isolated world with its own resources.
"""

MULTI_PROCESS_OS = {
    # =====================================================================
    # ENTITY TYPES
    #
    # Process has scoped containers — each Process entity gets its own
    # isolated FD_FREE and FD_OPEN containers. No other entity can
    # access them. The isolation is structural, not checked.
    # =====================================================================
    "entity_types": [
        {"name": "Process", "scoped_containers": [
            {"name": "FD_FREE", "kind": "simple", "entity_type": "FileDescriptor"},
            {"name": "FD_OPEN", "kind": "simple", "entity_type": "FileDescriptor"},
        ]},
        {"name": "FileDescriptor"},
        {"name": "Signal"},
    ],

    # =====================================================================
    # CONTAINERS — global scheduling state
    # =====================================================================
    "containers": [
        {"name": "READY_QUEUE", "kind": "simple", "entity_type": "Process"},
        {"name": "CPU0",        "kind": "slot",   "entity_type": "Process"},
        {"name": "BLOCKED",     "kind": "simple", "entity_type": "Process"},
        {"name": "TERMINATED",  "kind": "simple", "entity_type": "Process"},

        # Signal containers
        {"name": "TICK_SIGNAL",    "kind": "simple", "entity_type": "Signal"},
        {"name": "OPEN_REQUEST",   "kind": "simple", "entity_type": "Signal"},
        {"name": "CLOSE_REQUEST",  "kind": "simple", "entity_type": "Signal"},
        {"name": "SIGNAL_DONE",    "kind": "simple", "entity_type": "Signal"},
    ],

    # =====================================================================
    # MOVES — the operation set
    #
    # Regular moves for process scheduling.
    # Scoped moves for FD operations within a process's namespace.
    # =====================================================================
    "moves": [
        # Process scheduling (regular moves)
        {"name": "schedule",
         "from": ["READY_QUEUE"], "to": ["CPU0"],
         "entity_type": "Process"},

        {"name": "preempt",
         "from": ["CPU0"], "to": ["READY_QUEUE"],
         "entity_type": "Process"},

        {"name": "block_process",
         "from": ["CPU0"], "to": ["BLOCKED"],
         "entity_type": "Process"},

        {"name": "unblock",
         "from": ["BLOCKED"], "to": ["READY_QUEUE"],
         "entity_type": "Process"},

        {"name": "terminate",
         "from": ["CPU0"], "to": ["TERMINATED"],
         "entity_type": "Process"},

        # FD operations (SCOPED — within a process's own containers)
        # The runtime ensures source and target belong to the same
        # entity. Cross-process FD operations don't exist.
        {"name": "open_fd",
         "scoped_from": ["FD_FREE"], "scoped_to": ["FD_OPEN"],
         "entity_type": "FileDescriptor"},

        {"name": "close_fd",
         "scoped_from": ["FD_OPEN"], "scoped_to": ["FD_FREE"],
         "entity_type": "FileDescriptor"},

        # Signal processing
        {"name": "consume_signal",
         "from": ["TICK_SIGNAL", "OPEN_REQUEST", "CLOSE_REQUEST"],
         "to": ["SIGNAL_DONE"],
         "entity_type": "Signal"},
    ],

    # =====================================================================
    # TENSIONS — the energy gradients
    # =====================================================================
    "tensions": [
        # -----------------------------------------------------------------
        # SCHEDULE: Fill CPU with highest-priority ready process
        # -----------------------------------------------------------------
        {
            "name": "schedule_ready",
            "priority": 10,
            "match": [
                {"bind": "proc", "in": "READY_QUEUE",
                 "select": "max_by", "key": "priority"},
                {"bind": "cpu", "empty_in": ["CPU0"], "select": "first"},
            ],
            "emit": [
                {"move": "schedule", "entity": "proc", "to": "cpu"},
            ],
        },

        # -----------------------------------------------------------------
        # TIMER TICK: Decrement time_slice for running process
        #
        # When a tick signal arrives, decrement the running process's
        # time_slice. Property mutation: this is a non-conserved property
        # so "set" is the right mechanism (not transfer).
        # -----------------------------------------------------------------
        {
            "name": "timer_tick",
            "priority": 20,
            "match": [
                {"bind": "sig", "in": "TICK_SIGNAL", "select": "first"},
                {"bind": "proc", "in": "CPU0", "select": "first",
                 "required": False},
            ],
            "emit": [
                {"set": "proc", "property": "time_slice",
                 "value": {"op": "-",
                           "left": {"prop": "time_slice", "of": "proc"},
                           "right": 1}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIGNAL_DONE"},
            ],
        },

        # -----------------------------------------------------------------
        # PREEMPT EXPIRED: When time_slice <= 0, preempt and reset
        #
        # The where clause filters to only match if time_slice <= 0.
        # The set resets time_slice for the next scheduling round.
        # -----------------------------------------------------------------
        {
            "name": "preempt_expired",
            "priority": 15,
            "match": [
                {"bind": "proc", "in": "CPU0", "select": "first",
                 "where": {"op": "<=",
                           "left": {"prop": "time_slice", "of": "proc"},
                           "right": 0}},
            ],
            "emit": [
                {"move": "preempt", "entity": "proc", "to": "READY_QUEUE"},
                {"set": "proc", "property": "time_slice", "value": 3},
            ],
        },

        # -----------------------------------------------------------------
        # OPEN FD: For running process, open an FD from its own table
        #
        # THE PROOF OF ISOLATION: "proc" is bound to the process on CPU0.
        # The scoped match {"scope": "proc", "container": "FD_FREE"}
        # resolves to THAT process's FD_FREE container. There is NO WAY
        # to reference another process's containers. The isolation is
        # not enforced by checks — it's structural.
        # -----------------------------------------------------------------
        {
            "name": "fd_open",
            "priority": 12,
            "match": [
                {"bind": "sig", "in": "OPEN_REQUEST", "select": "first"},
                {"bind": "proc", "in": "CPU0", "select": "first"},
                {"bind": "fd", "in": {"scope": "proc", "container": "FD_FREE"},
                 "select": "first"},
            ],
            "emit": [
                {"move": "open_fd", "entity": "fd",
                 "to": {"scope": "proc", "container": "FD_OPEN"}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIGNAL_DONE"},
            ],
        },

        # -----------------------------------------------------------------
        # CLOSE FD: For running process, close an FD back to its table
        # -----------------------------------------------------------------
        {
            "name": "fd_close",
            "priority": 12,
            "match": [
                {"bind": "sig", "in": "CLOSE_REQUEST", "select": "first"},
                {"bind": "proc", "in": "CPU0", "select": "first"},
                {"bind": "fd", "in": {"scope": "proc", "container": "FD_OPEN"},
                 "select": "first"},
            ],
            "emit": [
                {"move": "close_fd", "entity": "fd",
                 "to": {"scope": "proc", "container": "FD_FREE"}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIGNAL_DONE"},
            ],
        },
    ],

    # =====================================================================
    # ENTITIES
    #
    # Processes are created first (so their scoped containers exist).
    # FDs are then placed in process-scoped containers.
    # =====================================================================
    "entities": [
        # Processes (with priority and time_slice properties)
        {"name": "proc_A", "type": "Process", "in": "READY_QUEUE",
         "properties": {"priority": 5, "time_slice": 3}},
        {"name": "proc_B", "type": "Process", "in": "READY_QUEUE",
         "properties": {"priority": 3, "time_slice": 3}},

        # Process A's file descriptors (in A's scoped FD_FREE)
        {"name": "fd0_A", "type": "FileDescriptor",
         "in": {"scope": "proc_A", "container": "FD_FREE"}},
        {"name": "fd1_A", "type": "FileDescriptor",
         "in": {"scope": "proc_A", "container": "FD_FREE"}},
        {"name": "fd2_A", "type": "FileDescriptor",
         "in": {"scope": "proc_A", "container": "FD_FREE"}},

        # Process B's file descriptors (in B's scoped FD_FREE)
        {"name": "fd0_B", "type": "FileDescriptor",
         "in": {"scope": "proc_B", "container": "FD_FREE"}},
        {"name": "fd1_B", "type": "FileDescriptor",
         "in": {"scope": "proc_B", "container": "FD_FREE"}},
    ],
}
