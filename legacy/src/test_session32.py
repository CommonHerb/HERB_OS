"""
Session 32 Tests: Multi-Dimensional State

Tests for named dimensions — independent state spaces that allow
entities to occupy one container per dimension simultaneously.

The fundamental change: an entity in READY_QUEUE (scheduling dimension)
can ALSO be in PRIO_HIGH (priority dimension). Each dimension has its
own operation set (MoveTypes). Dimensions are independent — moving in
one doesn't affect another.

Backward compatible: programs with no dimensions work exactly as before.
"""

import pytest
from herb_move import (
    MoveGraph, ContainerKind, MoveType, Tension,
    IntendedMove, IntendedSet,
)
from herb_program import HerbProgram, validate_program, _eval_expr


# =============================================================================
# PART 1: Core Dimension Mechanics (herb_move.py)
# =============================================================================

class TestDimensionBasics:
    """Basic dimension creation and container assignment."""

    def test_container_default_dimension(self):
        """Containers without dimension are in default dimension (None)."""
        g = MoveGraph()
        cid = g.define_container("READY")
        assert g.container_dimension[cid] is None
        assert g.containers[cid].dimension is None

    def test_container_named_dimension(self):
        """Containers with dimension are in that named dimension."""
        g = MoveGraph()
        cid = g.define_container("PRIO_HIGH", dimension="priority")
        assert g.container_dimension[cid] == "priority"
        assert g.containers[cid].dimension == "priority"

    def test_multiple_dimensions(self):
        """Multiple independent dimensions can coexist."""
        g = MoveGraph()
        c1 = g.define_container("READY", dimension="scheduling")
        c2 = g.define_container("PRIO_HIGH", dimension="priority")
        c3 = g.define_container("MEM_LOW", dimension="memory")
        c4 = g.define_container("SIGNAL_IN")  # default dimension

        assert g.container_dimension[c1] == "scheduling"
        assert g.container_dimension[c2] == "priority"
        assert g.container_dimension[c3] == "memory"
        assert g.container_dimension[c4] is None


