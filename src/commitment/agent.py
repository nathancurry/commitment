from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import re
import stat
import sys
from collections.abc import Iterable
from datetime import date
from pathlib import Path, PurePosixPath

import commitment

from commitment.ollama import DEFAULT_MODEL, MAX_RESPONSE_BYTES, build_request, parse_response
from commitment.result import (
    CommitmentError,
    JournalResult,
    ModelError,
    Mutation,
    PolicyError,
)
from commitment.safeio import open_directory, read_regular

DEFAULT_MAX_BYTES = 16 * 1024
MAX_TRACKED_ENTRIES = 4096
MAX_INSPECTED_FILE_BYTES = 1024 * 1024
MAX_INSPECTED_TOTAL_BYTES = 8 * 1024 * 1024
MAX_MODEL_INPUT_BYTES = 512 * 1024
MAX_REPOSITORY_TEXT_BYTES = 500 * 1024
JOURNAL_PATH = re.compile(
    r"journal/[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(?:-[a-z0-9]+)*\.md"
)
CONTAINER_UID = 10001
CONTAINER_GID = 10001


def inspect_repository(
    root: Path,
    *,
    max_entries: int = MAX_TRACKED_ENTRIES,
    max_file_bytes: int = MAX_INSPECTED_FILE_BYTES,
    max_total_bytes: int = MAX_INSPECTED_TOTAL_BYTES,
    max_input_bytes: int = MAX_REPOSITORY_TEXT_BYTES,
) -> str:
    sections: list[str] = []
    entry_count = 0
    inspected_bytes = 0
    input_bytes = 0

    def walk(directory_fd: int, prefix: tuple[str, ...]) -> None:
        nonlocal entry_count, inspected_bytes, input_bytes
        names: list[str] = []
        with os.scandir(directory_fd) as entries:
            for entry in entries:
                entry_count += 1
                if entry_count > max_entries:
                    raise PolicyError(f"repository snapshot exceeds {max_entries} entries")
                names.append(entry.name)
        for name in sorted(names):
            try:
                name.encode("utf-8")
            except UnicodeEncodeError as exc:
                raise PolicyError("repository snapshot contains non-UTF-8 path") from exc
            if name in {".", ".."} or "/" in name:
                raise PolicyError("repository snapshot contains unsafe path")
            try:
                descriptor = os.open(
                    name,
                    os.O_RDONLY
                    | os.O_NONBLOCK
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=directory_fd,
                )
            except OSError as exc:
                if exc.errno == errno.ELOOP:
                    relative = "/".join((*prefix, name))
                    raise PolicyError(
                        f"repository snapshot contains symlink: {relative}"
                    ) from exc
                raise PolicyError(
                    f"cannot inspect repository snapshot entry: {name}: {exc}"
                ) from exc
            try:
                metadata = os.fstat(descriptor)
                relative = "/".join((*prefix, name))
                if stat.S_ISDIR(metadata.st_mode):
                    walk(descriptor, (*prefix, name))
                    continue
                if not stat.S_ISREG(metadata.st_mode):
                    raise PolicyError(
                        f"repository snapshot contains non-regular file: {relative}"
                    )
                if metadata.st_size > max_file_bytes:
                    raise PolicyError(
                        f"repository file exceeds {max_file_bytes} bytes: {relative}"
                    )
                if inspected_bytes + metadata.st_size > max_total_bytes:
                    raise PolicyError(
                        f"repository snapshot exceeds {max_total_bytes} inspected bytes"
                    )
                inspected_bytes += metadata.st_size
                header = f"\n--- {relative} ---\n".encode()
                if input_bytes + len(header) + metadata.st_size > max_input_bytes:
                    continue
                content = read_regular(
                    descriptor,
                    expected_size=metadata.st_size,
                    max_bytes=max_file_bytes,
                )
                try:
                    text = content.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                sections.append(header.decode() + text)
                input_bytes += len(header) + len(content)
            finally:
                os.close(descriptor)

    try:
        root_fd = open_directory(root)
    except OSError as exc:
        raise PolicyError(f"cannot open repository snapshot safely: {exc}") from exc
    try:
        walk(root_fd, ())
    finally:
        os.close(root_fd)
    if not sections:
        raise PolicyError("repository snapshot contains no readable tracked files")
    return "".join(sections)


