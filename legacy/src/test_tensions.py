"""
Tests for HERB Tension System.

Tensions are the energy gradients that make the system run itself.
A tension declares: "when this condition holds, this MOVE should execute."
The runtime resolves tensions to fixpoint (equilibrium).

Key properties tested:
1. Tensions only trigger MOVEs in the operation set (safety preserved)
2. run() reaches equilibrium (fixpoint)
3. Signals disturb equilibrium, run() restores it
4. Priority ordering works
5. Provenance tracks tension-caused operations
6. Max step safety valve prevents infinite loops
"""

import pytest
from herb_move import (
    MoveGraph, ContainerKind, GoalPursuit,
    Tension, IntendedMove
)


# =============================================================================
# FIXTURES
# =============================================================================

@pytest.fixture
def scheduler_graph():
    """Basic scheduler: processes, CPUs, standard moves + tensions."""
    g = MoveGraph()

    process_type = g.define_entity_type("Process")

    ready = g.define_container("READY", entity_type=process_type)
    cpu0 = g.define_container("CPU0", ContainerKind.SLOT, entity_type=process_type)
    cpu1 = g.define_container("CPU1", ContainerKind.SLOT, entity_type=process_type)
    blocked = g.define_container("BLOCKED", entity_type=process_type)

    g.define_move("schedule", [ready], [cpu0, cpu1], process_type)
    g.define_move("preempt", [cpu0, cpu1], [ready], process_type)
    g.define_move("block", [cpu0, cpu1], [blocked], process_type)
    g.define_move("unblock", [blocked], [ready], process_type)

    cpus = [cpu0, cpu1]

    # Tension: schedule ready processes to empty CPUs
    def schedule_ready(graph):
        moves = []
        ready_procs = list(graph.contents_of(ready))
        for cpu in cpus:
            if graph.containers[cpu].is_empty() and ready_procs:
                moves.append(IntendedMove("schedule", ready_procs.pop(0), cpu))
        return moves

    g.define_tension("schedule_ready", schedule_ready, priority=10)

    return g, {
        'type': process_type,
        'ready': ready,
        'cpu0': cpu0,
        'cpu1': cpu1,
        'blocked': blocked,
        'cpus': cpus,
    }


# =============================================================================
# BASIC TENSION RESOLUTION
# =============================================================================

