import copy
import errno
import hashlib
import json
import os
from pathlib import Path
import select
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/persona_training"))
import shard_cache as cache


def fixture():
    header = json.dumps({"weight": {"dtype": "BF16", "shape": [1], "data_offsets": [0, 2]}}).encode()
    return len(header).to_bytes(8, "little") + header + b"\x00\x00"


def manifest(payload=None):
    payload = fixture() if payload is None else payload
    names = [f"model-0000{i}-of-00002.safetensors" for i in [1, 2]]
    return {"version": 1, "base_model": "Qwen/Qwen3.6-35B-A3B", "base_revision": "test-revision",
        "architecture": "Qwen3_5MoeForConditionalGeneration", "config": {}, "config_sha256": "a" * 64,
        "index": {"weight_map": {"weight" + str(i): name for i, name in enumerate(names)}}, "index_sha256": "b" * 64,
        "files": {name: {"bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest(),
            "tensors": {"weight": {"dtype": "BF16", "shape": [1]}}} for name in names}}


class Child:
    pid = 987654321
    def __init__(self, payload, code=0, ignore_term=False):
        read, write = os.pipe()
        self.stdout = os.fdopen(read, "rb", buffering=0)
        self.writer = write
        self.code, self.ignore_term, self.waits = code, ignore_term, 0
        if payload is not None:
            os.write(write, payload)
            os.close(write)
            self.writer = None
    def poll(self): return self.code
    def wait(self, timeout=None):
        self.waits += 1
        if self.code is None: raise subprocess.TimeoutExpired("mock-ssh", timeout)
        return self.code
    def signal(self, group, number):
        if group != self.pid: raise AssertionError("Signalled an unrelated process group")
        if self.ignore_term and number == signal.SIGTERM: return
        self.code = -int(number)
        if self.writer is not None: os.close(self.writer); self.writer = None


class ShardCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.payload, self.manifest = fixture(), manifest()
        self.names = list(self.manifest["files"])
        self.space = patch.object(cache.shutil, "disk_usage", return_value=types.SimpleNamespace(free=100 * 2**30))
        self.space.start()
        self.exit_status = patch.object(cache, "_exit_code", side_effect=lambda child: child.code)
        self.exit_status.start()
    def tearDown(self): self.exit_status.stop(); self.space.stop(); self.temporary.cleanup()

    def fake(self, payload=None, code=0, ignore_term=False):
        child = Child(self.payload if payload is None and code is not None else payload, code, ignore_term)
        return child

    def test_verified_shard_keeps_one_inode_and_callbacks_release_before_next(self):
        children, commands, partials = [], [], []
        def spawn(command, **options):
            commands.append(command)
            self.assertTrue(options["start_new_session"])
            self.assertEqual(options["stdin"], subprocess.DEVNULL)
            partials.append(next(holder.cache_root.glob("*.partial")).stat().st_ino)
            child = self.fake(); children.append(child); return child
        with cache.ShardCache(self.manifest, private_root=self.root) as holder, patch.object(cache.subprocess, "Popen", side_effect=spawn):
            directory = holder.cache_root
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            first = holder.acquire(self.names[0])
            self.assertEqual(first.name, self.names[0]); self.assertEqual(first.parent, directory)
            self.assertEqual(first.read_bytes(), self.payload)
            self.assertEqual(first.stat().st_ino, partials[0])
            self.assertEqual(first.stat().st_nlink, 1)
            self.assertEqual(first.stat().st_mode & 0o777, 0o400)
            with self.assertRaises(RuntimeError): holder.acquire(self.names[1])
            holder.release(self.names[0], first)
            second = holder.acquire(self.names[1]); holder.release(self.names[1], second)
        self.assertFalse(directory.exists())
        self.assertTrue(all(child.stdout.closed and child.waits for child in children))
        self.assertEqual(len(commands), 2)
        command = commands[0]
        self.assertIn("-oBatchMode=yes", command); self.assertIn("-oStrictHostKeyChecking=yes", command)
        self.assertIn("-oPasswordAuthentication=no", command)
        self.assertEqual(command[-2], "dgx-spark-sync")
        remote = shlex.split(command[-1])
        self.assertEqual(remote[:2], ["python3", "-c"])
        self.assertIn(cache.REMOTE_ROOT, remote[2]); self.assertEqual(remote[-2], self.names[0])

    def test_bad_hash_size_or_remote_exit_never_exposes_ready_shard(self):
        cases = [(self.payload[:-1], 0), (b"X" + self.payload[1:], 0), (self.payload + b"X", 0), (self.payload, 3)]
        for payload, code in cases:
            with self.subTest(bytes=len(payload), code=code), cache.ShardCache(self.manifest, private_root=self.root) as holder:
                child = self.fake(payload, code)
                with patch.object(cache.subprocess, "Popen", return_value=child):
                    with self.assertRaises(ValueError): holder.acquire(self.names[0])
                self.assertEqual({p.name for p in holder.cache_root.iterdir()}, {cache.MARKER})

    def test_manifest_path_control_wildcard_unknown_field_and_size_rejections(self):
        for name in ["../model.safetensors", "/model.safetensors", "model*.safetensors", "model?.safetensors", "m\n.safetensors", "model..safetensors", "-x.safetensors", "a:b.safetensors", "model.pth"]:
            bad = copy.deepcopy(self.manifest)
            item = bad["files"].pop(self.names[0]); bad["files"][name] = item
            with self.subTest(name=name), self.assertRaises(ValueError): cache.ShardCache(bad, private_root=self.root)
        for change in [lambda v: v.update(remote_root="/tmp"), lambda v: v["files"][self.names[0]].update(bytes=cache.MAX_SHARD_BYTES + 1),
                       lambda v: v["files"][self.names[0]].update(bytes=True), lambda v: v["files"][self.names[0]].update(link="elsewhere")]:
            bad = copy.deepcopy(self.manifest); change(bad)
            with self.assertRaises(ValueError): cache.ShardCache(bad, private_root=self.root)

    def test_unknown_basename_or_release_path_does_not_touch_other_files(self):
        with cache.ShardCache(self.manifest, private_root=self.root) as holder, patch.object(cache.subprocess, "Popen", return_value=self.fake()):
            with self.assertRaises(ValueError): holder.acquire("unknown.safetensors")
            path = holder.acquire(self.names[0])
            other = self.root / "other"; other.write_text("preserve")
            with self.assertRaises(ValueError): holder.release(self.names[0], other)
            self.assertEqual(other.read_text(), "preserve")
            holder.release(self.names[0], path)

    def test_disk_reserve_is_checked_before_ssh_and_during_transfer(self):
        with cache.ShardCache(self.manifest, private_root=self.root) as holder, patch.object(cache.subprocess, "Popen") as spawn:
            with patch.object(cache.shutil, "disk_usage", return_value=types.SimpleNamespace(free=cache.DISK_RESERVE_BYTES + len(self.payload) - 1)):
                with self.assertRaises(RuntimeError): holder.acquire(self.names[0])
            spawn.assert_not_called()
        with cache.ShardCache(self.manifest, private_root=self.root) as holder:
            values = iter([100 * 2**30, 100 * 2**30, cache.DISK_RESERVE_BYTES - 1])
            with patch.object(cache.shutil, "disk_usage", side_effect=lambda _: types.SimpleNamespace(free=next(values))), \
                 patch.object(cache.subprocess, "Popen", return_value=self.fake()):
                with self.assertRaises(RuntimeError): holder.acquire(self.names[0])
            self.assertEqual({p.name for p in holder.cache_root.iterdir()}, {cache.MARKER})

    def test_guard_cancellation_terminates_owned_group_and_reaps(self):
        class Cancelled(Exception): pass
        count = [0]
        def guard():
            count[0] += 1
            if count[0] == 2: raise Cancelled()
        child = Child(None, None)
        clock = [0.]
        def tick(): clock[0] += .3; return clock[0]
        with cache.ShardCache(self.manifest, private_root=self.root, guard=guard) as holder, \
             patch.object(cache.subprocess, "Popen", return_value=child), patch.object(cache.os, "killpg", side_effect=child.signal) as kill, \
             patch.object(cache.time, "monotonic", side_effect=tick):
            with self.assertRaises(Cancelled): holder.acquire(self.names[0])
            self.assertEqual({p.name for p in holder.cache_root.iterdir()}, {cache.MARKER})
        self.assertEqual([call.args for call in kill.call_args_list], [(child.pid, signal.SIGTERM), (child.pid, signal.SIGKILL)])
        self.assertTrue(child.waits); self.assertTrue(child.stdout.closed)

    def test_exited_leader_keeps_pid_reserved_until_its_remaining_group_is_killed(self):
        self.exit_status.stop()
        grandchild = "import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print(os.getpid(),flush=True); time.sleep(60)"
        leader = "import os,subprocess,sys; subprocess.Popen([sys.executable,'-c',sys.argv[1]]); os._exit(0)"
        child = subprocess.Popen([sys.executable, "-c", leader, grandchild], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        remaining_output = None
        try:
            self.assertGreater(int(child.stdout.readline()), 0)
            remaining_output = os.dup(child.stdout.fileno())
            deadline = time.monotonic() + 2
            while cache._exit_code(child) is None and time.monotonic() < deadline: time.sleep(.01)
            self.assertEqual(cache._exit_code(child), 0)
            self.assertIsNone(child.returncode)
            with cache.ShardCache(self.manifest, private_root=self.root) as holder:
                holder._child = child
                with patch.object(cache.os, "killpg", wraps=os.killpg) as kill:
                    holder._stop()
                self.assertEqual([call.args for call in kill.call_args_list], [(child.pid, signal.SIGTERM), (child.pid, signal.SIGKILL)])
            self.assertEqual(child.returncode, 0)
            self.assertTrue(child.stdout.closed)
            self.assertTrue(select.select([remaining_output], [], [], 1)[0])
            self.assertEqual(os.read(remaining_output, 1), b"")
        finally:
            if child.returncode is None:
                try: os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                child.wait()
            if child.stdout is not None: child.stdout.close()
            if remaining_output is not None: os.close(remaining_output)

    def test_reaped_or_unrelated_pid_is_never_signalled(self):
        child = self.fake()
        with cache.ShardCache(self.manifest, private_root=self.root) as holder:
            holder._child = child
            with patch.object(cache, "_exit_code", side_effect=ChildProcessError()), patch.object(cache.os, "killpg") as kill:
                with self.assertRaises(ChildProcessError): holder._stop()
            kill.assert_not_called()
            self.assertTrue(child.stdout.closed)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin libc compatibility path")
    def test_darwin_libc_waitid_observes_without_reaping_and_rejects_reaped_pid(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(.2); raise SystemExit(7)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            self.assertIsNone(cache._darwin_waitid(child.pid))
            deadline = time.monotonic() + 2
            value = None
            while value is None and time.monotonic() < deadline:
                value = cache._darwin_waitid(child.pid)
                if value is None: time.sleep(.01)
            self.assertIsNotNone(value)
            self.assertEqual((value.si_pid, value.si_code, value.si_status), (child.pid, os.CLD_EXITED, 7))
            self.assertEqual(cache._darwin_waitid(child.pid).si_status, 7)
            self.assertIsNone(child.returncode)
            self.assertEqual(child.wait(), 7)
            with self.assertRaises(ChildProcessError): cache._darwin_waitid(child.pid)
        finally:
            if child.returncode is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()

    def test_group_permission_error_only_ignores_an_exited_zombie_only_group(self):
        for code, group, accepted in [(0, "Z", True), (0, "S", False), (None, "Z", False)]:
            child = self.fake(code=code)
            listing = types.SimpleNamespace(stdout=f"{child.pid} {child.pid} Z\n42 {child.pid} {group}\n")
            with self.subTest(code=code, group=group), \
                 patch.object(cache.os, "killpg", side_effect=PermissionError(errno.EPERM, "fixture")), \
                 patch.object(cache.subprocess, "run", return_value=listing) as observation:
                if accepted: cache._signal_group(child, signal.SIGTERM)
                else:
                    with self.assertRaises(PermissionError): cache._signal_group(child, signal.SIGTERM)
                if code is None: observation.assert_not_called()
            child.stdout.close()
            if child.writer is not None: os.close(child.writer)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin zombie-only group behavior")
    def test_naturally_exited_cat_is_cleaned_up_without_reaping_before_group_observation(self):
        self.exit_status.stop()
        child = subprocess.Popen(["/bin/cat"], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            self.assertEqual(child.stdout.read(), b"")
            deadline = time.monotonic() + 2
            while cache._exit_code(child) is None and time.monotonic() < deadline: time.sleep(.01)
            self.assertEqual(cache._exit_code(child), 0)
            self.assertIsNone(child.returncode)
            with cache.ShardCache(self.manifest, private_root=self.root) as holder:
                holder._child = child
                holder._stop()
            self.assertEqual(child.returncode, 0)
            self.assertTrue(child.stdout.closed)
        finally:
            if child.returncode is None:
                try: cache._signal_group(child, signal.SIGKILL)
                finally: child.wait()
            if child.stdout is not None: child.stdout.close()

    def test_timeout_uses_term_then_kill_only_for_owned_ssh_group(self):
        child = Child(None, None, ignore_term=True)
        clock = [0.]
        def tick(): clock[0] += .4; return clock[0]
        with cache.ShardCache(self.manifest, private_root=self.root, timeout_seconds=3) as holder, \
             patch.object(cache.subprocess, "Popen", return_value=child), patch.object(cache.os, "killpg", side_effect=child.signal) as kill, \
             patch.object(cache.time, "monotonic", side_effect=tick):
            with self.assertRaises(TimeoutError): holder.acquire(self.names[0])
        self.assertEqual([call.args for call in kill.call_args_list], [(child.pid, signal.SIGTERM), (child.pid, signal.SIGKILL)])
        self.assertTrue(child.stdout.closed)

    def test_global_lock_prevents_parallel_caches(self):
        with cache.ShardCache(self.manifest, private_root=self.root):
            with self.assertRaises(BlockingIOError):
                with cache.ShardCache(self.manifest, private_root=self.root): self.fail("Second cache acquired the lock")

    def test_remote_reader_rejects_symlink_and_hardlink_sources_before_reading(self):
        namespace = {"__name__": "reader_test"}
        exec(cache.REMOTE_READER, namespace)
        for mode, links in [(stat.S_IFLNK | 0o777, 1), (stat.S_IFREG | 0o400, 2)]:
            value = types.SimpleNamespace(st_mode=mode, st_nlink=links, st_size=len(self.payload))
            with patch.object(sys, "argv", ["reader", self.names[0], str(len(self.payload))]), \
                 patch.object(os, "open", return_value=1000) as opening, patch.object(os, "close"), \
                 patch.object(os, "fstat", return_value=value), patch.object(os, "read") as reading:
                with self.assertRaises(ValueError): namespace["main"]()
                reading.assert_not_called()
                self.assertTrue(all(call.args[1] & os.O_NOFOLLOW for call in opening.call_args_list))

    def test_directory_replacement_is_left_untouched_on_cleanup(self):
        holder = cache.ShardCache(self.manifest, private_root=self.root).__enter__()
        old = holder.cache_root; moved = self.root / "retained"
        old.rename(moved); old.mkdir(mode=0o700); sentinel = old / "foreign"; sentinel.write_text("preserve")
        with self.assertRaises(RuntimeError): holder.close()
        self.assertEqual(sentinel.read_text(), "preserve"); self.assertTrue((moved / cache.MARKER).is_file())

    def test_atomic_rename_never_replaces_a_foreign_target(self):
        target = None
        count = [0]
        def guard():
            count[0] += 1
            if count[0] == 2: (holder.cache_root / self.names[0]).write_bytes(b"preserve")
        with self.assertRaises(FileExistsError):
            with cache.ShardCache(self.manifest, private_root=self.root, guard=guard) as holder:
                target = holder.cache_root / self.names[0]
                with patch.object(cache.subprocess, "Popen", return_value=self.fake()): holder.acquire(self.names[0])
        self.assertEqual(target.read_bytes(), b"preserve")

    def test_token_tampering_never_deletes_the_directory(self):
        holder = cache.ShardCache(self.manifest, private_root=self.root).__enter__()
        directory = holder.cache_root
        (directory / cache.MARKER).write_text('{"version":1,"token":"different"}')
        with self.assertRaises(RuntimeError): holder.close()
        self.assertTrue(directory.is_dir())

    def test_stored_bytes_are_rehashed_before_the_atomic_rename(self):
        calls = [0]
        def guard():
            calls[0] += 1
            if calls[0] == 2:
                next(holder.cache_root.glob("*.partial")).write_bytes(b"X" + self.payload[1:])
        with cache.ShardCache(self.manifest, private_root=self.root, guard=guard) as holder, \
             patch.object(cache.subprocess, "Popen", return_value=self.fake()):
            with self.assertRaises(ValueError): holder.acquire(self.names[0])
            self.assertEqual({p.name for p in holder.cache_root.iterdir()}, {cache.MARKER})

    def test_local_symlink_is_never_read_or_removed(self):
        holder = cache.ShardCache(self.manifest, private_root=self.root).__enter__()
        other = self.root / "other"; other.write_bytes(b"preserve")
        link = holder.cache_root / self.names[0]; link.symlink_to(other)
        with patch.object(cache.subprocess, "Popen") as spawn:
            with self.assertRaises(RuntimeError): holder.acquire(self.names[0])
            spawn.assert_not_called()
        with self.assertRaises(RuntimeError): holder.close()
        self.assertTrue(link.is_symlink()); self.assertEqual(other.read_bytes(), b"preserve")


if __name__ == "__main__": unittest.main()
