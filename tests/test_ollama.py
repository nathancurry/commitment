from __future__ import annotations

import json
import socket
import threading
import time
import unittest
from contextlib import contextmanager
from collections.abc import Iterator
from unittest import mock

from commitment.ollama import (
    CONTEXT_TOKENS,
    GENERATION_OPTIONS,
    MAX_BODY_SECONDS,
    MAX_HEADER_BYTES,
    MAX_HEADER_SECONDS,
    MAX_PROMPT_BYTES,
    RESERVED_OUTPUT_TOKENS,
    TEMPLATE_FRAMING_RESERVE_TOKENS,
    WORST_CASE_TOKENS_PER_UTF8_BYTE,
    build_request,
    parse_response,
    request_ollama,
)
from commitment.result import ModelError, PolicyError


def loopback_available() -> bool:
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    except OSError:
        return False
    probe.close()
    return True


LOOPBACK_AVAILABLE = loopback_available()


@contextmanager
def fake_server(response: bytes, *, delay: float = 0) -> Iterator[tuple[str, list[bytes]]]:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    requests: list[bytes] = []

    def serve() -> None:
        connection, _ = listener.accept()
        with connection:
            raw = bytearray()
            while b"\r\n\r\n" not in raw:
                raw.extend(connection.recv(4096))
            marker = raw.index(b"\r\n\r\n") + 4
            headers = bytes(raw[:marker])
            length = next(
                int(line.split(b":", 1)[1])
                for line in headers.split(b"\r\n")
                if line.lower().startswith(b"content-length:")
            )
            while len(raw) - marker < length:
                raw.extend(connection.recv(4096))
            requests.append(bytes(raw[: marker + length]))
            if delay:
                time.sleep(delay)
            try:
                connection.sendall(response)
            except BrokenPipeError:
                pass

    thread = threading.Thread(target=serve)
    thread.start()
    host, port = listener.getsockname()
    try:
        yield f"http://{host}:{port}", requests
    finally:
        listener.close()
        thread.join(timeout=2)


class ContextContractTests(unittest.TestCase):
    def test_context_contract_arithmetic_and_generation_settings(self) -> None:
        self.assertEqual(
            MAX_PROMPT_BYTES * WORST_CASE_TOKENS_PER_UTF8_BYTE
            + TEMPLATE_FRAMING_RESERVE_TOKENS
            + RESERVED_OUTPUT_TOKENS,
            CONTEXT_TOKENS,
        )
        self.assertEqual(GENERATION_OPTIONS["num_ctx"], CONTEXT_TOKENS)
        self.assertEqual(
            GENERATION_OPTIONS["num_predict"], RESERVED_OUTPUT_TOKENS
        )

    def test_exact_prompt_byte_boundary_and_one_byte_over(self) -> None:
        hostile = "".join(chr(33 + index % 94) for index in range(MAX_PROMPT_BYTES))
        self.assertEqual(len(hostile.encode("utf-8")), MAX_PROMPT_BYTES)
        request = json.loads(build_request(hostile, "local-model"))
        self.assertEqual(request["prompt"], hostile)
        with self.assertRaisesRegex(PolicyError, "prompt exceeds"):
            build_request(hostile + "x", "local-model")

    def test_multibyte_prompt_uses_utf8_byte_boundary(self) -> None:
        emoji = "\N{GRINNING FACE}" * (MAX_PROMPT_BYTES // 4)
        self.assertEqual(len(emoji.encode("utf-8")), MAX_PROMPT_BYTES)
        build_request(emoji, "local-model")
        with self.assertRaisesRegex(PolicyError, "prompt exceeds"):
            build_request(emoji + "x", "local-model")

    def test_truncation_and_inconsistent_context_metadata_are_rejected(self) -> None:
        cases = (
            ({"response": "{}", "truncated": True}, "truncated input"),
            ({"response": "{}", "done": False}, "incomplete"),
            ({"response": "{}", "done_reason": "length"}, "output budget"),
            (
                {
                    "response": "{}",
                    "prompt_eval_count": CONTEXT_TOKENS
                    - RESERVED_OUTPUT_TOKENS
                    + 1,
                },
                "prompt context budget",
            ),
            (
                {"response": "{}", "eval_count": RESERVED_OUTPUT_TOKENS + 1},
                "output token count",
            ),
            (
                {"response": "{}", "context": [0] * (CONTEXT_TOKENS + 1)},
                "oversized context",
            ),
        )
        for document, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(
                ModelError, message
            ):
                parse_response(json.dumps(document).encode())


@unittest.skipUnless(LOOPBACK_AVAILABLE, "loopback sockets unavailable in test sandbox")
class OllamaTests(unittest.TestCase):
    def test_nonstreaming_generation_has_full_header_budget(self) -> None:
        self.assertEqual(MAX_HEADER_SECONDS, MAX_BODY_SECONDS)

    def test_direct_request_is_exactly_once_and_bounded(self) -> None:
        body = json.dumps({"response": "{}"}).encode()
        response = (
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
            + str(len(body)).encode()
            + b"\r\nConnection: close\r\n\r\n"
            + body
        )
        with fake_server(response) as (url, requests):
            self.assertEqual(request_ollama(b"{}", url, 1), body)
        self.assertEqual(len(requests), 1)
        self.assertTrue(requests[0].startswith(b"POST /api/generate HTTP/1.1\r\n"))
        self.assertTrue(requests[0].endswith(b"\r\n\r\n{}"))

    def test_redirects_and_oversized_headers_are_rejected(self) -> None:
        redirect = b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/\r\nContent-Length: 0\r\n\r\n"
        with fake_server(redirect) as (url, _), self.assertRaisesRegex(ModelError, "redirect rejected"):
            request_ollama(b"{}", url, 1)

        oversized = b"HTTP/1.1 200 OK\r\nX-Fill: " + b"x" * MAX_HEADER_BYTES
        with fake_server(oversized) as (url, _), self.assertRaisesRegex(ModelError, "headers exceed"):
            request_ollama(b"{}", url, 1)

    def test_bounded_chunked_response_is_supported(self) -> None:
        body = json.dumps({"response": "{}"}).encode()
        midpoint = len(body) // 2
        chunks = (body[:midpoint], body[midpoint:])
        framed = b"".join(
            f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n" for chunk in chunks
        ) + b"0\r\n\r\n"
        response = (
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + framed
        )
        with fake_server(response) as (url, _):
            self.assertEqual(request_ollama(b"{}", url, 1), body)

    def test_bounded_reasoning_metadata_is_supported(self) -> None:
        body = json.dumps({"response": "{}", "thinking": "x" * (64 * 1024)}).encode()
        response = (
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
            + str(len(body)).encode()
            + b"\r\nConnection: close\r\n\r\n"
            + body
        )
        with fake_server(response) as (url, _):
            self.assertEqual(request_ollama(b"{}", url, 1), body)

    def test_header_deadline_is_separate_and_bounded(self) -> None:
        with (
            fake_server(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", delay=0.05) as (url, _),
            mock.patch("commitment.ollama.MAX_HEADER_SECONDS", 0.01),
            self.assertRaisesRegex(ModelError, "timed out"),
        ):
            request_ollama(b"{}", url, 1)


if __name__ == "__main__":
    unittest.main()
