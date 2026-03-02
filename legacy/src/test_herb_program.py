"""
Tests for HERB Program Representation.

Proves that HERB programs — pure data structures with no Python callables —
produce correct behavior when loaded and executed by the runtime.

The acid test: the declarative scheduler program produces IDENTICAL
behavior to the hand-coded Python version in demo_scheduler.py.
"""

import pytest
from herb_move import MoveGraph, ContainerKind
from herb_program import HerbProgram, validate_program
from herb_scheduler import SCHEDULER
from herb_dom import DOM_LAYOUT


# =============================================================================
# LOADING BASICS
# =============================================================================

class TestLoading:
    """Test that program specifications load correctly."""

    def test_minimal_program(self):
        """Smallest valid program: one type, one container, one entity."""
        spec = {
            "entity_types": [{"name": "Thing"}],
            "containers": [{"name": "HOME", "kind": "simple", "entity_type": "Thing"}],
            "moves": [],
            "tensions": [],
            "entities": [{"name": "x", "type": "Thing", "in": "HOME"}],
        }
        program = HerbProgram(spec)
        g = program.load()

        assert program.where_is("x") == "HOME"
        assert len(g.entities) > 0

    def test_entity_types_registered(self):
        """Entity types get IDs assigned."""
        spec = {
            "entity_types": [{"name": "Alpha"}, {"name": "Beta"}],
            "containers": [],
            "moves": [],
            "tensions": [],
            "entities": [],
        }
        program = HerbProgram(spec)
        program.load()

        assert program.type_id("Alpha") is not None
        assert program.type_id("Beta") is not None
        assert program.type_id("Alpha") != program.type_id("Beta")

    def test_containers_registered(self):
        """Containers get IDs and correct kinds."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "QUEUE", "kind": "simple", "entity_type": "T"},
                {"name": "SLOT", "kind": "slot", "entity_type": "T"},
            ],
            "moves": [],
            "tensions": [],
            "entities": [],
        }
        program = HerbProgram(spec)
        g = program.load()

        q_id = program.container_id("QUEUE")
        s_id = program.container_id("SLOT")
        assert g.containers[q_id].kind == ContainerKind.SIMPLE
        assert g.containers[s_id].kind == ContainerKind.SLOT

    def test_moves_registered(self):
        """Moves are registered in the operation set."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "A", "entity_type": "T"},
                {"name": "B", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["A"], "to": ["B"], "entity_type": "T"},
            ],
            "tensions": [],
            "entities": [{"name": "x", "type": "T", "in": "A"}],
        }
        program = HerbProgram(spec)
        g = program.load()

        # Move should exist
        eid = program.entity_id("x")
        bid = program.container_id("B")
        exists, _ = g.operation_exists("go", eid, bid)
        assert exists

    def test_entities_placed(self):
        """Entities start in their declared containers."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "A", "entity_type": "T"},
                {"name": "B", "entity_type": "T"},
            ],
            "moves": [],
            "tensions": [],
            "entities": [
                {"name": "x", "type": "T", "in": "A"},
                {"name": "y", "type": "T", "in": "B"},
            ],
        }
        program = HerbProgram(spec)
        program.load()

        assert program.where_is("x") == "A"
        assert program.where_is("y") == "B"


# =============================================================================
# TENSION COMPILATION — BASIC
# =============================================================================

class TestTensionBasic:
    """Test that compiled tensions produce correct behavior."""

    def test_simple_tension(self):
        """Tension moves entity from A to B."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "A", "entity_type": "T"},
                {"name": "B", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["A"], "to": ["B"], "entity_type": "T"},
            ],
            "tensions": [{
                "name": "move_it",
                "priority": 0,
                "match": [{"bind": "x", "in": "A"}],
                "emit": [{"move": "go", "entity": "x", "to": "B"}],
            }],
            "entities": [{"name": "thing", "type": "T", "in": "A"}],
        }
        program = HerbProgram(spec)
        g = program.load()

        ops = g.run()

        assert ops == 1
        assert program.where_is("thing") == "B"

    def test_tension_inactive_when_empty(self):
        """Tension doesn't fire when matched container is empty."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "A", "entity_type": "T"},
                {"name": "B", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["A"], "to": ["B"], "entity_type": "T"},
            ],
            "tensions": [{
                "name": "move_it",
                "match": [{"bind": "x", "in": "A"}],
                "emit": [{"move": "go", "entity": "x", "to": "B"}],
            }],
            "entities": [{"name": "thing", "type": "T", "in": "B"}],
        }
        program = HerbProgram(spec)
        g = program.load()

        ops = g.run()
        assert ops == 0

    def test_tension_with_literal_to(self):
        """Emit 'to' can be a literal container name, not a binding."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "SRC", "entity_type": "T"},
                {"name": "DST", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["SRC"], "to": ["DST"], "entity_type": "T"},
            ],
            "tensions": [{
                "name": "push",
                "match": [{"bind": "x", "in": "SRC"}],
                "emit": [{"move": "go", "entity": "x", "to": "DST"}],
            }],
            "entities": [{"name": "ball", "type": "T", "in": "SRC"}],
        }
        program = HerbProgram(spec)
        g = program.load()
        g.run()

        assert program.where_is("ball") == "DST"