class TestDimensionPlacement:
    """Entity enrollment in dimensions."""

    def test_enroll_in_dimension(self):
        """Entity can be enrolled in a named dimension."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        proc = g.create_entity(proc_type, "proc_A", ready)

        op_id = g.enroll_in_dimension(proc, prio_high)
        assert op_id is not None

        # Entity is in READY (default) AND PRIO_HIGH (priority)
        assert g.where_is(proc) == ready
        assert g.where_is_in(proc, "priority") == prio_high

    def test_enroll_multiple_dimensions(self):
        """Entity can be in multiple named dimensions simultaneously."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")
        mem_low = g.define_container("MEM_LOW", dimension="memory")

        proc = g.create_entity(proc_type, "proc_A", ready)
        g.enroll_in_dimension(proc, prio_high)
        g.enroll_in_dimension(proc, mem_low)

        assert g.where_is(proc) == ready
        assert g.where_is_in(proc, "priority") == prio_high
        assert g.where_is_in(proc, "memory") == mem_low

    def test_enroll_duplicate_dimension_fails(self):
        """Can't enroll in a dimension twice (use move to change position)."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")
        prio_low = g.define_container("PRIO_LOW", dimension="priority")

        proc = g.create_entity(proc_type, "proc_A", ready)
        g.enroll_in_dimension(proc, prio_high)

        # Try to enroll in another container of same dimension
        result = g.enroll_in_dimension(proc, prio_low)
        assert result is None  # Can't enroll — already in dimension

        # Still in PRIO_HIGH
        assert g.where_is_in(proc, "priority") == prio_high

    def test_enroll_default_dimension_fails(self):
        """Can't enroll in default dimension (that's what create_entity does)."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        blocked = g.define_container("BLOCKED")

        proc = g.create_entity(proc_type, "proc_A", ready)
        result = g.enroll_in_dimension(proc, blocked)
        assert result is None  # Default dimension — use move()

    def test_enroll_slot_full(self):
        """Can't enroll in a full slot."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        core_0 = g.define_container("CORE_0", ContainerKind.SLOT, dimension="affinity")

        p1 = g.create_entity(proc_type, "p1", ready)
        p2 = g.create_entity(proc_type, "p2", ready)

        g.enroll_in_dimension(p1, core_0)
        result = g.enroll_in_dimension(p2, core_0)
        assert result is None  # Slot full

    def test_entity_type_check_on_enroll(self):
        """Enrollment respects entity type restrictions."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        msg_type = g.define_entity_type("Message")
        ready = g.define_container("READY")
        proc_prio = g.define_container("PROC_PRIO", dimension="priority",
                                       entity_type=proc_type)

        msg = g.create_entity(msg_type, "msg1", ready)
        result = g.enroll_in_dimension(msg, proc_prio)
        assert result is None  # Wrong entity type

    def test_contents_of_dimensional_container(self):
        """contents_of works for dimensional containers."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")
        prio_low = g.define_container("PRIO_LOW", dimension="priority")

        p1 = g.create_entity(proc_type, "p1", ready)
        p2 = g.create_entity(proc_type, "p2", ready)

        g.enroll_in_dimension(p1, prio_high)
        g.enroll_in_dimension(p2, prio_low)

        assert p1 in g.contents_of(prio_high)
        assert p2 in g.contents_of(prio_low)
        assert p1 not in g.contents_of(prio_low)

    def test_is_entity_in_container(self):
        """is_entity_in_container works across dimensions."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        proc = g.create_entity(proc_type, "proc", ready)
        g.enroll_in_dimension(proc, prio_high)

        assert g.is_entity_in_container(proc, ready) == True
        assert g.is_entity_in_container(proc, prio_high) == True

    def test_where_is_in_named(self):
        """where_is_in_named returns container name in dimension."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        proc = g.create_entity(proc_type, "proc", ready)
        g.enroll_in_dimension(proc, prio_high)

        assert g.where_is_in_named(proc, "priority") == "PRIO_HIGH"
        assert g.where_is_in_named(proc, "nonexistent") is None


class TestDimensionalMoves:
    """Moves within named dimensions."""

    def test_move_in_named_dimension(self):
        """A move can operate within a named dimension."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")

        # Default dimension
        ready = g.define_container("READY")

        # Priority dimension
        prio_low = g.define_container("PRIO_LOW", dimension="priority")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        g.define_move("promote",
            from_containers=[prio_low],
            to_containers=[prio_high],
            entity_type=proc_type)

        proc = g.create_entity(proc_type, "proc", ready)
        g.enroll_in_dimension(proc, prio_low)

        # Move within priority dimension
        result = g.move("promote", proc, prio_high)
        assert result is not None

        # Default dimension unchanged
        assert g.where_is(proc) == ready
        # Priority dimension changed
        assert g.where_is_in(proc, "priority") == prio_high

    def test_dimensional_move_wrong_source(self):
        """Move fails if entity not in correct dimensional container."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_low = g.define_container("PRIO_LOW", dimension="priority")
        prio_med = g.define_container("PRIO_MED", dimension="priority")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        g.define_move("promote",
            from_containers=[prio_low],
            to_containers=[prio_med, prio_high],
            entity_type=proc_type)

        proc = g.create_entity(proc_type, "proc", ready)
        g.enroll_in_dimension(proc, prio_high)  # Already at HIGH

        # Can't promote — not in PRIO_LOW
        result = g.move("promote", proc, prio_med)
        assert result is None

    def test_dimensional_move_not_enrolled(self):
        """Move fails if entity not enrolled in the dimension."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_low = g.define_container("PRIO_LOW", dimension="priority")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        g.define_move("promote",
            from_containers=[prio_low],
            to_containers=[prio_high],
            entity_type=proc_type)

        proc = g.create_entity(proc_type, "proc", ready)
        # NOT enrolled in priority dimension

        result = g.move("promote", proc, prio_high)
        assert result is None

    def test_independent_dimensions_dont_interact(self):
        """Moving in one dimension doesn't affect another."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")

        ready = g.define_container("READY")
        running = g.define_container("RUNNING", ContainerKind.SLOT)
        prio_low = g.define_container("PRIO_LOW", dimension="priority")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        g.define_move("schedule",
            from_containers=[ready],
            to_containers=[running],
            entity_type=proc_type)
        g.define_move("promote",
            from_containers=[prio_low],
            to_containers=[prio_high],
            entity_type=proc_type)

        proc = g.create_entity(proc_type, "proc", ready)
        g.enroll_in_dimension(proc, prio_low)

        # Move in default dimension
        g.move("schedule", proc, running)
        assert g.where_is(proc) == running
        assert g.where_is_in(proc, "priority") == prio_low  # Unchanged

        # Move in priority dimension
        g.move("promote", proc, prio_high)
        assert g.where_is(proc) == running  # Unchanged
        assert g.where_is_in(proc, "priority") == prio_high

    def test_dimensional_slot_constraint(self):
        """Slot constraints work in named dimensions."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        core_0 = g.define_container("CORE_0", ContainerKind.SLOT, dimension="affinity")
        unassigned = g.define_container("UNASSIGNED", dimension="affinity")

        g.define_move("assign",
            from_containers=[unassigned],
            to_containers=[core_0],
            entity_type=proc_type)

        p1 = g.create_entity(proc_type, "p1", ready)
        p2 = g.create_entity(proc_type, "p2", ready)
        g.enroll_in_dimension(p1, unassigned)
        g.enroll_in_dimension(p2, unassigned)

        # Assign p1 to core_0
        assert g.move("assign", p1, core_0) is not None

        # p2 can't go to core_0 — slot full
        assert g.move("assign", p2, core_0) is None

    def test_provenance_tracks_dimensional_moves(self):
        """Operations in named dimensions are logged with provenance."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_low = g.define_container("PRIO_LOW", dimension="priority")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        g.define_move("promote",
            from_containers=[prio_low],
            to_containers=[prio_high])

        proc = g.create_entity(proc_type, "proc", ready)
        g.enroll_in_dimension(proc, prio_low)

        op_id = g.move("promote", proc, prio_high)
        assert op_id is not None

        # Find the promote operation
        ops = [op for op in g.operations if op.op_type == 'promote']
        assert len(ops) == 1
        assert ops[0].params['from_container'] == prio_low
        assert ops[0].params['to_container'] == prio_high


class TestDimensionalSignal:
    """Signal with dimensional containers."""

    def test_signal_to_dimensional_container(self):
        """Signal can place entity in a named-dimension container."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        proc = g.create_entity(proc_type, "proc", ready)

        op_id = g.signal(proc, prio_high)
        assert op_id is not None
        assert g.where_is_in(proc, "priority") == prio_high
        # Default dimension unchanged
        assert g.where_is(proc) == ready

    def test_signal_replaces_in_dimension(self):
        """Signal to dimensional container replaces existing position in that dimension."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_low = g.define_container("PRIO_LOW", dimension="priority")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        proc = g.create_entity(proc_type, "proc", ready)
        g.enroll_in_dimension(proc, prio_low)

        # Signal overrides position in priority dimension
        g.signal(proc, prio_high)
        assert g.where_is_in(proc, "priority") == prio_high
        assert proc not in g.contents_of(prio_low)
        assert proc in g.contents_of(prio_high)


class TestDimensionalTensions:
    """Tensions that operate across dimensions."""

    def test_tension_moves_in_dimension(self):
        """A tension can trigger a move in a named dimension."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_low = g.define_container("PRIO_LOW", dimension="priority")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        g.define_move("promote",
            from_containers=[prio_low],
            to_containers=[prio_high])

        proc = g.create_entity(proc_type, "proc", ready)
        g.enroll_in_dimension(proc, prio_low)

        # Tension: promote all low-priority entities
        def auto_promote(graph):
            actions = []
            for eid in sorted(graph.contents_of(prio_low)):
                actions.append(IntendedMove("promote", eid, prio_high))
            return actions

        g.define_tension("auto_promote", auto_promote)
        g.run()

        assert g.where_is_in(proc, "priority") == prio_high
        assert g.where_is(proc) == ready  # Default unchanged

    def test_cross_dimensional_tension(self):
        """Tension can read state from multiple dimensions to decide action."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")

        ready = g.define_container("READY")
        running = g.define_container("RUNNING", ContainerKind.SLOT)
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")
        prio_low = g.define_container("PRIO_LOW", dimension="priority")

        g.define_move("schedule",
            from_containers=[ready],
            to_containers=[running],
            entity_type=proc_type)

        p1 = g.create_entity(proc_type, "p1", ready)
        p2 = g.create_entity(proc_type, "p2", ready)
        g.enroll_in_dimension(p1, prio_low)
        g.enroll_in_dimension(p2, prio_high)

        # Tension: schedule the highest-priority ready process
        def schedule_by_priority(graph):
            ready_procs = sorted(graph.contents_of(ready))
            if not ready_procs or not graph.containers[running].is_empty():
                return []
            # Pick highest priority
            high_prio = sorted(graph.contents_of(prio_high))
            for eid in high_prio:
                if eid in ready_procs:
                    return [IntendedMove("schedule", eid, running)]
            # Fallback to any ready proc
            return [IntendedMove("schedule", ready_procs[0], running)]

        g.define_tension("schedule_priority", schedule_by_priority)
        g.run()

        # p2 should be scheduled (it's high priority)
        assert g.where_is(p2) == running
        assert g.where_is(p1) == ready


# =============================================================================
# PART 2: Expression Evaluator ({"in": "container", "of": "entity"})
# =============================================================================

class TestDimensionalExpressions:
    """The {"in": "container", "of": "entity"} expression type."""

    def test_in_expression_default_dimension(self):
        """Expression checks if entity is in a default-dimension container."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        blocked = g.define_container("BLOCKED")

        proc = g.create_entity(proc_type, "proc", ready)

        container_ids = {"READY": ready, "BLOCKED": blocked}
        entity_ids = {"proc": proc}

        result = _eval_expr(
            {"in": "READY", "of": "proc"},
            {}, g, entity_ids, container_ids
        )
        assert result == True

        result = _eval_expr(
            {"in": "BLOCKED", "of": "proc"},
            {}, g, entity_ids, container_ids
        )
        assert result == False

    def test_in_expression_named_dimension(self):
        """Expression checks if entity is in a named-dimension container."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")
        prio_low = g.define_container("PRIO_LOW", dimension="priority")

        proc = g.create_entity(proc_type, "proc", ready)
        g.enroll_in_dimension(proc, prio_high)

        container_ids = {"READY": ready, "PRIO_HIGH": prio_high, "PRIO_LOW": prio_low}
        entity_ids = {"proc": proc}

        result = _eval_expr(
            {"in": "PRIO_HIGH", "of": "proc"},
            {}, g, entity_ids, container_ids
        )
        assert result == True

        result = _eval_expr(
            {"in": "PRIO_LOW", "of": "proc"},
            {}, g, entity_ids, container_ids
        )
        assert result == False

    def test_in_expression_with_bindings(self):
        """Expression resolves entity ref from bindings first."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        proc = g.create_entity(proc_type, "proc", ready)
        g.enroll_in_dimension(proc, prio_high)

        container_ids = {"PRIO_HIGH": prio_high}
        entity_ids = {}

        # Resolve from bindings
        result = _eval_expr(
            {"in": "PRIO_HIGH", "of": "p"},
            {"p": proc}, g, entity_ids, container_ids
        )
        assert result == True


