#!/usr/bin/env python3
"""Host-only, per-session bridge to one Commitment Secrets Manager project."""

import json
import fcntl
import os
from pathlib import Path
import re
import resource
import secrets
import signal
import select
import stat
import time
import sys
import uuid


LIMIT = 4096
NAME = re.compile(r"[a-zA-Z][a-zA-Z0-9_.-]{0,79}\Z")
OPERATIONS = {"available", "list", "exists", "generate", "rotate", "delete"}


class Unavailable(Exception):
    """Only fixed, non-secret messages may cross the IPC boundary."""


def identifier(value):
    try:
        return str(value if isinstance(value, uuid.UUID) else uuid.UUID(value))
    except (ValueError, AttributeError, TypeError):
        raise Unavailable("invalid Bitwarden identifier") from None


def validate(request):
    if not isinstance(request, dict) or not isinstance(request.get("op"), str):
        raise Unavailable("invalid request")
    op = request["op"]
    if op not in OPERATIONS:
        raise Unavailable("unsupported secret operation")
    fields = {"op"} if op in {"available", "list"} else {"op", "name"}
    if op in {"generate", "rotate"} and "length" in request:
        fields.add("length")
        length = request["length"]
        if type(length) is not int or not 32 <= length <= 128:
            raise Unavailable("length must be an integer from 32 to 128")
    if set(request) != fields:
        raise Unavailable("invalid request fields")
    if "name" in fields and (
        not isinstance(request["name"], str) or not NAME.fullmatch(request["name"])
    ):
        raise Unavailable("invalid secret name")
    return op


def outside_mounts(path, mounts):
    resolved = Path(path).resolve()
    for mount in mounts:
        root = Path(mount).resolve()
        if resolved == root or root in resolved.parents:
            raise Unavailable("secret runtime and token must be outside creative mounts")


def sdk_client():
    # Imported only in the trusted installed interpreter, never from agent paths.
    from bitwarden_sdk import BitwardenClient
    return BitwardenClient()


class Backend:
    def __init__(self, project, token_file, mounts=()):
        self.project = identifier(project)
        outside_mounts(token_file, mounts)
        try:
            fd = os.open(token_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "r", encoding="ascii") as handle:
                info = os.fstat(handle.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or stat.S_IMODE(info.st_mode) & 0o077 or info.st_nlink != 1):
                    raise Unavailable("machine token must be an owner-only regular file")
                token = handle.read(8193).strip()
            if not token or len(token) > 8192 or any(c.isspace() for c in token):
                raise Unavailable("machine token is empty or invalid")
        except (OSError, UnicodeError):
            raise Unavailable("machine token file is missing, unreadable, or invalid") from None
        try:
            self.client = sdk_client()
            # None explicitly disables the SDK's persistent authentication cache.
            authenticated = self.call(self.client.auth().login_access_token, token, None)
            if authenticated.authenticated is not True:
                raise Unavailable("Bitwarden SDK authentication failed")
            project_data = self.call(self.client.projects().get, self.project)
            if identifier(project_data.id) != self.project:
                raise Unavailable("SDK returned an unexpected project")
            self.organization = identifier(project_data.organization_id)
        except Unavailable:
            raise
        except Exception:
            raise Unavailable("Bitwarden SDK unavailable; reinstall trusted runtime") from None

    def call(self, operation, *args, **kwargs):
        try:
            response = operation(*args, **kwargs)
            if response.success is not True or response.data is None:
                raise ValueError
            return response.data
        except Exception:
            # SDK errors may include token, values, or credentialed proxy URLs.
            raise Unavailable("Bitwarden SDK operation failed; check host setup") from None

    def metadata(self, item):
        projects = getattr(item, "project_ids", None)
        if projects is None:
            projects = [getattr(item, "project_id", None)]
        if (not isinstance(projects, list) or len(projects) != 1
                or identifier(projects[0]) != self.project
                or identifier(getattr(item, "organization_id", None)) != self.organization):
            raise Unavailable("SDK returned an out-of-project or invalid secret")
        name = getattr(item, "key", None)
        if not isinstance(name, str) or not NAME.fullmatch(name):
            raise Unavailable("project contains an unsupported secret name")
        secret_id = identifier(getattr(item, "id", None))
        # Deliberate allowlist; never return notes, values, or raw backend objects.
        return {"name": name, "secret_ref": "bitwarden:" + secret_id}

    def listing(self):
        items = self.call(self.client.secrets().list, self.organization).data
        if not isinstance(items, list):
            raise Unavailable("SDK returned an invalid secret list")
        return [self.metadata(item) for item in items]

    def operate(self, request):
        op = validate(request)
        items = self.listing()
        if op == "available":
            return {"available": True}
        if op == "list":
            return {"secrets": items}
        name = request["name"]
        matches = [item for item in items if item["name"] == name]
        if len(matches) > 1:
            raise Unavailable("duplicate secret name; operator must resolve ambiguity")
        if op == "exists":
            return {"exists": bool(matches), **(matches[0] if matches else {})}
        if op == "generate":
            if matches:
                raise Unavailable("secret already exists; generate never overwrites")
        elif not matches:
            raise Unavailable("secret does not exist in the configured project")
        else:
            secret_id = matches[0]["secret_ref"].removeprefix("bitwarden:")
            current = self.call(self.client.secrets().get, secret_id)
            if self.metadata(current) != matches[0]:
                raise Unavailable("SDK returned an unexpected secret reference")
        if op == "delete":
            deleted = self.call(self.client.secrets().delete, [secret_id]).data
            if (not isinstance(deleted, list) or len(deleted) != 1
                    or identifier(deleted[0].id) != secret_id or deleted[0].error is not None):
                raise Unavailable("SDK did not confirm single-secret deletion")
            return {**matches[0], "deleted": True}
        # Alphanumeric passwords: at least 190 bits, entirely trusted-side.
        value = "".join(secrets.choice(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        ) for _ in range(request.get("length", 48)))
        if op == "generate":
            result = self.call(self.client.secrets().create, self.organization,
                               name, value, None, [self.project])
        else:
            result = self.call(self.client.secrets().update, self.organization,
                               secret_id, name, value, current.note, [self.project])
        metadata = self.metadata(result)
        if metadata["name"] != name or (op == "rotate" and metadata != matches[0]):
            raise Unavailable("SDK returned an unexpected secret reference")
        return metadata


