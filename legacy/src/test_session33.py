"""
Session 33 Tests: Program Composition

Tests for the module system — namespace isolation, export/import resolution,
entity type extensions, dependency ordering, circular detection, and the
acid test: decomposed programs produce identical behavior to monoliths.
"""

import pytest
from herb_compose import (
    compose, compose_and_load, validate_module, _topological_sort
)
from herb_program import HerbProgram, validate_program
from herb_multiprocess import MULTI_PROCESS_OS
from herb_multiprocess_modules import (
    SCHEDULER_MODULE, FD_MANAGER_MODULE, COMPOSED_MULTIPROCESS
)
from herb_kernel import (
    PROC_MODULE, MEM_MODULE, FS_MODULE, IPC_MODULE, KERNEL
)


# =============================================================================
# PART 1: Topological Sort + Cycle Detection
# =============================================================================

class TestTopologicalSort:

    def test_no_deps(self):
        order = _topological_sort({"a": set(), "b": set(), "c": set()})
        assert order == ["a", "b", "c"]

    def test_linear_deps(self):
        order = _topological_sort({"c": {"b"}, "b": {"a"}, "a": set()})
        assert order == ["a", "b", "c"]

    def test_diamond_deps(self):
        order = _topological_sort({
            "d": {"b", "c"}, "b": {"a"}, "c": {"a"}, "a": set()
        })
        assert order[0] == "a"
        assert order[-1] == "d"

    def test_cycle_detected(self):
        with pytest.raises(ValueError, match="Circular"):
            _topological_sort({"a": {"b"}, "b": {"a"}})

    def test_three_way_cycle(self):
        with pytest.raises(ValueError, match="Circular"):
            _topological_sort({"a": {"c"}, "b": {"a"}, "c": {"b"}})

    def test_single_node(self):
        order = _topological_sort({"x": set()})
        assert order == ["x"]


# =============================================================================
# PART 2: Module Validation
# =============================================================================

class TestModuleValidation:

    def test_valid_module(self):
        errs = validate_module({
            "module": "test",
            "exports": ["Thing", "HOME"],
            "entity_types": [{"name": "Thing"}],
            "containers": [{"name": "HOME"}],
        })
        assert errs == []

    def test_missing_module_name(self):
        errs = validate_module({})
        assert any("Missing" in e for e in errs)

    def test_export_not_defined(self):
        errs = validate_module({
            "module": "test",
            "exports": ["GHOST"],
            "entity_types": [],
        })
        assert any("GHOST" in e for e in errs)

    def test_export_scoped_container_ok(self):
        """Scoped container names can be exported."""
        errs = validate_module({
            "module": "test",
            "exports": ["FD_FREE"],
            "entity_types": [{"name": "Process", "scoped_containers": [
                {"name": "FD_FREE", "kind": "simple"},
            ]}],
        })
        assert errs == []

    def test_export_from_extension_ok(self):
        errs = validate_module({
            "module": "test",
            "exports": ["FD_FREE"],
            "imports": ["other.Process"],
            "entity_type_extensions": [
                {"extend": "Process", "add_scoped_containers": [
                    {"name": "FD_FREE", "kind": "simple"},
                ]},
            ],
        })
        assert errs == []

    def test_import_must_be_qualified(self):
        errs = validate_module({
            "module": "test",
            "imports": ["unqualified"],
        })
        assert any("qualified" in e for e in errs)

    def test_duplicate_import_alias(self):
        errs = validate_module({
            "module": "test",
            "imports": ["a.Thing", "b.Thing"],
        })
        assert any("ambiguous" in e.lower() for e in errs)

    def test_import_collides_with_local(self):
        errs = validate_module({
            "module": "test",
            "imports": ["other.Thing"],
            "entity_types": [{"name": "Thing"}],
        })
        assert any("collides" in e for e in errs)

    def test_no_exports_no_imports_ok(self):
        errs = validate_module({
            "module": "test",
            "entity_types": [{"name": "X"}],
        })
        assert errs == []


# =============================================================================
# PART 3: Basic Composition
# =============================================================================

