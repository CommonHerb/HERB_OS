"""
Tests for Session 31: Inter-Process Communication.

Proves that the new features work correctly:
1. Channels — typed cross-scope communication (the ONLY way to cross scopes)
2. Channel send — entity leaves sender's scope, enters channel buffer
3. Channel receive — entity leaves channel buffer, enters receiver's scope
4. FD passing — real resource transfer across scope boundaries
5. Entity duplication — explicit copy-then-send (Zircon's handle_duplicate)
6. Nesting depth bound — prevents undecidability from unbounded nesting
7. IPC demo — full multi-process communication scenario
8. Isolation proof — cross-scope access outside channels is impossible
9. Backward compatibility — all existing programs still work
"""

import pytest
from herb_move import (
    MoveGraph, ContainerKind, IntendedMove,
    IntendedTransfer, IntendedCreate, IntendedSet,
    IntendedSend, IntendedReceive, IntendedDuplicate
)
from herb_program import HerbProgram, validate_program, _eval_expr
from herb_scheduler import SCHEDULER
from herb_scheduler_priority import PRIORITY_SCHEDULER
from herb_economy import ECONOMY
from herb_dom import DOM_LAYOUT
from herb_multiprocess import MULTI_PROCESS_OS
from herb_ipc import IPC_DEMO


# =============================================================================
# CHANNELS — RUNTIME LEVEL
# =============================================================================

class TestChannelsRuntime:
    """Test channels at the MoveGraph level."""

    def setup_method(self):
        """Create a graph with two processes and a channel between them."""
        self.g = MoveGraph()
        self.msg_type = self.g.define_entity_type("Message")
        self.proc_type = self.g.define_entity_type("Process")
        self.q = self.g.define_container("Q", entity_type=self.proc_type)

        self.g.define_entity_type_scopes(self.proc_type, [
            {"name": "OUTBOX", "kind": ContainerKind.SIMPLE, "entity_type": self.msg_type},
            {"name": "INBOX", "kind": ContainerKind.SIMPLE, "entity_type": self.msg_type},
        ])

        self.p1 = self.g.create_entity(self.proc_type, "proc_A", self.q)
        self.p2 = self.g.create_entity(self.proc_type, "proc_B", self.q)

        # Define channel from proc_A to proc_B
        self.channel_buffer = self.g.define_channel(
            "pipe_AB", self.p1, self.p2, self.msg_type
        )

        # Create a message in proc_A's outbox
        outbox_a = self.g.get_scoped_container(self.p1, "OUTBOX")
        self.msg = self.g.create_entity(
            self.msg_type, "msg1", outbox_a, {"content": "hello"}
        )

    def test_channel_creates_buffer_container(self):
        """Channel definition creates a buffer container."""
        assert self.channel_buffer in self.g.containers
        assert self.g.containers[self.channel_buffer].name == "channel:pipe_AB"

    def test_channel_registered(self):
        """Channel is registered in the graph."""
        ch = self.g.channels["pipe_AB"]
        assert ch["sender_id"] == self.p1
        assert ch["receiver_id"] == self.p2
        assert ch["entity_type"] == self.msg_type
        assert ch["buffer_container"] == self.channel_buffer

    def test_channel_send_moves_entity_to_buffer(self):
        """Send moves entity from sender's scope to channel buffer."""
        result = self.g.channel_send("pipe_AB", self.msg)
        assert result is not None
        assert self.g.where_is(self.msg) == self.channel_buffer

    def test_channel_send_removes_from_sender(self):
        """After send, entity is NOT in sender's scope."""
        outbox = self.g.get_scoped_container(self.p1, "OUTBOX")
        assert self.msg in self.g.contents_of(outbox)

        self.g.channel_send("pipe_AB", self.msg)

        assert self.msg not in self.g.contents_of(outbox)

    def test_channel_send_wrong_sender_rejected(self):
        """Entity not in sender's scope can't be sent."""
        # Create message in proc_B's outbox (but channel sender is proc_A)
        outbox_b = self.g.get_scoped_container(self.p2, "OUTBOX")
        msg_b = self.g.create_entity(
            self.msg_type, "msg_b", outbox_b, {"content": "from B"}
        )

        result = self.g.channel_send("pipe_AB", msg_b)
        assert result is None  # Not in sender's scope

    def test_channel_send_wrong_type_rejected(self):
        """Entity of wrong type can't be sent through typed channel."""
        other_type = self.g.define_entity_type("Other")
        outbox_a = self.g.get_scoped_container(self.p1, "OUTBOX")
        wrong = self.g.create_entity(other_type, "wrong", outbox_a)

        result = self.g.channel_send("pipe_AB", wrong)
        assert result is None

    def test_channel_send_unknown_channel_rejected(self):
        """Send to nonexistent channel returns None."""
        result = self.g.channel_send("nonexistent", self.msg)
        assert result is None

    def test_channel_receive_moves_to_receiver(self):
        """Receive moves entity from buffer to receiver's scope."""
        self.g.channel_send("pipe_AB", self.msg)
        inbox_b = self.g.get_scoped_container(self.p2, "INBOX")

        result = self.g.channel_receive("pipe_AB", self.msg, inbox_b)
        assert result is not None
        assert self.g.where_is(self.msg) == inbox_b

    def test_channel_receive_removes_from_buffer(self):
        """After receive, entity is NOT in channel buffer."""
        self.g.channel_send("pipe_AB", self.msg)
        inbox_b = self.g.get_scoped_container(self.p2, "INBOX")

        self.g.channel_receive("pipe_AB", self.msg, inbox_b)

        assert self.msg not in self.g.contents_of(self.channel_buffer)

    def test_channel_receive_wrong_receiver_rejected(self):
        """Target not owned by receiver can't receive."""
        self.g.channel_send("pipe_AB", self.msg)

        # Try to receive into sender's inbox (wrong receiver)
        inbox_a = self.g.get_scoped_container(self.p1, "INBOX")
        result = self.g.channel_receive("pipe_AB", self.msg, inbox_a)
        assert result is None

    def test_channel_receive_not_in_buffer_rejected(self):
        """Entity not in channel buffer can't be received."""
        inbox_b = self.g.get_scoped_container(self.p2, "INBOX")
        result = self.g.channel_receive("pipe_AB", self.msg, inbox_b)
        assert result is None  # msg is in outbox, not buffer

    def test_channel_send_receive_provenance(self):
        """Channel operations are logged for provenance."""
        self.g.channel_send("pipe_AB", self.msg)
        inbox_b = self.g.get_scoped_container(self.p2, "INBOX")
        self.g.channel_receive("pipe_AB", self.msg, inbox_b)

        send_ops = [o for o in self.g.operations if o.op_type == "channel_send"]
        recv_ops = [o for o in self.g.operations if o.op_type == "channel_receive"]
        assert len(send_ops) == 1
        assert send_ops[0].params["channel"] == "pipe_AB"
        assert len(recv_ops) == 1
        assert recv_ops[0].params["channel"] == "pipe_AB"

    def test_channel_full_roundtrip(self):
        """Message goes sender → channel → receiver."""
        outbox_a = self.g.get_scoped_container(self.p1, "OUTBOX")
        inbox_b = self.g.get_scoped_container(self.p2, "INBOX")

        # Start: msg in A's outbox
        assert self.msg in self.g.contents_of(outbox_a)

        # Send: msg moves to channel
        self.g.channel_send("pipe_AB", self.msg)
        assert self.msg not in self.g.contents_of(outbox_a)
        assert self.msg in self.g.contents_of(self.channel_buffer)

        # Receive: msg moves to B's inbox
        self.g.channel_receive("pipe_AB", self.msg, inbox_b)
        assert self.msg not in self.g.contents_of(self.channel_buffer)
        assert self.msg in self.g.contents_of(inbox_b)

    def test_multiple_messages_in_channel(self):
        """Channel can buffer multiple messages."""
        outbox_a = self.g.get_scoped_container(self.p1, "OUTBOX")
        msg2 = self.g.create_entity(
            self.msg_type, "msg2", outbox_a, {"content": "second"}
        )

        self.g.channel_send("pipe_AB", self.msg)
        self.g.channel_send("pipe_AB", msg2)

        assert len(self.g.contents_of(self.channel_buffer)) == 2


