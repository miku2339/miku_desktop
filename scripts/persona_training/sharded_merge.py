"""Bounded CPU merge for the approved Qwen3.6 rank-16 language adapters."""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
import re
import tempfile


GIB = 2**30
PENDING = ".miku-export-pending.json"
MAX_HEADER_BYTES = 16 * 2**20
TARGET = re.compile(r"model\.language_model\.layers\.([0-9]+)\.(?:self_attn\.(?:q_proj|k_proj|v_proj|o_proj)|linear_attn\.(?:in_proj_qkv|in_proj_z|in_proj_b|in_proj_a|out_proj))")
FROZEN_MTP_TARGETS = {"mtp.layers.0.self_attn." + name + "_proj" for name in ["q", "k", "v", "o"]}
WIDTHS = {"BF16": 2, "F32": 4, "F16": 2, "I64": 8, "I32": 4, "I16": 2, "I8": 1, "U8": 1, "BOOL": 1}


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError("Duplicate JSON key: " + key)
        result[key] = value
    return result


def _json(path: Path, maximum: int = MAX_HEADER_BYTES) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > maximum:
        raise ValueError("Expected a bounded local JSON file")
    value = json.loads(path.read_text(), object_pairs_hook=_unique_object)
    if not isinstance(value, dict): raise ValueError("JSON object required")
    return value


def _identity(path: Path) -> tuple:
    if path.is_symlink() or not path.is_file(): raise ValueError("Expected a regular local weight file")
    value = path.stat()
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns


def _header(path: Path) -> tuple[dict, dict, tuple]:
    identity = _identity(path)
    with path.open("rb") as stream:
        size = int.from_bytes(stream.read(8), "little")
        if not 2 <= size <= MAX_HEADER_BYTES or size + 8 > identity[2]:
            raise ValueError("Invalid safetensors header length")
        header = json.loads(stream.read(size), object_pairs_hook=_unique_object)
    if not isinstance(header, dict): raise ValueError("Invalid safetensors header")
    metadata = header.pop("__metadata__", {})
    if not isinstance(metadata, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in metadata.items()):
        raise ValueError("Invalid safetensors metadata")
    spans = []
    for name, entry in header.items():
        if not name or not isinstance(entry, dict) or set(entry) != {"dtype", "shape", "data_offsets"}:
            raise ValueError("Invalid safetensors tensor descriptor")
        shape, offsets, dtype = entry["shape"], entry["data_offsets"], entry["dtype"]
        if not isinstance(dtype, str) or dtype not in WIDTHS or not isinstance(shape, list) or any(type(n) is not int or n < 0 for n in shape):
            raise ValueError("Invalid tensor dtype or shape")
        if not isinstance(offsets, list) or len(offsets) != 2 or any(type(n) is not int or n < 0 for n in offsets):
            raise ValueError("Invalid tensor offsets")
        if offsets[1] - offsets[0] != math.prod(shape) * WIDTHS[dtype]:
            raise ValueError("Tensor size does not match its offsets")
        spans.append(tuple(offsets))
    cursor = 0
    for start, end in sorted(spans):
        if start != cursor or end < start: raise ValueError("Safetensors data has a hole or overlap")
        cursor = end
    if cursor != identity[2] - size - 8 or _identity(path) != identity:
        raise ValueError("Safetensors payload size or source identity changed")
    return header, metadata, identity


def _approved(values) -> set[str]:
    if not isinstance(values, (list, tuple, set)) or any(not isinstance(v, str) for v in values):
        raise ValueError("Explicit approved language targets are required")
    names = set(values)
    if len(values) != 190 or len(names) != 190:
        raise ValueError("Exactly 190 unique approved language targets are required")
    for name in names:
        match = TARGET.fullmatch(name)
        if not match or not 0 <= int(match[1]) < 40: raise ValueError("Unexpected language adapter target")
    return names