class TestBasicComposition:

    def test_single_module(self):
        """One module composes to itself with prefixed names."""
        mod = {
            "module": "alpha",
            "exports": ["Thing", "HOME"],
            "entity_types": [{"name": "Thing"}],
            "containers": [{"name": "HOME", "entity_type": "Thing"}],
            "moves": [],
            "tensions": [],
        }
        flat = compose({
            "modules": [mod],
            "entities": [{"name": "x", "type": "alpha.Thing",
                          "in": "alpha.HOME"}],
        })
        assert any(et["name"] == "alpha.Thing"
                    for et in flat["entity_types"])
        assert any(c["name"] == "alpha.HOME"
                    for c in flat["containers"])
        assert flat["containers"][0]["entity_type"] == "alpha.Thing"

    def test_single_module_loads(self):
        mod = {
            "module": "m",
            "exports": ["T", "C"],
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "C", "entity_type": "T"}],
            "moves": [],
            "tensions": [],
        }
        prog = compose_and_load({
            "modules": [mod],
            "entities": [{"name": "e", "type": "m.T", "in": "m.C"}],
        })
        assert prog.where_is("e") == "m.C"

    def test_two_modules_no_imports(self):
        mod_a = {
            "module": "a", "exports": ["X"],
            "entity_types": [{"name": "X"}],
            "containers": [{"name": "BOX", "entity_type": "X"}],
            "moves": [], "tensions": [],
        }
        mod_b = {
            "module": "b", "exports": ["Y"],
            "entity_types": [{"name": "Y"}],
            "containers": [{"name": "BOX", "entity_type": "Y"}],
            "moves": [], "tensions": [],
        }
        flat = compose({"modules": [mod_a, mod_b], "entities": []})
        container_names = [c["name"] for c in flat["containers"]]
        assert "a.BOX" in container_names
        assert "b.BOX" in container_names

    def test_namespace_isolation(self):
        """Same container name in two modules become different containers."""
        mod_a = {
            "module": "a", "exports": ["T"],
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "Q", "entity_type": "T"}],
            "moves": [], "tensions": [],
        }
        mod_b = {
            "module": "b", "exports": ["T"],
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "Q", "entity_type": "T"}],
            "moves": [], "tensions": [],
        }
        prog = compose_and_load({
            "modules": [mod_a, mod_b],
            "entities": [
                {"name": "x", "type": "a.T", "in": "a.Q"},
                {"name": "y", "type": "b.T", "in": "b.Q"},
            ],
        })
        assert prog.where_is("x") == "a.Q"
        assert prog.where_is("y") == "b.Q"

    def test_duplicate_module_name_rejected(self):
        mod = {"module": "dup", "entity_types": [], "containers": [],
               "moves": [], "tensions": []}
        with pytest.raises(ValueError, match="Duplicate"):
            compose({"modules": [mod, mod], "entities": []})

    def test_missing_module_in_compose(self):
        with pytest.raises(ValueError, match="not in modules"):
            compose({
                "compose": ["ghost"],
                "modules": [{"module": "real", "entity_types": [],
                             "containers": [], "moves": [],
                             "tensions": []}],
                "entities": [],
            })


# =============================================================================
# PART 4: Import/Export Resolution
# =============================================================================

class TestImportExport:

    def test_import_resolves_to_export(self):
        """Imported entity type resolves to exporter's qualified name."""
        mod_a = {
            "module": "a", "exports": ["T"],
            "entity_types": [{"name": "T"}],
            "containers": [], "moves": [], "tensions": [],
        }
        mod_b = {
            "module": "b", "exports": [],
            "imports": ["a.T"],
            "entity_types": [],
            "containers": [{"name": "BOX", "entity_type": "T"}],
            "moves": [], "tensions": [],
        }
        flat = compose({"modules": [mod_a, mod_b], "entities": []})
        b_box = next(c for c in flat["containers"]
                     if c["name"] == "b.BOX")
        assert b_box["entity_type"] == "a.T"

    def test_import_not_exported_rejected(self):
        mod_a = {
            "module": "a", "exports": [],
            "entity_types": [{"name": "Secret"}],
            "containers": [], "moves": [], "tensions": [],
        }
        mod_b = {
            "module": "b", "imports": ["a.Secret"],
            "entity_types": [], "containers": [],
            "moves": [], "tensions": [],
        }
        with pytest.raises(ValueError, match="not exported"):
            compose({"modules": [mod_a, mod_b], "entities": []})

    def test_import_from_missing_module_rejected(self):
        mod = {
            "module": "lonely", "imports": ["ghost.Thing"],
            "entity_types": [], "containers": [],
            "moves": [], "tensions": [],
        }
        with pytest.raises(ValueError, match="not in composition"):
            compose({"modules": [mod], "entities": []})

    def test_circular_import_rejected(self):
        mod_a = {
            "module": "a", "exports": ["X"],
            "imports": ["b.Y"],
            "entity_types": [{"name": "X"}],
            "containers": [], "moves": [], "tensions": [],
        }
        mod_b = {
            "module": "b", "exports": ["Y"],
            "imports": ["a.X"],
            "entity_types": [{"name": "Y"}],
            "containers": [], "moves": [], "tensions": [],
        }
        with pytest.raises(ValueError, match="Circular"):
            compose({"modules": [mod_a, mod_b], "entities": []})


