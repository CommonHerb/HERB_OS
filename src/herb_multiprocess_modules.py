"""
HERB Multi-Process OS — Modular Decomposition

The monolithic herb_multiprocess.py split into two independent modules:
  1. scheduler — Process scheduling, time slicing, preemption
  2. fd_manager — File descriptor management (scoped per-process)

Composed back into an identical-behavior system. This is the acid test:
composition must be lossless. Same tests pass, same demo output.
"""


# =====================================================================
# MODULE 1: SCHEDULER
#
# Owns: Process, Signal entity types
#       Scheduling containers and moves
#       Timer and preemption tensions
# =====================================================================

SCHEDULER_MODULE = {
    "module": "scheduler",

    "exports": [
        "Process", "Signal",
        "READY_QUEUE", "CPU0", "BLOCKED", "TERMINATED",
        "schedule", "preempt", "block_process", "unblock", "terminate",
        "TICK_SIGNAL", "OPEN_REQUEST", "CLOSE_REQUEST", "SIGNAL_DONE",
        "consume_signal",
    ],

    "imports": [],

    "entity_types": [
        {"name": "Process"},
        {"name": "Signal"},
    ],

    "containers": [
        {"name": "READY_QUEUE", "kind": "simple", "entity_type": "Process"},
        {"name": "CPU0",        "kind": "slot",   "entity_type": "Process"},
        {"name": "BLOCKED",     "kind": "simple", "entity_type": "Process"},
        {"name": "TERMINATED",  "kind": "simple", "entity_type": "Process"},

        {"name": "TICK_SIGNAL",    "kind": "simple", "entity_type": "Signal"},
        {"name": "OPEN_REQUEST",   "kind": "simple", "entity_type": "Signal"},
        {"name": "CLOSE_REQUEST",  "kind": "simple", "entity_type": "Signal"},
        {"name": "SIGNAL_DONE",    "kind": "simple", "entity_type": "Signal"},
    ],

    "moves": [
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

        {"name": "consume_signal",
         "from": ["TICK_SIGNAL", "OPEN_REQUEST", "CLOSE_REQUEST"],
         "to": ["SIGNAL_DONE"],
         "entity_type": "Signal"},
    ],

    "tensions": [
        # Schedule highest-priority ready process
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

        # Timer tick: decrement time_slice
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

        # Preempt expired time slice
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
    ],
}


# =====================================================================
# MODULE 2: FD MANAGER
#
# Owns: FileDescriptor entity type
#       FD scoped containers (extensions on Process)
#       FD open/close moves and tensions
#
# Imports: Process, CPU0, signal containers, consume_signal from scheduler
# =====================================================================

FD_MANAGER_MODULE = {
    "module": "fd_manager",

    "exports": [
        "FileDescriptor",
        "FD_FREE", "FD_OPEN",
        "open_fd", "close_fd",
    ],

    "imports": [
        "scheduler.Process",
        "scheduler.CPU0",
        "scheduler.OPEN_REQUEST",
        "scheduler.CLOSE_REQUEST",
        "scheduler.SIGNAL_DONE",
        "scheduler.consume_signal",
    ],

    "entity_types": [
        {"name": "FileDescriptor"},
    ],

    "entity_type_extensions": [
        {"extend": "Process", "add_scoped_containers": [
            {"name": "FD_FREE", "kind": "simple",
             "entity_type": "FileDescriptor"},
            {"name": "FD_OPEN", "kind": "simple",
             "entity_type": "FileDescriptor"},
        ]},
    ],

    "containers": [],

    "moves": [
        {"name": "open_fd",
         "scoped_from": ["FD_FREE"], "scoped_to": ["FD_OPEN"],
         "entity_type": "FileDescriptor"},

        {"name": "close_fd",
         "scoped_from": ["FD_OPEN"], "scoped_to": ["FD_FREE"],
         "entity_type": "FileDescriptor"},
    ],

    "tensions": [
        # Open FD: running process opens an FD from its own table
        {
            "name": "fd_open",
            "priority": 12,
            "match": [
                {"bind": "sig", "in": "OPEN_REQUEST", "select": "first"},
                {"bind": "proc", "in": "CPU0", "select": "first"},
                {"bind": "fd",
                 "in": {"scope": "proc", "container": "FD_FREE"},
                 "select": "first"},
            ],
            "emit": [
                {"move": "open_fd", "entity": "fd",
                 "to": {"scope": "proc", "container": "FD_OPEN"}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIGNAL_DONE"},
            ],
        },

        # Close FD: running process closes an FD
        {
            "name": "fd_close",
            "priority": 12,
            "match": [
                {"bind": "sig", "in": "CLOSE_REQUEST", "select": "first"},
                {"bind": "proc", "in": "CPU0", "select": "first"},
                {"bind": "fd",
                 "in": {"scope": "proc", "container": "FD_OPEN"},
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
}


# =====================================================================
# COMPOSITION: The complete multi-process OS
# =====================================================================

COMPOSED_MULTIPROCESS = {
    "compose": ["scheduler", "fd_manager"],
    "modules": [SCHEDULER_MODULE, FD_MANAGER_MODULE],

    "entities": [
        # Processes
        {"name": "proc_A", "type": "scheduler.Process",
         "in": "scheduler.READY_QUEUE",
         "properties": {"priority": 5, "time_slice": 3}},
        {"name": "proc_B", "type": "scheduler.Process",
         "in": "scheduler.READY_QUEUE",
         "properties": {"priority": 3, "time_slice": 3}},

        # Process A's file descriptors
        {"name": "fd0_A", "type": "fd_manager.FileDescriptor",
         "in": {"scope": "proc_A", "container": "FD_FREE"}},
        {"name": "fd1_A", "type": "fd_manager.FileDescriptor",
         "in": {"scope": "proc_A", "container": "FD_FREE"}},
        {"name": "fd2_A", "type": "fd_manager.FileDescriptor",
         "in": {"scope": "proc_A", "container": "FD_FREE"}},

        # Process B's file descriptors
        {"name": "fd0_B", "type": "fd_manager.FileDescriptor",
         "in": {"scope": "proc_B", "container": "FD_FREE"}},
        {"name": "fd1_B", "type": "fd_manager.FileDescriptor",
         "in": {"scope": "proc_B", "container": "FD_FREE"}},
    ],
}
