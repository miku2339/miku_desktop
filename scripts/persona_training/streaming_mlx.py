"""One-shard RTN conversion for the pinned, fused-expert Qwen3.6 HF export."""

from __future__ import annotations

import copy
import gc
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import tempfile
from types import SimpleNamespace

from sharded_merge import _header, _owned


MAX_SHARD_BYTES = 4 * 2**30
BASE = "Qwen/Qwen3.6-35B-A3B"
REVISION = "995ad96eacd98c81ed38be0c5b274b04031597b0"
ARCHITECTURE = "Qwen3_5MoeForConditionalGeneration"
CACHE_MARKER = ".miku-shard-cache.json"


def _positive(value, name):
    if type(value) is not int or not 0 < value <= 1048576:
        raise ValueError("Invalid model dimension: " + name)
    return value


def expected_hf_shapes(config: dict) -> dict[str, list[int]]:
    """The current fused-expert archive; no per-expert or quantized HF layouts."""
    if config.get("architectures") != [ARCHITECTURE] or config.get("model_type") != "qwen3_5_moe":
        raise ValueError("Only the pinned Qwen VLM architecture is supported")
    if config.get("quantization") is not None or config.get("quantization_config") is not None:
        raise ValueError("The source must be the floating-point HF export")
    text, vision = config["text_config"], config["vision_config"]
    if text.get("model_type") != "qwen3_5_moe_text" or vision.get("model_type") != "qwen3_5_moe":
        raise ValueError("Unexpected language or vision architecture")
    if text.get("attention_bias", False) is not False or type(text.get("tie_word_embeddings", False)) is not bool:
        raise ValueError("Unsupported attention or embedding layout")
    if vision.get("deepstack_visual_indexes") not in [None, []]:
        raise ValueError("This Qwen architecture does not use deepstack")
    for section in [text, vision]:
        if section.get("quantization") is not None or section.get("quantization_config") is not None:
            raise ValueError("Nested source quantization is unsupported")
    def dim(section, name, default=None):
        return _positive(section.get(name, default), name)
    h, vocab = dim(text, "hidden_size"), dim(text, "vocab_size")
    layers, interval = dim(text, "num_hidden_layers"), dim(text, "full_attention_interval", 4)
    experts, inter = dim(text, "num_experts"), dim(text, "moe_intermediate_size")
    shared = dim(text, "shared_expert_intermediate_size")
    heads, kv, hd = dim(text, "num_attention_heads"), dim(text, "num_key_value_heads"), dim(text, "head_dim")
    kh, vh = dim(text, "linear_num_key_heads"), dim(text, "linear_num_value_heads")
    kd, vd = dim(text, "linear_key_head_dim"), dim(text, "linear_value_head_dim")
    conv = dim(text, "linear_conv_kernel_dim")
    if layers > 40 or interval != 4 or experts > 256 or vh % kh:
        raise ValueError("Unsupported Qwen layer schedule or expert layout")
    shapes = {"model.language_model.embed_tokens.weight": [vocab, h],
        "model.language_model.norm.weight": [h]}
    if not text.get("tie_word_embeddings", False): shapes["lm_head.weight"] = [vocab, h]
    for layer in range(layers):
        p = f"model.language_model.layers.{layer}"
        shapes.update({f"{p}.input_layernorm.weight": [h], f"{p}.post_attention_layernorm.weight": [h],
            f"{p}.mlp.experts.gate_up_proj": [experts, 2 * inter, h],
            f"{p}.mlp.experts.down_proj": [experts, h, inter], f"{p}.mlp.gate.weight": [experts, h],
            f"{p}.mlp.shared_expert.gate_proj.weight": [shared, h], f"{p}.mlp.shared_expert.up_proj.weight": [shared, h],
            f"{p}.mlp.shared_expert.down_proj.weight": [h, shared], f"{p}.mlp.shared_expert_gate.weight": [1, h]})
        if (layer + 1) % interval:
            p += ".linear_attn"
            channels = 2 * kh * kd + vh * vd
            shapes.update({f"{p}.conv1d.weight": [channels, 1, conv], f"{p}.A_log": [vh], f"{p}.dt_bias": [vh],
                f"{p}.norm.weight": [vd], f"{p}.in_proj_qkv.weight": [channels, h], f"{p}.in_proj_z.weight": [vh * vd, h],
                f"{p}.in_proj_b.weight": [vh, h], f"{p}.in_proj_a.weight": [vh, h], f"{p}.out_proj.weight": [h, vh * vd]})
        else:
            p += ".self_attn"
            shapes.update({f"{p}.q_proj.weight": [2 * heads * hd, h], f"{p}.k_proj.weight": [kv * hd, h],
                f"{p}.v_proj.weight": [kv * hd, h], f"{p}.o_proj.weight": [h, heads * hd],
                f"{p}.q_norm.weight": [hd], f"{p}.k_norm.weight": [hd]})
    d, vi, depth = dim(vision, "hidden_size"), dim(vision, "intermediate_size"), dim(vision, "depth")
    channels, patch, temporal = dim(vision, "in_channels", 3), dim(vision, "patch_size"), dim(vision, "temporal_patch_size", 2)
    merge = dim(vision, "spatial_merge_size", 2)
    if depth > 64 or channels != 3: raise ValueError("Unsupported vision layout")
    p = "model.visual"
    shapes.update({f"{p}.patch_embed.proj.weight": [d, channels, temporal, patch, patch],
        f"{p}.patch_embed.proj.bias": [d], f"{p}.pos_embed.weight": [dim(vision, "num_position_embeddings"), d]})
    for layer in range(depth):
        p = f"model.visual.blocks.{layer}"
        for norm in ["norm1", "norm2"]:
            shapes[f"{p}.{norm}.weight"] = shapes[f"{p}.{norm}.bias"] = [d]
        for name, shape in {"attn.qkv": [3 * d, d], "attn.proj": [d, d],
                "mlp.linear_fc1": [vi, d], "mlp.linear_fc2": [d, vi]}.items():
            shapes[f"{p}.{name}.weight"], shapes[f"{p}.{name}.bias"] = shape, [shape[0]]
    p, merged = "model.visual.merger", d * merge**2
    shapes.update({f"{p}.norm.weight": [d], f"{p}.norm.bias": [d],
        f"{p}.linear_fc1.weight": [merged, merged], f"{p}.linear_fc1.bias": [merged],
        f"{p}.linear_fc2.weight": [dim(vision, "out_hidden_size"), merged],
        f"{p}.linear_fc2.bias": [dim(vision, "out_hidden_size")]})
    return shapes


