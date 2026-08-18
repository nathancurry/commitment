from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass


class CommitmentError(RuntimeError):
    """Base error for a rejected commitment run."""


class ModelError(CommitmentError):
    """Ollama request or response failed."""


class PolicyError(CommitmentError):
    """A proposed mutation crossed the supervisor policy boundary."""


class ExecutionError(CommitmentError):
    """A required subprocess failed or timed out."""


MAX_TIMEOUT_SECONDS = 3600.0


def validate_timeout(value: float, *, label: str = "timeout") -> float:
    if not math.isfinite(value) or value <= 0 or value > MAX_TIMEOUT_SECONDS:
        raise PolicyError(
            f"{label} must be finite and greater than zero, up to "
            f"{MAX_TIMEOUT_SECONDS:g} seconds"
        )
    return value


@dataclass(frozen=True)
class Mutation:
    path: str
    content: str

    @property
    def size(self) -> int:
        return len(self.content.encode("utf-8"))

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.content.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class JournalResult:
    path: str
    content: str
    size: int
    sha256: str

    def to_json(self) -> str:
        return json.dumps(
            {
                "content": self.content,
                "path": self.path,
                "sha256": self.sha256,
                "size": self.size,
            },
            separators=(",", ":"),
            sort_keys=True,
        )

    @classmethod
    def from_json(cls, raw: str) -> JournalResult:
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise PolicyError("render container returned malformed result JSON") from exc
        if not isinstance(value, dict) or set(value) != {
            "content",
            "path",
            "sha256",
            "size",
        }:
            raise PolicyError(
                "render result must contain only content, path, sha256, and size"
            )
        path = value["path"]
        content = value["content"]
        digest = value["sha256"]
        size = value["size"]
        if (
            not isinstance(path, str)
            or not isinstance(content, str)
            or not isinstance(digest, str)
            or not isinstance(size, int)
            or isinstance(size, bool)
        ):
            raise PolicyError("render result has invalid field types")
        return cls(path=path, content=content, size=size, sha256=digest)
