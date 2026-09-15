#!/usr/bin/python3 -I
"""Creative shell client: metadata/reference operations only, no credentials."""

import argparse
import json
import os
import fcntl
from pathlib import Path
import select
import time
import sys
import uuid


def exchange(request):
    directory = Path(os.environ.get("COMMITMENT_SECRET_DIR", "/run/commitment-secrets"))
    deadline = time.monotonic() + 90
    request_id = uuid.uuid4().hex
    with (directory / "lock").open("rb") as lock:
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError
                time.sleep(0.05)
        incoming = os.open(directory / "response", os.O_RDONLY | os.O_NONBLOCK)
        try:
            # Discard a stale response from a caller that died before reading it.
            while select.select([incoming], [], [], 0)[0]:
                if not os.read(incoming, 4096):
                    break
            outgoing = os.open(directory / "request", os.O_WRONLY | os.O_NONBLOCK)
            try:
                data = json.dumps({"id": request_id, "request": request}).encode() + b"\n"
                if len(data) > 4096:
                    raise ValueError
                os.write(outgoing, data)  # One atomic PIPE_BUF-bounded request.
            finally:
                os.close(outgoing)
            data = bytearray()
            while time.monotonic() < deadline and len(data) <= 4 * 1024 * 1024:
                if select.select([incoming], [], [], 0.5)[0]:
                    chunk = os.read(incoming, 4096)
                    if not chunk:
                        raise OSError
                    data.extend(chunk)
                    while b"\n" in data:
                        line, _, remaining = data.partition(b"\n")
                        data = bytearray(remaining)
                        response = json.loads(line)
                        if response.get("id") == request_id:
                            return response["result"]
            raise TimeoutError
        finally:
            os.close(incoming)


def main():
    parser = argparse.ArgumentParser(prog="commitment-secret")
    commands = parser.add_subparsers(dest="op", required=True)
    for op in ("available", "list", "exists", "generate", "rotate", "delete"):
        command = commands.add_parser(op)
        if op not in ("available", "list"):
            command.add_argument("name")
        if op in ("generate", "rotate"):
            command.add_argument("--length", type=int, default=48)
    request = vars(parser.parse_args())
    try:
        result = exchange(request)
        if not result.get("ok"):
            print(json.dumps(result), file=sys.stderr)
            return 1
        print(json.dumps(result))
        return int(result.get("exists") is False)
    except (OSError, ValueError):
        print("commitment-secret: trusted backend unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
