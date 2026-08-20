from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import os
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import BinaryIO

from commitment.agent import (
    DEFAULT_MAX_BYTES,
    JOURNAL_PATH,
    MAX_INSPECTED_FILE_BYTES,
    MAX_INSPECTED_TOTAL_BYTES,
    MAX_TRACKED_ENTRIES,
)
from commitment.ollama import (
    DEFAULT_MODEL,
    DEFAULT_OLLAMA_URL,
    MAX_REQUEST_BYTES,
    MAX_RESPONSE_BYTES,
    request_ollama,
    validate_ollama_url,
    validate_request,
)
from commitment.result import (
    CommitmentError,
    ExecutionError,
    JournalResult,
    PolicyError,
    validate_timeout,
)
from commitment.safeio import (
    atomic_write,
    open_child_directory,
    open_directory,
    open_parent,
    open_regular,
    open_regular_with_parent,
    read_regular,
)

DEFAULT_IMAGE = "commitment:latest"
DEFAULT_CONTAINER_TIMEOUT = 180.0
CONTAINER_UID = 10001
CONTAINER_GID = 10001
MAX_PROCESS_OUTPUT = 64 * 1024
MAX_RENDER_OUTPUT = 32 * 1024
MAX_CONTAINER_STDERR = 16 * 1024
MAX_TREE_LIST_BYTES = 1024 * 1024
MAX_INDEX_BYTES = 16 * 1024 * 1024
MAX_PREPARE_SECONDS = 30.0
MAX_RENDER_SECONDS = 30.0
COMMIT_AUTHOR_NAME = "commitment supervisor"
COMMIT_AUTHOR_EMAIL = "commitment@localhost.invalid"
_TREE_LINE = re.compile(
    r"(?P<mode>[0-9]{6}) +(?P<kind>[^ ]+) +(?P<oid>[0-9a-f]{40,64}) +(?P<size>[0-9-]+)\t(?P<path>.*)",
    re.DOTALL,
)
_CLEANLINESS_GIT_CONFIG = (
    "core.ignoreCase=false",
    "core.fileMode=true",
    "core.precomposeUnicode=false",
    "core.ignoreStat=false",
    "core.trustCtime=true",
    "core.checkStat=default",
    "core.autocrlf=false",
    "core.eol=lf",
)


@dataclass(frozen=True)
class CompletedCommand:
    returncode: int
    stdout: bytes
    stderr: bytes


class CommandExecutor:
    def run(
        self,
        command: Sequence[str],
        *,
        cwd: Path,
        timeout: float | None = None,
        env: Mapping[str, str] | None = None,
        input_data: bytes | None = None,
        max_stdout: int = MAX_PROCESS_OUTPUT,
        max_stderr: int = MAX_PROCESS_OUTPUT,
    ) -> CompletedCommand:
        try:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                env=env,
                stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
        except OSError as exc:
            raise ExecutionError(f"cannot execute {command[0]}: {exc}") from exc
        assert process.stdout is not None and process.stderr is not None
        selector = selectors.DefaultSelector()
        streams: dict[BinaryIO, tuple[str, bytearray, int]] = {
            process.stdout: ("stdout", bytearray(), max_stdout),
            process.stderr: ("stderr", bytearray(), max_stderr),
        }
        pending_input = memoryview(input_data or b"")
        try:
            if input_data is not None:
                assert process.stdin is not None
                os.set_blocking(process.stdin.fileno(), False)
                selector.register(process.stdin, selectors.EVENT_WRITE)
            for stream in streams:
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ)
            deadline = None if timeout is None else time.monotonic() + timeout
            while selector.get_map():
                remaining = None if deadline is None else deadline - time.monotonic()
                if remaining is not None and remaining <= 0:
                    raise ExecutionError(
                        f"command timed out after {timeout:g} seconds: {command[0]}"
                    )
                events = selector.select(remaining)
                if not events and deadline is not None:
                    raise ExecutionError(
                        f"command timed out after {timeout:g} seconds: {command[0]}"
                    )
                for key, _ in events:
                    stream = key.fileobj
                    assert hasattr(stream, "fileno")
                    if process.stdin is not None and stream is process.stdin:
                        try:
                            written = os.write(stream.fileno(), pending_input[:65536])
                            pending_input = pending_input[written:]
                        except (BrokenPipeError, OSError):
                            pending_input = pending_input[:0]
                        if not pending_input:
                            selector.unregister(stream)
                            stream.close()
                        continue
                    label, buffer, limit = streams[stream]
                    try:
                        chunk = os.read(
                            stream.fileno(), min(65536, max(1, limit - len(buffer) + 1))
                        )
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(stream)
                    elif len(buffer) + len(chunk) > limit:
                        raise ExecutionError(
                            f"command {label} exceeds {limit} bytes: {command[0]}"
                        )
                    else:
                        buffer.extend(chunk)
            returncode = process.wait()
        except BaseException:
            self._kill(process)
            raise
        finally:
            selector.close()
            process.stdout.close()
            process.stderr.close()
            if process.stdin is not None and not process.stdin.closed:
                process.stdin.close()
        return CompletedCommand(
            returncode,
            bytes(streams[process.stdout][1]),
            bytes(streams[process.stderr][1]),
        )

    @staticmethod
    def _kill(process: subprocess.Popen[bytes]) -> None:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                try:
                    process.kill()
                except OSError:
                    pass
        try:
            process.wait()
        except OSError:
            pass


def _display(raw: bytes) -> str:
    return raw.decode("utf-8", errors="replace").strip()


def require_success(result: CompletedCommand, command: Sequence[str]) -> bytes:
    if result.returncode:
        detail = _display(result.stderr) or _display(result.stdout) or "no diagnostic output"
        raise ExecutionError(f"command failed ({result.returncode}): {command[0]}: {detail}")
    return result.stdout


def _decode(raw: bytes, label: str) -> str:
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PolicyError(f"{label} is not valid UTF-8") from exc


