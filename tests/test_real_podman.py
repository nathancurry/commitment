from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from collections.abc import Mapping, Sequence
from pathlib import Path

from commitment.ollama import MAX_REQUEST_BYTES
from commitment.supervisor import CommandExecutor, CompletedCommand, Supervisor
from tests.test_ollama import fake_server
from tests.test_supervisor import JOURNAL_CONTENT, JOURNAL_PATH, git, repository_state

IMAGE = os.environ.get("COMMITMENT_REAL_PODMAN_IMAGE")


class InspectingExecutor(CommandExecutor):
    def __init__(self) -> None:
        self.real = CommandExecutor()
        self.inspections: list[dict[str, object]] = []
        self.identities: list[dict[str, object]] = []
        self.names: list[str] = []
        self.run_commands: list[tuple[str, ...]] = []
        self.container_stderr: list[bytes] = []

    def run(
        self,
        command: Sequence[str],
        *,
        cwd: Path,
        timeout: float | None = None,
        env: Mapping[str, str] | None = None,
        input_data: bytes | None = None,
        max_stdout: int = 64 * 1024,
        max_stderr: int = 64 * 1024,
    ) -> CompletedCommand:
        command = tuple(command)
        if command[:2] == ("podman", "run"):
            stage = "prepare" if "prepare" in command else "render"
            image_index = command.index(stage) - 1
            command = (
                *command[:image_index],
                "--env",
                "PYTHONPATH=/repo",
                *command[image_index:],
            )
        result = self.real.run(
            command,
            cwd=cwd,
            timeout=timeout,
            env=env,
            input_data=input_data,
            max_stdout=max_stdout,
            max_stderr=max_stderr,
        )
        if tuple(command[:2]) == ("podman", "run") and result.returncode == 0:
            self.container_stderr.append(result.stderr)
            marker = b"COMMITMENT_IDENTITY="
            identity_line = next(
                line for line in result.stderr.splitlines() if line.startswith(marker)
            )
            self.identities.append(json.loads(identity_line[len(marker) :]))
            self.run_commands.append(tuple(command))
            name = command[command.index("--name") + 1]
            inspected = self.real.run(
                ("podman", "inspect", name),
                cwd=cwd,
                timeout=10,
                max_stdout=256 * 1024,
            )
            if inspected.returncode:
                raise AssertionError(inspected.stderr.decode(errors="replace"))
            self.names.append(name)
            self.inspections.append(json.loads(inspected.stdout)[0])
        return result


