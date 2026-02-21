"""
Tests for HERB Goal Pursuit system.

The goal pursuit system finds sequences of valid MOVE operations to reach
desired states. This is where HERB transitions from a state machine to a planner.

Key insight: We're not searching an abstract state space. We're finding
sequences of operations that EXIST. If no path exists, the goal is unreachable
BY CONSTRUCTION.
"""

import pytest
from herb_move import (
    MoveGraph, ContainerKind, GoalPursuit, PlannedMove
)


# =============================================================================
# FIXTURES
# =============================================================================

@pytest.fixture
def process_graph():
    """Create a process scheduling graph with CREATED state."""
    g = MoveGraph()

    process_type = g.define_entity_type("Process")

    created = g.define_container("CREATED", entity_type=process_type)
    ready = g.define_container("READY_QUEUE", entity_type=process_type)
    cpu0 = g.define_container("CPU0", ContainerKind.SLOT, entity_type=process_type)
    cpu1 = g.define_container("CPU1", ContainerKind.SLOT, entity_type=process_type)
    blocked = g.define_container("BLOCKED", entity_type=process_type)

    g.define_move("spawn", [created], [ready], process_type)
    g.define_move("schedule", [ready], [cpu0, cpu1], process_type)
    g.define_move("preempt", [cpu0, cpu1], [ready], process_type)
    g.define_move("block", [cpu0, cpu1], [blocked], process_type)
    g.define_move("unblock", [blocked], [ready], process_type)

    return g, {
        'type': process_type,
        'created': created,
        'ready': ready,
        'cpu0': cpu0,
        'cpu1': cpu1,
        'blocked': blocked
    }


@pytest.fixture
def dom_graph():
    """Create a DOM element positioning graph."""
    g = MoveGraph()

    element_type = g.define_entity_type("Element")

    detached = g.define_container("DETACHED", entity_type=element_type)
    body = g.define_container("BODY", entity_type=element_type)
    slot1 = g.define_container("SLOT1", ContainerKind.SLOT, entity_type=element_type)
    slot2 = g.define_container("SLOT2", ContainerKind.SLOT, entity_type=element_type)

    g.define_move("appendChild", [detached, body], [slot1, slot2, body], element_type)
    g.define_move("removeChild", [slot1, slot2, body], [detached], element_type)
    g.define_move("moveChild", [slot1, slot2], [slot1, slot2], element_type)

    return g, {
        'type': element_type,
        'detached': detached,
        'body': body,
        'slot1': slot1,
        'slot2': slot2
    }


# =============================================================================
# SIMPLE PATH TESTS
# =============================================================================

class TestSimplePaths:
    """Tests for simple goal pursuit (no blocking)."""

    def test_already_at_goal(self, process_graph):
        """Entity already at goal should return empty plan."""
        g, c = process_graph
        p = g.create_entity(c['type'], "P", c['ready'])

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, c['ready'])

        assert plan == []

    def test_single_move(self, process_graph):
        """Goal reachable in one move."""
        g, c = process_graph
        p = g.create_entity(c['type'], "P", c['created'])

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, c['ready'])

        assert len(plan) == 1
        assert plan[0].move_name == "spawn"
        assert plan[0].to_container == c['ready']

    def test_two_moves(self, process_graph):
        """Goal reachable in two moves (CREATED -> READY -> CPU)."""
        g, c = process_graph
        p = g.create_entity(c['type'], "P", c['created'])

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, c['cpu0'])

        assert len(plan) == 2
        assert plan[0].move_name == "spawn"
        assert plan[1].move_name == "schedule"
        assert plan[1].to_container == c['cpu0']

    def test_blocked_to_running(self, process_graph):
        """Blocked process needs unblock -> schedule."""
        g, c = process_graph
        p = g.create_entity(c['type'], "P", c['blocked'])

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, c['cpu1'])

        assert len(plan) == 2
        assert plan[0].move_name == "unblock"
        assert plan[1].move_name == "schedule"


# =============================================================================
# SLOT OCCUPANCY TESTS
# =============================================================================

