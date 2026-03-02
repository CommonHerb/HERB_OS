"""
Session 34 Tests: Serialization + C Runtime

Tests:
  1. JSON round-trip for all 9 programs (serialize → deserialize → identical spec)
  2. Behavioral equivalence after round-trip (load JSON → run → same results)
  3. Validation on load (reject malformed programs)
  4. Composition round-trip (compose from JSON modules)
  5. Cross-runtime equivalence (Python vs C on same .herb.json)
"""

import os
import sys
import json
import unittest
import tempfile
import subprocess

sys.path.insert(0, os.path.dirname(__file__))

from herb_serialize import (
    serialize, deserialize, save, load,
    validate, detect_kind, spec_to_program,
    _check_serializable,
)
from herb_program import HerbProgram, validate_program
from herb_compose import compose, compose_and_load


# =============================================================================
# PROGRAM IMPORTS
# =============================================================================

from herb_scheduler import SCHEDULER
from herb_scheduler_priority import PRIORITY_SCHEDULER
from herb_dom import DOM_LAYOUT
from herb_economy import ECONOMY
from herb_multiprocess import MULTI_PROCESS_OS
from herb_ipc import IPC_DEMO
from herb_process_dimensions import PROGRAM as DIMENSIONS
from herb_multiprocess_modules import (
    COMPOSED_MULTIPROCESS, SCHEDULER_MODULE, FD_MANAGER_MODULE
)
from herb_kernel import KERNEL, PROC_MODULE, MEM_MODULE, FS_MODULE, IPC_MODULE

PROGRAMS_DIR = os.path.join(os.path.dirname(__file__), '..', 'programs')


# =============================================================================
# 1. JSON ROUND-TRIP TESTS
# =============================================================================

class TestJsonRoundTrip(unittest.TestCase):
    """Serialize → deserialize → spec is identical."""

    def _round_trip(self, spec, name):
        """Helper: serialize and deserialize, assert equal."""
        json_str = serialize(spec)
        recovered = deserialize(json_str)
        self.assertEqual(spec, recovered, f"{name}: round-trip mismatch")

    def test_scheduler_round_trip(self):
        self._round_trip(SCHEDULER, "scheduler")

    def test_priority_scheduler_round_trip(self):
        self._round_trip(PRIORITY_SCHEDULER, "priority_scheduler")

    def test_dom_layout_round_trip(self):
        self._round_trip(DOM_LAYOUT, "dom_layout")

    def test_economy_round_trip(self):
        self._round_trip(ECONOMY, "economy")

    def test_multiprocess_round_trip(self):
        self._round_trip(MULTI_PROCESS_OS, "multiprocess")

    def test_ipc_round_trip(self):
        self._round_trip(IPC_DEMO, "ipc")

    def test_dimensions_round_trip(self):
        self._round_trip(DIMENSIONS, "dimensions")

    def test_composed_multiprocess_round_trip(self):
        self._round_trip(COMPOSED_MULTIPROCESS, "composed_multiprocess")

    def test_kernel_round_trip(self):
        self._round_trip(KERNEL, "kernel")


# =============================================================================
# 2. FILE SAVE/LOAD TESTS
# =============================================================================

class TestFileSaveLoad(unittest.TestCase):
    """Save to file → load from file → spec is identical."""

    def _file_round_trip(self, spec, name):
        with tempfile.NamedTemporaryFile(
            mode='w', suffix='.herb.json', delete=False
        ) as f:
            path = f.name
        try:
            save(spec, path)
            recovered = load(path)
            self.assertEqual(spec, recovered, f"{name}: file round-trip mismatch")
        finally:
            os.unlink(path)

    def test_scheduler_file(self):
        self._file_round_trip(SCHEDULER, "scheduler")

    def test_kernel_file(self):
        self._file_round_trip(KERNEL, "kernel")

    def test_economy_file(self):
        self._file_round_trip(ECONOMY, "economy")

    def test_ipc_file(self):
        self._file_round_trip(IPC_DEMO, "ipc")

    def test_saved_programs_exist(self):
        """Verify all 9 .herb.json files exist in programs/."""
        expected = [
            'scheduler.herb.json',
            'priority_scheduler.herb.json',
            'dom_layout.herb.json',
            'economy.herb.json',
            'multiprocess.herb.json',
            'ipc.herb.json',
            'process_dimensions.herb.json',
            'multiprocess_modules.herb.json',
            'kernel.herb.json',
        ]
        for fname in expected:
            path = os.path.join(PROGRAMS_DIR, fname)
            self.assertTrue(
                os.path.exists(path),
                f"Missing program file: {fname}"
            )

    def test_load_saved_kernel(self):
        """Load kernel.herb.json from programs/ directory."""
        path = os.path.join(PROGRAMS_DIR, 'kernel.herb.json')
        if not os.path.exists(path):
            self.skipTest("kernel.herb.json not found")
        spec = load(path)
        self.assertIn("compose", spec)
        self.assertEqual(len(spec["modules"]), 4)

    def test_load_saved_priority_scheduler(self):
        """Load priority_scheduler.herb.json from programs/ directory."""
        path = os.path.join(PROGRAMS_DIR, 'priority_scheduler.herb.json')
        if not os.path.exists(path):
            self.skipTest("priority_scheduler.herb.json not found")
        spec = load(path)
        self.assertIn("entity_types", spec)
        self.assertIn("tensions", spec)


