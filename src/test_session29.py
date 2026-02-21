"""
Tests for Session 29: Properties, Expressions, Quantities, Creation.

Proves that the new features work correctly:
1. Entity properties — key-value data on entities
2. Expression evaluator — declarative expression language
3. Property-aware matching — max_by, min_by, where, guard
4. Quantity transfers — conservation pools with structural guarantees
5. Dynamic entity creation — tension emits can create entities
6. Priority scheduler — highest-priority process scheduled first
7. Economy demo — gold transfers with conservation
"""

import pytest
from herb_move import (
    MoveGraph, ContainerKind, IntendedMove,
    IntendedTransfer, IntendedCreate
)
from herb_program import HerbProgram, validate_program, _eval_expr
from herb_scheduler import SCHEDULER
from herb_scheduler_priority import PRIORITY_SCHEDULER
from herb_economy import ECONOMY
from herb_dom import DOM_LAYOUT


# =============================================================================
# ENTITY PROPERTIES — RUNTIME LEVEL
# =============================================================================

class TestEntityProperties:
    """Test entity properties at the MoveGraph level."""

    def test_create_with_properties(self):
        """Entities can be created with initial properties."""
        g = MoveGraph()
        t = g.define_entity_type("Process")
        c = g.define_container("Q", entity_type=t)

        p = g.create_entity(t, "proc", c, {"priority": 5, "time_slice": 50})

        assert g.get_property(p, "priority") == 5
        assert g.get_property(p, "time_slice") == 50
        assert g.get_property(p, "nonexistent") is None

    def test_set_property(self):
        """Properties can be set after creation."""
        g = MoveGraph()
        t = g.define_entity_type("Thing")
        c = g.define_container("C", entity_type=t)

        e = g.create_entity(t, "x", c)
        assert g.get_property(e, "value") is None

        g.set_property(e, "value", 42)
        assert g.get_property(e, "value") == 42

    def test_properties_preserved_through_moves(self):
        """Properties survive entity moves between containers."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        a = g.define_container("A", entity_type=t)
        b = g.define_container("B", entity_type=t)
        g.define_move("go", [a], [b], t)

        e = g.create_entity(t, "x", a, {"score": 100})
        g.move("go", e, b)

        assert g.where_is(e) == b
        assert g.get_property(e, "score") == 100

    def test_create_without_properties_backward_compat(self):
        """Old code without properties still works."""
        g = MoveGraph()
        t = g.define_entity_type("T")
        c = g.define_container("C", entity_type=t)

        e = g.create_entity(t, "x", c)
        assert g.entities[e].properties == {}


# =============================================================================
# CONSERVATION POOLS — RUNTIME LEVEL
# =============================================================================

class TestConservationPools:
    """Test quantity pools and transfers at the MoveGraph level."""

    def test_define_pool_and_transfer(self):
        """Pools and transfer types can be defined."""
        g = MoveGraph()
        t = g.define_entity_type("Player")

        g.define_pool("gold", "gold")
        g.define_transfer("send_gold", "gold", t)

        assert "gold" in g.pool_defs
        assert "send_gold" in g.transfer_types

    def test_basic_transfer(self):
        """Quantity transfers between entities."""
        g = MoveGraph()
        t = g.define_entity_type("Player")
        c = g.define_container("WORLD", entity_type=t)

        g.define_pool("gold", "gold")
        g.define_transfer("send_gold", "gold", t)

        alice = g.create_entity(t, "alice", c, {"gold": 500})
        bob = g.create_entity(t, "bob", c, {"gold": 300})

        op_id = g.transfer("send_gold", alice, bob, 100)

        assert op_id is not None
        assert g.get_property(alice, "gold") == 400
        assert g.get_property(bob, "gold") == 400

    def test_transfer_conservation(self):
        """Total quantity is preserved across transfers."""
        g = MoveGraph()
        t = g.define_entity_type("Player")
        c = g.define_container("W", entity_type=t)

        g.define_pool("gold", "gold")
        g.define_transfer("send", "gold", t)

        a = g.create_entity(t, "a", c, {"gold": 500})
        b = g.create_entity(t, "b", c, {"gold": 300})
        total_before = 500 + 300

        g.transfer("send", a, b, 100)
        g.transfer("send", b, a, 50)
        g.transfer("send", a, b, 200)

        total_after = g.get_property(a, "gold") + g.get_property(b, "gold")
        assert total_after == total_before

    def test_transfer_insufficient_funds(self):
        """Transfer doesn't exist if source can't cover amount."""
        g = MoveGraph()
        t = g.define_entity_type("Player")
        c = g.define_container("W", entity_type=t)

        g.define_pool("gold", "gold")
        g.define_transfer("send", "gold", t)

        a = g.create_entity(t, "a", c, {"gold": 50})
        b = g.create_entity(t, "b", c, {"gold": 300})

        op_id = g.transfer("send", a, b, 100)

        assert op_id is None  # Operation doesn't exist
        assert g.get_property(a, "gold") == 50  # Unchanged
        assert g.get_property(b, "gold") == 300

    def test_transfer_negative_amount_rejected(self):
        """Can't transfer negative amounts."""
        g = MoveGraph()
        t = g.define_entity_type("Player")
        c = g.define_container("W", entity_type=t)

        g.define_pool("gold", "gold")
        g.define_transfer("send", "gold", t)

        a = g.create_entity(t, "a", c, {"gold": 500})
        b = g.create_entity(t, "b", c, {"gold": 300})

        assert g.transfer("send", a, b, -50) is None
        assert g.transfer("send", a, b, 0) is None

    def test_transfer_logs_operation(self):
        """Transfers are logged for provenance."""
        g = MoveGraph()
        t = g.define_entity_type("Player")
        c = g.define_container("W", entity_type=t)

        g.define_pool("gold", "gold")
        g.define_transfer("send", "gold", t)

        a = g.create_entity(t, "a", c, {"gold": 500})
        b = g.create_entity(t, "b", c, {"gold": 300})

        op_id = g.transfer("send", a, b, 100)

        assert op_id is not None
        op = [o for o in g.operations if o.id == op_id][0]
        assert op.op_type == "send"
        assert op.params["amount"] == 100
        assert op.params["from_entity"] == a
        assert op.params["to_entity"] == b

    def test_transfer_wrong_type(self):
        """Transfer with wrong entity type doesn't exist."""
        g = MoveGraph()
        t1 = g.define_entity_type("Player")
        t2 = g.define_entity_type("NPC")
        c = g.define_container("W")

        g.define_pool("gold", "gold")
        g.define_transfer("send", "gold", t1)  # Only for Players

        a = g.create_entity(t1, "a", c, {"gold": 500})
        b = g.create_entity(t2, "b", c, {"gold": 300})

        assert g.transfer("send", a, b, 100) is None