@unittest.skipUnless(IMAGE, "set COMMITMENT_REAL_PODMAN_IMAGE for real rootless Podman acceptance")
class RealPodmanAcceptance(unittest.TestCase):
    def test_real_networkless_dry_run(self) -> None:
        assert IMAGE is not None
        with tempfile.TemporaryDirectory(prefix="commitment-real-") as temporary:
            repo = Path(temporary)
            git(repo, "init", "-q")
            git(repo, "config", "user.name", "acceptance")
            git(repo, "config", "user.email", "acceptance@localhost.invalid")
            (repo / "README.md").write_text("# acceptance\n", encoding="utf-8")
            (repo / "VOICE.md").write_text("lowercase prose.\n", encoding="utf-8")
            (repo / "commitment").mkdir()
            malicious = (
                "import sys\n"
                "print('COMMITMENT_MALICIOUS_IMPORT_EXECUTED', file=sys.stderr)\n"
                "raise SystemExit('malicious snapshot import executed')\n"
            )
            (repo / "commitment" / "__init__.py").write_text(malicious, encoding="utf-8")
            (repo / "sitecustomize.py").write_text(malicious, encoding="utf-8")
            (repo / "usercustomize.py").write_text(malicious, encoding="utf-8")
            git(repo, "add", ".")
            git(repo, "commit", "-q", "-m", "fixture")
            before = repository_state(repo)
            mutation = {"path": JOURNAL_PATH, "content": JOURNAL_CONTENT.decode()}
            body = json.dumps({"response": json.dumps(mutation)}).encode()
            response = (
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                + str(len(body)).encode()
                + b"\r\nConnection: close\r\n\r\n"
                + body
            )
            executor = InspectingExecutor()
            with fake_server(response) as (url, requests):
                result = Supervisor(repo, executor).run(image=IMAGE, ollama_url=url)

            self.assertEqual(result.path, JOURNAL_PATH)
            self.assertFalse(result.applied)
            self.assertEqual(repository_state(repo), before)
            self.assertEqual(len(requests), 1)
            request_body = requests[0].split(b"\r\n\r\n", 1)[1]
            self.assertLessEqual(len(request_body), MAX_REQUEST_BYTES)
            self.assertEqual(len(executor.inspections), 2)
            self.assertEqual(len(executor.identities), 2)
            self.assertEqual(len(set(executor.names)), 2)

            evidence: list[dict[str, object]] = []
            for name, inspected, identity in zip(
                executor.names, executor.inspections, executor.identities, strict=True
            ):
                command = executor.run_commands[len(evidence)]
                config = inspected["Config"]
                host = inspected["HostConfig"]
                mounts = inspected["Mounts"]
                assert isinstance(config, dict) and isinstance(host, dict) and isinstance(mounts, list)
                self.assertEqual(config["User"], "10001:10001")
                self.assertEqual(identity["uid"], 10001)
                self.assertEqual(identity["gid"], 10001)
                self.assertEqual(identity["stage"], "prepare" if "prepare" in name else "render")
                commitment_file = Path(str(identity["commitment_file"]))
                self.assertNotEqual(commitment_file, Path("/repo"))
                self.assertNotIn(Path("/repo"), commitment_file.parents)
                self.assertIn("site-packages", commitment_file.parts)
                self.assertEqual(config["WorkingDir"], "/opt/commitment")
                self.assertEqual(config["Entrypoint"], ["python", "-I", "-m", "commitment"])
                self.assertIn("PYTHONPATH=/repo", config["Env"])
                self.assertTrue(host["ReadonlyRootfs"])
                self.assertEqual(host["NetworkMode"], "none")
                self.assertEqual(command[command.index("--userns") + 1], "nomap")
                self.assertFalse(host.get("Tmpfs"))
                self.assertTrue(all(not mount["RW"] for mount in mounts))
                if "prepare" in name:
                    repository = next(mount for mount in mounts if mount["Destination"] == "/repo")
                    self.assertFalse(repository["RW"])
                else:
                    self.assertEqual(mounts, [])
                absent = subprocess.run(
                    ("podman", "container", "exists", name),
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self.assertEqual(absent.returncode, 1)
                evidence.append(
                    {
                        "name": name,
                        "commitment_file": identity["commitment_file"],
                        "uid_gid": config["User"],
                        "uid_map": identity["uid_map"],
                        "read_only_rootfs": host["ReadonlyRootfs"],
                        "network": host["NetworkMode"],
                        "userns": command[command.index("--userns") + 1],
                        "mounts": [
                            {
                                "destination": mount["Destination"],
                                "rw": mount["RW"],
                            }
                            for mount in mounts
                        ],
                        "removed": True,
                    }
                )
            print(
                "REAL_PODMAN_EVIDENCE="
                + json.dumps(
                    {
                        "containers": evidence,
                        "request_count": len(requests),
                        "request_bytes": len(request_body),
                        "journal": result.path,
                        "repository_unchanged": repository_state(repo) == before,
                        "snapshot_imports_executed": False,
                    },
                    sort_keys=True,
                )
            )
            self.assertNotIn(
                b"COMMITMENT_MALICIOUS_IMPORT_EXECUTED",
                b"".join(executor.container_stderr),
            )


if __name__ == "__main__":
    unittest.main()