def build_container_command(
    *,
    stage: str,
    container_name: str,
    image: str,
    snapshot: Path | None = None,
    model: str | None = None,
) -> tuple[str, ...]:
    if not image or image.startswith("-") or len(image.encode("utf-8")) > 512:
        raise PolicyError("container image must be a nonempty image reference")
    if stage not in {"prepare", "render"}:
        raise PolicyError("container stage is invalid")
    if not re.fullmatch(r"commitment-(?:prepare|render)-[0-9a-f]{32}", container_name):
        raise PolicyError("container name is invalid")
    if stage == "prepare":
        if snapshot is None:
            raise PolicyError("prepare container requires repository snapshot")
        if not model or "\x00" in model or len(model.encode("utf-8")) > 256:
            raise PolicyError("model must be a nonempty string without null bytes")
    elif snapshot is not None or model is not None:
        raise PolicyError("render container accepts no repository mount or model setting")
    if os.getuid() == 0:
        raise PolicyError("commitment requires rootless Podman from a non-root host account")
    command = [
        "podman",
        "run",
        "--name",
        container_name,
        "--read-only",
        "--read-only-tmpfs=false",
        "--network",
        "none",
        "--userns",
        "nomap",
        "--user",
        f"{CONTAINER_UID}:{CONTAINER_GID}",
        "--cap-drop",
        "all",
        "--security-opt",
        "no-new-privileges",
        "--pids-limit",
        "128",
        "--memory",
        "1g",
        "--cpus",
        "2",
    ]
    if stage == "render":
        command.append("--interactive")
    else:
        command.extend(
            (
                "--mount",
                f"type=bind,source={snapshot},destination=/repo,ro,Z",
            )
        )
    command.extend((image, stage))
    if stage == "prepare":
        assert model is not None
        command.extend(("--workspace", "/repo", "--model", model))
    return tuple(command)


def _sanitized_git_environment(*, index: Path | None = None) -> dict[str, str]:
    environment = {
        "PATH": os.defpath,
        "LC_ALL": "C",
        "LANG": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": os.devnull,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_PAGER": "",
        "PAGER": "",
        "GIT_EXTERNAL_DIFF": "",
        "GIT_AUTHOR_NAME": COMMIT_AUTHOR_NAME,
        "GIT_AUTHOR_EMAIL": COMMIT_AUTHOR_EMAIL,
        "GIT_COMMITTER_NAME": COMMIT_AUTHOR_NAME,
        "GIT_COMMITTER_EMAIL": COMMIT_AUTHOR_EMAIL,
    }
    if index is not None:
        environment["GIT_INDEX_FILE"] = os.fspath(index)
    return environment


class GitContext:
    def __init__(self, repo: Path, executor: CommandExecutor, hooks: Path) -> None:
        self.executor = executor
        self.repo_fd = -1
        self.git_fd = -1
        self.lock_fd = -1
        try:
            self.repo_fd = open_directory(repo)
            try:
                self.git_fd = open_child_directory(self.repo_fd, ".git")
            except (FileNotFoundError, NotADirectoryError) as exc:
                raise PolicyError("bare repositories and linked worktrees are unsupported") from exc
        except OSError as exc:
            self.close()
            raise PolicyError(f"cannot open repository without symlinks: {exc}") from exc
        process = os.getpid()
        self.repo_path = Path(f"/proc/{process}/fd/{self.repo_fd}")
        self.git_path = Path(f"/proc/{process}/fd/{self.git_fd}")
        self.git_prefix = (
            "git",
            "--no-pager",
            f"--git-dir={self.git_path}",
            f"--work-tree={self.repo_path}",
            "-c",
            f"core.hooksPath={hooks}",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "-c",
            "core.useReplaceRefs=false",
            "-c",
            "core.sparseCheckout=false",
            "-c",
            "core.sparseCheckoutCone=false",
            "-c",
            f"core.attributesFile={os.devnull}",
            "-c",
            f"core.excludesFile={os.devnull}",
            "-c",
            "commit.gpgSign=false",
            "-c",
            "diff.external=",
        )

    def __enter__(self) -> GitContext:
        try:
            self.lock_fd = os.open(
                "commitment.lock",
                os.O_RDWR
                | os.O_CREAT
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0),
                0o600,
                dir_fd=self.git_fd,
            )
            if not stat.S_ISREG(os.fstat(self.lock_fd).st_mode):
                raise PolicyError("repository lock is not a regular file")
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            self.close()
            raise PolicyError("another commitment supervisor is running for this repository") from exc
        except BaseException:
            self.close()
            raise
        return self

    def __exit__(self, *args: object) -> None:
        self.close()

    def close(self) -> None:
        for name in ("lock_fd", "git_fd", "repo_fd"):
            descriptor = getattr(self, name, -1)
            if descriptor >= 0:
                os.close(descriptor)
                setattr(self, name, -1)

    def execute(
        self,
        arguments: Sequence[str],
        *,
        timeout: float = 30,
        index: Path | None = None,
        input_data: bytes | None = None,
        max_stdout: int = MAX_PROCESS_OUTPUT,
    ) -> CompletedCommand:
        command = (*self.git_prefix, *arguments)
        return self.executor.run(
            command,
            cwd=self.repo_path,
            timeout=timeout,
            env=_sanitized_git_environment(index=index),
            input_data=input_data,
            max_stdout=max_stdout,
        )

    def cleanliness_execute(
        self,
        arguments: Sequence[str],
        *,
        timeout: float = 30,
        index: Path | None = None,
        input_data: bytes | None = None,
        max_stdout: int = MAX_PROCESS_OUTPUT,
    ) -> CompletedCommand:
        config = tuple(
            item
            for setting in _CLEANLINESS_GIT_CONFIG
            for item in ("-c", setting)
        )
        command = (*self.git_prefix, *config, *arguments)
        return self.executor.run(
            command,
            cwd=self.repo_path,
            timeout=timeout,
            env=_sanitized_git_environment(index=index),
            input_data=input_data,
            max_stdout=max_stdout,
        )

    def git(self, arguments: Sequence[str], **kwargs: object) -> bytes:
        result = self.execute(arguments, **kwargs)
        return require_success(result, (*self.git_prefix, *arguments))

    def cleanliness_git(self, arguments: Sequence[str], **kwargs: object) -> bytes:
        result = self.cleanliness_execute(arguments, **kwargs)
        return require_success(result, (*self.git_prefix, *arguments))


@dataclass(frozen=True)
class IndexRecord:
    path: bytes
    stage: bytes
    flag: bytes


