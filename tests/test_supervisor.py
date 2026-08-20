from __future__ import annotations

import errno
import fcntl
import hashlib
import io
import json
import math
import os
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Callable, Mapping, Sequence
from datetime import date
from pathlib import Path
from unittest import mock

from commitment.agent import prepare_request, render_response
from commitment.ollama import validate_ollama_url
from commitment.result import ExecutionError, JournalResult, PolicyError
from commitment.safeio import (
    open_regular_with_parent as safe_open_regular_with_parent,
    read_regular as safe_read_regular,
)
from commitment.supervisor import (
    CommandExecutor,
    CompletedCommand,
    Supervisor,
    build_container_command,
    main,
)

JOURNAL_PATH = "journal/2026-08-18-bounded-run.md"
JOURNAL_CONTENT = b"I read the repository.\nI wrote one journal.\n"


def git(repo: Path, *arguments: str, check: bool = True) -> str:
    completed = subprocess.run(
        ("git", *arguments),
        cwd=repo,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout


def repository_state(repo: Path) -> tuple[str, bytes, int, str]:
    index = repo / ".git" / "index"
    return (
        git(repo, "rev-parse", "HEAD").strip(),
        index.read_bytes(),
        index.stat().st_mode & 0o777,
        git(repo, "status", "--porcelain=v1", "--untracked-files=all"),
    )


def reflogs(repo: Path) -> tuple[bytes, bytes]:
    branch = git(repo, "symbolic-ref", "HEAD").strip().removeprefix("refs/")
    return (
        (repo / ".git" / "logs" / "HEAD").read_bytes(),
        (repo / ".git" / "logs" / "refs" / branch).read_bytes(),
    )


class FakeOllama:
    def __init__(self) -> None:
        self.requests: list[tuple[bytes, str, float]] = []

    def __call__(self, request: bytes, url: str, timeout: float) -> bytes:
        self.requests.append((request, url, timeout))
        mutation = {"path": JOURNAL_PATH, "content": JOURNAL_CONTENT.decode()}
        return json.dumps({"response": json.dumps(mutation)}).encode()


class FakeExecutor(CommandExecutor):
    def __init__(
        self,
        *,
        fail_git: str | None = None,
        on_prepare: Callable[[Path], None] | None = None,
        container_error: BaseException | None = None,
        cleanup_fails: bool = False,
        bad_render: str | None = None,
    ) -> None:
        self.fail_git = fail_git
        self.on_prepare = on_prepare
        self.container_error = container_error
        self.cleanup_fails = cleanup_fails
        self.bad_render = bad_render
        self.real = CommandExecutor()
        self.container_commands: list[tuple[str, ...]] = []
        self.cleanup_commands: list[tuple[str, ...]] = []
        self.snapshot_readme: bytes | None = None
        self.snapshot_paths: tuple[str, ...] = ()
        self.git_commands: list[tuple[tuple[str, ...], Mapping[str, str]]] = []

    def run(
        self,
        command: Sequence[str],
        *,
        cwd: Path,
        timeout: float | None = None,
        env: Mapping[str, str] | None = None,
        input_data: bytes | None = None,
        max_stdout: int = 64 * 1024,
        max_stderr: int = 64 * 1024,
    ) -> CompletedCommand:
        command = tuple(command)
        if command[:2] == ("podman", "run"):
            self.container_commands.append(command)
            if self.container_error is not None:
                raise self.container_error
            if "prepare" in command:
                mount = command[command.index("--mount") + 1]
                source = next(
                    part[7:] for part in mount.split(",") if part.startswith("source=")
                )
                snapshot = Path(source)
                self.snapshot_readme = (snapshot / "README.md").read_bytes()
                self.snapshot_paths = tuple(
                    sorted(
                        path.relative_to(snapshot).as_posix()
                        for path in snapshot.rglob("*")
                        if path.is_file()
                    )
                )
                if self.on_prepare is not None:
                    self.on_prepare(snapshot)
                model = command[command.index("--model") + 1]
                return CompletedCommand(
                    0,
                    prepare_request(snapshot, model, today=date(2026, 8, 18)),
                    b"",
                )
            assert input_data is not None
            report = render_response(input_data)
            if self.bad_render == "digest":
                report = JournalResult(report.path, report.content, report.size, "0" * 64)
            if self.bad_render == "path":
                report = JournalResult("unexpected.md", report.content, report.size, report.sha256)
            return CompletedCommand(0, report.to_json().encode(), b"")
        if command[:3] == ("podman", "container", "exists"):
            self.cleanup_commands.append(command)
            return CompletedCommand(0 if self.cleanup_fails else 1, b"", b"")
        if command and command[0] == "podman":
            self.cleanup_commands.append(command)
            return CompletedCommand(2 if self.cleanup_fails else 0, b"", b"cleanup failure")
        if command[0] == "git":
            assert env is not None
            self.git_commands.append((command, env))
            if self.fail_git is not None:
                operation = next(
                    (
                        value
                        for value in command
                        if value in {"update-index", "commit-tree", "update-ref"}
                    ),
                    "",
                )
                if operation == self.fail_git or (
                    self.fail_git == "journal-ref" and operation == "update-ref"
                ):
                    return CompletedCommand(70, b"", f"forced {operation} failure".encode())
        return self.real.run(
            command,
            cwd=cwd,
            timeout=timeout,
            env=env,
            input_data=input_data,
            max_stdout=max_stdout,
            max_stderr=max_stderr,
        )


class InterruptAfterCASExecutor(FakeExecutor):
    def run(self, command: Sequence[str], **kwargs: object) -> CompletedCommand:
        if command[0] == "git" and "update-ref" in command:
            self.real.run(command, **kwargs)
            raise KeyboardInterrupt()
        return super().run(command, **kwargs)


class InterruptIndexExecutor(FakeExecutor):
    def __init__(self, phase: str) -> None:
        super().__init__()
        self.phase = phase

    def run(self, command: Sequence[str], **kwargs: object) -> CompletedCommand:
        environment = kwargs.get("env")
        real_index_update = (
            command[0] == "git"
            and "update-index" in command
            and "--add" in command
            and isinstance(environment, Mapping)
            and "GIT_INDEX_FILE" not in environment
        )
        if not real_index_update:
            return super().run(command, **kwargs)
        if self.phase == "during":
            with mock.patch.object(
                selectors.DefaultSelector, "select", side_effect=KeyboardInterrupt()
            ):
                return self.real.run(command, **kwargs)
        result = self.real.run(command, **kwargs)
        if self.phase == "after":
            raise KeyboardInterrupt()
        return result


class ReplaceIndexThenInterruptExecutor(FakeExecutor):
    replacement: str | None = None

    def run(self, command: Sequence[str], **kwargs: object) -> CompletedCommand:
        environment = kwargs.get("env")
        real_index_update = (
            command[0] == "git"
            and "update-index" in command
            and "--add" in command
            and isinstance(environment, Mapping)
            and "GIT_INDEX_FILE" not in environment
        )
        if not real_index_update:
            return super().run(command, **kwargs)
        self.real.run(command, **kwargs)
        operation = command.index("update-index")
        hash_arguments = (
            *command[:operation],
            "hash-object",
            "--no-filters",
            "-w",
            "--stdin",
        )
        hash_kwargs = dict(kwargs)
        hash_kwargs["input_data"] = b"interfering index bytes\n"
        alternate = self.real.run(hash_arguments, **hash_kwargs).stdout.decode().strip()
        self.replacement = alternate
        replacement = list(command)
        replacement[replacement.index("--cacheinfo") + 2] = alternate
        self.real.run(tuple(replacement), **kwargs)
        raise KeyboardInterrupt()


class AddStagedOnlyThenInterruptExecutor(FakeExecutor):
    path = "concurrent-only.txt"

    def run(self, command: Sequence[str], **kwargs: object) -> CompletedCommand:
        environment = kwargs.get("env")
        real_index_update = (
            command[0] == "git"
            and "update-index" in command
            and "--add" in command
            and isinstance(environment, Mapping)
            and "GIT_INDEX_FILE" not in environment
        )
        if not real_index_update:
            return super().run(command, **kwargs)
        self.real.run(command, **kwargs)
        operation = command.index("update-index")
        hash_arguments = (
            *command[:operation],
            "hash-object",
            "--no-filters",
            "-w",
            "--stdin",
        )
        hash_kwargs = dict(kwargs)
        hash_kwargs["input_data"] = b"concurrent staged-only bytes\n"
        blob = self.real.run(hash_arguments, **hash_kwargs).stdout.decode().strip()
        addition = (
            *command[:operation],
            "update-index",
            "--add",
            "--cacheinfo",
            "100644",
            blob,
            self.path,
        )
        self.real.run(addition, **kwargs)
        raise KeyboardInterrupt()


class HoldCanonicalIndexLockThenInterruptExecutor(FakeExecutor):
    lock_content = b"external canonical Git lock\n"

    def run(self, command: Sequence[str], **kwargs: object) -> CompletedCommand:
        environment = kwargs.get("env")
        real_index_update = (
            command[0] == "git"
            and "update-index" in command
            and "--add" in command
            and isinstance(environment, Mapping)
            and "GIT_INDEX_FILE" not in environment
        )
        if not real_index_update:
            return super().run(command, **kwargs)
        self.real.run(command, **kwargs)
        git_directory = Path(
            next(
                value.removeprefix("--git-dir=")
                for value in command
                if value.startswith("--git-dir=")
            )
        )
        descriptor = os.open(
            git_directory / "index.lock", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
        )
        try:
            os.write(descriptor, self.lock_content)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        raise KeyboardInterrupt()


class SupervisorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary.name)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "commitment tests")
        git(self.repo, "config", "user.email", "commitment@example.invalid")
        (self.repo / "README.md").write_text("# commitment\n", encoding="utf-8")
        git(self.repo, "add", "README.md")
        git(self.repo, "commit", "-q", "-m", "test fixture")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def supervisor(
        self, executor: FakeExecutor | None = None
    ) -> tuple[Supervisor, FakeExecutor, FakeOllama]:
        actual_executor = executor or FakeExecutor()
        ollama = FakeOllama()
        return Supervisor(self.repo, actual_executor, ollama), actual_executor, ollama

    def add_ignored_artifacts(self) -> dict[str, bytes]:
        (self.repo / ".gitignore").write_text(
            ".venv/\n.ruff_cache/\ndist/\n*.egg-info/\n__pycache__/\n",
            encoding="utf-8",
        )
        git(self.repo, "add", ".gitignore")
        git(self.repo, "commit", "-q", "-m", "ignore development artifacts")
        artifacts = {
            ".venv/ignored-venv-secret.bin": b"venv\x00bytes\n",
            ".ruff_cache/ignored-ruff-secret.bin": b"ruff cache bytes\n",
            "dist/ignored-dist-secret.whl": b"wheel bytes\x00\n",
            "commitment.egg-info/ignored-egg-secret.txt": b"egg info bytes\n",
            "src/commitment/__pycache__/ignored-pycache-secret.pyc": b"pyc\x00bytes\n",
        }
        for relative, content in artifacts.items():
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        return artifacts

    def protected_state(self) -> tuple[object, ...]:
        return (
            repository_state(self.repo),
            reflogs(self.repo),
            git(self.repo, "for-each-ref", "--format=%(refname) %(objectname)"),
            (self.repo / ".git" / "config").read_bytes(),
            (self.repo / "README.md").read_bytes(),
        )

    def test_dry_run_changes_nothing_and_uses_pinned_head(self) -> None:
        (self.repo / "README.md").write_text("dirty working bytes\n", encoding="utf-8")
        before = repository_state(self.repo)
        supervisor, executor, ollama = self.supervisor()
        result = supervisor.run()
        self.assertFalse(result.applied)
        self.assertEqual(executor.snapshot_readme, b"# commitment\n")
        self.assertEqual(len(ollama.requests), 1)
        self.assertEqual(repository_state(self.repo), before)
        publication_commands = {
            "hash-object",
            "update-index",
            "write-tree",
            "commit-tree",
            "update-ref",
        }
        self.assertFalse(
            publication_commands.intersection(
                argument
                for command, environment in executor.git_commands
                if "GIT_INDEX_FILE" not in environment
                for argument in command
            )
        )

    def test_apply_and_commit_publish_only_validated_bytes(self) -> None:
        before = git(self.repo, "rev-parse", "HEAD").strip()
        before_logs = reflogs(self.repo)
        supervisor, _, _ = self.supervisor()
        result = supervisor.run(apply=True, commit=True)
        self.assertTrue(result.committed)
        self.assertNotEqual(git(self.repo, "rev-parse", "HEAD").strip(), before)
        self.assertEqual((self.repo / JOURNAL_PATH).read_bytes(), JOURNAL_CONTENT)
        self.assertEqual(
            git(self.repo, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").splitlines(),
            [JOURNAL_PATH],
        )
        self.assertEqual(git(self.repo, "status", "--porcelain=v1"), "")
        after_logs = reflogs(self.repo)
        self.assertEqual(len(after_logs[0].splitlines()), len(before_logs[0].splitlines()) + 1)
        self.assertEqual(len(after_logs[1].splitlines()), len(before_logs[1].splitlines()) + 1)

    def test_apply_and_commit_allow_and_exclude_ignored_artifacts(self) -> None:
        artifacts = self.add_ignored_artifacts()
        before = {path: (self.repo / path).read_bytes() for path in artifacts}
        supervisor, executor, ollama = self.supervisor()
        supervisor.run(apply=True, commit=True)

        self.assertEqual(
            {path: (self.repo / path).read_bytes() for path in artifacts}, before
        )
        for path, content in artifacts.items():
            self.assertNotIn(path, executor.snapshot_paths)
            self.assertNotIn(path.encode(), ollama.requests[0][0])
            self.assertNotIn(content, ollama.requests[0][0])
        tracked = git(self.repo, "ls-files", "-z").split("\0")
        committed = git(self.repo, "ls-tree", "-r", "--name-only", "HEAD").splitlines()
        for path in artifacts:
            self.assertNotIn(path, tracked)
            self.assertNotIn(path, committed)
        self.assertEqual(
            git(
                self.repo,
                "diff-tree",
                "--no-commit-id",
                "--name-only",
                "-r",
                "HEAD",
            ).splitlines(),
            [JOURNAL_PATH],
        )
        self.assertEqual(
            git(self.repo, "status", "--porcelain=v1", "--untracked-files=all"), ""
        )

    def test_commit_requires_apply(self) -> None:
        supervisor, _, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "--commit requires --apply"):
            supervisor.run(commit=True)

    def test_git_commands_disable_configured_execution_surfaces(self) -> None:
        executor = FakeExecutor()
        supervisor, _, _ = self.supervisor(executor)
        supervisor.run(apply=True, commit=True)
        for command, environment in executor.git_commands:
            self.assertEqual(command[:2], ("git", "--no-pager"))
            joined = " ".join(command)
            for setting in (
                "core.fsmonitor=false",
                "core.useReplaceRefs=false",
                "core.sparseCheckout=false",
                "commit.gpgSign=false",
                "diff.external=",
            ):
                self.assertIn(setting, joined)
            self.assertEqual(environment["GIT_CONFIG_GLOBAL"], os.devnull)
            self.assertEqual(environment["GIT_CONFIG_SYSTEM"], os.devnull)
            self.assertEqual(environment["GIT_NO_REPLACE_OBJECTS"], "1")
            self.assertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
            self.assertEqual(environment["GIT_PAGER"], "")
            self.assertEqual(environment["GIT_EXTERNAL_DIFF"], "")
        hash_command = next(c for c, _ in executor.git_commands if "hash-object" in c)
        self.assertIn("--stdin", hash_command)
        self.assertIn("--no-filters", hash_command)
        index_updates = [c for c, _ in executor.git_commands if "update-index" in c]
        self.assertTrue(
            all("--cacheinfo" in c or "--index-info" in c for c in index_updates)
        )

    def test_malicious_attributes_and_filter_config_are_rejected_without_execution(self) -> None:
        marker = self.repo.parent / f"filter-marker-{self.repo.name}"
        (self.repo / ".gitattributes").write_text("*.md filter=owned\n", encoding="utf-8")
        git(self.repo, "add", ".gitattributes")
        git(self.repo, "commit", "-q", "-m", "hostile attributes")
        git(self.repo, "config", "filter.owned.clean", f"touch {marker}")
        git(self.repo, "config", "filter.owned.smudge", f"touch {marker}")
        supervisor, executor, ollama = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "configured Git clean/smudge filters"):
            supervisor.run(apply=True, commit=True)
        self.assertFalse(marker.exists(), "malicious filter command executed")
        self.assertEqual(executor.container_commands, [])
        self.assertEqual(ollama.requests, [])

    def test_repository_replacement_refs_are_rejected(self) -> None:
        original = git(self.repo, "rev-parse", "HEAD").strip()
        (self.repo / "README.md").write_text("replacement\n", encoding="utf-8")
        git(self.repo, "add", "README.md")
        git(self.repo, "commit", "-q", "-m", "replacement")
        replacement = git(self.repo, "rev-parse", "HEAD").strip()
        git(self.repo, "reset", "--hard", "-q", original)
        git(self.repo, "replace", original, replacement)
        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "replacement refs"):
            supervisor.run()
        self.assertEqual(executor.container_commands, [])

    def test_assume_unchanged_does_not_hide_tracked_worktree_change(self) -> None:
        git(self.repo, "update-index", "--assume-unchanged", "README.md")
        before = git(self.repo, "ls-files", "--debug", "README.md")
        (self.repo / "README.md").write_text("hidden unrelated bytes\n", encoding="utf-8")
        supervisor, _, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "tracked worktree"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(git(self.repo, "ls-files", "--debug", "README.md"), before)
        self.assertFalse((self.repo / JOURNAL_PATH).exists())

    def test_review_reproducer_eol_lf_assume_unchanged_crlf_is_rejected(self) -> None:
        (self.repo / ".gitattributes").write_text("*.md text eol=lf\n", encoding="utf-8")
        git(self.repo, "add", ".gitattributes")
        git(self.repo, "commit", "-q", "-m", "add normalization")
        git(self.repo, "update-index", "--assume-unchanged", "README.md")
        (self.repo / "README.md").write_bytes(b"# commitment\r\n")

        self.assertEqual(git(self.repo, "status", "--porcelain=v1"), "")
        self.assertEqual(
            subprocess.run(
                ("git", "diff-files", "--quiet", "--", "README.md"),
                cwd=self.repo,
                check=False,
            ).returncode,
            0,
        )
        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "tracked worktree"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(executor.container_commands, [])
        self.assertEqual((self.repo / "README.md").read_bytes(), b"# commitment\r\n")

    def test_eol_lf_crlf_raw_mismatch_without_assume_unchanged_is_rejected(self) -> None:
        (self.repo / ".gitattributes").write_text("*.md text eol=lf\n", encoding="utf-8")
        git(self.repo, "add", ".gitattributes")
        git(self.repo, "commit", "-q", "-m", "add normalization")
        (self.repo / "README.md").write_bytes(b"# commitment\r\n")

        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "tracked worktree"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(executor.container_commands, [])

    def test_working_tree_encoding_raw_transformation_is_rejected(self) -> None:
        (self.repo / ".gitattributes").write_text(
            "*.txt text working-tree-encoding=UTF-16LE\n", encoding="utf-8"
        )
        encoded = self.repo / "encoded.txt"
        encoded.write_bytes("encoded\n".encode("utf-16-le"))
        git(self.repo, "add", ".gitattributes", "encoded.txt")
        git(self.repo, "commit", "-q", "-m", "add encoded file")
        self.assertEqual(encoded.read_bytes(), "encoded\n".encode("utf-16-le"))
        self.assertEqual(git(self.repo, "show", "HEAD:encoded.txt"), "encoded\n")
        self.assertEqual(git(self.repo, "status", "--porcelain=v1"), "")

        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "tracked worktree"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(executor.container_commands, [])

    def test_ident_raw_transformation_is_rejected(self) -> None:
        (self.repo / ".gitattributes").write_text("*.txt ident\n", encoding="utf-8")
        identified = self.repo / "identified.txt"
        identified.write_bytes(b"$Id$\n")
        git(self.repo, "add", ".gitattributes", "identified.txt")
        git(self.repo, "commit", "-q", "-m", "add identified file")
        identified.unlink()
        git(self.repo, "checkout-index", "--force", "--", "identified.txt")
        self.assertNotEqual(identified.read_bytes(), b"$Id$\n")
        self.assertEqual(git(self.repo, "show", "HEAD:identified.txt"), "$Id$\n")

        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "tracked worktree"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(executor.container_commands, [])

    def test_clean_raw_bytes_with_normalization_attributes_are_accepted(self) -> None:
        (self.repo / ".gitattributes").write_text("*.md text eol=lf\n", encoding="utf-8")
        git(self.repo, "add", ".gitattributes")
        git(self.repo, "commit", "-q", "-m", "add normalization")
        self.assertEqual(
            (self.repo / "README.md").read_bytes(),
            git(self.repo, "show", "HEAD:README.md").encode(),
        )

        supervisor, _, _ = self.supervisor()
        result = supervisor.run(apply=True)
        self.assertTrue(result.applied)

    def test_tracked_path_type_replacements_are_rejected(self) -> None:
        target = self.repo / "README.md"
        for kind in ("deleted", "symlink", "directory", "fifo"):
            with self.subTest(kind=kind):
                target.unlink()
                if kind == "symlink":
                    target.symlink_to("missing-target")
                elif kind == "directory":
                    target.mkdir()
                elif kind == "fifo":
                    os.mkfifo(target)
                supervisor, executor, _ = self.supervisor()
                with self.assertRaisesRegex(PolicyError, "tracked worktree"):
                    supervisor.run(apply=True, commit=True)
                self.assertEqual(executor.container_commands, [])
                if target.is_dir() and not target.is_symlink():
                    target.rmdir()
                else:
                    target.unlink(missing_ok=True)
                git(self.repo, "checkout", "-q", "--", "README.md")

    def test_staged_only_change_is_rejected(self) -> None:
        committed = (self.repo / "README.md").read_bytes()
        (self.repo / "README.md").write_bytes(b"staged only\n")
        git(self.repo, "add", "README.md")
        (self.repo / "README.md").write_bytes(committed)
        self.assertNotEqual(git(self.repo, "diff", "--cached", "--", "README.md"), "")
        self.assertEqual((self.repo / "README.md").read_bytes(), committed)

        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "staged"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(executor.container_commands, [])

    def test_skip_worktree_does_not_hide_tracked_worktree_change(self) -> None:
        git(self.repo, "update-index", "--skip-worktree", "README.md")
        before = git(self.repo, "ls-files", "--debug", "README.md")
        (self.repo / "README.md").write_text("hidden unrelated bytes\n", encoding="utf-8")
        supervisor, _, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "tracked worktree"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(git(self.repo, "ls-files", "--debug", "README.md"), before)
        self.assertFalse((self.repo / JOURNAL_PATH).exists())

    def test_hostile_ignorecase_config_cannot_hide_case_variant_untracked(self) -> None:
        git(self.repo, "config", "core.ignoreCase", "true")
        config = self.repo / ".git" / "config"
        before = config.read_bytes()
        (self.repo / "readme.md").write_text("case variant\n", encoding="utf-8")
        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "non-ignored untracked"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(config.read_bytes(), before)
        self.assertEqual(executor.container_commands, [])

    def test_hostile_filemode_config_cannot_hide_executable_change(self) -> None:
        git(self.repo, "config", "core.fileMode", "false")
        config = self.repo / ".git" / "config"
        before = config.read_bytes()
        (self.repo / "README.md").chmod(0o755)
        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "tracked worktree"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(config.read_bytes(), before)
        self.assertEqual(executor.container_commands, [])

    def test_hostile_ignorecase_and_filemode_config_are_both_overridden(self) -> None:
        git(self.repo, "config", "core.ignoreCase", "true")
        git(self.repo, "config", "core.fileMode", "false")
        (self.repo / "README.md").chmod(0o755)
        (self.repo / "readme.md").write_text("case variant\n", encoding="utf-8")
        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(
            PolicyError, "staged, tracked worktree, or non-ignored untracked"
        ):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(executor.container_commands, [])

    def test_hostile_autocrlf_cannot_combine_with_hidden_index_metadata(self) -> None:
        git(self.repo, "config", "core.autocrlf", "true")
        git(self.repo, "update-index", "--assume-unchanged", "README.md")
        (self.repo / "README.md").write_bytes(b"# commitment\r\n")
        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "tracked worktree"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(executor.container_commands, [])

    def test_cleanliness_overrides_precede_subcommands_and_ambient_config(self) -> None:
        hostile = {
            "GIT_CONFIG_COUNT": "3",
            "GIT_CONFIG_KEY_0": "core.ignoreCase",
            "GIT_CONFIG_VALUE_0": "true",
            "GIT_CONFIG_KEY_1": "core.fileMode",
            "GIT_CONFIG_VALUE_1": "false",
            "GIT_CONFIG_KEY_2": "core.precomposeUnicode",
            "GIT_CONFIG_VALUE_2": "true",
        }
        supervisor, executor, _ = self.supervisor()
        with mock.patch.dict(os.environ, hostile):
            supervisor.run(apply=True, commit=True)

        cleanliness_commands = []
        for command, environment in executor.git_commands:
            operation = next(
                (
                    item
                    for item in (
                        "status",
                        "diff-index",
                        "check-ignore",
                        "ls-files",
                    )
                    if item in command
                ),
                None,
            )
            if operation is None:
                continue
            cleanliness_commands.append(command)
            operation_index = command.index(operation)
            for setting in (
                "core.ignoreCase=false",
                "core.fileMode=true",
                "core.precomposeUnicode=false",
                "core.ignoreStat=false",
                "core.trustCtime=true",
                "core.checkStat=default",
                "core.autocrlf=false",
                "core.eol=lf",
            ):
                self.assertLess(command.index(setting), operation_index)
            self.assertNotIn("GIT_CONFIG_COUNT", environment)
        self.assertTrue(cleanliness_commands)
        status = next(command for command in cleanliness_commands if "status" in command)
        self.assertIn("--untracked-files=all", status)

    def test_clean_apply_preserves_repository_config_bytes(self) -> None:
        git(self.repo, "config", "core.ignoreCase", "true")
        git(self.repo, "config", "core.fileMode", "false")
        config = self.repo / ".git" / "config"
        before = config.read_bytes()
        supervisor, _, _ = self.supervisor()
        supervisor.run(apply=True, commit=True)
        self.assertEqual(config.read_bytes(), before)

    def test_unsupported_executable_semantics_fail_closed(self) -> None:
        real_fchmod = os.fchmod

        def suppress_executable_bit(descriptor: int, mode: int) -> None:
            if mode != 0o700:
                real_fchmod(descriptor, mode)

        supervisor, executor, _ = self.supervisor()
        with (
            mock.patch(
                "commitment.supervisor.os.fchmod",
                side_effect=suppress_executable_bit,
            ),
            self.assertRaisesRegex(
                PolicyError,
                "unsupported filesystem.*executable-bit tracking required",
            ),
        ):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(executor.container_commands, [])

    def test_raw_comparison_io_failure_preserves_repository_state(self) -> None:
        before = self.protected_state()

        def fail_readme(
            root_fd: int, parts: Sequence[str]
        ) -> tuple[int, int, str]:
            values = tuple(parts)
            if values == ("README.md",):
                raise OSError(errno.EACCES, "forced raw comparison failure")
            return safe_open_regular_with_parent(root_fd, values)

        supervisor, executor, _ = self.supervisor()
        with (
            mock.patch(
                "commitment.supervisor.open_regular_with_parent",
                side_effect=fail_readme,
            ),
            self.assertRaisesRegex(
                PolicyError, "cannot compare tracked worktree file safely"
            ),
        ):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(self.protected_state(), before)
        self.assertFalse((self.repo / JOURNAL_PATH).exists())
        self.assertEqual(executor.container_commands, [])

    def test_raw_path_replacement_immediately_after_open_is_rejected(self) -> None:
        artifacts = self.add_ignored_artifacts()
        target = self.repo / "README.md"
        backup = self.repo / "README.raced"
        index = self.repo / ".git" / "index"
        config = self.repo / ".git" / "config"
        raced_worktree: tuple[tuple[str, str, bytes], ...] | None = None

        def worktree_state() -> tuple[tuple[str, str, bytes], ...]:
            result: list[tuple[str, str, bytes]] = []
            for root, directories, files in os.walk(self.repo, followlinks=False):
                if Path(root) == self.repo and ".git" in directories:
                    directories.remove(".git")
                for name in sorted((*directories, *files)):
                    path = Path(root) / name
                    relative = path.relative_to(self.repo).as_posix()
                    metadata = path.lstat()
                    if stat.S_ISREG(metadata.st_mode):
                        result.append((relative, "file", path.read_bytes()))
                    elif stat.S_ISLNK(metadata.st_mode):
                        result.append((relative, "symlink", os.readlink(path).encode()))
                    elif stat.S_ISDIR(metadata.st_mode):
                        result.append((relative, "directory", b""))
                    else:
                        result.append((relative, "special", b""))
            return tuple(sorted(result))

        before = (
            git(self.repo, "rev-parse", "HEAD").strip(),
            index.read_bytes(),
            index.stat().st_mode & 0o777,
            reflogs(self.repo),
            git(self.repo, "for-each-ref", "--format=%(refname) %(objectname)"),
            config.read_bytes(),
            {path: (self.repo / path).read_bytes() for path in artifacts},
        )
        raced = False

        def replace_after_open(
            root_fd: int, parts: Sequence[str]
        ) -> tuple[int, int, str]:
            nonlocal raced, raced_worktree
            opened = safe_open_regular_with_parent(root_fd, parts)
            if tuple(parts) == ("README.md",) and not raced:
                target.rename(backup)
                target.write_bytes(b"dirty replacement\n")
                raced = True
                raced_worktree = worktree_state()
            return opened

        supervisor, executor, _ = self.supervisor()
        with (
            mock.patch(
                "commitment.supervisor.open_regular_with_parent",
                side_effect=replace_after_open,
            ),
            self.assertRaisesRegex(PolicyError, "pathname changed"),
        ):
            supervisor.run(apply=True, commit=True)

        self.assertTrue(raced)
        self.assertEqual(target.read_bytes(), b"dirty replacement\n")
        self.assertEqual(backup.read_bytes(), b"# commitment\n")
        self.assertEqual(worktree_state(), raced_worktree)
        self.assertFalse((self.repo / JOURNAL_PATH).exists())
        self.assertEqual(executor.container_commands, [])
        self.assertEqual(
            (
                git(self.repo, "rev-parse", "HEAD").strip(),
                index.read_bytes(),
                index.stat().st_mode & 0o777,
                reflogs(self.repo),
                git(self.repo, "for-each-ref", "--format=%(refname) %(objectname)"),
                config.read_bytes(),
                {path: (self.repo / path).read_bytes() for path in artifacts},
            ),
            before,
        )

    def test_raw_path_replacement_before_post_read_stat_is_rejected(self) -> None:
        target = self.repo / "README.md"
        backup = self.repo / "README.raced"
        real_stat = os.stat
        raced = False

        def replace_before_stat(
            path: object, *args: object, **kwargs: object
        ) -> os.stat_result:
            nonlocal raced
            if (
                path == "README.md"
                and kwargs.get("dir_fd") is not None
                and kwargs.get("follow_symlinks") is False
                and not raced
            ):
                target.rename(backup)
                target.write_bytes(b"dirty replacement\n")
                raced = True
            return real_stat(path, *args, **kwargs)

        supervisor, executor, _ = self.supervisor()
        with (
            mock.patch("commitment.supervisor.os.stat", side_effect=replace_before_stat),
            self.assertRaisesRegex(PolicyError, "pathname changed"),
        ):
            supervisor.run(apply=True, commit=True)
        self.assertTrue(raced)
        self.assertEqual(executor.container_commands, [])

    def test_raw_path_replacement_with_symlink_is_rejected(self) -> None:
        target = self.repo / "README.md"
        backup = self.repo / "README.raced"
        raced = False

        def symlink_after_open(
            root_fd: int, parts: Sequence[str]
        ) -> tuple[int, int, str]:
            nonlocal raced
            opened = safe_open_regular_with_parent(root_fd, parts)
            if tuple(parts) == ("README.md",) and not raced:
                target.rename(backup)
                target.symlink_to(backup.name)
                raced = True
            return opened

        supervisor, executor, _ = self.supervisor()
        with (
            mock.patch(
                "commitment.supervisor.open_regular_with_parent",
                side_effect=symlink_after_open,
            ),
            self.assertRaisesRegex(PolicyError, "pathname changed"),
        ):
            supervisor.run(apply=True, commit=True)
        self.assertTrue(target.is_symlink())
        self.assertEqual(executor.container_commands, [])

    def test_raw_path_deletion_after_open_is_rejected(self) -> None:
        target = self.repo / "README.md"
        backup = self.repo / "README.raced"
        raced = False

        def delete_after_open(
            root_fd: int, parts: Sequence[str]
        ) -> tuple[int, int, str]:
            nonlocal raced
            opened = safe_open_regular_with_parent(root_fd, parts)
            if tuple(parts) == ("README.md",) and not raced:
                target.rename(backup)
                raced = True
            return opened

        supervisor, executor, _ = self.supervisor()
        with (
            mock.patch(
                "commitment.supervisor.open_regular_with_parent",
                side_effect=delete_after_open,
            ),
            self.assertRaisesRegex(PolicyError, "cannot compare"),
        ):
            supervisor.run(apply=True, commit=True)
        self.assertFalse(target.exists())
        self.assertEqual(executor.container_commands, [])

    def test_raw_path_directory_replacement_after_open_is_rejected(self) -> None:
        target = self.repo / "README.md"
        backup = self.repo / "README.raced"
        raced = False

        def directory_after_open(
            root_fd: int, parts: Sequence[str]
        ) -> tuple[int, int, str]:
            nonlocal raced
            opened = safe_open_regular_with_parent(root_fd, parts)
            if tuple(parts) == ("README.md",) and not raced:
                target.rename(backup)
                target.mkdir()
                raced = True
            return opened

        supervisor, executor, _ = self.supervisor()
        with (
            mock.patch(
                "commitment.supervisor.open_regular_with_parent",
                side_effect=directory_after_open,
            ),
            self.assertRaisesRegex(PolicyError, "pathname changed"),
        ):
            supervisor.run(apply=True, commit=True)
        self.assertTrue(target.is_dir())
        self.assertEqual(executor.container_commands, [])

    def test_raw_in_place_write_during_read_is_rejected(self) -> None:
        target = self.repo / "README.md"
        raced = False

        def write_during_read(
            descriptor: int, *, expected_size: int, max_bytes: int
        ) -> bytes:
            nonlocal raced
            content = safe_read_regular(
                descriptor, expected_size=expected_size, max_bytes=max_bytes
            )
            if (
                os.readlink(f"/proc/self/fd/{descriptor}").endswith("/README.md")
                and not raced
            ):
                target.write_bytes(b"x" * len(content))
                raced = True
            return content

        supervisor, executor, _ = self.supervisor()
        with (
            mock.patch(
                "commitment.supervisor.read_regular", side_effect=write_during_read
            ),
            self.assertRaisesRegex(PolicyError, "file changed"),
        ):
            supervisor.run(apply=True, commit=True)
        self.assertTrue(raced)
        self.assertEqual(executor.container_commands, [])

    def test_raw_path_identity_accepts_unchanged_file(self) -> None:
        supervisor, _, _ = self.supervisor()
        result = supervisor.run(apply=True)
        self.assertTrue(result.applied)

    def test_raw_path_identity_accepts_same_inode_hard_link_alias(self) -> None:
        (self.repo / ".gitignore").write_text("README.alias\n", encoding="utf-8")
        git(self.repo, "add", ".gitignore")
        git(self.repo, "commit", "-q", "-m", "ignore hard-link alias")
        target = self.repo / "README.md"
        alias = self.repo / "README.alias"
        os.link(target, alias)
        raced = False

        def alias_after_open(
            root_fd: int, parts: Sequence[str]
        ) -> tuple[int, int, str]:
            nonlocal raced
            opened = safe_open_regular_with_parent(root_fd, parts)
            if tuple(parts) == ("README.md",) and not raced:
                target.unlink()
                os.link(alias, target)
                raced = True
            return opened

        supervisor, _, _ = self.supervisor()
        with mock.patch(
            "commitment.supervisor.open_regular_with_parent",
            side_effect=alias_after_open,
        ):
            result = supervisor.run(apply=True)
        self.assertTrue(result.applied)
        self.assertTrue(target.samefile(alias))

    def test_all_four_raw_revalidations_use_path_identity_primitive(self) -> None:
        readme_opens = 0

        def count_open(
            root_fd: int, parts: Sequence[str]
        ) -> tuple[int, int, str]:
            nonlocal readme_opens
            if tuple(parts) == ("README.md",):
                readme_opens += 1
            return safe_open_regular_with_parent(root_fd, parts)

        supervisor, _, _ = self.supervisor()
        with mock.patch(
            "commitment.supervisor.open_regular_with_parent", side_effect=count_open
        ):
            supervisor.run(apply=True, commit=True)

        # One initial pin read plus post-pin, pre-apply, post-apply, and pre-CAS reads.
        self.assertEqual(readme_opens, 5)

    def test_raw_comparison_limits_fail_closed_without_mutation(self) -> None:
        original = (self.repo / "README.md").read_bytes()
        cases = (
            ("file count", "MAX_TRACKED_ENTRIES", 0, original, "tracked entries"),
            (
                "individual bytes",
                "MAX_INSPECTED_FILE_BYTES",
                len(original),
                original + b"x",
                "tracked worktree file exceeds",
            ),
            (
                "aggregate bytes",
                "MAX_INSPECTED_TOTAL_BYTES",
                len(original),
                original + b"x",
                "tracked worktree exceeds",
            ),
        )
        for label, constant, limit, worktree, message in cases:
            with self.subTest(limit=label):
                (self.repo / "README.md").write_bytes(worktree)
                before = self.protected_state()
                supervisor, executor, _ = self.supervisor()
                with (
                    mock.patch(f"commitment.supervisor.{constant}", limit),
                    self.assertRaisesRegex(PolicyError, message),
                ):
                    supervisor.run(apply=True, commit=True)
                self.assertEqual(self.protected_state(), before)
                self.assertFalse((self.repo / JOURNAL_PATH).exists())
                self.assertEqual(executor.container_commands, [])
                (self.repo / "README.md").write_bytes(original)

    def test_invalid_rendered_results_are_rejected(self) -> None:
        for failure, message in (("digest", "does not match"), ("path", "unexpected changed path")):
            with self.subTest(failure=failure):
                supervisor, _, _ = self.supervisor(FakeExecutor(bad_render=failure))
                with self.assertRaisesRegex(PolicyError, message):
                    supervisor.run()

    def test_non_ignored_untracked_apply_rejected_but_dry_run_allowed(self) -> None:
        (self.repo / "dirty.txt").write_text("dirty\n", encoding="utf-8")
        supervisor, _, _ = self.supervisor()
        supervisor.run()
        supervisor, _, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "non-ignored untracked"):
            supervisor.run(apply=True)

    def test_staged_and_tracked_worktree_changes_are_rejected(self) -> None:
        for state in ("staged", "modified", "deleted"):
            with self.subTest(state=state):
                if state == "deleted":
                    (self.repo / "README.md").unlink()
                else:
                    (self.repo / "README.md").write_text(
                        f"{state}\n", encoding="utf-8"
                    )
                    if state == "staged":
                        git(self.repo, "add", "README.md")
                supervisor, executor, ollama = self.supervisor()
                with self.assertRaisesRegex(
                    PolicyError, "staged, tracked worktree"
                ):
                    supervisor.run(apply=True)
                self.assertEqual(executor.container_commands, [])
                self.assertEqual(ollama.requests, [])
                git(self.repo, "reset", "--hard", "-q", "HEAD")

    def test_unstaged_rename_is_rejected(self) -> None:
        (self.repo / "README.md").rename(self.repo / "RENAMED.md")
        supervisor, executor, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "tracked worktree"):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(executor.container_commands, [])

    def test_ignored_generated_journal_path_is_rejected(self) -> None:
        (self.repo / ".gitignore").write_text("journal/*.md\n", encoding="utf-8")
        git(self.repo, "add", ".gitignore")
        git(self.repo, "commit", "-q", "-m", "ignore journals")
        supervisor, _, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "generated journal path is ignored"):
            supervisor.run(apply=True)
        self.assertFalse((self.repo / JOURNAL_PATH).exists())

    def test_ignored_journal_parent_symlink_or_special_file_is_rejected(self) -> None:
        (self.repo / ".gitignore").write_text("/journal\n", encoding="utf-8")
        git(self.repo, "add", ".gitignore")
        git(self.repo, "commit", "-q", "-m", "ignore journal parent")
        for kind in ("symlink", "special file"):
            with self.subTest(kind=kind):
                target = self.repo / "journal"
                try:
                    if kind == "symlink":
                        target.symlink_to(self.repo / "outside")
                    else:
                        os.mkfifo(target)
                    supervisor, _, _ = self.supervisor()
                    with self.assertRaisesRegex(
                        PolicyError,
                        f"required journal parent conflicts with ignored {kind}",
                    ):
                        supervisor.run(apply=True)
                    metadata = target.lstat()
                    self.assertEqual(
                        stat.S_ISLNK(metadata.st_mode), kind == "symlink"
                    )
                    self.assertEqual(
                        stat.S_ISFIFO(metadata.st_mode), kind == "special file"
                    )
                finally:
                    target.unlink(missing_ok=True)

    def test_rollback_leaves_ignored_artifacts_untouched(self) -> None:
        artifacts = self.add_ignored_artifacts()
        before = {path: (self.repo / path).read_bytes() for path in artifacts}
        old_head = git(self.repo, "rev-parse", "HEAD").strip()
        supervisor, _, _ = self.supervisor(FakeExecutor(fail_git="journal-ref"))
        with self.assertRaises(ExecutionError):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD").strip(), old_head)
        self.assertEqual(
            {path: (self.repo / path).read_bytes() for path in artifacts}, before
        )
        self.assertFalse((self.repo / JOURNAL_PATH).exists())

    def test_concurrent_head_and_index_movement_rejected(self) -> None:
        def move_head(snapshot: Path) -> None:
            (self.repo / "README.md").write_text("moved\n", encoding="utf-8")
            git(self.repo, "add", "README.md")
            git(self.repo, "commit", "-q", "-m", "concurrent")

        supervisor, _, _ = self.supervisor(FakeExecutor(on_prepare=move_head))
        with self.assertRaisesRegex(PolicyError, "HEAD moved"):
            supervisor.run(apply=True)
        self.assertFalse((self.repo / JOURNAL_PATH).exists())

    def test_failures_before_cas_leave_no_publication(self) -> None:
        for stage in ("update-index", "commit-tree", "journal-ref"):
            with self.subTest(stage=stage):
                old_head = git(self.repo, "rev-parse", "HEAD").strip()
                old_logs = reflogs(self.repo)
                supervisor, _, _ = self.supervisor(FakeExecutor(fail_git=stage))
                with self.assertRaises(ExecutionError):
                    supervisor.run(apply=True, commit=True)
                self.assertEqual(git(self.repo, "rev-parse", "HEAD").strip(), old_head)
                self.assertEqual(reflogs(self.repo), old_logs)
                self.assertEqual(git(self.repo, "status", "--porcelain=v1"), "")

    def test_index_interruptions_restore_exact_repository_state(self) -> None:
        for phase in ("during", "after", "confirmation"):
            with self.subTest(phase=phase):
                before = repository_state(self.repo)
                readme = (self.repo / "README.md").read_bytes()
                supervisor, _, _ = self.supervisor(InterruptIndexExecutor(phase))
                if phase == "confirmation":
                    with mock.patch(
                        "commitment.supervisor._verify_staged",
                        side_effect=KeyboardInterrupt(),
                    ), self.assertRaises(KeyboardInterrupt):
                        supervisor.run(apply=True, commit=True)
                else:
                    with self.assertRaises(KeyboardInterrupt):
                        supervisor.run(apply=True, commit=True)
                self.assertEqual(repository_state(self.repo), before)
                self.assertEqual((self.repo / "README.md").read_bytes(), readme)
                self.assertFalse((self.repo / JOURNAL_PATH).exists())

    def test_index_cleanup_preserves_concurrent_same_path_replacement(self) -> None:
        before_head = git(self.repo, "rev-parse", "HEAD").strip()
        executor = ReplaceIndexThenInterruptExecutor()
        supervisor, _, _ = self.supervisor(executor)
        with self.assertRaises(KeyboardInterrupt) as caught:
            supervisor.run(apply=True, commit=True)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD").strip(), before_head)
        self.assertFalse((self.repo / JOURNAL_PATH).exists())
        self.assertTrue(git(self.repo, "status", "--porcelain=v1").startswith("AD "))
        self.assertEqual(
            git(self.repo, "ls-files", "--stage", "--", JOURNAL_PATH).split(),
            ["100644", executor.replacement, "0", JOURNAL_PATH],
        )
        self.assertFalse((self.repo / ".git" / "index.lock").exists())
        self.assertIn(
            "journal index entry was replaced; replacement preserved",
            "\n".join(caught.exception.__notes__),
        )

    def test_index_cleanup_preserves_concurrent_unrelated_staged_only_entry(
        self,
    ) -> None:
        executor = AddStagedOnlyThenInterruptExecutor()
        supervisor, _, _ = self.supervisor(executor)
        with self.assertRaises(KeyboardInterrupt):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(git(self.repo, "ls-files", "--", JOURNAL_PATH), "")
        self.assertNotEqual(
            git(self.repo, "ls-files", "--stage", "--", executor.path), ""
        )
        self.assertFalse((self.repo / executor.path).exists())
        self.assertEqual(
            git(self.repo, "status", "--porcelain=v1"), f"AD {executor.path}\n"
        )
        self.assertFalse((self.repo / ".git" / "index.lock").exists())

    def test_index_cleanup_preserves_contended_canonical_lock(self) -> None:
        executor = HoldCanonicalIndexLockThenInterruptExecutor()
        supervisor, _, _ = self.supervisor(executor)
        with self.assertRaises(KeyboardInterrupt) as caught:
            supervisor.run(apply=True, commit=True)
        lock = self.repo / ".git" / "index.lock"
        self.assertEqual(lock.read_bytes(), executor.lock_content)
        self.assertNotEqual(git(self.repo, "ls-files", "--", JOURNAL_PATH), "")
        self.assertIn(
            "repository index lock is held; existing lock preserved",
            "\n".join(caught.exception.__notes__),
        )

    def test_index_cleanup_interruption_before_and_after_final_rename(self) -> None:
        real_rename = os.rename
        for phase in ("before", "after"):
            with self.subTest(phase=phase):
                current_phase = phase
                before = repository_state(self.repo)
                renamed = False

                def interrupt_final_rename(
                    source: str,
                    destination: str,
                    *,
                    src_dir_fd: int | None = None,
                    dst_dir_fd: int | None = None,
                    phase_under_test: str = current_phase,
                ) -> None:
                    nonlocal renamed
                    if source == "index.lock" and destination == "index":
                        if phase_under_test == "after":
                            real_rename(
                                source,
                                destination,
                                src_dir_fd=src_dir_fd,
                                dst_dir_fd=dst_dir_fd,
                            )
                            renamed = True
                        raise KeyboardInterrupt()
                    real_rename(
                        source,
                        destination,
                        src_dir_fd=src_dir_fd,
                        dst_dir_fd=dst_dir_fd,
                    )

                supervisor, _, _ = self.supervisor(InterruptIndexExecutor("after"))
                with (
                    mock.patch(
                        "commitment.supervisor.os.rename",
                        side_effect=interrupt_final_rename,
                    ),
                    self.assertRaises(KeyboardInterrupt),
                ):
                    supervisor.run(apply=True, commit=True)
                self.assertFalse((self.repo / ".git" / "index.lock").exists())
                self.assertEqual(renamed, current_phase == "after")
                if current_phase == "after":
                    self.assertEqual(repository_state(self.repo), before)
                else:
                    self.assertNotEqual(
                        git(self.repo, "ls-files", "--", JOURNAL_PATH), ""
                    )
                    git(self.repo, "reset", "--mixed", "-q", "HEAD")

    def test_index_cleanup_exactly_restores_original_bytes_and_mode(self) -> None:
        index = self.repo / ".git" / "index"
        self.assertEqual(git(self.repo, "status", "--porcelain=v1"), "")
        index.chmod(0o640)
        before_bytes = index.read_bytes()
        before_mode = index.stat().st_mode & 0o777
        supervisor, _, _ = self.supervisor(InterruptIndexExecutor("after"))
        with self.assertRaises(KeyboardInterrupt):
            supervisor.run(apply=True, commit=True)
        self.assertEqual(index.read_bytes(), before_bytes)
        self.assertEqual(index.stat().st_mode & 0o777, before_mode)
        self.assertEqual(git(self.repo, "status", "--porcelain=v1"), "")
        self.assertFalse((self.repo / ".git" / "index.lock").exists())

    def test_git_hooks_never_run(self) -> None:
        custom = self.repo.parent / f"custom-hooks-{self.repo.name}"
        custom.mkdir()
        marker = self.repo.parent / f"hook-marker-{self.repo.name}"
        hook = custom / "reference-transaction"
        hook.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 91\n", encoding="utf-8")
        hook.chmod(0o755)
        git(self.repo, "config", "core.hooksPath", os.fspath(custom))
        supervisor, _, _ = self.supervisor()
        supervisor.run(apply=True, commit=True)
        self.assertFalse(marker.exists())

    def test_confirmed_cas_is_not_rolled_back_after_interrupt(self) -> None:
        old_head = git(self.repo, "rev-parse", "HEAD").strip()
        supervisor, _, _ = self.supervisor(InterruptAfterCASExecutor())
        with self.assertRaises(KeyboardInterrupt):
            supervisor.run(apply=True, commit=True)
        self.assertNotEqual(git(self.repo, "rev-parse", "HEAD").strip(), old_head)
        self.assertEqual((self.repo / JOURNAL_PATH).read_bytes(), JOURNAL_CONTENT)

    def test_container_stages_have_no_writable_mounts(self) -> None:
        prepare = build_container_command(
            stage="prepare",
            snapshot=Path("/proc/1/fd/10"),
            container_name="commitment-prepare-" + "a" * 32,
            image="commitment:latest",
            model="gpt-oss:20b",
        )
        render = build_container_command(
            stage="render",
            container_name="commitment-render-" + "b" * 32,
            image="commitment:latest",
        )
        for command in (prepare, render):
            self.assertEqual(command[command.index("--network") + 1], "none")
            self.assertEqual(command[command.index("--userns") + 1], "nomap")
            self.assertEqual(command[command.index("--user") + 1], "10001:10001")
            self.assertIn("--read-only", command)
            self.assertIn("--read-only-tmpfs=false", command)
            self.assertNotIn("--tmpfs", command)
            self.assertNotIn("--volume", command)
            self.assertIn("--cap-drop", command)
            self.assertIn("no-new-privileges", command)
        mounts = [prepare[index + 1] for index, value in enumerate(prepare) if value == "--mount"]
        self.assertEqual(len(mounts), 1)
        self.assertIn("destination=/repo,ro", mounts[0])
        self.assertEqual(prepare[prepare.index("--workspace") + 1], "/repo")
        self.assertNotIn("--mount", render)
        self.assertIn("--interactive", render)

    def test_ollama_endpoint_restricted_to_ip_loopback(self) -> None:
        self.assertEqual(validate_ollama_url("http://127.0.0.1:11434"), "http://127.0.0.1:11434")
        for value in (
            "https://127.0.0.1:11434",
            "http://localhost:11434",
            "http://example.invalid:11434",
            "http://secret@127.0.0.1:11434",
            "http://127.0.0.1:11434/api/generate",
            "http://127.0.0.1:0",
        ):
            with self.subTest(value=value), self.assertRaises(PolicyError):
                validate_ollama_url(value)

    def test_command_timeout_and_output_limits_terminate(self) -> None:
        with self.assertRaisesRegex(ExecutionError, "timed out"):
            CommandExecutor().run(
                (sys.executable, "-c", "import time; time.sleep(5)"),
                cwd=self.repo,
                timeout=0.05,
            )
        for stream in ("stdout", "stderr"):
            code = "import sys; sys.%s.write('x' * 70000); sys.%s.flush()" % (stream, stream)
            with self.subTest(stream=stream), self.assertRaisesRegex(
                ExecutionError, f"{stream} exceeds 65536 bytes"
            ):
                CommandExecutor().run((sys.executable, "-c", code), cwd=self.repo, timeout=4)

    def test_interrupt_kills_subprocess_group(self) -> None:
        with (
            mock.patch.object(selectors.DefaultSelector, "select", side_effect=KeyboardInterrupt()),
            mock.patch("commitment.supervisor.os.killpg", wraps=os.killpg) as killed,
            self.assertRaises(KeyboardInterrupt),
        ):
            CommandExecutor().run(
                (sys.executable, "-c", "import time; time.sleep(30)"), cwd=self.repo
            )
        self.assertEqual(killed.call_args.args[1], signal.SIGKILL)

    def test_timeout_forces_and_verifies_cleanup(self) -> None:
        executor = FakeExecutor(container_error=ExecutionError("command timed out"))
        supervisor, _, _ = self.supervisor(executor)
        with self.assertRaisesRegex(ExecutionError, "timed out"):
            supervisor.run(timeout=1)
        self.assertTrue(any(command[1] == "stop" for command in executor.cleanup_commands))
        self.assertTrue(any(command[1] == "rm" for command in executor.cleanup_commands))

    def test_repository_lock_serializes_supervisors(self) -> None:
        descriptor = os.open(self.repo / ".git" / "commitment.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            supervisor, _, _ = self.supervisor()
            with self.assertRaisesRegex(PolicyError, "another commitment supervisor"):
                supervisor.run()
        finally:
            os.close(descriptor)

    def test_invalid_timeout_values_are_clean_cli_errors(self) -> None:
        for value in ("nan", "inf", "-inf", "0", "-1", "3601"):
            stderr = io.StringIO()
            with self.subTest(value=value), mock.patch("sys.stderr", stderr), self.assertRaises(SystemExit):
                main((f"--timeout={value}",))
            self.assertIn("container timeout must be finite", stderr.getvalue())
        supervisor, _, _ = self.supervisor()
        for value in (math.nan, math.inf, 0.0, -1.0, 3601.0):
            with self.subTest(direct=value), self.assertRaisesRegex(PolicyError, "must be finite"):
                supervisor.run(timeout=value)


if __name__ == "__main__":
    unittest.main()
