"""Independent Linux memory-reserve guard for the owned weight-loading process."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


def available_memory() -> float:
    value = re.search(r"^MemAvailable:\s+(\d+)\s+kB", Path("/proc/meminfo").read_text(), re.M)
    if value is None: raise ValueError("MemAvailable is unavailable")
    return int(value.group(1)) / 2**20


def process_start(pid: int) -> str:
    return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]


def write(path: Path, value: dict):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def watch(pid: int, identity: str, reserve: float, status: Path, stop_report: Path,
          *, phase="weight_loading", memory=available_memory, birth=process_start, kill=os.kill, sleep=time.sleep) -> None:
    if phase not in ["weight_loading", "training"]: raise ValueError("Invalid resource guard phase")
    def owned():
        try: return birth(pid) == identity
        except (OSError, ValueError, IndexError): return False
    if pid <= 1 or not owned(): return
    write(status, {"status": "ready", "pid": pid, "reserve_gib": reserve})
    while owned():
        try:
            available = memory()
            reason = "available_memory_below_reserve_during_" + phase if available < reserve else None
        except (OSError, ValueError):
            available, reason = None, "memory_observation_failed_during_" + phase
        if reason:
            report = {"reason": reason, "available_gib": available, "reserve_gib": reserve,
                "training_pid": pid, "training_start": identity, "phase": phase,
                "checkpoint_exists": any((stop_report.parent / "adapter").glob("checkpoint-*/trainer_state.json")), "action": "terminate_only_owned_training_process",
                "timestamp": datetime.now(timezone.utc).isoformat()}
            try: write(stop_report, report)
            except OSError: pass
            if owned():
                try: kill(pid, signal.SIGTERM)
                except ProcessLookupError: return
            # The loader may be blocked in native code; never wait for a Python callback.
            for _ in range(10):
                sleep(.1)
                if not owned(): return
            if owned():
                try: kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
            return
        sleep(.2)


class WeightLoadWatchdog:
    def __init__(self, reserve: float, directory: Path, phase="weight_loading"):
        if phase not in ["weight_loading", "training"]: raise ValueError("Invalid resource guard phase")
        self.reserve, self.directory, self.phase = reserve, directory, phase
        self.child = None

    def __enter__(self):
        if available_memory() < self.reserve:
            raise RuntimeError("Weight loading memory reserve is unavailable")
        pid = os.getpid()
        prefix = "load" if self.phase == "weight_loading" else "training"
        status = self.directory / (prefix + "-watchdog.json")
        status.unlink(missing_ok=True)
        stop_report = self.directory / (prefix + "-resource-stop.json")
        self.child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--pid", str(pid),
            "--identity", process_start(pid), "--reserve", str(self.reserve), "--status", str(status),
            "--stop-report", str(stop_report), "--phase", self.phase], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 5
        try:
            while time.monotonic() < deadline:
                if self.child.poll() is not None: raise RuntimeError("Weight-loading watchdog failed to start")
                if status.is_file():
                    ready = json.loads(status.read_text())
                    if ready.get("status") == "ready" and ready.get("pid") == pid: return self
                time.sleep(.025)
            raise RuntimeError("Weight-loading watchdog readiness timed out")
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, error_type, *_):
        if self.child is not None:
            unexpected_exit = self.child.poll() is not None
            if not unexpected_exit: self.child.terminate()
            try: self.child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait()
            if unexpected_exit and error_type is None:
                raise RuntimeError("Weight-loading watchdog exited unexpectedly")


@contextmanager
def sequential_weight_loading():
    previous = os.environ.get("HF_DEACTIVATE_ASYNC_LOAD")
    os.environ["HF_DEACTIVATE_ASYNC_LOAD"] = "1"
    try: yield
    finally:
        if previous is None: os.environ.pop("HF_DEACTIVATE_ASYNC_LOAD", None)
        else: os.environ["HF_DEACTIVATE_ASYNC_LOAD"] = previous


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--reserve", type=float, required=True)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("--stop-report", type=Path, required=True)
    parser.add_argument("--phase", choices=["weight_loading", "training"], default="weight_loading")
    args = parser.parse_args()
    if args.pid <= 1 or args.pid != os.getppid() or args.reserve < 16:
        parser.error("Only the direct parent training process may be watched, with at least 16 GiB reserve")
    watch(args.pid, args.identity, args.reserve, args.status, args.stop_report, phase=args.phase)
