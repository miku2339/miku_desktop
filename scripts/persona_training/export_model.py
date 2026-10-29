#!/usr/bin/env python3
"""Merge on DGX or convert a complete VLM on Mac without overwriting production."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

from persona import config, mac_gate, mac_observations, write_report
from train import local_model


def check_destination(destination: Path, source: Path, required_gib: float) -> None:
    if destination.resolve() == source.resolve() or destination.exists():
        raise ValueError("Destination must be a new model directory")
    parent = destination.parent
    if not parent.is_dir():
        raise ValueError("Destination parent must already exist")
    if shutil.disk_usage(parent).free / 2**30 < required_gib:
        raise ValueError("Insufficient destination space including rollback reserve")


def verify_vlm(path: Path) -> dict:
    local_model(str(path))
    index = json.loads((path / "model.safetensors.index.json").read_text())
    vision = [n for n in index["weight_map"] if "vision" in n or "visual" in n]
    if not (path / "preprocessor_config.json").exists():
        raise ValueError("VLM image processor is missing")
    return {"vision_tensors": len(vision), "weight_shards": len(set(index["weight_map"].values())), "image_processor": True, "architecture": json.loads((path / "config.json").read_text())["architectures"]}


def merge_hf(source: Path, adapter: Path, destination: Path) -> dict:
    check_destination(destination, source, 90)
    memory = Path("/proc/meminfo").read_text()
    available = int(re.search(r"MemAvailable:\s+(\d+)", memory).group(1)) * 1024 / 2**30
    if available < 90:
        raise ValueError("HF merge requires at least 90 GiB available RAM including reserve")
    from peft import PeftModel
    from transformers import AutoProcessor, Qwen3_5MoeForConditionalGeneration
    import torch
    current = json.loads((source / "config.json").read_text())
    if current.get("quantization") or current.get("quantization_config"):
        raise ValueError("Merge requires the original floating-point HF VLM")
    original = Qwen3_5MoeForConditionalGeneration.from_pretrained(source, local_files_only=True, dtype=torch.bfloat16, device_map="cpu", trust_remote_code=False)
    model = PeftModel.from_pretrained(original, adapter, local_files_only=True)
    model = model.merge_and_unload(safe_merge=True)
    model.save_pretrained(destination, safe_serialization=True, max_shard_size="4GB")
    AutoProcessor.from_pretrained(source, local_files_only=True, trust_remote_code=False).save_pretrained(destination)
    result = verify_vlm(destination)
    result["source"] = str(source)
    result["adapter"] = str(adapter)
    write_report(destination / "miku-export-receipt.json", result)
    return result


def convert_mlx(source: Path, destination: Path) -> dict:
    # The BF16 source stays on NAS; only the quantized candidate is local.
    check_destination(destination, source, 55)
    require_mac_resources()
    source_config = json.loads((source / "config.json").read_text())
    if source_config.get("quantization") or source_config.get("quantization_config"):
        raise ValueError("Convert from the merged floating-point HF VLM, not an existing quantized candidate")
    from mlx_vlm.convert import convert
    convert(str(source), mlx_path=str(destination), quantize=True, q_group_size=16, q_bits=4, q_mode="nvfp4", trust_remote_code=False)
    result = verify_vlm(destination)
    result["source"] = str(source)
    result["format"] = "mlx-vlm-nvfp4"
    write_report(destination / "miku-export-receipt.json", result)
    return result


def fuse_mac(source: Path, adapter: Path, destination: Path) -> dict:
    check_destination(destination, source, 55)
    require_mac_resources()
    from mlx_vlm import load
    from mlx_vlm.trainer.peft import load_adapters
    from mlx_vlm.utils import save_weights
    from mlx.utils import tree_unflatten
    model, processor = load(str(source))
    model = load_adapters(model, adapter)
    replacements = [(name, module.fuse()) for name, module in model.named_modules() if hasattr(module, "fuse")]
    if not replacements:
        raise ValueError("No mergeable language adapters found")
    if any(not name.startswith("language_model.") for name, _ in replacements):
        raise ValueError("Unexpected adapter outside the language tower")
    model.update_modules(tree_unflatten(replacements))
    destination.mkdir(mode=0o700)
    save_weights(destination, model, donate_weights=True)
    processor.save_pretrained(destination)
    cfg = json.loads((source / "config.json").read_text())
    cfg.pop("lora", None)
    write_report(destination / "config.json", cfg)
    result = verify_vlm(destination)
    result.update({"source": str(source), "adapter": str(adapter), "fused_language_modules": len(replacements), "format": "mlx-vlm-preserved-quantization"})
    write_report(destination / "miku-export-receipt.json", result)
    return result


def require_mac_resources() -> None:
    cfg = config()
    observations = mac_observations(cfg)
    gate = mac_gate(cfg, observations)
    if not gate["allowed"]:
        raise ValueError("Mac export resource gate denied: " + ", ".join(gate["reasons"]))
    import mlx.core as mx
    safe_limit = min(cfg["mac"]["max_memory_gib"], observations["available_ram_gib"] - 16)
    mx.set_memory_limit(int(safe_limit * 2**30))
    mx.set_cache_limit(2 * 2**30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["merge-hf", "convert-mlx", "fuse-mac", "verify"])
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--adapter", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    source = local_model(str(args.model))
    if args.operation == "verify": result = verify_vlm(source)
    elif args.dry_run: result = {"operation": args.operation, "source": str(source), "destination": str(args.output), "would_load_model": False, "preserve_vision": True}
    else:
        if args.output is None: raise ValueError("--output is required")
        if args.operation in ["merge-hf", "fuse-mac"]:
            if args.adapter is None: raise ValueError("--adapter is required")
            result = merge_hf(source, args.adapter, args.output) if args.operation == "merge-hf" else fuse_mac(source, args.adapter, args.output)
        else: result = convert_mlx(source, args.output)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try: main()
    except (OSError, ValueError) as error: raise SystemExit(str(error))