class TestBasicTensions:
    """Test fundamental tension behavior."""

    def test_single_tension_fires(self, scheduler_graph):
        """A single ready process gets scheduled to an empty CPU."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['ready'])

        ops = g.run()

        assert ops == 1
        assert g.where_is(p) == c['cpu0']

    def test_two_processes_two_cpus(self, scheduler_graph):
        """Two ready processes fill two CPUs."""
        g, c = scheduler_graph
        p1 = g.create_entity(c['type'], "P1", c['ready'])
        p2 = g.create_entity(c['type'], "P2", c['ready'])

        ops = g.run()

        assert ops == 2
        # Both should be on CPUs (order may vary)
        locs = {g.where_is(p1), g.where_is(p2)}
        assert locs == {c['cpu0'], c['cpu1']}

    def test_third_process_stays_ready(self, scheduler_graph):
        """Third process stays in READY — no free CPU."""
        g, c = scheduler_graph
        p1 = g.create_entity(c['type'], "P1", c['ready'])
        p2 = g.create_entity(c['type'], "P2", c['ready'])
        p3 = g.create_entity(c['type'], "P3", c['ready'])

        ops = g.run()

        assert ops == 2
        # Two on CPUs, one still ready
        on_cpu = sum(1 for p in [p1, p2, p3]
                     if g.where_is(p) in [c['cpu0'], c['cpu1']])
        in_ready = sum(1 for p in [p1, p2, p3]
                       if g.where_is(p) == c['ready'])
        assert on_cpu == 2
        assert in_ready == 1

    def test_empty_system_at_equilibrium(self, scheduler_graph):
        """No processes = already at equilibrium."""
        g, c = scheduler_graph

        ops = g.run()

        assert ops == 0

    def test_all_blocked_at_equilibrium(self, scheduler_graph):
        """All processes blocked = at equilibrium (no tension active)."""
        g, c = scheduler_graph
        p1 = g.create_entity(c['type'], "P1", c['blocked'])
        p2 = g.create_entity(c['type'], "P2", c['blocked'])

        ops = g.run()

        assert ops == 0
        assert g.where_is(p1) == c['blocked']
        assert g.where_is(p2) == c['blocked']


# =============================================================================
# EQUILIBRIUM AND FIXPOINT
# =============================================================================

class TestEquilibrium:
    """Test that run() reaches equilibrium."""

    def test_run_reaches_fixpoint(self, scheduler_graph):
        """After run(), calling run() again does nothing."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['ready'])

        ops1 = g.run()
        ops2 = g.run()

        assert ops1 > 0
        assert ops2 == 0  # Already at equilibrium

    def test_step_returns_empty_at_equilibrium(self, scheduler_graph):
        """step() returns empty list when at equilibrium."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['ready'])

        g.run()
        executed = g.step()

        assert executed == []

    def test_max_steps_safety_valve(self):
        """max_steps prevents infinite loops from bad tensions."""
        g = MoveGraph()
        t = g.define_entity_type("Thing")
        a = g.define_container("A", entity_type=t)
        b = g.define_container("B", entity_type=t)

        g.define_move("a_to_b", [a], [b], t)
        g.define_move("b_to_a", [b], [a], t)

        thing = g.create_entity(t, "thing", a)

        # Pathological tension: always wants to move to the other container
        def oscillate(graph):
            loc = graph.where_is(thing)
            if loc == a:
                return [IntendedMove("a_to_b", thing, b)]
            elif loc == b:
                return [IntendedMove("b_to_a", thing, a)]
            return []

        g.define_tension("oscillate", oscillate)

        ops = g.run(max_steps=5)

        # Should have stopped after 5 steps, not run forever
        assert ops == 5


# =============================================================================
# SIGNALS AND DISTURBANCE
# =============================================================================

class TestSignals:
    """Test external signals disturbing equilibrium."""

    def test_signal_places_entity(self, scheduler_graph):
        """signal() places entity in target container."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['cpu0'])

        g.signal(p, c['ready'])

        assert g.where_is(p) == c['ready']

    def test_signal_then_run_restores_equilibrium(self, scheduler_graph):
        """Signal disturbs equilibrium, run() restores it."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['cpu0'])

        # Equilibrium: P on CPU0, nothing to do
        assert g.run() == 0

        # Signal: P moves to READY (simulating preemption by external event)
        g.signal(p, c['ready'])
        assert g.where_is(p) == c['ready']

        # run() should reschedule P
        ops = g.run()
        assert ops == 1
        assert g.where_is(p) == c['cpu0']  # Back on CPU

    def test_signal_logs_operation(self, scheduler_graph):
        """Signals are logged in the operation history."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['cpu0'])

        op_id = g.signal(p, c['ready'])

        assert op_id is not None
        # Find the signal operation
        signal_ops = [op for op in g.operations if op.op_type == 'signal']
        assert len(signal_ops) == 1
        assert signal_ops[0].cause == 'external_signal'

    def test_signal_nonexistent_entity(self, scheduler_graph):
        """Signal for nonexistent entity returns None."""
        g, c = scheduler_graph

        result = g.signal(9999, c['ready'])

        assert result is None

    def test_io_complete_signal_flow(self, scheduler_graph):
        """Full flow: process blocks, I/O completes, process reschedules."""
        g, c = scheduler_graph

        io_complete = g.define_container("IO_COMPLETE", entity_type=c['type'])
        g.define_move("io_unblock", [io_complete], [c['ready']], c['type'])

        def process_io(graph):
            moves = []
            for proc in list(graph.contents_of(io_complete)):
                moves.append(IntendedMove("io_unblock", proc, c['ready']))
            return moves

        g.define_tension("process_io", process_io, priority=20)

        p = g.create_entity(c['type'], "P", c['cpu0'])

        # Block P
        g.move("block", p, c['blocked'])
        assert g.where_is(p) == c['blocked']

        # Signal I/O completion
        g.signal(p, io_complete)
        assert g.where_is(p) == io_complete

        # System responds: unblock → schedule
        ops = g.run()
        assert ops == 2  # io_unblock + schedule
        assert g.where_is(p) == c['cpu0']


# =============================================================================
# PRIORITY
# =============================================================================

class TestPriority:
    """Test tension priority ordering."""

    def test_higher_priority_fires_first(self):
        """Higher priority tensions resolve before lower ones."""
        g = MoveGraph()
        t = g.define_entity_type("Thing")
        start = g.define_container("START", entity_type=t)
        dest_high = g.define_container("DEST_HIGH", entity_type=t)
        dest_low = g.define_container("DEST_LOW", entity_type=t)

        g.define_move("to_high", [start], [dest_high], t)
        g.define_move("to_low", [start], [dest_low], t)

        thing = g.create_entity(t, "thing", start)

        # Two tensions competing for the same entity
        def want_high(graph):
            if graph.where_is(thing) == start:
                return [IntendedMove("to_high", thing, dest_high)]
            return []

        def want_low(graph):
            if graph.where_is(thing) == start:
                return [IntendedMove("to_low", thing, dest_low)]
            return []

        g.define_tension("high", want_high, priority=20)
        g.define_tension("low", want_low, priority=5)

        g.run()

        # High priority should have won
        assert g.where_is(thing) == dest_high

    def test_same_priority_both_fire(self):
        """Same priority tensions both fire (for different entities)."""
        g = MoveGraph()
        t = g.define_entity_type("Thing")
        pool = g.define_container("POOL", entity_type=t)
        dest = g.define_container("DEST", entity_type=t)

        g.define_move("go", [pool], [dest], t)

        a = g.create_entity(t, "A", pool)
        b = g.create_entity(t, "B", pool)

        def move_a(graph):
            if graph.where_is(a) == pool:
                return [IntendedMove("go", a, dest)]
            return []

        def move_b(graph):
            if graph.where_is(b) == pool:
                return [IntendedMove("go", b, dest)]
            return []

        g.define_tension("move_a", move_a, priority=10)
        g.define_tension("move_b", move_b, priority=10)

        ops = g.run()

        assert ops == 2
        assert g.where_is(a) == dest
        assert g.where_is(b) == dest


