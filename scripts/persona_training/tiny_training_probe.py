"""Exercise the real SFT stack on synthetic weights under a 256 MiB allocator cap."""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time

from completion_tokens import tokenize_completion
from loader_probe import CAP_BYTES, UNITS, service_state
from load_watchdog import WeightLoadWatchdog, available_memory
from persona import config, private_root, targets, write_report


def resource_gate(memory: float, services: dict) -> None:
    if memory < 48 or set(services) != set(UNITS) or any(value != "active" for value in services.values()):
        raise ValueError("Both inference services must remain active and at least 48 GiB RAM must be available")


def synthetic_config(official: dict) -> dict:
    vocab = official["text_config"]["vocab_size"]
    if vocab != 248320: raise ValueError("The official tokenizer vocabulary changed; review this bounded probe")
    return {"text_config": {"vocab_size": vocab, "hidden_size": 64, "num_hidden_layers": 40,
        "num_attention_heads": 4, "num_key_value_heads": 2, "head_dim": 16,
        "linear_key_head_dim": 16, "linear_value_head_dim": 16, "linear_num_key_heads": 4,
        "linear_num_value_heads": 4, "moe_intermediate_size": 32,
        "shared_expert_intermediate_size": 32, "num_experts": 2, "num_experts_per_tok": 1,
        "max_position_embeddings": 128, "use_cache": False,
        "rope_parameters": {"rope_type": "default", "rope_theta": 10000.0,
            "partial_rotary_factor": 1.0, "mrope_section": [2, 3, 3]}},
        "vision_config": {"depth": 2, "hidden_size": 32, "intermediate_size": 64,
            "num_heads": 4, "patch_size": 4, "spatial_merge_size": 2,
            "temporal_patch_size": 2, "out_hidden_size": 64, "num_position_embeddings": 64},
        **{key: official[key] for key in ["image_token_id", "video_token_id", "vision_start_token_id", "vision_end_token_id"]}}


def synthetic_rows(tokenizer) -> list[dict]:
    rows = []
    for word in ["Hello", "Hi"]:
        row = {"id": "synthetic-" + word, "prompt": [{"role": "system", "content": "Reply with JSON."},
            {"role": "user", "content": word}], "completion": [{"role": "assistant",
                "content": json.dumps({"text": "Hello!", "emotion": "happy", "action": "idle"})}]}
        if word == "Hi":
            row["prompt"][1:1] = [{"role": "user", "content": "Earlier"}, {"role": "assistant",
                "content": json.dumps({"text": "Earlier reply.", "emotion": "calm", "action": "idle"})}]
        rows.append(tokenize_completion(tokenizer, row, 128))
    return rows


def state_digest(model, trainable: bool = False) -> str:
    digest = hashlib.sha256()
    for name, parameter in model.named_parameters():
        if parameter.requires_grad != trainable: continue
        value = parameter.detach().cpu().contiguous().view(-1).view(__import__("torch").uint8)
        digest.update(name.encode())
        digest.update(value.numpy().tobytes())
    return digest.hexdigest()