# =============================================================================
# MATCH CLAUSE TYPES
# =============================================================================

class TestMatchClauses:
    """Test different match clause types."""

    def test_empty_in_match(self):
        """Match finds empty containers from a list."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "POOL", "entity_type": "T"},
                {"name": "S0", "kind": "slot", "entity_type": "T"},
                {"name": "S1", "kind": "slot", "entity_type": "T"},
            ],
            "moves": [
                {"name": "fill", "from": ["POOL"], "to": ["S0", "S1"], "entity_type": "T"},
            ],
            "tensions": [{
                "name": "fill_slots",
                "match": [
                    {"bind": "item", "in": "POOL", "select": "each"},
                    {"bind": "slot", "empty_in": ["S0", "S1"], "select": "each"},
                ],
                "pair": "zip",
                "emit": [{"move": "fill", "entity": "item", "to": "slot"}],
            }],
            "entities": [
                {"name": "a", "type": "T", "in": "POOL"},
                {"name": "b", "type": "T", "in": "POOL"},
            ],
        }
        program = HerbProgram(spec)
        g = program.load()
        g.run()

        # Both slots filled
        s0_contents = g.contents_of(program.container_id("S0"))
        s1_contents = g.contents_of(program.container_id("S1"))
        assert len(s0_contents) == 1
        assert len(s1_contents) == 1

    def test_boolean_guard_empty(self):
        """Boolean guard: container must be empty."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "SRC", "entity_type": "T"},
                {"name": "DST", "entity_type": "T"},
                {"name": "GUARD", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["SRC"], "to": ["DST"], "entity_type": "T"},
            ],
            "tensions": [{
                "name": "guarded_move",
                "match": [
                    {"bind": "x", "in": "SRC"},
                    {"container": "GUARD", "is": "empty"},
                ],
                "emit": [{"move": "go", "entity": "x", "to": "DST"}],
            }],
            "entities": [
                {"name": "mover", "type": "T", "in": "SRC"},
                {"name": "blocker", "type": "T", "in": "GUARD"},
            ],
        }
        program = HerbProgram(spec)
        g = program.load()

        ops = g.run()
        # Guard container is occupied → tension doesn't fire
        assert ops == 0
        assert program.where_is("mover") == "SRC"

    def test_boolean_guard_occupied(self):
        """Boolean guard: container must be occupied."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "SRC", "entity_type": "T"},
                {"name": "DST", "entity_type": "T"},
                {"name": "TRIGGER", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["SRC"], "to": ["DST"], "entity_type": "T"},
            ],
            "tensions": [{
                "name": "triggered_move",
                "match": [
                    {"bind": "x", "in": "SRC"},
                    {"container": "TRIGGER", "is": "occupied"},
                ],
                "emit": [{"move": "go", "entity": "x", "to": "DST"}],
            }],
            "entities": [
                {"name": "mover", "type": "T", "in": "SRC"},
                {"name": "flag", "type": "T", "in": "TRIGGER"},
            ],
        }
        program = HerbProgram(spec)
        g = program.load()

        ops = g.run()
        assert ops == 1
        assert program.where_is("mover") == "DST"

    def test_optional_match(self):
        """Optional match clause: tension fires even if optional fails."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "SRC", "entity_type": "T"},
                {"name": "DST1", "entity_type": "T"},
                {"name": "DST2", "entity_type": "T"},
                {"name": "MAYBE", "entity_type": "T"},
            ],
            "moves": [
                {"name": "always_go", "from": ["SRC"], "to": ["DST1"], "entity_type": "T"},
                {"name": "maybe_go", "from": ["MAYBE"], "to": ["DST2"], "entity_type": "T"},
            ],
            "tensions": [{
                "name": "partial",
                "match": [
                    {"bind": "x", "in": "SRC"},
                    {"bind": "y", "in": "MAYBE", "required": False},
                ],
                "emit": [
                    {"move": "always_go", "entity": "x", "to": "DST1"},
                    {"move": "maybe_go", "entity": "y", "to": "DST2"},
                ],
            }],
            "entities": [
                {"name": "main", "type": "T", "in": "SRC"},
                # Note: nothing in MAYBE
            ],
        }
        program = HerbProgram(spec)
        g = program.load()

        ops = g.run()
        # First emit fires (x is bound), second skipped (y is unbound)
        assert ops == 1
        assert program.where_is("main") == "DST1"