def _index_records(
    context: GitContext, *, index: Path | None = None
) -> tuple[IndexRecord, ...]:
    stage_raw = context.cleanliness_git(
        ("ls-files", "--stage", "-z"), index=index, max_stdout=MAX_INDEX_BYTES
    )
    flag_raw = context.cleanliness_git(
        ("ls-files", "-v", "-z"), index=index, max_stdout=MAX_INDEX_BYTES
    )
    stages: dict[bytes, bytes] = {}
    flags: dict[bytes, bytes] = {}
    for item in stage_raw.split(b"\0"):
        if not item:
            continue
        try:
            _, path = item.split(b"\t", 1)
        except ValueError as exc:
            raise PolicyError("Git returned malformed index entry") from exc
        if path in stages:
            raise PolicyError("unmerged index entries are unsupported")
        stages[path] = item
    for item in flag_raw.split(b"\0"):
        if not item:
            continue
        if len(item) < 3 or item[1:2] != b" ":
            raise PolicyError("Git returned malformed index flags")
        path = item[2:]
        if path in flags:
            raise PolicyError("duplicate index entry")
        flags[path] = item[:1]
    if stages.keys() != flags.keys():
        raise PolicyError("Git returned inconsistent index entries")
    return tuple(IndexRecord(path, stages[path], flags[path]) for path in sorted(stages))


def _read_index(context: GitContext) -> tuple[bytes, int]:
    try:
        descriptor = open_regular(context.git_fd, ("index",))
    except OSError as exc:
        raise PolicyError(f"cannot read repository index safely: {exc}") from exc
    try:
        metadata = os.fstat(descriptor)
        return (
            read_regular(descriptor, expected_size=metadata.st_size, max_bytes=MAX_INDEX_BYTES),
            stat.S_IMODE(metadata.st_mode),
        )
    except OSError as exc:
        raise PolicyError(f"repository index exceeds safe bounds or changed: {exc}") from exc
    finally:
        os.close(descriptor)


def _head(context: GitContext) -> str:
    return _decode(context.git(("rev-parse", "--verify", "HEAD^{commit}")), "HEAD").strip()


def _branch(context: GitContext) -> str:
    result = context.execute(("symbolic-ref", "-q", "HEAD"))
    if result.returncode:
        raise PolicyError("detached HEAD is unsupported")
    branch = _decode(result.stdout, "HEAD branch").strip()
    if not branch.startswith("refs/heads/"):
        raise PolicyError("HEAD must name a local branch")
    return branch


def _status(context: GitContext) -> bytes:
    raw = context.cleanliness_git(
        (
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--ignore-submodules=none",
            "--no-renames",
        )
    )
    safe: list[bytes] = []
    for item in raw.split(b"\0"):
        if not item:
            continue
        if len(item) < 4 or item[2:3] != b" ":
            raise PolicyError("Git returned malformed worktree status")
        if item[:2] == b"??" or item[:1] != b" ":
            safe.append(item)
    return b"\0".join(safe) + (b"\0" if safe else b"")


def _staged_index_is_clean(context: GitContext, head: str) -> bool:
    result = context.cleanliness_execute(
        (
            "diff-index",
            "--cached",
            "--quiet",
            "--no-ext-diff",
            "--ignore-submodules=none",
            head,
            "--",
        ),
    )
    if result.returncode not in {0, 1}:
        require_success(result, (*context.git_prefix, "diff-index"))
    return result.returncode == 0


def _is_ignored(context: GitContext, path: str) -> bool:
    result = context.cleanliness_execute(
        ("check-ignore", "--quiet", "--no-index", "--", path)
    )
    if result.returncode not in {0, 1}:
        require_success(result, (*context.git_prefix, "check-ignore"))
    return result.returncode == 0


def reject_configured_filters(context: GitContext) -> None:
    raw = context.git(
        ("config", "--local", "--includes", "--name-only", "--null", "--list"),
        max_stdout=MAX_INDEX_BYTES,
    )
    pattern = re.compile(r"filter\..+\.(?:clean|smudge|process|required)")
    configured = sorted(
        {
            _decode(name, "Git configuration key")
            for name in raw.split(b"\0")
            if name and pattern.fullmatch(_decode(name, "Git configuration key").lower())
        }
    )
    if configured:
        raise PolicyError(
            "configured Git clean/smudge filters are unsupported: "
            + ", ".join(configured)
        )


def _require_cleanliness_filesystem(context: GitContext) -> None:
    if not sys.platform.startswith("linux"):
        raise PolicyError("unsupported filesystem for Phase 0 cleanliness: Linux required")
    if os.fstat(context.repo_fd).st_dev != os.fstat(context.git_fd).st_dev:
        raise PolicyError(
            "unsupported filesystem for Phase 0 cleanliness: "
            "worktree and Git directory must share one filesystem"
        )
    directory = f"commitment-fsprobe-{uuid.uuid4().hex}"
    directory_fd = -1
    directory_created = False
    created: list[str] = []

    def create(name: str, mode: int = 0o600) -> os.stat_result:
        descriptor = os.open(
            name,
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            mode,
            dir_fd=directory_fd,
        )
        created.append(name)
        try:
            return os.fstat(descriptor)
        finally:
            os.close(descriptor)

    try:
        os.mkdir(directory, 0o700, dir_fd=context.git_fd)
        directory_created = True
        directory_fd = open_child_directory(context.git_fd, directory)
        lower = create("case")
        try:
            upper = create("CASE")
        except FileExistsError as exc:
            raise PolicyError(
                "unsupported filesystem for Phase 0 cleanliness: "
                "case-sensitive filenames required"
            ) from exc
        if (lower.st_dev, lower.st_ino) == (upper.st_dev, upper.st_ino):
            raise PolicyError(
                "unsupported filesystem for Phase 0 cleanliness: "
                "case-sensitive filenames required"
            )

        mode_name = "executable-mode"
        create(mode_name)
        mode_fd = os.open(
            mode_name,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            dir_fd=directory_fd,
        )
        try:
            os.fchmod(mode_fd, 0o700)
            if stat.S_IMODE(os.fstat(mode_fd).st_mode) & 0o111 != 0o100:
                raise PolicyError(
                    "unsupported filesystem for Phase 0 cleanliness: "
                    "executable-bit tracking required"
                )
        finally:
            os.close(mode_fd)

        decomposed = create("e\N{COMBINING ACUTE ACCENT}")
        try:
            composed = create("\N{LATIN SMALL LETTER E WITH ACUTE}")
        except FileExistsError as exc:
            raise PolicyError(
                "unsupported filesystem for Phase 0 cleanliness: "
                "Unicode filename preservation required"
            ) from exc
        if (decomposed.st_dev, decomposed.st_ino) == (
            composed.st_dev,
            composed.st_ino,
        ):
            raise PolicyError(
                "unsupported filesystem for Phase 0 cleanliness: "
                "Unicode filename preservation required"
            )
    except PolicyError:
        raise
    except OSError as exc:
        raise PolicyError(
            f"unsupported filesystem for Phase 0 cleanliness: cannot verify semantics: {exc}"
        ) from exc
    finally:
        if directory_fd >= 0:
            cleanup_error: OSError | None = None
            for name in reversed(created):
                try:
                    os.unlink(name, dir_fd=directory_fd)
                except OSError as exc:
                    cleanup_error = cleanup_error or exc
            os.close(directory_fd)
            try:
                os.rmdir(directory, dir_fd=context.git_fd)
            except OSError as exc:
                cleanup_error = cleanup_error or exc
            if cleanup_error is not None and sys.exc_info()[0] is None:
                raise PolicyError(
                    "unsupported filesystem for Phase 0 cleanliness: "
                    f"cannot clean capability probe: {cleanup_error}"
                ) from cleanup_error
        elif directory_created:
            try:
                os.rmdir(directory, dir_fd=context.git_fd)
            except OSError:
                pass