class TestSlotOccupancy:
    """Tests for goal pursuit when slots are occupied."""

    def test_preempt_occupant(self, process_graph):
        """Goal slot occupied - need to preempt first."""
        g, c = process_graph
        p = g.create_entity(c['type'], "P", c['ready'])
        q = g.create_entity(c['type'], "Q", c['cpu0'])

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, c['cpu0'])

        # Should be: preempt(Q), schedule(P)
        assert len(plan) == 2
        assert plan[0].move_name == "preempt"
        assert plan[0].entity_id == q
        assert plan[1].move_name == "schedule"
        assert plan[1].entity_id == p

    def test_spawn_then_preempt(self, process_graph):
        """CREATED -> CPU0 when CPU0 is occupied."""
        g, c = process_graph
        p = g.create_entity(c['type'], "P", c['created'])
        q = g.create_entity(c['type'], "Q", c['cpu0'])

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, c['cpu0'])

        # Should be: preempt(Q), spawn(P), schedule(P)
        assert len(plan) == 3
        assert plan[0].entity_id == q  # Q preempted first
        assert plan[1].entity_id == p  # P spawned
        assert plan[2].entity_id == p  # P scheduled

    def test_dom_replace_element(self, dom_graph):
        """DOM: replace element in slot."""
        g, c = dom_graph

        nav = g.create_entity(c['type'], "nav", c['detached'])
        sidebar = g.create_entity(c['type'], "sidebar", c['slot1'])

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(nav, c['slot1'])

        # Should be: removeChild(sidebar), appendChild(nav)
        assert len(plan) == 2
        assert plan[0].entity_id == sidebar
        assert plan[0].move_name == "removeChild"
        assert plan[1].entity_id == nav
        assert plan[1].move_name == "appendChild"


# =============================================================================
# NESTED BLOCKING TESTS
# =============================================================================

class TestNestedBlocking:
    """Tests for cascading slot occupancy."""

    def test_cascading_preemption(self):
        """Three CPUs in a chain - each can only move to the next."""
        g = MoveGraph()

        process_type = g.define_entity_type("Process")
        ready = g.define_container("READY", entity_type=process_type)
        cpu0 = g.define_container("CPU0", ContainerKind.SLOT, entity_type=process_type)
        cpu1 = g.define_container("CPU1", ContainerKind.SLOT, entity_type=process_type)
        cpu2 = g.define_container("CPU2", ContainerKind.SLOT, entity_type=process_type)

        # Chain: CPU0 -> CPU1 -> CPU2 -> READY
        g.define_move("move_0_1", [cpu0], [cpu1], process_type)
        g.define_move("move_1_2", [cpu1], [cpu2], process_type)
        g.define_move("move_2_ready", [cpu2], [ready], process_type)
        g.define_move("schedule", [ready], [cpu0, cpu1, cpu2], process_type)

        # All slots occupied
        p = g.create_entity(process_type, "P", ready)
        q = g.create_entity(process_type, "Q", cpu0)
        r = g.create_entity(process_type, "R", cpu1)
        s = g.create_entity(process_type, "S", cpu2)

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, cpu0)

        # Should cascade: S->READY, R->CPU2, Q->CPU1, P->CPU0
        assert len(plan) == 4

        # Execute and verify
        results = planner.execute_plan(plan)
        assert all(r is not None for r in results)
        assert g.where_is(p) == cpu0
        assert g.where_is(q) == cpu1
        assert g.where_is(r) == cpu2
        assert g.where_is(s) == ready


# =============================================================================
# IMPOSSIBLE GOALS TESTS
# =============================================================================

class TestImpossibleGoals:
    """Tests for goals that cannot be reached."""

    def test_no_path_exists(self):
        """No moves defined from current position."""
        g = MoveGraph()

        process_type = g.define_entity_type("Process")
        blocked = g.define_container("BLOCKED", entity_type=process_type)
        running = g.define_container("RUNNING", ContainerKind.SLOT, entity_type=process_type)

        # No moves defined at all
        p = g.create_entity(process_type, "P", blocked)

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, running)

        assert plan is None

    def test_unreachable_goal(self):
        """Goal exists but no valid path leads to it."""
        g = MoveGraph()

        process_type = g.define_entity_type("Process")
        state_a = g.define_container("STATE_A", entity_type=process_type)
        state_b = g.define_container("STATE_B", entity_type=process_type)
        state_c = g.define_container("STATE_C", entity_type=process_type)

        # A -> B but no path to C
        g.define_move("a_to_b", [state_a], [state_b], process_type)

        p = g.create_entity(process_type, "P", state_a)

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, state_c)

        assert plan is None

    def test_slot_occupant_stuck(self):
        """Slot occupied but occupant has no valid move."""
        g = MoveGraph()

        process_type = g.define_entity_type("Process")
        ready = g.define_container("READY", entity_type=process_type)
        cpu = g.define_container("CPU", ContainerKind.SLOT, entity_type=process_type)

        # Can schedule to CPU but can't preempt
        g.define_move("schedule", [ready], [cpu], process_type)
        # Note: NO preempt move defined

        p = g.create_entity(process_type, "P", ready)
        q = g.create_entity(process_type, "Q", cpu)  # Stuck on CPU

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, cpu)

        # Can't get P to CPU because Q can't move
        assert plan is None


# =============================================================================
# PLAN EXECUTION TESTS
# =============================================================================