def _adapter_config(value: dict, names: set[str], source_modules: set[str]) -> None:
    fixed = {"peft_type": "LORA", "task_type": "CAUSAL_LM", "r": 16, "lora_alpha": 32,
        "lora_dropout": 0.0, "bias": "none", "fan_in_fan_out": False,
        "use_rslora": False, "use_dora": False, "init_lora_weights": True}
    for key, expected in fixed.items():
        actual = value.get(key)
        if actual != expected or (type(expected) is bool and type(actual) is not bool) or (type(expected) is int and type(actual) is not int) or (type(expected) is float and type(actual) not in [int, float]):
            raise ValueError("Unsupported LoRA configuration: " + key)
    inert = {"base_model_name_or_path", "peft_version", "revision", "inference_mode", "target_modules", "megatron_core", "qalora_group_size"}
    if value.get("megatron_core", "megatron.core") != "megatron.core" or value.get("qalora_group_size", 16) != 16:
        raise ValueError("Unexpected inactive backend defaults")
    for key, item in value.items():
        if key in fixed or key in inert: continue
        if item is not None and item is not False and item != {} and item != []:
            raise ValueError("Unsupported extra adapter transformation: " + key)
    selectors = value.get("target_modules")
    suffixes = {name.rsplit(".", 1)[1] for name in names}
    if not isinstance(selectors, list) or not selectors or any(not isinstance(s, str) or s not in names | suffixes for s in selectors) or len(set(selectors)) != len(selectors):
        raise ValueError("Only approved full names or attention suffixes are supported")
    expanded = {name for name in source_modules if any(name == s or name.endswith("." + s) for s in selectors)}
    # PEFT compresses runtime targets to suffixes; the full HF archive also keeps
    # its frozen MTP head. Adapter tensors still have to match exactly 190 targets.
    if expanded & names != names or expanded - names - FROZEN_MTP_TARGETS:
        raise ValueError("Adapter selectors do not expand to the approved language targets")


def _inspect(source: Path, adapter: Path, approved_targets) -> dict:
    source, adapter = Path(source).resolve(), Path(adapter).resolve()
    adapter = adapter / "adapter_model.safetensors" if adapter.is_dir() else adapter
    if adapter.name != "adapter_model.safetensors": raise ValueError("One standard PEFT safetensors adapter is required")
    names = _approved(approved_targets)
    index_path = source / "model.safetensors.index.json"
    index_identity = _identity(index_path)
    index = _json(index_path)
    weight_map = index.get("weight_map")
    if not isinstance(weight_map, dict) or not weight_map or any(not isinstance(k, str) or not isinstance(v, str) or Path(v).name != v or not v.endswith(".safetensors") for k, v in weight_map.items()):
        raise ValueError("Invalid local HF shard index")
    shards, descriptors, identities = {}, {}, {index_path: index_identity}
    for name in sorted(set(weight_map.values())):
        path = source / name
        header, metadata, identity = _header(path)
        if set(header) != {key for key, shard in weight_map.items() if shard == name}:
            raise ValueError("Shard tensors differ from the HF index")
        if any(entry["dtype"] in {"F16", "F32"} for entry in header.values()):
            raise ValueError("The source floating-point weights must all be BF16")
        shards[name] = (header, metadata)
        descriptors.update(header)
        identities[path] = identity
    source_modules = {key[:-7] for key in descriptors if key.endswith(".weight")}
    if {name for name in source_modules if TARGET.fullmatch(name)} != names:
        raise ValueError("Source language targets differ from the approved target set")
    config_path = adapter.parent / "adapter_config.json"
    config_identity = _identity(config_path)
    _adapter_config(_json(config_path), names, source_modules)
    identities[config_path] = config_identity
    adapter_header, _, identities[adapter] = _header(adapter)
    pairs = {}
    for key, entry in adapter_header.items():
        match = re.fullmatch(r"base_model\.model\.(.+)\.lora_([AB])\.weight", key)
        if not match or match[1] not in names: raise ValueError("Unexpected adapter tensor key")
        module, side = match.groups()
        target = descriptors.get(module + ".weight")
        shape = target["shape"] if target else []
        expected = [16, shape[1]] if side == "A" and len(shape) == 2 else [shape[0], 16] if len(shape) == 2 else []
        if not target or target["dtype"] != "BF16" or not expected or any(n <= 0 for n in shape) or entry["shape"] != expected or entry["dtype"] not in {"F32", "BF16", "F16"}:
            raise ValueError("Adapter tensor shape or dtype does not match the BF16 base")
        pairs.setdefault(module + ".weight", {})[side] = key
    if set(pairs) != {name + ".weight" for name in names} or any(set(pair) != {"A", "B"} for pair in pairs.values()):
        raise ValueError("The adapter must contain exactly 190 complete A/B pairs")
    adapter_bytes = sum(math.prod(entry["shape"]) * WIDTHS[entry["dtype"]] for entry in adapter_header.values())
    if adapter_bytes > 512 * 2**20: raise ValueError("The adapter exceeds this profile's bounded size")
    if any(_identity(path) != identity for path, identity in identities.items()):
        raise RuntimeError("Merge inputs changed during inspection")
    largest_delta = max(math.prod(descriptors[name]["shape"]) * 4 for name in pairs)
    largest_shard = max(identities[source / name][2] for name in shards)
    working = 2 * largest_shard + adapter_bytes + 2 * largest_delta + 2 * GIB
    report = {"format": "hf-bf16-full-vlm-sharded", "target_count": len(names), "shard_count": len(shards),
        "source_weight_bytes": sum(identities[source / name][2] for name in shards),
        "adapter_tensor_bytes": adapter_bytes, "largest_shard_bytes": largest_shard,
        "largest_delta_bytes": largest_delta, "estimated_working_set_gib": working / GIB,
        "ram_reserve_gib": 16, "required_available_ram_gib": working / GIB + 16}
    return {"source": source, "adapter": adapter, "pairs": pairs, "shards": shards,
        "identities": identities, "report": report}


