#!/usr/bin/env python3
"""Merge on DGX or convert a complete VLM on Mac without overwriting production."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

from persona import config, mac_gate, mac_observations, private_root, write_report
from train import local_model

PENDING = ".miku-export-pending.json"
RESULT = ".miku-export-result.json"


def check_destination(destination: Path, source: Path, required_gib: float) -> None:
    target, original = destination.resolve(), source.resolve()
    if target == original or target.is_relative_to(original) or original.is_relative_to(target) or destination.exists() or destination.is_symlink():
        raise ValueError("Destination must be a new model directory")
    parent = destination.parent
    if not parent.is_dir():
        raise ValueError("Destination parent must already exist")
    if shutil.disk_usage(parent).free / 2**30 < required_gib:
        raise ValueError("Insufficient destination space including rollback reserve")


def verify_vlm(path: Path, allow_pending: bool = False) -> dict:
    if (path / PENDING).exists() and not allow_pending:
        raise ValueError("Export is incomplete; the candidate is not ready")
    local_model(str(path))
    index = json.loads((path / "model.safetensors.index.json").read_text())
    if any(Path(name).name != name for name in index["weight_map"].values()):
        raise ValueError("Model shards must remain inside the model directory")
    vision = [n for n in index["weight_map"] if "vision" in n or "visual" in n]
    for name in ["preprocessor_config.json", "tokenizer.json", "tokenizer_config.json"]:
        if not (path / name).is_file(): raise ValueError("VLM processor/tokenizer is incomplete: " + name)
    tokenizer = json.loads((path / "tokenizer_config.json").read_text())
    if not tokenizer.get("chat_template") and not any((path / name).is_file() for name in ["chat_template.jinja", "chat_template.json"]):
        raise ValueError("VLM chat template is missing")
    return {"vision_tensors": len(vision), "weight_shards": len(set(index["weight_map"].values())), "image_processor": True, "architecture": json.loads((path / "config.json").read_text())["architectures"]}


def copy_sidecars(source: Path, destination: Path) -> None:
    for pattern in ["tokenizer*.json", "processor_config.json", "preprocessor_config.json", "video_preprocessor_config.json", "special_tokens_map.json", "generation_config.json", "chat_template*.jinja", "chat_template*.json", "vocab.json", "merges.txt"]:
        for item in source.glob(pattern):
            target = destination / item.name
            if item.is_file() and not target.exists(): shutil.copyfile(item, target)


def _merge_hf(source: Path, adapter: Path, destination: Path) -> dict:
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
    copy_sidecars(source, destination)
    return {"format": "hf-bf16-full-vlm"}


def _convert_mlx(source: Path, destination: Path) -> dict:
    # The BF16 source stays on NAS; only the quantized candidate is local.
    source_config = json.loads((source / "config.json").read_text())
    if source_config.get("quantization") or source_config.get("quantization_config"):
        raise ValueError("Convert from the merged floating-point HF VLM, not an existing quantized candidate")
    from mlx_vlm.convert import convert
    convert(str(source), mlx_path=str(destination), quantize=True, q_group_size=16, q_bits=4, q_mode="nvfp4", trust_remote_code=False)
    copy_sidecars(source, destination)
    return {"format": "mlx-vlm-nvfp4"}


def _fuse_mac(source: Path, adapter: Path, destination: Path) -> dict:
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
    save_weights(destination, model, donate_weights=True)
    processor.save_pretrained(destination)
    copy_sidecars(source, destination)
    cfg = json.loads((source / "config.json").read_text())
    cfg.pop("lora", None)
    write_report(destination / "config.json", cfg)
    return {"fused_language_modules": len(replacements), "format": "mlx-vlm-preserved-quantization"}


def export_resources(operation: str, cfg: dict, destination: Path, preflight: bool = False) -> dict:
    disk = shutil.disk_usage(destination.parent).free / 2**30
    if operation == "merge-hf":
        memory = Path("/proc/meminfo").read_text()
        available = int(re.search(r"MemAvailable:\s+(\d+)", memory).group(1)) * 1024 / 2**30
        reasons = []
        if available < (90 if preflight else 18): reasons.append("insufficient_ram_reserve")
        if disk < 30: reasons.append("disk_reserve_below_30_gib")
        return {"allowed": not reasons, "reasons": reasons, "available_ram_gib": available}
    observations = mac_observations(cfg)
    # Allocation may consume the initial 40 GiB; retain 16 GiB plus reaction room.
    limits = {**cfg, "mac": {**cfg["mac"], "min_free_ram_gib": cfg["mac"]["min_free_ram_gib"] if preflight else 18}}
    observations["free_disk_gib"] = min(disk, observations.get("free_disk_gib", 0))
    gate = mac_gate(limits, observations)
    return {"allowed": gate["allowed"], "reasons": gate["reasons"], "available_ram_gib": observations.get("available_ram_gib", 0)}


@contextmanager
def candidate_slot(cfg: dict, destination: Path):
    import fcntl
    root = private_root(cfg)
    candidates = root / "candidates"
    if candidates.is_symlink() or destination.parent.resolve() != candidates.resolve():
        raise ValueError("Mac exports must stay directly in the private candidates directory")
    candidates.mkdir(mode=0o700, exist_ok=True)
    with (root / ".mac-export.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if any(p.is_dir() or p.is_symlink() for p in candidates.iterdir()):
            raise ValueError("A Mac candidate already exists; preserve it until explicitly reviewed or removed")
        yield


def owned_destination(destination: Path, identity: tuple, token: str) -> bool:
    if destination.is_symlink() or not destination.is_dir(): return False
    current = destination.stat()
    if (current.st_dev, current.st_ino) != identity: return False
    try: return json.loads((destination / PENDING).read_text()).get("token") == token
    except (OSError, ValueError): return False


def discard_incomplete(destination: Path, identity: tuple, token: str, marker_written: bool = True) -> None:
    current = destination.stat() if destination.is_dir() and not destination.is_symlink() else None
    identity_matches = current is not None and (current.st_dev, current.st_ino) == identity
    if not identity_matches or (marker_written and not owned_destination(destination, identity, token)):
        raise RuntimeError("Export directory ownership changed; nothing was deleted")
    receipt = destination / "miku-export-receipt.json"
    if receipt.exists():
        try: exported = json.loads(receipt.read_text())
        except (OSError, ValueError): exported = {}
        if isinstance(exported, dict) and exported.get("export_token") == token and exported.get("acceptance_passed") is True:
            raise RuntimeError("Accepted candidate was preserved")
    shutil.rmtree(destination)


def stop_worker(child) -> None:
    if child.poll() is not None: return
    try:
        if os.getpgid(child.pid) != child.pid:
            raise RuntimeError("Export child no longer owns its process group")
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        child.wait(timeout=5)
        return
    try: child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=5)


def guarded_export(operation: str, source: Path, adapter: Path | None, destination: Path, cfg: dict, command=None, poll_seconds: float = 1) -> dict:
    source = source.resolve()
    verify_vlm(source)
    if operation in ["merge-hf", "fuse-mac"]:
        if adapter is None: raise ValueError("A local adapter is required")
        folder = adapter if adapter.is_dir() else adapter.parent
        choices = ["adapter_model.safetensors"] if operation == "merge-hf" else ["adapters.safetensors", "weights.safetensors"]
        if not (folder / "adapter_config.json").is_file() or not (adapter.is_file() or any((folder / name).is_file() for name in choices)):
            raise ValueError("The local adapter checkpoint is incomplete")
        if operation == "fuse-mac" and json.loads((folder / "adapter_config.json").read_text()).get("fine_tune_type") == "full":
            raise ValueError("Fuse requires language LoRA adapters, not a full-model checkpoint")
    if operation in ["merge-hf", "convert-mlx"]:
        original = json.loads((source / "config.json").read_text())
        if original.get("quantization") or original.get("quantization_config"):
            raise ValueError("This operation requires the original floating-point HF VLM")
    index = json.loads((source / "model.safetensors.index.json").read_text())
    source_gib = sum((source / name).stat().st_size for name in set(index["weight_map"].values())) / 2**30
    needed = max(90, source_gib + 34) if operation == "merge-hf" else max(55, source_gib * 1.1 + 34) if operation == "fuse-mac" else 55
    check_destination(destination, source, needed)
    first = export_resources(operation, cfg, destination, preflight=True)
    if not first["allowed"]: raise ValueError("Export resource gate denied: " + ", ".join(first["reasons"]))
    interpreter = Path(sys.executable) if operation == "merge-hf" else private_root(cfg) / "envs/mac/bin/python"
    if command is None and not interpreter.is_file():
        raise ValueError("The isolated export environment is missing")
    destination.mkdir(mode=0o700)
    stat = destination.stat(); identity = (stat.st_dev, stat.st_ino)
    token = uuid.uuid4().hex
    plan = {"operation": operation, "source": str(source), "adapter": str(adapter.resolve()) if adapter else None, "destination": str(destination.resolve()), "parent_pid": os.getpid(), "token": token, "configuration": cfg, "memory_limit_gib": min(cfg["mac"]["max_memory_gib"], first["available_ram_gib"] - 18)}
    child = None
    marker_written = False
    old_handlers = {}
    def cancel(signum, frame): raise KeyboardInterrupt("Export cancelled")
    try:
        write_report(destination / PENDING, plan)
        marker_written = True
        for signum in [signal.SIGINT, signal.SIGTERM]:
            old_handlers[signum] = signal.signal(signum, cancel)
        child = subprocess.Popen(command or [str(interpreter), str(Path(__file__).resolve()), "_worker", "--model", str(source), "--output", str(destination), "--token", token], stdin=subprocess.DEVNULL, start_new_session=True, env={**os.environ, "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "TOKENIZERS_PARALLELISM": "false"})
        while True:
            gate = export_resources(operation, cfg, destination)
            if not gate["allowed"]: raise RuntimeError("Export cancelled: " + ", ".join(gate["reasons"]))
            if not owned_destination(destination, identity, token): raise RuntimeError("Export directory ownership changed")
            code = child.poll()
            if code is not None: break
            time.sleep(poll_seconds)
        if code != 0: raise RuntimeError("Export worker failed with exit code " + str(code))
        result = json.loads((destination / RESULT).read_text())
        result.update(verify_vlm(destination, allow_pending=True))
        original = verify_vlm(source)
        if result["vision_tensors"] != original["vision_tensors"]:
            raise ValueError("Vision tensor count changed during export")
        gate = export_resources(operation, cfg, destination)
        if not gate["allowed"]: raise RuntimeError("Export cancelled: " + ", ".join(gate["reasons"]))
        result.update({"source": str(source), "adapter": str(adapter) if adapter else None, "status": "complete_pending_quality_review", "export_token": token, "acceptance_passed": False, "for_deployment": False})
        write_report(destination / "miku-export-receipt.json", result)
        (destination / RESULT).unlink()
        (destination / PENDING).unlink()
        return result
    except BaseException:
        if child is not None: stop_worker(child)
        discard_incomplete(destination, identity, token, marker_written)
        raise
    finally:
        for signum, handler in old_handlers.items(): signal.signal(signum, handler)


def worker(destination: Path, token: str) -> None:
    plan = json.loads((destination / PENDING).read_text())
    if plan["token"] != token or plan["parent_pid"] != os.getppid() or os.getpgrp() != os.getpid() or destination.resolve() != Path(plan["destination"]):
        raise ValueError("Export worker requires its live supervisor and owned destination")
    def check_parent():
        while True:
            if os.getppid() != plan["parent_pid"]:
                os.killpg(os.getpgrp(), signal.SIGKILL)
            time.sleep(0.5)
    threading.Thread(target=check_parent, daemon=True).start()
    if plan["operation"] != "merge-hf":
        import importlib.metadata as packages
        cfg = plan["configuration"]["mac"]
        direct = json.loads(packages.distribution("mlx-vlm").read_text("direct_url.json"))
        if packages.version("mlx") != cfg["mlx"] or packages.version("transformers") != cfg["transformers"] or direct.get("vcs_info", {}).get("commit_id") != cfg["mlx_vlm_commit"]:
            raise ValueError("Use the isolated, pinned Mac export environment")
        import mlx.core as mx
        mx.set_memory_limit(int(plan["memory_limit_gib"] * 2**30))
        mx.set_cache_limit(2 * 2**30)
    source = Path(plan["source"])
    adapter = Path(plan["adapter"]) if plan["adapter"] else None
    result = {"merge-hf": lambda: _merge_hf(source, adapter, destination), "convert-mlx": lambda: _convert_mlx(source, destination), "fuse-mac": lambda: _fuse_mac(source, adapter, destination)}[plan["operation"]]()
    write_report(destination / RESULT, result)


def run_export(operation: str, source: Path, adapter: Path | None, destination: Path) -> dict:
    cfg = config()
    if operation == "merge-hf": return guarded_export(operation, source, adapter, destination, cfg)
    with candidate_slot(cfg, destination): return guarded_export(operation, source, adapter, destination, cfg)


def merge_hf(source: Path, adapter: Path, destination: Path) -> dict:
    return run_export("merge-hf", source, adapter, destination)


def convert_mlx(source: Path, destination: Path) -> dict:
    return run_export("convert-mlx", source, None, destination)


def fuse_mac(source: Path, adapter: Path, destination: Path) -> dict:
    return run_export("fuse-mac", source, adapter, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["merge-hf", "convert-mlx", "fuse-mac", "verify", "_worker"])
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--adapter", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--token", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.operation == "_worker":
        worker(args.output, args.token)
        return
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
    except KeyboardInterrupt: raise SystemExit("Export cancelled; incomplete output removed")
    except (OSError, ValueError, RuntimeError) as error: raise SystemExit(str(error))
