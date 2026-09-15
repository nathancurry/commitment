#!/usr/bin/env python3
"""Offline boundary tests. Never reads real configuration or contacts Bitwarden."""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace as Object
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("broker", ROOT / "secret-broker.py")
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
spec = importlib.util.spec_from_file_location("fake_sdk", ROOT / "tests/fixtures/fake-sdk.py")
fake_sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fake_sdk)
PROJECT = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"


class Secrets(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="commitment-secret-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mockdir = self.root / "backend"
        self.mockdir.mkdir()
        self.token = self.root / "token"
        self.token.write_text("fixture-machine-token\n")
        self.token.chmod(0o600)
        self.home = self.root / "home"
        self.home.mkdir()
        self.directory = self.root / "secrets-session.fixture"
        self.directory.mkdir(mode=0o700)
        self.env = {"PATH": str(self.mockdir) + ":/usr/bin:/bin", "HOME": str(self.home),
                    "FAKE_SDK_DIR": str(self.mockdir),
                    "BITWARDEN_SECRETS_ENABLED": "true", "BITWARDEN_PROJECT_ID": PROJECT,
                    "BITWARDEN_SECRETS_TOKEN_FILE": str(self.token)}
        self.process = None
        self.addCleanup(self.stop)
        self.sdk = fake_sdk.BitwardenClient(self.mockdir)
        patcher = mock.patch.object(broker, "sdk_client", return_value=self.sdk)
        patcher.start()
        self.addCleanup(patcher.stop)

    def backend(self):
        with mock.patch.dict(os.environ, self.env, clear=True):
            return broker.Backend(PROJECT, str(self.token))

    def state(self):
        return json.loads((self.mockdir / "backend.json").read_text())

    def seed(self, items):
        (self.mockdir / "backend.json").write_text(json.dumps({"items": items, "calls": []}))

    def start(self, extra=(), parent=None):
        self.process = subprocess.Popen(
            [sys.executable, "-IB", str(ROOT / "tests/fixtures/fake-sdk.py"),
             str(ROOT / "secret-broker.py"), str(self.directory),
             str(parent or os.getpid()), *map(str, extra)], env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if (self.directory / "lock").exists() or self.process.poll() is not None:
                return
            time.sleep(0.02)
        self.fail("broker startup timed out")

    def stop(self):
        if self.process is not None:
            self.process.terminate()
            stdout, stderr = self.process.communicate(timeout=5)
            self.process = None
            self.assertNotIn(b"fixture-machine-token", stdout + stderr)
            self.assertNotIn(b"Z" * 48, stdout + stderr)
            self.assertFalse((self.directory / "lock").exists())

    def request(self, value):
        packet = {"id": "a" * 32, "request": value}
        incoming = os.open(self.directory / "response", os.O_RDONLY | os.O_NONBLOCK)
        outgoing = os.open(self.directory / "request", os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(outgoing, (value if isinstance(value, bytes) else json.dumps(packet).encode()) + b"\n")
            self.assertTrue(select.select([incoming], [], [], 5)[0])
            result = json.loads(os.read(incoming, 65536))
            return result.get("result", result)
        finally:
            os.close(incoming)
            os.close(outgoing)

    def client(self, *args):
        return subprocess.run([sys.executable, "-I", str(ROOT / "commitment-secret.py"), *args],
                              env={"COMMITMENT_SECRET_DIR": str(self.directory)},
                              capture_output=True, timeout=5)

    def test_generate_rotate_metadata_only_and_no_disk_or_log_leaks(self):
        backend = self.backend()
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
            with mock.patch.object(broker.secrets, "choice", return_value="Z"):
                generated = backend.operate({"op": "generate", "name": "mail"})
            with mock.patch.object(broker.secrets, "choice", return_value="Y"):
                rotated = backend.operate({"op": "rotate", "name": "mail"})
            listing = backend.operate({"op": "list"})
            exists = backend.operate({"op": "exists", "name": "mail"})
        self.assertEqual(generated, rotated)
        self.assertEqual(set(generated), {"name", "secret_ref"})
        self.assertTrue(exists["exists"])
        self.assertEqual(self.sdk.values, ["Z" * 48, "Y" * 48])
        for value in ("Z" * 48, "Y" * 48):
            self.assertNotIn(value, captured.getvalue() + json.dumps([generated, rotated, listing, exists]))
            # Inspect actual Git-managed files (including runlog), and disposable
            # runtime files, including all mock artifacts (metadata/hashes only).
            tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
            paths = [ROOT / p.decode() for p in tracked if p] + list(self.root.rglob("*"))
            for path in paths:
                if path.is_file():
                    self.assertNotIn(value.encode(), path.read_bytes(), str(path))

    def test_duplicate_generation_and_ambiguous_mutation(self):
        backend = self.backend()
        backend.operate({"op": "generate", "name": "one"})
        with self.assertRaisesRegex(broker.Unavailable, "already exists"):
            backend.operate({"op": "generate", "name": "one"})
        item = self.state()["items"][0]
        self.seed([item, {**item, "id": OTHER}])
        for op in ("exists", "generate", "rotate", "delete"):
            with self.subTest(op=op), self.assertRaisesRegex(broker.Unavailable, "duplicate"):
                backend.operate({"op": op, "name": "one"})

    def test_delete_one_and_scope_checks(self):
        backend = self.backend()
        one = backend.operate({"op": "generate", "name": "one"})
        backend.operate({"op": "generate", "name": "two"})
        self.assertTrue(backend.operate({"op": "delete", "name": "one"})["deleted"])
        self.assertEqual([x["key"] for x in self.state()["items"]], ["two"])
        self.assertEqual(self.state()["calls"][-1], ["delete", [one["secret_ref"][10:]]])
        item = self.state()["items"][0]
        self.seed([{**item, "project_id": OTHER}])
        for op in ("list", "rotate", "delete", "generate"):
            request = {"op": op} if op == "list" else {"op": op, "name": "two"}
            with self.subTest(op=op), self.assertRaisesRegex(broker.Unavailable, "out-of-project"):
                backend.operate(request)

    def test_invalid_requests_cannot_invoke_backend(self):
        bad = [None, [], {"op": []}, {"op": "get", "name": "mail"},
               {"op": "run", "command": "touch /tmp/escaped"},
               {"op": "list", "path": "/etc/passwd"},
               {"op": "list", "project": OTHER}, {"op": "generate", "name": "a;id"},
               {"op": "generate", "name": "--help"}, {"op": "delete", "name": "*"},
               {"op": "generate", "name": "a", "length": True},
               {"op": "rotate", "name": "a", "length": 1},
               {"op": "generate", "name": "a", "length": 129}]
        backend = self.backend()
        with mock.patch.object(backend, "call") as call:
            for request in bad:
                with self.subTest(request=request), self.assertRaises(broker.Unavailable):
                    backend.operate(request)
            call.assert_not_called()

    def test_unavailable_token_dependency_interface(self):
        for value in ("", "bad\nmultiline", "x" * 8193):
            self.token.write_text(value)
            with self.assertRaisesRegex(broker.Unavailable, "token"):
                self.backend()
        self.token.write_text("fixture-machine-token")
        self.token.chmod(0o644)
        with self.assertRaisesRegex(broker.Unavailable, "owner-only"):
            self.backend()
        self.token.unlink()
        with self.assertRaisesRegex(broker.Unavailable, "missing"):
            self.backend()
        target = self.root / "target"
        target.write_text("fixture-machine-token")
        self.token.symlink_to(target)
        with self.assertRaisesRegex(broker.Unavailable, "invalid"):
            self.backend()
        self.token.unlink()
        self.token.write_text("fixture-machine-token")
        self.token.chmod(0o600)
        with mock.patch.object(broker, "sdk_client", side_effect=ImportError("fixture-machine-token")):
            with self.assertRaisesRegex(broker.Unavailable, "SDK unavailable"):
                self.backend()
        with mock.patch.object(broker.Backend, "call", return_value="obsolete interface"):
            with self.assertRaisesRegex(broker.Unavailable, "SDK unavailable"):
                self.backend()

    def test_backend_failure_never_discloses(self):
        backend = self.backend()
        backend.operate({"op": "generate", "name": "mail"})
        for flag in ("malformed",):
            (self.mockdir / flag).touch()
            with self.assertRaises(broker.Unavailable) as caught:
                backend.operate({"op": "list"})
            self.assertNotIn("fixture-machine-token", str(caught.exception))
            (self.mockdir / flag).unlink()
        with mock.patch.object(self.sdk, "list", side_effect=RuntimeError("fixture-machine-token")):
            with self.assertRaisesRegex(broker.Unavailable, "check host setup"):
                backend.operate({"op": "list"})
        self.start()
        (self.mockdir / "fail").touch()
        result = self.client("list")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(b"fixture-machine-token", result.stdout + result.stderr)
        self.stop()  # Also checks native/Python diagnostics never leave broker.

    def test_fifo_client_lifecycle_and_no_secret_stdout(self):
        self.start()
        pipe_path = self.directory / "request"
        self.assertTrue(stat.S_ISFIFO(pipe_path.stat().st_mode))
        self.assertEqual(pipe_path.stat().st_uid, os.getuid())
        self.assertEqual(pipe_path.stat().st_mode & 0o777, 0o600)
        for name in ("response", "lock"):
            self.assertEqual((self.directory / name).stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.client("available").returncode, 0)
        self.assertEqual(self.client("exists", "missing").returncode, 1)
        results = [self.client("generate", "one"), self.client("rotate", "one"),
                   self.client("list"), self.client("exists", "one"), self.client("delete", "one")]
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(b"value", result.stdout + result.stderr)
            self.assertNotIn(b"fixture-machine-token", result.stdout + result.stderr)
            self.assertNotIn(b"Z" * 48, result.stdout + result.stderr)
        packet = self.request({"op": "generate", "name": "direct-ipc"})
        self.assertTrue(packet["ok"])
        self.assertNotIn("Z" * 48, json.dumps(packet))
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"Z" * 48, path.read_bytes(), str(path))
        for op in ("get", "reveal", "put", "run"):
            self.assertNotEqual(self.client(op, "one").returncode, 0)
        self.stop()
        self.assertEqual(list(self.root.glob("bws-*")), [])

    def test_malformed_ipc_and_no_override(self):
        self.start()
        for request in (b"bad JSON", b"x" * 4097, [], {"op": "get"},
                        {"op": "list", "project": OTHER}, {"op": "list", "file": str(self.token)},
                        {"op": "generate", "name": "$(touch /tmp/escaped)"}):
            with self.subTest(request=str(request)[:70]):
                self.assertFalse(self.request(request)["ok"])
        self.assertFalse((self.mockdir / "backend.json").exists())
        self.assertTrue(self.request({"op": "available"})["ok"])

    def test_missing_invalid_and_disabled_backend_over_ipc(self):
        for setting in ("missing", "invalid", "disabled", "invalid-project"):
            with self.subTest(setting=setting):
                self.token.write_text("wrong" if setting == "invalid" else "fixture-machine-token")
                self.env["BITWARDEN_SECRETS_TOKEN_FILE"] = str(self.root / "absent" if setting == "missing" else self.token)
                self.env["BITWARDEN_SECRETS_ENABLED"] = "false" if setting == "disabled" else "true"
                self.env["BITWARDEN_PROJECT_ID"] = "invalid" if setting == "invalid-project" else PROJECT
                self.start()
                result = self.client("available")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(b"fixture-machine-token", result.stderr)
                self.assertNotIn(b"wrong", result.stderr)
                self.stop()

    def test_unsafe_mount_and_permissions_fail_before_ipc(self):
        self.start(extra=[self.root])
        self.process.wait(timeout=5)
        self.assertNotEqual(self.process.returncode, 0)
        self.stop()
        self.directory.chmod(0o755)
        self.start()
        self.process.wait(timeout=5)
        self.assertNotEqual(self.process.returncode, 0)

    def test_parent_loss_stops_broker(self):
        self.start(parent=99999999)
        self.process.wait(timeout=5)
        self.assertEqual(self.process.returncode, 0)
        self.assertFalse((self.directory / "lock").exists())

    def test_concurrent_clients_and_stale_reply(self):
        self.start()
        clients = [subprocess.Popen(
            [sys.executable, "-IB", str(ROOT / "commitment-secret.py"), "generate", "same"],
            env={"COMMITMENT_SECRET_DIR": str(self.directory)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
        for client in clients:
            client.communicate(timeout=5)
        self.assertEqual(sorted(client.returncode for client in clients), [0, 1])
        self.assertEqual(len(self.state()["items"]), 1)
        fd = os.open(self.directory / "response", os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(fd, b'{"id":"old","result":{"ok":false}}\n')
        finally:
            os.close(fd)
        self.assertEqual(self.client("available").returncode, 0)

    def test_stop_during_backend_call_cleans_up(self):
        self.start()
        (self.mockdir / "sleep").touch()
        fd = os.open(self.directory / "request", os.O_WRONLY | os.O_NONBLOCK)
        os.write(fd, json.dumps({"id": "a" * 32, "request": {"op": "available"}}).encode() + b"\n")
        os.close(fd)
        time.sleep(0.1)
        self.stop()
        self.assertEqual(list(self.root.glob("bws-*")), [])

    def test_write_values_never_enter_process_argv_or_children(self):
        backend = self.backend()
        real_write = self.sdk.write
        entered, release = threading.Event(), threading.Event()

        def delayed(*args):
            entered.set()
            if not release.wait(5):
                raise RuntimeError("test timed out")
            return real_write(*args)

        for op, letter in (("generate", "Z"), ("rotate", "Y")):
            entered.clear()
            release.clear()
            errors = []

            def operate():
                try:
                    backend.operate({"op": op, "name": "argv-fixture"})
                except Exception as exc:
                    errors.append(type(exc).__name__)

            with mock.patch.object(self.sdk, "write", side_effect=delayed), \
                    mock.patch.object(broker.secrets, "choice", return_value=letter), \
                    mock.patch.object(subprocess, "Popen", side_effect=AssertionError("child forbidden")) as popen, \
                    mock.patch.object(os, "system", side_effect=AssertionError("shell forbidden")) as system, \
                    mock.patch.object(os, "posix_spawn", side_effect=AssertionError("spawn forbidden")) as spawn:
                worker = threading.Thread(target=operate)
                worker.start()
                try:
                    self.assertTrue(entered.wait(3))
                    inspected = 0
                    for path in Path("/proc").glob("[0-9]*/cmdline"):
                        try:
                            command = path.read_bytes()
                        except (FileNotFoundError, PermissionError, ProcessLookupError):
                            continue
                        inspected += 1
                        self.assertNotIn((letter * 48).encode(), command, "fixture in process argv")
                    self.assertGreater(inspected, 0)
                finally:
                    release.set()
                    worker.join(5)
                self.assertFalse(worker.is_alive())
                self.assertEqual(errors, [])
                popen.assert_not_called()
                system.assert_not_called()
                spawn.assert_not_called()
        source = (ROOT / "secret-broker.py").read_text()
        self.assertNotIn("subprocess", source)
        self.assertNotIn("communicate(", source)

    def test_entropy_bounds_and_sdk_result_scope(self):
        backend = self.backend()
        for length in (32, 48, 128):
            backend.operate({"op": "generate", "name": "length" + str(length), "length": length})
            self.assertEqual(len(self.sdk.values[-1]), length)
            self.assertRegex(self.sdk.values[-1], r"^[A-Za-z0-9]+$")
        self.assertEqual(len(set(self.sdk.values)), 3)
        good = self.sdk.get(self.state()["items"][0]["id"]).data
        with mock.patch.object(self.sdk, "create", return_value=fake_sdk.response(
                Object(**{**vars(good), "key": "new", "project_id": OTHER}))):
            with self.assertRaisesRegex(broker.Unavailable, "out-of-project"):
                backend.operate({"op": "generate", "name": "new"})
        for changes in ({"project_id": OTHER}, {"organization_id": OTHER}, {"key": "different"}):
            bad = Object(**{**vars(good), **changes})
            with mock.patch.object(self.sdk, "update", return_value=fake_sdk.response(bad)):
                with self.assertRaises(broker.Unavailable):
                    backend.operate({"op": "rotate", "name": "length32"})
        with mock.patch.object(self.sdk, "get", return_value=fake_sdk.response(
                Object(**{**vars(good), "project_id": OTHER}))), \
                mock.patch.object(self.sdk, "delete") as delete:
            with self.assertRaises(broker.Unavailable):
                backend.operate({"op": "delete", "name": "length32"})
            delete.assert_not_called()
        for deleted in ([], [Object(id=OTHER, error=None)],
                        [Object(id=good.id, error="fixture-machine-token")]):
            with mock.patch.object(self.sdk, "delete", return_value=fake_sdk.response(Object(data=deleted))):
                with self.assertRaisesRegex(broker.Unavailable, "single-secret"):
                    backend.operate({"op": "delete", "name": "length32"})

    def test_additional_token_file_checks(self):
        self.token.unlink()
        os.mkfifo(self.token, 0o600)
        with self.assertRaises(broker.Unavailable):
            self.backend()
        self.token.unlink()
        self.token.write_text("fixture-machine-token")
        self.token.chmod(0o600)
        os.link(self.token, self.root / "hardlink")
        with self.assertRaises(broker.Unavailable):
            self.backend()
        (self.root / "hardlink").unlink()
        with mock.patch.object(broker.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(broker.Unavailable):
                self.backend()
        with mock.patch.object(self.sdk, "login_access_token", return_value=fake_sdk.response(
                Object(authenticated=False))):
            with self.assertRaisesRegex(broker.Unavailable, "authentication failed"):
                self.backend()


class Cleanup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="commitment-cleanup-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / "runtime"
        self.state.mkdir(mode=0o700)

    def session(self, name="secrets-session.fixture"):
        directory = self.state / name
        directory.mkdir(mode=0o700)
        os.mkfifo(directory / "request", 0o600)
        os.mkfifo(directory / "response", 0o600)
        (directory / "lock").touch(mode=0o600)
        return directory

    def test_stale_missing_unrelated_and_legacy(self):
        stale = self.session()
        unrelated = self.session("unrelated")
        legacy = self.state / "bws-legacy"
        legacy.mkdir(mode=0o700)
        (self.state / "run.lock").touch(mode=0o644)
        broker.cleanup_stale(self.state)
        self.assertEqual((self.state / "run.lock").stat().st_mode & 0o777, 0o600)
        self.assertFalse(stale.exists())
        self.assertFalse(legacy.exists())
        self.assertTrue(unrelated.exists())
        broker.cleanup_stale(self.state / "missing")

    def test_active_session_shared_lock(self):
        active = self.session()
        lock = self.state / "run.lock"
        lock.touch(mode=0o600)
        with lock.open("rb") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            broker.cleanup_stale(self.state)
            self.assertTrue((active / "request").exists())
        broker.cleanup_stale(self.state)
        self.assertFalse(active.exists())

    def test_sigkill_residue_is_removed_on_later_cleanup(self):
        directory = self.state / "secrets-session.killed"
        directory.mkdir(mode=0o700)
        lock_fd = os.open(self.state / "run.lock", os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        child = subprocess.Popen(
            [sys.executable, "-IB", str(ROOT / "secret-broker.py"), str(directory), str(os.getpid())],
            env={"BITWARDEN_SECRETS_ENABLED": "false"}, pass_fds=(lock_fd,),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.close(lock_fd)  # Only the real broker now holds the inherited lock.
        try:
            for _ in range(100):
                if (directory / "lock").exists():
                    break
                time.sleep(0.01)
            self.assertTrue((directory / "lock").exists())
            broker.cleanup_stale(self.state)
            self.assertTrue(directory.exists())
            child.kill()
            child.communicate(timeout=5)
            self.assertTrue((directory / "request").exists())
            broker.cleanup_stale(self.state)
            self.assertFalse(directory.exists())
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate(timeout=5)

    def test_reject_symlinks_types_modes_owners_and_unknown_contents(self):
        external = self.root / "operator"
        external.mkdir(mode=0o700)
        token = external / "token"
        token.write_text("untouched fixture")
        (self.state / "secrets-session.symlink").symlink_to(external, target_is_directory=True)
        (self.state / "secrets-session.file").touch(mode=0o600)
        bad = self.session("secrets-session.bad")
        (bad / "request").unlink()
        (bad / "request").symlink_to(token)
        wrong_type = self.session("secrets-session.type")
        (wrong_type / "response").unlink()
        (wrong_type / "response").touch(mode=0o600)
        wrong_mode = self.session("secrets-session.mode")
        wrong_mode.chmod(0o755)
        unknown = self.session("secrets-session.unknown")
        (unknown / "nested").mkdir()
        owned = self.session("secrets-session.owner")
        with mock.patch.object(broker.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(broker.Unavailable):
                broker.cleanup_stale(self.state)
        self.assertTrue(owned.exists())
        real_stat = broker.os.fstat

        def other_owner(fd):
            info = real_stat(fd)
            if info.st_ino == owned.stat().st_ino:
                return Object(st_uid=os.getuid() + 1, st_mode=info.st_mode)
            return info

        with mock.patch.object(broker.os, "fstat", side_effect=other_owner):
            broker.cleanup_stale(self.state)
        for path in (bad, wrong_type, wrong_mode, unknown, owned):
            self.assertTrue(path.exists())
        self.assertEqual(token.read_text(), "untouched fixture")
        link = self.root / "root-link"
        link.symlink_to(self.state, target_is_directory=True)
        with self.assertRaises(OSError):
            broker.cleanup_stale(link)


if __name__ == "__main__":
    unittest.main()