# =============================================================================
# PART 5: Entity Type Extensions
# =============================================================================

class TestEntityTypeExtensions:

    def test_extension_adds_scoped_containers(self):
        mod_a = {
            "module": "a", "exports": ["P"],
            "entity_types": [{"name": "P"}],
            "containers": [], "moves": [], "tensions": [],
        }
        mod_b = {
            "module": "b", "imports": ["a.P"],
            "entity_types": [{"name": "FD"}],
            "entity_type_extensions": [
                {"extend": "P", "add_scoped_containers": [
                    {"name": "FD_FREE", "kind": "simple",
                     "entity_type": "FD"},
                ]},
            ],
            "containers": [], "moves": [], "tensions": [],
        }
        prog = compose_and_load({
            "modules": [mod_a, mod_b],
            "entities": [
                {"name": "p1", "type": "a.P", "in": None},
            ],
        })
        # Entity should have scoped container FD_FREE
        eid = prog.entity_id("p1")
        cid = prog.graph.get_scoped_container(eid, "FD_FREE")
        assert cid is not None

    def test_extension_type_resolves(self):
        """Entity type in extension's scoped container resolves correctly."""
        mod_a = {
            "module": "a", "exports": ["P"],
            "entity_types": [{"name": "P"}],
            "containers": [], "moves": [], "tensions": [],
        }
        mod_b = {
            "module": "b", "imports": ["a.P"],
            "entity_types": [{"name": "FD"}],
            "entity_type_extensions": [
                {"extend": "P", "add_scoped_containers": [
                    {"name": "TABLE", "kind": "simple",
                     "entity_type": "FD"},
                ]},
            ],
            "containers": [], "moves": [], "tensions": [],
        }
        flat = compose({"modules": [mod_a, mod_b], "entities": []})
        p_type = next(et for et in flat["entity_types"]
                      if et["name"] == "a.P")
        sc = p_type["scoped_containers"][0]
        assert sc["entity_type"] == "b.FD"

    def test_duplicate_scope_name_rejected(self):
        mod_a = {
            "module": "a", "exports": ["P"],
            "entity_types": [{"name": "P", "scoped_containers": [
                {"name": "TABLE", "kind": "simple"},
            ]}],
            "containers": [], "moves": [], "tensions": [],
        }
        mod_b = {
            "module": "b", "imports": ["a.P"],
            "entity_type_extensions": [
                {"extend": "P", "add_scoped_containers": [
                    {"name": "TABLE", "kind": "simple"},
                ]},
            ],
            "entity_types": [], "containers": [],
            "moves": [], "tensions": [],
        }
        with pytest.raises(ValueError, match="already exists"):
            compose({"modules": [mod_a, mod_b], "entities": []})

    def test_extend_nonexistent_type_rejected(self):
        mod = {
            "module": "x", "imports": [],
            "entity_type_extensions": [
                {"extend": "Ghost", "add_scoped_containers": []},
            ],
            "entity_types": [], "containers": [],
            "moves": [], "tensions": [],
        }
        with pytest.raises(ValueError, match="doesn't exist"):
            compose({"modules": [mod], "entities": []})

    def test_multiple_extensions_on_same_type(self):
        """Two modules can extend the same type with different scoped containers."""
        mod_a = {
            "module": "a", "exports": ["P"],
            "entity_types": [{"name": "P"}],
            "containers": [], "moves": [], "tensions": [],
        }
        mod_b = {
            "module": "b", "imports": ["a.P"],
            "entity_types": [{"name": "FD"}],
            "entity_type_extensions": [
                {"extend": "P", "add_scoped_containers": [
                    {"name": "FD_TABLE", "kind": "simple",
                     "entity_type": "FD"},
                ]},
            ],
            "containers": [], "moves": [], "tensions": [],
        }
        mod_c = {
            "module": "c", "imports": ["a.P"],
            "entity_types": [{"name": "Page"}],
            "entity_type_extensions": [
                {"extend": "P", "add_scoped_containers": [
                    {"name": "MEM_TABLE", "kind": "simple",
                     "entity_type": "Page"},
                ]},
            ],
            "containers": [], "moves": [], "tensions": [],
        }
        prog = compose_and_load({
            "modules": [mod_a, mod_b, mod_c],
            "entities": [{"name": "p1", "type": "a.P", "in": None}],
        })
        eid = prog.entity_id("p1")
        assert prog.graph.get_scoped_container(eid, "FD_TABLE") is not None
        assert prog.graph.get_scoped_container(eid, "MEM_TABLE") is not None


