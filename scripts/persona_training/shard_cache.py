"""Read one verified shard at a time from the owner's fixed DGX export."""

from __future__ import annotations

import ctypes
import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import selectors
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

REMOTE_ROOT = "/home/miku2339/miku-persona-training/private/exports/miku-persona-probe-v4-hf"
SSH_ALIAS = "dgx-spark-sync"
MARKER = ".miku-shard-cache.json"
MAX_SHARD_BYTES = 4 * 2**30
DISK_RESERVE_BYTES = 30 * 2**30
CHUNK_BYTES = 2**20
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.safetensors")
HEX = re.compile(r"[0-9a-f]{64}")

# Open every directory component without following links. Only the named regular
# file is sent to stdout; the final identity check rejects changes during transfer.
REMOTE_READER = r'''
import os, re, stat, sys
ROOT = "/home/miku2339/miku-persona-training/private/exports/miku-persona-probe-v4-hf"
def identity(value):
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns, value.st_nlink
def main():
    name, expected = sys.argv[1], int(sys.argv[2])
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.safetensors", name) or ".." in name or not 0 < expected <= 4 * 2**30:
        raise ValueError("Invalid shard selector")
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    source = None
    try:
        for component in ROOT.strip("/").split("/"):
            following = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = following
        source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        before = os.fstat(source)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size != expected:
            raise ValueError("Source shard is not a single regular file of the expected size")
        remaining = expected
        while remaining:
            block = os.read(source, min(2**20, remaining))
            if not block: raise ValueError("Source shard is truncated")
            sys.stdout.buffer.write(block)
            remaining -= len(block)
        after = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if identity(os.fstat(source)) != identity(before) or identity(after) != identity(before):
            raise ValueError("Source shard identity changed")
        sys.stdout.buffer.flush()
    finally:
        if source is not None: os.close(source)
        os.close(directory)
if __name__ == "__main__": main()
'''


def _name(value) -> str:
    if not isinstance(value, str) or NAME.fullmatch(value) is None or ".." in value:
        raise ValueError("Expected a whitelisted safetensors basename")
    return value


def validate_manifest(value: dict) -> dict:
    fields = {"version", "base_model", "base_revision", "architecture", "config", "config_sha256", "index", "index_sha256", "files"}
    if not isinstance(value, dict) or set(value) != fields or type(value["version"]) is not int or value["version"] != 1:
        raise ValueError("Invalid source manifest schema")
    for field in ["base_model", "base_revision", "architecture"]:
        if not isinstance(value[field], str) or not value[field] or len(value[field]) > 256 or any(ord(c) < 32 for c in value[field]):
            raise ValueError("Invalid source identity")
    if not isinstance(value["config"], dict) or not isinstance(value["index"], dict):
        raise ValueError("Source config and HF index are required")
    for field in ["config_sha256", "index_sha256"]:
        if not isinstance(value[field], str) or HEX.fullmatch(value[field]) is None:
            raise ValueError("Invalid metadata digest")
    files = value["files"]
    if not isinstance(files, dict) or not 1 <= len(files) <= 256:
        raise ValueError("A bounded shard whitelist is required")
    result = {}
    for name, item in files.items():
        _name(name)
        if (not isinstance(item, dict) or set(item) != {"bytes", "sha256", "tensors"}
                or type(item["bytes"]) is not int or not 0 < item["bytes"] <= MAX_SHARD_BYTES
                or not isinstance(item["sha256"], str) or HEX.fullmatch(item["sha256"]) is None
                or not isinstance(item["tensors"], dict)):
            raise ValueError("Invalid bounded shard descriptor")
        result[name] = {"bytes": item["bytes"], "sha256": item["sha256"]}
    weights = value["index"].get("weight_map")
    if not isinstance(weights, dict) or not weights or any(not isinstance(k, str) or not k or not isinstance(v, str) or v not in result for k, v in weights.items()):
        raise ValueError("HF index differs from the shard whitelist")
    if set(weights.values()) != set(result): raise ValueError("Unindexed source shards are not allowed")
    return result


def _identity(value) -> tuple:
    return value.st_dev, value.st_ino


def _regular(value) -> bool:
    return stat.S_ISREG(value.st_mode) and value.st_nlink == 1 and value.st_uid == os.getuid()


