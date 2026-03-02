"""
Tests for Session 30: Scoped Containers + Property Mutation.

Proves that the new features work correctly:
1. Scoped containers — per-entity isolated namespaces
2. Scoped moves — operations within a scope, cross-scope impossible
3. Property mutation — set non-conserved properties from tensions
4. Multi-process OS demo — per-process FD tables, time_slice, preemption
5. Backward compatibility — all existing programs still work
"""

import pytest
from herb_move import (
    MoveGraph, ContainerKind, IntendedMove,
    IntendedTransfer, IntendedCreate, IntendedSet
)
from herb_program import HerbProgram, validate_program, _eval_expr
from herb_scheduler import SCHEDULER
from herb_scheduler_priority import PRIORITY_SCHEDULER
from herb_economy import ECONOMY
from herb_dom import DOM_LAYOUT
from herb_multiprocess import MULTI_PROCESS_OS


# =============================================================================
# SCOPED CONTAINERS — RUNTIME LEVEL
# =============================================================================

class TestScopedContainersRuntime:
    """Test scoped containers at the MoveGraph level."""

    def test_scoped_containers_created_on_entity_creation(self):
        """Entity with scoped type gets its own containers."""
        g = MoveGraph()
        fd_type = g.define_entity_type("FD")
        proc_type = g.define_entity_type("Process")
        c = g.define_container("Q", entity_type=proc_type)

        g.define_entity_type_scopes(proc_type, [
            {"name": "FD_FREE", "kind": ContainerKind.SIMPLE, "entity_type": fd_type},
            {"name": "FD_OPEN", "kind": ContainerKind.SIMPLE, "entity_type": fd_type},
        ])

        p = g.create_entity(proc_type, "proc_A", c)

        # Entity should have scoped containers
        assert p in g.entity_scoped_containers
        scoped = g.entity_scoped_containers[p]
        assert "FD_FREE" in scoped
        assert "FD_OPEN" in scoped

        # Containers should exist in the graph
        free_id = scoped["FD_FREE"]
        open_id = scoped["FD_OPEN"]
        assert free_id in g.containers
        assert open_id in g.containers
        assert g.containers[free_id].name == "proc_A::FD_FREE"
        assert g.containers[open_id].name == "proc_A::FD_OPEN"

    def test_scoped_containers_isolated_per_entity(self):
        """Each entity gets its OWN scoped containers."""
        g = MoveGraph()
        fd_type = g.define_entity_type("FD")
        proc_type = g.define_entity_type("Process")
        c = g.define_container("Q", entity_type=proc_type)

        g.define_entity_type_scopes(proc_type, [
            {"name": "FD_FREE", "kind": ContainerKind.SIMPLE, "entity_type": fd_type},
        ])

        p1 = g.create_entity(proc_type, "proc_A", c)
        p2 = g.create_entity(proc_type, "proc_B", c)

        # Different container IDs
        free1 = g.get_scoped_container(p1, "FD_FREE")
        free2 = g.get_scoped_container(p2, "FD_FREE")
        assert free1 != free2
        assert free1 is not None
        assert free2 is not None

    def test_get_scoped_container(self):
        """get_scoped_container resolves correctly."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        g.define_entity_type_scopes(t, [
            {"name": "INBOX", "kind": ContainerKind.SIMPLE},
        ])

        e = g.create_entity(t, "x", c)
        inbox = g.get_scoped_container(e, "INBOX")
        assert inbox is not None
        assert g.containers[inbox].name == "x::INBOX"

    def test_get_scoped_container_nonexistent(self):
        """get_scoped_container returns None for missing scope."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        e = g.create_entity(t, "x", c)  # No scoped containers defined

        assert g.get_scoped_container(e, "WHATEVER") is None
        assert g.get_scoped_container(9999, "WHATEVER") is None

    def test_scoped_container_ownership(self):
        """Container owner tracked correctly."""
        g = MoveGraph()
        fd_type = g.define_entity_type("FD")
        proc_type = g.define_entity_type("Process")
        c = g.define_container("Q", entity_type=proc_type)
        g.define_entity_type_scopes(proc_type, [
            {"name": "FD_FREE", "kind": ContainerKind.SIMPLE, "entity_type": fd_type},
        ])

        p = g.create_entity(proc_type, "proc", c)
        free_id = g.get_scoped_container(p, "FD_FREE")

        assert g.container_owner[free_id] == p

    def test_entities_in_scoped_containers(self):
        """Entities can be placed in scoped containers."""
        g = MoveGraph()
        fd_type = g.define_entity_type("FD")
        proc_type = g.define_entity_type("Process")
        c = g.define_container("Q", entity_type=proc_type)
        g.define_entity_type_scopes(proc_type, [
            {"name": "FD_FREE", "kind": ContainerKind.SIMPLE, "entity_type": fd_type},
        ])

        p = g.create_entity(proc_type, "proc", c)
        free_id = g.get_scoped_container(p, "FD_FREE")

        fd = g.create_entity(fd_type, "fd0", free_id)

        assert g.where_is(fd) == free_id
        assert fd in g.contents_of(free_id)

    def test_entity_without_scoped_type(self):
        """Entity of non-scoped type has no scoped containers."""
        g = MoveGraph()
        t = g.define_entity_type("Plain")
        c = g.define_container("C", entity_type=t)
        e = g.create_entity(t, "x", c)

        assert e not in g.entity_scoped_containers


