from __future__ import annotations

import json
import socket
import time
from urllib.parse import urlsplit

from commitment.result import ModelError, PolicyError, validate_timeout

DEFAULT_MODEL = "gpt-oss:20b"
DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"
MAX_REQUEST_BYTES = 768 * 1024
MAX_RESPONSE_BYTES = 256 * 1024
MAX_HEADER_BYTES = 16 * 1024
MAX_HEADERS = 64
MAX_CONNECTION_SECONDS = 5.0
MAX_BODY_SECONDS = 120.0
# Non-streaming Ollama generates before sending response headers.
MAX_HEADER_SECONDS = MAX_BODY_SECONDS

# Context contract: every UTF-8 byte may consume one token. The model-side
# template and prompt framing have their own reserve, separate from output.
CONTEXT_TOKENS = 16_384
RESERVED_OUTPUT_TOKENS = 4_096
TEMPLATE_FRAMING_RESERVE_TOKENS = 2_048
WORST_CASE_TOKENS_PER_UTF8_BYTE = 1
MAX_PROMPT_BYTES = (
    CONTEXT_TOKENS
    - RESERVED_OUTPUT_TOKENS
    - TEMPLATE_FRAMING_RESERVE_TOKENS
) // WORST_CASE_TOKENS_PER_UTF8_BYTE

GENERATION_OPTIONS = {
    "temperature": 1,
    "seed": 0,
    "top_p": 1,
    "num_ctx": CONTEXT_TOKENS,
    "num_predict": RESERVED_OUTPUT_TOKENS,
}
THINK_LEVEL = "low"


def validate_ollama_url(url: str) -> str:
    try:
        parsed = urlsplit(url)
        port = 11434 if parsed.port is None else parsed.port
    except ValueError as exc:
        raise PolicyError(f"invalid Ollama URL: {exc}") from exc
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "::1"}:
        raise PolicyError("Ollama URL must use HTTP on an IP loopback address")
    if port <= 0:
        raise PolicyError("Ollama URL port must be greater than zero")
    if parsed.username is not None or parsed.password is not None:
        raise PolicyError("Ollama URL must not contain credentials")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise PolicyError("Ollama URL must not contain path, query, or fragment data")
    host = f"[{parsed.hostname}]" if ":" in parsed.hostname else parsed.hostname
    return f"http://{host}:{port}"


def build_request(prompt: str, model: str) -> bytes:
    if not model or "\x00" in model or len(model.encode("utf-8")) > 256:
        raise PolicyError("model must be a nonempty string without null bytes")
    prompt_bytes = len(prompt.encode("utf-8"))
    if prompt_bytes > MAX_PROMPT_BYTES:
        raise PolicyError(f"model prompt exceeds {MAX_PROMPT_BYTES} UTF-8 bytes")
    payload = json.dumps(
        {
            "model": model,
            "prompt": prompt,
            "stream": False,
            "think": THINK_LEVEL,
            "options": GENERATION_OPTIONS,
        },
        separators=(",", ":"),
    ).encode("utf-8")
    if len(payload) > MAX_REQUEST_BYTES:
        raise ModelError(f"Ollama request exceeds {MAX_REQUEST_BYTES} bytes")
    return payload


def validate_request(raw: bytes, model: str) -> None:
    if len(raw) > MAX_REQUEST_BYTES:
        raise PolicyError(f"prepared Ollama request exceeds {MAX_REQUEST_BYTES} bytes")
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise PolicyError("prepare container returned malformed request JSON") from exc
    expected_keys = {"model", "prompt", "stream", "think", "options"}
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise PolicyError("prepare container returned unexpected request fields")
    if value["model"] != model or not isinstance(value["prompt"], str):
        raise PolicyError("prepare container returned invalid model or prompt")
    if len(value["prompt"].encode("utf-8")) > MAX_PROMPT_BYTES:
        raise PolicyError(f"prepared model prompt exceeds {MAX_PROMPT_BYTES} UTF-8 bytes")
    if (
        value["stream"] is not False
        or value["think"] != THINK_LEVEL
        or value["options"] != GENERATION_OPTIONS
    ):
        raise PolicyError("prepare container returned unsafe generation settings")