class _DarwinSigval(ctypes.Union):
    _fields_ = [("sival_int", ctypes.c_int), ("sival_ptr", ctypes.c_void_p)]


class _DarwinSiginfo(ctypes.Structure):
    # Darwin SDK sys/signal.h siginfo_t; pid_t=int32_t, uid_t=uint32_t.
    _fields_ = [("si_signo", ctypes.c_int), ("si_errno", ctypes.c_int), ("si_code", ctypes.c_int),
        ("si_pid", ctypes.c_int32), ("si_uid", ctypes.c_uint32), ("si_status", ctypes.c_int),
        ("si_addr", ctypes.c_void_p), ("si_value", _DarwinSigval), ("si_band", ctypes.c_long),
        ("__pad", ctypes.c_ulong * 7)]


def _darwin_waitid(pid):
    if sys.platform != "darwin" or ctypes.sizeof(ctypes.c_void_p) != 8 or ctypes.sizeof(_DarwinSiginfo) != 104:
        raise RuntimeError("Non-reaping child observation is unavailable")
    value = _DarwinSiginfo()
    function = ctypes.CDLL(None, use_errno=True).waitid
    function.argtypes = [ctypes.c_int, ctypes.c_uint32, ctypes.POINTER(_DarwinSiginfo), ctypes.c_int]
    function.restype = ctypes.c_int
    while function(os.P_PID, pid, ctypes.byref(value), os.WEXITED | os.WNOHANG | os.WNOWAIT):
        code = ctypes.get_errno()
        if code == errno.EINTR: continue
        raise OSError(code, os.strerror(code))
    return value if value.si_pid else None


def _exit_code(child):
    # Leave the direct child unreaped until its whole group has been signalled;
    # its reserved PID prevents the owned group ID from being reused meanwhile.
    waitid = getattr(os, "waitid", None)
    value = waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) if waitid else _darwin_waitid(child.pid)
    if value is None: return None
    return value.si_status if value.si_code == os.CLD_EXITED else -value.si_status


def _signal_group(child, number):
    _exit_code(child)
    try:
        os.killpg(child.pid, number)
    except ProcessLookupError:
        return
    except PermissionError as error:
        if error.errno != errno.EPERM or _exit_code(child) is None: raise
        # Darwin rejects signals to a group containing only zombies. Its direct
        # leader stays unreaped while checking that no executable member remains.
        result = subprocess.run(["/bin/ps", "-axo", "pid=,pgid=,stat="], stdin=subprocess.DEVNULL,
            capture_output=True, text=True, check=True, timeout=2)
        if len(result.stdout) > 2**20: raise RuntimeError("Process group observation exceeded its bound") from error
        for line in result.stdout.splitlines():
            fields = line.split()
            if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit() or not fields[2]:
                raise RuntimeError("Process group observation is invalid") from error
            if int(fields[1]) == child.pid and not fields[2].startswith("Z"):
                raise error
        _exit_code(child)


def _rename_exclusive(directory: int, source: str, target: str) -> None:
    library = ctypes.CDLL(None, use_errno=True)
    name, flag = ("renameatx_np", 4) if sys.platform == "darwin" else ("renameat2", 1)
    function = getattr(library, name, None)
    if function is None: raise RuntimeError("Exclusive atomic rename is unavailable")
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(directory, os.fsencode(source), directory, os.fsencode(target), flag):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