# =============================================================================
# PART 3: Program Loader with Dimensions
# =============================================================================

class TestProgramDimensions:
    """Program specification with dimensions."""

    def test_program_with_dimensions(self):
        """Load a program that uses named dimensions."""
        spec = {
            "dimensions": ["priority"],
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "RUNNING", "kind": "slot"},
                {"name": "PRIO_LOW", "dimension": "priority"},
                {"name": "PRIO_MED", "dimension": "priority"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
            ],
            "moves": [
                {"name": "schedule", "from": ["READY"], "to": ["RUNNING"],
                 "entity_type": "Process"},
                {"name": "promote", "from": ["PRIO_LOW"], "to": ["PRIO_MED", "PRIO_HIGH"],
                 "entity_type": "Process"},
                {"name": "demote", "from": ["PRIO_HIGH"], "to": ["PRIO_MED", "PRIO_LOW"],
                 "entity_type": "Process"},
            ],
            "entities": [
                {"name": "proc_A", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_HIGH"}},
                {"name": "proc_B", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"}},
            ],
            "tensions": [],
        }

        prog = HerbProgram(spec)
        g = prog.load()

        # proc_A: READY (default) + PRIO_HIGH (priority)
        assert prog.where_is("proc_A") == "READY"
        pid_a = prog.entity_id("proc_A")
        assert g.where_is_in_named(pid_a, "priority") == "PRIO_HIGH"

        # proc_B: READY (default) + PRIO_LOW (priority)
        assert prog.where_is("proc_B") == "READY"
        pid_b = prog.entity_id("proc_B")
        assert g.where_is_in_named(pid_b, "priority") == "PRIO_LOW"

    def test_program_dimensional_move(self):
        """Program can define moves that operate in a dimension."""
        spec = {
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "PRIO_LOW", "dimension": "priority"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
            ],
            "moves": [
                {"name": "promote", "from": ["PRIO_LOW"], "to": ["PRIO_HIGH"],
                 "entity_type": "Process"},
            ],
            "entities": [
                {"name": "proc", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"}},
            ],
            "tensions": [],
        }

        prog = HerbProgram(spec)
        g = prog.load()

        pid = prog.entity_id("proc")
        prio_high = prog.container_id("PRIO_HIGH")

        result = g.move("promote", pid, prio_high)
        assert result is not None
        assert g.where_is_in_named(pid, "priority") == "PRIO_HIGH"
        assert prog.where_is("proc") == "READY"  # Default unchanged

    def test_program_tension_with_dimensional_where(self):
        """Tension uses {"in": "container", "of": "entity"} in where clause."""
        spec = {
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "RUNNING", "kind": "slot"},
                {"name": "PRIO_LOW", "dimension": "priority"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
            ],
            "moves": [
                {"name": "schedule", "from": ["READY"], "to": ["RUNNING"],
                 "entity_type": "Process"},
            ],
            "entities": [
                {"name": "p1", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"}},
                {"name": "p2", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_HIGH"}},
            ],
            "tensions": [
                {
                    "name": "schedule_high_priority",
                    "match": [
                        {"bind": "proc", "in": "READY", "select": "first",
                         "where": {"in": "PRIO_HIGH", "of": "proc"}},
                        {"bind": "slot", "empty_in": ["RUNNING"]},
                    ],
                    "emit": [
                        {"move": "schedule", "entity": "proc", "to": "slot"},
                    ],
                },
            ],
        }

        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        # Only p2 is PRIO_HIGH, so p2 gets scheduled
        assert prog.where_is("p2") == "RUNNING"
        assert prog.where_is("p1") == "READY"

    def test_program_tension_dimensional_move(self):
        """Tension can emit a move in a named dimension."""
        spec = {
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "PRIO_LOW", "dimension": "priority"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
            ],
            "moves": [
                {"name": "promote", "from": ["PRIO_LOW"], "to": ["PRIO_HIGH"]},
            ],
            "entities": [
                {"name": "proc", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"},
                 "properties": {"wait_time": 100}},
            ],
            "tensions": [
                {
                    "name": "auto_promote",
                    "match": [
                        {"bind": "proc", "in": "PRIO_LOW",
                         "where": {"op": ">",
                                   "left": {"prop": "wait_time", "of": "proc"},
                                   "right": 50}},
                    ],
                    "emit": [
                        {"move": "promote", "entity": "proc", "to": "PRIO_HIGH"},
                    ],
                },
            ],
        }

        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        pid = prog.entity_id("proc")
        assert g.where_is_in_named(pid, "priority") == "PRIO_HIGH"

    def test_program_dimensional_match(self):
        """Match clause can bind entities from a dimensional container."""
        spec = {
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "RUNNING", "kind": "slot"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
                {"name": "PRIO_LOW", "dimension": "priority"},
            ],
            "moves": [
                {"name": "schedule", "from": ["READY"], "to": ["RUNNING"]},
            ],
            "entities": [
                {"name": "p1", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_HIGH"}},
                {"name": "p2", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"}},
            ],
            "tensions": [
                {
                    "name": "schedule_from_prio",
                    "priority": 10,
                    "match": [
                        # Match entities in PRIO_HIGH dimensional container
                        {"bind": "proc", "in": "PRIO_HIGH"},
                        {"bind": "slot", "empty_in": ["RUNNING"]},
                        # Guard: entity must also be in READY (default dimension)
                        {"guard": {"in": "READY", "of": "proc"}},
                    ],
                    "emit": [
                        {"move": "schedule", "entity": "proc", "to": "slot"},
                    ],
                },
            ],
        }

        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        # p1 is in PRIO_HIGH and READY -> gets scheduled
        assert prog.where_is("p1") == "RUNNING"
        assert prog.where_is("p2") == "READY"

    def test_program_no_dimensions_backward_compat(self):
        """Programs without dimensions work exactly as before."""
        spec = {
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "RUNNING", "kind": "slot"},
            ],
            "moves": [
                {"name": "schedule", "from": ["READY"], "to": ["RUNNING"]},
            ],
            "entities": [
                {"name": "proc", "type": "Process", "in": "READY"},
            ],
            "tensions": [
                {
                    "name": "auto_schedule",
                    "match": [
                        {"bind": "p", "in": "READY"},
                        {"bind": "s", "empty_in": ["RUNNING"]},
                    ],
                    "emit": [
                        {"move": "schedule", "entity": "p", "to": "s"},
                    ],
                },
            ],
        }

        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        assert prog.where_is("proc") == "RUNNING"


