"""Device-specific trainers. Imports and GPU work happen only after resource gates."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import shlex
import subprocess
import time

from persona import mac_gate, mac_observations, private_root, read_jsonl, targets, training_profile, write_report
from mac_loop import ResourceMonitor, checkpoint_directory, train_resumable
from load_watchdog import WeightLoadWatchdog, sequential_weight_loading


def run_directory(cfg: dict, run_id: str) -> Path:
    path = private_root(cfg) / "runs" / run_id
    path.mkdir(parents=True, mode=0o700, exist_ok=False)
    return path


def local_model(path: str | None) -> Path:
    if not path:
        raise ValueError("A complete local model directory is required; automatic downloads are disabled")
    model = Path(path).expanduser().resolve()
    cfg = json.loads((model / "config.json").read_text())
    if "Qwen3_5MoeForConditionalGeneration" not in cfg.get("architectures", []) or not cfg.get("vision_config"):
        raise ValueError("A complete Qwen3.5/3.6 MoE VLM is required")
    index = json.loads((model / "model.safetensors.index.json").read_text())
    if not any("vision" in k or "visual" in k for k in index["weight_map"]):
        raise ValueError("Model index is missing the vision tower")
    if any(not (model / shard).is_file() for shard in set(index["weight_map"].values())):
        raise ValueError("Model shards are incomplete")
    return model


def metadata(cfg: dict, device: str, model: Path, args) -> dict:
    return {"version": 1, "device": device, "run_id": args.run_id, "probe": args.probe, "model": str(model), "base_revision": cfg["base_revision"], "persona_version": cfg["persona_version"], "started_at": datetime.now(timezone.utc).isoformat(), "status": "running", "private": True, "configuration": cfg[device], "effective_profile": training_profile(cfg, device, args.probe, args.smoke), "training_data": "pending calibration" if args.probe else "reviewed", "for_deployment": False, "acceptance_passed": False}


def run_fingerprint(cfg: dict, device: str, index_sha256: str, probe=False, smoke=False, data_sha256=None) -> str:
    limits = cfg[device]
    profile = training_profile(cfg, device, probe, smoke)
    value = {"version": 1, "device": device, "base_model": cfg["base_model"], "base_revision": cfg["base_revision"],
        "index_sha256": index_sha256, "profile": profile, "probe": probe,
        "rank": limits["rank"], "alpha": limits["alpha"], "batch_size": limits["batch_size"],
        "learning_rate": limits["learning_rate"], "targets": cfg["target_pattern"],
        "last_layers": limits.get("last_layers"), "gradient_checkpointing": True,
        "seed": 39, "rng_strategy": "microstep_seed_v1", "data_sha256": data_sha256,
        "preparation": limits.get("preparation"), "quantization": ("bf16-cpu-then-cuda-sequential" if limits.get("precision", "bf16") == "bf16" else "nf4-direct-cuda-sequential") if device == "dgx" else "existing-nvfp4",
        "mlx": limits.get("mlx"), "mlx_vlm_commit": limits.get("mlx_vlm_commit"), "transformers": limits.get("transformers")}
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def mac_runtime_reasons(cfg: dict) -> list[str]:
    current = mac_gate(cfg, mac_observations(cfg))
    # The model allocation consumes the preflight RAM reserve, while system pressure
    # and all other gates remain mandatory throughout training.
    reasons = [r for r in current["reasons"] if r != "insufficient_available_ram"]
    if current["observations"].get("available_ram_gib", 0) < 10:
        reasons.append("runtime_ram_reserve_below_10_gib")
    return reasons


def load_dgx_weights(model_class, path: Path, precision: str, dtype, quantization_factory):
    if precision not in ["bf16", "nf4"]: raise ValueError("Unsupported DGX training precision")
    options = {"local_files_only": True, "trust_remote_code": False, "dtype": dtype,
        "device_map": None if precision == "bf16" else {"": 0}}
    if precision == "nf4":
        options["quantization_config"] = quantization_factory(load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_use_double_quant=True, bnb_4bit_compute_dtype=dtype, llm_int8_skip_modules=["model.visual", "visual", "vision_tower", "model.vision_tower"])
    model = model_class.from_pretrained(path, **options)
    # Module.to replaces parameters one at a time after the CPU loader releases its
    # checkpoint state; this path also skips Transformers' accelerator warmup.
    return model.to("cuda:0") if precision == "bf16" else model


def train_mac(cfg: dict, args) -> dict:
    gate = mac_gate(cfg, mac_observations(cfg))
    if not gate["allowed"]:
        raise ValueError("Mac resource gate denied: " + ", ".join(gate["reasons"]))
    model_path = local_model(args.model or cfg["mac_base_model"])
    import importlib.metadata as packages
    if packages.version("mlx") != cfg["mac"]["mlx"] or packages.version("transformers") != cfg["mac"]["transformers"]:
        raise ValueError("Use the isolated, pinned Mac training environment")
    direct = json.loads(packages.distribution("mlx-vlm").read_text("direct_url.json"))
    if direct.get("vcs_info", {}).get("commit_id") != cfg["mac"]["mlx_vlm_commit"]:
        raise ValueError("MLX-VLM revision does not match the manifest")
    import mlx.core as mx
    import mlx.optimizers as optim
    from mlx_vlm import load
    from mlx_vlm.trainer import Trainer, VLMTrainingArgs, prepare_model_for_training

    limit = cfg["mac"]
    mx.set_memory_limit(int(limit["max_memory_gib"] * 2**30))
    mx.set_cache_limit(2 * 2**30)
    mx.random.seed(39)
    directory = run_directory(cfg, args.run_id)
    report = metadata(cfg, "mac", model_path, args)
    write_report(directory / "run.json", report)
    try:
        model, processor = load(str(model_path))
        names = targets([n for n, _ in model.named_modules()], cfg, limit["last_layers"])
        resume = checkpoint_directory(args.resume) if args.resume else None
        model = prepare_model_for_training(model, train_type="lora", lora_rank=limit["rank"], lora_alpha=limit["alpha"], lora_dropout=0.0, target_modules=names, quantization_bits=None, checkpoint_path=str(resume / "adapter") if resume else None)
        from mlx.utils import tree_flatten
        expected = [n for n, _ in tree_flatten(model.trainable_parameters())]
        if not expected or any(not n.endswith(("lora_a", "lora_b")) for n in expected):
            raise ValueError("Unexpected non-adapter trainable parameters")
        max_length = limit["probe_tokens"] if args.probe else cfg["max_tokens"]
        rows = read_jsonl(private_root(cfg) / "data/export/train.jsonl")
        prepared = []
        for row in rows:
            messages = row["prompt"] + row["completion"]
            count = len(processor.tokenizer.apply_chat_template(messages, tokenize=True, return_dict=False, enable_thinking=False))
            if count <= max_length:
                prepared.append({"messages": messages})
        if len(prepared) < 10:
            raise ValueError("Too few complete samples fit the configured context; increase the context explicitly")
        report["targets"] = names
        report["samples_used"] = len(prepared)
        report["samples_excluded_for_probe_length"] = len(rows) - len(prepared)
        write_report(directory / "run.json", report)

        profile = training_profile(cfg, "mac", args.probe, args.smoke)
        settings = VLMTrainingArgs(iters=profile["steps"], batch_size=limit["batch_size"], gradient_accumulation_steps=profile["gradient_accumulation"], max_seq_length=max_length, train_on_completions=True, grad_checkpoint=True, steps_per_report=1, steps_per_save=20, adapter_file=str(directory / "adapter/weights.safetensors"))
        trainer = Trainer(model, settings, optimizer=optim.AdamW(learning_rate=limit["learning_rate"]), processing_class=processor, train_dataset=prepared, seed=39)
        data_digest = hashlib.sha256((private_root(cfg) / "data/export/train.jsonl").read_bytes()).hexdigest()
        index_digest = hashlib.sha256((model_path / "model.safetensors.index.json").read_bytes()).hexdigest()
        fingerprint = run_fingerprint(cfg, "mac", index_digest, args.probe, args.smoke, data_digest)
        with ResourceMonitor(lambda: mac_runtime_reasons(cfg)) as monitor:
            progress = train_resumable(trainer, directory / "checkpoints", fingerprint, monitor.check, resume=resume)
        report.update(progress)
        if progress["status"] == "paused":
            return report
        trainer.save_adapter()
        report["status"] = "probe_complete" if args.probe else "trained_not_accepted"
        report["peak_memory_bytes"] = mx.get_peak_memory()
        return report
    except BaseException as error:
        report["status"] = "interrupted" if isinstance(error, KeyboardInterrupt) else "failed"
        report["error_type"] = type(error).__name__
        raise
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        write_report(directory / "run.json", report)


def dgx_budget_gate(cfg: dict, available: float, disk: float, utilization: float | None, training_processes: int, budget: dict, index_sha256: str, now: float, probe=False, smoke=False) -> dict:
    limits = cfg["dgx"]
    reasons = []
    peak = budget.get("estimated_peak_gib")
    precision = limits.get("precision", "bf16")
    if precision not in ["bf16", "nf4"]: reasons.append("unsupported_training_precision")
    meta_budget = cfg.get("meta_memory_budget", {})
    lower_bound = meta_budget.get("base_lower_bound_by_precision_gib", {}).get(precision, meta_budget.get("base_lower_bound_gib", 0))
    if available < lower_bound + limits["runtime_ram_reserve_gib"]:
        reasons.append("minimum_base_plus_16_gib_exceeds_available_ram")
    fingerprint = run_fingerprint(cfg, "dgx", index_sha256, probe, smoke)
    proof = budget.get("version") == 2 and budget.get("verified") is True and budget.get("model_index_sha256") == index_sha256 and budget.get("preparation") == limits["preparation"]
    proof = proof and budget.get("base_revision") == cfg["base_revision"] and budget.get("run_fingerprint") == fingerprint
    profile = training_profile(cfg, "dgx", probe, smoke)
    measured = budget.get("kind") == "measured_peak"
    analytical = budget.get("kind") == "conservative_analytical_probe" and precision == "bf16" and probe and 1 <= profile["steps"] <= 50 and profile["max_tokens"] <= 512 and profile["gradient_accumulation"] == 1 and limits["batch_size"] == 1 and limits["rank"] <= 16
    proof = proof and (measured or analytical)
    proof = proof and type(peak) in [int, float] and math.isfinite(peak) and peak >= lower_bound
    if analytical: proof = proof and peak >= lower_bound + 16
    expiry = budget.get("expires_at")
    proof = proof and type(expiry) in [int, float] and now <= expiry <= now + 86400
    if not proof: reasons.append("missing_or_invalid_memory_budget")
    elif available < peak + limits["runtime_ram_reserve_gib"]: reasons.append("estimated_peak_plus_16_gib_exceeds_available_ram")
    if disk < limits["min_free_disk_gib"]: reasons.append("insufficient_disk")
    if utilization is None: reasons.append("gpu_utilization_unavailable")
    elif utilization > limits["max_gpu_utilization_percent"]: reasons.append("gpu_busy")
    if training_processes: reasons.append("another_training_process_is_active")
    return {"allowed": not reasons, "reasons": reasons, "available_ram_gib": available, "free_disk_gib": disk, "gpu_utilization_percent": utilization, "other_training_processes": training_processes, "estimated_peak_gib": peak, "meta_base_lower_bound_gib": lower_bound, "reserved_ram_gib": limits["runtime_ram_reserve_gib"], "budget_kind": budget.get("kind"), "run_fingerprint": fingerprint}


def dgx_gate(cfg: dict, model: Path, probe=False, smoke=False) -> dict:
    memory = Path("/proc/meminfo").read_text()
    available = int(re.search(r"MemAvailable:\s+(\d+)", memory).group(1)) * 1024 / 2**30
    disk = shutil.disk_usage(private_root(cfg)).free / 2**30
    query = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"], capture_output=True, text=True, check=True)
    try: utilization = max(float(v.strip()) for v in query.stdout.splitlines())
    except ValueError: utilization = None
    processes = subprocess.check_output(["ps", "-eo", "pid=,args="], text=True)
    training = 0
    for line in processes.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or int(fields[0]) == os.getpid(): continue
        try: argv = shlex.split(fields[1])
        except ValueError: continue
        if len(argv) > 1 and Path(argv[1]).name in ["training_window.py", "run_when_idle.py"]:
            continue
        if argv and Path(argv[0]).name.startswith("python") and any(re.search(r"(?:^|/)(?:train[^/]*|finetune[^/]*|persona)\.py$", a) for a in argv[1:]):
            if not any(a in ["gate", "status", "prepare", "validate", "tokenize"] for a in argv[1:]): training += 1
    try: budget = json.loads((private_root(cfg) / cfg["dgx"]["memory_budget_file"]).read_text())
    except (OSError, ValueError): budget = {}
    digest = hashlib.sha256((model / "model.safetensors.index.json").read_bytes()).hexdigest()
    return dgx_budget_gate(cfg, available, disk, utilization, training, budget, digest, time.time(), probe, smoke)


def train_dgx(cfg: dict, args) -> dict:
    model_path = local_model(args.model)
    if json.loads((model_path / "config.json").read_text()).get("quantization"):
        raise ValueError("DGX trainer requires original HF weights, not MLX packed weights")
    gate = dgx_gate(cfg, model_path, args.probe, args.smoke)
    if not gate["allowed"]:
        raise ValueError("DGX resource gate denied: " + ", ".join(gate["reasons"]))
    import torch
    from datasets import Dataset
    from peft import LoraConfig, get_peft_model
    from transformers import AutoProcessor, BitsAndBytesConfig, Qwen3_5MoeForConditionalGeneration, TrainerCallback
    from trl import SFTConfig, SFTTrainer

    limits = cfg["dgx"]
    directory = run_directory(cfg, args.run_id)
    report = metadata(cfg, "dgx", model_path, args)
    write_report(directory / "run.json", report)
    started = time.monotonic()
    previous_alarm_handler = None
    if args.probe:
        def timeout(signum, frame):
            raise TimeoutError("Technical probe exceeded its 30-minute budget")
        previous_alarm_handler = signal.signal(signal.SIGALRM, timeout)
        signal.setitimer(signal.ITIMER_REAL, limits["probe_max_seconds"])
    try:
        total = torch.cuda.get_device_properties(0).total_memory / 2**30
        fraction = min(0.95, (gate["available_ram_gib"] - limits["runtime_ram_reserve_gib"]) / total)
        if fraction <= 0: raise ValueError("No CUDA allocator budget remains")
        torch.cuda.set_per_process_memory_fraction(fraction, 0)
        report["cuda_allocator_cap_gib"] = fraction * total
        report["memory_budget"] = gate
        precision = limits.get("precision", "bf16")
        report["phase"] = "weight_loading"
        report["loading_precision"] = precision
        report["loading_route"] = "cpu_then_cuda" if precision == "bf16" else "direct_cuda"
        write_report(directory / "run.json", report)
        with WeightLoadWatchdog(limits["runtime_ram_reserve_gib"] + 2, directory), sequential_weight_loading():
            model = load_dgx_weights(Qwen3_5MoeForConditionalGeneration, model_path, precision, torch.bfloat16, BitsAndBytesConfig)
        if any(".experts." in name and parameter.dtype != torch.bfloat16 for name, parameter in model.named_parameters()):
            raise ValueError("Frozen fused experts must remain BF16")
        report["phase"] = "adapter_preparation"
        target_names = targets([n for n, _ in model.named_modules()], cfg)
        # Generic k-bit preparation casts unquantized MoE experts to FP32.
        # Keep the frozen BF16 base intact and enable gradients only at inputs/adapters.
        model.requires_grad_(False)
        model.enable_input_require_grads()
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model = get_peft_model(model, LoraConfig(r=limits["rank"], lora_alpha=limits["alpha"], lora_dropout=0.0, target_modules=target_names, bias="none", task_type="CAUSAL_LM"))
        trained = [n for n, p in model.named_parameters() if p.requires_grad]
        if not trained or any("lora_" not in n for n in trained):
            raise ValueError("Unexpected non-adapter parameters became trainable")
        processor = AutoProcessor.from_pretrained(model_path, local_files_only=True, trust_remote_code=False)
        report["quantized_parameter_tensors"] = sum(type(p).__name__ == "Params4bit" for p in model.parameters())
        report["nonquantized_parameter_elements"] = sum(p.numel() for p in model.parameters() if type(p).__name__ != "Params4bit")
        source = private_root(cfg) / "data/export"
        length = limits["probe_tokens"] if args.probe else cfg["max_tokens"]
        def data_rows(split):
            result = []
            for row in read_jsonl(source / f"{split}.jsonl"):
                tokens = processor.tokenizer.apply_chat_template(row["prompt"] + row["completion"], tokenize=True, return_dict=False, enable_thinking=False)
                if len(tokens) <= length:
                    result.append({"prompt": row["prompt"], "completion": row["completion"]})
            if not result: raise ValueError("No complete samples fit the selected context")
            return result
        train_rows, valid_rows = data_rows("train"), data_rows("valid")
        settings = SFTConfig(output_dir=str(directory / "adapter"), learning_rate=limits["learning_rate"], per_device_train_batch_size=limits["batch_size"], gradient_accumulation_steps=limits["probe_gradient_accumulation"] if args.probe else limits["gradient_accumulation"], max_steps=(limits["probe_smoke_steps"] if args.smoke else limits["probe_steps"]) if args.probe else -1, num_train_epochs=limits["max_epochs"], max_length=length, completion_only_loss=True, bf16=True, gradient_checkpointing=True, logging_steps=1, save_steps=1 if args.smoke else 25, save_total_limit=2, report_to="none", push_to_hub=False, seed=39, data_seed=39, eval_strategy="no" if args.smoke else "steps", eval_steps=25)
        class ResourceGuard(TrainerCallback):
            def on_step_begin(self, training_args, state, control, **kwargs):
                available = int(re.search(r"MemAvailable:\s+(\d+)", Path("/proc/meminfo").read_text()).group(1)) * 1024 / 2**30
                if available < limits["runtime_ram_reserve_gib"] or shutil.disk_usage(directory).free / 2**30 < 20:
                    raise RuntimeError("DGX runtime memory/disk reserve reached")

            def on_log(self, training_args, state, control, logs=None, **kwargs):
                if logs and "loss" in logs and not math.isfinite(float(logs["loss"])):
                    raise RuntimeError("Training loss is not finite")

        trainer = SFTTrainer(model=model, args=settings, processing_class=processor, train_dataset=Dataset.from_list(train_rows), eval_dataset=Dataset.from_list(valid_rows), callbacks=[ResourceGuard()])
        report["targets"] = target_names
        report["trainable_parameters"] = sum(p.numel() for p in model.parameters() if p.requires_grad)
        write_report(directory / "run.json", report)
        trainer.train(resume_from_checkpoint=str(args.resume) if args.resume else None)
        trainer.save_model(str(directory / "adapter"))
        processor.save_pretrained(directory / "adapter")
        report["status"] = "probe_complete" if args.probe else "trained_not_accepted"
        report["peak_memory_bytes"] = torch.cuda.max_memory_allocated()
        return report
    except BaseException as error:
        report["status"] = "interrupted" if isinstance(error, KeyboardInterrupt) else "failed"
        report["error_type"] = type(error).__name__
        raise
    finally:
        if args.probe:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous_alarm_handler)
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        write_report(directory / "run.json", report)