def _mtp_keys() -> set[str]:
    prefix = "mtp.layers.0."
    return {"mtp.fc.weight", "mtp.norm.weight", "mtp.pre_fc_norm_embedding.weight", "mtp.pre_fc_norm_hidden.weight",
        prefix + "input_layernorm.weight", prefix + "post_attention_layernorm.weight",
        prefix + "mlp.experts.gate_up_proj", prefix + "mlp.experts.down_proj", prefix + "mlp.gate.weight",
        prefix + "mlp.shared_expert_gate.weight"} | {prefix + "self_attn." + name + ".weight" for name in
        ["q_proj", "k_proj", "v_proj", "o_proj", "q_norm", "k_norm"]} | {prefix + "mlp.shared_expert." + name + ".weight"
        for name in ["gate_proj", "up_proj", "down_proj"]}


def plan_conversion(manifest: dict) -> dict:
    if manifest.get("version") != 1 or manifest.get("base_model") != BASE or manifest.get("base_revision") != REVISION or manifest.get("architecture") != ARCHITECTURE:
        raise ValueError("The private manifest must identify the pinned Qwen base")
    for key in ["config_sha256", "index_sha256"]:
        if not re.fullmatch(r"[0-9a-f]{64}", str(manifest.get(key, ""))): raise ValueError("Missing sidecar fingerprint")
    config = manifest["config"]
    expected = expected_hf_shapes(config)
    files, weight_map = manifest.get("files"), manifest.get("index", {}).get("weight_map")
    if not isinstance(files, dict) or not files or not isinstance(weight_map, dict) or not weight_map:
        raise ValueError("A full HF index and per-shard headers are required")
    descriptors = {}
    for name, entry in files.items():
        if not isinstance(name, str) or Path(name).name != name or not re.fullmatch(r"[A-Za-z0-9_-]+\.safetensors", name):
            raise ValueError("Invalid source shard basename")
        size = entry.get("bytes")
        if type(size) is not int or not 10 <= size <= MAX_SHARD_BYTES or not re.fullmatch(r"[0-9a-f]{64}", str(entry.get("sha256", ""))):
            raise ValueError("Missing fingerprint or shard exceeds 4 GiB")
        header = entry.get("tensors")
        if not isinstance(header, dict) or not header: raise ValueError("Missing shard descriptors")
        payload = 0
        for key, tensor in header.items():
            if key in descriptors or weight_map.get(key) != name or not isinstance(tensor, dict) or set(tensor) != {"dtype", "shape"}:
                raise ValueError("Duplicate tensor or header/index mismatch")
            shape = tensor["shape"]
            if tensor["dtype"] != "BF16" or not isinstance(shape, list) or not shape or any(type(n) is not int or n <= 0 for n in shape):
                raise ValueError("Only complete BF16 tensors are supported")
            payload += math.prod(shape) * 2
            descriptors[key] = tensor
        if payload + 8 > size: raise ValueError("Shard descriptors exceed file size")
    if set(weight_map) != set(descriptors) or set(weight_map.values()) != set(files):
        raise ValueError("The index must describe every source shard exactly")
    mtp = {key for key in descriptors if key.startswith("mtp.")}
    if mtp and mtp != _mtp_keys(): raise ValueError("Unknown or incomplete frozen MTP layout")
    source_keys = set(descriptors) - mtp
    tied_head = config["text_config"].get("tie_word_embeddings", False) and "lm_head.weight" in source_keys
    if tied_head:
        expected["lm_head.weight"] = expected["model.language_model.embed_tokens.weight"]
    if source_keys != set(expected) or any(descriptors[key]["shape"] != shape for key, shape in expected.items()):
        raise ValueError("HF keys/shapes differ from this complete fused-expert VLM layout")
    return {"shard_count": len(files), "source_weight_bytes": sum(entry["bytes"] for entry in files.values()),
        "largest_shard_bytes": max(entry["bytes"] for entry in files.values()), "source_tensor_count": len(descriptors),
        "source_vision_tensors": sum(key.startswith("model.visual.") for key in descriptors),
        "dropped_mtp_tensors": len(mtp), "tied_head_dropped": bool(tied_head), "cache_limit_bytes": MAX_SHARD_BYTES,
        "for_deployment": False, "acceptance_passed": False}