def build_prompt(repo_text: str, today: date) -> str:
    return f"""You are commitment. Inspect this credential-free repository snapshot.
Return exactly one JSON object matching the supplied schema. Do not return prose outside JSON.
Create one new Markdown journal entry and no other mutation.
Path must be journal/{today.isoformat()}-<lowercase-hyphen-slug>.md.
Content must follow VOICE.md: lowercase prose, short concrete sentences, one thought per sentence.
Refer to project as commitment, always lowercase. Preserve exact code identifiers when needed.
State only facts supported by repository files. Do not claim strict model determinism.
Keep content useful and under {DEFAULT_MAX_BYTES} UTF-8 bytes.

Repository files:{repo_text}
"""


def parse_mutation(raw: str, *, max_bytes: int = DEFAULT_MAX_BYTES) -> Mutation:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ModelError("model returned malformed mutation JSON") from exc
    if not isinstance(value, dict) or set(value) != {"path", "content"}:
        raise ModelError("model mutation must contain only path and content")
    path = value["path"]
    content = value["content"]
    if not isinstance(path, str) or not isinstance(content, str):
        raise ModelError("model mutation path and content must be strings")
    if not JOURNAL_PATH.fullmatch(path):
        raise PolicyError(f"model returned unexpected path: {path}")
    pure_path = PurePosixPath(path)
    if pure_path.is_absolute() or ".." in pure_path.parts:
        raise PolicyError(f"model returned unsafe path: {path}")
    if not content.strip() or not content.endswith("\n"):
        raise ModelError("model journal content must be nonempty and end with newline")
    mutation = Mutation(path=path, content=content)
    if mutation.size > max_bytes:
        raise PolicyError(f"model journal exceeds {max_bytes} bytes")
    return mutation


def report_container_identity(stage: str) -> None:
    uid = os.getuid()
    gid = os.getgid()
    if (uid, gid) != (CONTAINER_UID, CONTAINER_GID):
        raise PolicyError(
            f"container identity must be {CONTAINER_UID}:{CONTAINER_GID}, got {uid}:{gid}"
        )
    try:
        with open("/proc/self/uid_map", "r", encoding="ascii") as mapping:
            uid_map = mapping.read(4097)
    except OSError as exc:
        raise PolicyError(f"cannot inspect container UID map: {exc}") from exc
    if not uid_map or len(uid_map) > 4096:
        raise PolicyError("container UID map is missing or exceeds 4096 bytes")
    package_file = Path(commitment.__file__ or "").resolve()
    if package_file == Path("/repo") or Path("/repo") in package_file.parents:
        raise PolicyError("commitment package resolved beneath repository mount")
    print(
        "COMMITMENT_IDENTITY="
        + json.dumps(
            {
                "commitment_file": os.fspath(package_file),
                "gid": gid,
                "stage": stage,
                "uid": uid,
                "uid_map": uid_map,
            },
            separators=(",", ":"),
            sort_keys=True,
        ),
        file=sys.stderr,
    )


def prepare_request(root: Path, model: str, *, today: date | None = None) -> bytes:
    repo_text = inspect_repository(root)
    prompt = build_prompt(repo_text, today or date.today())
    if len(prompt.encode("utf-8")) > MAX_MODEL_INPUT_BYTES:
        raise PolicyError(f"model input exceeds {MAX_MODEL_INPUT_BYTES} bytes")
    return build_request(prompt, model)


def render_response(raw: bytes) -> JournalResult:
    mutation = parse_mutation(parse_response(raw))
    content = mutation.content.encode("utf-8")
    return JournalResult(
        path=mutation.path,
        content=mutation.content,
        size=len(content),
        sha256=hashlib.sha256(content).hexdigest(),
    )


def _read_stdin(max_bytes: int) -> bytes:
    raw = sys.stdin.buffer.read(max_bytes + 1)
    if len(raw) > max_bytes:
        raise PolicyError(f"render input exceeds {max_bytes} bytes")
    return raw


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="commitment-agent")
    commands = result.add_subparsers(dest="stage", required=True)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--workspace", type=Path, default=Path("/repo"))
    prepare.add_argument("--model", default=os.environ.get("COMMITMENT_MODEL", DEFAULT_MODEL))
    commands.add_parser("render")
    return result


def main(argv: Iterable[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        report_container_identity(args.stage)
        if args.stage == "prepare":
            sys.stdout.buffer.write(prepare_request(args.workspace, args.model))
        else:
            print(render_response(_read_stdin(MAX_RESPONSE_BYTES)).to_json())
    except CommitmentError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