# =============================================================================
# PART 6: Tension Name Resolution
# =============================================================================

class TestTensionResolution:

    def _make_scheduler(self):
        return {
            "module": "sched",
            "exports": ["Process", "READY", "CPU0", "schedule"],
            "entity_types": [{"name": "Process"}],
            "containers": [
                {"name": "READY", "entity_type": "Process"},
                {"name": "CPU0", "kind": "slot",
                 "entity_type": "Process"},
            ],
            "moves": [
                {"name": "schedule", "from": ["READY"], "to": ["CPU0"],
                 "entity_type": "Process"},
            ],
            "tensions": [
                {"name": "auto_sched", "priority": 10,
                 "match": [
                     {"bind": "p", "in": "READY"},
                     {"bind": "c", "empty_in": ["CPU0"]},
                 ],
                 "emit": [
                     {"move": "schedule", "entity": "p", "to": "c"},
                 ]},
            ],
        }

    def test_tension_containers_resolved(self):
        """Tension match container refs get prefixed."""
        flat = compose({
            "modules": [self._make_scheduler()],
            "entities": [],
        })
        t = flat["tensions"][0]
        assert t["match"][0]["in"] == "sched.READY"
        assert t["match"][1]["empty_in"] == ["sched.CPU0"]

    def test_tension_move_resolved(self):
        flat = compose({
            "modules": [self._make_scheduler()],
            "entities": [],
        })
        t = flat["tensions"][0]
        assert t["emit"][0]["move"] == "sched.schedule"

    def test_tension_binding_not_resolved(self):
        """Binding names must NOT be prefixed."""
        flat = compose({
            "modules": [self._make_scheduler()],
            "entities": [],
        })
        t = flat["tensions"][0]
        assert t["emit"][0]["entity"] == "p"
        assert t["emit"][0]["to"] == "c"

    def test_imported_container_in_tension(self):
        """Tension referencing imported container resolves to source module."""
        mod_b = {
            "module": "ext",
            "imports": ["sched.CPU0", "sched.Process"],
            "entity_types": [],
            "containers": [],
            "moves": [],
            "tensions": [
                {"name": "check_cpu", "priority": 1,
                 "match": [
                     {"bind": "p", "in": "CPU0"},
                 ],
                 "emit": []},
            ],
        }
        flat = compose({
            "modules": [self._make_scheduler(), mod_b],
            "entities": [],
        })
        ext_t = next(t for t in flat["tensions"]
                     if t["name"] == "ext.check_cpu")
        assert ext_t["match"][0]["in"] == "sched.CPU0"

    def test_scoped_ref_not_prefixed(self):
        """Scoped container names in tension refs must NOT be prefixed."""
        mod = {
            "module": "m",
            "entity_types": [{"name": "P", "scoped_containers": [
                {"name": "BOX", "kind": "simple"},
            ]}],
            "containers": [{"name": "Q"}],
            "moves": [],
            "tensions": [
                {"name": "t1", "priority": 1,
                 "match": [
                     {"bind": "p", "in": "Q"},
                     {"bind": "x", "in": {"scope": "p",
                                           "container": "BOX"}},
                 ],
                 "emit": []},
            ],
        }
        flat = compose({"modules": [mod], "entities": []})
        t = flat["tensions"][0]
        assert t["match"][1]["in"]["container"] == "BOX"

    def test_expression_resolution(self):
        """Expression container refs are resolved, prop refs are not."""
        mod = {
            "module": "m",
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "Q"}],
            "moves": [],
            "tensions": [
                {"name": "t1", "priority": 1,
                 "match": [
                     {"bind": "x", "in": "Q",
                      "where": {"op": ">",
                                "left": {"prop": "val", "of": "x"},
                                "right": 0}},
                 ],
                 "emit": []},
            ],
        }
        flat = compose({"modules": [mod], "entities": []})
        t = flat["tensions"][0]
        w = t["match"][0]["where"]
        assert w["left"]["of"] == "x"  # binding, not prefixed

    def test_count_expression_resolved(self):
        mod = {
            "module": "m",
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "Q"}],
            "moves": [],
            "tensions": [
                {"name": "t1", "priority": 1,
                 "match": [
                     {"guard": {"op": ">",
                                "left": {"count": "Q"},
                                "right": 0}},
                 ],
                 "emit": []},
            ],
        }
        flat = compose({"modules": [mod], "entities": []})
        t = flat["tensions"][0]
        assert t["match"][0]["guard"]["left"]["count"] == "m.Q"

    def test_set_emit_resolved(self):
        mod = {
            "module": "m",
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "Q"}],
            "moves": [],
            "tensions": [
                {"name": "t1", "priority": 1,
                 "match": [{"bind": "x", "in": "Q"}],
                 "emit": [{"set": "x", "property": "val",
                           "value": {"op": "+",
                                     "left": {"prop": "val", "of": "x"},
                                     "right": 1}}]},
            ],
        }
        flat = compose({"modules": [mod], "entities": []})
        t = flat["tensions"][0]
        assert t["emit"][0]["set"] == "x"  # binding, not prefixed


