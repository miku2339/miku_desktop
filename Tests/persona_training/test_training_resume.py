"""Resource gates and opt-in tiny CPU checkpoint/resume checks."""

import json
import os
from pathlib import Path
import random
import signal
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/persona_training"))
import persona
from mac_loop import ResourceMonitor, TrainingPaused, checkpoint_directory, train_resumable, verify_restored_arrays
from train import dgx_budget_gate, run_fingerprint


class ResourceTests(unittest.TestCase):
    def setUp(self): self.cfg = persona.config()

    def budget(self, probe=False, smoke=False, kind="measured_peak"):
        return {"version": 2, "verified": True, "kind": kind, "base_revision": self.cfg["base_revision"],
            "run_fingerprint": run_fingerprint(self.cfg, "dgx", "index", probe, smoke),
            "model_index_sha256": "index", "preparation": self.cfg["dgx"]["preparation"],
            "estimated_peak_gib": 85, "expires_at": 1100}

    def gate(self, budget, probe=False, smoke=False):
        return dgx_budget_gate(self.cfg, 110, 200, 0, 0, budget, "index", 1000, probe, smoke)["allowed"]

    def test_analytical_budget_only_authorizes_its_small_probe(self):
        budget = self.budget(True, True, "conservative_analytical_probe")
        self.assertTrue(self.gate(budget, True, True))
        self.assertFalse(self.gate(budget, True, False))
        self.assertFalse(self.gate(budget))
        budget = self.budget(True, False, "conservative_analytical_probe")
        self.assertTrue(self.gate(budget, True, False))

    def test_analytical_budget_reserves_activation_and_system_memory(self):
        budget = self.budget(True, True, "conservative_analytical_probe")
        budget["estimated_peak_gib"] = 63
        self.assertFalse(self.gate(budget, True, True))
        budget["estimated_peak_gib"] = 100
        self.assertFalse(self.gate(budget, True, True))

    def test_budget_fails_on_changed_revision_or_training_profile(self):
        for key, value in [("rank", 8), ("alpha", 16), ("batch_size", 2), ("gradient_accumulation", 8), ("learning_rate", .0001)]:
            budget = self.budget()
            self.cfg["dgx"][key] = value
            self.assertFalse(self.gate(budget))
            self.cfg = persona.config()
        budget = self.budget()
        self.cfg["max_tokens"] += 2048
        self.assertFalse(self.gate(budget))
        self.cfg = persona.config()
        budget["base_revision"] = "wrong"
        self.assertFalse(self.gate(budget))

    def test_missing_warning_and_critical_pressure_fail_closed(self):
        obs = {"now": 1000, "platform": "darwin", "ac_power": True, "idle_seconds": 601,
            "available_ram_gib": 100, "free_disk_gib": 100, "voice_state_live": True,
            "voice_state": {"version": 1, "active": False, "updated_at": 1000}}
        for state in [None, "unknown", "warning", "critical"]:
            obs["memory_pressure"] = state
            self.assertIn("memory_pressure_not_normal", persona.mac_gate(self.cfg, obs)["reasons"])
        obs["memory_pressure"] = "normal"
        self.assertTrue(persona.mac_gate(self.cfg, obs)["allowed"])

    def test_monitor_latches_resource_warning(self):
        with ResourceMonitor(lambda: ["user_not_idle_10_minutes"], interval=.01) as monitor:
            with self.assertRaises(TrainingPaused): monitor.check()

    def test_stop_signal_requests_safe_pause_and_restores_handlers(self):
        original = signal.getsignal(signal.SIGTERM)
        with ResourceMonitor(lambda: [], interval=.01) as monitor:
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
            with self.assertRaises(TrainingPaused): monitor.check()
        self.assertEqual(signal.getsignal(signal.SIGTERM), original)

    def test_resume_rejects_adapter_only(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError): checkpoint_directory(Path(temp))