# =============================================================================
# EXPRESSION EVALUATOR
# =============================================================================

class TestExpressionEval:
    """Test the declarative expression evaluator."""

    def setup_method(self):
        """Create a basic graph with properties for testing."""
        self.g = MoveGraph()
        t = self.g.define_entity_type("Thing")
        c = self.g.define_container("C", entity_type=t)
        self.e1 = self.g.create_entity(t, "x", c, {"score": 10, "name": "alice"})
        self.e2 = self.g.create_entity(t, "y", c, {"score": 25, "name": "bob"})
        self.entity_ids = {"x": self.e1, "y": self.e2}
        self.container_ids = {"C": c}

    def _eval(self, expr, bindings=None):
        return _eval_expr(
            expr, bindings or {}, self.g,
            self.entity_ids, self.container_ids
        )

    def test_literal_int(self):
        assert self._eval(42) == 42

    def test_literal_float(self):
        assert self._eval(3.14) == 3.14

    def test_literal_bool(self):
        assert self._eval(True) is True

    def test_literal_string(self):
        assert self._eval("hello") == "hello"

    def test_property_access(self):
        assert self._eval({"prop": "score", "of": "x"}) == 10

    def test_property_access_via_binding(self):
        assert self._eval(
            {"prop": "score", "of": "thing"},
            {"thing": self.e2}
        ) == 25

    def test_property_access_nonexistent(self):
        assert self._eval({"prop": "missing", "of": "x"}) is None

    def test_comparison_gt(self):
        assert self._eval({"op": ">", "left": 10, "right": 5}) is True
        assert self._eval({"op": ">", "left": 3, "right": 5}) is False

    def test_comparison_lt(self):
        assert self._eval({"op": "<", "left": 3, "right": 5}) is True

    def test_comparison_eq(self):
        assert self._eval({"op": "==", "left": 5, "right": 5}) is True
        assert self._eval({"op": "==", "left": 5, "right": 3}) is False

    def test_comparison_gte_lte(self):
        assert self._eval({"op": ">=", "left": 5, "right": 5}) is True
        assert self._eval({"op": "<=", "left": 5, "right": 5}) is True

    def test_arithmetic_add(self):
        assert self._eval({"op": "+", "left": 10, "right": 3}) == 13

    def test_arithmetic_sub(self):
        assert self._eval({"op": "-", "left": 10, "right": 3}) == 7

    def test_arithmetic_mul(self):
        assert self._eval({"op": "*", "left": 4, "right": 5}) == 20

    def test_arithmetic_div(self):
        assert self._eval({"op": "//", "left": 10, "right": 3}) == 3

    def test_arithmetic_div_by_zero(self):
        assert self._eval({"op": "//", "left": 10, "right": 0}) is None

    def test_logical_and(self):
        assert self._eval({"op": "and", "left": True, "right": True}) is True
        assert self._eval({"op": "and", "left": True, "right": False}) is False

    def test_logical_or(self):
        assert self._eval({"op": "or", "left": False, "right": True}) is True
        assert self._eval({"op": "or", "left": False, "right": False}) is False

    def test_logical_not(self):
        assert self._eval({"op": "not", "arg": True}) is False
        assert self._eval({"op": "not", "arg": False}) is True

    def test_nested_expression(self):
        """Complex: x.score + y.score > 30"""
        expr = {
            "op": ">",
            "left": {
                "op": "+",
                "left": {"prop": "score", "of": "x"},
                "right": {"prop": "score", "of": "y"},
            },
            "right": 30,
        }
        assert self._eval(expr) is True  # 10 + 25 = 35 > 30

    def test_count_expression(self):
        """Count entities in a container."""
        assert self._eval({"count": "C"}) == 2

    def test_property_comparison(self):
        """x.score < y.score"""
        expr = {
            "op": "<",
            "left": {"prop": "score", "of": "x"},
            "right": {"prop": "score", "of": "y"},
        }
        assert self._eval(expr) is True  # 10 < 25


