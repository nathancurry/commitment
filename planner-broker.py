#!/usr/bin/env python3
"""Host-only CheaperInference planner broker with a text-only FIFO interface."""

import fcntl
import json
import os
import re
import resource
import select
import signal
import stat
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ENDPOINT = "https://api.cheaperinference.com/v1/chat/completions"
DEFAULT_MODEL = "glm-5.3"
DEFAULT_REASONING = "high"
DEFAULT_MAX_TOKENS = 16384
REQUEST_LIMIT = 1024 * 1024
PACKET_LIMIT = REQUEST_LIMIT + 65536
RESPONSE_LIMIT = 4 * 1024 * 1024
HTTP_TIMEOUT = 600
SYSTEM_PROMPT = """You are a planning, prospecting, and reasoning consultant for Commitment, an
autonomous agent in pursuit of greater usefulness.

Commitment evaluates usefulness relative to:
- usefulness to its operator;
- usefulness to the world;
- its ability to become more useful.

Analyze the supplied objective, evidence, research, capabilities, current state,
design, or proposed next move.

When asked to prospect, identify promising problems, opportunities, experiments,
capabilities, information sources, data streams, communication channels,
interfaces, resources, or other directions worth investigating.

Consider ways Commitment could increase its ability to observe, understand,
communicate, publish, receive input, collaborate, build, test, distribute, and
solve useful problems.

Attention, trust, resources, access, capabilities, and opportunities can provide
leverage toward greater usefulness; treat them as means rather than ends.

Challenge material assumptions, identify important missing information or
uncertainty, and recommend concrete next moves.

Further research, design, prototyping, implementation, testing, acquiring a
capability, asking the operator for something, abandoning a direction, or
changing direction may all be appropriate.

Do not claim to have performed research, tests, or actions that are not present
in the supplied context.

Your response is advice. Commitment retains responsibility for deciding and
acting."""


