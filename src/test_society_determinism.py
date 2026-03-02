"""
Determinism gates for society-sim lane.

These tests are intentionally small and strict:
- same spec + same initial state must produce identical outcomes
- replay to fixpoint must be idempotent
"""

from herb_program import HerbProgram


SPEC = {
    "entity_types": [{"name": "Unit"}],
    "containers": [
        {"name": "A", "kind": "simple", "entity_type": "Unit"},
        {"name": "B", "kind": "simple", "entity_type": "Unit"},
        {"name": "C", "kind": "simple", "entity_type": "Unit"},
    ],
    "moves": [
        {"name": "ab", "from": ["A"], "to": ["B"], "entity_type": "Unit"},
        {"name": "bc", "from": ["B"], "to": ["C"], "entity_type": "Unit"},
    ],
    "tensions": [
        {
            "name": "move_a_to_b",
            "priority": 10,
            "match": [{"bind": "x", "in": "A"}],
            "emit": [{"move": "ab", "entity": "x", "to": "B"}],
        },
        {
            "name": "move_b_to_c",
            "priority": 5,
            "match": [{"bind": "y", "in": "B"}],
            "emit": [{"move": "bc", "entity": "y", "to": "C"}],
        },
    ],
    "entities": [
        {"name": "u1", "type": "Unit", "in": "A"},
        {"name": "u2", "type": "Unit", "in": "A"},
        {"name": "u3", "type": "Unit", "in": "A"},
    ],
}


def run_spec_once():
    program = HerbProgram(SPEC)
    graph = program.load()

    ops_1 = graph.run()
    ops_2 = graph.run()

    locations = {
        "u1": program.where_is("u1"),
        "u2": program.where_is("u2"),
        "u3": program.where_is("u3"),
    }
    return ops_1, ops_2, locations


def test_society_lane_is_replay_deterministic():
    a = run_spec_once()
    b = run_spec_once()
    assert a == b


def test_society_lane_reaches_fixpoint():
    ops_1, ops_2, locations = run_spec_once()
    assert ops_1 > 0
    assert ops_2 == 0
    assert locations == {"u1": "C", "u2": "C", "u3": "C"}