# =============================================================================
# SAFETY GUARANTEES
# =============================================================================

class TestSafety:
    """Test that tensions preserve operation-set safety."""

    def test_tension_cant_bypass_operation_set(self):
        """A tension that tries an invalid move simply fails."""
        g = MoveGraph()
        t = g.define_entity_type("Thing")
        a = g.define_container("A", entity_type=t)
        b = g.define_container("B", entity_type=t)

        # NO move defined from A to B
        thing = g.create_entity(t, "thing", a)

        def want_impossible(graph):
            return [IntendedMove("nonexistent_move", thing, b)]

        g.define_tension("impossible", want_impossible)

        ops = g.run(max_steps=5)

        # Tension fires but move doesn't exist — nothing happens
        # run() hits max_steps because tension keeps trying
        assert g.where_is(thing) == a

    def test_tension_cant_double_fill_slot(self):
        """Tension can't put two entities in a slot."""
        g = MoveGraph()
        t = g.define_entity_type("Thing")
        pool = g.define_container("POOL", entity_type=t)
        slot = g.define_container("SLOT", ContainerKind.SLOT, entity_type=t)

        g.define_move("fill", [pool], [slot], t)

        a = g.create_entity(t, "A", pool)
        b = g.create_entity(t, "B", pool)

        def fill_slot(graph):
            moves = []
            for entity in list(graph.contents_of(pool)):
                moves.append(IntendedMove("fill", entity, slot))
            return moves

        g.define_tension("fill", fill_slot)

        g.run()

        # Exactly one entity in slot, one still in pool
        slot_contents = g.contents_of(slot)
        pool_contents = g.contents_of(pool)
        assert len(slot_contents) == 1
        assert len(pool_contents) == 1

    def test_tension_respects_entity_type(self):
        """Tension can't move wrong entity type."""
        g = MoveGraph()
        type_a = g.define_entity_type("TypeA")
        type_b = g.define_entity_type("TypeB")

        pool_a = g.define_container("POOL_A", entity_type=type_a)
        pool_b = g.define_container("POOL_B", entity_type=type_b)
        dest = g.define_container("DEST", entity_type=type_a)

        g.define_move("go", [pool_a], [dest], type_a)

        entity_a = g.create_entity(type_a, "A", pool_a)
        entity_b = g.create_entity(type_b, "B", pool_b)

        # Tension tries to move entity_b with a type_a move
        def bad_move(graph):
            return [IntendedMove("go", entity_b, dest)]

        g.define_tension("bad", bad_move)

        g.run(max_steps=3)

        # entity_b should not have moved
        assert g.where_is(entity_b) == pool_b


# =============================================================================
# PROVENANCE
# =============================================================================

class TestTensionProvenance:
    """Test that tension-caused operations are properly tracked."""

    def test_cause_tracks_tension_name(self, scheduler_graph):
        """Operations caused by tensions record the tension name."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['ready'])

        g.run()

        history = g.why(p)
        assert len(history) == 1
        assert history[0].cause == "tension:schedule_ready"

    def test_signal_cause_tracked(self, scheduler_graph):
        """Signal operations are tracked separately."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['ready'])

        g.run()  # P → CPU
        g.signal(p, c['ready'])  # External disturbance

        history = g.why(p)
        assert any(op.cause == "external_signal" for op in history)

    def test_full_provenance_chain(self, scheduler_graph):
        """Track the full provenance of a process through scheduling lifecycle."""
        g, c = scheduler_graph

        timer = g.define_container("TIMER_EXPIRED", entity_type=c['type'])
        g.define_move("timer_preempt", [timer], [c['ready']], c['type'])

        def process_timer(graph):
            moves = []
            for proc in list(graph.contents_of(timer)):
                moves.append(IntendedMove("timer_preempt", proc, c['ready']))
            return moves

        g.define_tension("timer", process_timer, priority=20)

        p = g.create_entity(c['type'], "P", c['ready'])

        # Boot
        g.run()
        assert g.where_is(p) == c['cpu0']

        # Timer expires
        g.signal(p, timer)
        g.run()

        history = g.why(p)
        assert len(history) == 4  # schedule, signal, timer_preempt, re-schedule
        causes = [op.cause for op in history]
        assert causes[0] == "tension:schedule_ready"   # Boot
        assert causes[1] == "external_signal"           # Timer signal
        assert causes[2] == "tension:timer"             # Timer processing
        assert causes[3] == "tension:schedule_ready"    # Re-scheduled


