"""Run one resumable Mac technical probe only during the approved idle conditions."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from persona import config, mac_gate, mac_observations, private_root, write_report
from mac_loop import checkpoint_directory


def stop_child(child, deadline: float) -> int:
    if child.poll() is not None:
        return child.wait()
    # Every child is launched in its own new session; never signal the queue's group.
    try: os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError: pass
    try:
        return child.wait(timeout=max(0, min(90, deadline - time.monotonic())))
    except subprocess.TimeoutExpired:
        try: os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        return child.wait()


def run_child(command: list[str], log, deadline: float) -> tuple[int, bool]:
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        try:
            return child.wait(timeout=max(0, deadline - time.monotonic() - 90)), False
        except subprocess.TimeoutExpired:
            return stop_child(child, deadline), True
    finally:
        if child.poll() is None:
            stop_child(child, deadline)
        else:
            child.wait()


def run(cfg: dict, hours: float, resume: Path | None = None) -> dict:
    root = private_root(cfg)
    checkpoint = None
    if resume:
        source = checkpoint_directory(resume)
        if not source.is_relative_to((root / "runs").resolve()):
            raise ValueError("Initial checkpoint must belong to this private training root")
        checkpoint = str(source)
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    status_path = runtime / "mac-probe-queue.json"
    with (runtime / "mac-probe-queue.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        deadline = time.time() + hours * 3600
        hard_deadline = time.monotonic() + hours * 3600
        attempt = 0
        last_reasons = None
        while time.monotonic() < hard_deadline:
            gate = mac_gate(cfg, mac_observations(cfg))
            if not gate["allowed"]:
                if gate["reasons"] != last_reasons:
                    write_report(status_path, {"status": "waiting", "pid": os.getpid(), "reasons": gate["reasons"], "deadline": deadline, "checkpoint": checkpoint})
                    last_reasons = gate["reasons"]
                time.sleep(30)
                continue
            if hard_deadline - time.monotonic() <= 90:
                break
            attempt += 1
            run_id = f"mac-idle-probe-{int(time.time())}-{attempt}"
            command = [sys.executable, str(Path(__file__).with_name("persona.py")), "train-mac", "--probe", "--run-id", run_id]
            if checkpoint:
                command += ["--resume", checkpoint]
            write_report(status_path, {"status": "running", "pid": os.getpid(), "run_id": run_id, "deadline": deadline})
            report_path = root / "runs" / run_id / "run.json"
            with (root / "logs/mac-idle-probe.log").open("ab") as log:
                try:
                    exit_code, expired = run_child(command, log, hard_deadline)
                except KeyboardInterrupt:
                    report = json.loads(report_path.read_text()) if report_path.is_file() else {}
                    if report.get("status") == "paused": checkpoint = report["checkpoint"]
                    value = {"status": "cancelled", "run_id": run_id, "checkpoint": checkpoint, "acceptance_passed": False}
                    write_report(status_path, value)
                    return value
            report = json.loads(report_path.read_text()) if report_path.is_file() else {}
            if expired:
                if exit_code == 0 and report.get("status") == "paused": checkpoint = report["checkpoint"]
                if exit_code != 0 or report.get("status") != "probe_complete":
                    value = {"status": "expired_checkpointed" if exit_code == 0 and report.get("status") == "paused" else "expired_stopped", "run_id": run_id, "exit_code": exit_code, "checkpoint": checkpoint, "acceptance_passed": False}
                    write_report(status_path, value)
                    return value
            if exit_code != 0 or report.get("status") not in ["paused", "probe_complete"]:
                value = {"status": "failed", "run_id": run_id, "exit_code": exit_code, "report": str(report_path)}
                write_report(status_path, value)
                return value
            if report["status"] == "probe_complete":
                value = {"status": "probe_complete", "run_id": run_id, "report": str(report_path), "acceptance_passed": False}
                write_report(status_path, value)
                return value
            checkpoint = report["checkpoint"]
            last_reasons = None
            time.sleep(30)
        value = {"status": "expired_waiting_for_idle", "checkpoint": checkpoint, "acceptance_passed": False}
        write_report(status_path, value)
        return value


if __name__ == "__main__":
    def cancel_queue(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, cancel_queue)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hours", type=float, default=6)
    parser.add_argument("--resume", type=Path)
    args = parser.parse_args()
    if not 0 < args.hours <= 6:
        parser.error("The technical-probe queue is limited to six hours")
    cfg = config()
    (private_root(cfg) / "logs").mkdir(mode=0o700, parents=True, exist_ok=True)
    print(json.dumps(run(cfg, args.hours, args.resume)))