# =============================================================================
# SCOPED MOVES — RUNTIME LEVEL
# =============================================================================

class TestScopedMovesRuntime:
    """Test scoped moves at the MoveGraph level."""

    def setup_method(self):
        """Create a graph with two processes and scoped FD containers."""
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

        # Scoped move: FD_FREE -> FD_OPEN within same process
        self.g.define_move("open_fd",
            is_scoped=True,
            scoped_from=["FD_FREE"],
            scoped_to=["FD_OPEN"],
            entity_type=self.fd_type)

        self.g.define_move("close_fd",
            is_scoped=True,
            scoped_from=["FD_OPEN"],
            scoped_to=["FD_FREE"],
            entity_type=self.fd_type)

        # Create FDs in each process's scope
        free1 = self.g.get_scoped_container(self.p1, "FD_FREE")
        free2 = self.g.get_scoped_container(self.p2, "FD_FREE")
        self.fd_a = self.g.create_entity(self.fd_type, "fd_a", free1)
        self.fd_b = self.g.create_entity(self.fd_type, "fd_b", free2)

    def test_scoped_move_within_same_entity(self):
        """Scoped move works within the same entity's containers."""
        open1 = self.g.get_scoped_container(self.p1, "FD_OPEN")
        result = self.g.move("open_fd", self.fd_a, open1)
        assert result is not None
        assert self.g.where_is(self.fd_a) == open1

    def test_scoped_move_cross_entity_blocked(self):
        """Scoped move across different entities doesn't exist."""
        # Try to move fd_a (in proc_A's scope) to proc_B's FD_OPEN
        open2 = self.g.get_scoped_container(self.p2, "FD_OPEN")
        exists, reason = self.g.operation_exists("open_fd", self.fd_a, open2)
        assert not exists
        assert "isolation" in reason.lower()

        result = self.g.move("open_fd", self.fd_a, open2)
        assert result is None

    def test_scoped_move_close(self):
        """Scoped close move works."""
        open1 = self.g.get_scoped_container(self.p1, "FD_OPEN")
        free1 = self.g.get_scoped_container(self.p1, "FD_FREE")

        self.g.move("open_fd", self.fd_a, open1)
        assert self.g.where_is(self.fd_a) == open1

        result = self.g.move("close_fd", self.fd_a, free1)
        assert result is not None
        assert self.g.where_is(self.fd_a) == free1

    def test_scoped_move_wrong_scope_name(self):
        """Move from wrong scope container name doesn't exist."""
        # fd_a is in FD_FREE; try close_fd which requires FD_OPEN as source
        free1 = self.g.get_scoped_container(self.p1, "FD_FREE")
        exists, reason = self.g.operation_exists("close_fd", self.fd_a, free1)
        assert not exists

    def test_operations_independent_per_process(self):
        """FD operations on one process don't affect another."""
        open1 = self.g.get_scoped_container(self.p1, "FD_OPEN")
        free2 = self.g.get_scoped_container(self.p2, "FD_FREE")

        # Open fd_a in proc_A
        self.g.move("open_fd", self.fd_a, open1)

        # fd_b still in proc_B's FD_FREE
        assert self.g.where_is(self.fd_b) == free2


# =============================================================================
# PROPERTY MUTATION — RUNTIME LEVEL
# =============================================================================

