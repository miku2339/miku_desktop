import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/persona_training"))
from load_watchdog import WeightLoadWatchdog, sequential_weight_loading, watch
import persona
import loader_probe
from train import dgx_budget_gate, load_dgx_weights, run_fingerprint


class WatchdogTests(unittest.TestCase):
    def test_training_reserve_guard_reports_training_phase_and_saved_checkpoint(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            checkpoint = root / "adapter/checkpoint-1/trainer_state.json"
            checkpoint.parent.mkdir(parents=True)
            checkpoint.write_text('{"global_step":1}')
            identities = iter(["owned", "owned", "owned", "gone"])
            signals = []
            watch(123, "owned", 18, root / "ready.json", root / "stop.json", phase="training",
                memory=lambda: 17, birth=lambda pid: next(identities, "gone"),
                kill=lambda pid, sig: signals.append((pid, sig)), sleep=lambda _: None)
            report = json.loads((root / "stop.json").read_text())
            self.assertEqual(report["phase"], "training")
            self.assertTrue(report["checkpoint_exists"])
            self.assertEqual(signals, [(123, signal.SIGTERM)])

    def observe(self, memory, ignores_term=False, replace_identity=False, fail_report=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            status, report = root / "status.json", root / "stop.json"
            alive, births, signals = [True], [], []
            def birth(pid):
                births.append(pid)
                if replace_identity and len(births) >= 3: return "reused"
                if not alive[0]: raise FileNotFoundError()
                return "owned"
            def kill(pid, number):
                signals.append((pid, number))
                if not ignores_term or number == signal.SIGKILL: alive[0] = False
            def sleep(delay):
                if memory == 20: alive[0] = False
            if callable(memory): probe = memory
            else: probe = lambda: memory
            if fail_report:
                from load_watchdog import write
                def writer(path, value):
                    if path == report: raise OSError("disk full")
                    write(path, value)
                with patch("load_watchdog.write", side_effect=writer):
                    watch(123, "owned", 16, status, report, memory=probe, birth=birth, kill=kill, sleep=sleep)
            else:
                watch(123, "owned", 16, status, report, memory=probe, birth=birth, kill=kill, sleep=sleep)
            return signals, json.loads(report.read_text()) if report.is_file() else None

    def test_low_memory_stops_only_owned_parent_pid_without_training_callback(self):
        signals, report = self.observe(15)
        self.assertEqual(signals, [(123, signal.SIGTERM)])
        self.assertEqual(report["phase"], "weight_loading")
        self.assertEqual(report["available_gib"], 15)
        self.assertFalse(report["checkpoint_exists"])

    def test_native_loader_ignoring_term_is_killed_after_one_second(self):
        signals, _ = self.observe(15, ignores_term=True)
        self.assertEqual(signals, [(123, signal.SIGTERM), (123, signal.SIGKILL)])

    def test_reused_pid_is_never_signalled(self):
        signals, _ = self.observe(15, replace_identity=True)
        self.assertEqual(signals, [])

    def test_normal_reserve_does_not_terminate_or_record_failure(self):
        self.assertEqual(self.observe(20), ([], None))

    def test_missing_memory_observation_fails_closed(self):
        def missing(): raise OSError("no meminfo")
        signals, report = self.observe(missing)
        self.assertEqual(signals, [(123, signal.SIGTERM)])
        self.assertIn("memory_observation_failed", report["reason"])

    def test_report_write_failure_cannot_disable_reserve_stop(self):
        signals, report = self.observe(15, fail_report=True)
        self.assertEqual(signals, [(123, signal.SIGTERM)])
        self.assertIsNone(report)

    def test_watchdog_must_be_ready_before_loader_runs_and_is_reaped(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            class Child:
                returncode = None
                def poll(self): return self.returncode
                def terminate(self): self.returncode = -15
                def wait(self, timeout=None): return self.returncode
            child = Child()
            def start(command, **options):
                self.assertTrue(options["start_new_session"])
                self.assertEqual(command[command.index("--pid") + 1], "123")
                path = Path(command[command.index("--status") + 1])
                path.write_text(json.dumps({"status": "ready", "pid": 123}))
                return child
            with patch("load_watchdog.available_memory", return_value=88), patch("load_watchdog.process_start", return_value="owned"), patch("load_watchdog.os.getpid", return_value=123), patch("load_watchdog.subprocess.Popen", side_effect=start):
                with WeightLoadWatchdog(16, root): self.assertIsNone(child.poll())
                self.assertEqual(child.poll(), -15)

    def test_watchdog_start_failure_refuses_loading(self):
        with tempfile.TemporaryDirectory() as temp:
            class Child:
                def poll(self): return 1
                def wait(self, timeout=None): return 1
            with patch("load_watchdog.available_memory", return_value=88), patch("load_watchdog.process_start", return_value="owned"), patch("load_watchdog.subprocess.Popen", return_value=Child()):
                with self.assertRaises(RuntimeError):
                    with WeightLoadWatchdog(16, Path(temp)): self.fail("loader must not run")

    def test_sequential_loading_restores_environment(self):
        for previous in [None, "0"]:
            with patch.dict(os.environ, {}, clear=False):
                if previous is None: os.environ.pop("HF_DEACTIVATE_ASYNC_LOAD", None)
                else: os.environ["HF_DEACTIVATE_ASYNC_LOAD"] = previous
                with sequential_weight_loading(): self.assertEqual(os.environ["HF_DEACTIVATE_ASYNC_LOAD"], "1")
                self.assertEqual(os.environ.get("HF_DEACTIVATE_ASYNC_LOAD"), previous)


class PrecisionTests(unittest.TestCase):
    def test_resume_fingerprint_rejects_a_different_completion_mask(self):
        cfg = persona.config()
        current = run_fingerprint(cfg, "mac", "index", True, data_sha256="same-data")
        with patch("train.COMPLETION_MASK_VERSION", "legacy_prefix_length"):
            legacy = run_fingerprint(cfg, "mac", "index", True, data_sha256="same-data")
        self.assertNotEqual(current, legacy)

    def test_tiny_probe_refuses_low_ram_or_inactive_services_before_torch_import(self):
        import builtins
        original = builtins.__import__
        def guarded_import(name, *args, **kwargs):
            if name == "torch": self.fail("Resource rejection must precede Torch import")
            return original(name, *args, **kwargs)
        for memory, active in [(47.99, True), (64, False)]:
            with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {"MIKU_TRAINING_ROOT": temp}), \
                 patch("loader_probe.sys.platform", "linux"), patch("loader_probe.available_memory", return_value=memory), \
                 patch("loader_probe.service_state", return_value={unit: "active" if active else "inactive" for unit in loader_probe.UNITS}), \
                 patch("builtins.__import__", side_effect=guarded_import):
                with self.assertRaises(ValueError): loader_probe.run(persona.config(), Path(temp) / "reports/test.json")

    def test_tiny_probe_dry_run_never_loads_weights(self):
        result = subprocess.run([sys.executable, str(Path(loader_probe.__file__)), "--output", "unused.json"], capture_output=True, text=True, check=True)
        report = json.loads(result.stdout)
        self.assertTrue(report["dry_run"])
        self.assertFalse(report["would_load_full_weights"])
        self.assertEqual(report["allocator_cap_bytes"], 256 * 2**20)

    def test_bf16_loads_on_cpu_then_moves_same_complete_model(self):
        calls = []
        class Model:
            vision = object()
            @classmethod
            def from_pretrained(cls, path, **options):
                calls.append(("load", options))
                return cls()
            def to(self, device):
                calls.append(("move", device))
                return self
        def forbidden(**_): self.fail("BF16 must not create a quantizer")
        model = load_dgx_weights(Model, Path("local"), "bf16", "bf16", forbidden)
        self.assertIs(model.vision, Model.vision)
        self.assertIsNone(calls[0][1]["device_map"])
        self.assertEqual(calls[0][1]["dtype"], "bf16")
        self.assertEqual(calls[1], ("move", "cuda:0"))

    def test_explicit_nf4_keeps_direct_device_mapping(self):
        calls = []
        class Model:
            @classmethod
            def from_pretrained(cls, path, **options): calls.append(options); return cls()
            def to(self, device): self.fail("Quantized model must not be moved after loading")
        model = load_dgx_weights(Model, Path("local"), "nf4", "bf16", lambda **kwargs: kwargs)
        self.assertIsInstance(model, Model)
        self.assertEqual(calls[0]["device_map"], {"": 0})
        self.assertTrue(calls[0]["quantization_config"]["load_in_4bit"])

    def test_bf16_is_default_and_nf4_requires_explicit_choice(self):
        cfg = persona.config()
        self.assertEqual(cfg["dgx"]["precision"], "bf16")
        self.assertGreater(cfg["meta_memory_budget"]["base_lower_bound_by_precision_gib"]["bf16"], 65)
        baseline = run_fingerprint(cfg, "dgx", "index", True, True)
        cfg["dgx"]["precision"] = "nf4"
        self.assertNotEqual(baseline, run_fingerprint(cfg, "dgx", "index", True, True))
        budget = {"version": 2, "verified": True, "kind": "conservative_analytical_probe", "estimated_peak_gib": 85,
            "model_index_sha256": "index", "base_revision": cfg["base_revision"], "expires_at": 1100,
            "preparation": cfg["dgx"]["preparation"], "run_fingerprint": run_fingerprint(cfg, "dgx", "index", True, True)}
        gate = dgx_budget_gate(cfg, 110, 200, 0, 0, budget, "index", 1000, True, True)
        self.assertFalse(gate["allowed"])

    def test_explicit_nf4_dry_run_does_not_load_a_model(self):
        script = Path(persona.__file__)
        result = subprocess.run([sys.executable, str(script), "train-dgx", "--probe", "--smoke", "--precision", "nf4", "--run-id", "dry-only", "--dry-run"], capture_output=True, text=True, check=True)
        report = json.loads(result.stdout)
        self.assertEqual(report["configuration"]["precision"], "nf4")
        self.assertFalse(report["would_run_gpu"])


if __name__ == "__main__": unittest.main()
