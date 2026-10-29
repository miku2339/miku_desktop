"""Resumable single-device MLX microsteps with safe resource pauses."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import shutil
import signal
import threading
import uuid


class TrainingPaused(RuntimeError):
    pass


class ResourceMonitor:
    def __init__(self, observe, interval=2):
        self.observe = observe
        self.interval = interval
        self.reason = None
        self.stop = threading.Event()

    def _poll(self):
        try:
            reasons = self.observe()
            if reasons:
                self.reason = ", ".join(reasons)
        except Exception:
            self.reason = "resource_observation_failed"

    def __enter__(self):
        self._poll()
        self.handlers = {}
        if threading.current_thread() is threading.main_thread():
            for number in [signal.SIGINT, signal.SIGTERM]:
                self.handlers[number] = signal.getsignal(number)
                signal.signal(number, lambda number, frame: self.request_pause(f"signal_{number}"))
        def watch():
            while not self.stop.wait(self.interval) and self.reason is None:
                self._poll()
        self.thread = threading.Thread(target=watch, daemon=True)
        self.thread.start()
        return self

    def request_pause(self, reason):
        self.reason = self.reason or reason

    def check(self):
        if self.reason is not None:
            raise TrainingPaused(self.reason)

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=self.interval + 1)
        for number, handler in self.handlers.items():
            signal.signal(number, handler)


def checkpoint_directory(path: Path) -> Path:
    path = Path(path).expanduser().resolve()
    if (path / "latest.json").is_file():
        name = json.loads((path / "latest.json").read_text())["directory"]
        if Path(name).name != name or not name.startswith("state-"):
            raise ValueError("Invalid checkpoint pointer")
        path = path / name
    if not (path / "checkpoint.json").is_file():
        raise ValueError("Resume requires a full training checkpoint, not adapter weights alone")
    return path


def _pack(value, arrays, mx):
    if isinstance(value, mx.array):
        key = f"array_{len(arrays)}"
        arrays[key] = value
        return {"array": key}
    if isinstance(value, dict):
        return {"dict": [[key, _pack(item, arrays, mx)] for key, item in value.items()]}
    if isinstance(value, (list, tuple)):
        return {"tuple" if isinstance(value, tuple) else "list": [_pack(item, arrays, mx) for item in value]}
    if value is None or type(value) in [str, int, float, bool]:
        return {"scalar": value}
    raise TypeError(f"Unsupported checkpoint state: {type(value).__name__}")


def _unpack(value, arrays):
    if "array" in value: return arrays[value["array"]]
    if "dict" in value: return {key: _unpack(item, arrays) for key, item in value["dict"]}
    if "tuple" in value: return tuple(_unpack(item, arrays) for item in value["tuple"])
    if "list" in value: return [_unpack(item, arrays) for item in value["list"]]
    return value["scalar"]


def _step_seed(seed, iteration):
    return int.from_bytes(hashlib.sha256(f"{seed}:{iteration}".encode()).digest()[:4], "big")


def train_resumable(trainer, destination: Path, fingerprint: str, guard, *, resume=None, seed=39, save_every=20):
    import mlx.core as mx
    import mlx.nn as nn
    import numpy as np
    from mlx_vlm.trainer.common.utils import apply_gradient_step, apply_final_accumulated_gradients

    args, model, task, optimizer = trainer.args, trainer.model, trainer.task, trainer.optimizer
    args.validate()
    if mx.distributed.init().size() != 1:
        raise ValueError("Mac checkpoints support one training device")
    if args.grad_checkpoint:
        if task.checkpoint is None: raise ValueError("Missing gradient checkpoint implementation")
        task.checkpoint(model)
    optimizer.init(model.trainable_parameters())
    random.seed(seed)
    np.random.seed(seed)
    completed, updates, gradients = 0, 0, None
    restored_rng = None
    if resume:
        source = checkpoint_directory(resume)
        saved = json.loads((source / "checkpoint.json").read_text())
        if saved.get("version") != 1 or saved.get("fingerprint") != fingerprint or saved.get("seed") != seed:
            raise ValueError("Checkpoint model, data or training configuration does not match")
        completed, updates = saved["completed_microsteps"], saved["optimizer_steps"]
        if type(completed) is not int or not 0 <= completed <= args.iters or saved.get("data_cursor") != completed:
            raise ValueError("Invalid checkpoint cursor")
        model.load_weights(str(source / "adapter/weights.safetensors"), strict=False)
        state = _unpack(saved["state"], mx.load(str(source / "state.safetensors")))
        optimizer.state, gradients = state["optimizer"], state["gradients"]
        restored_rng = saved["rng"]
        if restored_rng.get("mlx") != {"strategy": "microstep_seed_v1", "seed": seed, "next_microstep": completed + 1}:
            raise ValueError("Invalid MLX RNG checkpoint")
    # The pinned VLM iterator owns a seeded NumPy generator. Replay preprocessing only,
    # then restore process RNGs before the next forward pass.
    iterator = iter(task.batches(trainer.train_dataset, train=True, seed=seed))
    for _ in range(completed):
        try:
            guard()
        except TrainingPaused as error:
            return {"status": "paused", "reason": str(error), "completed_microsteps": completed,
                "remaining_microsteps": args.iters - completed, "checkpoint": str(source)}
        next(iterator)
    if restored_rng:
        random.setstate(_unpack(restored_rng["python"], {}))
        numpy = restored_rng["numpy"]
        np.random.set_state((numpy[0], np.asarray(numpy[1], dtype=np.uint32), numpy[2], numpy[3], numpy[4]))
    model.train()
    value_and_grad = task.value_and_grad_factory(model, False) if task.value_and_grad_factory else nn.value_and_grad(model, task.loss)
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)

    def save(status):
        arrays = {}
        state = _pack({"optimizer": optimizer.state, "gradients": gradients}, arrays, mx)
        mx.eval(model.trainable_parameters(), list(arrays.values()))
        numpy = np.random.get_state()
        record = {"version": 1, "fingerprint": fingerprint, "seed": seed,
            "completed_microsteps": completed, "optimizer_steps": updates, "data_cursor": completed,
            "total_microsteps": args.iters, "remaining_microsteps": args.iters - completed,
            "status": status, "state": state, "rng": {
                "mlx": {"strategy": "microstep_seed_v1", "seed": seed, "next_microstep": completed + 1},
                "python": _pack(random.getstate(), {}, mx),
                "numpy": [numpy[0], numpy[1].tolist(), numpy[2], numpy[3], numpy[4]]}}
        staging = destination / f".state-{uuid.uuid4().hex}"
        final = destination / staging.name[1:]
        staging.mkdir(mode=0o700)
        try:
            trainer.save_adapter(str(staging / "adapter/weights.safetensors"))
            mx.save_safetensors(str(staging / "state.safetensors"), arrays)
            (staging / "checkpoint.json").write_text(json.dumps(record, allow_nan=False) + "\n")
            for file in staging.rglob("*"):
                if file.is_file(): file.chmod(0o600)
            staging.rename(final)
            pointer = destination / ".latest.tmp"
            pointer.write_text(json.dumps({"directory": final.name}) + "\n")
            pointer.chmod(0o600)
            pointer.replace(destination / "latest.json")
            # Keep the current state and one previous usable rollback.
            previous = sorted((p for p in destination.glob("state-*") if p != final), key=lambda p: p.stat().st_mtime, reverse=True)
            for old in previous[1:]: shutil.rmtree(old)
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise
        return final

    try:
        while completed < args.iters:
            guard()
            before_batch = random.getstate(), np.random.get_state()
            batch = next(iterator)
            try:
                guard()
            except TrainingPaused:
                random.setstate(before_batch[0])
                np.random.set_state(before_batch[1])
                del batch
                raise
            # Explicit per-microstep seeding makes resume independent of opaque global
            # MLX RNG state while preserving every random draw within that microstep.
            mx.random.seed(_step_seed(seed, completed + 1))
            extra = task.loss_args(batch) if task.loss_args else ()
            update = (completed + 1) % args.gradient_accumulation_steps == 0
            loss, metrics, gradients = apply_gradient_step(model, optimizer, value_and_grad, batch, gradients,
                update=update, accumulation_steps=args.gradient_accumulation_steps, loss_args=extra)
            mx.eval(model.state, optimizer.state, gradients, loss)
            if not bool(mx.isfinite(loss).item()): raise RuntimeError("Training loss is not finite")
            completed += 1
            updates += int(update)
            if completed == args.iters:
                updates += int(apply_final_accumulated_gradients(model, optimizer, gradients, completed, args.gradient_accumulation_steps) > 0)
                gradients = None
            del batch, extra, loss, metrics
            guard()
            if completed % save_every == 0: save("running")
        final = save("complete")
        return {"status": "complete", "completed_microsteps": completed, "remaining_microsteps": 0, "checkpoint": str(final)}
    except TrainingPaused as error:
        final = save("paused")
        return {"status": "paused", "reason": str(error) or "interrupted", "completed_microsteps": completed,
            "remaining_microsteps": args.iters - completed, "checkpoint": str(final)}