class TestPropertyMutationRuntime:
    """Test property mutation (IntendedSet) at the MoveGraph level."""

    def test_intended_set_changes_property(self):
        """IntendedSet changes an entity property via tension."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        e = g.create_entity(t, "x", c, {"counter": 10})

        def decrement(graph):
            val = graph.get_property(e, "counter")
            if val and val > 0:
                return [IntendedSet(e, "counter", val - 1)]
            return []

        g.define_tension("tick", decrement)
        ops = g.step()

        assert len(ops) == 1
        assert g.get_property(e, "counter") == 9

    def test_set_conserved_property_rejected(self):
        """Setting a conserved property (in a pool) is rejected."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        g.define_pool("gold", "gold")
        e = g.create_entity(t, "x", c, {"gold": 100})

        def steal(graph):
            return [IntendedSet(e, "gold", 999)]

        g.define_tension("cheat", steal)
        ops = g.step()

        assert len(ops) == 0  # Rejected
        assert g.get_property(e, "gold") == 100  # Unchanged

    def test_set_nonexistent_entity_rejected(self):
        """Setting property on nonexistent entity returns None."""
        g = MoveGraph()
        result = g._set_from_tension(IntendedSet(9999, "x", 1), "test")
        assert result is None

    def test_set_logs_operation(self):
        """Property mutation is logged for provenance."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        e = g.create_entity(t, "x", c, {"score": 0})

        def bump(graph):
            return [IntendedSet(e, "score", 10)]

        g.define_tension("bump", bump)
        g.step()

        set_ops = [op for op in g.operations if op.op_type == "set_property"]
        assert len(set_ops) == 1
        assert set_ops[0].params["property"] == "score"
        assert set_ops[0].params["old_value"] == 0
        assert set_ops[0].params["new_value"] == 10
        assert set_ops[0].cause == "tension:bump"

    def test_set_multiple_properties_in_one_step(self):
        """Multiple property sets in one step."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)
        e = g.create_entity(t, "x", c, {"a": 1, "b": 2})

        def multi_set(graph):
            return [
                IntendedSet(e, "a", 10),
                IntendedSet(e, "b", 20),
            ]

        g.define_tension("multi", multi_set)
        ops = g.step()

        assert len(ops) == 2
        assert g.get_property(e, "a") == 10
        assert g.get_property(e, "b") == 20


# =============================================================================
# PROPERTY MUTATION — PROGRAM LEVEL
# =============================================================================