# =============================================================================
# PART 7: Composed Programs Run Correctly
# =============================================================================

class TestComposedExecution:

    def test_scheduling_works(self):
        """Basic scheduling tension fires in composed program."""
        mod = {
            "module": "s",
            "exports": ["P", "R", "C", "go"],
            "entity_types": [{"name": "P"}],
            "containers": [
                {"name": "R", "entity_type": "P"},
                {"name": "C", "kind": "slot", "entity_type": "P"},
            ],
            "moves": [
                {"name": "go", "from": ["R"], "to": ["C"],
                 "entity_type": "P"},
            ],
            "tensions": [
                {"name": "auto", "priority": 10,
                 "match": [
                     {"bind": "p", "in": "R"},
                     {"bind": "c", "empty_in": ["C"]},
                 ],
                 "emit": [
                     {"move": "go", "entity": "p", "to": "c"},
                 ]},
            ],
        }
        prog = compose_and_load({
            "modules": [mod],
            "entities": [{"name": "x", "type": "s.P", "in": "s.R"}],
        })
        ops = prog.graph.run()
        assert ops == 1
        assert prog.where_is("x") == "s.C"

    def test_scoped_moves_in_composed(self):
        """Scoped moves work in composed programs."""
        mod_a = {
            "module": "a",
            "exports": ["P", "Q"],
            "entity_types": [{"name": "P", "scoped_containers": [
                {"name": "FREE", "kind": "simple", "entity_type": "I"},
                {"name": "USED", "kind": "simple", "entity_type": "I"},
            ]}],
            "containers": [{"name": "Q", "entity_type": "P"}],
            "moves": [
                {"name": "use", "scoped_from": ["FREE"],
                 "scoped_to": ["USED"], "entity_type": "I"},
            ],
            "tensions": [],
        }
        # Need to define entity type I
        mod_a["entity_types"].append({"name": "I"})
        prog = compose_and_load({
            "modules": [mod_a],
            "entities": [
                {"name": "p1", "type": "a.P", "in": "a.Q"},
                {"name": "i1", "type": "a.I",
                 "in": {"scope": "p1", "container": "FREE"}},
            ],
        })
        i1 = prog.entity_id("i1")
        p1 = prog.entity_id("p1")
        used_cid = prog.graph.get_scoped_container(p1, "USED")
        result = prog.graph.move("a.use", i1, used_cid)
        assert result is not None

    def test_cross_module_tension(self):
        """Tension in one module references containers from another."""
        mod_a = {
            "module": "core",
            "exports": ["T", "SRC", "DST", "go"],
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "SRC", "entity_type": "T"},
                {"name": "DST", "entity_type": "T"},
            ],
            "moves": [
                {"name": "go", "from": ["SRC"], "to": ["DST"],
                 "entity_type": "T"},
            ],
            "tensions": [],
        }
        mod_b = {
            "module": "driver",
            "imports": ["core.T", "core.SRC", "core.DST", "core.go"],
            "entity_types": [],
            "containers": [],
            "moves": [],
            "tensions": [
                {"name": "push", "priority": 10,
                 "match": [{"bind": "x", "in": "SRC"}],
                 "emit": [{"move": "go", "entity": "x", "to": "DST"}]},
            ],
        }
        prog = compose_and_load({
            "modules": [mod_a, mod_b],
            "entities": [
                {"name": "item", "type": "core.T", "in": "core.SRC"},
            ],
        })
        ops = prog.graph.run()
        assert ops == 1
        assert prog.where_is("item") == "core.DST"

    def test_property_mutation_in_composed(self):
        """Set emit works with qualified names."""
        mod = {
            "module": "m",
            "entity_types": [{"name": "T"}],
            "containers": [{"name": "Q"}],
            "moves": [],
            "tensions": [
                {"name": "inc", "priority": 1,
                 "match": [
                     {"bind": "x", "in": "Q",
                      "where": {"op": "<",
                                "left": {"prop": "count", "of": "x"},
                                "right": 3}},
                 ],
                 "emit": [
                     {"set": "x", "property": "count",
                      "value": {"op": "+",
                                "left": {"prop": "count", "of": "x"},
                                "right": 1}},
                 ]},
            ],
        }
        prog = compose_and_load({
            "modules": [mod],
            "entities": [
                {"name": "e", "type": "m.T", "in": "m.Q",
                 "properties": {"count": 0}},
            ],
        })
        prog.graph.run()
        assert prog.get_property("e", "count") == 3


