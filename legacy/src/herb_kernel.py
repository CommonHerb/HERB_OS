"""
HERB Four-Module Kernel — Composition Demo

Four independent modules composed into a working kernel:
  1. proc — Process lifecycle and scheduling
  2. mem  — Per-process memory page allocation
  3. fs   — Per-process file descriptor management
  4. ipc  — Inter-process message passing via channels

This would be impractical as a monolith (~500 lines as a single dict).
As modules, each is independently testable and clearly bounded.

Cross-module interactions:
  - mem, fs, ipc all extend the Process entity type with scoped containers
  - mem, fs, ipc tensions reference proc's CPU0 to find the running process
  - ipc uses channels defined at composition level
  - All signal handling flows through proc's signal infrastructure
"""


# =====================================================================
# MODULE 1: PROC — Process Lifecycle
# =====================================================================

PROC_MODULE = {
    "module": "proc",

    "exports": [
        "Process", "Signal",
        "READY", "CPU0", "BLOCKED", "TERMINATED",
        "schedule", "preempt", "block_proc", "unblock", "terminate",
        "TIMER_SIG", "ALLOC_SIG", "FREE_SIG",
        "OPEN_SIG", "CLOSE_SIG",
        "SEND_SIG", "RECV_SIG",
        "SIG_DONE",
        "consume_signal",
    ],

    "imports": [],

    "entity_types": [
        {"name": "Process"},
        {"name": "Signal"},
    ],

    "containers": [
        {"name": "READY",      "kind": "simple", "entity_type": "Process"},
        {"name": "CPU0",       "kind": "slot",   "entity_type": "Process"},
        {"name": "BLOCKED",    "kind": "simple", "entity_type": "Process"},
        {"name": "TERMINATED", "kind": "simple", "entity_type": "Process"},

        # Signal containers
        {"name": "TIMER_SIG",  "kind": "simple", "entity_type": "Signal"},
        {"name": "ALLOC_SIG",  "kind": "simple", "entity_type": "Signal"},
        {"name": "FREE_SIG",   "kind": "simple", "entity_type": "Signal"},
        {"name": "OPEN_SIG",   "kind": "simple", "entity_type": "Signal"},
        {"name": "CLOSE_SIG",  "kind": "simple", "entity_type": "Signal"},
        {"name": "SEND_SIG",   "kind": "simple", "entity_type": "Signal"},
        {"name": "RECV_SIG",   "kind": "simple", "entity_type": "Signal"},
        {"name": "SIG_DONE",   "kind": "simple", "entity_type": "Signal"},
    ],

    "moves": [
        {"name": "schedule",
         "from": ["READY"], "to": ["CPU0"],
         "entity_type": "Process"},

        {"name": "preempt",
         "from": ["CPU0"], "to": ["READY"],
         "entity_type": "Process"},

        {"name": "block_proc",
         "from": ["CPU0"], "to": ["BLOCKED"],
         "entity_type": "Process"},

        {"name": "unblock",
         "from": ["BLOCKED"], "to": ["READY"],
         "entity_type": "Process"},

        {"name": "terminate",
         "from": ["CPU0"], "to": ["TERMINATED"],
         "entity_type": "Process"},

        {"name": "consume_signal",
         "from": ["TIMER_SIG", "ALLOC_SIG", "FREE_SIG",
                  "OPEN_SIG", "CLOSE_SIG", "SEND_SIG", "RECV_SIG"],
         "to": ["SIG_DONE"],
         "entity_type": "Signal"},
    ],

    "tensions": [
        # Schedule highest-priority ready process
        {
            "name": "schedule_ready",
            "priority": 10,
            "match": [
                {"bind": "proc", "in": "READY",
                 "select": "max_by", "key": "priority"},
                {"bind": "cpu", "empty_in": ["CPU0"]},
            ],
            "emit": [
                {"move": "schedule", "entity": "proc", "to": "cpu"},
            ],
        },

        # Timer: decrement time_slice and preempt when expired
        {
            "name": "timer_tick",
            "priority": 20,
            "match": [
                {"bind": "sig", "in": "TIMER_SIG"},
                {"bind": "proc", "in": "CPU0", "required": False},
            ],
            "emit": [
                {"set": "proc", "property": "time_slice",
                 "value": {"op": "-",
                           "left": {"prop": "time_slice", "of": "proc"},
                           "right": 1}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIG_DONE"},
            ],
        },

        {
            "name": "preempt_expired",
            "priority": 15,
            "match": [
                {"bind": "proc", "in": "CPU0",
                 "where": {"op": "<=",
                           "left": {"prop": "time_slice", "of": "proc"},
                           "right": 0}},
            ],
            "emit": [
                {"move": "preempt", "entity": "proc", "to": "READY"},
                {"set": "proc", "property": "time_slice", "value": 3},
            ],
        },
    ],
}


# =====================================================================
# MODULE 2: MEM — Memory Page Management
# =====================================================================

MEM_MODULE = {
    "module": "mem",

    "exports": [
        "Page",
        "MEM_FREE", "MEM_USED",
        "alloc_page", "free_page",
    ],

    "imports": [
        "proc.Process",
        "proc.CPU0",
        "proc.ALLOC_SIG",
        "proc.FREE_SIG",
        "proc.SIG_DONE",
        "proc.consume_signal",
    ],

    "entity_types": [
        {"name": "Page"},
    ],

    "entity_type_extensions": [
        {"extend": "Process", "add_scoped_containers": [
            {"name": "MEM_FREE", "kind": "simple", "entity_type": "Page"},
            {"name": "MEM_USED", "kind": "simple", "entity_type": "Page"},
        ]},
    ],

    "containers": [],

    "moves": [
        {"name": "alloc_page",
         "scoped_from": ["MEM_FREE"], "scoped_to": ["MEM_USED"],
         "entity_type": "Page"},

        {"name": "free_page",
         "scoped_from": ["MEM_USED"], "scoped_to": ["MEM_FREE"],
         "entity_type": "Page"},
    ],

    "tensions": [
        # Allocate: running process gets a free page
        {
            "name": "do_alloc",
            "priority": 12,
            "match": [
                {"bind": "sig", "in": "ALLOC_SIG"},
                {"bind": "proc", "in": "CPU0"},
                {"bind": "page",
                 "in": {"scope": "proc", "container": "MEM_FREE"},
                 "select": "first"},
            ],
            "emit": [
                {"move": "alloc_page", "entity": "page",
                 "to": {"scope": "proc", "container": "MEM_USED"}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIG_DONE"},
            ],
        },

        # Free: running process frees a used page
        {
            "name": "do_free",
            "priority": 12,
            "match": [
                {"bind": "sig", "in": "FREE_SIG"},
                {"bind": "proc", "in": "CPU0"},
                {"bind": "page",
                 "in": {"scope": "proc", "container": "MEM_USED"},
                 "select": "first"},
            ],
            "emit": [
                {"move": "free_page", "entity": "page",
                 "to": {"scope": "proc", "container": "MEM_FREE"}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIG_DONE"},
            ],
        },
    ],
}


# =====================================================================
# MODULE 3: FS — File Descriptor Management
# =====================================================================

FS_MODULE = {
    "module": "fs",

    "exports": [
        "FileDescriptor",
        "FD_FREE", "FD_OPEN",
        "open_fd", "close_fd",
    ],

    "imports": [
        "proc.Process",
        "proc.CPU0",
        "proc.OPEN_SIG",
        "proc.CLOSE_SIG",
        "proc.SIG_DONE",
        "proc.consume_signal",
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
        {
            "name": "do_open",
            "priority": 12,
            "match": [
                {"bind": "sig", "in": "OPEN_SIG"},
                {"bind": "proc", "in": "CPU0"},
                {"bind": "fd",
                 "in": {"scope": "proc", "container": "FD_FREE"},
                 "select": "first"},
            ],
            "emit": [
                {"move": "open_fd", "entity": "fd",
                 "to": {"scope": "proc", "container": "FD_OPEN"}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIG_DONE"},
            ],
        },

        {
            "name": "do_close",
            "priority": 12,
            "match": [
                {"bind": "sig", "in": "CLOSE_SIG"},
                {"bind": "proc", "in": "CPU0"},
                {"bind": "fd",
                 "in": {"scope": "proc", "container": "FD_OPEN"},
                 "select": "first"},
            ],
            "emit": [
                {"move": "close_fd", "entity": "fd",
                 "to": {"scope": "proc", "container": "FD_FREE"}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIG_DONE"},
            ],
        },
    ],
}


# =====================================================================
# MODULE 4: IPC — Inter-Process Communication
# =====================================================================

IPC_MODULE = {
    "module": "ipc",

    "exports": [
        "Message",
        "INBOX", "OUTBOX", "PROCESSED",
        "process_msg",
    ],

    "imports": [
        "proc.Process",
        "proc.CPU0",
        "proc.SEND_SIG",
        "proc.RECV_SIG",
        "proc.SIG_DONE",
        "proc.consume_signal",
    ],

    "entity_types": [
        {"name": "Message"},
    ],

    "entity_type_extensions": [
        {"extend": "Process", "add_scoped_containers": [
            {"name": "INBOX",     "kind": "simple", "entity_type": "Message"},
            {"name": "OUTBOX",    "kind": "simple", "entity_type": "Message"},
            {"name": "PROCESSED", "kind": "simple", "entity_type": "Message"},
        ]},
    ],

    "containers": [],

    "moves": [
        {"name": "process_msg",
         "scoped_from": ["INBOX"], "scoped_to": ["PROCESSED"],
         "entity_type": "Message"},
    ],

    "tensions": [
        # Send: running process sends message from OUTBOX through channel
        {
            "name": "do_send",
            "priority": 15,
            "match": [
                {"bind": "sig", "in": "SEND_SIG"},
                {"bind": "proc", "in": "CPU0"},
                {"bind": "msg",
                 "in": {"scope": "proc", "container": "OUTBOX"},
                 "select": "first"},
            ],
            "emit": [
                {"send": "msg_pipe", "entity": "msg"},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIG_DONE"},
            ],
        },

        # Receive: running process receives message from channel into INBOX
        {
            "name": "do_recv",
            "priority": 12,
            "match": [
                {"bind": "sig", "in": "RECV_SIG"},
                {"bind": "proc", "in": "CPU0"},
                {"bind": "msg", "in": {"channel": "msg_pipe"}},
            ],
            "emit": [
                {"receive": "msg_pipe", "entity": "msg",
                 "to": {"scope": "proc", "container": "INBOX"}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIG_DONE"},
            ],
        },

        # React: process a received message
        {
            "name": "react_to_msg",
            "priority": 8,
            "match": [
                {"bind": "proc", "in": "CPU0"},
                {"bind": "msg",
                 "in": {"scope": "proc", "container": "INBOX"},
                 "select": "first"},
            ],
            "emit": [
                {"set": "proc", "property": "msgs_received",
                 "value": {"op": "+",
                           "left": {"prop": "msgs_received", "of": "proc"},
                           "right": 1}},
                {"move": "process_msg", "entity": "msg",
                 "to": {"scope": "proc", "container": "PROCESSED"}},
            ],
        },
    ],
}


# =====================================================================
# COMPOSITION: The Four-Module Kernel
# =====================================================================

KERNEL = {
    "compose": ["proc", "mem", "fs", "ipc"],
    "modules": [PROC_MODULE, MEM_MODULE, FS_MODULE, IPC_MODULE],

    "channels": [
        {"name": "msg_pipe", "from": "server", "to": "client",
         "entity_type": "ipc.Message"},
    ],

    "max_nesting_depth": 3,

    "entities": [
        # Processes
        {"name": "server", "type": "proc.Process", "in": "proc.READY",
         "properties": {"priority": 8, "time_slice": 3, "msgs_received": 0}},
        {"name": "client", "type": "proc.Process", "in": "proc.READY",
         "properties": {"priority": 5, "time_slice": 3, "msgs_received": 0}},

        # Server's memory pages
        {"name": "page0_s", "type": "mem.Page",
         "in": {"scope": "server", "container": "MEM_FREE"}},
        {"name": "page1_s", "type": "mem.Page",
         "in": {"scope": "server", "container": "MEM_FREE"}},

        # Client's memory pages
        {"name": "page0_c", "type": "mem.Page",
         "in": {"scope": "client", "container": "MEM_FREE"}},
        {"name": "page1_c", "type": "mem.Page",
         "in": {"scope": "client", "container": "MEM_FREE"}},

        # Server's file descriptors
        {"name": "fd0_s", "type": "fs.FileDescriptor",
         "in": {"scope": "server", "container": "FD_FREE"}},
        {"name": "fd1_s", "type": "fs.FileDescriptor",
         "in": {"scope": "server", "container": "FD_FREE"}},

        # Client's file descriptors
        {"name": "fd0_c", "type": "fs.FileDescriptor",
         "in": {"scope": "client", "container": "FD_FREE"}},

        # A message in server's outbox
        {"name": "msg1", "type": "ipc.Message",
         "in": {"scope": "server", "container": "OUTBOX"},
         "properties": {"content": "hello from server", "seq": 1}},
    ],
}


def run_demo():
    """Run the four-module kernel demo."""
    from herb_compose import compose_and_load

    print("=" * 70)
    print("HERB Four-Module Kernel Demo")
    print("=" * 70)
    print()
    print("Modules: proc (scheduling), mem (pages), fs (FDs), ipc (messages)")
    print()

    prog = compose_and_load(KERNEL)
    g = prog.graph

    def show_state(label):
        print(f"\n--- {label} ---")
        for name in ["server", "client"]:
            eid = prog.entity_id(name)
            loc = prog.where_is(name)
            ts = prog.get_property(name, "time_slice")
            msgs = prog.get_property(name, "msgs_received")
            mem_free = g.get_scoped_container(eid, "MEM_FREE")
            mem_used = g.get_scoped_container(eid, "MEM_USED")
            fd_free = g.get_scoped_container(eid, "FD_FREE")
            fd_open = g.get_scoped_container(eid, "FD_OPEN")
            inbox = g.get_scoped_container(eid, "INBOX")
            print(f"  {name:10s} sched={loc:15s} ts={ts} msgs={msgs}")
            print(f"             mem: {g.containers[mem_free].count} free, "
                  f"{g.containers[mem_used].count} used")
            print(f"             fds: {g.containers[fd_free].count} free, "
                  f"{g.containers[fd_open].count} open")
            print(f"             inbox: {g.containers[inbox].count} msgs")

    show_state("Initial State")

    # Phase 1: Boot — schedule processes
    print("\n>>> Phase 1: Boot (auto-schedule)")
    ops = g.run()
    print(f"    {ops} operations")
    show_state("After boot")

    # Phase 2: Server allocates a memory page
    print("\n>>> Phase 2: Server allocates memory page")
    prog.create_entity("alloc1", "proc.Signal", "proc.ALLOC_SIG")
    ops = g.run()
    print(f"    {ops} operations")
    show_state("After alloc")

    # Phase 3: Server opens a file descriptor
    print("\n>>> Phase 3: Server opens FD")
    prog.create_entity("open1", "proc.Signal", "proc.OPEN_SIG")
    ops = g.run()
    print(f"    {ops} operations")
    show_state("After open")

    # Phase 4: Server sends message to client via channel
    print("\n>>> Phase 4: Server sends message through IPC channel")
    prog.create_entity("send1", "proc.Signal", "proc.SEND_SIG")
    ops = g.run()
    print(f"    {ops} operations")
    show_state("After send")

    # Phase 5: Server blocks on I/O — client gets scheduled
    print("\n>>> Phase 5: Server blocks (context switch to client)")
    server_id = prog.entity_id("server")
    blocked = prog.container_id("proc.BLOCKED")
    g.move("proc.block_proc", server_id, blocked)
    ops = g.run()
    print(f"    {ops} operations (client scheduled)")
    show_state("After block + reschedule")

    # Phase 6: Client receives the message from channel
    print("\n>>> Phase 6: Client receives message from channel")
    prog.create_entity("recv1", "proc.Signal", "proc.RECV_SIG")
    ops = g.run()
    print(f"    {ops} operations")
    show_state("After receive + react")

    # Summary
    print("\n" + "=" * 70)
    print("Four modules cooperating through composition:")
    print("  proc — scheduled processes, handled time slicing")
    print("  mem  — allocated pages in server's scoped memory")
    print("  fs   — opened FDs in server's scoped FD table")
    print("  ipc  — sent message through channel, client received + reacted")
    print(f"\nTotal operations: {len(g.operations)}")
    print("=" * 70)


if __name__ == "__main__":
    run_demo()