class TestPropertyMutationProgram:
    """Test property mutation through the program spec."""

    def test_set_emit_in_tension(self):
        """Tension with set emit changes property."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "SIG", "entity_type": "T"},
                {"name": "DONE", "entity_type": "T"},
                {"name": "WORLD", "entity_type": "T"},
            ],
            "moves": [
                {"name": "ack", "from": ["SIG"], "to": ["DONE"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "bump_score",
                "match": [
                    {"bind": "sig", "in": "SIG", "select": "first"},
                    {"bind": "target", "in": "WORLD", "select": "first"},
                ],
                "emit": [
                    {"set": "target", "property": "score",
                     "value": {"op": "+",
                               "left": {"prop": "score", "of": "target"},
                               "right": 10}},
                    {"move": "ack", "entity": "sig", "to": "DONE"},
                ],
            }],
            "entities": [
                {"name": "player", "type": "T", "in": "WORLD",
                 "properties": {"score": 0}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        prog.create_entity("signal", "T", "SIG")
        g.run()

        assert prog.get_property("player", "score") == 10

    def test_set_conserved_blocked_in_program(self):
        """Set on conserved property blocked in program tension."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "W", "entity_type": "T"},
                {"name": "SIG", "entity_type": "T"},
                {"name": "DONE", "entity_type": "T"},
            ],
            "pools": [{"name": "gold", "property": "gold"}],
            "moves": [
                {"name": "ack", "from": ["SIG"], "to": ["DONE"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "cheat",
                "match": [
                    {"bind": "sig", "in": "SIG", "select": "first"},
                ],
                "emit": [
                    {"set": "player", "property": "gold", "value": 9999},
                    {"move": "ack", "entity": "sig", "to": "DONE"},
                ],
            }],
            "entities": [
                {"name": "player", "type": "T", "in": "W",
                 "properties": {"gold": 100}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        prog.create_entity("hack", "T", "SIG")
        g.run()

        # Gold unchanged — conserved property rejected by set
        assert prog.get_property("player", "gold") == 100

    def test_set_with_guard(self):
        """Set emit with guard expression."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "WORLD", "entity_type": "T"},
            ],
            "moves": [],
            "tensions": [{
                "name": "countdown",
                "match": [
                    {"bind": "x", "in": "WORLD", "select": "first",
                     "where": {"op": ">",
                               "left": {"prop": "timer", "of": "x"},
                               "right": 0}},
                ],
                "emit": [
                    {"set": "x", "property": "timer",
                     "value": {"op": "-",
                               "left": {"prop": "timer", "of": "x"},
                               "right": 1}},
                ],
            }],
            "entities": [
                {"name": "bomb", "type": "T", "in": "WORLD",
                 "properties": {"timer": 3}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        # Timer counts down to 0 then stops (where: timer > 0)
        assert prog.get_property("bomb", "timer") == 0


# =============================================================================
# SCOPED CONTAINERS — PROGRAM LEVEL
# =============================================================================

class TestScopedContainersProgram:
    """Test scoped containers through the program spec."""

    def test_entity_type_with_scoped_containers(self):
        """Entity type declares scoped container templates."""
        spec = {
            "entity_types": [
                {"name": "Process", "scoped_containers": [
                    {"name": "INBOX", "kind": "simple"},
                ]},
            ],
            "containers": [
                {"name": "WORLD", "entity_type": "Process"},
            ],
            "moves": [],
            "tensions": [],
            "entities": [
                {"name": "proc", "type": "Process", "in": "WORLD"},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        proc_id = prog.entity_id("proc")
        inbox = g.get_scoped_container(proc_id, "INBOX")
        assert inbox is not None
        assert g.containers[inbox].name == "proc::INBOX"

    def test_scoped_entity_placement(self):
        """Entities placed in scoped containers via program spec."""
        spec = {
            "entity_types": [
                {"name": "Box", "scoped_containers": [
                    {"name": "ITEMS", "kind": "simple", "entity_type": "Item"},
                ]},
                {"name": "Item"},
            ],
            "containers": [
                {"name": "WORLD", "entity_type": "Box"},
            ],
            "moves": [],
            "tensions": [],
            "entities": [
                {"name": "box1", "type": "Box", "in": "WORLD"},
                {"name": "thing", "type": "Item",
                 "in": {"scope": "box1", "container": "ITEMS"}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        # thing should be in box1's ITEMS container
        box_id = prog.entity_id("box1")
        items_cid = g.get_scoped_container(box_id, "ITEMS")
        thing_id = prog.entity_id("thing")
        assert g.where_is(thing_id) == items_cid

    def test_scoped_match_clause(self):
        """Tension match clause queries scoped containers."""
        spec = {
            "entity_types": [
                {"name": "Box", "scoped_containers": [
                    {"name": "SRC", "kind": "simple", "entity_type": "Ball"},
                    {"name": "DST", "kind": "simple", "entity_type": "Ball"},
                ]},
                {"name": "Ball"},
            ],
            "containers": [
                {"name": "ACTIVE", "kind": "slot", "entity_type": "Box"},
            ],
            "moves": [
                {"name": "toss", "scoped_from": ["SRC"], "scoped_to": ["DST"],
                 "entity_type": "Ball"},
            ],
            "tensions": [{
                "name": "auto_toss",
                "match": [
                    {"bind": "box", "in": "ACTIVE", "select": "first"},
                    {"bind": "ball", "in": {"scope": "box", "container": "SRC"},
                     "select": "each"},
                ],
                "emit": [
                    {"move": "toss", "entity": "ball",
                     "to": {"scope": "box", "container": "DST"}},
                ],
            }],
            "entities": [
                {"name": "box1", "type": "Box", "in": "ACTIVE"},
                {"name": "b1", "type": "Ball",
                 "in": {"scope": "box1", "container": "SRC"}},
                {"name": "b2", "type": "Ball",
                 "in": {"scope": "box1", "container": "SRC"}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        # Both balls should move from SRC to DST within box1's scope
        box_id = prog.entity_id("box1")
        dst = g.get_scoped_container(box_id, "DST")
        assert prog.entity_id("b1") in g.contents_of(dst)
        assert prog.entity_id("b2") in g.contents_of(dst)

    def test_scoped_match_optional(self):
        """Scoped match with required=False handles empty scope."""
        spec = {
            "entity_types": [
                {"name": "Box", "scoped_containers": [
                    {"name": "ITEMS", "kind": "simple", "entity_type": "Item"},
                ]},
                {"name": "Item"},
                {"name": "Signal"},
            ],
            "containers": [
                {"name": "WORLD", "kind": "slot", "entity_type": "Box"},
                {"name": "SIG", "entity_type": "Signal"},
                {"name": "DONE", "entity_type": "Signal"},
            ],
            "moves": [
                {"name": "ack", "from": ["SIG"], "to": ["DONE"],
                 "entity_type": "Signal"},
            ],
            "tensions": [{
                "name": "check",
                "match": [
                    {"bind": "sig", "in": "SIG", "select": "first"},
                    {"bind": "box", "in": "WORLD", "select": "first"},
                    {"bind": "item", "in": {"scope": "box", "container": "ITEMS"},
                     "select": "first", "required": False},
                ],
                "emit": [
                    {"move": "ack", "entity": "sig", "to": "DONE"},
                ],
            }],
            "entities": [
                {"name": "box1", "type": "Box", "in": "WORLD"},
                # No items in box — scope is empty
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        prog.create_entity("s", "Signal", "SIG")
        g.run()

        # Signal consumed even though scoped container is empty
        assert prog.where_is("s") == "DONE"


# =============================================================================
# MULTI-PROCESS OS DEMO
# =============================================================================

class TestMultiProcessOS:
    """Test the multi-process OS demo."""

    def setup_method(self):
        self.prog = HerbProgram(MULTI_PROCESS_OS)
        self.g = self.prog.load()

    def test_validation_clean(self):
        """Multi-process OS program validates cleanly."""
        errors = validate_program(MULTI_PROCESS_OS)
        assert errors == []

    def test_boot_schedules_highest_priority(self):
        """Boot: proc_A (priority 5) gets CPU0."""
        self.g.run()
        assert self.prog.where_is("proc_A") == "CPU0"
        assert self.prog.where_is("proc_B") == "READY_QUEUE"

    def test_each_process_has_own_fd_table(self):
        """Each process has isolated FD containers."""
        self.g.run()  # Boot
        proc_a = self.prog.entity_id("proc_A")
        proc_b = self.prog.entity_id("proc_B")

        a_free = self.g.get_scoped_container(proc_a, "FD_FREE")
        b_free = self.g.get_scoped_container(proc_b, "FD_FREE")
        a_open = self.g.get_scoped_container(proc_a, "FD_OPEN")
        b_open = self.g.get_scoped_container(proc_b, "FD_OPEN")

        # All different containers
        assert len({a_free, b_free, a_open, b_open}) == 4

        # proc_A has 3 FDs, proc_B has 2
        assert len(self.g.contents_of(a_free)) == 3
        assert len(self.g.contents_of(b_free)) == 2

    def test_fd_open_within_process(self):
        """Opening an FD moves it within the running process's scope."""
        self.g.run()  # Boot: proc_A on CPU0

        self.prog.create_entity("open1", "Signal", "OPEN_REQUEST")
        self.g.run()

        proc_a = self.prog.entity_id("proc_A")
        a_open = self.g.get_scoped_container(proc_a, "FD_OPEN")
        a_free = self.g.get_scoped_container(proc_a, "FD_FREE")

        assert len(self.g.contents_of(a_open)) == 1
        assert len(self.g.contents_of(a_free)) == 2

    def test_fd_open_doesnt_touch_other_process(self):
        """Opening FD for proc_A doesn't affect proc_B's FDs."""
        self.g.run()  # Boot

        self.prog.create_entity("open1", "Signal", "OPEN_REQUEST")
        self.g.run()

        proc_b = self.prog.entity_id("proc_B")
        b_free = self.g.get_scoped_container(proc_b, "FD_FREE")
        b_open = self.g.get_scoped_container(proc_b, "FD_OPEN")

        # proc_B's FDs untouched
        assert len(self.g.contents_of(b_free)) == 2
        assert len(self.g.contents_of(b_open)) == 0

    def test_cross_process_fd_move_impossible(self):
        """Moving an FD from proc_A to proc_B's container doesn't exist."""
        self.g.run()

        fd_a = self.prog.entity_id("fd0_A")
        proc_b = self.prog.entity_id("proc_B")
        b_open = self.g.get_scoped_container(proc_b, "FD_OPEN")

        exists, reason = self.g.operation_exists("open_fd", fd_a, b_open)
        assert not exists
        assert "isolation" in reason.lower()

    def test_time_slice_decrement(self):
        """Timer tick decrements running process's time_slice."""
        self.g.run()  # Boot
        assert self.prog.get_property("proc_A", "time_slice") == 3

        self.prog.create_entity("tick1", "Signal", "TICK_SIGNAL")
        self.g.run()
        assert self.prog.get_property("proc_A", "time_slice") == 2

        self.prog.create_entity("tick2", "Signal", "TICK_SIGNAL")
        self.g.run()
        assert self.prog.get_property("proc_A", "time_slice") == 1

    def test_preemption_on_time_slice_zero(self):
        """Process preempted when time_slice reaches 0."""
        self.g.run()  # Boot

        # Tick 3 times: 3 -> 2 -> 1 -> 0 -> preempt
        for i in range(3):
            self.prog.create_entity(f"tick_{i}", "Signal", "TICK_SIGNAL")
            self.g.run()

        # After 3 ticks, time_slice hit 0, process was preempted + rescheduled
        # (proc_A gets rescheduled because it has higher priority)
        assert self.prog.get_property("proc_A", "time_slice") == 3  # Reset

    def test_blocking_allows_other_process(self):
        """Blocking running process lets the other one run."""
        self.g.run()  # Boot: proc_A on CPU0

        # Block proc_A manually
        self.g.move("block_process",
                    self.prog.entity_id("proc_A"),
                    self.prog.container_id("BLOCKED"),
                    cause='io_request')
        self.g.run()

        assert self.prog.where_is("proc_A") == "BLOCKED"
        assert self.prog.where_is("proc_B") == "CPU0"

    def test_proc_b_can_open_its_own_fds(self):
        """When proc_B is running, FD operations use B's FD table."""
        self.g.run()  # Boot

        # Block proc_A, proc_B gets CPU
        self.g.move("block_process",
                    self.prog.entity_id("proc_A"),
                    self.prog.container_id("BLOCKED"),
                    cause='io_request')
        self.g.run()
        assert self.prog.where_is("proc_B") == "CPU0"

        # Open FD for proc_B
        self.prog.create_entity("open_b", "Signal", "OPEN_REQUEST")
        self.g.run()

        proc_b = self.prog.entity_id("proc_B")
        b_open = self.g.get_scoped_container(proc_b, "FD_OPEN")
        b_free = self.g.get_scoped_container(proc_b, "FD_FREE")

        assert len(self.g.contents_of(b_open)) == 1
        assert len(self.g.contents_of(b_free)) == 1

        # proc_A's FDs unchanged
        proc_a = self.prog.entity_id("proc_A")
        a_open = self.g.get_scoped_container(proc_a, "FD_OPEN")
        a_free = self.g.get_scoped_container(proc_a, "FD_FREE")
        assert len(self.g.contents_of(a_open)) == 0
        assert len(self.g.contents_of(a_free)) == 3

    def test_fd_close_within_process(self):
        """Closing an FD moves it back to FD_FREE."""
        self.g.run()  # Boot

        # Open then close
        self.prog.create_entity("open1", "Signal", "OPEN_REQUEST")
        self.g.run()
        self.prog.create_entity("close1", "Signal", "CLOSE_REQUEST")
        self.g.run()

        proc_a = self.prog.entity_id("proc_A")
        a_free = self.g.get_scoped_container(proc_a, "FD_FREE")
        a_open = self.g.get_scoped_container(proc_a, "FD_OPEN")

        assert len(self.g.contents_of(a_free)) == 3
        assert len(self.g.contents_of(a_open)) == 0

    def test_full_scenario(self):
        """Complete scenario: boot, open FDs, tick, preempt, switch."""
        g = self.g

        # Boot: proc_A gets CPU0
        g.run()
        assert self.prog.where_is("proc_A") == "CPU0"

        # proc_A opens 2 FDs
        self.prog.create_entity("o1", "Signal", "OPEN_REQUEST")
        g.run()
        self.prog.create_entity("o2", "Signal", "OPEN_REQUEST")
        g.run()

        proc_a = self.prog.entity_id("proc_A")
        a_open = g.get_scoped_container(proc_a, "FD_OPEN")
        assert len(g.contents_of(a_open)) == 2

        # Block proc_A, proc_B gets CPU
        g.move("block_process",
               self.prog.entity_id("proc_A"),
               self.prog.container_id("BLOCKED"),
               cause='io')
        g.run()
        assert self.prog.where_is("proc_B") == "CPU0"

        # proc_B opens 1 FD
        self.prog.create_entity("o3", "Signal", "OPEN_REQUEST")
        g.run()

        proc_b = self.prog.entity_id("proc_B")
        b_open = g.get_scoped_container(proc_b, "FD_OPEN")
        assert len(g.contents_of(b_open)) == 1

        # proc_A's FDs unchanged while blocked
        assert len(g.contents_of(a_open)) == 2

        # Unblock proc_A — it goes to READY_QUEUE (CPU0 occupied by proc_B)
        g.move("unblock",
               self.prog.entity_id("proc_A"),
               self.prog.container_id("READY_QUEUE"),
               cause='io_done')
        g.run()

        # No priority preemption mechanism — proc_B keeps CPU, proc_A waits
        assert self.prog.where_is("proc_A") == "READY_QUEUE"
        assert self.prog.where_is("proc_B") == "CPU0"

        # proc_A's FDs still intact while it waits
        assert len(g.contents_of(a_open)) == 2

    def test_timer_tick_empty_cpu(self):
        """Timer tick with empty CPU consumes signal without error."""
        # Don't boot — CPU empty
        self.g.move("preempt",
                    self.prog.entity_id("proc_A"),
                    self.prog.container_id("READY_QUEUE"))
        # Actually proc_A is already in READY_QUEUE, this will fail silently
        # Let's just not run boot and send a tick
        # First remove all entities from READY_QUEUE for this test

        # Actually simpler: just don't boot, manually empty things
        # The system starts with procs in READY_QUEUE, run will schedule
        # Let's test a specific scenario: after termination

        self.g.run()  # Boot: proc_A on CPU0
        self.g.move("terminate",
                    self.prog.entity_id("proc_A"),
                    self.prog.container_id("TERMINATED"),
                    cause='exit')
        self.g.run()  # proc_B gets CPU

        self.g.move("terminate",
                    self.prog.entity_id("proc_B"),
                    self.prog.container_id("TERMINATED"),
                    cause='exit')
        self.g.run()  # CPU empty now

        # Tick with empty CPU — should just consume signal
        self.prog.create_entity("tick_empty", "Signal", "TICK_SIGNAL")
        ops = self.g.run()
        assert ops > 0  # Signal consumed
        assert self.prog.where_is("tick_empty") == "SIGNAL_DONE"


# =============================================================================
# EXPRESSION EVALUATOR — SCOPED COUNT
# =============================================================================

class TestScopedExpressions:
    """Test expressions with scoped container references."""

    def test_scoped_count_expression(self):
        """Count expression works with scoped containers."""
        spec = {
            "entity_types": [
                {"name": "Box", "scoped_containers": [
                    {"name": "ITEMS", "kind": "simple", "entity_type": "Item"},
                ]},
                {"name": "Item"},
            ],
            "containers": [
                {"name": "WORLD", "kind": "slot", "entity_type": "Box"},
            ],
            "moves": [],
            "tensions": [],
            "entities": [
                {"name": "box1", "type": "Box", "in": "WORLD"},
                {"name": "a", "type": "Item",
                 "in": {"scope": "box1", "container": "ITEMS"}},
                {"name": "b", "type": "Item",
                 "in": {"scope": "box1", "container": "ITEMS"}},
                {"name": "c", "type": "Item",
                 "in": {"scope": "box1", "container": "ITEMS"}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        box_id = prog.entity_id("box1")
        # Test count expression
        result = _eval_expr(
            {"count": {"scope": "box1", "container": "ITEMS"}},
            {}, g,
            {"box1": box_id},
            {}
        )
        assert result == 3


# =============================================================================
# DYNAMIC CREATION WITH SCOPED CONTAINERS
# =============================================================================

class TestDynamicCreationScoped:
    """Test dynamic entity creation into scoped containers."""

    def test_create_into_scoped_container(self):
        """Tension can create entity into a scoped container."""
        spec = {
            "entity_types": [
                {"name": "Box", "scoped_containers": [
                    {"name": "ITEMS", "kind": "simple", "entity_type": "Item"},
                ]},
                {"name": "Item"},
                {"name": "Signal"},
            ],
            "containers": [
                {"name": "ACTIVE", "kind": "slot", "entity_type": "Box"},
                {"name": "SIG", "entity_type": "Signal"},
                {"name": "DONE", "entity_type": "Signal"},
            ],
            "moves": [
                {"name": "ack", "from": ["SIG"], "to": ["DONE"],
                 "entity_type": "Signal"},
            ],
            "tensions": [{
                "name": "spawn_item",
                "match": [
                    {"bind": "sig", "in": "SIG", "select": "first"},
                    {"bind": "box", "in": "ACTIVE", "select": "first"},
                ],
                "emit": [
                    {"create": "Item",
                     "in": {"scope": "box", "container": "ITEMS"},
                     "properties": {"value": 42}},
                    {"move": "ack", "entity": "sig", "to": "DONE"},
                ],
            }],
            "entities": [
                {"name": "box1", "type": "Box", "in": "ACTIVE"},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        # Spawn an item into box1's ITEMS
        prog.create_entity("go", "Signal", "SIG")
        g.run()

        box_id = prog.entity_id("box1")
        items_cid = g.get_scoped_container(box_id, "ITEMS")
        assert len(g.contents_of(items_cid)) == 1

        # Check the created entity has properties
        item_id = list(g.contents_of(items_cid))[0]
        assert g.get_property(item_id, "value") == 42


# =============================================================================
# VALIDATION — NEW FEATURES
# =============================================================================

class TestNewValidation:
    """Test validation for scoped containers and property mutation."""

    def test_unknown_scoped_container_type(self):
        """Unknown entity type in scoped container caught."""
        spec = {
            "entity_types": [
                {"name": "Box", "scoped_containers": [
                    {"name": "ITEMS", "entity_type": "Ghost"},
                ]},
            ],
            "containers": [],
        }
        errors = validate_program(spec)
        assert any("Ghost" in e for e in errors)

    def test_invalid_scoped_container_kind(self):
        """Invalid kind in scoped container caught."""
        spec = {
            "entity_types": [
                {"name": "Box", "scoped_containers": [
                    {"name": "ITEMS", "kind": "magic"},
                ]},
            ],
            "containers": [],
        }
        errors = validate_program(spec)
        assert any("magic" in e for e in errors)

    def test_unknown_scoped_from_in_move(self):
        """Unknown scoped_from name in move caught."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [],
            "moves": [
                {"name": "bad", "scoped_from": ["NONEXISTENT"],
                 "scoped_to": ["ALSO_BAD"]},
            ],
        }
        errors = validate_program(spec)
        assert any("NONEXISTENT" in e for e in errors)

    def test_set_emit_missing_property(self):
        """Set emit without 'property' field caught."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "tensions": [{
                "name": "bad",
                "match": [{"bind": "x", "in": "C"}],
                "emit": [{"set": "x", "value": 10}],
            }],
        }
        errors = validate_program(spec)
        assert any("property" in e for e in errors)

    def test_set_emit_missing_value(self):
        """Set emit without 'value' field caught."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "tensions": [{
                "name": "bad",
                "match": [{"bind": "x", "in": "C"}],
                "emit": [{"set": "x", "property": "score"}],
            }],
        }
        errors = validate_program(spec)
        assert any("value" in e for e in errors)

    def test_multiprocess_validates_clean(self):
        """Multi-process OS program validates cleanly."""
        errors = validate_program(MULTI_PROCESS_OS)
        assert errors == []


# =============================================================================
# BACKWARD COMPATIBILITY
# =============================================================================

class TestBackwardCompat:
    """Ensure all original programs still work unchanged."""

    def test_fifo_scheduler_unchanged(self):
        prog = HerbProgram(SCHEDULER)
        g = prog.load()
        g.run()
        assert prog.where_is("init") == "CPU0"
        assert prog.where_is("shell") == "CPU1"
        assert prog.where_is("daemon") == "READY_QUEUE"

    def test_priority_scheduler_unchanged(self):
        prog = HerbProgram(PRIORITY_SCHEDULER)
        g = prog.load()
        g.run()
        assert prog.where_is("daemon") == "CPU0"
        assert prog.where_is("shell") == "CPU1"
        assert prog.where_is("init") == "READY_QUEUE"

    def test_dom_layout_unchanged(self):
        prog = HerbProgram(DOM_LAYOUT)
        g = prog.load()
        ops = g.run()
        assert ops == 12
        assert prog.where_is("header") == "CLEAN"

    def test_economy_unchanged(self):
        prog = HerbProgram(ECONOMY)
        g = prog.load()
        total = sum(prog.get_property(n, "gold") or 0
                    for n in ["alice", "bob", "charlie", "treasury"])
        assert total == 1000

        prog.create_entity("tax1", "TaxEvent", "TAX_PENDING")
        g.run()
        total_after = sum(prog.get_property(n, "gold") or 0
                          for n in ["alice", "bob", "charlie", "treasury"])
        assert total_after == 1000

    def test_all_validations_clean(self):
        for spec in [SCHEDULER, PRIORITY_SCHEDULER, DOM_LAYOUT, ECONOMY]:
            errors = validate_program(spec)
            assert errors == [], f"Validation errors: {errors}"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