def parse_response(raw: bytes) -> str:
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ModelError(f"Ollama response exceeds {MAX_RESPONSE_BYTES} bytes")
    try:
        document = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ModelError("Ollama returned malformed JSON") from exc
    if isinstance(document, dict) and document.get("error"):
        raise ModelError(f"Ollama generation failed: {document['error']}")
    if not isinstance(document, dict) or not isinstance(document.get("response"), str):
        raise ModelError("Ollama response is missing string field 'response'")
    if document.get("truncated") is True:
        raise ModelError("Ollama reported truncated input")
    if document.get("done") is False:
        raise ModelError("Ollama returned an incomplete non-streaming response")
    if document.get("done_reason") in {"length", "max_tokens"}:
        raise ModelError("Ollama generation exhausted its output budget")
    prompt_tokens = _optional_count(document, "prompt_eval_count")
    output_tokens = _optional_count(document, "eval_count")
    if (
        prompt_tokens is not None
        and prompt_tokens + RESERVED_OUTPUT_TOKENS > CONTEXT_TOKENS
    ):
        raise ModelError("Ollama reported an inconsistent prompt context budget")
    if output_tokens is not None and output_tokens > RESERVED_OUTPUT_TOKENS:
        raise ModelError("Ollama reported an inconsistent output token count")
    context = document.get("context")
    if isinstance(context, list) and len(context) > CONTEXT_TOKENS:
        raise ModelError("Ollama reported an oversized context")
    return document["response"]


def _optional_count(document: dict[object, object], field: str) -> int | None:
    value = document.get(field)
    if value is None:
        return None
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ModelError(f"Ollama response has invalid {field}")
    return value


def _remaining(deadline: float, phase_deadline: float, label: str) -> float:
    remaining = min(deadline, phase_deadline) - time.monotonic()
    if remaining <= 0:
        raise ModelError(f"Ollama {label} deadline exceeded")
    return remaining


class _SocketReader:
    def __init__(self, connection: socket.socket, total_deadline: float) -> None:
        self.connection = connection
        self.total_deadline = total_deadline
        self.buffer = bytearray()

    def _receive(self, maximum: int, phase_deadline: float, label: str) -> None:
        self.connection.settimeout(_remaining(self.total_deadline, phase_deadline, label))
        chunk = self.connection.recv(maximum)
        if not chunk:
            raise ModelError(f"Ollama closed connection during {label}")
        self.buffer.extend(chunk)

    def headers(self, phase_deadline: float) -> bytes:
        while True:
            marker = self.buffer.find(b"\r\n\r\n")
            if marker >= 0:
                raw = bytes(self.buffer[:marker])
                del self.buffer[: marker + 4]
                return raw
            if len(self.buffer) >= MAX_HEADER_BYTES:
                raise ModelError(f"Ollama response headers exceed {MAX_HEADER_BYTES} bytes")
            self._receive(MAX_HEADER_BYTES - len(self.buffer), phase_deadline, "header")

    def exact(self, size: int, phase_deadline: float) -> bytes:
        while len(self.buffer) < size:
            self._receive(min(65536, size - len(self.buffer)), phase_deadline, "body")
        result = bytes(self.buffer[:size])
        del self.buffer[:size]
        return result

    def line(self, phase_deadline: float) -> bytes:
        while True:
            marker = self.buffer.find(b"\r\n")
            if marker >= 0:
                result = bytes(self.buffer[:marker])
                del self.buffer[: marker + 2]
                return result
            if len(self.buffer) > 256:
                raise ModelError("Ollama returned malformed chunk framing")
            self._receive(256 - len(self.buffer) + 1, phase_deadline, "body")


