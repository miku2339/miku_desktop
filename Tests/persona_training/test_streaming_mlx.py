import copy
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/persona_training"))
import streaming_mlx as stream


def tiny_config(tied=False):
    return {"architectures": [stream.ARCHITECTURE], "model_type": "qwen3_5_moe", "dtype": "bfloat16",
        "text_config": {"model_type": "qwen3_5_moe_text", "hidden_size": 64, "num_hidden_layers": 4,
            "num_attention_heads": 4, "num_key_value_heads": 2, "head_dim": 16,
            "linear_num_value_heads": 4, "linear_num_key_heads": 4, "linear_key_head_dim": 16,
            "linear_value_head_dim": 16, "linear_conv_kernel_dim": 4, "num_experts": 2,
            "num_experts_per_tok": 1, "shared_expert_intermediate_size": 32, "moe_intermediate_size": 32,
            "rms_norm_eps": 1e-6, "vocab_size": 128, "max_position_embeddings": 128,
            "tie_word_embeddings": tied, "attention_bias": False, "full_attention_interval": 4,
            "rope_parameters": {"type": "default", "mrope_section": [2, 3, 3], "rope_theta": 10000.0,
                "partial_rotary_factor": 1.0}},
        "vision_config": {"model_type": "qwen3_5_moe", "hidden_size": 32, "intermediate_size": 64,
            "out_hidden_size": 64, "depth": 1, "num_heads": 4, "patch_size": 4, "in_channels": 3,
            "temporal_patch_size": 2, "spatial_merge_size": 2, "num_position_embeddings": 16,
            "deepstack_visual_indexes": []}}


def metadata(config, headers):
    files = {name: {"bytes": sum(math.prod(item["shape"]) * 2 for item in header.values()) + 16384,
        "sha256": "a" * 64, "tensors": header} for name, header in headers.items()}
    return {"version": 1, "base_model": stream.BASE, "base_revision": stream.REVISION,
        "architecture": stream.ARCHITECTURE, "config": copy.deepcopy(config), "config_sha256": "b" * 64,
        "index_sha256": "c" * 64, "index": {"weight_map": {key: name for name, header in headers.items() for key in header}},
        "files": files}


class StreamingPlanTests(unittest.TestCase):
    def setUp(self):
        self.config = tiny_config()
        shapes = stream.expected_hf_shapes(self.config)
        self.manifest = metadata(self.config, {"model-1.safetensors": {key: {"dtype": "BF16", "shape": shape} for key, shape in shapes.items()}})

    def test_complete_fused_layout_is_required(self):
        plan = stream.plan_conversion(self.manifest)
        self.assertEqual(plan["source_tensor_count"], len(stream.expected_hf_shapes(self.config)))
        self.assertFalse(plan["acceptance_passed"])
        for key, value in [("base_revision", "0" * 40), ("architecture", "OtherModel")]:
            altered = copy.deepcopy(self.manifest); altered[key] = value
            with self.assertRaises(ValueError): stream.plan_conversion(altered)
        altered = copy.deepcopy(self.manifest)
        key = "model.language_model.layers.0.mlp.experts.gate_up_proj"
        altered["files"]["model-1.safetensors"]["tensors"].pop(key)
        with self.assertRaises(ValueError): stream.plan_conversion(altered)

    def test_size_paths_dtypes_and_exact_index_fail_closed(self):
        for change in ["oversize", "path", "dtype", "shape", "extra", "quantized"]:
            with self.subTest(change=change):
                altered = copy.deepcopy(self.manifest)
                file = altered["files"]["model-1.safetensors"]
                tensor = next(iter(file["tensors"]))
                if change == "oversize": file["bytes"] = stream.MAX_SHARD_BYTES + 1
                elif change == "path": altered["files"]["../escape.safetensors"] = altered["files"].pop("model-1.safetensors")
                elif change == "dtype": file["tensors"][tensor]["dtype"] = "F32"
                elif change == "shape": file["tensors"][tensor]["shape"] = [True]
                elif change == "extra": altered["index"]["weight_map"]["unknown.weight"] = "model-1.safetensors"
                elif change == "quantized": altered["config"]["quantization_config"] = {"mode": "nvfp4"}
                with self.assertRaises(ValueError): stream.plan_conversion(altered)

    def test_tied_head_and_frozen_mtp_have_explicit_policies(self):
        altered = copy.deepcopy(self.manifest)
        altered["config"]["text_config"]["tie_word_embeddings"] = True
        self.assertTrue(stream.plan_conversion(altered)["tied_head_dropped"])
        header = altered["files"]["model-1.safetensors"]["tensors"]
        for key in stream._mtp_keys():
            header[key] = {"dtype": "BF16", "shape": [2, 2]}
            altered["index"]["weight_map"][key] = "model-1.safetensors"
        self.assertEqual(stream.plan_conversion(altered)["dropped_mtp_tensors"], 19)
        header["mtp.unknown.weight"] = {"dtype": "BF16", "shape": [2, 2]}
        altered["index"]["weight_map"]["mtp.unknown.weight"] = "model-1.safetensors"
        with self.assertRaises(ValueError): stream.plan_conversion(altered)