# =============================================================================
# PART 8: Acid Test — Decomposition is Lossless
# =============================================================================

class TestDecompositionLossless:
    """
    The monolithic herb_multiprocess.py and the composed
    herb_multiprocess_modules.py must produce identical behavior
    under the same sequence of signals.
    """

    def _load_both(self):
        mono = HerbProgram(MULTI_PROCESS_OS)
        mono_g = mono.load()
        comp = compose_and_load(COMPOSED_MULTIPROCESS)
        comp_g = comp.graph
        return mono, mono_g, comp, comp_g

    def _strip(self, name):
        if name is None:
            return None
        return (name.replace("scheduler.", "")
                    .replace("fd_manager.", ""))

    def _compare(self, mono, comp, names):
        for n in names:
            m = mono.where_is(n)
            c = self._strip(comp.where_is(n))
            assert m == c, f"{n}: mono={m} vs comp={c}"

    def test_initial_state_matches(self):
        mono, _, comp, _ = self._load_both()
        self._compare(mono, comp,
                      ["proc_A", "proc_B", "fd0_A", "fd1_A",
                       "fd2_A", "fd0_B", "fd1_B"])

    def test_scheduling_matches(self):
        mono, mono_g, comp, comp_g = self._load_both()
        mono_g.run()
        comp_g.run()
        self._compare(mono, comp, ["proc_A", "proc_B"])

    def test_tick_matches(self):
        mono, mono_g, comp, comp_g = self._load_both()
        mono_g.run()
        comp_g.run()

        mono.create_entity("t1", "Signal", "TICK_SIGNAL")
        comp.create_entity("t1", "scheduler.Signal",
                           "scheduler.TICK_SIGNAL")
        mono_g.run()
        comp_g.run()

        assert (mono.get_property("proc_A", "time_slice") ==
                comp.get_property("proc_A", "time_slice"))

    def test_fd_open_matches(self):
        mono, mono_g, comp, comp_g = self._load_both()
        mono_g.run()
        comp_g.run()

        mono.create_entity("o1", "Signal", "OPEN_REQUEST")
        comp.create_entity("o1", "scheduler.Signal",
                           "scheduler.OPEN_REQUEST")
        mono_g.run()
        comp_g.run()

        m_loc = mono.where_is("fd0_A")
        c_loc = self._strip(comp.where_is("fd0_A"))
        assert m_loc == c_loc
        assert "FD_OPEN" in m_loc

    def test_fd_close_matches(self):
        mono, mono_g, comp, comp_g = self._load_both()
        mono_g.run()
        comp_g.run()

        # Open then close
        mono.create_entity("o1", "Signal", "OPEN_REQUEST")
        comp.create_entity("o1", "scheduler.Signal",
                           "scheduler.OPEN_REQUEST")
        mono_g.run()
        comp_g.run()

        mono.create_entity("c1", "Signal", "CLOSE_REQUEST")
        comp.create_entity("c1", "scheduler.Signal",
                           "scheduler.CLOSE_REQUEST")
        mono_g.run()
        comp_g.run()

        m_loc = mono.where_is("fd0_A")
        c_loc = self._strip(comp.where_is("fd0_A"))
        assert m_loc == c_loc
        assert "FD_FREE" in m_loc

    def test_preemption_matches(self):
        mono, mono_g, comp, comp_g = self._load_both()
        mono_g.run()
        comp_g.run()

        # Send enough ticks to trigger preemption
        for i in range(5):
            mono.create_entity(f"t{i}", "Signal", "TICK_SIGNAL")
            comp.create_entity(f"t{i}", "scheduler.Signal",
                               "scheduler.TICK_SIGNAL")
            mono_g.run()
            comp_g.run()

        self._compare(mono, comp, ["proc_A", "proc_B"])
        assert (mono.get_property("proc_A", "time_slice") ==
                comp.get_property("proc_A", "time_slice"))


# =============================================================================
# PART 9: Module Independence
# =============================================================================