def plan_merge(source: Path, adapter: Path, approved_targets) -> dict:
    """Read bounded headers/config only; the caller enforces the RAM/disk gates."""
    return _inspect(source, adapter, approved_targets)["report"]


def _owned(destination: Path, identity: tuple, token: str) -> None:
    if destination.is_symlink() or not destination.is_dir(): raise RuntimeError("Export directory ownership changed")
    value = destination.stat()
    if (value.st_dev, value.st_ino) != tuple(identity) or not token or _json(destination / PENDING).get("token") != token:
        raise RuntimeError("Export directory ownership changed")


def merge_shards(source: Path, adapter: Path, destination: Path, approved_targets, *, owner_identity: tuple, owner_token: str, guard=None) -> dict:
    """Write weights only into the supervisor's new directory; retain its pending marker."""
    destination = Path(destination).absolute()
    _owned(destination, owner_identity, owner_token)
    plan = _inspect(source, adapter, approved_targets)
    for original in [plan["source"], plan["adapter"].parent]:
        if destination.resolve() == original or destination.resolve().is_relative_to(original) or original.is_relative_to(destination.resolve()):
            raise ValueError("The export must be separate from source and adapter directories")
    if {p.name for p in destination.iterdir()} != {PENDING}: raise ValueError("The owned export directory must otherwise be empty")
    if guard: guard()
    import torch
    from safetensors import safe_open
    from safetensors.torch import save_file

    def check():
        _owned(destination, owner_identity, owner_token)
        if guard: guard()
        for path, identity in plan["identities"].items():
            if _identity(path) != identity: raise RuntimeError("Merge source changed after inspection")

    written, temporary = [], None
    with torch.no_grad(), safe_open(plan["adapter"], framework="pt", device="cpu") as adapters:
        try:
            for name, (header, metadata) in plan["shards"].items():
                check()
                values = {}
                with safe_open(plan["source"] / name, framework="pt", device="cpu") as weights:
                    for key in header:
                        check()
                        weight = weights.get_tensor(key)
                        if key in plan["pairs"]:
                            pair = plan["pairs"][key]
                            a, b = (adapters.get_tensor(pair[side]).float() for side in ["A", "B"])
                            if not torch.isfinite(a).all() or not torch.isfinite(b).all(): raise ValueError("Non-finite adapter weights")
                            delta = (b @ a) * 2.0
                            delta = delta.to(weight.dtype)
                            if not torch.isfinite(delta).all(): raise ValueError("Non-finite merged delta")
                            weight = weight.clone()
                            weight.add_(delta)
                            if not torch.isfinite(weight).all(): raise ValueError("Non-finite merged weights")
                            del a, b, delta
                        values[key] = weight
                    check()
                    descriptor, temporary_name = tempfile.mkstemp(prefix=".merge-", suffix=".safetensors", dir=destination)
                    os.close(descriptor)
                    temporary = Path(temporary_name)
                    save_file(values, temporary, metadata=metadata)
                    saved, saved_metadata, _ = _header(temporary)
                    if saved_metadata != metadata or set(saved) != set(header) or any(saved[k]["shape"] != header[k]["shape"] or saved[k]["dtype"] != header[k]["dtype"] for k in header):
                        raise RuntimeError("Merged shard changed its tensor descriptors or metadata")
                    check()
                    # Atomic publication refuses to overwrite any concurrently created path.
                    os.link(temporary, destination / name)
                    temporary.unlink(); temporary = None
                    written.append(name)
                    values.clear(); del weight
                check()
        finally:
            if temporary is not None:
                _owned(destination, owner_identity, owner_token)
                temporary.unlink(missing_ok=True)
    return {**plan["report"], "written_shards": written, "source_weight_map_preserved": True,
        "for_deployment": False, "acceptance_passed": False}