# =============================================================================
# PROPERTY-AWARE MATCHING (PROGRAM LEVEL)
# =============================================================================

class TestPropertyMatching:
    """Test max_by, min_by, where, and guard in tension matching."""

    def test_max_by_select(self):
        """max_by selects entity with highest property value."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "POOL", "entity_type": "T"},
                {"name": "DST", "kind": "slot", "entity_type": "T"},
            ],
            "moves": [
                {"name": "pick", "from": ["POOL"], "to": ["DST"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "pick_best",
                "match": [
                    {"bind": "x", "in": "POOL",
                     "select": "max_by", "key": "score"},
                ],
                "emit": [
                    {"move": "pick", "entity": "x", "to": "DST"},
                ],
            }],
            "entities": [
                {"name": "low",  "type": "T", "in": "POOL",
                 "properties": {"score": 1}},
                {"name": "mid",  "type": "T", "in": "POOL",
                 "properties": {"score": 5}},
                {"name": "high", "type": "T", "in": "POOL",
                 "properties": {"score": 10}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        # Only the highest-score entity should be picked
        assert prog.where_is("high") == "DST"
        assert prog.where_is("mid") == "POOL"
        assert prog.where_is("low") == "POOL"

    def test_min_by_select(self):
        """min_by selects entity with lowest property value."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "POOL", "entity_type": "T"},
                {"name": "DST", "kind": "slot", "entity_type": "T"},
            ],
            "moves": [
                {"name": "pick", "from": ["POOL"], "to": ["DST"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "pick_worst",
                "match": [
                    {"bind": "x", "in": "POOL",
                     "select": "min_by", "key": "score"},
                ],
                "emit": [
                    {"move": "pick", "entity": "x", "to": "DST"},
                ],
            }],
            "entities": [
                {"name": "low",  "type": "T", "in": "POOL",
                 "properties": {"score": 1}},
                {"name": "mid",  "type": "T", "in": "POOL",
                 "properties": {"score": 5}},
                {"name": "high", "type": "T", "in": "POOL",
                 "properties": {"score": 10}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        assert prog.where_is("low") == "DST"
        assert prog.where_is("mid") == "POOL"
        assert prog.where_is("high") == "POOL"

    def test_where_filter(self):
        """Where clause filters entities before selection."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "SRC", "entity_type": "T"},
                {"name": "DST", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["SRC"], "to": ["DST"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "move_high",
                "match": [
                    {"bind": "x", "in": "SRC", "select": "each",
                     "where": {"op": ">",
                               "left": {"prop": "score", "of": "x"},
                               "right": 5}},
                ],
                "emit": [
                    {"move": "go", "entity": "x", "to": "DST"},
                ],
            }],
            "entities": [
                {"name": "a", "type": "T", "in": "SRC",
                 "properties": {"score": 3}},
                {"name": "b", "type": "T", "in": "SRC",
                 "properties": {"score": 8}},
                {"name": "c", "type": "T", "in": "SRC",
                 "properties": {"score": 12}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        # Only b and c (score > 5) should move
        assert prog.where_is("a") == "SRC"
        assert prog.where_is("b") == "DST"
        assert prog.where_is("c") == "DST"

    def test_guard_expression(self):
        """Guard expression filters complete binding sets."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "SRC", "entity_type": "T"},
                {"name": "DST", "entity_type": "T"},
                {"name": "CTRL", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["SRC"], "to": ["DST"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "guarded",
                "match": [
                    {"bind": "x", "in": "SRC"},
                    {"bind": "ctrl", "in": "CTRL"},
                    # Only fire if ctrl.threshold <= x.value
                    {"guard": {"op": "<=",
                               "left": {"prop": "threshold", "of": "ctrl"},
                               "right": {"prop": "value", "of": "x"}}},
                ],
                "emit": [
                    {"move": "go", "entity": "x", "to": "DST"},
                ],
            }],
            "entities": [
                {"name": "item", "type": "T", "in": "SRC",
                 "properties": {"value": 20}},
                {"name": "gate", "type": "T", "in": "CTRL",
                 "properties": {"threshold": 10}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()
        g.run()

        # 10 <= 20 is true, so move happens
        assert prog.where_is("item") == "DST"

    def test_guard_blocks_when_false(self):
        """Guard blocks tension when expression is false."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "SRC", "entity_type": "T"},
                {"name": "DST", "entity_type": "T"},
                {"name": "CTRL", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["SRC"], "to": ["DST"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "guarded",
                "match": [
                    {"bind": "x", "in": "SRC"},
                    {"bind": "ctrl", "in": "CTRL"},
                    {"guard": {"op": "<=",
                               "left": {"prop": "threshold", "of": "ctrl"},
                               "right": {"prop": "value", "of": "x"}}},
                ],
                "emit": [
                    {"move": "go", "entity": "x", "to": "DST"},
                ],
            }],
            "entities": [
                {"name": "item", "type": "T", "in": "SRC",
                 "properties": {"value": 5}},
                {"name": "gate", "type": "T", "in": "CTRL",
                 "properties": {"threshold": 100}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()
        ops = g.run()

        # 100 <= 5 is false, so no move
        assert ops == 0
        assert prog.where_is("item") == "SRC"


# =============================================================================
# QUANTITY TRANSFERS (PROGRAM LEVEL)
# =============================================================================

class TestProgramTransfers:
    """Test quantity transfers through the program spec."""

    def test_simple_transfer_tension(self):
        """Tension emits a quantity transfer."""
        spec = {
            "entity_types": [{"name": "Player"}],
            "containers": [
                {"name": "WORLD", "entity_type": "Player"},
                {"name": "TRIGGER", "entity_type": "Player"},
                {"name": "DONE", "entity_type": "Player"},
            ],
            "pools": [{"name": "gold", "property": "gold"}],
            "transfers": [{"name": "pay", "pool": "gold"}],
            "moves": [
                {"name": "consume", "from": ["TRIGGER"], "to": ["DONE"],
                 "entity_type": "Player"},
            ],
            "tensions": [{
                "name": "collect",
                "match": [
                    {"bind": "sig", "in": "TRIGGER", "select": "first"},
                ],
                "emit": [
                    {"transfer": "pay", "from": "alice", "to": "bob",
                     "amount": 50},
                    {"move": "consume", "entity": "sig", "to": "DONE"},
                ],
            }],
            "entities": [
                {"name": "alice", "type": "Player", "in": "WORLD",
                 "properties": {"gold": 200}},
                {"name": "bob", "type": "Player", "in": "WORLD",
                 "properties": {"gold": 100}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        # Create trigger
        prog.create_entity("trigger", "Player", "TRIGGER")
        g.run()

        assert prog.get_property("alice", "gold") == 150
        assert prog.get_property("bob", "gold") == 150

    def test_transfer_with_expression_amount(self):
        """Transfer amount can be an expression."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "W", "entity_type": "T"},
                {"name": "SIG", "entity_type": "T"},
                {"name": "DONE", "entity_type": "T"},
            ],
            "pools": [{"name": "gold", "property": "gold"}],
            "transfers": [{"name": "pay", "pool": "gold"}],
            "moves": [
                {"name": "ack", "from": ["SIG"], "to": ["DONE"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "dynamic_pay",
                "match": [
                    {"bind": "invoice", "in": "SIG", "select": "first"},
                ],
                "emit": [
                    {"transfer": "pay", "from": "debtor", "to": "creditor",
                     "amount": {"prop": "cost", "of": "invoice"}},
                    {"move": "ack", "entity": "invoice", "to": "DONE"},
                ],
            }],
            "entities": [
                {"name": "debtor",   "type": "T", "in": "W",
                 "properties": {"gold": 1000}},
                {"name": "creditor", "type": "T", "in": "W",
                 "properties": {"gold": 0}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        prog.create_entity("bill", "T", "SIG", {"cost": 250})
        g.run()

        assert prog.get_property("debtor", "gold") == 750
        assert prog.get_property("creditor", "gold") == 250

    def test_transfer_conservation_in_program(self):
        """Conservation holds across multiple tension-driven transfers."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "W", "entity_type": "T"},
                {"name": "EVENTS", "entity_type": "T"},
                {"name": "DONE", "entity_type": "T"},
            ],
            "pools": [{"name": "gold", "property": "gold"}],
            "transfers": [{"name": "send", "pool": "gold"}],
            "moves": [
                {"name": "ack", "from": ["EVENTS"], "to": ["DONE"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "process",
                "match": [
                    {"bind": "evt", "in": "EVENTS", "select": "first"},
                ],
                "emit": [
                    {"transfer": "send", "from": "a", "to": "b",
                     "amount": 10},
                    {"move": "ack", "entity": "evt", "to": "DONE"},
                ],
            }],
            "entities": [
                {"name": "a", "type": "T", "in": "W",
                 "properties": {"gold": 100}},
                {"name": "b", "type": "T", "in": "W",
                 "properties": {"gold": 50}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()
        total_before = 150

        # Process 5 transfer events
        for i in range(5):
            prog.create_entity(f"evt_{i}", "T", "EVENTS")
            g.run()

        total_after = (prog.get_property("a", "gold") +
                       prog.get_property("b", "gold"))
        assert total_after == total_before
        assert prog.get_property("a", "gold") == 50
        assert prog.get_property("b", "gold") == 100


# =============================================================================
# DYNAMIC ENTITY CREATION
# =============================================================================

class TestDynamicCreation:
    """Test dynamic entity creation from tension emits."""

    def test_create_entity_from_tension(self):
        """Tension can create new entities."""
        spec = {
            "entity_types": [{"name": "Parent"}, {"name": "Child"}],
            "containers": [
                {"name": "WORLD", "entity_type": "Parent"},
                {"name": "NURSERY", "entity_type": "Child"},
                {"name": "SPAWN_SIG", "entity_type": "Parent"},
                {"name": "SPAWN_DONE", "entity_type": "Parent"},
            ],
            "moves": [
                {"name": "ack_spawn", "from": ["SPAWN_SIG"],
                 "to": ["SPAWN_DONE"], "entity_type": "Parent"},
            ],
            "tensions": [{
                "name": "spawn",
                "match": [
                    {"bind": "sig", "in": "SPAWN_SIG", "select": "first"},
                ],
                "emit": [
                    {"create": "Child", "in": "NURSERY",
                     "properties": {"generation": 1}},
                    {"move": "ack_spawn", "entity": "sig",
                     "to": "SPAWN_DONE"},
                ],
            }],
            "entities": [],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        # Trigger spawn
        prog.create_entity("spawn_request", "Parent", "SPAWN_SIG")
        g.run()

        # Check that a child was created in NURSERY
        nursery_contents = g.contents_of(prog.container_id("NURSERY"))
        assert len(nursery_contents) == 1

        child_id = list(nursery_contents)[0]
        assert g.get_property(child_id, "generation") == 1

    def test_create_with_expression_properties(self):
        """Created entity properties can reference parent properties."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "PARENTS", "entity_type": "T"},
                {"name": "CHILDREN", "entity_type": "T"},
                {"name": "SIGNAL", "entity_type": "T"},
                {"name": "DONE", "entity_type": "T"},
            ],
            "moves": [
                {"name": "ack", "from": ["SIGNAL"], "to": ["DONE"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "spawn_child",
                "match": [
                    {"bind": "sig", "in": "SIGNAL", "select": "first"},
                    {"bind": "parent", "in": "PARENTS", "select": "first"},
                ],
                "emit": [
                    {"create": "T", "in": "CHILDREN",
                     "properties": {
                         "generation": {
                             "op": "+",
                             "left": {"prop": "generation", "of": "parent"},
                             "right": 1,
                         },
                     }},
                    {"move": "ack", "entity": "sig", "to": "DONE"},
                ],
            }],
            "entities": [
                {"name": "adam", "type": "T", "in": "PARENTS",
                 "properties": {"generation": 0}},
            ],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        prog.create_entity("go", "T", "SIGNAL")
        g.run()

        children = g.contents_of(prog.container_id("CHILDREN"))
        assert len(children) == 1
        child_id = list(children)[0]
        assert g.get_property(child_id, "generation") == 1

    def test_create_logs_operation(self):
        """Entity creation from tensions is logged for provenance."""
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "DST", "entity_type": "T"},
                {"name": "SIG", "entity_type": "T"},
                {"name": "DONE", "entity_type": "T"},
            ],
            "moves": [
                {"name": "ack", "from": ["SIG"], "to": ["DONE"],
                 "entity_type": "T"},
            ],
            "tensions": [{
                "name": "maker",
                "match": [
                    {"bind": "s", "in": "SIG", "select": "first"},
                ],
                "emit": [
                    {"create": "T", "in": "DST", "properties": {}},
                    {"move": "ack", "entity": "s", "to": "DONE"},
                ],
            }],
            "entities": [],
        }
        prog = HerbProgram(spec)
        g = prog.load()

        prog.create_entity("trigger", "T", "SIG")
        g.run()

        create_ops = [op for op in g.operations if op.op_type == "create"]
        assert len(create_ops) == 1
        assert create_ops[0].cause == "tension:maker"


# =============================================================================
# PRIORITY SCHEDULER
# =============================================================================

class TestPriorityScheduler:
    """
    Prove the priority scheduler works differently from the FIFO scheduler.

    The FIFO scheduler schedules by entity ID (lowest first: init, shell, daemon).
    The priority scheduler schedules by priority property (highest first: daemon, shell, init).
    """

    def setup_method(self):
        self.prog = HerbProgram(PRIORITY_SCHEDULER)
        self.g = self.prog.load()

    def test_boot_schedules_by_priority(self):
        """Boot: highest priority processes get CPUs first."""
        self.g.run()

        # daemon (priority 10) and shell (priority 5) should get CPUs
        # init (priority 1) stays in READY_QUEUE
        assert self.prog.where_is("daemon") == "CPU0"
        assert self.prog.where_is("shell") == "CPU1"
        assert self.prog.where_is("init") == "READY_QUEUE"

    def test_priority_differs_from_fifo(self):
        """Priority scheduler produces different result than FIFO."""
        # Load FIFO scheduler for comparison
        fifo_prog = HerbProgram(SCHEDULER)
        fifo_g = fifo_prog.load()
        fifo_g.run()

        # FIFO: init and shell get CPUs (lowest IDs first)
        assert fifo_prog.where_is("init") == "CPU0"
        assert fifo_prog.where_is("shell") == "CPU1"
        assert fifo_prog.where_is("daemon") == "READY_QUEUE"

        # Priority: daemon and shell get CPUs (highest priority first)
        self.g.run()
        assert self.prog.where_is("daemon") == "CPU0"
        assert self.prog.where_is("shell") == "CPU1"
        assert self.prog.where_is("init") == "READY_QUEUE"

    def test_preempt_reschedules_by_priority(self):
        """After preemption, highest-priority ready process gets the CPU."""
        self.g.run()  # Boot

        # Preempt daemon from CPU0
        self.g.move(
            "preempt",
            self.prog.entity_id("daemon"),
            self.prog.container_id("READY_QUEUE"),
            cause='timer'
        )
        self.g.run()

        # daemon (priority 10) should get CPU0 back (highest priority ready)
        assert self.prog.where_is("daemon") == "CPU0"

    def test_timer_preemption_flow(self):
        """Full timer preemption with priority rescheduling."""
        self.g.run()  # Boot

        # Timer expires
        self.prog.create_entity("timer_1", "Signal", "TIMER_EXPIRED")
        self.g.run()

        # CPU0 was preempted (daemon), rescheduled by priority
        # daemon has highest priority so gets CPU0 back
        assert self.prog.where_is("daemon") == "CPU0"
        assert self.prog.where_is("shell") == "CPU1"
        assert self.prog.where_is("init") == "READY_QUEUE"

    def test_block_and_reschedule_by_priority(self):
        """Blocking frees CPU, init (lowest) finally gets scheduled."""
        self.g.run()  # Boot: daemon on CPU0, shell on CPU1

        # Block shell (frees CPU1)
        self.g.move(
            "block",
            self.prog.entity_id("shell"),
            self.prog.container_id("BLOCKED"),
            cause='io_request'
        )
        self.g.run()

        # init (only ready process) gets CPU1
        assert self.prog.where_is("daemon") == "CPU0"
        assert self.prog.where_is("shell") == "BLOCKED"
        assert self.prog.where_is("init") == "CPU1"

    def test_properties_readable(self):
        """Entity properties are accessible through the program."""
        self.g.run()

        assert self.prog.get_property("daemon", "priority") == 10
        assert self.prog.get_property("shell", "priority") == 5
        assert self.prog.get_property("init", "priority") == 1

    def test_validation_clean(self):
        """Priority scheduler validates cleanly."""
        errors = validate_program(PRIORITY_SCHEDULER)
        assert errors == []


# =============================================================================
# ECONOMY DEMO
# =============================================================================

class TestEconomy:
    """Test the gold economy demo — conservation and quantity transfers."""

    def setup_method(self):
        self.prog = HerbProgram(ECONOMY)
        self.g = self.prog.load()
        # Total gold: 500 + 300 + 5 + 195 = 1000
        self.total_gold = 1000

    def _total_gold(self):
        return sum(
            self.prog.get_property(name, "gold") or 0
            for name in ["alice", "bob", "charlie", "treasury"]
        )

    def test_initial_state(self):
        """All entities start with correct gold amounts."""
        assert self.prog.get_property("alice", "gold") == 500
        assert self.prog.get_property("bob", "gold") == 300
        assert self.prog.get_property("charlie", "gold") == 5
        assert self.prog.get_property("treasury", "gold") == 195
        assert self._total_gold() == self.total_gold

    def test_tax_collection(self):
        """Tax event collects from players who can afford it."""
        self.prog.create_entity("tax1", "TaxEvent", "TAX_PENDING")
        self.g.run()

        # alice (500) and bob (300) can afford 10 tax
        # charlie (5) cannot afford 10 tax
        # treasury gets +20 from alice and bob
        assert self.prog.get_property("alice", "gold") == 490
        assert self.prog.get_property("bob", "gold") == 290
        assert self.prog.get_property("charlie", "gold") == 5
        assert self.prog.get_property("treasury", "gold") == 215
        assert self._total_gold() == self.total_gold

    def test_tax_conservation(self):
        """Gold is conserved through tax collection."""
        for i in range(5):
            self.prog.create_entity(f"tax_{i}", "TaxEvent", "TAX_PENDING")
            self.g.run()

        assert self._total_gold() == self.total_gold

    def test_charlie_skipped_by_where(self):
        """Charlie (gold=5) is filtered by the where clause."""
        self.prog.create_entity("tax1", "TaxEvent", "TAX_PENDING")
        self.g.run()

        # Charlie's gold unchanged — where clause filtered him out
        assert self.prog.get_property("charlie", "gold") == 5

    def test_reward_distribution(self):
        """Reward goes to richest player (max_by gold)."""
        self.prog.create_entity("bonus", "Reward", "REWARD_PENDING",
                                {"amount": 50})
        self.g.run()

        # Alice (500) is richest, gets the reward from treasury
        assert self.prog.get_property("alice", "gold") == 550
        assert self.prog.get_property("treasury", "gold") == 145
        assert self._total_gold() == self.total_gold

    def test_reward_treasury_insufficient(self):
        """Reward blocked when treasury can't cover it."""
        # Drain treasury first
        self.prog.create_entity("big_reward", "Reward", "REWARD_PENDING",
                                {"amount": 1000})
        self.g.run()

        # Treasury only has 195 — can't cover 1000
        # Guard blocks the tension
        assert self.prog.where_is("big_reward") == "REWARD_PENDING"
        assert self._total_gold() == self.total_gold

    def test_tax_then_reward(self):
        """Tax collection then reward distribution."""
        # Tax first
        self.prog.create_entity("tax1", "TaxEvent", "TAX_PENDING")
        self.g.run()

        # Treasury now has 215
        assert self.prog.get_property("treasury", "gold") == 215

        # Reward to richest
        self.prog.create_entity("bonus1", "Reward", "REWARD_PENDING",
                                {"amount": 100})
        self.g.run()

        # Alice (490 after tax) is richest, gets 100
        assert self.prog.get_property("alice", "gold") == 590
        assert self.prog.get_property("treasury", "gold") == 115
        assert self._total_gold() == self.total_gold

    def test_validation_clean(self):
        """Economy program validates cleanly."""
        errors = validate_program(ECONOMY)
        assert errors == []


# =============================================================================
# BACKWARD COMPATIBILITY
# =============================================================================

class TestBackwardCompat:
    """Ensure all original programs still work unchanged."""

    def test_fifo_scheduler_unchanged(self):
        """Original FIFO scheduler produces same results."""
        prog = HerbProgram(SCHEDULER)
        g = prog.load()
        g.run()

        assert prog.where_is("init") == "CPU0"
        assert prog.where_is("shell") == "CPU1"
        assert prog.where_is("daemon") == "READY_QUEUE"

    def test_dom_layout_unchanged(self):
        """DOM layout pipeline produces same results."""
        prog = HerbProgram(DOM_LAYOUT)
        g = prog.load()
        ops = g.run()

        assert ops == 12
        assert prog.where_is("header") == "CLEAN"
        assert prog.where_is("content") == "CLEAN"
        assert prog.where_is("footer") == "CLEAN"

    def test_scheduler_validation_unchanged(self):
        errors = validate_program(SCHEDULER)
        assert errors == []

    def test_dom_validation_unchanged(self):
        errors = validate_program(DOM_LAYOUT)
        assert errors == []


# =============================================================================
# VALIDATION FOR NEW FEATURES
# =============================================================================

class TestNewValidation:
    """Test validation catches errors in new feature usage."""

    def test_unknown_pool_in_transfer(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [],
            "pools": [],
            "transfers": [{"name": "send", "pool": "nonexistent"}],
        }
        errors = validate_program(spec)
        assert any("nonexistent" in e for e in errors)

    def test_unknown_transfer_in_emit(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "pools": [],
            "transfers": [],
            "tensions": [{
                "name": "bad",
                "match": [{"bind": "x", "in": "C"}],
                "emit": [{"transfer": "ghost", "from": "x", "to": "x",
                           "amount": 10}],
            }],
        }
        errors = validate_program(spec)
        assert any("ghost" in e for e in errors)

    def test_unknown_type_in_create_emit(self):
        spec = {
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "tensions": [{
                "name": "bad",
                "match": [{"bind": "x", "in": "C"}],
                "emit": [{"create": "Ghost", "in": "C"}],
            }],
        }
        errors = validate_program(spec)
        assert any("Ghost" in e for e in errors)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
