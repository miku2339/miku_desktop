import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/persona_training"))
import persona
import run_when_idle
from train import dgx_gate, run_fingerprint


class IdleSchedulerTests(unittest.TestCase):
    def run_queue(self, gates, outcomes, hours=1, resume=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "logs").mkdir()
            source = root / "runs/original/checkpoints/state-final"
            if resume:
                source.mkdir(parents=True)
                (source / "checkpoint.json").write_text('{"completed_microsteps":20}')
            clock, commands, statuses = [1000.0], [], []
            self.processes, self.signals = [], []
            values = iter(gates)
            last = gates[-1]
            def gate(*_):
                nonlocal last
                last = next(values, last)
                return last
            def execute(command, **kwargs):
                commands.append(command)
                self.assertTrue(kwargs["start_new_session"])
                outcome = outcomes[len(commands) - 1]
                status, exit_code = outcome[:2]
                actions = list(outcome[2]) if len(outcome) > 2 else [exit_code]
                run_id = command[command.index("--run-id") + 1]
                directory = root / "runs" / run_id
                class Child:
                    pid = 2000 + len(commands)
                    returncode = None
                    waits = None
                    def poll(self): return self.returncode
                    def wait(self, timeout=None):
                        self.waits.append(timeout)
                        if self.returncode is not None: return self.returncode
                        action = actions.pop(0)
                        if action is subprocess.TimeoutExpired:
                            clock[0] += timeout
                            raise subprocess.TimeoutExpired(command, timeout)
                        if action is KeyboardInterrupt: raise KeyboardInterrupt()
                        self.returncode = action
                        directory.mkdir(parents=True)
                        (directory / "run.json").write_text(json.dumps({"status": status, "checkpoint": str(root / "checkpoint")}))
                        return action
                child = Child()
                child.waits = []
                self.processes.append(child)
                return child
            original = persona.write_report
            def report(path, value):
                statuses.append(dict(value))
                original(path, value)
            with patch.dict(os.environ, {"MIKU_TRAINING_ROOT": temp}), \
                 patch("run_when_idle.mac_gate", side_effect=gate), \
                 patch("run_when_idle.mac_observations", return_value={}), \
                 patch("run_when_idle.time.time", side_effect=lambda: clock[0]), \
                 patch("run_when_idle.time.monotonic", side_effect=lambda: clock[0]), \
                 patch("run_when_idle.time.sleep", side_effect=lambda delay: clock.__setitem__(0, clock[0] + delay)), \
                 patch("run_when_idle.subprocess.Popen", side_effect=execute), \
                 patch("run_when_idle.os.killpg", side_effect=lambda pid, number: self.signals.append((pid, number))), \
                 patch("run_when_idle.write_report", side_effect=report):
                result = run_when_idle.run(persona.config(), hours, source if resume else None)
            if resume:
                self.assertEqual((source / "checkpoint.json").read_text(), '{"completed_microsteps":20}')
            return result, commands, statuses

    def test_waits_without_starting_a_model_until_all_gates_allow(self):
        result, commands, statuses = self.run_queue(
            [{"allowed": False, "reasons": ["voice_call_active"]}, {"allowed": True, "reasons": []}],
            [("probe_complete", 0)])
        self.assertEqual([s["status"] for s in statuses], ["waiting", "running", "probe_complete"])
        self.assertEqual(result["status"], "probe_complete")
        self.assertEqual(len(commands), 1)
        self.assertIn("--probe", commands[0])
        self.assertNotIn("--resume", commands[0])
        self.assertFalse(result["acceptance_passed"])

    def test_pause_waits_for_idle_and_resumes_checkpoint_under_new_run_id(self):
        result, commands, statuses = self.run_queue(
            [{"allowed": True, "reasons": []}, {"allowed": False, "reasons": ["memory_pressure_not_normal"]}, {"allowed": True, "reasons": []}],
            [("paused", 0), ("probe_complete", 0)])
        self.assertEqual(result["status"], "probe_complete")
        self.assertEqual(len(commands), 2)
        self.assertNotEqual(commands[0][commands[0].index("--run-id") + 1], commands[1][commands[1].index("--run-id") + 1])
        self.assertIn("--resume", commands[1])
        checkpoint = commands[1][commands[1].index("--resume") + 1]
        self.assertTrue(checkpoint.endswith("/checkpoint"))
        waiting = next(s for s in statuses if s["status"] == "waiting")
        self.assertEqual(waiting["checkpoint"], checkpoint)

    def test_explicit_checkpoint_waits_for_gates_and_is_passed_to_first_probe(self):
        reasons = ["not_on_ac_power", "user_not_idle_10_minutes", "voice_call_active",
            "memory_pressure_not_normal", "insufficient_available_ram", "insufficient_free_disk"]
        gates = [{"allowed": False, "reasons": [reason]} for reason in reasons]
        result, commands, statuses = self.run_queue(gates + [{"allowed": True, "reasons": []}],
            [("probe_complete", 0)], resume=True)
        self.assertEqual(result["status"], "probe_complete")
        self.assertEqual(len(commands), 1)
        self.assertEqual([status["reasons"][0] for status in statuses if status["status"] == "waiting"], reasons)
        checkpoint = commands[0][commands[0].index("--resume") + 1]
        self.assertTrue(checkpoint.endswith("/runs/original/checkpoints/state-final"))
        self.assertIn("--probe", commands[0])

    def test_initial_checkpoint_outside_private_runs_is_rejected_before_loading(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "checkpoint.json").write_text("{}")
            with patch.dict(os.environ, {"MIKU_TRAINING_ROOT": temp}), \
                 patch("run_when_idle.mac_observations") as observe, \
                 patch("run_when_idle.subprocess.Popen") as start:
                with self.assertRaisesRegex(ValueError, "private training root"):
                    run_when_idle.run(persona.config(), 1, root)
                observe.assert_not_called()
                start.assert_not_called()

    def test_failed_child_is_not_retried_or_reported_as_complete(self):
        for status, code in [("probe_complete", 1), ("failed", 0), ("trained_not_accepted", 0)]:
            result, commands, _ = self.run_queue([{"allowed": True, "reasons": []}], [(status, code)])
            self.assertEqual(result["status"], "failed")
            self.assertEqual(len(commands), 1)

    def test_queue_expiry_never_starts_a_model(self):
        result, commands, _ = self.run_queue([{"allowed": False, "reasons": ["user_not_idle_10_minutes"]}], [], hours=1/3600)
        self.assertEqual(result["status"], "expired_waiting_for_idle")
        self.assertEqual(commands, [])
        self.assertFalse(result["acceptance_passed"])

    def test_child_deadline_requests_checkpoint_and_reaps_own_process_group(self):
        result, _, _ = self.run_queue([{"allowed": True, "reasons": []}], [("paused", 0, [subprocess.TimeoutExpired, 0])])
        self.assertEqual(result["status"], "expired_checkpointed")
        self.assertTrue(result["checkpoint"].endswith("/checkpoint"))
        child = self.processes[0]
        self.assertEqual(self.signals, [(child.pid, signal.SIGTERM)])
        self.assertEqual(child.waits[:2], [3510, 90])
        self.assertIsNotNone(child.poll())

    def test_child_ignoring_grace_is_killed_and_reaped_before_return(self):
        result, _, _ = self.run_queue([{"allowed": True, "reasons": []}], [("paused", -9, [subprocess.TimeoutExpired, subprocess.TimeoutExpired, -9])])
        self.assertEqual(result["status"], "expired_stopped")
        child = self.processes[0]
        self.assertEqual(self.signals, [(child.pid, signal.SIGTERM), (child.pid, signal.SIGKILL)])
        self.assertEqual(child.waits[:3], [3510, 90, None])
        self.assertEqual(child.poll(), -9)

    def test_cancelling_queue_saves_checkpoint_and_reaps_child(self):
        result, _, _ = self.run_queue([{"allowed": True, "reasons": []}], [("paused", 0, [KeyboardInterrupt, 0])])
        self.assertEqual(result["status"], "cancelled")
        self.assertTrue(result["checkpoint"].endswith("/checkpoint"))
        child = self.processes[0]
        self.assertEqual(self.signals, [(child.pid, signal.SIGTERM)])
        self.assertIsNotNone(child.poll())

    def test_no_child_starts_without_90_second_checkpoint_grace(self):
        result, commands, _ = self.run_queue([{"allowed": True, "reasons": []}], [], hours=90/3600)
        self.assertEqual(result["status"], "expired_waiting_for_idle")
        self.assertEqual(commands, [])