class TestPlanExecution:
    """Tests for executing plans."""

    def test_execute_simple_plan(self, process_graph):
        """Execute a simple two-move plan."""
        g, c = process_graph
        p = g.create_entity(c['type'], "P", c['created'])

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, c['cpu1'])
        results = planner.execute_plan(plan)

        assert len(results) == 2
        assert all(r is not None for r in results)
        assert g.where_is(p) == c['cpu1']

    def test_execute_with_preemption(self, process_graph):
        """Execute plan that requires preemption."""
        g, c = process_graph
        p = g.create_entity(c['type'], "P", c['ready'])
        q = g.create_entity(c['type'], "Q", c['cpu0'])

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, c['cpu0'])
        results = planner.execute_plan(plan)

        assert len(results) == 2
        assert all(r is not None for r in results)
        assert g.where_is(p) == c['cpu0']
        assert g.where_is(q) == c['ready']

    def test_provenance_tracked(self, process_graph):
        """Executed moves should be logged for provenance."""
        g, c = process_graph
        p = g.create_entity(c['type'], "P", c['created'])

        initial_ops = len(g.operations)

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, c['cpu0'])
        planner.execute_plan(plan)

        # Should have added 2 operations
        assert len(g.operations) == initial_ops + 2

        # Provenance should show both moves
        history = g.why(p)
        assert len(history) == 2
        assert history[0].op_type == "spawn"
        assert history[1].op_type == "schedule"


# =============================================================================
# EDGE CASES
# =============================================================================

class TestEdgeCases:
    """Edge cases and boundary conditions."""

    def test_entity_not_in_any_container(self):
        """Entity not placed in any container."""
        g = MoveGraph()
        process_type = g.define_entity_type("Process")
        ready = g.define_container("READY", entity_type=process_type)

        # Create entity WITHOUT initial container
        p = g.create_entity(process_type, "P")

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, ready)

        assert plan is None  # Can't plan for unplaced entity

    def test_nonexistent_entity(self):
        """Entity ID doesn't exist."""
        g = MoveGraph()
        ready = g.define_container("READY")

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(9999, ready)

        assert plan is None

    def test_nonexistent_container(self):
        """Goal container doesn't exist."""
        g = MoveGraph()
        process_type = g.define_entity_type("Process")
        ready = g.define_container("READY", entity_type=process_type)
        p = g.create_entity(process_type, "P", ready)

        planner = GoalPursuit(g)
        plan = planner.plan_to_goal(p, 9999)

        assert plan is None

    def test_depth_limit_for_nested_blocking(self):
        """Depth limit affects recursive slot clearing, not path length.

        max_depth limits how deeply we recurse when clearing occupied slots.
        It does NOT limit the path length (BFS always finds shortest path).
        """
        g = MoveGraph()
        process_type = g.define_entity_type("Process")

        # Create deeply nested blocking: each slot can only move to the next
        ready = g.define_container("READY", entity_type=process_type)
        slots = []
        for i in range(6):
            slots.append(g.define_container(f"SLOT_{i}", ContainerKind.SLOT, entity_type=process_type))

        # Chain: SLOT_0 -> SLOT_1 -> SLOT_2 -> ... -> READY
        for i in range(len(slots) - 1):
            g.define_move(f"cascade_{i}", [slots[i]], [slots[i+1]], process_type)
        g.define_move("to_ready", [slots[-1]], [ready], process_type)
        g.define_move("schedule", [ready], [slots[0]], process_type)

        # Fill all slots
        p = g.create_entity(process_type, "P", ready)
        occupants = []
        for i, slot in enumerate(slots):
            occ = g.create_entity(process_type, f"Q{i}", slot)
            occupants.append(occ)

        planner = GoalPursuit(g)

        # With max_depth=2, can't cascade through 6 slots
        plan = planner.plan_to_goal(p, slots[0], max_depth=2)
        assert plan is None  # Recursion too deep

        # With max_depth=10, can cascade through all slots
        plan = planner.plan_to_goal(p, slots[0], max_depth=10)
        assert plan is not None

    def test_long_path_finds_shortest(self):
        """BFS finds shortest path regardless of chain length."""
        g = MoveGraph()
        process_type = g.define_entity_type("Process")

        # Create a long chain of states
        states = []
        for i in range(20):
            states.append(g.define_container(f"STATE_{i}", entity_type=process_type))

        for i in range(len(states) - 1):
            g.define_move(f"move_{i}", [states[i]], [states[i+1]], process_type)

        p = g.create_entity(process_type, "P", states[0])

        planner = GoalPursuit(g)

        # Can reach state 10 (requires 10 moves)
        plan = planner.plan_to_goal(p, states[10])
        assert plan is not None
        assert len(plan) == 10

        # Can reach state 19 (requires 19 moves)
        plan = planner.plan_to_goal(p, states[19])
        assert plan is not None
        assert len(plan) == 19


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
