#!/usr/bin/env python3
"""Private Miku persona data preparation and fail-closed training entry point."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent


def config(path: Path | None = None) -> dict:
    return json.loads((path or HERE / "manifest.json").read_text())


def private_root(cfg: dict) -> Path:
    return Path(os.environ.get("MIKU_TRAINING_ROOT", cfg["private_root"])).expanduser().resolve()


def training_profile(cfg: dict, device: str, probe: bool, smoke: bool = False) -> dict:
    values = cfg[device]
    steps = (values.get("probe_smoke_steps", 1) if smoke else values["probe_steps"]) if probe else values.get("max_steps")
    return {"steps": steps, "gradient_accumulation": values["probe_gradient_accumulation"] if probe else values["gradient_accumulation"], "max_tokens": values["probe_tokens"] if probe else cfg["max_tokens"], "max_epochs": values.get("max_epochs"), "not_for_deployment": True}


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))
    path.chmod(0o600)


def write_report(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    path.chmod(0o600)


def family_splits(rows: list[dict], cfg: dict) -> dict[str, str]:
    families = sorted({r["family"] for r in rows})
    families.sort(key=lambda f: hashlib.sha256((cfg["split"]["seed"] + f).encode()).hexdigest())
    n = len(families)
    valid = max(1, round(n * cfg["split"]["valid"] / 100))
    test = max(1, round(n * cfg["split"]["test"] / 100))
    if n < 3 or valid + test >= n:
        raise ValueError("At least three scenario families are required")
    return {f: ("test" if i < test else "valid" if i < test + valid else "train") for i, f in enumerate(families)}


def validate_rows(rows: list[dict], cfg: dict) -> dict:
    ids, pairs, errors = set(), set(), []
    for row in rows:
        ident = row.get("id", "")
        if not ident or ident in ids:
            errors.append(f"duplicate/missing id: {ident}")
        ids.add(ident)
        if not row.get("family") or not row.get("scenario"):
            errors.append(f"missing scenario/family: {ident}")
        if row.get("language") not in cfg["languages"] or row.get("mode") not in cfg["modes"]:
            errors.append(f"invalid language/mode: {ident}")
        if row.get("status") not in ["pending", "accepted", "rejected"]:
            errors.append(f"invalid review status: {ident}")
        messages = row.get("messages", [])
        if len(messages) < 4 or len(messages) % 2:
            errors.append(f"requires a complete multi-turn exchange: {ident}")
        for i, message in enumerate(messages):
            if message.get("role") != ("user" if i % 2 == 0 else "assistant") or not str(message.get("content", "")).strip():
                errors.append(f"invalid turn: {ident}/{i}")
        pair = json.dumps(messages, ensure_ascii=False, sort_keys=True)
        if pair in pairs:
            errors.append(f"duplicate conversation: {ident}")
        pairs.add(pair)
    if errors:
        raise ValueError("; ".join(errors[:30]))
    return {"rows": len(rows), "families": len({r['family'] for r in rows}), "pending": sum(r["status"] == "pending" for r in rows), "counts": {lang: {mode: sum(r["language"] == lang and r["mode"] == mode for r in rows) for mode in cfg["modes"]} for lang in cfg["languages"]}}


def context_message(row: dict, cfg: dict) -> dict:
    rule = "Use Taiwan Mandarin." if row["language"] == "zh-TW" else {"ja": "Use natural Japanese.", "en": "Use conversational English.", "yue": "Use Hong Kong written Cantonese.", "ko": "Use natural Korean."}[row["language"]]
    state = row.get("context", {})
    body = "You are Hatsune Miku, a cheerful virtual singer and desktop companion with your own opinions. Be warm, specific, curious without interrogating, and honest about capabilities and missing knowledge. " + rule
    body += " " + cfg["relationship_policy"]
    body += " Voice mode: use speakable short sentences and natural pauses." if row["mode"] == "voice" else " Text mode: match the detail to the conversation."
    body += " App state: " + json.dumps(state, ensure_ascii=False, sort_keys=True)
    body += ' Reply with JSON fields text, emotion and action. Do not invent lyrics, memories, facts or completed tool actions.'
    return {"role": "system", "content": body}


def expand_rows(rows: list[dict], cfg: dict) -> list[dict]:
    result = []
    for row in rows:
        if row["status"] == "rejected":
            continue
        prior = [context_message(row, cfg)]
        for i, message in enumerate(row["messages"]):
            converted = dict(message)
            if message["role"] == "assistant":
                converted["content"] = json.dumps({"text": message["content"], "emotion": message.get("emotion", "calm"), "action": message.get("action", "idle")}, ensure_ascii=False)
                result.append({"id": f"{row['id']}-turn-{i // 2 + 1}", "family": row["family"], "language": row["language"], "mode": row["mode"], "status": row["status"], "prompt": list(prior), "completion": [converted]})
            prior.append(converted)
    return result


def prepare(cfg: dict) -> dict:
    root = private_root(cfg)
    rows = read_jsonl(root / "data/candidates.jsonl")
    report = validate_rows(rows, cfg)
    splits = family_splits(rows, cfg)
    report["splits"] = {}
    for split in ["train", "valid", "test"]:
        subset = [r for r in rows if splits[r["family"]] == split]
        write_jsonl(root / "data/export" / f"{split}.jsonl", expand_rows(subset, cfg))
        report["splits"][split] = {"families": len({r["family"] for r in subset}), "conversations": len(subset), "completions": len(expand_rows(subset, cfg))}
    report["data_sha256"] = hashlib.sha256((root / "data/candidates.jsonl").read_bytes()).hexdigest()
    report["training_approved"] = report["pending"] == 0
    write_report(root / "reports/data-validation.json", report)
    return report


def calibrate(cfg: dict, selections: Path) -> dict:
    root = private_root(cfg)
    values = json.loads(selections.read_text())
    cases = read_jsonl(root / "data/calibration.jsonl")
    known = {r["id"] for r in cases}
    if set(values) - known:
        raise ValueError("Unknown calibration IDs")
    if any(v not in ["A", "B", "both", "neither"] for v in values.values()):
        raise ValueError("Selections must be A, B, both or neither")
    write_report(root / "data/calibration-selections.json", values)
    return {"selected": len(values), "total": len(cases), "complete": len(values) == len(cases), "neither": sum(v == "neither" for v in values.values())}


def tokenize(cfg: dict, model: str | None) -> dict:
    from transformers import AutoTokenizer
    root = private_root(cfg)
    tokenizer = AutoTokenizer.from_pretrained(model or str(Path(cfg["mac_base_model"]).expanduser()), local_files_only=True, trust_remote_code=False)
    result = {"max_tokens": cfg["max_tokens"], "splits": {}, "overflow_ids": []}
    for split in ["train", "valid", "test"]:
        rows = read_jsonl(root / "data/export" / f"{split}.jsonl")
        lengths = []
        for row in rows:
            messages = row["prompt"] + row["completion"]
            tokens = tokenizer.apply_chat_template(messages, tokenize=True, return_dict=False, add_generation_prompt=False, enable_thinking=False)
            lengths.append(len(tokens))
            if len(tokens) > cfg["max_tokens"]:
                result["overflow_ids"].append(row["id"])
        result["splits"][split] = {"count": len(lengths), "max": max(lengths, default=0), "mean": round(sum(lengths) / max(len(lengths), 1), 1)}
    result["data_sha256"] = hashlib.sha256((root / "data/candidates.jsonl").read_bytes()).hexdigest()
    result["passed"] = not result["overflow_ids"]
    write_report(root / "reports/token-lengths.json", result)
    return result


def mac_observations(cfg: dict) -> dict:
    now = time.time()
    root = private_root(cfg)
    observations = {"now": now, "platform": sys.platform, "free_disk_gib": shutil.disk_usage(root).free / 2**30}
    try:
        power = subprocess.check_output(["/usr/bin/pmset", "-g", "batt"], text=True)
        observations["ac_power"] = "AC Power" in power
        idle = subprocess.check_output(["/usr/sbin/ioreg", "-c", "IOHIDSystem"], text=True)
        observations["idle_seconds"] = int(re.search(r'"HIDIdleTime"\s*=\s*(\d+)', idle).group(1)) / 1e9
        vm = subprocess.check_output(["/usr/bin/vm_stat"], text=True)
        page = int(re.search(r"page size of (\d+) bytes", vm).group(1))
        counts = [int(re.search(name + r":\s+(\d+)", vm).group(1)) for name in ["Pages free", "Pages inactive", "Pages speculative"]]
        observations["available_ram_gib"] = sum(counts) * page / 2**30
    except (OSError, subprocess.SubprocessError, AttributeError, ValueError) as error:
        observations["probe_error"] = type(error).__name__
    try:
        pressure = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"], text=True).strip())
        observations["memory_pressure"] = {1: "normal", 2: "warning", 4: "critical"}.get(pressure, "unknown")
    except (OSError, subprocess.SubprocessError, ValueError):
        observations["memory_pressure"] = "unknown"
    try:
        state = json.loads((root / "runtime/voice-call-state.json").read_text())
        pid = state.get("pid")
        if type(pid) is not int or pid <= 0:
            raise ValueError("invalid pid")
        os.kill(pid, 0)
        observations["voice_state"] = state
        observations["voice_state_live"] = True
    except (OSError, ValueError, TypeError):
        observations["voice_state_live"] = False
    return observations


def mac_gate(cfg: dict, observations: dict) -> dict:
    limits = cfg["mac"]
    reasons = []
    if observations.get("platform") != "darwin": reasons.append("not_macos")
    if not observations.get("ac_power"): reasons.append("not_on_ac_power")
    if observations.get("idle_seconds", 0) < limits["min_idle_seconds"]: reasons.append("user_not_idle_10_minutes")
    if observations.get("available_ram_gib", 0) < limits["min_free_ram_gib"]: reasons.append("insufficient_available_ram")
    if observations.get("memory_pressure") != "normal": reasons.append("memory_pressure_not_normal")
    if observations.get("free_disk_gib", 0) < limits["min_free_disk_gib"]: reasons.append("insufficient_disk")
    state = observations.get("voice_state", {})
    stamp = state.get("updated_at")
    fresh = type(stamp) in [int, float] and 0 <= observations["now"] - stamp <= limits["heartbeat_max_age_seconds"]
    if not observations.get("voice_state_live") or state.get("version") != 1 or not fresh: reasons.append("missing_or_stale_app_heartbeat")
    elif state.get("active") is not False: reasons.append("voice_call_active_or_unknown")
    return {"allowed": not reasons, "reasons": reasons, "observations": observations}


def targets(names: list[str], cfg: dict, last_layers: int | None = None) -> list[str]:
    pattern = re.compile(cfg["target_pattern"])
    result = [n for n in names if pattern.fullmatch(n)]
    if len(result) != cfg["expected_language_targets"]:
        raise ValueError(f"Expected {cfg['expected_language_targets']} language projection targets, found {len(result)}")
    if last_layers is not None:
        largest = max(int(pattern.fullmatch(n).group(1)) for n in result)
        result = [n for n in result if int(pattern.fullmatch(n).group(1)) > largest - last_layers]
    return result


def require_data(cfg: dict, probe: bool) -> None:
    root = private_root(cfg)
    validated = prepare(cfg)
    lengths = json.loads((root / "reports/token-lengths.json").read_text())
    if not lengths.get("passed") or lengths.get("data_sha256") != validated["data_sha256"]:
        raise ValueError("Current corpus must pass token-length validation before training")
    if not probe and not validated["training_approved"]:
        raise ValueError("Full training requires accepted/rejected review status for every candidate")
    if not probe:
        review = json.loads((root / "data/calibration-review.json").read_text())
        if review.get("completed") is not True:
            raise ValueError("The owner must explicitly complete style calibration before full training")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ["prepare", "validate", "gate", "status"]: commands.add_parser(name)
    tok = commands.add_parser("tokenize"); tok.add_argument("--model")
    cal = commands.add_parser("calibrate"); cal.add_argument("selections", type=Path)
    for name in ["train-mac", "train-dgx"]:
        p = commands.add_parser(name); p.add_argument("--probe", action="store_true"); p.add_argument("--smoke", action="store_true"); p.add_argument("--resume", type=Path); p.add_argument("--dry-run", action="store_true"); p.add_argument("--model"); p.add_argument("--run-id", required=True)
        if name == "train-dgx": p.add_argument("--precision", choices=["bf16", "nf4"])
    args = parser.parse_args()
    cfg = config(args.manifest)
    if args.command in ["prepare", "validate"]: result = prepare(cfg)
    elif args.command == "tokenize": result = tokenize(cfg, args.model)
    elif args.command == "calibrate": result = calibrate(cfg, args.selections)
    elif args.command == "gate": result = mac_gate(cfg, mac_observations(cfg))
    elif args.command == "status":
        root = private_root(cfg)
        result = {"root": str(root), "data_exists": (root / "data/candidates.jsonl").exists(), "mac_environment": (root / "envs/mac/bin/python").exists(), "gate": mac_gate(cfg, mac_observations(cfg))}
    else:
        if args.command == "train-dgx" and args.precision:
            cfg["dgx"]["precision"] = args.precision
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", args.run_id): raise ValueError("Invalid run ID")
        if args.smoke and not args.probe: raise ValueError("--smoke requires --probe")
        if args.dry_run:
            device = args.command.removeprefix("train-")
            result = {"dry_run": True, "device": device, "probe": args.probe, "run_id": args.run_id, "configuration": cfg[device], "effective_profile": training_profile(cfg, device, args.probe, args.smoke), "would_run_gpu": False}
        else:
            require_data(cfg, args.probe)
            from train import train_mac, train_dgx
            result = train_mac(cfg, args) if args.command == "train-mac" else train_dgx(cfg, args)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try: main()
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