class ShardCache:
    def __init__(self, manifest: dict, *, private_root: Path, guard=None, timeout_seconds: float = 300):
        self.files = validate_manifest(manifest)
        if isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, (int, float)) or not math.isfinite(timeout_seconds) or not 2 < timeout_seconds <= 900:
            raise ValueError("Shard transfer timeout must be bounded to 3–900 seconds")
        self.private_root = Path(private_root).expanduser().resolve(strict=True)
        self.guard, self.timeout_seconds = guard, timeout_seconds
        self.cache_root = None
        self.owner_identity = None
        self.owner_token = secrets.token_hex(24)
        self._directory = self._lock = None
        self._created = {}
        self._active = None
        self._child = None
        self.cleanup_error = None

    def __enter__(self):
        if self.cache_root is not None: raise RuntimeError("Shard cache contexts cannot be reused")
        parent = self.private_root / "tmp"
        parent.mkdir(mode=0o700, exist_ok=True)
        value = parent.lstat()
        if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid() or value.st_mode & 0o022:
            raise RuntimeError("Private temporary directory ownership is invalid")
        lock = parent / ".miku-shard-cache.lock"
        self._lock = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            if not _regular(os.fstat(self._lock)): raise RuntimeError("Shard cache lock is not owned")
            fcntl.flock(self._lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.cache_root = Path(tempfile.mkdtemp(prefix="miku-dgx-shard-", dir=parent))
            self.cache_root.chmod(0o700)
            self.owner_identity = _identity(self.cache_root.lstat())
            self._directory = os.open(self.cache_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            marker = os.open(MARKER, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self._directory)
            with os.fdopen(marker, "w") as stream:
                json.dump({"version": 1, "token": self.owner_token}, stream)
                stream.flush()
                self._created[MARKER] = _identity(os.fstat(stream.fileno()))
            self._owned()
            return self
        except BaseException:
            self.close()
            raise

    def _owned(self):
        if self._directory is None or self.cache_root is None: raise RuntimeError("Shard cache is not open")
        current = self.cache_root.lstat()
        if (not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid() or stat.S_IMODE(current.st_mode) != 0o700
                or _identity(current) != self.owner_identity or _identity(os.fstat(self._directory)) != self.owner_identity):
            raise RuntimeError("Shard cache directory ownership changed")
        descriptor = os.open(MARKER, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self._directory)
        with os.fdopen(descriptor, "r") as stream:
            marker = os.fstat(stream.fileno())
            if not _regular(marker) or marker.st_size > 4096 or _identity(marker) != self._created.get(MARKER):
                raise RuntimeError("Shard cache marker ownership changed")
            if json.loads(stream.read(4097)) != {"version": 1, "token": self.owner_token}:
                raise RuntimeError("Shard cache token changed")

    def _space(self, extra: int = 0):
        if shutil.disk_usage(self.cache_root).free < DISK_RESERVE_BYTES + extra:
            raise RuntimeError("Mac disk reserve would fall below 30 GiB")

    def _remove(self, name: str):
        self._owned()
        value = os.stat(name, dir_fd=self._directory, follow_symlinks=False)
        if not _regular(value) or _identity(value) != self._created.get(name):
            raise RuntimeError("Shard cache file ownership changed")
        os.unlink(name, dir_fd=self._directory)
        self._created.pop(name)

    def _stop(self, remaining: float = 2):
        child = self._child
        if child is None: return
        try:
            _exit_code(child)
            _signal_group(child, signal.SIGTERM)
            deadline = time.monotonic() + max(0, min(2, remaining))
            while _exit_code(child) is None and time.monotonic() < deadline:
                time.sleep(min(0.02, max(0, deadline - time.monotonic())))
            if time.monotonic() < deadline:
                time.sleep(min(0.05, max(0, deadline - time.monotonic())))
            _signal_group(child, signal.SIGKILL)
            child.wait()
        finally:
            if child.stdout is not None: child.stdout.close()
            self._child = None

    def acquire(self, name: str) -> Path:
        _name(name)
        if name not in self.files: raise ValueError("Shard is not in the fixed source manifest")
        self._owned()
        if self._active is not None or set(os.listdir(self.cache_root)) != {MARKER}:
            raise RuntimeError("Release the current shard before acquiring another")
        item = self.files[name]
        started, wall_started = time.monotonic(), time.time()
        def remaining():
            return min(self.timeout_seconds - (time.monotonic() - started), self.timeout_seconds - (time.time() - wall_started))
        self._space(item["bytes"])
        if self.guard: self.guard()
        self._owned()
        self._space(item["bytes"])
        if remaining() <= 2: raise TimeoutError("Bounded shard transfer timed out")
        partial = name + ".partial"
        descriptor = os.open(partial, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=self._directory)
        self._created[partial] = _identity(os.fstat(descriptor))
        digest, received, last_guard = hashlib.sha256(), 0, started
        command = ["/usr/bin/ssh", "-T", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oPasswordAuthentication=no",
            "-oKbdInteractiveAuthentication=no", "-oConnectTimeout=10", "-oConnectionAttempts=1", "--", SSH_ALIAS,
            "python3 -c " + shlex.quote(REMOTE_READER) + " " + shlex.quote(name) + " " + str(item["bytes"])]
        try:
            self._child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, start_new_session=True)
            os.set_blocking(self._child.stdout.fileno(), False)
            with selectors.DefaultSelector() as selector:
                selector.register(self._child.stdout, selectors.EVENT_READ)
                eof = False
                while True:
                    self._owned()
                    self._space()
                    if remaining() <= 2: raise TimeoutError("Bounded shard transfer timed out")
                    if self.guard and time.monotonic() - last_guard >= 0.2:
                        self.guard()
                        last_guard = time.monotonic()
                    for key, _ in selector.select(timeout=min(0.2, max(0, remaining() - 2))):
                        block = os.read(key.fd, min(CHUNK_BYTES, item["bytes"] - received + 1))
                        if not block:
                            selector.unregister(self._child.stdout)
                            eof = True
                            continue
                        if received + len(block) > item["bytes"]: raise ValueError("Shard exceeds its manifest size")
                        self._space(len(block))
                        view = memoryview(block)
                        while view:
                            count = os.write(descriptor, view)
                            if not count: raise OSError("Shard cache write failed")
                            view = view[count:]
                        digest.update(block)
                        received += len(block)
                    code = _exit_code(self._child)
                    if eof and code is not None: break
            self._stop(max(0, remaining()))
            if code != 0 or received != item["bytes"] or digest.hexdigest() != item["sha256"]:
                raise ValueError("Shard transfer, byte count or SHA-256 verification failed")
            self._owned()
            self._space()
            if self.guard: self.guard()
            os.fsync(descriptor)
            value = os.fstat(descriptor)
            path_value = os.stat(partial, dir_fd=self._directory, follow_symlinks=False)
            if not _regular(value) or value.st_size != item["bytes"] or _identity(path_value) != self._created[partial]:
                raise RuntimeError("Downloaded shard identity changed")
            os.lseek(descriptor, 0, os.SEEK_SET)
            stored = hashlib.sha256()
            while block := os.read(descriptor, CHUNK_BYTES):
                self._owned()
                self._space()
                if remaining() <= 2: raise TimeoutError("Bounded shard verification timed out")
                if self.guard and time.monotonic() - last_guard >= 0.2:
                    self.guard()
                    last_guard = time.monotonic()
                stored.update(block)
            after = os.fstat(descriptor)
            if (stored.hexdigest() != item["sha256"] or not _regular(after)
                    or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                    != (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)):
                raise ValueError("Stored shard digest or identity verification failed")
            os.fchmod(descriptor, 0o400)
            _rename_exclusive(self._directory, partial, name)
            self._created[name] = self._created.pop(partial)
            value = os.stat(name, dir_fd=self._directory, follow_symlinks=False)
            self._active = (name, _identity(value), value.st_size, value.st_mtime_ns, value.st_ctime_ns)
            return self.cache_root / name
        except BaseException:
            self._stop(max(0, remaining()))
            if partial in self._created:
                try: self._remove(partial)
                except (OSError, RuntimeError): pass
            raise
        finally:
            os.close(descriptor)

    def release(self, name: str, path: Path) -> None:
        _name(name)
        self._owned()
        if self._active is None or name != self._active[0] or Path(path) != self.cache_root / name:
            raise ValueError("Release must match the acquired shard path")
        value = Path(path).lstat()
        if (not _regular(value) or (_identity(value), value.st_size, value.st_mtime_ns, value.st_ctime_ns) != self._active[1:]):
            raise RuntimeError("Acquired shard changed before release")
        self._remove(name)
        self._active = None

    def close(self):
        try:
            self._stop()
            if self._directory is not None:
                self._owned()
                if set(os.listdir(self.cache_root)) != set(self._created):
                    raise RuntimeError("Unknown cache entries are left untouched")
                for name in list(self._created):
                    if name != MARKER: self._remove(name)
                self._remove(MARKER)
                if _identity(self.cache_root.lstat()) != self.owner_identity:
                    raise RuntimeError("Shard cache directory changed before removal")
                os.rmdir(self.cache_root)
        except BaseException as error:
            self.cleanup_error = type(error).__name__
            raise
        finally:
            if self._directory is not None: os.close(self._directory); self._directory = None
            if self._lock is not None: os.close(self._lock); self._lock = None

    def __exit__(self, error_type, *_):
        try: self.close()
        except BaseException:
            if error_type is None: raise