# =============================================================================
# CHANNELS VIA TENSIONS
# =============================================================================

class TestChannelsTensions:
    """Test channels driven by tensions (IntendedSend/IntendedReceive)."""

    def test_intended_send_via_tension(self):
        """IntendedSend works through step()."""
        g = MoveGraph()
        msg_type = g.define_entity_type("Msg")
        proc_type = g.define_entity_type("Proc")
        q = g.define_container("Q", entity_type=proc_type)

        g.define_entity_type_scopes(proc_type, [
            {"name": "OUT", "kind": ContainerKind.SIMPLE, "entity_type": msg_type},
        ])

        p1 = g.create_entity(proc_type, "sender", q)
        p2 = g.create_entity(proc_type, "receiver", q)
        g.define_channel("ch", p1, p2, msg_type)

        out = g.get_scoped_container(p1, "OUT")
        msg = g.create_entity(msg_type, "m", out)

        def send_tension(graph):
            if graph.where_is(msg) == out:
                return [IntendedSend("ch", msg)]
            return []

        g.define_tension("auto_send", send_tension)
        ops = g.step()

        assert len(ops) == 1
        ch = g.channels["ch"]
        assert g.where_is(msg) == ch["buffer_container"]

    def test_intended_receive_via_tension(self):
        """IntendedReceive works through step()."""
        g = MoveGraph()
        msg_type = g.define_entity_type("Msg")
        proc_type = g.define_entity_type("Proc")
        q = g.define_container("Q", entity_type=proc_type)

        g.define_entity_type_scopes(proc_type, [
            {"name": "OUT", "kind": ContainerKind.SIMPLE, "entity_type": msg_type},
            {"name": "IN", "kind": ContainerKind.SIMPLE, "entity_type": msg_type},
        ])

        p1 = g.create_entity(proc_type, "sender", q)
        p2 = g.create_entity(proc_type, "receiver", q)
        buffer_cid = g.define_channel("ch", p1, p2, msg_type)

        out = g.get_scoped_container(p1, "OUT")
        inbox = g.get_scoped_container(p2, "IN")
        msg = g.create_entity(msg_type, "m", out)

        # Send first
        g.channel_send("ch", msg)
        assert g.where_is(msg) == buffer_cid

        def recv_tension(graph):
            contents = graph.contents_of(buffer_cid)
            if contents:
                return [IntendedReceive("ch", list(contents)[0], inbox)]
            return []

        g.define_tension("auto_recv", recv_tension)
        ops = g.step()

        assert len(ops) == 1
        assert g.where_is(msg) == inbox