# =============================================================================
# 3. BEHAVIORAL EQUIVALENCE AFTER ROUND-TRIP
# =============================================================================

class TestBehavioralEquivalence(unittest.TestCase):
    """Programs loaded from JSON behave identically to Python dict versions."""

    def test_priority_scheduler_equivalence(self):
        """Priority scheduler: identical scheduling from JSON."""
        # Python dict
        prog_py = HerbProgram(PRIORITY_SCHEDULER)
        prog_py.load()
        g_py = prog_py.graph
        g_py.run()

        # JSON round-trip
        json_str = serialize(PRIORITY_SCHEDULER)
        spec = deserialize(json_str)
        prog_json = HerbProgram(spec)
        prog_json.load()
        g_json = prog_json.graph
        g_json.run()

        # Daemon (priority 10) should be on CPU0, shell (5) on CPU1
        for name in ['init', 'shell', 'daemon']:
            self.assertEqual(
                prog_py.where_is(name),
                prog_json.where_is(name),
                f"{name} location mismatch"
            )

    def test_priority_scheduler_with_signals(self):
        """Priority scheduler: identical behavior under signal sequence."""
        for source in ['python', 'json']:
            if source == 'python':
                prog = HerbProgram(PRIORITY_SCHEDULER)
            else:
                spec = deserialize(serialize(PRIORITY_SCHEDULER))
                prog = HerbProgram(spec)
            prog.load()
            g = prog.graph

            # Boot
            g.run()
            self.assertEqual(prog.where_is('daemon'), 'CPU0')
            self.assertEqual(prog.where_is('shell'), 'CPU1')

            # Timer preempt CPU0 — daemon goes to READY then re-schedules
            # (highest priority), init stays in READY
            prog.create_entity('t1', 'Signal', 'TIMER_EXPIRED')
            g.run()
            # After preempt + re-schedule, daemon is back on CPU0
            # (still highest priority in READY_QUEUE)
            self.assertEqual(prog.where_is('daemon'), 'CPU0',
                             f"{source}: daemon should be back on CPU0")

    def test_dom_layout_equivalence(self):
        """DOM layout pipeline: identical cascade from JSON."""
        for source in ['python', 'json']:
            if source == 'python':
                prog = HerbProgram(DOM_LAYOUT)
            else:
                spec = deserialize(serialize(DOM_LAYOUT))
                prog = HerbProgram(spec)
            prog.load()
            g = prog.graph

            # Full pipeline: NEEDS_LAYOUT → LAID_OUT → NEEDS_PAINT → PAINTED → CLEAN
            g.run()
            for name in ['header', 'content', 'footer']:
                self.assertEqual(
                    prog.where_is(name), 'CLEAN',
                    f"{source}: {name} should be CLEAN"
                )

    def test_economy_equivalence(self):
        """Economy: identical tax collection from JSON."""
        for source in ['python', 'json']:
            if source == 'python':
                prog = HerbProgram(ECONOMY)
            else:
                spec = deserialize(serialize(ECONOMY))
                prog = HerbProgram(spec)
            prog.load()
            g = prog.graph

            # Trigger tax
            prog.create_entity('tax1', 'TaxEvent', 'TAX_PENDING')
            g.run()

            # Alice (500) and Bob (300) should have paid 10 each
            alice_gold = prog.get_property('alice', 'gold')
            bob_gold = prog.get_property('bob', 'gold')
            charlie_gold = prog.get_property('charlie', 'gold')
            treasury_gold = prog.get_property('treasury', 'gold')

            self.assertEqual(alice_gold, 490, f"{source}: alice")
            self.assertEqual(bob_gold, 290, f"{source}: bob")
            self.assertEqual(charlie_gold, 5, f"{source}: charlie (can't afford)")
            self.assertEqual(treasury_gold, 215, f"{source}: treasury")

    def test_multiprocess_equivalence(self):
        """Multi-process OS: identical scoped operations from JSON."""
        for source in ['python', 'json']:
            if source == 'python':
                prog = HerbProgram(MULTI_PROCESS_OS)
            else:
                spec = deserialize(serialize(MULTI_PROCESS_OS))
                prog = HerbProgram(spec)
            prog.load()
            g = prog.graph

            # Boot: A scheduled (higher priority)
            g.run()
            self.assertEqual(prog.where_is('proc_A'), 'CPU0',
                             f"{source}: proc_A should be on CPU0")

            # Open FD for running process
            prog.create_entity('open1', 'Signal', 'OPEN_REQUEST')
            g.run()

            # proc_A should have 1 open FD
            eid_a = prog.entity_id('proc_A')
            fd_open = g.get_scoped_container(eid_a, 'FD_OPEN')
            self.assertEqual(
                g.containers[fd_open].count, 1,
                f"{source}: proc_A should have 1 open FD"
            )

    def test_kernel_equivalence(self):
        """Four-module kernel: identical behavior from JSON."""
        # Python dict
        prog_py = compose_and_load(KERNEL)
        g_py = prog_py.graph

        # JSON round-trip
        spec = deserialize(serialize(KERNEL))
        prog_json = spec_to_program(spec)
        g_json = prog_json.graph

        # Run same sequence on both
        for prog, g in [(prog_py, g_py), (prog_json, g_json)]:
            g.run()  # boot
            prog.create_entity('alloc1', 'proc.Signal', 'proc.ALLOC_SIG')
            g.run()
            prog.create_entity('open1', 'proc.Signal', 'proc.OPEN_SIG')
            g.run()

        # Compare state
        for name in ['server', 'client']:
            self.assertEqual(
                prog_py.where_is(name),
                prog_json.where_is(name),
                f"{name} location mismatch"
            )
            for prop in ['time_slice', 'msgs_received']:
                self.assertEqual(
                    prog_py.get_property(name, prop),
                    prog_json.get_property(name, prop),
                    f"{name}.{prop} mismatch"
                )

    def test_dimensions_equivalence(self):
        """Multi-dimensional process manager from JSON."""
        for source in ['python', 'json']:
            if source == 'python':
                prog = HerbProgram(DIMENSIONS)
            else:
                spec = deserialize(serialize(DIMENSIONS))
                prog = HerbProgram(spec)
            prog.load()
            g = prog.graph

            g.run()
            # kernel_task (PRIO_HIGH) should be scheduled
            self.assertEqual(
                prog.where_is('kernel_task'), 'CPU_0',
                f"{source}: kernel_task should be on CPU_0"
            )

    def test_scheduler_equivalence(self):
        """FIFO scheduler from JSON."""
        for source in ['python', 'json']:
            if source == 'python':
                prog = HerbProgram(SCHEDULER)
            else:
                spec = deserialize(serialize(SCHEDULER))
                prog = HerbProgram(spec)
            prog.load()
            g = prog.graph

            g.run()
            # FIFO: init first (lowest ID), then shell
            self.assertEqual(prog.where_is('init'), 'CPU0',
                             f"{source}: init on CPU0")
            self.assertEqual(prog.where_is('shell'), 'CPU1',
                             f"{source}: shell on CPU1")
            self.assertEqual(prog.where_is('daemon'), 'READY_QUEUE',
                             f"{source}: daemon in READY_QUEUE")