@unittest.skipUnless(os.environ.get("MIKU_TEST_MLX_CPU") == "1", "Use the isolated Mac MLX environment for tiny CPU fixtures")
class StreamingEquivalenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import mlx.core as mx
        cls.mx, cls.previous_device = mx, mx.default_device()
        mx.set_default_device(mx.cpu)

    @classmethod
    def tearDownClass(cls):
        cls.mx.synchronize(); cls.mx.clear_cache(); cls.mx.set_default_device(cls.previous_device)

    def fixture(self, root, tied=False):
        from safetensors import safe_open
        mx = self.mx
        config = tiny_config(tied)
        shapes = stream.expected_hf_shapes(config)
        if tied: shapes["lm_head.weight"] = [128, 64]
        shapes.update({key: [2, 2] for key in stream._mtp_keys()})
        weights = {key: ((mx.arange(math.prod(shape), dtype=mx.float32).reshape(shape) + number) % 37 / 37 - 0.5).astype(mx.bfloat16)
            for number, (key, shape) in enumerate(sorted(shapes.items()))}
        mx.eval(weights)
        source = root / "source"; source.mkdir()
        groups = [{}, {}, {}]
        for key, value in weights.items():
            group = 0 if ".gate_up_proj" in key else 1 if ".down_proj" in key else 2
            groups[group][key] = value
        headers = {}
        for i, group in enumerate(groups):
            name = f"model-{i + 1}.safetensors"
            mx.save_safetensors(str(source / name), group, metadata={"format": "pt"})
            with safe_open(source / name, framework="np") as handle:
                headers[name] = {key: {"dtype": handle.get_slice(key).get_dtype(), "shape": handle.get_slice(key).get_shape()} for key in handle.keys()}
        manifest = metadata(config, headers)
        for name, entry in manifest["files"].items():
            entry["bytes"] = (source / name).stat().st_size
            entry["sha256"] = hashlib.sha256((source / name).read_bytes()).hexdigest()
        cache = root / "cache"; cache.mkdir(mode=0o700)
        (cache / stream.CACHE_MARKER).write_text('{"token":"input-owner"}')
        output = root / "candidate"; output.mkdir(mode=0o700)
        (output / ".miku-export-pending.json").write_text('{"token":"output-owner"}')
        identity = (output.stat().st_dev, output.stat().st_ino)
        events = []
        def acquire(name):
            self.assertFalse(any(cache.glob("*.safetensors")))
            events.append(("acquire", name))
            partial = cache / (name + ".partial")
            shutil.copyfile(source / name, partial)
            partial.rename(cache / name)
            return cache / name
        def release(name, path):
            self.assertEqual(path.parent, cache)
            events.append(("release", name)); path.unlink()
        return config, weights, manifest, source, cache, output, identity, acquire, release, events

    def test_cross_shard_experts_vision_norm_mtp_and_tied_head_match_official(self):
        from mlx.utils import tree_flatten
        from mlx_vlm.convert import _record_conversion_dtype
        from mlx_vlm.models.qwen3_5_moe import Model, ModelConfig, VisionModel
        from mlx_vlm.quant_utils import quantize_model
        from mlx_vlm.utils import skip_multimodal_module
        from safetensors import safe_open
        mx = self.mx
        for tied in [False, True]:
            with self.subTest(tied=tied), tempfile.TemporaryDirectory(prefix="miku-stream-mlx-") as temporary:
                config, weights, manifest, source, cache, output, identity, acquire, release, events = self.fixture(Path(temporary), tied)
                model = Model(ModelConfig.from_dict(copy.deepcopy(config)))
                sanitized = VisionModel.sanitize(None, model.sanitize(dict(weights)))
                model.load_weights(list(sanitized.items()), strict=True)
                predicate = model.quant_predicate
                def official_predicate(path, module):
                    return False if skip_multimodal_module(path) else predicate(path, module)
                model, gold_config = quantize_model(model, copy.deepcopy(config), 16, 4, mode="nvfp4", quant_predicate=official_predicate)
                _record_conversion_dtype(gold_config, "bfloat16")
                gold = dict(tree_flatten(model.parameters())); mx.eval(gold); mx.synchronize()
                result = stream.convert_shards(manifest, acquire, release, output, cache_root=cache,
                    owner_identity=identity, owner_token="output-owner")
                actual = {}
                for path in sorted(output.glob("*.safetensors")):
                    with safe_open(path, framework="np") as handle: self.assertEqual(handle.metadata(), {"format": "mlx"})
                    actual.update(mx.load(str(path)))
                self.assertEqual(set(actual), set(gold))
                for key in gold:
                    self.assertEqual(actual[key].dtype, gold[key].dtype, key)
                    self.assertEqual(actual[key].shape, gold[key].shape, key)
                    self.assertTrue(bool(mx.array_equal(actual[key].view(mx.uint8), gold[key].view(mx.uint8))), key)
                self.assertEqual(json.loads((output / "config.json").read_text()), gold_config)
                index = json.loads((output / "model.safetensors.index.json").read_text())
                self.assertEqual(index["metadata"]["total_size"], sum(value.nbytes for value in actual.values()))
                self.assertEqual(set(index["weight_map"]), set(gold))
                self.assertEqual(events, [item for name in sorted(manifest["files"]) for item in [("acquire", name), ("release", name)]])
                self.assertEqual({p.name for p in cache.iterdir()}, {stream.CACHE_MARKER})
                self.assertEqual(result["dropped_mtp_tensors"], 19)
                self.assertFalse(result["acceptance_passed"])
                self.assertTrue((output / ".miku-export-pending.json").exists())

    def test_cancel_releases_the_only_cache_and_keeps_pending_candidate(self):
        with tempfile.TemporaryDirectory(prefix="miku-stream-cancel-") as temporary:
            _, _, manifest, source, cache, output, identity, acquire, release, events = self.fixture(Path(temporary))
            def guard():
                if any(output.glob("*.safetensors")): raise RuntimeError("activity resumed")
            with self.assertRaisesRegex(RuntimeError, "activity resumed"):
                stream.convert_shards(manifest, acquire, release, output, cache_root=cache,
                    owner_identity=identity, owner_token="output-owner", guard=guard)
            self.assertEqual(events[:2], [("acquire", "model-1.safetensors"), ("release", "model-1.safetensors")])
            self.assertEqual({p.name for p in cache.iterdir()}, {stream.CACHE_MARKER})
            self.assertTrue((output / ".miku-export-pending.json").exists())
            self.assertFalse(any(p.name.startswith(".stream-") for p in output.iterdir()))

    def test_hash_failure_releases_input_before_any_output(self):
        with tempfile.TemporaryDirectory(prefix="miku-stream-fingerprint-") as temporary:
            _, _, manifest, _, cache, output, identity, acquire, release, events = self.fixture(Path(temporary))
            manifest["files"]["model-1.safetensors"]["sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "fingerprint"):
                stream.convert_shards(manifest, acquire, release, output, cache_root=cache,
                    owner_identity=identity, owner_token="output-owner")
            self.assertEqual({p.name for p in cache.iterdir()}, {stream.CACHE_MARKER})
            self.assertEqual({p.name for p in output.iterdir()}, {".miku-export-pending.json"})

    def test_non_finite_verified_input_is_not_quantized(self):
        mx = self.mx
        with tempfile.TemporaryDirectory(prefix="miku-stream-finite-") as temporary:
            _, _, manifest, source, cache, output, identity, acquire, release, _ = self.fixture(Path(temporary))
            name = "model-1.safetensors"
            values = mx.load(str(source / name))
            key = next(iter(values)); values[key] = mx.full(values[key].shape, float("nan"), dtype=mx.bfloat16)
            mx.save_safetensors(str(source / name), values, metadata={"format": "pt"})
            manifest["files"][name]["bytes"] = (source / name).stat().st_size
            manifest["files"][name]["sha256"] = hashlib.sha256((source / name).read_bytes()).hexdigest()
            values.clear(); mx.synchronize(); mx.clear_cache()
            with self.assertRaisesRegex(ValueError, "Non-finite"):
                stream.convert_shards(manifest, acquire, release, output, cache_root=cache,
                    owner_identity=identity, owner_token="output-owner")
            self.assertEqual({p.name for p in cache.iterdir()}, {stream.CACHE_MARKER})
            self.assertEqual({p.name for p in output.iterdir()}, {".miku-export-pending.json"})


if __name__ == "__main__": unittest.main()
