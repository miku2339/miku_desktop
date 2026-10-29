import builtins
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/persona_training"))
import tiny_training_probe as probe
import persona


class TinyTrainingProbeTests(unittest.TestCase):
    def test_resource_gate_rejects_low_ram_inactive_and_missing_services(self):
        valid = {unit: "active" for unit in probe.UNITS}
        probe.resource_gate(48, valid)
        for memory, states in [(47.99, valid), (64, {**valid, probe.UNITS[0]: "inactive"}),
                               (64, {probe.UNITS[0]: "active"})]:
            with self.assertRaises(ValueError): probe.resource_gate(memory, states)

    def test_gate_runs_before_torch_or_weight_loading(self):
        original = builtins.__import__
        def guarded(name, *args, **kwargs):
            if name in ["torch", "transformers", "trl"]: self.fail("Rejected probe imported model libraries")
            return original(name, *args, **kwargs)
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {"MIKU_TRAINING_ROOT": temporary}), \
             patch.object(probe.sys, "platform", "linux"), patch.object(probe, "available_memory", return_value=47), \
             patch.object(probe, "service_state", return_value={unit: "active" for unit in probe.UNITS}), \
             patch("builtins.__import__", side_effect=guarded):
            with self.assertRaises(ValueError):
                probe.run(persona.config(), Path("not-read"), Path(temporary) / "reports/probe.json")

    def test_config_preserves_official_vocab_and_special_tokens_but_only_tiny_dimensions(self):
        official = {"text_config": {"vocab_size": 248320}, "image_token_id": 248056,
            "video_token_id": 248057, "vision_start_token_id": 248053, "vision_end_token_id": 248054}
        tiny = probe.synthetic_config(official)
        self.assertEqual(tiny["text_config"]["num_hidden_layers"], 40)
        self.assertEqual(tiny["text_config"]["hidden_size"], 64)
        self.assertEqual(tiny["text_config"]["vocab_size"], 248320)
        self.assertEqual(tiny["image_token_id"], 248056)
        self.assertEqual(tiny["vision_config"]["depth"], 2)
        official["text_config"]["vocab_size"] = 500000
        with self.assertRaises(ValueError): probe.synthetic_config(official)

    def test_synthetic_examples_use_exact_completion_helper_and_never_read_corpus(self):
        rows = []
        def tokenize(tokenizer, row, length):
            rows.append(row)
            self.assertEqual(length, 128)
            self.assertEqual(json.loads(row["completion"][0]["content"])["text"], "Hello!")
            return {"input_ids": [1, 2], "completion_mask": [0, 1], "labels": [-100, 2]}
        with patch.object(probe, "tokenize_completion", side_effect=tokenize):
            result = probe.synthetic_rows(object())
        self.assertEqual(len(result), 2)
        self.assertEqual([row["prompt"][-1]["content"] for row in rows], ["Hello", "Hi"])

    def test_dry_run_does_not_read_metadata_import_gpu_or_mutate_services(self):
        result = subprocess.run([sys.executable, probe.__file__, "--metadata", "does-not-exist", "--output", "unused.json"],
            capture_output=True, text=True, check=True)
        report = json.loads(result.stdout)
        self.assertTrue(report["dry_run"])
        self.assertFalse(report["would_load_full_weights"])
        self.assertFalse(report["would_change_services"])
        self.assertEqual(report["allocator_cap_bytes"], 256 * 2**20)


if __name__ == "__main__": unittest.main()
