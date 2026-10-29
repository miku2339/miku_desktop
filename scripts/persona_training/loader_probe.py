"""Compare two official loading routes on a synthetic, bounded Qwen VLM."""

from __future__ import annotations

import argparse
import gc
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from load_watchdog import WeightLoadWatchdog, available_memory, sequential_weight_loading
from persona import config, private_root, targets, write_report

UNITS = ["spark-model.service", "maritime-model.service"]
CAP_BYTES = 256 * 2**20


def service_state() -> dict:
    return {unit: subprocess.run(["systemctl", "--user", "is-active", unit], capture_output=True, text=True).stdout.strip() for unit in UNITS}


def run(cfg: dict, output: Path) -> dict:
    if sys.platform != "linux": raise ValueError("This bounded CUDA probe runs on DGX only")
    root = private_root(cfg)
    if not output.resolve().is_relative_to((root / "reports").resolve()) or output.exists():
        raise ValueError("Use a new private reports path")
    before = service_state()
    available = available_memory()
    if any(value != "active" for value in before.values()) or available < 48:
        raise ValueError("Both inference services must remain active and at least 48 GiB RAM must be available")
    import torch
    from transformers import Qwen3_5MoeConfig, Qwen3_5MoeForConditionalGeneration

    torch.cuda.set_per_process_memory_fraction(CAP_BYTES / torch.cuda.get_device_properties(0).total_memory, 0)
    tiny = Qwen3_5MoeConfig(
        text_config={"vocab_size": 128, "hidden_size": 64, "num_hidden_layers": 40,
            "num_attention_heads": 4, "num_key_value_heads": 2, "head_dim": 16,
            "linear_key_head_dim": 16, "linear_value_head_dim": 16, "linear_num_key_heads": 4,
            "linear_num_value_heads": 4, "moe_intermediate_size": 32,
            "shared_expert_intermediate_size": 32, "num_experts": 2, "num_experts_per_tok": 1,
            "max_position_embeddings": 128,
            "rope_parameters": {"rope_type": "default", "rope_theta": 10000.0, "partial_rotary_factor": 1.0, "mrope_section": [2, 3, 3]}},
        vision_config={"depth": 2, "hidden_size": 32, "intermediate_size": 64, "num_heads": 4,
            "patch_size": 4, "spatial_merge_size": 2, "temporal_patch_size": 2,
            "out_hidden_size": 64, "num_position_embeddings": 64},
        image_token_id=120, video_token_id=121, vision_start_token_id=122, vision_end_token_id=123)
    results = []
    with tempfile.TemporaryDirectory(prefix="tiny-loader-", dir=root) as temporary:
        directory = Path(temporary)
        torch.manual_seed(39)
        original = Qwen3_5MoeForConditionalGeneration(tiny).to(dtype=torch.bfloat16)
        expected = {name: value.clone() for name, value in original.state_dict().items()}
        weight_bytes = sum(value.numel() * value.element_size() for value in expected.values())
        if weight_bytes > CAP_BYTES // 4: raise ValueError("Synthetic model exceeds the safe size")
        expected_targets = targets([name for name, _ in original.named_modules()], cfg)
        original.save_pretrained(directory / "checkpoint", safe_serialization=True)
        del original
        gc.collect()
        for route in ["direct_cuda", "cpu_then_cuda"]:
            if available_memory() < 48 or any(v != "active" for v in service_state().values()):
                raise ValueError("Probe resource or service condition changed")
            torch.cuda.empty_cache()
            torch.cuda.reset_peak_memory_stats()
            calls, snapshots = [], []
            previous_profile = sys.getprofile()
            def trace(frame, event, arg):
                if frame.f_code.co_name == "caching_allocator_warmup" and frame.f_code.co_filename.endswith("transformers/modeling_utils.py"):
                    if event == "call": calls.append("called")
                    if event == "return": snapshots.append({"allocated_bytes": torch.cuda.memory_allocated(), "reserved_bytes": torch.cuda.memory_reserved()})
            started = time.monotonic()
            try:
                sys.setprofile(trace)
                with WeightLoadWatchdog(16, directory / route), sequential_weight_loading():
                    model = Qwen3_5MoeForConditionalGeneration.from_pretrained(directory / "checkpoint", local_files_only=True,
                        trust_remote_code=False, dtype=torch.bfloat16, device_map={"": 0} if route == "direct_cuda" else None)
                    if route == "cpu_then_cuda": model.to("cuda:0")
                    torch.cuda.synchronize()
            finally:
                sys.setprofile(previous_profile)
            actual = model.state_dict()
            same_weights = set(actual) == set(expected) and all(torch.equal(value.cpu(), expected[name]) for name, value in actual.items())
            same_targets = targets([name for name, _ in model.named_modules()], cfg) == expected_targets
            vision = [name for name in actual if ".visual." in name]
            row = {"route": route, "warmup_calls": len(calls), "warmup_return_snapshots": snapshots,
                "peak_allocated_bytes": torch.cuda.max_memory_allocated(), "peak_reserved_bytes": torch.cuda.max_memory_reserved(),
                "current_allocated_bytes": torch.cuda.memory_allocated(), "current_reserved_bytes": torch.cuda.memory_reserved(),
                "load_seconds": time.monotonic() - started, "weights_equal": same_weights,
                "vision_tensors": len(vision), "targets_equal": same_targets, "target_count": len(expected_targets)}
            if not same_weights or not same_targets or not vision or row["peak_reserved_bytes"] > CAP_BYTES:
                raise RuntimeError("Tiny loading-route comparison failed")
            results.append(row)
            del actual, model
            gc.collect()
            torch.cuda.empty_cache()
    after = service_state()
    report = {"version": 1, "synthetic_model_only": True, "full_model_weights_loaded": False,
        "full_model_route_verified": False, "training_started": False, "allocator_cap_bytes": CAP_BYTES,
        "gpu_measurement_scope": "torch_allocator_excludes_cuda_driver_context", "weight_bytes": weight_bytes,
        "available_ram_before_gib": available, "available_ram_after_gib": available_memory(),
        "services_before": before, "services_after": after, "allocator_backend": torch.cuda.get_allocator_backend(),
        "torch_version": torch.__version__, "results": results, "acceptance_passed": False}
    write_report(output, report)
    if any(value != "active" for value in after.values()): raise RuntimeError("An inference service is no longer active")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    if args.execute: result = run(config(), args.output)
    else: result = {"dry_run": True, "would_load_full_weights": False, "allocator_cap_bytes": CAP_BYTES}
    print(json.dumps(result, indent=2))
