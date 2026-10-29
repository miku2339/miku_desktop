#!/usr/bin/env python3
"""Check imports and API signatures without loading weights or starting GPU work."""
import importlib.metadata as packages
import inspect
import json
from pathlib import Path

from persona import config, private_root, write_report

cfg = config()
versions = {name: packages.version(name) for name in ["mlx", "mlx-vlm", "transformers", "datasets"]}
from mlx_vlm.trainer import Trainer, VLMTrainingArgs, prepare_model_for_training
from mlx_vlm.trainer.peft.lora_layers import LoRALinear
from mlx_vlm.convert import convert
direct = json.loads(packages.distribution("mlx-vlm").read_text("direct_url.json"))
commit = direct.get("vcs_info", {}).get("commit_id")
if commit != cfg["mac"]["mlx_vlm_commit"]:
    raise SystemExit("Unexpected MLX-VLM revision")
if versions["mlx"] != cfg["mac"]["mlx"] or versions["transformers"] != cfg["mac"]["transformers"]:
    raise SystemExit("Unexpected training dependency version")
settings = VLMTrainingArgs(iters=20, batch_size=1, gradient_accumulation_steps=4, train_on_completions=True, grad_checkpoint=True)
settings.validate()
report = {"versions": versions, "mlx_vlm_commit": commit, "trainer_imported": True, "vlm_conversion_available": True, "lora_fuse_available": callable(LoRALinear.fuse), "weights_loaded": False, "training_started": False}
write_report(private_root(cfg) / "reports/mac-environment.json", report)
print(json.dumps(report, indent=2))