def _safe_relative(value: str) -> tuple[str, ...]:
    pure = PurePosixPath(value)
    if pure.is_absolute() or not pure.parts or ".git" in pure.parts:
        raise PolicyError(f"unsafe Git tree path: {value}")
    if any(part in {"", ".", ".."} for part in pure.parts):
        raise PolicyError(f"unsafe Git tree path: {value}")
    return pure.parts


@dataclass(frozen=True)
class TreeEntry:
    path: str
    parts: tuple[str, ...]
    oid: str
    size: int
    executable: bool


def _tree_entries(context: GitContext, revision: str) -> tuple[TreeEntry, ...]:
    raw = context.git(
        ("ls-tree", "-rz", "--full-tree", "--long", "-r", revision),
        max_stdout=MAX_TREE_LIST_BYTES,
    )
    entries: list[TreeEntry] = []
    total = 0
    for item in raw.split(b"\0"):
        if not item:
            continue
        if len(entries) >= MAX_TRACKED_ENTRIES:
            raise PolicyError(f"Git tree exceeds {MAX_TRACKED_ENTRIES} tracked entries")
        line = _decode(item, "Git tree entry")
        match = _TREE_LINE.fullmatch(line)
        if match is None:
            raise PolicyError("Git returned malformed tree entry")
        mode = match["mode"]
        if match["kind"] != "blob" or mode not in {"100644", "100755"}:
            raise PolicyError(f"unsupported Git tree entry: {match['path']} ({mode})")
        size = int(match["size"])
        if size < 0:
            raise PolicyError("Git returned malformed tree entry size")
        if size > MAX_INSPECTED_FILE_BYTES:
            raise PolicyError(
                "tracked file exceeds "
                f"{MAX_INSPECTED_FILE_BYTES} bytes: {match['path']}"
            )
        total += size
        if total > MAX_INSPECTED_TOTAL_BYTES:
            raise PolicyError(
                f"Git tree exceeds {MAX_INSPECTED_TOTAL_BYTES} inspected bytes"
            )
        entries.append(
            TreeEntry(
                match["path"],
                _safe_relative(match["path"]),
                match["oid"],
                size,
                mode == "100755",
            )
        )
    if not entries:
        raise PolicyError("repository has no tracked regular files")
    return tuple(entries)


def _read_blob(context: GitContext, entry: TreeEntry) -> bytes:
    content = context.git(("cat-file", "blob", entry.oid), max_stdout=entry.size)
    if len(content) != entry.size:
        raise PolicyError(f"Git blob size changed for {entry.path}")
    return content


_WORKTREE_TYPE_MISMATCH = {
    errno.ENOENT,
    errno.ENOTDIR,
    errno.EISDIR,
    errno.ELOOP,
    errno.EINVAL,
    errno.ENXIO,
    errno.ENODEV,
}


def _tracked_worktree_is_clean(
    context: GitContext, entries: tuple[TreeEntry, ...]
) -> bool:
    clean = True
    total = 0
    for entry in entries:
        expected = _read_blob(context, entry)
        descriptor = -1
        parent_descriptor = -1
        name = ""
        try:
            descriptor, parent_descriptor, name = open_regular_with_parent(
                context.repo_fd, entry.parts
            )
        except OSError as exc:
            if exc.errno in _WORKTREE_TYPE_MISMATCH:
                clean = False
                continue
            raise PolicyError(
                f"cannot compare tracked worktree file safely: {entry.path}: {exc}"
            ) from exc
        try:
            before = os.fstat(descriptor)
            if before.st_size > MAX_INSPECTED_FILE_BYTES:
                raise PolicyError(
                    "tracked worktree file exceeds "
                    f"{MAX_INSPECTED_FILE_BYTES} bytes: {entry.path}"
                )
            total += before.st_size
            if total > MAX_INSPECTED_TOTAL_BYTES:
                raise PolicyError(
                    "tracked worktree exceeds "
                    f"{MAX_INSPECTED_TOTAL_BYTES} inspected bytes"
                )
            content = read_regular(
                descriptor,
                expected_size=before.st_size,
                max_bytes=MAX_INSPECTED_FILE_BYTES,
            )
            after = os.fstat(descriptor)
            if (
                before.st_dev,
                before.st_ino,
                before.st_mode,
                before.st_size,
                before.st_mtime_ns,
                before.st_ctime_ns,
            ) != (
                after.st_dev,
                after.st_ino,
                after.st_mode,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            ):
                raise PolicyError(
                    f"tracked worktree file changed during raw comparison: {entry.path}"
                )
            pathname = os.stat(
                name, dir_fd=parent_descriptor, follow_symlinks=False
            )
            if not stat.S_ISREG(pathname.st_mode) or (
                pathname.st_dev,
                pathname.st_ino,
            ) != (after.st_dev, after.st_ino):
                raise PolicyError(
                    f"tracked worktree pathname changed during raw comparison: {entry.path}"
                )
            if (
                content != expected
                or bool(before.st_mode & stat.S_IXUSR) != entry.executable
            ):
                clean = False
        except PolicyError:
            raise
        except OSError as exc:
            raise PolicyError(
                f"cannot compare tracked worktree file safely: {entry.path}: {exc}"
            ) from exc
        finally:
            os.close(descriptor)
            os.close(parent_descriptor)
    return clean