# =============================================================================
# ENTITY DUPLICATION — RUNTIME LEVEL
# =============================================================================

class TestDuplicationRuntime:
    """Test entity duplication at the MoveGraph level."""

    def test_duplicate_creates_copy(self):
        """Duplicate creates a new entity with same type and properties."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        e = g.create_entity(t, "original", c, {"x": 42, "y": "hello"})

        new_id = g.duplicate_entity(e, c, "copy")
        assert new_id is not None
        assert new_id != e

        # Same type
        assert g.entities[new_id].type_id == t
        # Same properties
        assert g.get_property(new_id, "x") == 42
        assert g.get_property(new_id, "y") == "hello"
        # Same container
        assert g.where_is(new_id) == c

    def test_duplicate_original_unchanged(self):
        """Original entity is not affected by duplication."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        e = g.create_entity(t, "original", c, {"val": 100})

        g.duplicate_entity(e, c)

        # Original still there with same properties
        assert g.where_is(e) == c
        assert g.get_property(e, "val") == 100

    def test_duplicate_independent_properties(self):
        """Copy's properties are independent from original."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        e = g.create_entity(t, "original", c, {"val": 100})

        new_id = g.duplicate_entity(e, c)

        # Modify copy
        g.set_property(new_id, "val", 999)

        # Original unchanged
        assert g.get_property(e, "val") == 100
        assert g.get_property(new_id, "val") == 999

    def test_duplicate_nonexistent_returns_none(self):
        """Duplicating nonexistent entity returns None."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)

        result = g.duplicate_entity(9999, c)
        assert result is None

    def test_duplicate_logs_operation(self):
        """Duplication is logged for provenance."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        e = g.create_entity(t, "original", c)

        g.duplicate_entity(e, c, "copy")

        dup_ops = [o for o in g.operations if o.op_type == "duplicate"]
        assert len(dup_ops) == 1
        assert dup_ops[0].params["source_entity"] == e

    def test_intended_duplicate_via_tension(self):
        """IntendedDuplicate works through step()."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        e = g.create_entity(t, "x", c, {"val": 7})

        duplicated = [False]

        def dup_tension(graph):
            if not duplicated[0]:
                duplicated[0] = True
                return [IntendedDuplicate(e, c)]
            return []

        g.define_tension("dup", dup_tension)
        ops = g.step()

        assert len(ops) == 1
        assert len(g.contents_of(c)) == 2  # Original + copy


# =============================================================================
# NESTING DEPTH BOUND
# =============================================================================