class TestModuleIndependence:

    def test_scheduler_module_runs_standalone(self):
        """Scheduler module can be loaded independently."""
        prog = HerbProgram(SCHEDULER_MODULE)
        g = prog.load()
        prog.create_entity(
            "p1", "Process", "READY_QUEUE",
            {"priority": 5, "time_slice": 3}
        )
        ops = g.run()
        assert ops == 1
        assert prog.where_is("p1") == "CPU0"

    def test_proc_module_runs_standalone(self):
        """Proc module from kernel can run alone."""
        prog = HerbProgram(PROC_MODULE)
        g = prog.load()
        prog.create_entity(
            "p1", "Process", "READY",
            {"priority": 5, "time_slice": 3}
        )
        ops = g.run()
        assert ops == 1
        assert prog.where_is("p1") == "CPU0"


# =============================================================================
# PART 10: Four-Module Kernel Tests
# =============================================================================

class TestFourModuleKernel:

    def _load_kernel(self):
        return compose_and_load(KERNEL)

    def test_kernel_loads(self):
        prog = self._load_kernel()
        assert prog.graph is not None

    def test_kernel_initial_state(self):
        prog = self._load_kernel()
        assert prog.where_is("server") == "proc.READY"
        assert prog.where_is("client") == "proc.READY"

    def test_kernel_scheduling(self):
        prog = self._load_kernel()
        prog.graph.run()
        # Server has higher priority, gets CPU
        assert prog.where_is("server") == "proc.CPU0"
        assert prog.where_is("client") == "proc.READY"

    def test_kernel_mem_alloc(self):
        prog = self._load_kernel()
        g = prog.graph
        g.run()  # Schedule server

        prog.create_entity("a1", "proc.Signal", "proc.ALLOC_SIG")
        g.run()

        server_id = prog.entity_id("server")
        mem_used = g.get_scoped_container(server_id, "MEM_USED")
        assert g.containers[mem_used].count == 1

    def test_kernel_fd_open(self):
        prog = self._load_kernel()
        g = prog.graph
        g.run()

        prog.create_entity("o1", "proc.Signal", "proc.OPEN_SIG")
        g.run()

        server_id = prog.entity_id("server")
        fd_open = g.get_scoped_container(server_id, "FD_OPEN")
        assert g.containers[fd_open].count == 1

    def test_kernel_ipc_send(self):
        prog = self._load_kernel()
        g = prog.graph
        g.run()

        prog.create_entity("s1", "proc.Signal", "proc.SEND_SIG")
        g.run()

        # msg1 should be in channel buffer
        ch = g.channels.get("msg_pipe")
        assert ch is not None
        buf = ch["buffer_container"]
        assert g.containers[buf].count == 1

    def test_kernel_ipc_full_flow(self):
        """Send -> context switch -> receive -> react."""
        prog = self._load_kernel()
        g = prog.graph
        g.run()  # Schedule server

        # Send message
        prog.create_entity("s1", "proc.Signal", "proc.SEND_SIG")
        g.run()

        # Block server, client gets CPU
        server_id = prog.entity_id("server")
        blocked = prog.container_id("proc.BLOCKED")
        g.move("proc.block_proc", server_id, blocked)
        g.run()
        assert prog.where_is("client") == "proc.CPU0"

        # Receive message
        prog.create_entity("r1", "proc.Signal", "proc.RECV_SIG")
        g.run()

        assert prog.get_property("client", "msgs_received") == 1

    def test_kernel_cross_module_isolation(self):
        """Server's resources don't leak to client."""
        prog = self._load_kernel()
        g = prog.graph
        g.run()

        # Allocate memory and open FD on server
        prog.create_entity("a1", "proc.Signal", "proc.ALLOC_SIG")
        g.run()
        prog.create_entity("o1", "proc.Signal", "proc.OPEN_SIG")
        g.run()

        # Client's resources unchanged
        client_id = prog.entity_id("client")
        mem_used = g.get_scoped_container(client_id, "MEM_USED")
        fd_open = g.get_scoped_container(client_id, "FD_OPEN")
        assert g.containers[mem_used].count == 0
        assert g.containers[fd_open].count == 0

    def test_kernel_mem_free(self):
        prog = self._load_kernel()
        g = prog.graph
        g.run()

        # Alloc then free
        prog.create_entity("a1", "proc.Signal", "proc.ALLOC_SIG")
        g.run()
        prog.create_entity("f1", "proc.Signal", "proc.FREE_SIG")
        g.run()

        server_id = prog.entity_id("server")
        mem_used = g.get_scoped_container(server_id, "MEM_USED")
        assert g.containers[mem_used].count == 0

    def test_kernel_fd_close(self):
        prog = self._load_kernel()
        g = prog.graph
        g.run()

        prog.create_entity("o1", "proc.Signal", "proc.OPEN_SIG")
        g.run()
        prog.create_entity("c1", "proc.Signal", "proc.CLOSE_SIG")
        g.run()

        server_id = prog.entity_id("server")
        fd_open = g.get_scoped_container(server_id, "FD_OPEN")
        assert g.containers[fd_open].count == 0


