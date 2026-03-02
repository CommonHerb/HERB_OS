"""
HERB Priority Scheduler — Pure Data

The original scheduler (herb_scheduler.py) is FIFO — first process in
READY_QUEUE gets scheduled first. This is because it used "select": "first"
which picks the entity with the lowest ID.

This scheduler uses "select": "max_by" with "key": "priority" to schedule
the HIGHEST PRIORITY ready process first. This is impossible without
entity properties and property-aware matching.

Same structure as the original scheduler. Same moves. Same signals.
The ONLY difference: the schedule_ready tension selects by priority
instead of FIFO. This is where HERB's expression system proves its worth.
"""

PRIORITY_SCHEDULER = {
    "entity_types": [
        {"name": "Process"},
        {"name": "Signal"},
    ],

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

    "tensions": [
        # -----------------------------------------------------------------
        # SCHEDULE: Fill idle CPUs with HIGHEST PRIORITY ready process
        #
        # THE KEY DIFFERENCE from the FIFO scheduler:
        # "select": "max_by", "key": "priority"
        #
        # This picks the entity with the highest "priority" property value.
        # If two processes have equal priority, the one with the lower
        # entity ID wins (deterministic).
        #
        # We select one process (max_by → scalar) and one CPU (first empty).
        # If both match, schedule it. The tension fires again each step
        # until all CPUs are filled or no ready processes remain.
        # -----------------------------------------------------------------
        {
            "name": "schedule_ready",
            "priority": 10,
            "match": [
                {"bind": "proc", "in": "READY_QUEUE",
                 "select": "max_by", "key": "priority"},
                {"bind": "cpu",  "empty_in": ["CPU0", "CPU1"],
                 "select": "first"},
            ],
            "emit": [
                {"move": "schedule", "entity": "proc", "to": "cpu"},
            ],
        },

        # Timer preemption (same as FIFO scheduler)
        {
            "name": "timer_preempt",
            "priority": 5,
            "match": [
                {"bind": "sig",  "in": "TIMER_EXPIRED", "select": "first"},
                {"bind": "proc", "in": "CPU0", "select": "first",
                 "required": False},
            ],
            "emit": [
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIGNAL_DONE"},
                {"move": "preempt", "entity": "proc",
                 "to": "READY_QUEUE"},
            ],
        },

        # I/O completion (same as FIFO scheduler)
        {
            "name": "io_unblock",
            "priority": 5,
            "match": [
                {"bind": "sig",  "in": "IO_COMPLETE", "select": "first"},
                {"bind": "proc", "in": "BLOCKED", "select": "first",
                 "required": False},
            ],
            "emit": [
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIGNAL_DONE"},
                {"move": "unblock", "entity": "proc",
                 "to": "READY_QUEUE"},
            ],
        },
    ],

    # -----------------------------------------------------------------
    # ENTITIES — processes with PRIORITY values
    #
    # daemon has highest priority (10), shell medium (5), init lowest (1).
    # With FIFO scheduling, init would be scheduled first (lowest ID).
    # With PRIORITY scheduling, daemon should be scheduled first.
    # -----------------------------------------------------------------
    "entities": [
        {"name": "init",   "type": "Process", "in": "READY_QUEUE",
         "properties": {"priority": 1}},
        {"name": "shell",  "type": "Process", "in": "READY_QUEUE",
         "properties": {"priority": 5}},
        {"name": "daemon", "type": "Process", "in": "READY_QUEUE",
         "properties": {"priority": 10}},
    ],
}
