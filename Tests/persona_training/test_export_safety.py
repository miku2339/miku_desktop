import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/persona_training"))
import export_model as export
from persona import config, write_report


def model(path):
    path.mkdir()
    write_report(path / "config.json", {"architectures": ["Qwen3_5MoeForConditionalGeneration"], "vision_config": {"depth": 1}})
    write_report(path / "model.safetensors.index.json", {"weight_map": {"model.visual.weight": "model.safetensors"}})
    (path / "model.safetensors").write_bytes(b"tiny-structural-fixture-not-loaded")
    for name in ["preprocessor_config.json", "tokenizer.json", "tokenizer_config.json"]:
        write_report(path / name, {})
    (path / "chat_template.jinja").write_text("test template")


class ExportSafetyTests(unittest.TestCase):
    def setUp(self): self.cfg = config()

    def observation(self):
        return {"now": 1000, "platform": "darwin", "ac_power": True, "idle_seconds": 601, "available_ram_gib": 45, "memory_pressure": "normal", "free_disk_gib": 80, "voice_state_live": True, "voice_state": {"version": 1, "active": False, "updated_at": 990}}

    def test_runtime_checks_call_idle_power_pressure_ram_and_actual_disk(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp) / "new"
            for key, value in [("ac_power", False), ("idle_seconds", 1), ("memory_pressure", "warning"), ("available_ram_gib", 17), ("free_disk_gib", 29)]:
                observation = self.observation(); observation[key] = value
                with patch.object(export, "mac_observations", return_value=observation), patch.object(export.shutil, "disk_usage", return_value=Mock(free=80*2**30)):
                    self.assertFalse(export.export_resources("convert-mlx", self.cfg, destination)["allowed"])
            observation = self.observation(); observation["voice_state"]["active"] = True
            with patch.object(export, "mac_observations", return_value=observation):
                self.assertFalse(export.export_resources("fuse-mac", self.cfg, destination)["allowed"])
            observation = self.observation(); observation["available_ram_gib"] = 20
            with patch.object(export, "mac_observations", return_value=observation), patch.object(export.shutil, "disk_usage", return_value=Mock(free=80*2**30)):
                self.assertTrue(export.export_resources("convert-mlx", self.cfg, destination)["allowed"])
                self.assertFalse(export.export_resources("convert-mlx", self.cfg, destination, True)["allowed"])
            with patch.object(export, "mac_observations", return_value=self.observation()), patch.object(export.shutil, "disk_usage", return_value=Mock(free=29*2**30)):
                self.assertFalse(export.export_resources("convert-mlx", self.cfg, destination)["allowed"])

    def test_pending_export_and_missing_processor_are_not_usable(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source"; model(source)
            write_report(source / export.PENDING, {"token": "owned"})
            with self.assertRaises(ValueError): export.verify_vlm(source)
            (source / export.PENDING).unlink()
            (source / "chat_template.jinja").unlink()
            with self.assertRaises(ValueError): export.verify_vlm(source)

    def test_hf_merge_retains_ram_and_destination_disk_during_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp) / "new"
            for available, preflight, allowed in [(89, True, False), (90, True, True), (20, False, True), (17, False, False)]:
                with patch.object(Path, "read_text", return_value=f"MemAvailable: {available*2**20} kB\n"), patch.object(export.shutil, "disk_usage", return_value=Mock(free=100*2**30)):
                    self.assertEqual(export.export_resources("merge-hf", self.cfg, destination, preflight)["allowed"], allowed)
            with patch.object(Path, "read_text", return_value=f"MemAvailable: {100*2**20} kB\n"), patch.object(export.shutil, "disk_usage", return_value=Mock(free=29*2**30)):
                self.assertFalse(export.export_resources("merge-hf", self.cfg, destination)["allowed"])

    def test_sharded_merge_preflight_uses_its_bound_and_keeps_the_runtime_reserve(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp) / "new"
            for available, preflight, allowed in [(31, True, False), (32, True, True), (18, False, True), (17, False, False)]:
                with patch.object(Path, "read_text", return_value=f"MemAvailable: {available*2**20} kB\n"), patch.object(export.shutil, "disk_usage", return_value=Mock(free=100*2**30)):
                    result = export.export_resources("merge-hf", self.cfg, destination, preflight,
                        required_preflight_ram_gib=32)
                    self.assertEqual(result["allowed"], allowed)

    def test_hf_adapter_naming_a_different_base_is_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source"; model(source)
            adapter = Path(temp) / "adapter"; adapter.mkdir()
            write_report(adapter / "adapter_config.json", {"base_model_name_or_path": str(Path(temp) / "other")})
            with self.assertRaisesRegex(ValueError, "exact original HF base"):
                export.hf_merge_plan(source, adapter, self.cfg)

    def test_production_and_nested_destinations_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source"; model(source)
            with self.assertRaises(ValueError): export.check_destination(source / "new", source, 0)
            alias = Path(temp) / "alias"; alias.symlink_to(source)
            with self.assertRaises(ValueError): export.check_destination(alias, source, 0)
            self.assertTrue((source / "model.safetensors").exists())

    def test_one_mac_candidate_slot_preserves_existing_candidate(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {"MIKU_TRAINING_ROOT": temp}):
            destination = Path(temp) / "candidates/new"
            with export.candidate_slot(self.cfg, destination): pass
            existing = destination.parent / "existing"; existing.mkdir()
            with self.assertRaises(ValueError):
                with export.candidate_slot(self.cfg, destination): pass
            self.assertTrue(existing.exists())
            with self.assertRaises(ValueError):
                with export.candidate_slot(self.cfg, Path(temp) / "outside"): pass

    def test_cleanup_requires_the_owned_directory_and_preserves_acceptance(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp) / "new"; destination.mkdir(); stat = destination.stat(); identity = (stat.st_dev, stat.st_ino)
            write_report(destination / export.PENDING, {"token": "ours"})
            with self.assertRaises(RuntimeError): export.discard_incomplete(destination, identity, "someone_else")
            write_report(destination / "miku-export-receipt.json", {"export_token": "ours", "acceptance_passed": True})
            with self.assertRaises(RuntimeError): export.discard_incomplete(destination, identity, "ours")
            self.assertTrue(destination.exists())
            write_report(destination / "miku-export-receipt.json", {"export_token": "source_export", "acceptance_passed": True})
            export.discard_incomplete(destination, identity, "ours")
            self.assertFalse(destination.exists())

    def test_real_tiny_child_is_cancelled_and_only_its_partial_export_removed(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source"; model(source)
            destination = Path(temp) / "new"
            child_pid = Path(temp) / "child-pid"
            command = [sys.executable, "-c", "import os,pathlib,sys,time;pathlib.Path(sys.argv[2]).write_text(str(os.getpid()));(pathlib.Path(sys.argv[1])/'partial.bin').write_bytes(b'partial');time.sleep(30)", str(destination), str(child_pid)]
            def resources(*args, **kwargs):
                deny = (destination / "partial.bin").exists()
                return {"allowed": not deny, "reasons": ["voice_call_active_or_unknown"] if deny else [], "available_ram_gib": 50}
            with patch.object(export, "export_resources", side_effect=resources), patch.object(export.shutil, "disk_usage", return_value=Mock(free=200*2**30)):
                with self.assertRaises(RuntimeError): export.guarded_export("convert-mlx", source, None, destination, self.cfg, command=command, poll_seconds=0.01)
            self.assertFalse(destination.exists())
            self.assertEqual((source / "model.safetensors").read_bytes(), b"tiny-structural-fixture-not-loaded")
            with self.assertRaises(ProcessLookupError): os.kill(int(child_pid.read_text()), 0)

    def test_partial_success_receipt_does_not_leave_owned_unaccepted_weights(self):
        with tempfile.TemporaryDirectory() as temp:
            for contents in ['{"acceptance_passed":', '[]']:
                destination = Path(temp) / "new"; destination.mkdir()
                stat = destination.stat(); identity = (stat.st_dev, stat.st_ino)
                write_report(destination / export.PENDING, {"token": "ours"})
                (destination / "miku-export-receipt.json").write_text(contents)
                (destination / "partial.safetensors").write_bytes(b"owned partial weights")
                export.discard_incomplete(destination, identity, "ours")
                self.assertFalse(destination.exists())

    def test_success_requires_complete_vlm_and_stays_pending_quality(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source"; model(source)
            destination = Path(temp) / "new"
            command = [sys.executable, "-c", "import json,pathlib,shutil,sys;shutil.copytree(sys.argv[1],sys.argv[2],dirs_exist_ok=True);(pathlib.Path(sys.argv[2])/sys.argv[3]).write_text(json.dumps({'format':'tiny-test-fixture'}))", str(source), str(destination), export.RESULT]
            with patch.object(export, "export_resources", return_value={"allowed": True, "reasons": [], "available_ram_gib": 50}), patch.object(export.shutil, "disk_usage", return_value=Mock(free=200*2**30)):
                result = export.guarded_export("convert-mlx", source, None, destination, self.cfg, command=command, poll_seconds=0.01)
            self.assertFalse(result["acceptance_passed"])
            self.assertFalse(result["for_deployment"])
            self.assertEqual(result["status"], "complete_pending_quality_review")
            self.assertFalse((destination / export.PENDING).exists())
            self.assertEqual(export.verify_vlm(destination)["vision_tensors"], 1)

    def test_worker_failure_cleans_new_directory_but_keeps_source(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source"; model(source)
            destination = Path(temp) / "new"
            for code in [0, 3]:
                with patch.object(export, "export_resources", return_value={"allowed": True, "reasons": [], "available_ram_gib": 50}), patch.object(export.shutil, "disk_usage", return_value=Mock(free=200*2**30)):
                    with self.assertRaises((RuntimeError, OSError)):
                        export.guarded_export("convert-mlx", source, None, destination, self.cfg, command=[sys.executable, "-c", f"raise SystemExit({code})"], poll_seconds=0.01)
                self.assertFalse(destination.exists())
                self.assertTrue((source / "model.safetensors").exists())

    def test_marker_write_failure_cleans_only_the_exclusively_created_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source"; model(source)
            destination = Path(temp) / "new"
            with patch.object(export, "export_resources", return_value={"allowed": True, "reasons": [], "available_ram_gib": 50}), patch.object(export.shutil, "disk_usage", return_value=Mock(free=200*2**30)), patch.object(export, "write_report", side_effect=OSError("disk write failed")):
                with self.assertRaises(OSError): export.guarded_export("convert-mlx", source, None, destination, self.cfg, command=[sys.executable, "-c", "pass"])
            self.assertFalse(destination.exists())
            self.assertTrue(source.exists())


if __name__ == "__main__": unittest.main()