# =============================================================================
# 4. VALIDATION TESTS
# =============================================================================

class TestValidation(unittest.TestCase):
    """Validation catches malformed programs."""

    def test_detect_kind_program(self):
        self.assertEqual(detect_kind(SCHEDULER), "program")

    def test_detect_kind_composition(self):
        self.assertEqual(detect_kind(KERNEL), "composition")

    def test_detect_kind_module(self):
        self.assertEqual(detect_kind(PROC_MODULE), "module")

    def test_valid_program_passes(self):
        errors = validate(SCHEDULER)
        self.assertEqual(errors, [])

    def test_valid_kernel_passes(self):
        errors = validate(KERNEL)
        self.assertEqual(errors, [])

    def test_valid_module_passes(self):
        errors = validate(PROC_MODULE)
        self.assertEqual(errors, [])

    def test_reject_invalid_json(self):
        with self.assertRaises(ValueError):
            deserialize("not valid json {{{")

    def test_reject_non_dict(self):
        with self.assertRaises(ValueError):
            deserialize("[1, 2, 3]")

    def test_reject_missing_entity_types(self):
        bad_spec = {"containers": [], "moves": []}
        errors = validate(bad_spec)
        self.assertTrue(any("entity_types" in e for e in errors))

    def test_reject_missing_containers(self):
        bad_spec = {"entity_types": [{"name": "A"}]}
        errors = validate(bad_spec)
        self.assertTrue(any("containers" in e for e in errors))

    def test_reject_unknown_container_in_move(self):
        bad_spec = {
            "entity_types": [{"name": "A"}],
            "containers": [{"name": "C1"}],
            "moves": [{"name": "m1", "from": ["C1"], "to": ["NONEXISTENT"]}],
        }
        errors = validate(bad_spec)
        self.assertTrue(any("NONEXISTENT" in e for e in errors))

    def test_reject_unknown_type_in_entity(self):
        bad_spec = {
            "entity_types": [{"name": "A"}],
            "containers": [{"name": "C1"}],
            "entities": [{"name": "e1", "type": "B", "in": "C1"}],
        }
        errors = validate(bad_spec)
        self.assertTrue(any("unknown type" in e for e in errors))

    def test_reject_composition_bad_module_ref(self):
        bad_comp = {
            "compose": ["nonexistent"],
            "modules": [PROC_MODULE],
        }
        errors = validate(bad_comp)
        self.assertTrue(any("nonexistent" in e for e in errors))

    def test_reject_composition_no_modules(self):
        bad_comp = {"compose": ["proc"]}
        errors = validate(bad_comp)
        self.assertTrue(len(errors) > 0)

    def test_serializability_check_accepts_tuple(self):
        """Tuples are accepted (json.dumps converts them to arrays)."""
        _check_serializable({"key": (1, 2, 3)})  # should not raise

    def test_serializability_check_rejects_set(self):
        with self.assertRaises(TypeError):
            _check_serializable({"key": {1, 2, 3}})

    def test_serializability_check_accepts_valid(self):
        _check_serializable(SCHEDULER)
        _check_serializable(KERNEL)

    def test_deserialize_validates(self):
        """deserialize() rejects valid JSON with invalid HERB structure."""
        bad_json = json.dumps({"entity_types": [{"name": "A"}]})
        with self.assertRaises(ValueError) as cm:
            deserialize(bad_json)
        self.assertIn("containers", str(cm.exception))