# =============================================================================
# TICK AND RUN
# =============================================================================

class TestTickAndRun:
    """Test tick_and_run() method."""

    def test_tick_advances_time(self, scheduler_graph):
        """tick_and_run() advances the tick counter."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['ready'])

        assert g.current_tick == 0
        g.tick_and_run()
        assert g.current_tick == 1

    def test_tick_and_run_resolves_tensions(self, scheduler_graph):
        """tick_and_run() resolves tensions after advancing time."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['ready'])

        ops = g.tick_and_run()

        assert ops == 1
        assert g.where_is(p) == c['cpu0']

    def test_multiple_ticks(self, scheduler_graph):
        """Multiple tick_and_run() calls work correctly."""
        g, c = scheduler_graph
        p = g.create_entity(c['type'], "P", c['ready'])

        ops1 = g.tick_and_run()
        assert ops1 == 1  # Schedules P

        ops2 = g.tick_and_run()
        assert ops2 == 0  # Already at equilibrium

        assert g.current_tick == 2


# =============================================================================
# MULTIPLE INTERACTING TENSIONS
# =============================================================================

class TestInteractingTensions:
    """Test scenarios where multiple tensions interact."""

    def test_cascading_response(self):
        """One tension's result activates another tension."""
        g = MoveGraph()
        t = g.define_entity_type("Packet")

        inbox = g.define_container("INBOX", entity_type=t)
        processing = g.define_container("PROCESSING", ContainerKind.SLOT, entity_type=t)
        outbox = g.define_container("OUTBOX", entity_type=t)

        g.define_move("accept", [inbox], [processing], t)
        g.define_move("complete", [processing], [outbox], t)

        pkt = g.create_entity(t, "pkt", inbox)

        # Tension 1: accept packets from inbox
        def accept_packets(graph):
            moves = []
            for p in list(graph.contents_of(inbox)):
                if graph.containers[processing].is_empty():
                    moves.append(IntendedMove("accept", p, processing))
            return moves

        # Tension 2: immediately complete processed packets
        def complete_packets(graph):
            moves = []
            for p in list(graph.contents_of(processing)):
                moves.append(IntendedMove("complete", p, outbox))
            return moves

        g.define_tension("accept", accept_packets, priority=10)
        g.define_tension("complete", complete_packets, priority=5)

        ops = g.run()

        # Should cascade: inbox → processing → outbox
        assert ops == 2
        assert g.where_is(pkt) == outbox

    def test_scheduler_with_signal_containers(self):
        """Full scheduler scenario with signal processing tensions."""
        g = MoveGraph()
        pt = g.define_entity_type("Process")

        ready = g.define_container("READY", entity_type=pt)
        cpu = g.define_container("CPU", ContainerKind.SLOT, entity_type=pt)
        timer_sig = g.define_container("TIMER_SIG", entity_type=pt)

        g.define_move("schedule", [ready], [cpu], pt)
        g.define_move("timer_preempt", [timer_sig], [ready], pt)

        def schedule(graph):
            procs = list(graph.contents_of(ready))
            if procs and graph.containers[cpu].is_empty():
                return [IntendedMove("schedule", procs[0], cpu)]
            return []

        def handle_timer(graph):
            moves = []
            for p in list(graph.contents_of(timer_sig)):
                moves.append(IntendedMove("timer_preempt", p, ready))
            return moves

        g.define_tension("schedule", schedule, priority=10)
        g.define_tension("timer", handle_timer, priority=20)

        p1 = g.create_entity(pt, "P1", ready)
        p2 = g.create_entity(pt, "P2", ready)

        # Boot: P1 gets CPU
        g.run()
        assert g.where_is(p1) == cpu
        assert g.where_is(p2) == ready

        # Timer expires for P1
        g.signal(p1, timer_sig)
        g.run()

        # P1 goes to READY via timer, P2 (or P1) gets CPU
        assert g.where_is(p1) in [cpu, ready]
        assert g.where_is(p2) in [cpu, ready]
        # Exactly one on CPU
        on_cpu = [p for p in [p1, p2] if g.where_is(p) == cpu]
        assert len(on_cpu) == 1


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