def _sanitize(weights: dict, config: dict) -> dict:
    from mlx_vlm.models.qwen3_5_moe import Model, ModelConfig, VisionModel
    # The official sanitizer couples down_proj renaming to gate_up's presence.
    # Each fused down tensor is independent; rename it before processing a shard.
    for key in list(weights):
        if key.startswith("model.language_model.") and key.endswith(".mlp.experts.down_proj"):
            weights[key.replace(".experts.down_proj", ".switch_mlp.down_proj.weight")] = weights.pop(key)
    proxy = SimpleNamespace(config=ModelConfig.from_dict(copy.deepcopy(config)))
    weights = Model.sanitize(proxy, weights)
    return VisionModel.sanitize(None, weights)


def _quantize(weights: dict) -> tuple[dict, dict]:
    import mlx.core as mx
    result, overrides = {}, {}
    for key, value in weights.items():
        quantizable = key.startswith("language_model.") and key.endswith(".weight") and (
            value.ndim == 2 or value.ndim == 3 and ".switch_mlp." in key)
        module = key[:-7]
        router = module.endswith("mlp.gate") or module.endswith("shared_expert_gate")
        group, bits, mode = (64, 8, "affine") if router else (16, 4, "nvfp4")
        if quantizable and value.shape[-1] % group == 0:
            packed, scales, *biases = mx.quantize(value, group_size=group, bits=bits, mode=mode)
            result[key], result[module + ".scales"] = packed, scales
            if biases: result[module + ".biases"] = biases[0]
            if router: overrides[module] = {"group_size": group, "bits": bits}
        else:
            result[key] = value
    return result, overrides


def _cache_identity(root: Path) -> tuple:
    value = root.lstat()
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid() or stat.S_IMODE(value.st_mode) != 0o700:
        raise ValueError("Use the dedicated private 0700 shard cache")
    return value.st_dev, value.st_ino


def _verify_source(path: Path, name: str, entry: dict, cache: Path, cache_identity: tuple) -> tuple:
    if _cache_identity(cache) != cache_identity or path.name != name or path.parent != cache or path.is_symlink():
        raise RuntimeError("The acquired shard escaped its owned cache")
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size != entry["bytes"]:
        raise ValueError("Unexpected acquired shard identity or size")
    if {p.name for p in cache.iterdir()} - {name, CACHE_MARKER}:
        raise ValueError("Only one source shard may occupy the cache")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 2**20), b""): digest.update(chunk)
    header, _, identity = _header(path)
    simplified = {key: {"dtype": item["dtype"], "shape": item["shape"]} for key, item in header.items()}
    if digest.hexdigest() != entry["sha256"] or simplified != entry["tensors"] or identity != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns):
        raise ValueError("The acquired shard failed its fingerprint/header check")
    return identity