class TestNestingDepthBound:
    """Test configurable max nesting depth."""

    def test_nesting_depth_zero_for_global(self):
        """Global containers have depth 0."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        assert g.get_nesting_depth(c) == 0

    def test_nesting_depth_one_for_scoped(self):
        """Scoped containers have depth 1."""
        g = MoveGraph()
        inner_type = g.define_entity_type("Inner")
        outer_type = g.define_entity_type("Outer")
        c = g.define_container("Q", entity_type=outer_type)

        g.define_entity_type_scopes(outer_type, [
            {"name": "BOX", "kind": ContainerKind.SIMPLE, "entity_type": inner_type},
        ])

        outer = g.create_entity(outer_type, "outer", c)
        box = g.get_scoped_container(outer, "BOX")
        assert g.get_nesting_depth(box) == 1

    def test_bound_prevents_deep_nesting(self):
        """max_nesting_depth prevents entity creation beyond limit."""
        g = MoveGraph()
        g.max_nesting_depth = 1

        inner_type = g.define_entity_type("Inner")
        mid_type = g.define_entity_type("Mid")
        outer_type = g.define_entity_type("Outer")
        c = g.define_container("Q", entity_type=outer_type)

        g.define_entity_type_scopes(outer_type, [
            {"name": "SLOT", "kind": ContainerKind.SIMPLE, "entity_type": mid_type},
        ])
        g.define_entity_type_scopes(mid_type, [
            {"name": "DEEP", "kind": ContainerKind.SIMPLE, "entity_type": inner_type},
        ])

        # Depth 1: outer entity with scoped containers — allowed
        outer = g.create_entity(outer_type, "outer", c)
        assert "SLOT" in g.entity_scoped_containers[outer]

        # Depth 2: mid entity inside outer's scope — would create depth-2 scopes
        slot = g.get_scoped_container(outer, "SLOT")
        mid = g.create_entity(mid_type, "mid", slot)

        # mid should NOT get scoped containers (would be depth 2, exceeds bound of 1)
        assert mid not in g.entity_scoped_containers

    def test_bound_allows_at_limit(self):
        """Entities at exactly the depth limit get scoped containers."""
        g = MoveGraph()
        g.max_nesting_depth = 2

        inner_type = g.define_entity_type("Inner")
        mid_type = g.define_entity_type("Mid")
        outer_type = g.define_entity_type("Outer")
        c = g.define_container("Q", entity_type=outer_type)

        g.define_entity_type_scopes(outer_type, [
            {"name": "SLOT", "kind": ContainerKind.SIMPLE, "entity_type": mid_type},
        ])
        g.define_entity_type_scopes(mid_type, [
            {"name": "DEEP", "kind": ContainerKind.SIMPLE, "entity_type": inner_type},
        ])

        outer = g.create_entity(outer_type, "outer", c)
        slot = g.get_scoped_container(outer, "SLOT")
        mid = g.create_entity(mid_type, "mid", slot)

        # mid at depth 2 = max_nesting_depth, so it gets scoped containers
        assert mid in g.entity_scoped_containers
        assert "DEEP" in g.entity_scoped_containers[mid]

    def test_no_bound_allows_unlimited(self):
        """Without max_nesting_depth, nesting is unlimited."""
        g = MoveGraph()
        # No max_nesting_depth set (default None)

        inner_type = g.define_entity_type("Inner")
        mid_type = g.define_entity_type("Mid")
        outer_type = g.define_entity_type("Outer")
        c = g.define_container("Q", entity_type=outer_type)

        g.define_entity_type_scopes(outer_type, [
            {"name": "SLOT", "kind": ContainerKind.SIMPLE, "entity_type": mid_type},
        ])
        g.define_entity_type_scopes(mid_type, [
            {"name": "DEEP", "kind": ContainerKind.SIMPLE, "entity_type": inner_type},
        ])

        outer = g.create_entity(outer_type, "outer", c)
        slot = g.get_scoped_container(outer, "SLOT")
        mid = g.create_entity(mid_type, "mid", slot)

        # With no bound, mid gets scoped containers at any depth
        assert mid in g.entity_scoped_containers


# =============================================================================
# FD PASSING — THE CRITICAL TEST
# =============================================================================

class TestFDPassing:
    """Test file descriptor passing across scope boundaries via channels."""

    def setup_method(self):
        """Create two processes with FD tables and a channel between them."""
        self.g = MoveGraph()
        self.fd_type = self.g.define_entity_type("FD")
        self.proc_type = self.g.define_entity_type("Process")
        self.q = self.g.define_container("Q", entity_type=self.proc_type)

        self.g.define_entity_type_scopes(self.proc_type, [
            {"name": "FD_FREE", "kind": ContainerKind.SIMPLE, "entity_type": self.fd_type},
            {"name": "FD_OPEN", "kind": ContainerKind.SIMPLE, "entity_type": self.fd_type},
        ])

        self.p1 = self.g.create_entity(self.proc_type, "proc_A", self.q)
        self.p2 = self.g.create_entity(self.proc_type, "proc_B", self.q)

        # FD channel from proc_A to proc_B
        self.fd_channel = self.g.define_channel(
            "fd_pipe", self.p1, self.p2, self.fd_type
        )

        # Scoped moves for FD operations
        self.g.define_move("open_fd",
            is_scoped=True,
            scoped_from=["FD_FREE"], scoped_to=["FD_OPEN"],
            entity_type=self.fd_type)

        # Create FDs
        free_a = self.g.get_scoped_container(self.p1, "FD_FREE")
        self.fd1 = self.g.create_entity(self.fd_type, "fd1", free_a)

    def test_fd_send_removes_from_sender(self):
        """After sending FD through channel, sender loses access."""
        # Open FD first
        open_a = self.g.get_scoped_container(self.p1, "FD_OPEN")
        self.g.move("open_fd", self.fd1, open_a)
        assert self.g.where_is(self.fd1) == open_a

        # Send through channel
        self.g.channel_send("fd_pipe", self.fd1)

        # FD is no longer in proc_A's scope
        assert self.g.where_is(self.fd1) != open_a
        free_a = self.g.get_scoped_container(self.p1, "FD_FREE")
        assert self.fd1 not in self.g.contents_of(open_a)
        assert self.fd1 not in self.g.contents_of(free_a)

    def test_fd_receive_into_receiver_scope(self):
        """Receiver gets the FD in their scope."""
        open_a = self.g.get_scoped_container(self.p1, "FD_OPEN")
        self.g.move("open_fd", self.fd1, open_a)

        # Send
        self.g.channel_send("fd_pipe", self.fd1)

        # Receive into proc_B's FD_FREE
        free_b = self.g.get_scoped_container(self.p2, "FD_FREE")
        self.g.channel_receive("fd_pipe", self.fd1, free_b)

        assert self.g.where_is(self.fd1) == free_b
        assert self.fd1 in self.g.contents_of(free_b)

    def test_fd_after_transfer_sender_operation_gone(self):
        """After FD transfer, scoped move on that FD in sender's scope doesn't exist."""
        open_a = self.g.get_scoped_container(self.p1, "FD_OPEN")
        self.g.move("open_fd", self.fd1, open_a)

        # Transfer FD to proc_B
        self.g.channel_send("fd_pipe", self.fd1)
        free_b = self.g.get_scoped_container(self.p2, "FD_FREE")
        self.g.channel_receive("fd_pipe", self.fd1, free_b)

        # Attempt to open_fd on fd1 within proc_A's scope — DOESN'T EXIST
        # The FD is in proc_B's scope now
        exists, reason = self.g.operation_exists("open_fd", self.fd1, open_a)
        assert not exists

    def test_cross_scope_without_channel_impossible(self):
        """Direct cross-scope move (bypassing channel) doesn't exist."""
        free_a = self.g.get_scoped_container(self.p1, "FD_FREE")
        open_b = self.g.get_scoped_container(self.p2, "FD_OPEN")

        # Try to move fd1 directly from A's scope to B's scope
        exists, reason = self.g.operation_exists("open_fd", self.fd1, open_b)
        assert not exists
        assert "isolation" in reason.lower()

    def test_duplicate_then_send_preserves_original(self):
        """Duplicate-then-send: sender keeps original, receiver gets copy."""
        open_a = self.g.get_scoped_container(self.p1, "FD_OPEN")
        self.g.move("open_fd", self.fd1, open_a)

        # Duplicate the FD
        copy_id = self.g.duplicate_entity(self.fd1, open_a, "fd1_copy")
        assert copy_id is not None

        # Send the COPY (not the original)
        self.g.channel_send("fd_pipe", copy_id)

        # Original still in sender's scope
        assert self.g.where_is(self.fd1) == open_a

        # Copy is in channel
        assert self.g.where_is(copy_id) == self.fd_channel

        # Receiver can receive the copy
        free_b = self.g.get_scoped_container(self.p2, "FD_FREE")
        self.g.channel_receive("fd_pipe", copy_id, free_b)

        # Both exist: original in A's scope, copy in B's scope
        assert self.g.where_is(self.fd1) == open_a
        assert self.g.where_is(copy_id) == free_b