def reply(fd, message):
    data = json.dumps(message).encode() + b"\n"
    deadline = time.monotonic() + 2
    while data and time.monotonic() < deadline:
        if select.select([], [fd], [], 0.1)[1]:
            try:
                data = data[os.write(fd, data):]
            except BlockingIOError:
                pass


def cleanup_stale(root):
    """Under the shared run lock, remove only recognized private, flat residue.

    The launcher and broker inherit the run lock throughout a session. Legacy
    bws homes are removed only when empty; unknown contents need operator review.
    dir_fd and O_NOFOLLOW keep traversal inside the verified dedicated root.
    """
    try:
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return
    try:
        info = os.fstat(root_fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise Unavailable("unsafe secret runtime root")
        lock_fd = os.open("run.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                          0o600, dir_fd=root_fd)
        try:
            info = os.fstat(lock_fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) & 0o022 or info.st_nlink != 1):
                raise Unavailable("unsafe runtime lock")
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return  # A live launcher, broker, or inherited session owns it.
            # Older launchers created this non-secret lock under the host umask
            # (often 0644). Tighten it only after excluding an active session.
            os.fchmod(lock_fd, 0o600)
            for name in os.listdir(root_fd):
                if not re.fullmatch(r"(?:secrets-session\.|bws-)[a-zA-Z0-9_-]+", name):
                    continue
                entry_fd = None
                try:
                    entry_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                       dir_fd=root_fd)
                    info = os.fstat(entry_fd)
                    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                        continue
                    entries = os.listdir(entry_fd)
                    allowed = {"request": stat.S_ISFIFO, "response": stat.S_ISFIFO,
                               "lock": stat.S_ISREG} if name.startswith("secrets-session.") else {}
                    valid = True
                    for entry in entries:
                        item = os.stat(entry, dir_fd=entry_fd, follow_symlinks=False)
                        if (entry not in allowed or not allowed[entry](item.st_mode)
                                or item.st_uid != os.getuid() or item.st_nlink != 1
                                or stat.S_IMODE(item.st_mode) != 0o600):
                            valid = False
                            break
                    if not valid:
                        continue
                    for entry in entries:
                        os.unlink(entry, dir_fd=entry_fd)
                    os.rmdir(name, dir_fd=root_fd)
                except OSError:
                    continue  # Missing, symlink, non-directory, or changed: preserve.
                finally:
                    if entry_fd is not None:
                        os.close(entry_fd)
        finally:
            os.close(lock_fd)
    finally:
        os.close(root_fd)


