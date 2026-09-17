#!/usr/bin/python3 -I
"""Creative-side text client for the fixed host planner capability."""

import fcntl
import json
import os
import select
import sys
import time
import uuid
from pathlib import Path

INPUT_LIMIT = 1024 * 1024
RESPONSE_LIMIT = 4 * 1024 * 1024
TIMEOUT = 660


def exchange(text):
    directory = Path("/run/commitment-planner")
    deadline = time.monotonic() + TIMEOUT
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
            while select.select([incoming], [], [], 0)[0]:
                if not os.read(incoming, 65536):
                    break
            outgoing = os.open(directory / "request", os.O_WRONLY | os.O_NONBLOCK)
            try:
                data = (
                    json.dumps(
                        {"id": request_id, "text": text}, ensure_ascii=False
                    ).encode("utf-8")
                    + b"\n"
                )
                offset = 0
                while offset < len(data):
                    if time.monotonic() >= deadline:
                        raise TimeoutError
                    if select.select([], [outgoing], [], 0.5)[1]:
                        offset += os.write(outgoing, data[offset:])
            finally:
                os.close(outgoing)
            data = bytearray()
            while time.monotonic() < deadline and len(data) <= RESPONSE_LIMIT:
                if select.select([incoming], [], [], 0.5)[0]:
                    chunk = os.read(incoming, 65536)
                    if not chunk:
                        raise OSError
                    data.extend(chunk)
                    while b"\n" in data:
                        line, _, remaining = data.partition(b"\n")
                        data = bytearray(remaining)
                        response = json.loads(line)
                        if response.get("id") == request_id:
                            return response
            raise TimeoutError
        finally:
            os.close(incoming)


def main():
    try:
        raw = sys.stdin.buffer.read(INPUT_LIMIT + 1)
        if len(raw) > INPUT_LIMIT:
            print("commitment-plan: input is too large", file=sys.stderr)
            return 2
        text = raw.decode("utf-8")
        if not text.strip():
            print("commitment-plan: input is empty", file=sys.stderr)
            return 2
        response = exchange(text)
        if response.get("ok") is not True or not isinstance(response.get("text"), str):
            diagnostic = response.get("error", "planner unavailable")
            if not isinstance(diagnostic, str):
                diagnostic = "planner unavailable"
            print("commitment-plan: " + diagnostic, file=sys.stderr)
            return 1
        output = response["text"]
        sys.stdout.write(output)
        if not output.endswith("\n"):
            sys.stdout.write("\n")
        return 0
    except UnicodeError:
        print("commitment-plan: input must be UTF-8 text", file=sys.stderr)
        return 2
    except TimeoutError:
        print("commitment-plan: planner timed out", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        print("commitment-plan: trusted planner unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