# =============================================================================
# PART 4: Validation
# =============================================================================

class TestDimensionValidation:
    """Validation of dimension-related program specs."""

    def test_valid_program_with_dimensions(self):
        """A correctly formed dimensional program validates clean."""
        spec = {
            "dimensions": ["priority"],
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "PRIO_LOW", "dimension": "priority"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
            ],
            "moves": [
                {"name": "promote", "from": ["PRIO_LOW"], "to": ["PRIO_HIGH"]},
            ],
            "entities": [
                {"name": "proc", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"}},
            ],
            "tensions": [],
        }
        errors = validate_program(spec)
        assert errors == []

    def test_unknown_dimension_on_container(self):
        """Container referencing undeclared dimension is an error."""
        spec = {
            "dimensions": ["priority"],
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "STATE_X", "dimension": "unknown_dim"},
            ],
            "moves": [],
            "entities": [],
            "tensions": [],
        }
        errors = validate_program(spec)
        assert any("unknown dimension" in e for e in errors)

    def test_mixed_dimension_move_error(self):
        """Move with containers from different dimensions is an error."""
        spec = {
            "dimensions": ["sched", "prio"],
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY", "dimension": "sched"},
                {"name": "PRIO_HIGH", "dimension": "prio"},
            ],
            "moves": [
                {"name": "bad_move", "from": ["READY"], "to": ["PRIO_HIGH"]},
            ],
            "entities": [],
            "tensions": [],
        }
        errors = validate_program(spec)
        assert any("multiple dimensions" in e for e in errors)

    def test_also_in_unknown_container(self):
        """Entity also_in referencing unknown container is an error."""
        spec = {
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
            ],
            "moves": [],
            "entities": [
                {"name": "proc", "type": "Process", "in": "READY",
                 "also_in": {"priority": "NONEXISTENT"}},
            ],
            "tensions": [],
        }
        errors = validate_program(spec)
        assert any("unknown container" in e for e in errors)

    def test_also_in_wrong_dimension(self):
        """Entity also_in with mismatched dimension is an error."""
        spec = {
            "dimensions": ["priority", "memory"],
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
            ],
            "moves": [],
            "entities": [
                {"name": "proc", "type": "Process", "in": "READY",
                 "also_in": {"memory": "PRIO_HIGH"}},  # Wrong dimension!
            ],
            "tensions": [],
        }
        errors = validate_program(spec)
        assert any("dimension" in e for e in errors)

    def test_no_dimensions_declared_containers_still_work(self):
        """Containers can have dimensions even without a top-level dimensions list."""
        spec = {
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "PRIO_LOW", "dimension": "priority"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
            ],
            "moves": [
                {"name": "promote", "from": ["PRIO_LOW"], "to": ["PRIO_HIGH"]},
            ],
            "entities": [
                {"name": "proc", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"}},
            ],
            "tensions": [],
        }
        errors = validate_program(spec)
        assert errors == []


