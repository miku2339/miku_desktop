import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/persona_training"))
import persona
from export_model import check_destination
from train import dgx_budget_gate, run_fingerprint


def rows(count=60):
    return [{"id": f"{n}-{lang}", "family": f"family-{n}", "scenario": f"scenario {n}", "language": lang, "mode": "text" if n % 2 else "voice", "status": "pending", "messages": [{"role": "user", "content": "first"}, {"role": "assistant", "content": "answer"}, {"role": "user", "content": str(n)}, {"role": "assistant", "content": lang}]} for n in range(count) for lang in ["zh-TW", "ja", "en", "yue", "ko"]]


class PipelineTests(unittest.TestCase):
    def setUp(self): self.cfg = persona.config()

    def test_family_split_is_stable_and_exact(self):
        assignments = persona.family_splits(rows(), self.cfg)
        self.assertEqual(assignments, persona.family_splits(list(reversed(rows())), self.cfg))
        self.assertEqual({s: list(assignments.values()).count(s) for s in ["train", "valid", "test"]}, {"train": 51, "valid": 3, "test": 6})

    def test_translation_stays_in_one_split(self):
        assignments = persona.family_splits(rows(), self.cfg)
        for n in range(60): self.assertEqual(len({assignments[r["family"]] for r in rows() if r["family"] == f"family-{n}"}), 1)

    def test_validation_rejects_duplicate_id(self):
        data = rows(3); data[1]["id"] = data[0]["id"]
        with self.assertRaises(ValueError): persona.validate_rows(data, self.cfg)

    def test_validation_rejects_broken_role_order(self):
        data = rows(3); data[0]["messages"][2]["role"] = "assistant"
        with self.assertRaises(ValueError): persona.validate_rows(data, self.cfg)

    def test_completion_only_has_one_target_and_prior_context(self):
        expanded = persona.expand_rows(rows(1)[:1], self.cfg)
        self.assertEqual(len(expanded), 2)
        self.assertEqual(len(expanded[1]["completion"]), 1)
        self.assertEqual(len(expanded[1]["prompt"]), 4)
        self.assertEqual(json.loads(expanded[1]["completion"][0]["content"])["text"], "zh-TW")

    def test_rejected_candidates_are_not_exported(self):
        data = rows(1)[:1]; data[0]["status"] = "rejected"
        self.assertEqual(persona.expand_rows(data, self.cfg), [])

    def observations(self):
        return {"now": 1000, "platform": "darwin", "ac_power": True, "idle_seconds": 601, "available_ram_gib": 45, "memory_pressure": "normal", "free_disk_gib": 40, "voice_state_live": True, "voice_state": {"version": 1, "pid": 123, "active": False, "updated_at": 990}}

    def test_gate_accepts_all_positive_evidence(self): self.assertTrue(persona.mac_gate(self.cfg, self.observations())["allowed"])

    def test_gate_fails_closed_without_heartbeat(self):
        obs = self.observations(); obs["voice_state_live"] = False
        self.assertFalse(persona.mac_gate(self.cfg, obs)["allowed"])

    def test_gate_rejects_future_and_stale_heartbeats(self):
        for stamp in [1001, 900, True]:
            obs = self.observations(); obs["voice_state"]["updated_at"] = stamp
            self.assertFalse(persona.mac_gate(self.cfg, obs)["allowed"])

    def test_heartbeat_updated_during_sampling_is_not_misread_as_future(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {"MIKU_TRAINING_ROOT": temp}):
            heartbeat = Path(temp) / "runtime/voice-call-state.json"
            heartbeat.parent.mkdir()
            heartbeat.write_text(json.dumps({"version": 1, "pid": 123, "active": False, "updated_at": 1000.5}))
            outputs = ["AC Power", '"HIDIdleTime" = 601000000000',
                "page size of 16384 bytes\nPages free: 3000000.\nPages inactive: 1000000.\nPages speculative: 1000000.", "1"]
            with patch("persona.time.time", side_effect=[1000, 1001]), patch("persona.sys.platform", "darwin"), \
                    patch("persona.subprocess.check_output", side_effect=outputs), patch("persona.os.kill"), \
                    patch("persona.shutil.disk_usage", return_value=type("Disk", (), {"free": 80 * 2**30})()):
                observations = persona.mac_observations(self.cfg)
            self.assertEqual(observations["now"], 1001)
            self.assertTrue(persona.mac_gate(self.cfg, observations)["allowed"])

    def test_gate_rejects_active_call_including_paused(self):
        obs = self.observations(); obs["voice_state"]["active"] = True
        self.assertIn("voice_call_active_or_unknown", persona.mac_gate(self.cfg, obs)["reasons"])

    def test_gate_requires_power_idle_ram_and_disk(self):
        for key, value in [("ac_power", False), ("idle_seconds", 5), ("available_ram_gib", 1), ("free_disk_gib", 2)]:
            obs = self.observations(); obs[key] = value
            self.assertFalse(persona.mac_gate(self.cfg, obs)["allowed"])

    def target_names(self):
        return [f"model.language_model.layers.{i}." + projection for i in range(40) for projection in ([f"self_attn.{x}_proj" for x in ["q", "k", "v", "o"]] if (i+1)%4 == 0 else [f"linear_attn.{x}" for x in ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a", "out_proj"]])]

    def test_target_selection_excludes_vision_expert_router(self):
        names = self.target_names() + ["model.visual.layers.0.self_attn.q_proj", "model.language_model.layers.1.mlp.gate", "model.language_model.layers.1.mlp.experts.down_proj"]
        selected = persona.targets(names, self.cfg)
        self.assertEqual(len(selected), 190)
        self.assertFalse(any("visual" in n or "mlp" in n for n in selected))

    def test_mac_targets_only_last_eight_layers(self): self.assertEqual(len(persona.targets(self.target_names(), self.cfg, 8)), 38)

    def test_unexpected_architecture_fails(self):
        with self.assertRaises(ValueError): persona.targets(self.target_names()[:-1], self.cfg)

    def test_probe_never_expands_into_800_microsteps(self):
        profile = persona.training_profile(self.cfg, "dgx", True)
        self.assertEqual(profile["steps"], 50)
        self.assertEqual(profile["gradient_accumulation"], 1)
        self.assertEqual(profile["max_tokens"], 512)
        self.assertEqual(persona.training_profile(self.cfg, "dgx", True, True)["steps"], 1)

    def test_formal_training_retains_original_accumulation(self):
        self.assertEqual(persona.training_profile(self.cfg, "dgx", False)["gradient_accumulation"], 16)

    def test_dgx_allows_resident_servers_only_with_peak_budget(self):
        budget = {"version": 2, "verified": True, "kind": "measured_peak", "base_revision": self.cfg["base_revision"], "run_fingerprint": run_fingerprint(self.cfg, "dgx", "model"), "model_index_sha256": "model", "estimated_peak_gib": 70, "expires_at": 1100, "preparation": self.cfg["dgx"]["preparation"]}
        self.assertTrue(dgx_budget_gate(self.cfg, 100, 200, 2, 0, budget, "model", 1000)["allowed"])
        self.assertFalse(dgx_budget_gate(self.cfg, 80, 200, 2, 0, budget, "model", 1000)["allowed"])
        self.assertFalse(dgx_budget_gate(self.cfg, 100, 200, 90, 0, budget, "model", 1000)["allowed"])
        self.assertFalse(dgx_budget_gate(self.cfg, 100, 200, 2, 1, budget, "model", 1000)["allowed"])

    def test_dgx_meta_lower_bound_is_not_a_verified_peak(self):
        budget = {"source": "meta_only", "base_lower_bound_gib": 62.1, "verified": False}
        result = dgx_budget_gate(self.cfg, 64, 200, 0, 0, budget, "model", 1000)
        self.assertFalse(result["allowed"])
        self.assertIn("missing_or_invalid_memory_budget", result["reasons"])
        self.assertIn("minimum_base_plus_16_gib_exceeds_available_ram", result["reasons"])

    def test_existing_destination_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            with self.assertRaises(ValueError): check_destination(source, source, 0)

    def test_pending_corpus_never_approved_by_export(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {"MIKU_TRAINING_ROOT": temp}):
            persona.write_jsonl(Path(temp)/"data/candidates.jsonl", rows())
            report = persona.prepare(self.cfg)
            self.assertFalse(report["training_approved"])
            self.assertEqual(report["pending"], 300)


if __name__ == "__main__": unittest.main()