@dataclass(frozen=True)
class PinnedState:
    head: str
    branch: str
    index: bytes
    index_mode: int
    index_records: tuple[IndexRecord, ...]
    status: bytes
    entries: tuple[TreeEntry, ...]
    staged_index_clean: bool
    tracked_worktree_clean: bool


def pin_state(context: GitContext) -> PinnedState:
    reject_configured_filters(context)
    _require_cleanliness_filesystem(context)
    replacements = context.git(("for-each-ref", "--format=%(refname)", "refs/replace/"))
    if replacements:
        raise PolicyError("Git replacement refs are unsupported")
    index, index_mode = _read_index(context)
    head = _head(context)
    entries = _tree_entries(context, head)
    return PinnedState(
        head,
        _branch(context),
        index,
        index_mode,
        _index_records(context),
        _status(context),
        entries,
        _staged_index_is_clean(context, head),
        _tracked_worktree_is_clean(context, entries),
    )


def verify_state(context: GitContext, pinned: PinnedState) -> None:
    if _branch(context) != pinned.branch or _head(context) != pinned.head:
        raise PolicyError("repository HEAD moved during supervisor run")
    if _read_index(context) != (pinned.index, pinned.index_mode):
        raise PolicyError("repository index moved during supervisor run")
    if _status(context) != pinned.status:
        raise PolicyError("repository state moved during supervisor run")
    if pinned.tracked_worktree_clean and not _tracked_worktree_is_clean(
        context, pinned.entries
    ):
        raise PolicyError("tracked worktree moved during supervisor run")


def create_snapshot(
    context: GitContext, destination_fd: int, entries: tuple[TreeEntry, ...]
) -> None:
    for entry in entries:
        content = _read_blob(context, entry)
        try:
            atomic_write(
                destination_fd,
                entry.parts,
                content,
                mode=0o755 if entry.executable else 0o644,
                create_parents=True,
            )
        except OSError as exc:
            raise PolicyError(
                f"cannot extract Git tree entry safely: {entry.path}: {exc}"
            ) from exc


@dataclass(frozen=True)
class ValidatedMutation:
    path: str
    parts: tuple[str, ...]
    content: bytes


def validate_rendered(report: JournalResult) -> ValidatedMutation:
    if not JOURNAL_PATH.fullmatch(report.path):
        raise PolicyError(f"unexpected changed path: {report.path}")
    content = report.content.encode("utf-8")
    if len(content) > DEFAULT_MAX_BYTES:
        raise PolicyError("rendered journal exceeds journal byte limit")
    digest = hashlib.sha256(content).hexdigest()
    if report.size != len(content) or report.sha256 != digest:
        raise PolicyError("render result does not match journal bytes")
    text = report.content
    if not text.strip() or not text.endswith("\n"):
        raise PolicyError("rendered journal must be nonempty and end with newline")
    return ValidatedMutation(report.path, _safe_relative(report.path), content)


def reject_ignored_journal_conflicts(
    context: GitContext, mutation: ValidatedMutation
) -> None:
    for end in range(1, len(mutation.parts) + 1):
        relative = "/".join(mutation.parts[:end])
        try:
            metadata = os.stat(relative, dir_fd=context.repo_fd, follow_symlinks=False)
        except FileNotFoundError:
            metadata = None
        except OSError as exc:
            raise PolicyError(f"cannot inspect proposed journal path safely: {exc}") from exc
        if metadata is not None and _is_ignored(context, relative):
            if stat.S_ISDIR(metadata.st_mode):
                kind = "directory"
            elif stat.S_ISREG(metadata.st_mode):
                kind = "file"
            elif stat.S_ISLNK(metadata.st_mode):
                kind = "symlink"
            else:
                kind = "special file"
            label = (
                "required journal parent"
                if end < len(mutation.parts)
                else "proposed journal path"
            )
            raise PolicyError(f"{label} conflicts with ignored {kind}: {relative}")
    if _is_ignored(context, mutation.path):
        raise PolicyError(f"generated journal path is ignored by Git: {mutation.path}")


def _container_absent(executor: CommandExecutor, name: str, cwd: Path) -> bool:
    result = executor.run(("podman", "container", "exists", name), cwd=cwd, timeout=10)
    if result.returncode not in {0, 1}:
        raise ExecutionError(f"cannot verify container cleanup: {_display(result.stderr)}")
    return result.returncode == 1


def _force_container_cleanup(executor: CommandExecutor, name: str, cwd: Path) -> None:
    diagnostics: list[str] = []
    for command in (
        ("podman", "stop", "--time", "1", name),
        ("podman", "rm", "--force", name),
    ):
        try:
            result = executor.run(command, cwd=cwd, timeout=10)
            if result.returncode not in {0, 1, 125}:
                diagnostics.append(f"{command[1]} failed ({result.returncode})")
        except BaseException as exc:
            diagnostics.append(f"{command[1]} cleanup failed: {exc}")
    try:
        if not _container_absent(executor, name, cwd):
            diagnostics.append("container still exists after forced removal")
    except BaseException as exc:
        diagnostics.append(str(exc))
    if diagnostics:
        raise ExecutionError("; ".join(diagnostics))


def run_container(
    executor: CommandExecutor,
    command: Sequence[str],
    *,
    cwd: Path,
    timeout: float,
    name: str,
    input_data: bytes | None = None,
    max_stdout: int = MAX_PROCESS_OUTPUT,
) -> CompletedCommand:
    original: BaseException | None = None
    result: CompletedCommand | None = None
    try:
        result = executor.run(
            command,
            cwd=cwd,
            timeout=timeout,
            input_data=input_data,
            max_stdout=max_stdout,
            max_stderr=MAX_CONTAINER_STDERR,
        )
    except BaseException as exc:
        original = exc
    cleanup: BaseException | None = None
    try:
        _force_container_cleanup(executor, name, cwd)
    except BaseException as exc:
        cleanup = exc
    if original is not None:
        if isinstance(original, (KeyboardInterrupt, SystemExit)):
            if cleanup is not None and hasattr(original, "add_note"):
                original.add_note(f"container cleanup failed: {cleanup}")
            raise original
        if cleanup is not None:
            raise ExecutionError(f"{original}; container cleanup failed: {cleanup}") from original
        raise original
    if cleanup is not None:
        raise ExecutionError(f"container cleanup failed: {cleanup}") from cleanup
    assert result is not None
    return result