# =============================================================================
# CHANNELS — PROGRAM LEVEL
# =============================================================================

class TestChannelsProgram:
    """Test channels through the program specification."""

    def test_basic_channel_program(self):
        """Channel defined in program spec creates proper infrastructure."""
        spec = {
            "entity_types": [
                {"name": "Proc", "scoped_containers": [
                    {"name": "OUT", "kind": "simple", "entity_type": "Msg"},
                    {"name": "IN", "kind": "simple", "entity_type": "Msg"},
                ]},
                {"name": "Msg"},
            ],
            "containers": [
                {"name": "WORLD", "entity_type": "Proc"},
            ],
            "moves": [],
            "channels": [
                {"name": "ch1", "from": "sender", "to": "receiver",
                 "entity_type": "Msg"},
            ],
            "tensions": [],
            "entities": [
                {"name": "sender", "type": "Proc", "in": "WORLD"},
                {"name": "receiver", "type": "Proc", "in": "WORLD"},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        assert "ch1" in g.channels
        assert g.channels["ch1"]["sender_id"] == prog.entity_id("sender")
        assert g.channels["ch1"]["receiver_id"] == prog.entity_id("receiver")

    def test_send_emit_in_tension(self):
        """Tension with send emit moves entity to channel."""
        spec = {
            "entity_types": [
                {"name": "Proc", "scoped_containers": [
                    {"name": "OUT", "kind": "simple", "entity_type": "Msg"},
                    {"name": "IN", "kind": "simple", "entity_type": "Msg"},
                ]},
                {"name": "Msg"},
                {"name": "Signal"},
            ],
            "containers": [
                {"name": "WORLD", "entity_type": "Proc"},
                {"name": "SIG", "entity_type": "Signal"},
                {"name": "DONE", "entity_type": "Signal"},
            ],
            "moves": [
                {"name": "ack", "from": ["SIG"], "to": ["DONE"],
                 "entity_type": "Signal"},
            ],
            "channels": [
                {"name": "ch1", "from": "sender", "to": "receiver",
                 "entity_type": "Msg"},
            ],
            "tensions": [{
                "name": "do_send",
                "match": [
                    {"bind": "sig", "in": "SIG", "select": "first"},
                    {"bind": "s", "in": "WORLD", "select": "first"},
                    {"bind": "m", "in": {"scope": "s", "container": "OUT"},
                     "select": "first"},
                ],
                "emit": [
                    {"send": "ch1", "entity": "m"},
                    {"move": "ack", "entity": "sig", "to": "DONE"},
                ],
            }],
            "entities": [
                {"name": "sender", "type": "Proc", "in": "WORLD"},
                {"name": "receiver", "type": "Proc", "in": "WORLD"},
                {"name": "msg1", "type": "Msg",
                 "in": {"scope": "sender", "container": "OUT"}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        # Trigger send
        prog.create_entity("go", "Signal", "SIG")
        g.run()

        # Message should be in channel buffer, not sender's outbox
        ch = g.channels["ch1"]
        msg_id = prog.entity_id("msg1")
        assert g.where_is(msg_id) == ch["buffer_container"]

    def test_receive_emit_in_tension(self):
        """Tension with receive emit moves entity from channel to scope."""
        spec = {
            "entity_types": [
                {"name": "Proc", "scoped_containers": [
                    {"name": "OUT", "kind": "simple", "entity_type": "Msg"},
                    {"name": "IN", "kind": "simple", "entity_type": "Msg"},
                ]},
                {"name": "Msg"},
            ],
            "containers": [
                {"name": "WORLD", "entity_type": "Proc"},
            ],
            "moves": [],
            "channels": [
                {"name": "ch1", "from": "sender", "to": "receiver",
                 "entity_type": "Msg"},
            ],
            "tensions": [
                {
                    "name": "do_send",
                    "priority": 10,
                    "match": [
                        {"bind": "s", "in": "WORLD", "select": "first"},
                        {"bind": "m", "in": {"scope": "s", "container": "OUT"},
                         "select": "first"},
                    ],
                    "emit": [
                        {"send": "ch1", "entity": "m"},
                    ],
                },
                {
                    "name": "do_recv",
                    "priority": 5,
                    "match": [
                        {"bind": "m", "in": {"channel": "ch1"},
                         "select": "first"},
                    ],
                    "emit": [
                        {"receive": "ch1", "entity": "m",
                         "to": {"scope": "receiver", "container": "IN"}},
                    ],
                },
            ],
            "entities": [
                {"name": "sender", "type": "Proc", "in": "WORLD"},
                {"name": "receiver", "type": "Proc", "in": "WORLD"},
                {"name": "msg1", "type": "Msg",
                 "in": {"scope": "sender", "container": "OUT"}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        # Message should end up in receiver's inbox
        recv_id = prog.entity_id("receiver")
        inbox = g.get_scoped_container(recv_id, "IN")
        msg_id = prog.entity_id("msg1")
        assert g.where_is(msg_id) == inbox

    def test_duplicate_emit_in_tension(self):
        """Tension with duplicate emit creates a copy."""
        spec = {
            "entity_types": [
                {"name": "Proc", "scoped_containers": [
                    {"name": "ITEMS", "kind": "simple", "entity_type": "Item"},
                ]},
                {"name": "Item"},
                {"name": "Signal"},
            ],
            "containers": [
                {"name": "WORLD", "entity_type": "Proc"},
                {"name": "SIG", "entity_type": "Signal"},
                {"name": "DONE", "entity_type": "Signal"},
            ],
            "moves": [
                {"name": "ack", "from": ["SIG"], "to": ["DONE"],
                 "entity_type": "Signal"},
            ],
            "channels": [],
            "tensions": [{
                "name": "dup_item",
                "match": [
                    {"bind": "sig", "in": "SIG", "select": "first"},
                    {"bind": "p", "in": "WORLD", "select": "first"},
                    {"bind": "item", "in": {"scope": "p", "container": "ITEMS"},
                     "select": "first"},
                ],
                "emit": [
                    {"duplicate": "item",
                     "in": {"scope": "p", "container": "ITEMS"}},
                    {"move": "ack", "entity": "sig", "to": "DONE"},
                ],
            }],
            "entities": [
                {"name": "box", "type": "Proc", "in": "WORLD"},
                {"name": "gem", "type": "Item",
                 "in": {"scope": "box", "container": "ITEMS"},
                 "properties": {"value": 100}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        box_id = prog.entity_id("box")
        items = g.get_scoped_container(box_id, "ITEMS")
        assert len(g.contents_of(items)) == 1

        prog.create_entity("go", "Signal", "SIG")
        g.run()

        # Should now have 2 items (original + copy)
        assert len(g.contents_of(items)) == 2

        # Both should have value=100
        for eid in g.contents_of(items):
            assert g.get_property(eid, "value") == 100

    def test_channel_match_clause(self):
        """Match clause with channel reference resolves to buffer."""
        spec = {
            "entity_types": [
                {"name": "Proc", "scoped_containers": [
                    {"name": "BOX", "kind": "simple", "entity_type": "Item"},
                ]},
                {"name": "Item"},
            ],
            "containers": [
                {"name": "WORLD", "entity_type": "Proc"},
            ],
            "moves": [],
            "channels": [
                {"name": "pipe", "from": "a", "to": "b",
                 "entity_type": "Item"},
            ],
            "tensions": [{
                "name": "count_channel",
                "match": [
                    {"bind": "item", "in": {"channel": "pipe"},
                     "select": "first"},
                ],
                "emit": [
                    {"receive": "pipe", "entity": "item",
                     "to": {"scope": "b", "container": "BOX"}},
                ],
            }],
            "entities": [
                {"name": "a", "type": "Proc", "in": "WORLD"},
                {"name": "b", "type": "Proc", "in": "WORLD"},
                {"name": "x", "type": "Item",
                 "in": {"scope": "a", "container": "BOX"}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        # Manually send item through channel
        a_id = prog.entity_id("a")
        x_id = prog.entity_id("x")
        g.channel_send("pipe", x_id)

        # Tension should receive it
        g.run()

        b_id = prog.entity_id("b")
        b_box = g.get_scoped_container(b_id, "BOX")
        assert x_id in g.contents_of(b_box)


# =============================================================================
# CHANNEL COUNT EXPRESSION
# =============================================================================

class TestChannelCountExpression:
    """Test count expressions with channel references."""

    def test_channel_count(self):
        """Count expression works with channel buffer."""
        spec = {
            "entity_types": [
                {"name": "Proc", "scoped_containers": [
                    {"name": "BOX", "kind": "simple", "entity_type": "Msg"},
                ]},
                {"name": "Msg"},
            ],
            "containers": [
                {"name": "WORLD", "entity_type": "Proc"},
            ],
            "moves": [],
            "channels": [
                {"name": "pipe", "from": "a", "to": "b",
                 "entity_type": "Msg"},
            ],
            "tensions": [],
            "entities": [
                {"name": "a", "type": "Proc", "in": "WORLD"},
                {"name": "b", "type": "Proc", "in": "WORLD"},
                {"name": "m1", "type": "Msg",
                 "in": {"scope": "a", "container": "BOX"}},
                {"name": "m2", "type": "Msg",
                 "in": {"scope": "a", "container": "BOX"}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        # Count before send
        result = _eval_expr(
            {"count": {"channel": "pipe"}},
            {}, g, {}, {}
        )
        assert result == 0

        # Send two messages
        g.channel_send("pipe", prog.entity_id("m1"))
        g.channel_send("pipe", prog.entity_id("m2"))

        result = _eval_expr(
            {"count": {"channel": "pipe"}},
            {}, g, {}, {}
        )
        assert result == 2


# =============================================================================
# IPC DEMO — FULL PROGRAM
# =============================================================================

class TestIPCDemo:
    """Test the IPC demo program."""

    def setup_method(self):
        self.prog = HerbProgram(IPC_DEMO)
        self.g = self.prog.load()

    def test_validation_clean(self):
        """IPC demo validates cleanly."""
        errors = validate_program(IPC_DEMO)
        assert errors == []

    def test_boot_schedules_proc_a(self):
        """proc_A (priority 5) gets CPU0 first."""
        self.g.run()
        assert self.prog.where_is("proc_A") == "CPU0"
        assert self.prog.where_is("proc_B") == "READY_QUEUE"

    def test_channels_exist(self):
        """Both channels are defined."""
        assert "pipe_AB" in self.g.channels
        assert "fd_pipe_AB" in self.g.channels

    def test_message_send(self):
        """proc_A sends message from outbox through channel."""
        self.g.run()  # Boot

        self.prog.create_entity("send_sig", "Signal", "SEND_MSG_REQUEST")
        self.g.run()

        # Message should be in channel buffer
        ch = self.g.channels["pipe_AB"]
        msg_id = self.prog.entity_id("msg1")
        assert self.g.where_is(msg_id) == ch["buffer_container"]

        # Message NOT in proc_A's outbox anymore
        proc_a = self.prog.entity_id("proc_A")
        outbox = self.g.get_scoped_container(proc_a, "OUTBOX")
        assert msg_id not in self.g.contents_of(outbox)

    def test_message_receive_and_react(self):
        """proc_B receives message and tension reacts to it."""
        self.g.run()  # Boot: proc_A on CPU

        # Send message
        self.prog.create_entity("send_sig", "Signal", "SEND_MSG_REQUEST")
        self.g.run()

        # Block proc_A so proc_B gets CPU
        self.g.move("block_process",
                    self.prog.entity_id("proc_A"),
                    self.prog.container_id("BLOCKED"),
                    cause="io_wait")
        self.g.run()  # proc_B gets CPU

        assert self.prog.where_is("proc_B") == "CPU0"

        # proc_B should receive the message and react
        self.g.run()  # Receive + react

        proc_b = self.prog.entity_id("proc_B")
        processed = self.g.get_scoped_container(proc_b, "PROCESSED")
        msg_id = self.prog.entity_id("msg1")

        # Message was received, reacted to, and moved to PROCESSED
        assert msg_id in self.g.contents_of(processed)

        # React: messages_received incremented exactly once
        assert self.prog.get_property("proc_B", "messages_received") == 1

    def test_fd_passing(self):
        """proc_A passes FD to proc_B through channel."""
        self.g.run()  # Boot: proc_A on CPU

        # First open an FD
        proc_a = self.prog.entity_id("proc_A")
        a_free = self.g.get_scoped_container(proc_a, "FD_FREE")
        a_open = self.g.get_scoped_container(proc_a, "FD_OPEN")

        fd_id = self.prog.entity_id("fd0_A")

        # Open it (need to move from FD_FREE to FD_OPEN within proc_A)
        self.g.move("open_fd", fd_id, a_open)
        assert self.g.where_is(fd_id) == a_open

        # Send FD through fd channel
        self.prog.create_entity("fd_sig", "Signal", "SEND_FD_REQUEST")
        self.g.run()

        # FD should be in fd channel buffer
        ch = self.g.channels["fd_pipe_AB"]
        assert self.g.where_is(fd_id) == ch["buffer_container"]

        # FD NOT in proc_A's scope
        assert fd_id not in self.g.contents_of(a_open)
        assert fd_id not in self.g.contents_of(a_free)

        # Block proc_A so proc_B gets CPU
        self.g.move("block_process",
                    self.prog.entity_id("proc_A"),
                    self.prog.container_id("BLOCKED"),
                    cause="io_wait")
        self.g.run()

        # proc_B receives the FD
        proc_b = self.prog.entity_id("proc_B")
        b_free = self.g.get_scoped_container(proc_b, "FD_FREE")
        assert fd_id in self.g.contents_of(b_free)

    def test_fd_after_transfer_sender_cant_use(self):
        """After FD passes to proc_B, proc_A can't use it."""
        self.g.run()  # Boot

        proc_a = self.prog.entity_id("proc_A")
        a_open = self.g.get_scoped_container(proc_a, "FD_OPEN")
        fd_id = self.prog.entity_id("fd0_A")

        # Open FD
        self.g.move("open_fd", fd_id, a_open)

        # Send through channel
        self.prog.create_entity("fd_sig", "Signal", "SEND_FD_REQUEST")
        self.g.run()

        # Block A, B gets CPU, B receives FD
        self.g.move("block_process",
                    self.prog.entity_id("proc_A"),
                    self.prog.container_id("BLOCKED"),
                    cause="io_wait")
        self.g.run()

        # FD is in B's scope now. A can't use it.
        exists, reason = self.g.operation_exists("open_fd", fd_id, a_open)
        assert not exists

    def test_isolation_outside_channels(self):
        """Cross-scope access without channel is impossible."""
        self.g.run()  # Boot

        proc_a = self.prog.entity_id("proc_A")
        proc_b = self.prog.entity_id("proc_B")

        fd_a = self.prog.entity_id("fd0_A")
        b_open = self.g.get_scoped_container(proc_b, "FD_OPEN")

        # Try direct cross-scope move — doesn't exist
        exists, reason = self.g.operation_exists("open_fd", fd_a, b_open)
        assert not exists
        assert "isolation" in reason.lower()

    def test_nesting_depth_bound_applied(self):
        """IPC demo has max_nesting_depth=3."""
        assert self.g.max_nesting_depth == 3


# =============================================================================
# VALIDATION — NEW FEATURES
# =============================================================================

class TestIPCValidation:
    """Test validation for channels and new emit types."""

    def test_channel_unknown_sender(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C"}],
            "entities": [{"name": "a", "type": "T", "in": "C"}],
            "channels": [{"name": "ch", "from": "ghost", "to": "a"}],
        }
        errors = validate_program(spec)
        assert any("ghost" in e for e in errors)

    def test_channel_unknown_receiver(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C"}],
            "entities": [{"name": "a", "type": "T", "in": "C"}],
            "channels": [{"name": "ch", "from": "a", "to": "ghost"}],
        }
        errors = validate_program(spec)
        assert any("ghost" in e for e in errors)

    def test_channel_unknown_entity_type(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C"}],
            "entities": [
                {"name": "a", "type": "T", "in": "C"},
                {"name": "b", "type": "T", "in": "C"},
            ],
            "channels": [
                {"name": "ch", "from": "a", "to": "b",
                 "entity_type": "Nonexistent"},
            ],
        }
        errors = validate_program(spec)
        assert any("Nonexistent" in e for e in errors)

    def test_send_emit_unknown_channel(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "tensions": [{
                "name": "bad",
                "match": [{"bind": "x", "in": "C"}],
                "emit": [{"send": "ghost_channel", "entity": "x"}],
            }],
        }
        errors = validate_program(spec)
        assert any("ghost_channel" in e for e in errors)

    def test_receive_emit_unknown_channel(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "tensions": [{
                "name": "bad",
                "match": [{"bind": "x", "in": "C"}],
                "emit": [{"receive": "ghost", "entity": "x",
                          "to": "C"}],
            }],
        }
        errors = validate_program(spec)
        assert any("ghost" in e for e in errors)

    def test_receive_emit_missing_to(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "entities": [
                {"name": "a", "type": "T", "in": "C"},
                {"name": "b", "type": "T", "in": "C"},
            ],
            "channels": [{"name": "ch", "from": "a", "to": "b"}],
            "tensions": [{
                "name": "bad",
                "match": [{"bind": "x", "in": "C"}],
                "emit": [{"receive": "ch", "entity": "x"}],
            }],
        }
        errors = validate_program(spec)
        assert any("missing 'to'" in e for e in errors)

    def test_send_emit_missing_entity(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "entities": [
                {"name": "a", "type": "T", "in": "C"},
                {"name": "b", "type": "T", "in": "C"},
            ],
            "channels": [{"name": "ch", "from": "a", "to": "b"}],
            "tensions": [{
                "name": "bad",
                "match": [{"bind": "x", "in": "C"}],
                "emit": [{"send": "ch"}],
            }],
        }
        errors = validate_program(spec)
        assert any("missing 'entity'" in e for e in errors)

    def test_duplicate_emit_missing_in(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "tensions": [{
                "name": "bad",
                "match": [{"bind": "x", "in": "C"}],
                "emit": [{"duplicate": "x"}],
            }],
        }
        errors = validate_program(spec)
        assert any("missing 'in'" in e for e in errors)

    def test_channel_match_unknown_channel(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "tensions": [{
                "name": "bad",
                "match": [
                    {"bind": "x", "in": {"channel": "nonexistent"}},
                ],
                "emit": [],
            }],
        }
        errors = validate_program(spec)
        assert any("nonexistent" in e for e in errors)

    def test_invalid_nesting_depth(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C"}],
            "max_nesting_depth": 0,
        }
        errors = validate_program(spec)
        assert any("nesting" in e.lower() for e in errors)

    def test_ipc_demo_validates_clean(self):
        """Full IPC demo validates without errors."""
        errors = validate_program(IPC_DEMO)
        assert errors == []


# =============================================================================
# BACKWARD COMPATIBILITY
# =============================================================================

class TestBackwardCompatSession31:
    """Ensure all original programs still work unchanged."""

    def test_fifo_scheduler(self):
        prog = HerbProgram(SCHEDULER)
        g = prog.load()
        g.run()
        assert prog.where_is("init") == "CPU0"
        assert prog.where_is("shell") == "CPU1"

    def test_priority_scheduler(self):
        prog = HerbProgram(PRIORITY_SCHEDULER)
        g = prog.load()
        g.run()
        assert prog.where_is("daemon") == "CPU0"
        assert prog.where_is("shell") == "CPU1"

    def test_dom_layout(self):
        prog = HerbProgram(DOM_LAYOUT)
        g = prog.load()
        ops = g.run()
        assert ops == 12
        assert prog.where_is("header") == "CLEAN"

    def test_economy(self):
        prog = HerbProgram(ECONOMY)
        g = prog.load()
        total = sum(prog.get_property(n, "gold") or 0
                    for n in ["alice", "bob", "charlie", "treasury"])
        assert total == 1000

    def test_multiprocess_os(self):
        prog = HerbProgram(MULTI_PROCESS_OS)
        g = prog.load()
        g.run()
        assert prog.where_is("proc_A") == "CPU0"

    def test_all_validations_clean(self):
        for spec in [SCHEDULER, PRIORITY_SCHEDULER, DOM_LAYOUT,
                     ECONOMY, MULTI_PROCESS_OS]:
            errors = validate_program(spec)
            assert errors == [], f"Validation errors: {errors}"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