# =============================================================================
# PART 11: Dimensions in Composition
# =============================================================================

class TestDimensionsInComposition:

    def test_dimension_prefixed(self):
        mod = {
            "module": "m",
            "dimensions": ["priority"],
            "entity_types": [{"name": "T"}],
            "containers": [
                {"name": "A", "entity_type": "T"},
                {"name": "B", "dimension": "priority",
                 "entity_type": "T"},
            ],
            "moves": [], "tensions": [],
        }
        flat = compose({"modules": [mod], "entities": []})
        assert flat["dimensions"] == ["m.priority"]
        b_container = next(c for c in flat["containers"]
                           if c["name"] == "m.B")
        assert b_container["dimension"] == "m.priority"


# =============================================================================
# PART 12: Composition-Level Channels
# =============================================================================

class TestCompositionChannels:

    def test_channel_name_not_prefixed_in_tension(self):
        """Channel names from composition level resolve correctly."""
        mod = {
            "module": "m",
            "entity_types": [{"name": "T"}, {"name": "Msg"}],
            "containers": [{"name": "Q", "entity_type": "T"}],
            "moves": [],
            "tensions": [
                {"name": "recv", "priority": 1,
                 "match": [
                     {"bind": "p", "in": "Q"},
                     {"bind": "msg", "in": {"channel": "pipe"}},
                 ],
                 "emit": [
                     {"receive": "pipe", "entity": "msg",
                      "to": {"scope": "p", "container": "BOX"}},
                 ]},
            ],
        }
        flat = compose({
            "modules": [mod],
            "channels": [{"name": "pipe", "from": "a", "to": "b",
                          "entity_type": "m.Msg"}],
            "entities": [],
        })
        t = flat["tensions"][0]
        # Channel name should NOT be prefixed
        assert t["match"][1]["in"]["channel"] == "pipe"
        assert t["emit"][0]["receive"] == "pipe"


# =============================================================================
# PART 13: Pools and Transfers in Composition
# =============================================================================

class TestPoolsInComposition:

    def test_pool_and_transfer_prefixed(self):
        mod = {
            "module": "econ",
            "entity_types": [{"name": "Player"}],
            "containers": [{"name": "WORLD", "entity_type": "Player"}],
            "pools": [{"name": "gold", "property": "gold"}],
            "transfers": [{"name": "pay", "pool": "gold",
                           "entity_type": "Player"}],
            "moves": [], "tensions": [],
        }
        flat = compose({"modules": [mod], "entities": []})
        assert flat["pools"][0]["name"] == "econ.gold"
        assert flat["transfers"][0]["name"] == "econ.pay"
        assert flat["transfers"][0]["pool"] == "econ.gold"
        assert flat["transfers"][0]["entity_type"] == "econ.Player"

    def test_transfer_works_in_composed(self):
        mod = {
            "module": "e",
            "entity_types": [{"name": "P"}],
            "containers": [{"name": "W", "entity_type": "P"}],
            "pools": [{"name": "g", "property": "gold"}],
            "transfers": [{"name": "pay", "pool": "g",
                           "entity_type": "P"}],
            "moves": [],
            "tensions": [
                {"name": "tax", "priority": 10,
                 "match": [
                     {"bind": "p", "in": "W",
                      "where": {"op": ">=",
                                "left": {"prop": "gold", "of": "p"},
                                "right": 10}},
                 ],
                 "emit": [
                     {"transfer": "pay", "from": "p",
                      "to": "bank", "amount": 10},
                 ]},
            ],
        }
        prog = compose_and_load({
            "modules": [mod],
            "entities": [
                {"name": "alice", "type": "e.P", "in": "e.W",
                 "properties": {"gold": 100}},
                {"name": "bank", "type": "e.P", "in": "e.W",
                 "properties": {"gold": 0}},
            ],
        })
        # run() resolves to fixpoint: tax fires until alice < 10
        # 100 -> 90 -> 80 -> ... -> 10 -> 0 (ten transfers)
        prog.graph.run()
        assert prog.get_property("alice", "gold") == 0
        assert prog.get_property("bank", "gold") == 100