class DGXSupervisorTests(unittest.TestCase):
    def gate(self, extra_process):
        cfg = persona.config()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            model = root / "model"
            model.mkdir()
            index = model / "model.safetensors.index.json"
            index.write_text("{}")
            digest = hashlib.sha256(index.read_bytes()).hexdigest()
            budget = {"version": 2, "kind": "conservative_analytical_probe", "verified": True,
                "base_revision": cfg["base_revision"], "preparation": cfg["dgx"]["preparation"],
                "model_index_sha256": digest, "run_fingerprint": run_fingerprint(cfg, "dgx", digest, True, True),
                "estimated_peak_gib": 85, "expires_at": 1100}
            persona.write_report(root / cfg["dgx"]["memory_budget_file"], budget)
            original = Path.read_text
            def read(path, *args, **kwargs):
                if str(path) == "/proc/meminfo": return f"MemAvailable: {110 * 2**20}\n"
                return original(path, *args, **kwargs)
            processes = "123 /venv/bin/python /tools/training_window.py run -- /venv/bin/python /tools/persona.py train-dgx\n124 /venv/bin/python /tools/run_when_idle.py --hours 6\n" + extra_process
            with patch.dict(os.environ, {"MIKU_TRAINING_ROOT": temp}), \
                 patch.object(Path, "read_text", new=read), \
                 patch("train.shutil.disk_usage", return_value=SimpleNamespace(free=200 * 2**30)), \
                 patch("train.subprocess.run", return_value=SimpleNamespace(stdout="0\n")), \
                 patch("train.subprocess.check_output", return_value=processes), \
                 patch("train.time.time", return_value=1000), \
                 patch("train.os.getpid", return_value=999):
                return dgx_gate(cfg, model, True, True)

    def test_supervisors_are_not_misidentified_as_other_training(self):
        result = self.gate("")
        self.assertTrue(result["allowed"])
        self.assertEqual(result["other_training_processes"], 0)

    def test_actual_parallel_trainer_is_still_rejected(self):
        result = self.gate("125 /venv/bin/python /tools/persona.py train-dgx --probe\n")
        self.assertFalse(result["allowed"])
        self.assertIn("another_training_process_is_active", result["reasons"])


if __name__ == "__main__": unittest.main()