# =============================================================================
# 5. COMPOSITION FROM JSON TESTS
# =============================================================================

class TestCompositionFromJson(unittest.TestCase):
    """Compose modules loaded from JSON."""

    def test_compose_kernel_from_json(self):
        """Compose kernel from JSON, run, verify behavior."""
        json_str = serialize(KERNEL)
        spec = deserialize(json_str)
        prog = spec_to_program(spec)
        g = prog.graph

        # Boot
        g.run()
        self.assertEqual(prog.where_is('server'), 'proc.CPU0')

    def test_compose_multiprocess_from_json(self):
        """Compose multiprocess modules from JSON."""
        json_str = serialize(COMPOSED_MULTIPROCESS)
        spec = deserialize(json_str)
        prog = spec_to_program(spec)
        g = prog.graph

        g.run()
        self.assertEqual(prog.where_is('proc_A'), 'scheduler.CPU0')

    def test_modules_individually_valid(self):
        """Each module in the kernel validates independently."""
        for mod in [PROC_MODULE, MEM_MODULE, FS_MODULE, IPC_MODULE]:
            json_str = serialize(mod)
            spec = json.loads(json_str)
            errors = validate(spec)
            self.assertEqual(errors, [],
                             f"Module {mod['module']} has validation errors: {errors}")


# =============================================================================
# 6. FORMAT TESTS
# =============================================================================