def _parse_headers(raw: bytes) -> tuple[int, dict[str, str]]:
    lines = raw.split(b"\r\n")
    if not lines or len(lines) - 1 > MAX_HEADERS:
        raise ModelError(f"Ollama response exceeds {MAX_HEADERS} headers")
    try:
        version, status_raw, _ = lines[0].decode("ascii").split(" ", 2)
        status = int(status_raw)
    except (UnicodeDecodeError, ValueError) as exc:
        raise ModelError("Ollama returned malformed HTTP status") from exc
    if version not in {"HTTP/1.0", "HTTP/1.1"}:
        raise ModelError("Ollama returned unsupported HTTP version")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line or line[:1] in {b" ", b"\t"} or b":" not in line:
            raise ModelError("Ollama returned malformed response header")
        name_raw, value_raw = line.split(b":", 1)
        try:
            name = name_raw.decode("ascii").lower()
            value = value_raw.decode("latin-1").strip()
        except UnicodeDecodeError as exc:
            raise ModelError("Ollama returned malformed response header") from exc
        if name in headers:
            raise ModelError("Ollama returned duplicate response header")
        headers[name] = value
    return status, headers


def _chunked_body(reader: _SocketReader, deadline: float) -> bytes:
    result = bytearray()
    while True:
        line = reader.line(deadline)
        try:
            size = int(line.split(b";", 1)[0], 16)
        except ValueError as exc:
            raise ModelError("Ollama returned malformed chunk size") from exc
        if size < 0 or len(result) + size > MAX_RESPONSE_BYTES:
            raise ModelError(f"Ollama response exceeds {MAX_RESPONSE_BYTES} bytes")
        if size == 0:
            if reader.line(deadline):
                raise ModelError("Ollama response trailers are unsupported")
            return bytes(result)
        result.extend(reader.exact(size, deadline))
        if reader.exact(2, deadline) != b"\r\n":
            raise ModelError("Ollama returned malformed chunk framing")


def request_ollama(payload: bytes, base_url: str, timeout: float) -> bytes:
    if len(payload) > MAX_REQUEST_BYTES:
        raise ModelError(f"Ollama request exceeds {MAX_REQUEST_BYTES} bytes")
    validate_timeout(timeout, label="Ollama total timeout")
    endpoint = validate_ollama_url(base_url)
    parsed = urlsplit(endpoint)
    assert parsed.hostname is not None and parsed.port is not None
    total_deadline = time.monotonic() + timeout
    connection_deadline = min(total_deadline, time.monotonic() + MAX_CONNECTION_SECONDS)
    try:
        connection = socket.create_connection(
            (parsed.hostname, parsed.port),
            timeout=_remaining(total_deadline, connection_deadline, "connection"),
        )
    except (OSError, TimeoutError) as exc:
        raise ModelError(f"Ollama connection failed: {exc}") from exc
    try:
        host = f"[{parsed.hostname}]:{parsed.port}" if ":" in parsed.hostname else f"{parsed.hostname}:{parsed.port}"
        request = (
            "POST /api/generate HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "Content-Type: application/json\r\n"
            f"Content-Length: {len(payload)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii") + payload
        connection.settimeout(_remaining(total_deadline, total_deadline, "request"))
        connection.sendall(request)
        reader = _SocketReader(connection, total_deadline)
        header_deadline = min(total_deadline, time.monotonic() + MAX_HEADER_SECONDS)
        status, headers = _parse_headers(reader.headers(header_deadline))
        if 300 <= status < 400:
            raise ModelError(f"Ollama redirect rejected (HTTP {status})")
        if status != 200:
            raise ModelError(f"Ollama returned HTTP {status}")
        body_deadline = min(total_deadline, time.monotonic() + MAX_BODY_SECONDS)
        transfer = headers.get("transfer-encoding", "").lower()
        if transfer:
            if transfer != "chunked" or "content-length" in headers:
                raise ModelError("Ollama returned unsupported response framing")
            raw = _chunked_body(reader, body_deadline)
        else:
            try:
                length = int(headers.get("content-length", ""))
            except ValueError as exc:
                raise ModelError("Ollama response requires valid Content-Length") from exc
            if length < 0 or length > MAX_RESPONSE_BYTES:
                raise ModelError(f"Ollama response exceeds {MAX_RESPONSE_BYTES} bytes")
            raw = reader.exact(length, body_deadline)
        parse_response(raw)
        return raw
    except socket.timeout as exc:
        raise ModelError("Ollama bounded request timed out") from exc
    except OSError as exc:
        raise ModelError(f"Ollama request failed: {exc}") from exc
    finally:
        connection.close()