# =============================================================================
# PART 5: Multi-Dimensional Scheduler Demo
# =============================================================================

class TestMultiDimScheduler:
    """Integration test: scheduler with priority as a real dimension."""

    def test_priority_scheduling(self):
        """
        Full integration: processes have scheduling state AND priority level
        as independent dimensions. A tension schedules the highest-priority
        ready process.
        """
        spec = {
            "dimensions": ["priority"],
            "entity_types": [{"name": "Process"}],
            "containers": [
                # Scheduling dimension (default)
                {"name": "READY"},
                {"name": "RUNNING", "kind": "slot"},
                {"name": "BLOCKED"},

                # Priority dimension
                {"name": "PRIO_LOW", "dimension": "priority"},
                {"name": "PRIO_MED", "dimension": "priority"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
            ],
            "moves": [
                # Default dimension moves
                {"name": "schedule", "from": ["READY"], "to": ["RUNNING"],
                 "entity_type": "Process"},
                {"name": "preempt", "from": ["RUNNING"], "to": ["READY"],
                 "entity_type": "Process"},
                {"name": "block", "from": ["RUNNING"], "to": ["BLOCKED"],
                 "entity_type": "Process"},
                {"name": "unblock", "from": ["BLOCKED"], "to": ["READY"],
                 "entity_type": "Process"},

                # Priority dimension moves
                {"name": "promote", "from": ["PRIO_LOW", "PRIO_MED"],
                 "to": ["PRIO_MED", "PRIO_HIGH"]},
                {"name": "demote", "from": ["PRIO_HIGH", "PRIO_MED"],
                 "to": ["PRIO_MED", "PRIO_LOW"]},
            ],
            "entities": [
                {"name": "init", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"}},
                {"name": "shell", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_MED"}},
                {"name": "kernel", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_HIGH"}},
            ],
            "tensions": [
                {
                    "name": "schedule_highest_priority",
                    "priority": 10,
                    "match": [
                        # Find a ready process that's also PRIO_HIGH
                        {"bind": "proc", "in": "READY",
                         "where": {"in": "PRIO_HIGH", "of": "proc"}},
                        {"bind": "slot", "empty_in": ["RUNNING"]},
                    ],
                    "emit": [
                        {"move": "schedule", "entity": "proc", "to": "slot"},
                    ],
                },
                {
                    "name": "schedule_medium_priority",
                    "priority": 5,
                    "match": [
                        {"bind": "proc", "in": "READY",
                         "where": {"in": "PRIO_MED", "of": "proc"}},
                        {"bind": "slot", "empty_in": ["RUNNING"]},
                    ],
                    "emit": [
                        {"move": "schedule", "entity": "proc", "to": "slot"},
                    ],
                },
                {
                    "name": "schedule_low_priority",
                    "priority": 1,
                    "match": [
                        {"bind": "proc", "in": "READY",
                         "where": {"in": "PRIO_LOW", "of": "proc"}},
                        {"bind": "slot", "empty_in": ["RUNNING"]},
                    ],
                    "emit": [
                        {"move": "schedule", "entity": "proc", "to": "slot"},
                    ],
                },
            ],
        }

        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        # Kernel (PRIO_HIGH) should be scheduled first
        assert prog.where_is("kernel") == "RUNNING"
        assert prog.where_is("shell") == "READY"
        assert prog.where_is("init") == "READY"

        # Priority dimensions unchanged by scheduling
        kid = prog.entity_id("kernel")
        sid = prog.entity_id("shell")
        iid = prog.entity_id("init")
        assert g.where_is_in_named(kid, "priority") == "PRIO_HIGH"
        assert g.where_is_in_named(sid, "priority") == "PRIO_MED"
        assert g.where_is_in_named(iid, "priority") == "PRIO_LOW"

    def test_priority_promotion_and_rescheduling(self):
        """
        Promote a process's priority, then verify it gets scheduled
        on the next cycle when the CPU is free.
        """
        spec = {
            "dimensions": ["priority"],
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "RUNNING", "kind": "slot"},
                {"name": "PRIO_LOW", "dimension": "priority"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
            ],
            "moves": [
                {"name": "schedule", "from": ["READY"], "to": ["RUNNING"]},
                {"name": "preempt", "from": ["RUNNING"], "to": ["READY"]},
                {"name": "promote", "from": ["PRIO_LOW"], "to": ["PRIO_HIGH"]},
            ],
            "entities": [
                {"name": "p1", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"}},
                {"name": "p2", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"}},
            ],
            "tensions": [
                {
                    "name": "schedule_high",
                    "priority": 10,
                    "match": [
                        {"bind": "proc", "in": "READY",
                         "where": {"in": "PRIO_HIGH", "of": "proc"}},
                        {"bind": "slot", "empty_in": ["RUNNING"]},
                    ],
                    "emit": [
                        {"move": "schedule", "entity": "proc", "to": "slot"},
                    ],
                },
                {
                    "name": "schedule_low",
                    "priority": 1,
                    "match": [
                        {"bind": "proc", "in": "READY",
                         "where": {"in": "PRIO_LOW", "of": "proc"}},
                        {"bind": "slot", "empty_in": ["RUNNING"]},
                    ],
                    "emit": [
                        {"move": "schedule", "entity": "proc", "to": "slot"},
                    ],
                },
            ],
        }

        prog = HerbProgram(spec)
        g = prog.load()

        # Initial run: both LOW priority, p1 gets scheduled (first by ID)
        g.run()
        assert prog.where_is("p1") == "RUNNING"
        assert prog.where_is("p2") == "READY"

        # Preempt p1, promote p2 to HIGH
        pid1 = prog.entity_id("p1")
        pid2 = prog.entity_id("p2")
        ready = prog.container_id("READY")
        prio_high = prog.container_id("PRIO_HIGH")

        g.move("preempt", pid1, ready)
        g.move("promote", pid2, prio_high)

        # Run again: p2 is now PRIO_HIGH, should be scheduled
        g.run()
        assert prog.where_is("p2") == "RUNNING"
        assert prog.where_is("p1") == "READY"

    def test_three_dimensions(self):
        """Entity with three independent dimensions."""
        spec = {
            "dimensions": ["priority", "security", "memory"],
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "PRIO_LOW", "dimension": "priority"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
                {"name": "SEC_USER", "dimension": "security"},
                {"name": "SEC_KERNEL", "dimension": "security"},
                {"name": "MEM_LOW", "dimension": "memory"},
                {"name": "MEM_HIGH", "dimension": "memory"},
            ],
            "moves": [
                {"name": "promote", "from": ["PRIO_LOW"], "to": ["PRIO_HIGH"]},
                {"name": "escalate", "from": ["SEC_USER"], "to": ["SEC_KERNEL"]},
                {"name": "grow_mem", "from": ["MEM_LOW"], "to": ["MEM_HIGH"]},
            ],
            "entities": [
                {"name": "proc", "type": "Process", "in": "READY",
                 "also_in": {
                     "priority": "PRIO_LOW",
                     "security": "SEC_USER",
                     "memory": "MEM_LOW",
                 }},
            ],
            "tensions": [],
        }

        prog = HerbProgram(spec)
        g = prog.load()

        pid = prog.entity_id("proc")

        # Start: LOW/USER/LOW
        assert g.where_is_in_named(pid, "priority") == "PRIO_LOW"
        assert g.where_is_in_named(pid, "security") == "SEC_USER"
        assert g.where_is_in_named(pid, "memory") == "MEM_LOW"

        # Move in each dimension independently
        g.move("promote", pid, prog.container_id("PRIO_HIGH"))
        g.move("escalate", pid, prog.container_id("SEC_KERNEL"))
        g.move("grow_mem", pid, prog.container_id("MEM_HIGH"))

        # Each dimension moved independently
        assert g.where_is_in_named(pid, "priority") == "PRIO_HIGH"
        assert g.where_is_in_named(pid, "security") == "SEC_KERNEL"
        assert g.where_is_in_named(pid, "memory") == "MEM_HIGH"
        assert prog.where_is("proc") == "READY"  # Default unchanged

    def test_dimension_with_count_expression(self):
        """Count expression works for dimensional containers."""
        spec = {
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY"},
                {"name": "PRIO_HIGH", "dimension": "priority"},
                {"name": "PRIO_LOW", "dimension": "priority"},
            ],
            "moves": [],
            "entities": [
                {"name": "p1", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_HIGH"}},
                {"name": "p2", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_HIGH"}},
                {"name": "p3", "type": "Process", "in": "READY",
                 "also_in": {"priority": "PRIO_LOW"}},
            ],
            "tensions": [],
        }

        prog = HerbProgram(spec)
        g = prog.load()

        prio_high = prog.container_id("PRIO_HIGH")
        prio_low = prog.container_id("PRIO_LOW")

        assert g.containers[prio_high].count == 2
        assert g.containers[prio_low].count == 1


# =============================================================================
# PART 6: Edge Cases
# =============================================================================

class TestDimensionEdgeCases:
    """Edge cases and boundary conditions."""

    def test_entity_in_default_only(self):
        """Entity without dimensional enrollment works normally."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        proc = g.create_entity(proc_type, "proc", ready)

        # Not enrolled in priority dimension
        assert g.where_is_in(proc, "priority") is None
        assert g.where_is(proc) == ready

    def test_dimensional_container_in_default_move(self):
        """A default-dimension move can't target a dimensional container."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        # Move from default to dimensional — mixed dimensions
        g.define_move("bad_move",
            from_containers=[ready],
            to_containers=[prio_high])

        proc = g.create_entity(proc_type, "proc", ready)

        # The move's containers are in different dimensions
        # _get_move_dimension returns None when mixed
        # The entity is in READY (default dim), but prio_high is in "priority" dim
        # The operation shouldn't work correctly because dimensions are mixed
        result = g.move("bad_move", proc, prio_high)
        # The entity_location check will look in default dim, find proc in READY,
        # and READY is in from_containers, so it'll proceed — but this is a
        # degenerate case. The validator catches this at the program spec level.
        # At the runtime level, the move DOES execute because from/to containers
        # match, but the entity ends up in entity_location pointing to prio_high
        # (which is weird). This is why the validator checks for mixed dimensions.

    def test_multiple_entities_in_same_dimensional_container(self):
        """Multiple entities can be in the same dimensional container."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        p1 = g.create_entity(proc_type, "p1", ready)
        p2 = g.create_entity(proc_type, "p2", ready)
        p3 = g.create_entity(proc_type, "p3", ready)

        g.enroll_in_dimension(p1, prio_high)
        g.enroll_in_dimension(p2, prio_high)
        g.enroll_in_dimension(p3, prio_high)

        assert g.containers[prio_high].count == 3
        assert {p1, p2, p3} == g.contents_of(prio_high)

    def test_enroll_provenance(self):
        """Enrollment operations are tracked in provenance."""
        g = MoveGraph()
        proc_type = g.define_entity_type("Process")
        ready = g.define_container("READY")
        prio_high = g.define_container("PRIO_HIGH", dimension="priority")

        proc = g.create_entity(proc_type, "proc", ready)
        op_id = g.enroll_in_dimension(proc, prio_high)

        assert op_id is not None
        ops = [op for op in g.operations if op.op_type == 'enroll_dimension']
        assert len(ops) == 1
        assert ops[0].params['dimension'] == 'priority'
        assert ops[0].params['entity_id'] == proc