def serve(directory, backend, error, parent):
    # FIFOs avoid SELinux unix_stream_socket/connectto permission on a host
    # process; no container label, namespace, or privilege relaxation is needed.
    # All creative processes share one authority. The client lock serializes
    # normal callers; malicious callers can deny service, not retrieve values.
    paths = [directory / name for name in ("request", "response", "lock")]
    descriptors = []
    try:
        for path in paths[:2]:
            os.mkfifo(path, 0o600)
            descriptors.append(os.open(path, os.O_RDWR | os.O_NONBLOCK))
        paths[2].touch(mode=0o600, exist_ok=False)  # Ready only after both pipes.
        incoming, outgoing = descriptors
        buffer = bytearray()
        last_input = time.monotonic()
        while os.getppid() == parent:
            if not select.select([incoming], [], [], 0.5)[0]:
                if buffer and time.monotonic() - last_input > 2:
                    buffer.clear()
                    reply(outgoing, {"ok": False, "error": "incomplete request"})
                continue
            chunk = os.read(incoming, LIMIT)
            last_input = time.monotonic()
            buffer.extend(chunk)
            if len(buffer) > LIMIT:
                buffer.clear()
                reply(outgoing, {"ok": False, "error": "request too large"})
                continue
            while b"\n" in buffer:
                line, _, remaining = buffer.partition(b"\n")
                buffer = bytearray(remaining)
                request_id = None
                try:
                    packet = json.loads(line)
                    if (not isinstance(packet, dict) or set(packet) != {"id", "request"}
                            or not isinstance(packet["id"], str)
                            or not re.fullmatch(r"[0-9a-f]{32}", packet["id"])):
                        raise Unavailable("invalid IPC envelope")
                    request_id = packet["id"]
                    request = packet["request"]
                    validate(request)
                    if error:
                        raise Unavailable(error)
                    result = {"ok": True, **backend.operate(request)}
                except Unavailable as exc:
                    result = {"ok": False, "error": str(exc)}
                except Exception:
                    result = {"ok": False, "error": "invalid request or secret backend failure"}
                reply(outgoing, {"id": request_id, "result": result})
    finally:
        for fd in descriptors:
            os.close(fd)
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
        raise Unavailable("usage: secret-broker.py SESSION_DIRECTORY PARENT_PID [CREATIVE_MOUNT ...]")
    directory = Path(sys.argv[1])
    parent = int(sys.argv[2])
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise Unavailable("secret IPC directory must be owned by the runtime with mode 0700")
    mounts = sys.argv[3:]
    outside_mounts(directory, mounts)
    if os.environ.get("BITWARDEN_SECRETS_ENABLED") == "true":
        outside_mounts(os.environ.get("BITWARDEN_SECRETS_TOKEN_FILE", ""), mounts)
    # Suppress Python AND native-library diagnostics before importing the SDK.
    # No buffering, temporary output files, inherited journald, or debug logging.
    with open(os.devnull, "w") as sink:
        os.dup2(sink.fileno(), 1)
        os.dup2(sink.fileno(), 2)
    backend, error = None, None
    if os.environ.get("BITWARDEN_SECRETS_ENABLED", "false") != "true":
        error = "Commitment-owned secrets are disabled by operator configuration"
    else:
        try:
            backend = Backend(os.environ.get("BITWARDEN_PROJECT_ID", ""),
                              os.environ.get("BITWARDEN_SECRETS_TOKEN_FILE", ""), mounts)
        except Unavailable as exc:
            error = str(exc)
    serve(directory, backend, error, parent)


def stop(_signum, _frame):
    raise SystemExit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        main()
    except Exception:
        print("commitment-secret: broker startup failed; check host configuration", file=sys.stderr)
        sys.exit(1)