@unittest.skipUnless(os.environ.get("MIKU_TEST_MLX") == "1", "Opt-in tiny CPU training only")
class ResumeCPUTests(unittest.TestCase):
    def setUp(self):
        import mlx.core as mx
        mx.set_default_device(mx.cpu)

    def trainer(self):
        import mlx.core as mx
        import mlx.nn as nn
        import mlx.optimizers as optim
        import numpy as np
        from mlx_vlm.trainer import Trainer
        from mlx_vlm.trainer.common.config import CoreTrainingArgs
        from mlx_vlm.trainer.common.task import TrainingTask
        mx.random.seed(91)
        model = nn.Linear(2, 1)
        calls = []
        def loss(m, batch):
            calls.append(batch)
            prediction = m(mx.array([[batch, 1.0]]))
            noise = mx.random.normal(shape=(1, 1)) * .1
            value = mx.mean((prediction + noise + random.random() * .01 + np.random.random() * .01) ** 2)
            return value, {"weight": mx.array(1)}
        def batches(dataset, *, train, seed):
            rng = np.random.default_rng(seed)
            while True:
                yield from (float(n) + random.random() * .001 + np.random.random() * .001 for n in rng.permutation(5))
        task = TrainingTask(loss=loss, batches=batches)
        args = CoreTrainingArgs(iters=7, batch_size=1, gradient_accumulation_steps=4, steps_per_save=20)
        trainer = Trainer(model, args, task=task, train_dataset=list(range(5)), optimizer=optim.AdamW(.01), prepared=True)
        return trainer, calls

    def test_pause_mid_accumulation_resumes_exact_optimizer_rng_and_cursor(self):
        import mlx.core as mx
        from mlx.utils import tree_flatten
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            baseline, baseline_calls = self.trainer()
            train_resumable(baseline, root / "baseline", "same", lambda: None)
            interrupted, calls = self.trainer()
            def guard():
                if len(calls) == 3: raise TrainingPaused("user_returned")
            paused = train_resumable(interrupted, root / "paused", "same", guard)
            self.assertEqual(paused["completed_microsteps"], 3)
            self.assertEqual(paused["remaining_microsteps"], 4)
            checkpoint = checkpoint_directory(root / "paused")
            state = json.loads((checkpoint / "checkpoint.json").read_text())
            self.assertEqual(state["optimizer_steps"], 0)
            resumed, resumed_calls = self.trainer()
            result = train_resumable(resumed, root / "resumed", "same", lambda: None, resume=root / "paused")
            self.assertEqual(result["completed_microsteps"], 7)
            self.assertEqual(calls + resumed_calls, baseline_calls)
            for (_, expected), (_, actual) in zip(tree_flatten(baseline.model.parameters()), tree_flatten(resumed.model.parameters())):
                self.assertTrue(mx.array_equal(expected, actual).item())
            for (_, expected), (_, actual) in zip(tree_flatten(baseline.optimizer.state), tree_flatten(resumed.optimizer.state)):
                self.assertTrue(mx.array_equal(expected, actual).item())
            stopped, stopped_calls = self.trainer()
            def stop_replay(): raise TrainingPaused("user_returned_again")
            again = train_resumable(stopped, root / "again", "same", stop_replay, resume=root / "paused")
            self.assertEqual(again["completed_microsteps"], 3)
            self.assertEqual(stopped_calls, [])
            self.assertEqual(again["checkpoint"], str(checkpoint))

    def test_pause_after_batch_before_forward_preserves_random_state(self):
        import mlx.core as mx
        from mlx.utils import tree_flatten
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            baseline, _ = self.trainer()
            train_resumable(baseline, root / "baseline", "same", lambda: None)
            paused_trainer, calls = self.trainer()
            checks = []
            def guard():
                checks.append(1)
                if len(checks) == 2: raise TrainingPaused("pressure_warning")
            paused = train_resumable(paused_trainer, root / "paused", "same", guard)
            self.assertEqual(paused["completed_microsteps"], 0)
            self.assertEqual(calls, [])
            resumed, _ = self.trainer()
            train_resumable(resumed, root / "resumed", "same", lambda: None, resume=root / "paused")
            for (_, expected), (_, actual) in zip(tree_flatten(baseline.model.parameters()), tree_flatten(resumed.model.parameters())):
                self.assertTrue(mx.array_equal(expected, actual).item())

    def test_pause_before_first_step_is_recoverable_and_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            trainer, calls = self.trainer()
            def guard(): raise TrainingPaused("pressure_warning")
            paused = train_resumable(trainer, Path(temp), "same", guard)
            self.assertEqual(paused["completed_microsteps"], 0)
            self.assertEqual(calls, [])
            restored, _ = self.trainer()
            with self.assertRaises(ValueError):
                train_resumable(restored, Path(temp) / "other", "changed", lambda: None, resume=Path(temp))

    def test_checkpoints_keep_only_current_and_one_rollback(self):
        with tempfile.TemporaryDirectory() as temp:
            trainer, _ = self.trainer()
            train_resumable(trainer, Path(temp), "same", lambda: None, save_every=1)
            self.assertEqual(len(list(Path(temp).glob("state-*"))), 2)

    def test_complete_checkpoint_reloads_fresh_model_and_optimizer_without_new_updates(self):
        import mlx.core as mx
        from mlx.utils import tree_flatten
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            original, _ = self.trainer()
            complete = train_resumable(original, root / "source", "same", lambda: None)
            source = checkpoint_directory(root / "source")
            saved = {str(p.relative_to(source)): p.read_bytes() for p in source.rglob("*") if p.is_file()}
            fresh, calls = self.trainer()
            fresh.model.weight = mx.full_like(fresh.model.weight, 100)
            result = train_resumable(fresh, root / "reloaded", "same", lambda: None, resume=source)
            self.assertEqual(calls, [])
            self.assertEqual(result["completed_microsteps"], complete["completed_microsteps"])
            self.assertEqual(result["resume_verification"]["completed_microsteps"], 7)
            self.assertTrue(result["resume_verification"]["all_finite"])
            self.assertGreater(result["resume_verification"]["trainable_tensors_equal"], 0)
            self.assertGreater(result["resume_verification"]["optimizer_tensors_equal"], 0)
            for (_, expected), (_, actual) in zip(tree_flatten(original.model.parameters()), tree_flatten(fresh.model.parameters())):
                self.assertTrue(mx.array_equal(expected, actual).item())
            for (_, expected), (_, actual) in zip(tree_flatten(original.optimizer.state), tree_flatten(fresh.optimizer.state)):
                self.assertTrue(mx.array_equal(expected, actual).item())
            self.assertEqual(saved, {str(p.relative_to(source)): p.read_bytes() for p in source.rglob("*") if p.is_file()})

    def test_restore_comparison_rejects_changed_or_nonfinite_tensors(self):
        import mlx.core as mx
        expected = {"adapter": mx.array([1.0, 2.0])}
        for actual in [{"other": expected["adapter"]}, {"adapter": mx.array([1.0])},
            {"adapter": mx.array([1.0, 3.0])}, {"adapter": mx.array([1.0, float("nan")])}]:
            with self.assertRaises(ValueError): verify_restored_arrays(actual, expected)


if __name__ == "__main__": unittest.main()