@dataclass(frozen=True)
class PreparedCommit:
    revision: str
    blob: str


def prepare_commit(
    context: GitContext,
    temporary: Path,
    mutation: ValidatedMutation,
    head: str,
) -> PreparedCommit:
    temporary_fd = open_directory(temporary)
    try:
        index = Path(f"/proc/{os.getpid()}/fd/{temporary_fd}/commit.index")
        context.git(("read-tree", head), index=index)
        blob = _decode(
            context.git(
                ("hash-object", "--no-filters", "-w", "--stdin"),
                input_data=mutation.content,
            ),
            "journal blob id",
        ).strip()
        context.git(
            ("update-index", "--add", "--cacheinfo", "100644", blob, mutation.path),
            index=index,
        )
        tree = _decode(context.git(("write-tree",), index=index), "commit tree id").strip()
        revision = _decode(
            context.git(
                ("commit-tree", tree, "-p", head),
                input_data=b"journal: record bounded run\n",
            ),
            "commit id",
        ).strip()
    finally:
        os.close(temporary_fd)
    return PreparedCommit(revision, blob)


@dataclass
class AppliedJournal:
    descriptor: int
    parent_descriptor: int
    parent_existed: bool
    content: bytes

    def close(self) -> None:
        for name in ("descriptor", "parent_descriptor"):
            descriptor = getattr(self, name)
            if descriptor >= 0:
                os.close(descriptor)
                setattr(self, name, -1)


def _journal_parent_exists(context: GitContext) -> bool:
    try:
        descriptor = open_child_directory(context.repo_fd, "journal")
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise PolicyError(f"journal parent is not a safe directory: {exc}") from exc
    os.close(descriptor)
    return True


def _apply_journal(context: GitContext, mutation: ValidatedMutation) -> AppliedJournal:
    parent_existed = _journal_parent_exists(context)
    atomic_write(context.repo_fd, mutation.parts, mutation.content, create_parents=True)
    descriptor = -1
    parent_descriptor = -1
    try:
        descriptor = open_regular(context.repo_fd, mutation.parts)
        metadata = os.fstat(descriptor)
        content = read_regular(
            descriptor,
            expected_size=metadata.st_size,
            max_bytes=DEFAULT_MAX_BYTES,
        )
        if content != mutation.content:
            raise PolicyError("applied journal content changed")
        parent_descriptor = open_child_directory(context.repo_fd, "journal")
        return AppliedJournal(descriptor, parent_descriptor, parent_existed, content)
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        if parent_descriptor >= 0:
            os.close(parent_descriptor)
        raise


def _journal_is_owned(context: GitContext, mutation: ValidatedMutation, lease: AppliedJournal) -> bool:
    try:
        current = open_regular(context.repo_fd, mutation.parts)
    except FileNotFoundError:
        return False
    try:
        expected = os.fstat(lease.descriptor)
        actual = os.fstat(current)
        if (expected.st_dev, expected.st_ino) != (actual.st_dev, actual.st_ino):
            return False
        os.lseek(current, 0, os.SEEK_SET)
        return (
            read_regular(current, expected_size=actual.st_size, max_bytes=DEFAULT_MAX_BYTES)
            == lease.content
        )
    finally:
        os.close(current)


def _rollback_journal(
    context: GitContext, mutation: ValidatedMutation, lease: AppliedJournal
) -> None:
    if not _journal_is_owned(context, mutation, lease):
        raise PolicyError("journal path was replaced; replacement preserved")
    parent_fd, name = open_parent(context.repo_fd, mutation.parts)
    try:
        current_parent = os.fstat(parent_fd)
        owned_parent = os.fstat(lease.parent_descriptor)
        if (current_parent.st_dev, current_parent.st_ino) != (
            owned_parent.st_dev,
            owned_parent.st_ino,
        ):
            raise PolicyError("journal parent was replaced; replacement preserved")
        os.unlink(name, dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)
    if not lease.parent_existed:
        current_parent = os.stat("journal", dir_fd=context.repo_fd, follow_symlinks=False)
        owned_parent = os.fstat(lease.parent_descriptor)
        if not stat.S_ISDIR(current_parent.st_mode) or (
            current_parent.st_dev,
            current_parent.st_ino,
        ) != (owned_parent.st_dev, owned_parent.st_ino):
            raise PolicyError("journal parent was replaced; replacement preserved")
        try:
            os.rmdir("journal", dir_fd=context.repo_fd)
        except OSError as exc:
            if exc.errno not in {errno.ENOTEMPTY, errno.EEXIST}:
                raise


def _expected_untracked(mutation: ValidatedMutation) -> bytes:
    return b"?? " + mutation.path.encode("utf-8") + b"\0"


def _verify_untracked(
    context: GitContext, pinned: PinnedState, mutation: ValidatedMutation
) -> None:
    if _branch(context) != pinned.branch or _head(context) != pinned.head:
        raise PolicyError("repository HEAD moved during supervisor run")
    if _read_index(context) != (pinned.index, pinned.index_mode):
        raise PolicyError("repository index moved during supervisor run")
    if _status(context) != _expected_untracked(mutation):
        raise PolicyError("repository state moved during supervisor run")
    if not _tracked_worktree_is_clean(context, pinned.entries):
        raise PolicyError("tracked worktree moved during supervisor run")


def _entry_for(records: tuple[IndexRecord, ...], path: bytes) -> IndexRecord | None:
    return next((record for record in records if record.path == path), None)


def _verify_staged(
    context: GitContext,
    pinned: PinnedState,
    mutation: ValidatedMutation,
    prepared: PreparedCommit,
    lease: AppliedJournal,
) -> None:
    if _branch(context) != pinned.branch or _head(context) != pinned.head:
        raise PolicyError("repository HEAD moved during supervisor run")
    _, mode = _read_index(context)
    if mode != pinned.index_mode:
        raise PolicyError("repository index metadata moved during supervisor run")
    current = _index_records(context)
    path = mutation.path.encode("utf-8")
    expected_entry = b"100644 " + prepared.blob.encode("ascii") + b" 0\t" + path
    journal = _entry_for(current, path)
    if journal is None or journal.stage != expected_entry:
        raise PolicyError("journal index entry moved during supervisor run")
    unrelated = tuple(record for record in current if record.path != path)
    if unrelated != pinned.index_records:
        raise PolicyError("unrelated index state moved during supervisor run")
    if _status(context) != b"A  " + path + b"\0":
        raise PolicyError("repository state moved during supervisor run")
    if not _tracked_worktree_is_clean(context, pinned.entries):
        raise PolicyError("tracked worktree moved during supervisor run")
    if not _journal_is_owned(context, mutation, lease):
        raise PolicyError("journal path was replaced during supervisor run")