class PlannerError(Exception):
    """A fixed, credential-safe diagnostic suitable for the creative side."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def outside_mounts(path, mounts):
    resolved = Path(path).resolve()
    for mount in mounts:
        root = Path(mount).resolve()
        if resolved == root or root in resolved.parents:
            raise PlannerError("planner key must stay outside creative mounts")


def load_key(path, mounts=()):
    outside_mounts(path, mounts)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as handle:
            info = os.fstat(handle.fileno())
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) & 0o077
                or info.st_nlink != 1
            ):
                raise PlannerError("planner key must be an owner-only regular file")
            raw = handle.read(8193)
        if len(raw) > 8192:
            raise PlannerError("planner key file is invalid")
        value = raw.decode("ascii").rstrip("\r\n")
        if not value or any(character.isspace() for character in value):
            raise PlannerError("planner key file is empty or invalid")
        return value
    except PlannerError:
        raise
    except (OSError, UnicodeError):
        raise PlannerError(
            "planner key file is missing, unreadable, or invalid"
        ) from None


def validate_settings(model, reasoning, max_tokens):
    if (
        not isinstance(model, str)
        or not model
        or len(model) > 200
        or any(character.isspace() for character in model)
    ):
        raise PlannerError("planner model configuration is invalid")
    if reasoning not in {"low", "medium", "high", "xhigh", "max"}:
        raise PlannerError("planner reasoning configuration is invalid")
    if type(max_tokens) is not int or not 1 <= max_tokens <= 1_000_000:
        raise PlannerError("planner token configuration is invalid")


class Backend:
    def __init__(
        self,
        key_file,
        model=DEFAULT_MODEL,
        reasoning=DEFAULT_REASONING,
        max_tokens=DEFAULT_MAX_TOKENS,
        mounts=(),
        opener=None,
    ):
        validate_settings(model, reasoning, max_tokens)
        self.key = load_key(key_file, mounts)
        self.model = model
        self.reasoning = reasoning
        self.max_tokens = max_tokens
        if opener is None:
            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({}), NoRedirect()
            )
            opener.addheaders = []
        self.opener = opener

    def payload(self, text):
        return {
            "model": self.model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": text},
            ],
            "reasoning": {"effort": self.reasoning, "exclude": True},
            "max_completion_tokens": self.max_tokens,
        }

    def plan(self, text):
        if not isinstance(text, str) or not text.strip():
            raise PlannerError("planner input is empty")
        if len(text.encode("utf-8")) > REQUEST_LIMIT:
            raise PlannerError("planner input is too large")
        body = json.dumps(self.payload(text), ensure_ascii=False).encode("utf-8")
        # Even if creative input somehow learns the key, never send it as model input.
        if self.key.encode("ascii") in body:
            raise PlannerError("planner input rejected")
        request = urllib.request.Request(
            ENDPOINT,
            data=body,
            headers={
                "Authorization": "Bearer " + self.key,
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            response = self.opener.open(request, timeout=HTTP_TIMEOUT)
            try:
                status = response.getcode()
                data = response.read(RESPONSE_LIMIT + 1)
            finally:
                response.close()
        except urllib.error.HTTPError as exc:
            status = exc.code
            exc.close()
            if status in (401, 403):
                raise PlannerError(
                    f"planner authentication failed (HTTP {status})"
                ) from None
            if status == 429:
                raise PlannerError("planner rate limited (HTTP 429)") from None
            if 500 <= status <= 599:
                raise PlannerError(
                    f"planner service unavailable (HTTP {status})"
                ) from None
            raise PlannerError(f"planner request failed (HTTP {status})") from None
        except TimeoutError:
            raise PlannerError("planner request timed out") from None
        except urllib.error.URLError as exc:
            if isinstance(exc.reason, TimeoutError):
                raise PlannerError("planner request timed out") from None
            raise PlannerError("planner network unavailable") from None
        except OSError:
            raise PlannerError("planner network unavailable") from None
        except Exception:  # noqa: BLE001 - never disclose transport internals.
            raise PlannerError("planner request failed") from None
        if status != 200:
            raise PlannerError(f"planner request failed (HTTP {status})")
        if len(data) > RESPONSE_LIMIT:
            raise PlannerError("planner response is too large")
        try:
            document = json.loads(data)
            choices = document["choices"]
            content = choices[0]["message"]["content"]
            if not isinstance(choices, list) or not isinstance(content, str):
                raise TypeError
        except (UnicodeError, json.JSONDecodeError, KeyError, IndexError, TypeError):
            raise PlannerError("planner returned an invalid response") from None
        if not content.strip():
            raise PlannerError("planner returned an empty response")
        if self.key in content:
            raise PlannerError("planner returned an unsafe response")
        return content


def reply(fd, message):
    data = json.dumps(message, ensure_ascii=False).encode("utf-8") + b"\n"
    deadline = time.monotonic() + 5
    while data and time.monotonic() < deadline:
        if select.select([], [fd], [], 0.1)[1]:
            try:
                data = data[os.write(fd, data) :]
            except BlockingIOError:
                pass


def cleanup_stale(root):
    try:
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return
    try:
        info = os.fstat(root_fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise PlannerError("unsafe planner runtime root")
        lock_fd = os.open(
            "run.lock",
            os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
            0o600,
            dir_fd=root_fd,
        )
        try:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            os.fchmod(lock_fd, 0o600)
            for name in os.listdir(root_fd):
                if not re.fullmatch(r"planner-session\.[a-zA-Z0-9_-]+", name):
                    continue
                directory_fd = None
                try:
                    directory_fd = os.open(
                        name,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=root_fd,
                    )
                    info = os.fstat(directory_fd)
                    if (
                        info.st_uid != os.getuid()
                        or stat.S_IMODE(info.st_mode) != 0o700
                    ):
                        continue
                    entries = os.listdir(directory_fd)
                    allowed = {
                        "request": stat.S_ISFIFO,
                        "response": stat.S_ISFIFO,
                        "lock": stat.S_ISREG,
                    }
                    if any(
                        entry not in allowed
                        or not allowed[entry](
                            os.stat(
                                entry, dir_fd=directory_fd, follow_symlinks=False
                            ).st_mode
                        )
                        for entry in entries
                    ):
                        continue
                    for entry in entries:
                        os.unlink(entry, dir_fd=directory_fd)
                    os.rmdir(name, dir_fd=root_fd)
                except OSError:
                    continue
                finally:
                    if directory_fd is not None:
                        os.close(directory_fd)
        finally:
            os.close(lock_fd)
    finally:
        os.close(root_fd)


def serve(directory, backend, error, parent):
    paths = [directory / name for name in ("request", "response", "lock")]
    descriptors = []
    try:
        for path in paths[:2]:
            os.mkfifo(path, 0o600)
            descriptors.append(os.open(path, os.O_RDWR | os.O_NONBLOCK))
        paths[2].touch(mode=0o600, exist_ok=False)
        incoming, outgoing = descriptors
        buffer = bytearray()
        last_input = time.monotonic()
        while os.getppid() == parent:
            if not select.select([incoming], [], [], 0.5)[0]:
                if buffer and time.monotonic() - last_input > 2:
                    buffer.clear()
                    reply(
                        outgoing,
                        {"id": None, "ok": False, "error": "incomplete request"},
                    )
                continue
            buffer.extend(os.read(incoming, 65536))
            last_input = time.monotonic()
            if len(buffer) > PACKET_LIMIT:
                buffer.clear()
                reply(outgoing, {"id": None, "ok": False, "error": "request too large"})
                continue
            while b"\n" in buffer:
                line, _, remaining = buffer.partition(b"\n")
                buffer = bytearray(remaining)
                request_id = None
                try:
                    packet = json.loads(line)
                    if (
                        not isinstance(packet, dict)
                        or set(packet) != {"id", "text"}
                        or not isinstance(packet["id"], str)
                        or not re.fullmatch(r"[0-9a-f]{32}", packet["id"])
                        or not isinstance(packet["text"], str)
                    ):
                        raise PlannerError("invalid request")
                    request_id = packet["id"]
                    if error:
                        raise PlannerError(error)
                    text = backend.plan(packet["text"])
                    result = {"id": request_id, "ok": True, "text": text}
                except PlannerError as exc:
                    result = {"id": request_id, "ok": False, "error": str(exc)}
                except Exception:  # noqa: BLE001 - IPC errors must remain fixed and safe.
                    result = {
                        "id": request_id,
                        "ok": False,
                        "error": "planner backend failed",
                    }
                reply(outgoing, result)
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
        for path in paths:
            path.unlink(missing_ok=True)


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.umask(0o077)
    if len(sys.argv) >= 4 and sys.argv[1] == "--check-paths":
        outside_mounts(sys.argv[2], sys.argv[3:])
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--cleanup":
        cleanup_stale(sys.argv[2])
        return
    if len(sys.argv) < 3:
        raise PlannerError(
            "usage: planner-broker.py SESSION_DIRECTORY PARENT_PID [CREATIVE_MOUNT ...]"
        )
    directory = Path(sys.argv[1])
    parent = int(sys.argv[2])
    info = directory.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise PlannerError("planner IPC directory must be private")
    mounts = sys.argv[3:]
    outside_mounts(directory, mounts)
    with open(os.devnull, "w") as sink:
        os.dup2(sink.fileno(), 1)
        os.dup2(sink.fileno(), 2)
    backend, error = None, None
    try:
        backend = Backend(
            os.environ.get("CHEAPERINFERENCE_API_KEY_FILE", ""),
            os.environ.get("PLANNER_MODEL", DEFAULT_MODEL),
            os.environ.get("PLANNER_REASONING", DEFAULT_REASONING),
            int(os.environ.get("PLANNER_MAX_TOKENS", DEFAULT_MAX_TOKENS)),
            mounts,
        )
    except (PlannerError, ValueError) as exc:
        error = (
            str(exc)
            if isinstance(exc, PlannerError)
            else "planner configuration is invalid"
        )
    serve(directory, backend, error, parent)


def stop(_signum, _frame):
    raise SystemExit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        main()
    except Exception:  # noqa: BLE001 - startup diagnostics must not expose credentials.
        print("commitment-plan: broker startup failed", file=sys.stderr)
        sys.exit(1)