def _convert_one(path: Path, config: dict, destination: Path, filename: str, check, check_owner) -> tuple[dict, dict]:
    import mlx.core as mx
    from safetensors import safe_open
    weights, converted, temporary = {}, {}, None
    try:
        weights = mx.load(str(path))
        if any(not bool(mx.all(mx.isfinite(value))) for value in weights.values()):
            raise ValueError("Non-finite source weights")
        weights = _sanitize(weights, config)
        converted, overrides = _quantize(weights)
        mx.eval(converted); mx.synchronize()
        check()
        if not converted: return {}, overrides
        descriptor, name = tempfile.mkstemp(prefix=".stream-", suffix=".safetensors", dir=destination)
        os.close(descriptor); temporary = Path(name)
        mx.save_safetensors(str(temporary), converted, metadata={"format": "mlx"})
        with safe_open(temporary, framework="np") as saved:
            if saved.metadata() != {"format": "mlx"} or set(saved.keys()) != set(converted):
                raise RuntimeError("Converted shard descriptor verification failed")
            if any(saved.get_slice(key).get_shape() != list(value.shape) for key, value in converted.items()):
                raise RuntimeError("Converted tensor shape changed during serialization")
        sizes = {key: value.nbytes for key, value in converted.items()}
        check()
        os.link(temporary, destination / filename)
        temporary.unlink(); temporary = None
        return sizes, overrides
    finally:
        weights.clear(); converted.clear()
        mx.synchronize(); gc.collect(); mx.clear_cache()
        if temporary is not None:
            check_owner()
            temporary.unlink(missing_ok=True)


def convert_shards(manifest: dict, acquire, release, destination: Path, *, cache_root: Path,
        owner_identity: tuple, owner_token: str, guard=None) -> dict:
    """Callers verify small sidecar bytes and retain the pending marker until full VLM checks."""
    plan = plan_conversion(manifest)
    import importlib.metadata as packages
    direct = json.loads(packages.distribution("mlx-vlm").read_text("direct_url.json"))
    if packages.version("mlx") != "0.32.4" or direct.get("vcs_info", {}).get("commit_id") != "138d7617d39653b39a5cbc379b1b5907a4481d67":
        raise ValueError("Use the pinned private MLX-VLM conversion environment")
    destination, cache_root = Path(destination).absolute(), Path(cache_root).absolute()
    _owned(destination, owner_identity, owner_token)
    if {p.name for p in destination.iterdir()} != {".miku-export-pending.json"}:
        raise ValueError("The owned candidate must otherwise be empty")
    if destination == cache_root or destination.is_relative_to(cache_root) or cache_root.is_relative_to(destination):
        raise ValueError("The input cache must be separate from the output candidate")
    cache_identity = _cache_identity(cache_root)
    if {p.name for p in cache_root.iterdir()} - {CACHE_MARKER}: raise ValueError("The input cache is not empty")
    config = copy.deepcopy(manifest["config"])
    dtype = config.get("dtype") or config.get("torch_dtype") or config["text_config"].get("dtype")
    if dtype not in [None, "bfloat16"]: raise ValueError("This export uses only BF16 source casting")
    def check_owner():
        _owned(destination, owner_identity, owner_token)
        if _cache_identity(cache_root) != cache_identity: raise RuntimeError("Shard cache ownership changed")
    def check():
        check_owner()
        if guard is not None: guard()
    mapping, sizes, overrides, count = {}, {}, {}, 0
    for name, entry in sorted(manifest["files"].items()):
        check()
        path = Path(acquire(name)).absolute()
        try:
            source_identity = _verify_source(path, name, entry, cache_root, cache_identity)
            count += 1
            target = f"model-part-{count:05d}.safetensors"
            converted_sizes, shard_overrides = _convert_one(path, config, destination, target, check, check_owner)
            current = path.stat()
            if path.is_symlink() or (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) != source_identity:
                raise RuntimeError("The cached input changed during conversion")
            if set(converted_sizes) & set(mapping): raise ValueError("Sanitization produced duplicate output keys")
            mapping.update({key: target for key in converted_sizes}); sizes.update(converted_sizes); overrides.update(shard_overrides)
        finally:
            release(name, path)
        check()
        if {p.name for p in cache_root.iterdir()} - {CACHE_MARKER}: raise RuntimeError("The shard callback did not release the input")
    from mlx_vlm.convert import _record_conversion_dtype
    if dtype is not None: _record_conversion_dtype(config, dtype)
    config["quantization"] = {"group_size": 16, "bits": 4, "mode": "nvfp4", **overrides}
    config["quantization_config"] = copy.deepcopy(config["quantization"])
    config.pop("_name_or_path", None); config.pop("torch_dtype", None)
    index = {"metadata": {"total_size": sum(sizes.values())}, "weight_map": dict(sorted(mapping.items()))}
    for filename, content in [("config.json", dict(sorted(config.items()))), ("model.safetensors.index.json", index)]:
        check()
        descriptor, name = tempfile.mkstemp(prefix=".stream-", suffix=".json", dir=destination)
        try:
            with os.fdopen(descriptor, "w") as stream: json.dump(content, stream, indent=4)
            os.link(name, destination / filename)
        finally:
            Path(name).unlink(missing_ok=True)
    check()
    return {**plan, "format": "mlx-vlm-nvfp4-sharded", "output_tensor_count": len(mapping),
        "quantized_tensor_bytes": sum(sizes.values()), "output_weight_shards": len(set(mapping.values())),
        "processor_sidecars_required": True, "sidecar_hashes_verified_by": "caller"}