def _write_all(descriptor: int, content: bytes) -> None:
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError(errno.EIO, "short index write")
        view = view[written:]


def _index_path_is(context: GitContext, name: str, metadata: os.stat_result) -> bool:
    try:
        current = os.stat(name, dir_fd=context.git_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return stat.S_ISREG(current.st_mode) and (current.st_dev, current.st_ino) == (
        metadata.st_dev,
        metadata.st_ino,
    )


def _read_index_path(path: Path) -> tuple[bytes, int]:
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PolicyError("temporary index is not a regular file")
        return (
            read_regular(
                descriptor,
                expected_size=metadata.st_size,
                max_bytes=MAX_INDEX_BYTES,
            ),
            stat.S_IMODE(metadata.st_mode),
        )
    finally:
        os.close(descriptor)


def _seed_index(path: Path, content: bytes, mode: int) -> None:
    descriptor = os.open(
        path,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
        mode,
    )
    try:
        _write_all(descriptor, content)
        os.fchmod(descriptor, mode)
    finally:
        os.close(descriptor)


def _install_index_lock(
    context: GitContext,
    lock_fd: int,
    lock_metadata: os.stat_result,
    content: bytes,
    mode: int,
) -> None:
    os.ftruncate(lock_fd, 0)
    os.lseek(lock_fd, 0, os.SEEK_SET)
    _write_all(lock_fd, content)
    os.fchmod(lock_fd, mode)
    os.fsync(lock_fd)
    try:
        os.rename(
            "index.lock",
            "index",
            src_dir_fd=context.git_fd,
            dst_dir_fd=context.git_fd,
        )
    finally:
        if _index_path_is(context, "index", lock_metadata):
            os.fsync(context.git_fd)


def _remove_owned_index_entry(
    context: GitContext,
    pinned: PinnedState,
    mutation: ValidatedMutation,
    prepared: PreparedCommit,
) -> None:
    path = mutation.path.encode("utf-8")
    expected = b"100644 " + prepared.blob.encode("ascii") + b" 0\t" + path
    lock_fd = -1
    lock_metadata: os.stat_result | None = None
    try:
        try:
            lock_fd = os.open(
                "index.lock",
                os.O_RDWR
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0),
                0o600,
                dir_fd=context.git_fd,
            )
        except FileExistsError as exc:
            raise PolicyError(
                "repository index lock is held; existing lock preserved"
            ) from exc
        lock_metadata = os.fstat(lock_fd)

        # This is the first ownership decision: the canonical index is read only
        # after the canonical Git lock is held.
        current, current_mode = _read_index(context)
        with tempfile.TemporaryDirectory(prefix="commitment-index-") as temporary_value:
            temporary = Path(temporary_value)
            current_copy = temporary / "current"
            _seed_index(current_copy, current, current_mode)
            raw = context.git(
                ("ls-files", "--stage", "-z", "--", mutation.path),
                index=current_copy,
            )
            entries = tuple(item for item in raw.split(b"\0") if item)
            if not entries:
                return
            if entries != (expected,):
                raise PolicyError(
                    "journal index entry was replaced; replacement preserved"
                )

            zero = b"0" * len(prepared.blob)
            context.git(
                ("update-index", "-z", "--index-info"),
                index=current_copy,
                input_data=b"0 " + zero + b"\t" + path + b"\0",
            )
            corrected, _ = _read_index_path(current_copy)
            restore_exact = (
                _index_records(context, index=current_copy) == pinned.index_records
            )
            corrected_mode = pinned.index_mode if restore_exact else current_mode
            if restore_exact:
                corrected = pinned.index

            _install_index_lock(
                context,
                lock_fd,
                lock_metadata,
                corrected,
                corrected_mode,
            )
    finally:
        if lock_fd >= 0 and lock_metadata is None:
            try:
                lock_metadata = os.fstat(lock_fd)
            except OSError:
                pass
        if lock_fd >= 0:
            os.close(lock_fd)
        if lock_metadata is not None and _index_path_is(
            context, "index.lock", lock_metadata
        ):
            os.unlink("index.lock", dir_fd=context.git_fd)


def _rollback_error(original: BaseException, failures: list[str]) -> BaseException:
    if isinstance(original, (KeyboardInterrupt, SystemExit)):
        if failures and hasattr(original, "add_note"):
            original.add_note("rollback interference: " + "; ".join(failures))
        return original
    if not failures and isinstance(original, CommitmentError):
        return original
    message = str(original)
    if failures:
        message += f"; rollback interference: {'; '.join(failures)}"
    if isinstance(original, CommitmentError):
        return type(original)(message)
    return ExecutionError(message)


def apply_and_commit(
    context: GitContext,
    pinned: PinnedState,
    mutation: ValidatedMutation,
    prepared: PreparedCommit,
) -> None:
    lease: AppliedJournal | None = None
    index_update_attempted = False
    cas_started = False
    try:
        verify_state(context, pinned)
        lease = _apply_journal(context, mutation)
        _verify_untracked(context, pinned, mutation)
        cas_started = True
        index_update_attempted = True
        context.git(
            (
                "update-index",
                "--add",
                "--cacheinfo",
                "100644",
                prepared.blob,
                mutation.path,
            )
        )
        _verify_staged(context, pinned, mutation, prepared, lease)
        context.git(
            (
                "update-ref",
                "--create-reflog",
                "-m",
                "commitment journal",
                pinned.branch,
                prepared.revision,
                pinned.head,
            )
        )
    except BaseException as original:
        failures: list[str] = []
        if cas_started:
            try:
                published = _decode(
                    context.git(("rev-parse", "--verify", f"{pinned.branch}^{{commit}}")),
                    "published branch",
                ).strip()
            except BaseException as exc:
                published = ""
                failures.append(f"cannot determine CAS outcome: {exc}")
            if published == prepared.revision or not published:
                error = _rollback_error(original, failures)
                raise error from original
        if index_update_attempted:
            try:
                _remove_owned_index_entry(context, pinned, mutation, prepared)
            except BaseException as exc:
                failures.append(f"preserve index: {exc}")
        if lease is not None:
            try:
                _rollback_journal(context, mutation, lease)
            except BaseException as exc:
                failures.append(f"preserve journal: {exc}")
        error = _rollback_error(original, failures)
        raise error from original
    finally:
        if lease is not None:
            lease.close()