class TestFormat(unittest.TestCase):
    """JSON format correctness."""

    def test_json_is_valid(self):
        """All serialized programs are valid JSON."""
        for spec in [SCHEDULER, PRIORITY_SCHEDULER, DOM_LAYOUT, ECONOMY,
                     MULTI_PROCESS_OS, IPC_DEMO, DIMENSIONS,
                     COMPOSED_MULTIPROCESS, KERNEL]:
            json_str = serialize(spec)
            parsed = json.loads(json_str)
            self.assertIsInstance(parsed, dict)

    def test_pretty_format(self):
        """Pretty format has indentation."""
        json_str = serialize(SCHEDULER, pretty=True)
        self.assertIn('\n', json_str)
        self.assertIn('  ', json_str)

    def test_compact_format(self):
        """Compact format has no extra whitespace."""
        json_str = serialize(SCHEDULER, pretty=False)
        self.assertNotIn('\n', json_str)

    def test_no_python_specific_types(self):
        """JSON output contains no Python-specific representations."""
        for spec in [SCHEDULER, KERNEL]:
            json_str = serialize(spec)
            self.assertNotIn("True", json_str)
            self.assertNotIn("False", json_str)
            self.assertNotIn("None", json_str)

    def test_kernel_json_structure(self):
        """kernel.herb.json has correct top-level structure."""
        path = os.path.join(PROGRAMS_DIR, 'kernel.herb.json')
        if not os.path.exists(path):
            self.skipTest("kernel.herb.json not found")
        with open(path) as f:
            data = json.load(f)
        self.assertIn("compose", data)
        self.assertIn("modules", data)
        self.assertIn("channels", data)
        self.assertIn("entities", data)
        self.assertEqual(data["compose"], ["proc", "mem", "fs", "ipc"])
        self.assertEqual(len(data["modules"]), 4)


# =============================================================================
# 7. CROSS-RUNTIME EQUIVALENCE (Python vs C)
# =============================================================================

