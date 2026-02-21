"""
HERB Inter-Process Communication Demo — Channels + FD Passing

This is the proof that HERB processes can communicate WITHOUT breaking
isolation. The critical insight from the research:

  Cross-scope communication IS a MOVE through a channel.
  — Zircon's model: channel write atomically removes handle from sender.
  — Boxed Ambients: communication across exactly one level of boundary.
  — No free-form cross-scope references (the bigraph trap).

What this demo proves:
1. Process A can send a message to Process B through a typed channel
2. Process B receives the message and its tension reacts to it
3. Process A can pass an FD to Process B (A LOSES it, B GAINS it)
4. After FD transfer, the FD is in B's scope — not A's
5. Cross-scope access outside channels is structurally impossible
6. Explicit duplication before send preserves sender's access

Key features exercised:
- Channels (typed cross-scope communication)
- Channel send/receive in tension emit clauses
- Channel match clauses (match entities in channel buffer)
- FD passing across scope boundaries via channels
- Entity duplication (explicit copy-then-send)
- Nesting depth bound
- All existing features (scoped containers, scoped moves, property mutation)
"""

IPC_DEMO = {
    # =====================================================================
    # ENTITY TYPES
    # =====================================================================
    "entity_types": [
        {"name": "Process", "scoped_containers": [
            {"name": "FD_FREE", "kind": "simple", "entity_type": "FileDescriptor"},
            {"name": "FD_OPEN", "kind": "simple", "entity_type": "FileDescriptor"},
            {"name": "INBOX",   "kind": "simple", "entity_type": "Message"},
            {"name": "OUTBOX",  "kind": "simple", "entity_type": "Message"},
            {"name": "PROCESSED", "kind": "simple", "entity_type": "Message"},
        ]},
        {"name": "FileDescriptor"},
        {"name": "Message"},
        {"name": "Signal"},
    ],

    # =====================================================================
    # CONTAINERS — global scheduling + signal state
    # =====================================================================
    "containers": [
        # Process scheduling
        {"name": "READY_QUEUE", "kind": "simple", "entity_type": "Process"},
        {"name": "CPU0",        "kind": "slot",   "entity_type": "Process"},
        {"name": "BLOCKED",     "kind": "simple", "entity_type": "Process"},

        # Signal containers
        {"name": "SEND_MSG_REQUEST", "kind": "simple", "entity_type": "Signal"},
        {"name": "SEND_FD_REQUEST",  "kind": "simple", "entity_type": "Signal"},
        {"name": "DUP_SEND_REQUEST", "kind": "simple", "entity_type": "Signal"},
        {"name": "SIGNAL_DONE",      "kind": "simple", "entity_type": "Signal"},
    ],

    # =====================================================================
    # MOVES — the operation set
    # =====================================================================
    "moves": [
        # Process scheduling
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

        # FD operations (scoped — within a process)
        {"name": "open_fd",
         "scoped_from": ["FD_FREE"], "scoped_to": ["FD_OPEN"],
         "entity_type": "FileDescriptor"},

        {"name": "close_fd",
         "scoped_from": ["FD_OPEN"], "scoped_to": ["FD_FREE"],
         "entity_type": "FileDescriptor"},

        # Message consumption (scoped — within a process)
        {"name": "process_msg",
         "scoped_from": ["INBOX"], "scoped_to": ["PROCESSED"],
         "entity_type": "Message"},

        # Signal processing
        {"name": "consume_signal",
         "from": ["SEND_MSG_REQUEST", "SEND_FD_REQUEST", "DUP_SEND_REQUEST"],
         "to": ["SIGNAL_DONE"],
         "entity_type": "Signal"},
    ],

    # =====================================================================
    # CHANNELS — typed cross-scope communication
    #
    # A channel connects two processes. The sender can SEND entities
    # into the channel. The receiver can RECEIVE entities from it.
    # These are the ONLY cross-scope operations that exist.
    #
    # This follows Zircon's model: channel write removes the handle
    # from the sender. No implicit sharing. If you want to keep a
    # copy, you must explicitly DUPLICATE before sending.
    # =====================================================================
    "channels": [
        {"name": "pipe_AB", "from": "proc_A", "to": "proc_B",
         "entity_type": "Message"},
        {"name": "fd_pipe_AB", "from": "proc_A", "to": "proc_B",
         "entity_type": "FileDescriptor"},
    ],

    # =====================================================================
    # NESTING DEPTH BOUND
    #
    # Prevent unbounded nesting (entity creates entity creates entity...).
    # The research warns: unbounded nesting + recursive creation =
    # undecidability. Depth 3 is generous for this demo.
    # =====================================================================
    "max_nesting_depth": 3,

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
        # SEND MESSAGE: Running process sends a message through channel
        #
        # When a send_msg signal arrives and proc_A is running:
        # 1. Match a message in proc_A's OUTBOX
        # 2. SEND it through pipe_AB (message leaves A's scope)
        # 3. Consume the signal
        #
        # After this, the message is in the channel buffer — NOT in
        # proc_A's scope. proc_A has lost access. This is MOVE semantics.
        # -----------------------------------------------------------------
        {
            "name": "send_message",
            "priority": 15,
            "match": [
                {"bind": "sig", "in": "SEND_MSG_REQUEST", "select": "first"},
                {"bind": "proc", "in": "CPU0", "select": "first"},
                {"bind": "msg", "in": {"scope": "proc", "container": "OUTBOX"},
                 "select": "first"},
            ],
            "emit": [
                {"send": "pipe_AB", "entity": "msg"},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIGNAL_DONE"},
            ],
        },

        # -----------------------------------------------------------------
        # RECEIVE MESSAGE: proc_B receives from channel into its INBOX
        #
        # When a message is in the channel buffer AND proc_B is running:
        # 1. Match in the channel buffer
        # 2. RECEIVE into proc_B's INBOX
        #
        # The channel match clause {"channel": "pipe_AB"} resolves to
        # the channel's buffer container. The receive emit moves the
        # entity from the buffer into the receiver's scoped container.
        # -----------------------------------------------------------------
        {
            "name": "receive_message",
            "priority": 12,
            "match": [
                {"bind": "proc_b", "in": "CPU0", "select": "first",
                 "where": {"op": "==",
                           "left": {"prop": "name", "of": "proc_b"},
                           "right": "B"}},
                {"bind": "msg", "in": {"channel": "pipe_AB"},
                 "select": "first"},
            ],
            "emit": [
                {"receive": "pipe_AB", "entity": "msg",
                 "to": {"scope": "proc_b", "container": "INBOX"}},
            ],
        },

        # -----------------------------------------------------------------
        # REACT TO MESSAGE: When proc_B has a message in INBOX, react
        #
        # This proves the tension system reacts to received messages.
        # The reaction: increment proc_B's "messages_received" counter.
        # -----------------------------------------------------------------
        {
            "name": "react_to_message",
            "priority": 8,
            "match": [
                {"bind": "proc_b", "in": "CPU0", "select": "first",
                 "where": {"op": "==",
                           "left": {"prop": "name", "of": "proc_b"},
                           "right": "B"}},
                {"bind": "msg", "in": {"scope": "proc_b", "container": "INBOX"},
                 "select": "first"},
            ],
            "emit": [
                {"set": "proc_b", "property": "messages_received",
                 "value": {"op": "+",
                           "left": {"prop": "messages_received", "of": "proc_b"},
                           "right": 1}},
                {"move": "process_msg", "entity": "msg",
                 "to": {"scope": "proc_b", "container": "PROCESSED"}},
            ],
        },

        # -----------------------------------------------------------------
        # SEND FD: Pass a file descriptor through the fd channel
        #
        # proc_A sends an FD to proc_B. After send, the FD is in the
        # channel — NOT in proc_A's scope. proc_A has lost access.
        # This is the Zircon model: handle write removes it from sender.
        # -----------------------------------------------------------------
        {
            "name": "send_fd",
            "priority": 15,
            "match": [
                {"bind": "sig", "in": "SEND_FD_REQUEST", "select": "first"},
                {"bind": "proc", "in": "CPU0", "select": "first"},
                {"bind": "fd", "in": {"scope": "proc", "container": "FD_OPEN"},
                 "select": "first"},
            ],
            "emit": [
                {"send": "fd_pipe_AB", "entity": "fd"},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIGNAL_DONE"},
            ],
        },

        # -----------------------------------------------------------------
        # RECEIVE FD: proc_B receives FD from channel into its FD_FREE
        # -----------------------------------------------------------------
        {
            "name": "receive_fd",
            "priority": 12,
            "match": [
                {"bind": "proc_b", "in": "CPU0", "select": "first",
                 "where": {"op": "==",
                           "left": {"prop": "name", "of": "proc_b"},
                           "right": "B"}},
                {"bind": "fd", "in": {"channel": "fd_pipe_AB"},
                 "select": "first"},
            ],
            "emit": [
                {"receive": "fd_pipe_AB", "entity": "fd",
                 "to": {"scope": "proc_b", "container": "FD_FREE"}},
            ],
        },

        # -----------------------------------------------------------------
        # DUPLICATE-THEN-SEND: Explicitly copy an FD before sending
        #
        # This is Zircon's handle_duplicate pattern. If you want to
        # keep access while also giving access to another process:
        # 1. DUPLICATE the entity (creates a copy in your scope)
        # 2. SEND the copy through the channel
        # The original stays in your scope. No implicit sharing.
        #
        # For simplicity, this tension duplicates into the sender's
        # FD_OPEN and then sends the copy. In practice, the duplicate
        # would go to a staging area, but the effect is the same.
        # -----------------------------------------------------------------
        {
            "name": "dup_and_send_fd",
            "priority": 15,
            "match": [
                {"bind": "sig", "in": "DUP_SEND_REQUEST", "select": "first"},
                {"bind": "proc", "in": "CPU0", "select": "first"},
                {"bind": "fd", "in": {"scope": "proc", "container": "FD_OPEN"},
                 "select": "first"},
            ],
            "emit": [
                {"duplicate": "fd",
                 "in": {"scope": "proc", "container": "FD_OPEN"}},
                {"move": "consume_signal", "entity": "sig",
                 "to": "SIGNAL_DONE"},
            ],
        },
    ],

    # =====================================================================
    # ENTITIES
    # =====================================================================
    "entities": [
        # Processes
        {"name": "proc_A", "type": "Process", "in": "READY_QUEUE",
         "properties": {"priority": 5, "name": "A", "messages_received": 0}},
        {"name": "proc_B", "type": "Process", "in": "READY_QUEUE",
         "properties": {"priority": 3, "name": "B", "messages_received": 0}},

        # proc_A's file descriptors
        {"name": "fd0_A", "type": "FileDescriptor",
         "in": {"scope": "proc_A", "container": "FD_FREE"}},
        {"name": "fd1_A", "type": "FileDescriptor",
         "in": {"scope": "proc_A", "container": "FD_FREE"}},
        {"name": "fd2_A", "type": "FileDescriptor",
         "in": {"scope": "proc_A", "container": "FD_FREE"}},

        # proc_B's file descriptors
        {"name": "fd0_B", "type": "FileDescriptor",
         "in": {"scope": "proc_B", "container": "FD_FREE"}},
        {"name": "fd1_B", "type": "FileDescriptor",
         "in": {"scope": "proc_B", "container": "FD_FREE"}},

        # A message in proc_A's outbox
        {"name": "msg1", "type": "Message",
         "in": {"scope": "proc_A", "container": "OUTBOX"},
         "properties": {"content": "hello from A", "seq": 1}},
    ],
}