# =============================================================================
# PAIRING MODES
# =============================================================================

class TestPairing:
    """Test vector pairing modes."""

    def test_zip_pairing(self):
        """Zip pairs first-to-first, second-to-second."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "POOL", "entity_type": "T"},
                {"name": "S0", "kind": "slot", "entity_type": "T"},
                {"name": "S1", "kind": "slot", "entity_type": "T"},
                {"name": "S2", "kind": "slot", "entity_type": "T"},
            ],
            "moves": [
                {"name": "place", "from": ["POOL"], "to": ["S0", "S1", "S2"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "fill",
                "match": [
                    {"bind": "item", "in": "POOL", "select": "each"},
                    {"bind": "slot", "empty_in": ["S0", "S1", "S2"], "select": "each"},
                ],
                "pair": "zip",
                "emit": [{"move": "place", "entity": "item", "to": "slot"}],
            }],
            "entities": [
                {"name": "a", "type": "T", "in": "POOL"},
                {"name": "b", "type": "T", "in": "POOL"},
            ],
        }
        program = HerbProgram(spec)
        g = program.load()
        g.run()

        # 2 items, 3 slots → zip gives 2 placements
        filled = sum(1 for s in ["S0", "S1", "S2"]
                     if not g.containers[program.container_id(s)].is_empty())
        assert filled == 2

    def test_cross_pairing(self):
        """Cross produces Cartesian product (only first succeeds for slots)."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "POOL", "entity_type": "T"},
                {"name": "S0", "kind": "slot", "entity_type": "T"},
                {"name": "S1", "kind": "slot", "entity_type": "T"},
            ],
            "moves": [
                {"name": "place", "from": ["POOL"], "to": ["S0", "S1"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "fill",
                "match": [
                    {"bind": "item", "in": "POOL", "select": "each"},
                    {"bind": "slot", "empty_in": ["S0", "S1"], "select": "each"},
                ],
                "pair": "cross",
                "emit": [{"move": "place", "entity": "item", "to": "slot"}],
            }],
            "entities": [
                {"name": "a", "type": "T", "in": "POOL"},
                {"name": "b", "type": "T", "in": "POOL"},
            ],
        }
        program = HerbProgram(spec)
        g = program.load()
        g.run()

        # Cross product produces all combos, but slot constraints mean
        # only valid placements succeed
        s0 = g.contents_of(program.container_id("S0"))
        s1 = g.contents_of(program.container_id("S1"))
        assert len(s0) <= 1
        assert len(s1) <= 1

    def test_scalar_plus_vector(self):
        """Scalar binding included in all vector binding sets."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "TRIGGER", "entity_type": "T"},
                {"name": "POOL", "entity_type": "T"},
                {"name": "DST", "entity_type": "T"},
                {"name": "DONE", "entity_type": "T"},
            ],
            "moves": [
                {"name": "process", "from": ["POOL"], "to": ["DST"], "entity_type": "T"},
                {"name": "ack", "from": ["TRIGGER"], "to": ["DONE"], "entity_type": "T"},
            ],
            "tensions": [{
                "name": "process_all",
                "match": [
                    {"bind": "sig", "in": "TRIGGER", "select": "first"},
                    {"bind": "item", "in": "POOL", "select": "each"},
                ],
                "emit": [
                    {"move": "process", "entity": "item", "to": "DST"},
                ],
            }],
            "entities": [
                {"name": "trigger", "type": "T", "in": "TRIGGER"},
                {"name": "a", "type": "T", "in": "POOL"},
                {"name": "b", "type": "T", "in": "POOL"},
                {"name": "c", "type": "T", "in": "POOL"},
            ],
        }
        program = HerbProgram(spec)
        g = program.load()
        g.run()

        # All pool items should move to DST (trigger is scalar, items are vector)
        assert program.where_is("a") == "DST"
        assert program.where_is("b") == "DST"
        assert program.where_is("c") == "DST"
        assert program.where_is("trigger") == "TRIGGER"  # Not moved by this tension


# =============================================================================
# SAFETY GUARANTEES
# =============================================================================

class TestSafety:
    """Declarative tensions preserve operation-set safety."""

    def test_compiled_tension_cant_bypass_ops(self):
        """Compiled tension can't create moves outside the operation set."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "A", "entity_type": "T"},
                {"name": "B", "entity_type": "T"},
            ],
            "moves": [],  # NO moves defined
            "tensions": [{
                "name": "impossible",
                "match": [{"bind": "x", "in": "A"}],
                "emit": [{"move": "nonexistent", "entity": "x", "to": "B"}],
            }],
            "entities": [{"name": "stuck", "type": "T", "in": "A"}],
        }
        program = HerbProgram(spec)
        g = program.load()

        ops = g.run(max_steps=5)
        assert program.where_is("stuck") == "A"

    def test_compiled_tension_cant_double_fill_slot(self):
        """Compiled tension respects slot constraints."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "POOL", "entity_type": "T"},
                {"name": "SLOT", "kind": "slot", "entity_type": "T"},
            ],
            "moves": [
                {"name": "fill", "from": ["POOL"], "to": ["SLOT"], "entity_type": "T"},
            ],
            "tensions": [{
                "name": "fill_all",
                "match": [{"bind": "x", "in": "POOL", "select": "each"}],
                "emit": [{"move": "fill", "entity": "x", "to": "SLOT"}],
            }],
            "entities": [
                {"name": "a", "type": "T", "in": "POOL"},
                {"name": "b", "type": "T", "in": "POOL"},
            ],
        }
        program = HerbProgram(spec)
        g = program.load()
        g.run()

        slot = g.contents_of(program.container_id("SLOT"))
        pool = g.contents_of(program.container_id("POOL"))
        assert len(slot) == 1
        assert len(pool) == 1


# =============================================================================
# THE ACID TEST: SCHEDULER EQUIVALENCE
# =============================================================================

class TestSchedulerEquivalence:
    """
    Prove the declarative scheduler produces IDENTICAL behavior
    to the hand-coded Python version.
    """

    def setup_method(self):
        """Load the scheduler program."""
        self.program = HerbProgram(SCHEDULER)
        self.g = self.program.load()

    def test_boot_fills_cpus(self):
        """Boot: 3 processes ready, 2 CPUs → 2 scheduled, 1 waiting."""
        ops = self.g.run()

        assert ops == 2
        assert self.program.where_is("init") == "CPU0"
        assert self.program.where_is("shell") == "CPU1"
        assert self.program.where_is("daemon") == "READY_QUEUE"

    def test_timer_preemption(self):
        """Timer signal preempts CPU0 process, system reschedules."""
        self.g.run()  # Boot

        self.program.create_entity("timer_1", "Signal", "TIMER_EXPIRED")
        ops = self.g.run()

        assert ops == 3  # consume + preempt + reschedule
        # init gets preempted then rescheduled (first in sorted order)
        assert self.program.where_is("init") == "CPU0"
        assert self.program.where_is("shell") == "CPU1"
        assert self.program.where_is("daemon") == "READY_QUEUE"

    def test_block_and_reschedule(self):
        """Blocking a process frees CPU for waiting process."""
        self.g.run()  # Boot

        # Block shell
        self.g.move("block",
                    self.program.entity_id("shell"),
                    self.program.container_id("BLOCKED"),
                    cause='io_request')
        ops = self.g.run()

        assert ops == 1  # daemon scheduled to freed CPU
        assert self.program.where_is("init") == "CPU0"
        assert self.program.where_is("shell") == "BLOCKED"
        assert self.program.where_is("daemon") == "CPU1"

    def test_io_completion(self):
        """I/O signal unblocks process, but CPUs may be full."""
        self.g.run()  # Boot

        # Block shell, daemon fills CPU1
        self.g.move("block",
                    self.program.entity_id("shell"),
                    self.program.container_id("BLOCKED"),
                    cause='io_request')
        self.g.run()

        # I/O complete
        self.program.create_entity("io_1", "Signal", "IO_COMPLETE")
        ops = self.g.run()

        assert ops == 2  # consume + unblock
        assert self.program.where_is("shell") == "READY_QUEUE"

    def test_full_scenario_matches_demo(self):
        """
        Complete scenario matching demo_scheduler.py output.
        This is THE test that proves equivalence.
        """
        g = self.g

        # Boot
        boot_ops = g.run()
        assert boot_ops == 2
        assert self.program.where_is("init") == "CPU0"
        assert self.program.where_is("shell") == "CPU1"
        assert self.program.where_is("daemon") == "READY_QUEUE"

        # Timer 1
        self.program.create_entity("timer_1", "Signal", "TIMER_EXPIRED")
        timer1_ops = g.run()
        assert timer1_ops == 3
        assert self.program.where_is("init") == "CPU0"
        assert self.program.where_is("shell") == "CPU1"
        assert self.program.where_is("daemon") == "READY_QUEUE"

        # Block shell
        g.move("block",
               self.program.entity_id("shell"),
               self.program.container_id("BLOCKED"),
               cause='io_request')
        block_ops = g.run()
        assert block_ops == 1
        assert self.program.where_is("init") == "CPU0"
        assert self.program.where_is("shell") == "BLOCKED"
        assert self.program.where_is("daemon") == "CPU1"

        # I/O complete
        self.program.create_entity("io_1", "Signal", "IO_COMPLETE")
        io_ops = g.run()
        assert io_ops == 2
        assert self.program.where_is("init") == "CPU0"
        assert self.program.where_is("shell") == "READY_QUEUE"
        assert self.program.where_is("daemon") == "CPU1"

        # Timer 2
        self.program.create_entity("timer_2", "Signal", "TIMER_EXPIRED")
        timer2_ops = g.run()
        assert timer2_ops == 3
        assert self.program.where_is("init") == "CPU0"
        assert self.program.where_is("shell") == "READY_QUEUE"
        assert self.program.where_is("daemon") == "CPU1"

        # Total operations
        assert len(g.operations) == 12

    def test_provenance_chain(self):
        """Provenance tracks tension-caused moves correctly."""
        g = self.g
        g.run()

        history = g.why(self.program.entity_id("init"))
        assert len(history) == 1
        assert history[0].op_type == "schedule"
        assert history[0].cause == "tension:schedule_ready"


# =============================================================================
# VALIDATION
# =============================================================================

class TestValidation:
    """Test program validation catches errors."""

    def test_valid_program(self):
        """Scheduler program should validate clean."""
        errors = validate_program(SCHEDULER)
        assert errors == []

    def test_missing_entity_type(self):
        """Reference to unknown entity type caught."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "A", "entity_type": "Unknown"}],
        }
        errors = validate_program(spec)
        assert any("Unknown" in e for e in errors)

    def test_missing_container_in_move(self):
        """Reference to unknown container in move caught."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "A", "entity_type": "T"}],
            "moves": [{"name": "go", "from": ["A"], "to": ["MISSING"]}],
        }
        errors = validate_program(spec)
        assert any("MISSING" in e for e in errors)

    def test_missing_move_in_tension(self):
        """Reference to unknown move in tension emit caught."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "A", "entity_type": "T"}],
            "moves": [],
            "tensions": [{
                "name": "bad",
                "match": [{"bind": "x", "in": "A"}],
                "emit": [{"move": "nonexistent", "entity": "x", "to": "A"}],
            }],
        }
        errors = validate_program(spec)
        assert any("nonexistent" in e for e in errors)

    def test_invalid_container_kind(self):
        """Invalid container kind caught."""
        spec = {
            "entity_types": [],
            "containers": [{"name": "X", "kind": "magic"}],
        }
        errors = validate_program(spec)
        assert any("magic" in e for e in errors)