def apply_only(context: GitContext, pinned: PinnedState, mutation: ValidatedMutation) -> None:
    lease: AppliedJournal | None = None
    try:
        verify_state(context, pinned)
        lease = _apply_journal(context, mutation)
        _verify_untracked(context, pinned, mutation)
    except BaseException as original:
        failures: list[str] = []
        if lease is not None:
            try:
                _rollback_journal(context, mutation, lease)
            except BaseException as exc:
                failures.append(f"preserve journal: {exc}")
        error = _rollback_error(original, failures)
        raise error from original
    finally:
        if lease is not None:
            lease.close()


@dataclass(frozen=True)
class SupervisorResult:
    path: str
    applied: bool
    committed: bool


class Supervisor:
    def __init__(
        self,
        repo: Path,
        executor: CommandExecutor | None = None,
        ollama_call: Callable[[bytes, str, float], bytes] = request_ollama,
    ) -> None:
        self.repo = repo
        self.executor = executor or CommandExecutor()
        self.ollama_call = ollama_call

    def run(
        self,
        *,
        apply: bool = False,
        commit: bool = False,
        image: str = DEFAULT_IMAGE,
        model: str = DEFAULT_MODEL,
        ollama_url: str = DEFAULT_OLLAMA_URL,
        timeout: float = DEFAULT_CONTAINER_TIMEOUT,
    ) -> SupervisorResult:
        if commit and not apply:
            raise PolicyError("--commit requires --apply")
        validate_timeout(timeout, label="container timeout")
        upstream = validate_ollama_url(ollama_url)
        with tempfile.TemporaryDirectory(prefix="commitment-") as temporary_value:
            temporary = Path(temporary_value)
            snapshot = temporary / "repo"
            hooks = temporary / "hooks"
            for directory in (snapshot, hooks):
                directory.mkdir(mode=0o700)
            with GitContext(self.repo, self.executor, hooks) as context:
                pinned = pin_state(context)
                verify_state(context, pinned)
                if apply and (
                    pinned.status
                    or not pinned.staged_index_clean
                    or not pinned.tracked_worktree_clean
                ):
                    raise PolicyError(
                        "apply target has staged, tracked worktree, or non-ignored "
                        "untracked changes"
                    )
                snapshot_fd = open_directory(snapshot)
                try:
                    create_snapshot(context, snapshot_fd, pinned.entries)
                    os.fchmod(snapshot_fd, 0o555)
                    prepare_name = f"commitment-prepare-{uuid.uuid4().hex}"
                    prepare_command = build_container_command(
                        stage="prepare",
                        container_name=prepare_name,
                        image=image,
                        snapshot=snapshot,
                        model=model,
                    )
                    try:
                        prepared = run_container(
                            self.executor,
                            prepare_command,
                            cwd=context.repo_path,
                            timeout=min(timeout, MAX_PREPARE_SECONDS),
                            name=prepare_name,
                            max_stdout=MAX_REQUEST_BYTES,
                        )
                    finally:
                        os.fchmod(snapshot_fd, 0o700)
                    request = require_success(prepared, prepare_command)
                    validate_request(request, model)
                    response = self.ollama_call(request, upstream, min(timeout, 120.0))
                    if len(response) > MAX_RESPONSE_BYTES:
                        raise PolicyError(
                            f"Ollama response exceeds {MAX_RESPONSE_BYTES} bytes"
                        )
                    render_name = f"commitment-render-{uuid.uuid4().hex}"
                    render_command = build_container_command(
                        stage="render",
                        container_name=render_name,
                        image=image,
                    )
                    rendered = run_container(
                        self.executor,
                        render_command,
                        cwd=context.repo_path,
                        timeout=min(timeout, MAX_RENDER_SECONDS),
                        name=render_name,
                        input_data=response,
                        max_stdout=MAX_RENDER_OUTPUT,
                    )
                    report = JournalResult.from_json(
                        _decode(
                            require_success(rendered, render_command),
                            "render container result",
                        ).strip()
                    )
                    mutation = validate_rendered(report)
                    reject_ignored_journal_conflicts(context, mutation)
                    commit_data = (
                        prepare_commit(context, temporary, mutation, pinned.head)
                        if commit
                        else None
                    )
                    if commit_data is not None:
                        apply_and_commit(context, pinned, mutation, commit_data)
                    elif apply:
                        apply_only(context, pinned, mutation)
                    return SupervisorResult(mutation.path, apply, commit)
                finally:
                    os.close(snapshot_fd)


def _timeout_argument(raw: str) -> float:
    try:
        return validate_timeout(float(raw), label="container timeout")
    except (ValueError, PolicyError) as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="commitment")
    result.add_argument("--repo", type=Path, default=Path.cwd())
    result.add_argument("--apply", action="store_true")
    result.add_argument("--commit", action="store_true")
    result.add_argument("--image", default=os.environ.get("COMMITMENT_IMAGE", DEFAULT_IMAGE))
    result.add_argument("--model", default=os.environ.get("COMMITMENT_MODEL", DEFAULT_MODEL))
    result.add_argument(
        "--ollama-url", default=os.environ.get("COMMITMENT_OLLAMA_URL", DEFAULT_OLLAMA_URL)
    )
    result.add_argument(
        "--timeout",
        type=_timeout_argument,
        default=os.environ.get("COMMITMENT_CONTAINER_TIMEOUT", str(DEFAULT_CONTAINER_TIMEOUT)),
    )
    return result


def main(argv: Iterable[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        outcome = Supervisor(args.repo).run(
            apply=args.apply,
            commit=args.commit,
            image=args.image,
            model=args.model,
            ollama_url=args.ollama_url,
            timeout=args.timeout,
        )
    except CommitmentError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if outcome.committed:
        print("local commit created.")
    elif outcome.applied:
        print("change applied.")
    else:
        print("dry run done.")
        print("working tree unchanged.")
    print(f"journal: {outcome.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