class TestCrossRuntime(unittest.TestCase):
    """Python and C runtimes produce identical results on the same .herb.json."""

    @classmethod
    def setUpClass(cls):
        """Check if C runtime is compiled."""
        src_dir = os.path.dirname(__file__)
        if sys.platform == 'win32':
            cls.c_exe = os.path.join(src_dir, 'herb_runtime_v2.exe')
        else:
            cls.c_exe = os.path.join(src_dir, 'herb_runtime_v2')
        cls.c_available = os.path.exists(cls.c_exe)

    def _run_c_runtime(self, json_path, commands):
        """Run C runtime with commands on stdin, return stdout."""
        if not self.c_available:
            self.skipTest("C runtime not compiled")
        proc = subprocess.run(
            [self.c_exe, json_path],
            input='\n'.join(commands) + '\n',
            capture_output=True,
            text=True,
            timeout=10
        )
        if proc.returncode != 0:
            self.fail(f"C runtime error:\n{proc.stderr}")
        return proc.stdout

    def test_priority_scheduler_cross_runtime(self):
        """Priority scheduler: Python and C produce identical states."""
        if not self.c_available:
            self.skipTest("C runtime not compiled")

        json_path = os.path.join(PROGRAMS_DIR, 'priority_scheduler.herb.json')
        if not os.path.exists(json_path):
            self.skipTest("priority_scheduler.herb.json not found")

        # Python: load, run, get state
        spec = load(json_path)
        prog = spec_to_program(spec)
        g = prog.graph
        g.run()

        py_state = {}
        for name in ['init', 'shell', 'daemon']:
            py_state[name] = prog.where_is(name)

        # C: load, run, get state
        output = self._run_c_runtime(json_path, ['run', 'state'])
        c_state = json.loads(output)

        # Compare
        for name in ['init', 'shell', 'daemon']:
            self.assertEqual(
                py_state[name],
                c_state.get(name, {}).get('location'),
                f"{name} location mismatch: Python={py_state[name]} C={c_state.get(name, {}).get('location')}"
            )

    def test_priority_scheduler_with_signals_cross_runtime(self):
        """Priority scheduler with timer signal: Python and C match."""
        if not self.c_available:
            self.skipTest("C runtime not compiled")

        json_path = os.path.join(PROGRAMS_DIR, 'priority_scheduler.herb.json')
        if not os.path.exists(json_path):
            self.skipTest("priority_scheduler.herb.json not found")

        # Python
        spec = load(json_path)
        prog = spec_to_program(spec)
        g = prog.graph
        g.run()
        prog.create_entity('t1', 'Signal', 'TIMER_EXPIRED')
        g.run()

        py_state = {}
        for name in ['init', 'shell', 'daemon']:
            py_state[name] = prog.where_is(name)
        py_state['total_ops'] = len(g.operations)

        # C
        output = self._run_c_runtime(json_path, [
            'run',
            'create t1 Signal TIMER_EXPIRED',
            'run',
            'state',
        ])
        c_state = json.loads(output)

        # Compare locations
        for name in ['init', 'shell', 'daemon']:
            self.assertEqual(
                py_state[name],
                c_state.get(name, {}).get('location'),
                f"{name} location mismatch after timer"
            )

    def test_fifo_scheduler_cross_runtime(self):
        """FIFO scheduler: Python and C produce identical states."""
        if not self.c_available:
            self.skipTest("C runtime not compiled")

        json_path = os.path.join(PROGRAMS_DIR, 'scheduler.herb.json')
        if not os.path.exists(json_path):
            self.skipTest("scheduler.herb.json not found")

        # Python
        spec = load(json_path)
        prog = spec_to_program(spec)
        prog.graph.run()

        # C
        output = self._run_c_runtime(json_path, ['run', 'state'])
        c_state = json.loads(output)

        for name in ['init', 'shell', 'daemon']:
            self.assertEqual(
                prog.where_is(name),
                c_state[name]['location'],
                f"FIFO {name} mismatch"
            )

    def test_dom_layout_cross_runtime(self):
        """DOM layout pipeline: Python and C produce identical states."""
        if not self.c_available:
            self.skipTest("C runtime not compiled")

        json_path = os.path.join(PROGRAMS_DIR, 'dom_layout.herb.json')
        if not os.path.exists(json_path):
            self.skipTest("dom_layout.herb.json not found")

        # Python
        spec = load(json_path)
        prog = spec_to_program(spec)
        prog.graph.run()

        # C
        output = self._run_c_runtime(json_path, ['run', 'state'])
        c_state = json.loads(output)

        for name in ['header', 'content', 'footer']:
            self.assertEqual(
                prog.where_is(name),
                c_state[name]['location'],
                f"DOM {name} mismatch"
            )

    def test_fifo_scheduler_full_signal_sequence(self):
        """FIFO scheduler with timer + IO signals: cross-runtime match."""
        if not self.c_available:
            self.skipTest("C runtime not compiled")

        json_path = os.path.join(PROGRAMS_DIR, 'scheduler.herb.json')
        if not os.path.exists(json_path):
            self.skipTest("scheduler.herb.json not found")

        # Python
        spec = load(json_path)
        prog = spec_to_program(spec)
        g = prog.graph
        g.run()
        prog.create_entity('t1', 'Signal', 'TIMER_EXPIRED')
        g.run()
        prog.create_entity('io1', 'Signal', 'IO_COMPLETE')
        g.run()

        # C
        output = self._run_c_runtime(json_path, [
            'run',
            'create t1 Signal TIMER_EXPIRED',
            'run',
            'create io1 Signal IO_COMPLETE',
            'run',
            'state',
        ])
        c_state = json.loads(output)

        for name in ['init', 'shell', 'daemon']:
            self.assertEqual(
                prog.where_is(name),
                c_state[name]['location'],
                f"FIFO+signals {name} mismatch"
            )

    def test_dom_layout_with_style_change(self):
        """DOM layout with style change signal: cross-runtime match."""
        if not self.c_available:
            self.skipTest("C runtime not compiled")

        json_path = os.path.join(PROGRAMS_DIR, 'dom_layout.herb.json')
        if not os.path.exists(json_path):
            self.skipTest("dom_layout.herb.json not found")

        # Python
        spec = load(json_path)
        prog = spec_to_program(spec)
        g = prog.graph
        g.run()  # initial pipeline
        prog.create_entity('sc1', 'StyleChange', 'STYLE_PENDING')
        g.run()  # re-layout cascade

        # C
        output = self._run_c_runtime(json_path, [
            'run',
            'create sc1 StyleChange STYLE_PENDING',
            'run',
            'state',
        ])
        c_state = json.loads(output)

        for name in ['header', 'content', 'footer']:
            self.assertEqual(
                prog.where_is(name),
                c_state[name]['location'],
                f"DOM+style {name} mismatch"
            )
        # Style change should be consumed
        self.assertEqual(
            prog.where_is('sc1'),
            c_state['sc1']['location'],
        )


if __name__ == '__main__':
    unittest.main()
