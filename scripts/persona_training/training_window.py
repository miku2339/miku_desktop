"""Bounded, owner-approved DGX training window with an independent restore timer."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import re
import subprocess
import time


UNITS = ("spark-model.service", "maritime-model.service")


def systemctl(*args: str, check: bool = True):
    return subprocess.run(["systemctl", "--user", *args], capture_output=True, text=True, check=check)


def write(path: Path, value: dict) -> None:
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, indent=2) + "\n")
    temp.chmod(0o600)
    temp.replace(path)


def process_start(pid: int) -> str:
    return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]


def finish_run(root: Path, run_id: str | None, code: int) -> None:
    if not run_id or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", run_id):
        return
    directory = root / "private/runs" / run_id
    path = directory / "run.json"
    if directory.is_symlink() or not path.is_file():
        return
    report = json.loads(path.read_text())
    if report.get("run_id") != run_id or report.get("status") != "running":
        return
    steps = 0
    for checkpoint in (directory / "adapter").glob("checkpoint-*/trainer_state.json"):
        value = json.loads(checkpoint.read_text()).get("global_step")
        if type(value) is int and 0 <= value <= 50:
            steps = max(steps, value)
    status = "timed_out" if code == 124 else "interrupted" if code < 0 else "failed"
    report.update(status=status, external_exit_code=code, verified_checkpoint_steps=steps,
        finished_at=datetime.now(timezone.utc).isoformat(), for_deployment=False, acceptance_passed=False)
    write(path, report)


def stop_child(pid: int | None, started: str | None = None) -> None:
    if not pid:
        return
    try:
        if started is not None and process_start(pid) != started:
            return
        if os.getpgid(pid) != pid:
            raise RuntimeError("Training process no longer owns its recorded process group")
        os.killpg(pid, signal.SIGTERM)
        for _ in range(50):
            time.sleep(0.1)
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, FileNotFoundError):
        pass


def restore(lease_path: Path) -> dict:
    import fcntl

    with lease_path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        lease = json.loads(lease_path.read_text())
        if lease.get("restored_at"):
            return lease
        if set(lease.get("originally_active", [])) - set(UNITS):
            raise ValueError("Unexpected service in lease")
        terminated = lease.get("child_pid") is not None
        stop_child(lease.get("child_pid"), lease.get("child_started"))
        if terminated:
            try:
                finish_run(lease_path.parent.parent, lease.get("run_id"),
                    124 if time.time() >= lease["deadline"] else -signal.SIGTERM)
            except (OSError, ValueError, TypeError, AttributeError) as error:
                lease["run_receipt_error"] = type(error).__name__
        results = {}
        for unit in lease["originally_active"]:
            result = systemctl("start", unit, check=False)
            results[unit] = result.returncode == 0 and systemctl("is-active", unit, check=False).stdout.strip() == "active"
        lease["restoration"] = results
        if all(results.values()):
            lease["restored_at"] = time.time()
        write(lease_path, lease)
        if not all(results.values()):
            raise RuntimeError("One or more original model services did not restart")
        return lease


def run_window(root: Path, approval_path: Path, command: list[str], dry_run: bool) -> dict:
    root = root.resolve()
    approval = json.loads(approval_path.read_text())
    if approval.get("approved_by") != "user" or set(approval.get("units", [])) != set(UNITS):
        raise ValueError("An explicit owner approval for both model services is required")
    seconds = approval.get("max_seconds")
    if not isinstance(seconds, int) or isinstance(seconds, bool) or not 60 <= seconds <= 1800:
        raise ValueError("The window must be at most 30 minutes")
    if not time.time() < approval.get("expires_at", 0):
        raise ValueError("The approval has expired")
    if approval.get("original_deadline") is not None:
        seconds = min(seconds, int(approval["original_deadline"] - time.time()) - 2)
        if seconds < 60:
            raise ValueError("The original approval window has insufficient time remaining")
    used_path = approval_path.with_suffix(".used.json")
    if used_path.exists():
        raise ValueError("This training window approval was already used")
    if not command or Path(command[0]).resolve() != (root / ".venv/bin/python").resolve():
        raise ValueError("Use the isolated training Python")
    if len(command) < 3 or Path(command[1]).resolve() != (root / "tools/persona_training/persona.py").resolve() or command[2] != "train-dgx" or "--probe" not in command:
        raise ValueError("This window permits only the approved DGX technical probe")
    try:
        run_id = command[command.index("--run-id") + 1]
    except (ValueError, IndexError):
        raise ValueError("A technical probe run ID is required")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", run_id):
        raise ValueError("Invalid technical probe run ID")
    active = [unit for unit in UNITS if systemctl("is-active", unit, check=False).stdout.strip() == "active"]
    if dry_run:
        return {"would_pause": active, "max_seconds": seconds, "training_started": False}
    windows = root / "windows"
    windows.mkdir(mode=0o700, exist_ok=True)
    lease_path = windows / f"{int(time.time())}.json"
    timer = f"miku-persona-restore-{lease_path.stem}"
    lease = {"started_at": time.time(), "deadline": time.time() + seconds, "originally_active": active, "timer": timer, "child_pid": None, "run_id": run_id}
    write(lease_path, lease)
    restore_script = Path(__file__).resolve()
    subprocess.run([
        "systemd-run", "--user", "--collect", f"--unit={timer}", f"--on-active={seconds}s",
        "--timer-property=AccuracySec=1s", "--property=Restart=on-failure", "--property=RestartSec=5s",
        str(root / ".venv/bin/python"),
        str(restore_script), "restore", "--lease", str(lease_path),
    ], check=True, capture_output=True, text=True)
    child = None
    try:
        with used_path.open("x") as used:
            used.write(json.dumps({"lease": str(lease_path), "started_at": lease["started_at"]}) + "\n")
        used_path.chmod(0o600)
        for unit in active:
            systemctl("stop", unit)
        environment = dict(os.environ)
        environment["MIKU_TRAINING_ROOT"] = str(root / "private")
        headers = root / "toolchain/python-dev/usr/include"
        if (headers / "python3.12/Python.h").is_file():
            include_paths = [headers / "python3.12", headers]
            environment["CPATH"] = os.pathsep.join([str(path) for path in include_paths]
                + ([environment["CPATH"]] if environment.get("CPATH") else []))
        environment["TRITON_CACHE_DIR"] = str(root / "cache/triton")
        ptxas = Path("/usr/local/cuda/bin/ptxas")
        if ptxas.is_file():
            version = subprocess.run([str(ptxas), "--version"], capture_output=True, text=True, check=True)
            if "release 13." in version.stdout:
                environment["TRITON_PTXAS_PATH"] = str(ptxas)
        with (root / "logs/technical-probe.log").open("ab") as log:
            child = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        lease["child_pid"] = child.pid
        lease["child_started"] = process_start(child.pid)
        write(lease_path, lease)
        try:
            code = child.wait(timeout=max(1, lease["deadline"] - time.time() - 90))
        except subprocess.TimeoutExpired:
            stop_child(child.pid, lease.get("child_started"))
            child.wait()
            code = 124
        lease["child_exit"] = code
        lease["child_pid"] = None
        write(lease_path, lease)
        finish_run(root, run_id, code)
    finally:
        if child is not None and child.poll() is None:
            stop_child(child.pid, lease.get("child_started"))
            child.wait()
        restore(lease_path)
        systemctl("stop", f"{timer}.timer", check=False)
    return json.loads(lease_path.read_text())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["run", "restore"])
    parser.add_argument("--root", type=Path)
    parser.add_argument("--approval", type=Path)
    parser.add_argument("--lease", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args, remaining = parser.parse_known_args()
    if args.operation == "restore":
        result = restore(args.lease)
    else:
        command = remaining[1:] if remaining[:1] == ["--"] else remaining
        result = run_window(args.root, args.approval, command, args.dry_run)
    print(json.dumps(result))