def run(cfg: dict, metadata: Path, output: Path) -> dict:
    if sys.platform != "linux": raise ValueError("This bounded CUDA probe runs on DGX only")
    root = private_root(cfg)
    if not output.resolve().is_relative_to((root / "reports").resolve()) or output.exists():
        raise ValueError("Use a new private reports path")
    before, ram = service_state(), available_memory()
    resource_gate(ram, before)
    official = json.loads((metadata / "config.json").read_text())
    tiny = synthetic_config(official)
    # Only metadata is read from the original model directory; weights are always newly initialized.
    import torch
    from datasets import Dataset
    from peft import LoraConfig, get_peft_model
    from transformers import AutoProcessor, Qwen3_5MoeConfig, Qwen3_5MoeForConditionalGeneration, TrainerCallback
    from trl import SFTConfig, SFTTrainer

    torch.cuda.set_per_process_memory_fraction(CAP_BYTES / torch.cuda.get_device_properties(0).total_memory, 0)
    torch.cuda.reset_peak_memory_stats()
    processor = AutoProcessor.from_pretrained(metadata, local_files_only=True, trust_remote_code=False)
    rows = synthetic_rows(processor.tokenizer)
    if max(max(row["input_ids"]) for row in rows) >= tiny["text_config"]["vocab_size"]:
        raise ValueError("Official token IDs exceed the tiny model vocabulary")
    report = {"version": 1, "synthetic_model_only": True, "full_model_weights_loaded": False,
        "full_model_training_verified": False, "acceptance_passed": False,
        "allocator_cap_bytes": CAP_BYTES, "gpu_measurement_scope": "torch_allocator_excludes_cuda_driver_context",
        "services_before": before, "available_ram_before_gib": ram,
        "official_vocabulary": tiny["text_config"]["vocab_size"], "language_layers": 40,
        "synthetic_examples": len(rows), "sequence_lengths": [len(row["input_ids"]) for row in rows],
        "completion_mask_source": "unchanged_official_template_offsets_last_json_and_eos",
        "checkpoint_artifacts": "temporary_removed_after_resume_verification", "status": "running"}
    write_report(output, report)
    started = time.monotonic()
    gradients, losses, fused_calls, resumed = [], [], [], []

    class Verify(TrainerCallback):
        def __init__(self, stop_after_one=False): self.stop_after_one = stop_after_one

        def on_train_begin(self, args, state, control, optimizer=None, model=None, **kwargs):
            if not self.stop_after_one:
                steps = [int(value["step"].item()) for value in optimizer.state.values() if "step" in value]
                if state.global_step != 1 or not steps or set(steps) != {1}:
                    raise RuntimeError("Trainer did not restore optimizer/global step 1")
                if state_digest(model, True) != report["stage_1"]["adapter_sha256"]:
                    raise RuntimeError("Trainer did not reload the exact first-step adapter")
                resumed.append({"global_step": state.global_step, "optimizer_steps": sorted(set(steps)),
                    "adapter_reloaded_exactly": True})

        def on_step_begin(self, args, state, control, **kwargs):
            resource_gate(available_memory(), service_state())

        def on_pre_optimizer_step(self, args, state, control, model=None, **kwargs):
            values = [parameter.grad for parameter in model.parameters() if parameter.requires_grad and parameter.grad is not None]
            if not values or not all(torch.isfinite(value).all().item() for value in values):
                raise RuntimeError("Adapter gradients are missing or nonfinite")
            nonzero = sum(torch.count_nonzero(value).item() for value in values)
            if not nonzero: raise RuntimeError("All adapter gradients are zero")
            gradients.append({"before_step": state.global_step, "tensors": len(values), "nonzero_elements": nonzero})

        def on_step_end(self, args, state, control, **kwargs):
            control.should_save = True
            if self.stop_after_one and state.global_step == 1: control.should_training_stop = True
            return control

    class ProbeTrainer(SFTTrainer):
        def compute_loss(self, model, inputs, return_outputs=False, num_items_in_batch=None):
            result = super().compute_loss(model, inputs, return_outputs=return_outputs, num_items_in_batch=num_items_in_batch)
            loss = result[0] if return_outputs else result
            if not torch.isfinite(loss).item(): raise RuntimeError("Tiny SFT loss is nonfinite")
            losses.append(float(loss.detach().cpu()))
            return result

    def observe_forward(module, args, kwargs, outputs):
        if kwargs.get("fused_lm_head") is True:
            if not hasattr(outputs, "log_probs") or not hasattr(outputs, "label_mask"):
                raise RuntimeError("The real TRL fused LM head outputs are missing")
            fused_calls.append(True)

    def create_model():
        torch.manual_seed(39)
        model = Qwen3_5MoeForConditionalGeneration(Qwen3_5MoeConfig(**tiny)).to(dtype=torch.bfloat16)
        weight_bytes = sum(parameter.numel() * parameter.element_size() for parameter in model.parameters())
        if weight_bytes > CAP_BYTES // 2: raise ValueError("Synthetic weights exceed the bounded size")
        names = targets([name for name, _ in model.named_modules()], cfg)
        model.requires_grad_(False)
        model.enable_input_require_grads()
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model = get_peft_model(model, LoraConfig(r=16, lora_alpha=32, lora_dropout=0.0,
            target_modules=names, bias="none", task_type="CAUSAL_LM"))
        if not model.is_gradient_checkpointing: raise RuntimeError("Gradient checkpointing is not active")
        trainable = [name for name, parameter in model.named_parameters() if parameter.requires_grad]
        if len(names) != 190 or not trainable or any("lora_" not in name for name in trainable):
            raise RuntimeError("Unexpected trainable parameters or target projections")
        if any(any(key in name for key in ["visual", "experts", "gate"]) for name in trainable):
            raise RuntimeError("Vision, experts or router became trainable")
        report.update({"weight_bytes": weight_bytes, "target_count": len(names), "trainable_tensors": len(trainable),
            "gradient_checkpointing": True,
            "vision_parameter_tensors": sum(".visual." in name for name, _ in model.named_parameters())})
        return model.to("cuda:0")

    try:
        with tempfile.TemporaryDirectory(prefix="tiny-sft-", dir=root) as temporary:
            work = Path(temporary)
            with WeightLoadWatchdog(16, work):
                frozen, adapters = [], []
                for stage in [1, 2]:
                    resource_gate(available_memory(), service_state())
                    model = create_model()
                    frozen.append(state_digest(model))
                    adapters.append(state_digest(model, True))
                    settings = SFTConfig(output_dir=str(work / "adapter"), max_steps=2, learning_rate=5e-5,
                        per_device_train_batch_size=1, gradient_accumulation_steps=1, max_length=128,
                        completion_only_loss=True, bf16=True, gradient_checkpointing=True,
                        gradient_checkpointing_kwargs={"use_reentrant": False}, optim="adamw_torch",
                        logging_steps=1, save_steps=1, save_total_limit=2, report_to="none", push_to_hub=False,
                        seed=39, data_seed=39, eval_strategy="no", dataloader_pin_memory=False, disable_tqdm=True)
                    trainer = ProbeTrainer(model=model, args=settings, processing_class=processor,
                        train_dataset=Dataset.from_list(rows), callbacks=[Verify(stage == 1)])
                    hook = model.register_forward_hook(observe_forward, with_kwargs=True)
                    batch = trainer.data_collator(rows)
                    for i, row in enumerate(rows):
                        if batch["labels"][i, :len(row["labels"])].tolist() != row["labels"]:
                            raise RuntimeError("Real TRL collator changed the completion-only labels")
                        if not all(value == -100 for value in batch["labels"][i, len(row["labels"]):].tolist()):
                            raise RuntimeError("Real TRL collator supervised padding tokens")
                    trainer.train(resume_from_checkpoint=str(work / "adapter/checkpoint-1") if stage == 2 else None)
                    checkpoint = work / f"adapter/checkpoint-{stage}"
                    required = ["adapter_model.safetensors", "optimizer.pt", "scheduler.pt", "rng_state.pth", "trainer_state.json"]
                    if trainer.state.global_step != stage or not all((checkpoint / name).is_file() for name in required):
                        raise RuntimeError("Full resumable Trainer checkpoint is incomplete")
                    if frozen[-1] != state_digest(model) or adapters[-1] == state_digest(model, True):
                        raise RuntimeError("Frozen weights changed or adapter weights did not change")
                    steps = [int(value["step"].item()) for value in trainer.optimizer.state.values() if "step" in value]
                    if not steps or set(steps) != {stage}: raise RuntimeError("Optimizer step did not advance")
                    report[f"stage_{stage}"] = {"global_step": trainer.state.global_step,
                        "optimizer_steps": sorted(set(steps)), "checkpoint_files": required,
                        "frozen_unchanged": True, "adapter_changed": True,
                        "adapter_sha256": state_digest(model, True), "frozen_sha256": frozen[-1]}
                    hook.remove()
                    del batch, trainer, model
                    gc.collect()
                    torch.cuda.empty_cache()
                if len(set(frozen)) != 1 or len(set(adapters)) != 1:
                    raise RuntimeError("Fresh base and adapter initializations were not reproducible")
                if report["stage_1"]["adapter_sha256"] == report["stage_2"]["adapter_sha256"]:
                    raise RuntimeError("Resumed second step did not change the first-step adapter")
        if len(gradients) != 2 or len(resumed) != 1 or len(fused_calls) != 2:
            raise RuntimeError("Expected exactly two genuine SFT optimizer steps and one resume")
        report.update({"status": "tiny_stack_passed", "gradients": gradients, "losses": losses,
            "fused_lm_head_calls": len(fused_calls), "resume_observations": resumed,
            "vision_experts_router_frozen": True, "completion_labels_preserved": True})
    except BaseException as error:
        report.update({"status": "failed", "error_type": type(error).__name__, "error": str(error)[:1200]})
        raise
    finally:
        report.update({"elapsed_seconds": time.monotonic() - started, "services_after": service_state(),
            "available_ram_after_gib": available_memory(), "peak_allocated_bytes": torch.cuda.max_memory_allocated(),
            "peak_reserved_bytes": torch.cuda.max_memory_reserved(), "torch_version": torch.__version__})
        if report["peak_reserved_bytes"] > CAP_BYTES or report["services_after"] != before:
            report["status"] = "failed"
        write_report(output, report)
    if report["status"] != "tiny_stack_passed": raise RuntimeError("Tiny probe did not pass its final safety checks")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    result = run(config(), args.metadata, args.output) if args.execute else {
        "dry_run": True, "synthetic_model_only": True, "would_load_full_weights": False,
        "would_change_services": False, "allocator_cap_bytes": CAP_BYTES}
    print(json.dumps(result, indent=2))
