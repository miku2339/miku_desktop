import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / "scripts/persona_training/training_window.py"
SPEC = importlib.util.spec_from_file_location("training_window", SOURCE)
window = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(window)


class TrainingWindowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.approval = self.root / "approval.json"
        self.value = {"approved_by": "user", "units": list(window.UNITS), "max_seconds": 1800, "expires_at": time.time() + 300}
        self.command = [str(self.root / ".venv/bin/python"), str(self.root / "tools/persona_training/persona.py"), "train-dgx", "--probe"]

    def save(self):
        self.approval.write_text(json.dumps(self.value))

    def test_missing_owner_approval_never_touches_services(self):
        self.value["approved_by"] = "agent"
        self.save()
        with patch.object(window, "systemctl") as service, self.assertRaises(ValueError):
            window.run_window(self.root, self.approval, self.command, False)
        service.assert_not_called()

    def test_expired_or_overlong_window_is_rejected(self):
        for change in [{"expires_at": 0}, {"max_seconds": 1801}]:
            value = dict(self.value, **change)
            self.approval.write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                window.run_window(self.root, self.approval, self.command, True)

    def test_only_the_isolated_probe_can_run(self):
        self.save()
        with self.assertRaises(ValueError):
            window.run_window(self.root, self.approval, ["/bin/sh", "other"], True)
        with self.assertRaises(ValueError):
            window.run_window(self.root, self.approval, self.command[:-1], True)

    def test_an_approval_can_only_be_consumed_once(self):
        self.save()
        self.approval.with_suffix(".used.json").write_text("{}")
        with patch.object(window, "systemctl") as service, self.assertRaises(ValueError):
            window.run_window(self.root, self.approval, self.command, False)
        service.assert_not_called()

    def test_watchdog_failure_never_stops_a_service(self):
        self.save()
        with patch.object(window, "systemctl", return_value=subprocess.CompletedProcess([], 0, "active\n", "")) as service, \
                patch.object(window.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "systemd-run")), \
                self.assertRaises(subprocess.CalledProcessError):
            window.run_window(self.root, self.approval, self.command, False)
        self.assertTrue(all(c.args[0] == "is-active" for c in service.call_args_list))
        self.assertFalse(self.approval.with_suffix(".used.json").exists())

    def test_dry_run_only_reads_service_state(self):
        self.save()
        with patch.object(window, "systemctl", return_value=subprocess.CompletedProcess([], 0, "active\n", "")) as service:
            result = window.run_window(self.root, self.approval, self.command, True)
        self.assertFalse(result["training_started"])
        self.assertEqual(result["would_pause"], list(window.UNITS))
        self.assertTrue(all(c.args[0] == "is-active" for c in service.call_args_list))

    def test_a_retry_never_extends_the_original_approval_deadline(self):
        self.value["original_deadline"] = time.time() + 180
        self.save()
        with patch.object(window, "systemctl", return_value=subprocess.CompletedProcess([], 0, "active\n", "")):
            result = window.run_window(self.root, self.approval, self.command, True)
        self.assertLessEqual(result["max_seconds"], 178)
        self.value["original_deadline"] = time.time() + 30
        self.save()
        with self.assertRaises(ValueError):
            window.run_window(self.root, self.approval, self.command, True)

    def test_launch_failure_restores_both_services(self):
        self.save()
        (self.root / "logs").mkdir()
        with patch.object(window, "systemctl", return_value=subprocess.CompletedProcess([], 0, "active\n", "")) as service, \
                patch.object(window.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(window.subprocess, "Popen", side_effect=OSError("launch failed")), \
                self.assertRaises(OSError):
            window.run_window(self.root, self.approval, self.command, False)
        for unit in window.UNITS:
            self.assertIn(("stop", unit), [c.args for c in service.call_args_list])
            self.assertIn(("start", unit), [c.args for c in service.call_args_list])
        lease = json.loads(next((self.root / "windows").glob("*.json")).read_text())
        self.assertIn("restored_at", lease)

    def test_a_reused_pid_is_never_terminated(self):
        with patch.object(window, "process_start", return_value="new"), patch.object(window.os, "killpg") as kill:
            window.stop_child(12345, "old")
        kill.assert_not_called()

    def test_restore_only_starts_originally_active_services(self):
        lease = self.root / "lease.json"
        lease.write_text(json.dumps({"originally_active": [window.UNITS[0]], "child_pid": None}))
        with patch.object(window, "systemctl", return_value=subprocess.CompletedProcess([], 0, "active\n", "")) as service:
            result = window.restore(lease)
        self.assertIn("restored_at", result)
        self.assertEqual(service.call_args_list[0].args, ("start", window.UNITS[0]))
        self.assertTrue(all(window.UNITS[1] not in c.args for c in service.call_args_list))

    def test_unexpected_service_is_never_started(self):
        lease = self.root / "lease.json"
        lease.write_text(json.dumps({"originally_active": ["unrelated.service"]}))
        with patch.object(window, "systemctl") as service, self.assertRaises(ValueError):
            window.restore(lease)
        service.assert_not_called()


if __name__ == "__main__":
    unittest.main()
