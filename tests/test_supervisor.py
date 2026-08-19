from __future__ import annotations

import fcntl
import hashlib
import io
import json
import math
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from unittest import mock

from commitment.agent import render_response
from commitment.ollama import build_request, validate_ollama_url
from commitment.result import ExecutionError, JournalResult, PolicyError
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
                if self.on_prepare is not None:
                    self.on_prepare(snapshot)
                model = command[command.index("--model") + 1]
                return CompletedCommand(0, build_request("bounded prompt", model), b"")
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
                for command, _ in executor.git_commands
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
        self.assertTrue(all("--cacheinfo" in c or "--index-info" in c for c in index_updates))

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

    def test_assume_unchanged_metadata_survives(self) -> None:
        git(self.repo, "update-index", "--assume-unchanged", "README.md")
        before = git(self.repo, "ls-files", "--debug", "README.md")
        (self.repo / "README.md").write_text("hidden unrelated bytes\n", encoding="utf-8")
        supervisor, _, _ = self.supervisor()
        supervisor.run(apply=True, commit=True)
        self.assertEqual(git(self.repo, "ls-files", "--debug", "README.md"), before)
        self.assertEqual(git(self.repo, "show", "HEAD:README.md"), "# commitment\n")

    def test_invalid_rendered_results_are_rejected(self) -> None:
        for failure, message in (("digest", "does not match"), ("path", "unexpected changed path")):
            with self.subTest(failure=failure):
                supervisor, _, _ = self.supervisor(FakeExecutor(bad_render=failure))
                with self.assertRaisesRegex(PolicyError, message):
                    supervisor.run()

    def test_dirty_apply_rejected_but_dry_run_allowed(self) -> None:
        (self.repo / "dirty.txt").write_text("dirty\n", encoding="utf-8")
        supervisor, _, _ = self.supervisor()
        supervisor.run()
        supervisor, _, _ = self.supervisor()
        with self.assertRaisesRegex(PolicyError, "uncommitted, untracked, or ignored changes"):
            supervisor.run(apply=True)

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