# =============================================================================
# RUNTIME ENTITY CREATION
# =============================================================================

class TestRuntimeEntities:
    """Test creating entities at runtime (for signals, etc.)."""

    def test_create_runtime_entity(self):
        """Entities can be created after program loads."""
        spec = {
            "entity_types": [{"name": "Signal"}],
            "containers": [
                {"name": "INBOX", "entity_type": "Signal"},
                {"name": "DONE", "entity_type": "Signal"},
            ],
            "moves": [
                {"name": "process", "from": ["INBOX"], "to": ["DONE"],
                 "entity_type": "Signal"},
            ],
            "tensions": [{
                "name": "drain",
                "match": [{"bind": "s", "in": "INBOX"}],
                "emit": [{"move": "process", "entity": "s", "to": "DONE"}],
            }],
            "entities": [],
        }
        program = HerbProgram(spec)
        g = program.load()

        # System at equilibrium (empty)
        assert g.run() == 0

        # Create signal at runtime
        program.create_entity("sig_1", "Signal", "INBOX")
        ops = g.run()

        assert ops == 1
        assert program.where_is("sig_1") == "DONE"


# =============================================================================
# EDGE CASES
# =============================================================================

class TestEdgeCases:
    """Edge cases and boundary conditions."""

    def test_empty_program(self):
        """Program with no entities still loads."""
        spec = {
            "entity_types": [],
            "containers": [],
            "moves": [],
            "tensions": [],
            "entities": [],
        }
        program = HerbProgram(spec)
        g = program.load()
        assert g.run() == 0

    def test_tension_with_no_match(self):
        """Tension with empty match always fires."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "A", "entity_type": "T"},
                {"name": "B", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["A"], "to": ["B"], "entity_type": "T"},
            ],
            "tensions": [{
                "name": "unconditional",
                "match": [],
                "emit": [],  # No emits either — no-op
            }],
            "entities": [{"name": "x", "type": "T", "in": "A"}],
        }
        program = HerbProgram(spec)
        g = program.load()
        ops = g.run()
        assert ops == 0  # No emits, so nothing happens

    def test_multiple_tensions_priority(self):
        """Higher priority tension wins for same entity."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "SRC", "entity_type": "T"},
                {"name": "HIGH", "entity_type": "T"},
                {"name": "LOW", "entity_type": "T"},
            ],
            "moves": [
                {"name": "to_high", "from": ["SRC"], "to": ["HIGH"], "entity_type": "T"},
                {"name": "to_low", "from": ["SRC"], "to": ["LOW"], "entity_type": "T"},
            ],
            "tensions": [
                {
                    "name": "high",
                    "priority": 20,
                    "match": [{"bind": "x", "in": "SRC"}],
                    "emit": [{"move": "to_high", "entity": "x", "to": "HIGH"}],
                },
                {
                    "name": "low",
                    "priority": 5,
                    "match": [{"bind": "x", "in": "SRC"}],
                    "emit": [{"move": "to_low", "entity": "x", "to": "LOW"}],
                },
            ],
            "entities": [{"name": "x", "type": "T", "in": "SRC"}],
        }
        program = HerbProgram(spec)
        g = program.load()
        g.run()

        assert program.where_is("x") == "HIGH"

    def test_cascading_tensions(self):
        """One tension's result triggers another."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "A", "entity_type": "T"},
                {"name": "B", "entity_type": "T"},
                {"name": "C", "entity_type": "T"},
            ],
            "moves": [
                {"name": "a_to_b", "from": ["A"], "to": ["B"], "entity_type": "T"},
                {"name": "b_to_c", "from": ["B"], "to": ["C"], "entity_type": "T"},
            ],
            "tensions": [
                {
                    "name": "first",
                    "priority": 10,
                    "match": [{"bind": "x", "in": "A"}],
                    "emit": [{"move": "a_to_b", "entity": "x", "to": "B"}],
                },
                {
                    "name": "second",
                    "priority": 5,
                    "match": [{"bind": "x", "in": "B"}],
                    "emit": [{"move": "b_to_c", "entity": "x", "to": "C"}],
                },
            ],
            "entities": [{"name": "ball", "type": "T", "in": "A"}],
        }
        program = HerbProgram(spec)
        g = program.load()
        ops = g.run()

        assert ops == 2
        assert program.where_is("ball") == "C"


# =============================================================================
# DOM LAYOUT PIPELINE
# =============================================================================

class TestDOMLayout:
    """
    Prove the representation works for browser scenarios.
    The layout pipeline demonstrates cascading tensions:
    style change → invalidation → layout → paint → clean.
    """

    def setup_method(self):
        self.program = HerbProgram(DOM_LAYOUT)
        self.g = self.program.load()

    def test_initial_layout_pipeline(self):
        """Elements start in NEEDS_LAYOUT and cascade to CLEAN."""
        ops = self.g.run()

        # Each element: NEEDS_LAYOUT → LAID_OUT → NEEDS_PAINT → PAINTED → CLEAN
        # That's 4 moves per element, 3 elements = 12
        assert ops == 12
        assert self.program.where_is("header") == "CLEAN"
        assert self.program.where_is("content") == "CLEAN"
        assert self.program.where_is("footer") == "CLEAN"

    def test_style_change_invalidates(self):
        """Style change signal invalidates clean elements, triggering re-layout."""
        self.g.run()  # Initial layout → all CLEAN

        # Style change signal
        self.program.create_entity("color_change", "StyleChange", "STYLE_PENDING")
        ops = self.g.run()

        # apply_style(1) + invalidate(3) + layout(3) + needs_paint(3) + paint(3) + clean(3) = 16
        assert ops == 16
        assert self.program.where_is("header") == "CLEAN"
        assert self.program.where_is("content") == "CLEAN"
        assert self.program.where_is("footer") == "CLEAN"
        assert self.program.where_is("color_change") == "STYLE_APPLIED"

    def test_multiple_style_changes(self):
        """Multiple style changes processed sequentially."""
        self.g.run()  # Initial layout

        self.program.create_entity("change_1", "StyleChange", "STYLE_PENDING")
        self.program.create_entity("change_2", "StyleChange", "STYLE_PENDING")
        self.g.run()

        # Both changes applied, all elements clean
        assert self.program.where_is("change_1") == "STYLE_APPLIED"
        assert self.program.where_is("change_2") == "STYLE_APPLIED"
        assert self.program.where_is("header") == "CLEAN"

    def test_equilibrium_when_clean(self):
        """No tensions active when all elements are clean."""
        self.g.run()

        # Running again does nothing
        ops = self.g.run()
        assert ops == 0

    def test_dom_validation(self):
        """DOM program validates cleanly."""
        errors = validate_program(DOM_LAYOUT)
        assert errors == []


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
