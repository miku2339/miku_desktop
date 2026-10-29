import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/persona_training"))
import sharded_merge as merge


def target_names():
    result = []
    for layer in range(40):
        kind, suffixes = ("self_attn", ["q_proj", "k_proj", "v_proj", "o_proj"]) if layer % 4 == 3 else ("linear_attn", ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a", "out_proj"])
        result.extend(f"model.language_model.layers.{layer}.{kind}.{suffix}" for suffix in suffixes)
    return result


def config(names):
    return {"peft_type": "LORA", "task_type": "CAUSAL_LM", "r": 16, "lora_alpha": 32,
        "lora_dropout": 0.0, "fan_in_fan_out": False, "bias": "none", "init_lora_weights": True,
        "use_dora": False, "use_rslora": False, "target_modules": sorted({n.rsplit(".", 1)[1] for n in names}),
        "peft_version": "0.21.2", "base_model_name_or_path": "synthetic-only", "inference_mode": True,
        "use_bdlora": None, "qalora_group_size": 16, "use_qalora": False, "megatron_core": "megatron.core",
        "rank_pattern": {}, "alpha_pattern": {}, "loftq_config": {}, "arrow_config": None}


def save_tensor_fixture(path, entries, metadata=None):
    header, payload = {}, bytearray()
    for name, (dtype, shape) in entries.items():
        size = merge.WIDTHS[dtype]
        for count in shape: size *= count
        header[name] = {"dtype": dtype, "shape": shape, "data_offsets": [len(payload), len(payload) + size]}
        payload.extend(bytes(size))
    if metadata is not None: header["__metadata__"] = metadata
    raw = json.dumps(header, separators=(",", ":")).encode()
    raw += b" " * (-len(raw) % 8)
    path.write_bytes(struct.pack("<Q", len(raw)) + raw + payload)


class ShardedMergeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="miku-sharded-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"; self.source.mkdir()
        self.adapter = self.root / "adapter"; self.adapter.mkdir()
        self.names = target_names()
        groups = [{}, {}, {}]; mapping = {}
        for index, name in enumerate(self.names + ["model.visual.proj", "lm_head"]):
            key, shard = name + ".weight", f"model-{index % 3}.safetensors"
            groups[index % 3][key] = ("BF16", [17, 16]); mapping[key] = shard
        self.index = self.source / "model.safetensors.index.json"
        self.index.write_text(json.dumps({"metadata": {"fixture": "synthetic"}, "weight_map": mapping}))
        for index, group in enumerate(groups):
            save_tensor_fixture(self.source / f"model-{index}.safetensors", group, {"format": "pt", "fixture": "synthetic"})
        entries = {}
        for name in self.names:
            entries[f"base_model.model.{name}.lora_A.weight"] = ("F32", [16, 16])
            entries[f"base_model.model.{name}.lora_B.weight"] = ("F32", [17, 16])
        save_tensor_fixture(self.adapter / "adapter_model.safetensors", entries)
        self.configuration = self.adapter / "adapter_config.json"
        self.configuration.write_text(json.dumps(config(self.names)))
        self.destination = self.root / "new"; self.destination.mkdir()
        (self.destination / merge.PENDING).write_text('{"token":"ours"}')
        stat = self.destination.stat(); self.owner = (stat.st_dev, stat.st_ino)

    def plan(self): return merge.plan_merge(self.source, self.adapter, self.names)

    def run_merge(self, **kwargs):
        return merge.merge_shards(self.source, self.adapter, self.destination, self.names,
            owner_identity=self.owner, owner_token="ours", **kwargs)

    def test_header_only_plan_keeps_a_conservative_16_gib_reserve(self):
        result = self.plan()
        self.assertEqual(result["target_count"], 190)
        self.assertEqual(result["shard_count"], 3)
        self.assertEqual(result["required_available_ram_gib"], result["estimated_working_set_gib"] + 16)
        self.assertGreater(result["estimated_working_set_gib"], 2)

    def test_exact_count_names_pairs_shapes_and_dtypes_are_required(self):
        for names in [self.names[:-1], self.names + [self.names[0]], self.names[:-1] + ["model.visual.q_proj"]]:
            with self.assertRaises(ValueError): merge.plan_merge(self.source, self.adapter, names)
        path = self.adapter / "adapter_model.safetensors"
        original = path.read_bytes()
        for entries in [
            {"base_model.model." + self.names[0] + ".lora_A.weight": ("F32", [16, 16])},
            {"base_model.model." + self.names[0] + ".lora_A.weight": ("F32", [17, 16])},
            {"base_model.model." + self.names[0] + ".lora_A.weight": ("I32", [16, 16])},
            {"base_model.model.model.visual.q_proj.lora_A.weight": ("F32", [16, 16])},
        ]:
            save_tensor_fixture(path, entries)
            with self.assertRaises(ValueError): self.plan()
        path.write_bytes(original)

    def test_extra_transformations_and_changed_initialization_fail_closed(self):
        valid = config(self.names)
        for key, value in [("use_dora", True), ("use_rslora", True), ("use_bdlora", True),
                ("lora_bias", True), ("target_parameters", ["weight"]), ("rank_pattern", {"q_proj": 8}),
                ("loftq_config", {"loftq_bits": 4}), ("alora_invocation_tokens", [1]),
                ("layer_replication", [[0, 2]]), ("arrow_config", {"top_k": 2}),
                ("future_transformation", "enabled"), ("init_lora_weights", "pissa"),
                ("lora_dropout", False), ("r", True), ("bias", "all")]:
            with self.subTest(key=key):
                self.configuration.write_text(json.dumps({**valid, key: value}))
                with self.assertRaises(ValueError): self.plan()
        self.configuration.write_text(json.dumps(valid))
        self.assertEqual(self.plan()["target_count"], 190)

    def test_suffixes_must_expand_to_exactly_the_approved_modules(self):
        value = config(self.names); value["target_modules"] = self.names
        self.configuration.write_text(json.dumps(value)); self.plan()
        value["target_modules"] = ["q_proj"]
        self.configuration.write_text(json.dumps(value))
        with self.assertRaises(ValueError): self.plan()
        self.configuration.write_text(json.dumps(config(self.names)))
        index = json.loads(self.index.read_text())
        index["weight_map"]["model.visual.q_proj.weight"] = "extra.safetensors"
        self.index.write_text(json.dumps(index))
        save_tensor_fixture(self.source / "extra.safetensors", {"model.visual.q_proj.weight": ("BF16", [17, 16])})
        with self.assertRaises(ValueError): self.plan()

    def test_index_paths_missing_extra_tensors_and_symlinks_are_rejected(self):
        original = self.index.read_text()
        for shard in ["../escape.safetensors", "/outside.safetensors", "missing.safetensors"]:
            value = json.loads(original); value["weight_map"][self.names[0] + ".weight"] = shard
            self.index.write_text(json.dumps(value))
            with self.assertRaises(ValueError): self.plan()
        self.index.write_text(original)
        shard = self.source / "model-0.safetensors"
        moved = self.source / "original.bin"; shard.rename(moved); shard.symlink_to(moved)
        with self.assertRaises(ValueError): self.plan()

    def test_compressed_selectors_may_leave_the_official_mtp_head_frozen(self):
        index = json.loads(self.index.read_text())
        entries = {name + ".weight": ("BF16", [17, 16]) for name in merge.FROZEN_MTP_TARGETS}
        index["weight_map"].update({key: "mtp.safetensors" for key in entries})
        self.index.write_text(json.dumps(index))
        save_tensor_fixture(self.source / "mtp.safetensors", entries)
        self.assertEqual(self.plan()["target_count"], 190)
        original = (self.adapter / "adapter_model.safetensors").read_bytes()
        with self.assertRaises(ValueError):
            save_tensor_fixture(self.adapter / "adapter_model.safetensors", {
                "base_model.model.mtp.layers.0.self_attn.q_proj.lora_A.weight": ("F32", [16, 16])})
            self.plan()
        (self.adapter / "adapter_model.safetensors").write_bytes(original)

    def test_malformed_duplicate_or_oversized_headers_and_non_bf16_source_fail(self):
        path = self.source / "model-0.safetensors"; original = path.read_bytes()
        for raw in [b'{"x":{},"x":{}}', b'[]',
                b'{"x":{"dtype":"BF16","shape":[true],"data_offsets":[0,2]}}',
                b'{"x":{"dtype":[],"shape":[1],"data_offsets":[0,2]}}',
                b'{"x":{"dtype":"BF16","shape":[1],"data_offsets":[1,3]}}',
                b'{"x":{"dtype":"BF16","shape":[1],"data_offsets":[0,2]},"y":{"dtype":"BF16","shape":[1],"data_offsets":[0,2]}}']:
            path.write_bytes(struct.pack("<Q", len(raw)) + raw + b"\0\0")
            with self.assertRaises(ValueError): self.plan()
        path.write_bytes(struct.pack("<Q", merge.MAX_HEADER_BYTES + 1))
        with self.assertRaises(ValueError): self.plan()
        path.write_bytes(original)
        header, _, _ = merge._header(path)
        entries = {key: ("F32", entry["shape"]) for key, entry in header.items()}
        save_tensor_fixture(path, entries)
        with self.assertRaises(ValueError): self.plan()

    def test_destination_requires_the_owned_token_and_an_otherwise_empty_directory(self):
        with self.assertRaises(RuntimeError):
            merge.merge_shards(self.source, self.adapter, self.destination, self.names, owner_identity=self.owner, owner_token="wrong")
        with self.assertRaises(RuntimeError):
            merge.merge_shards(self.source, self.adapter, self.destination, self.names, owner_identity=(0, 0), owner_token="ours")
        (self.destination / "existing").write_text("preserve")
        with self.assertRaises(ValueError): self.run_merge()
        self.assertEqual((self.destination / "existing").read_text(), "preserve")

    def test_resource_rejection_occurs_before_importing_torch_or_writing_weights(self):
        def denied(): raise RuntimeError("resource reserve reached")
        with self.assertRaisesRegex(RuntimeError, "resource reserve"): self.run_merge(guard=denied)
        self.assertEqual({p.name for p in self.destination.iterdir()}, {merge.PENDING})

    def test_nested_source_destination_is_refused_without_overwriting_inputs(self):
        nested = self.source / "new"; nested.mkdir()
        (nested / merge.PENDING).write_text('{"token":"ours"}')
        stat = nested.stat()
        with self.assertRaises(ValueError):
            merge.merge_shards(self.source, self.adapter, nested, self.names,
                owner_identity=(stat.st_dev, stat.st_ino), owner_token="ours")
        self.assertEqual({p.name for p in nested.iterdir()}, {merge.PENDING})


@unittest.skipUnless(os.environ.get("MIKU_TEST_PEFT") == "1", "Use the existing private Torch/PEFT environment for CPU fixtures")
class PEFTEquivalenceTests(unittest.TestCase):
    def test_three_adapter_dtypes_match_official_cpu_safe_merge_bitwise(self):
        import torch
        from torch import nn
        from peft import LoraConfig, PeftModel, get_peft_model
        from safetensors import safe_open
        from safetensors.torch import save_file
        from transformers import PretrainedConfig

        torch.set_num_threads(1)
        torch.manual_seed(39)
        class Tiny(nn.Module):
            def __init__(self):
                super().__init__(); self.config = PretrainedConfig(); self.model = nn.Module()
                self.model.language_model = nn.Module(); self.model.language_model.layers = nn.ModuleList([nn.Module() for _ in range(40)])
                for name in target_names():
                    _, _, _, number, kind, suffix = name.split(".")
                    layer = self.model.language_model.layers[int(number)]
                    if not hasattr(layer, kind): setattr(layer, kind, nn.Module())
                    setattr(getattr(layer, kind), suffix, nn.Linear(16, 17, bias=False))
                self.model.visual = nn.Linear(3, 4, bias=False); self.lm_head = nn.Linear(16, 5, bias=False)
            def prepare_inputs_for_generation(self, *args, **kwargs): return kwargs
            def forward(self, *args, **kwargs): raise AssertionError("No inference is needed for a merge fixture")
        base = Tiny().bfloat16()
        initial = {name: value.clone() for name, value in base.state_dict().items()}
        self.assertLess(sum(t.numel() * t.element_size() for t in initial.values()), 64 * 2**20)
        with tempfile.TemporaryDirectory(prefix="miku-peft-shards-") as temporary:
            root = Path(temporary); source = root / "source"; source.mkdir()
            groups, mapping = [{}, {}, {}], {}
            for index, (key, value) in enumerate(initial.items()):
                shard = f"model-{index % 3}.safetensors"; groups[index % 3][key] = value; mapping[key] = shard
            for index, group in enumerate(groups): save_file(group, source / f"model-{index}.safetensors", metadata={"format": "pt", "fixture": "synthetic"})
            index_bytes = json.dumps({"weight_map": mapping}).encode()
            (source / "model.safetensors.index.json").write_bytes(index_bytes)
            hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in set(mapping.values())}
            for dtype in [torch.float32, torch.bfloat16, torch.float16]:
                with self.subTest(dtype=dtype):
                    work = root / str(dtype).split(".")[-1]; work.mkdir(); adapter = work / "adapter"; output = work / "new"; output.mkdir()
                    (output / merge.PENDING).write_text('{"token":"ours"}')
                    stat = output.stat()
                    trained = get_peft_model(copy.deepcopy(base), LoraConfig(r=16, lora_alpha=32, target_modules=target_names(), task_type="CAUSAL_LM", bias="none"))
                    for name, parameter in trained.named_parameters():
                        if "lora_" in name: parameter.data = torch.randn(parameter.shape).mul_(0.1).to(dtype)
                    trained.save_pretrained(adapter, safe_serialization=True)
                    gold_base = Tiny().bfloat16(); gold_base.load_state_dict(initial)
                    gold = PeftModel.from_pretrained(gold_base, adapter, local_files_only=True).merge_and_unload(safe_merge=True).state_dict()
                    result = merge.merge_shards(source, adapter, output, target_names(), owner_identity=(stat.st_dev, stat.st_ino), owner_token="ours")
                    self.assertEqual(result["target_count"], 190)
                    self.assertFalse(result["acceptance_passed"])
                    self.assertFalse(result["for_deployment"])
                    for shard in set(mapping.values()):
                        with safe_open(output / shard, framework="pt", device="cpu") as handle:
                            self.assertEqual(handle.metadata(), {"format": "pt", "fixture": "synthetic"})
                            self.assertEqual(set(handle.keys()), {k for k, v in mapping.items() if v == shard})
                            for key in handle.keys(): self.assertTrue(torch.equal(handle.get_tensor(key).view(torch.int16), gold[key].view(torch.int16)), key)
                    self.assertEqual(hashes, {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in hashes})
                    self.assertEqual((source / "model.safetensors.index.json").read_bytes(), index_bytes)
                    self.assertTrue((output / merge.PENDING).exists())
                    cancelled = work / "cancelled"; cancelled.mkdir()
                    (cancelled / merge.PENDING).write_text('{"token":"ours"}')
                    cancelled_stat = cancelled.stat()
                    def cancel_after_first_shard():
                        if any(path.suffix == ".safetensors" for path in cancelled.iterdir()):
                            raise RuntimeError("resource reserve changed")
                    with self.assertRaisesRegex(RuntimeError, "resource reserve changed"):
                        merge.merge_shards(source, adapter, cancelled, target_names(),
                            owner_identity=(cancelled_stat.st_dev, cancelled_stat.st_ino), owner_token="ours", guard=cancel_after_first_shard)
                    self.assertTrue((cancelled / merge.PENDING).exists())
                    self.assertFalse(any(path.name.startswith(".merge-") for path in cancelled.iterdir()))
                    self.assertEqual(hashes, {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in hashes})
                    changed = work / "changed"; changed.mkdir()
                    (changed / merge.PENDING).write_text('{"token":"ours"}')
                    changed_stat = changed.stat()
                    changed_once = []
                    def replace_source_timestamp():
                        if not changed_once:
                            shard = source / next(iter(hashes))
                            previous = shard.stat()
                            os.utime(shard, ns=(previous.st_atime_ns, previous.st_mtime_ns + 1_000_000_000))
                            changed_once.append(True)
                    with self.assertRaisesRegex(RuntimeError, "source changed"):
                        merge.merge_shards(source, adapter, changed, target_names(),
                            owner_identity=(changed_stat.st_dev, changed_stat.st_ino), owner_token="ours", guard=replace_source_timestamp)
                    self.assertEqual({path.name for path in changed.iterdir()}, {merge.PENDING})
                    with torch.no_grad():
                        next(parameter for name, parameter in trained.named_parameters() if "lora_B" in name).fill_(float("nan"))
                    bad_adapter = work / "bad-adapter"; trained.save_pretrained(bad_adapter, safe_serialization=True)
                    invalid = work / "invalid"; invalid.mkdir()
                    (invalid / merge.PENDING).write_text('{"token":"ours"}')
                    invalid_stat = invalid.stat()
                    with self.assertRaisesRegex(ValueError, "Non-finite adapter"):
                        merge.merge_shards(source, bad_adapter, invalid, target_names(),
                            owner_identity=(invalid_stat.st_dev, invalid_stat.st_ino), owner_token="ours")
                    self.assertFalse(any(path.name.startswith(".merge-") for path in invalid.iterdir()))
        self.assertFalse(torch.cuda.is_initialized())


if __name__ == "__main__": unittest.main()
