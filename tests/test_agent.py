from __future__ import annotations

import json
import os
import tempfile
import unittest
from datetime import date
from pathlib import Path

from commitment.agent import inspect_repository, parse_mutation, prepare_request, render_response
from commitment.ollama import MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES
from commitment.result import ModelError, PolicyError


class AgentTests(unittest.TestCase):
    def test_prepare_emits_bounded_ollama_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "VOICE.md").write_text("lowercase prose.\n", encoding="utf-8")
            raw = prepare_request(root, "local-model", today=date(2026, 8, 18))
        request = json.loads(raw)
        self.assertLessEqual(len(raw), MAX_REQUEST_BYTES)
        self.assertEqual(request["model"], "local-model")
        self.assertFalse(request["stream"])
        self.assertIn("journal/2026-08-18-", request["prompt"])

    def test_render_validates_response_and_emits_structured_journal(self) -> None:
        mutation = {
            "path": "journal/2026-08-18-read-repo.md",
            "content": "me read repo.\nrepo stays bounded.\n",
        }
        result = render_response(
            json.dumps({"response": json.dumps(mutation)}).encode("utf-8")
        )
        self.assertEqual(result.path, mutation["path"])
        self.assertEqual(result.content, mutation["content"])
        self.assertEqual(result.size, len(mutation["content"].encode()))

    def test_malformed_model_response_rejected(self) -> None:
        with self.assertRaisesRegex(ModelError, "malformed mutation JSON"):
            parse_mutation("not json")
        with self.assertRaisesRegex(ModelError, "Ollama returned malformed JSON"):
            render_response(b"not json")

    def test_path_traversal_rejected(self) -> None:
        response = json.dumps({"path": "journal/../../escape.md", "content": "no.\n"})
        with self.assertRaisesRegex(PolicyError, "unexpected path"):
            parse_mutation(response)

    def test_oversized_model_output_rejected(self) -> None:
        response = json.dumps(
            {"path": "journal/2026-08-18-too-big.md", "content": "x" * 20 + "\n"}
        )
        with self.assertRaisesRegex(PolicyError, "exceeds 10 bytes"):
            parse_mutation(response, max_bytes=10)

    def test_repository_entry_file_total_and_model_input_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.txt").write_text("12345678", encoding="utf-8")
            (root / "two.txt").write_text("abcdefgh", encoding="utf-8")
            with self.assertRaisesRegex(PolicyError, "exceeds 1 entries"):
                inspect_repository(root, max_entries=1)
            with self.assertRaisesRegex(PolicyError, "file exceeds 4 bytes"):
                inspect_repository(root, max_file_bytes=4)
            with self.assertRaisesRegex(PolicyError, "exceeds 10 inspected bytes"):
                inspect_repository(root, max_total_bytes=10)
            text = inspect_repository(root, max_input_bytes=30)
            self.assertLessEqual(len(text.encode()), 30)

    def test_non_regular_input_rejected_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            os.mkfifo(root / "pipe")
            with self.assertRaisesRegex(PolicyError, "non-regular file"):
                inspect_repository(root)

    def test_response_limit_rejected(self) -> None:
        with self.assertRaisesRegex(ModelError, "response exceeds"):
            render_response(b"x" * (MAX_RESPONSE_BYTES + 1))


if __name__ == "__main__":
    unittest.main()
