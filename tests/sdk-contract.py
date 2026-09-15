#!/usr/bin/env python3
"""Optional installed-wheel contract check; native/network client is replaced.

Run with the isolated SDK interpreter. Normal tests use fake-sdk.py exclusively.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from unittest import mock

import bitwarden_py

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("broker", ROOT / "secret-broker.py")
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
PROJECT = "11111111-1111-4111-8111-111111111111"
ORG = "33333333-3333-4333-8333-333333333333"
ID = "44444444-4444-4444-8444-444444444444"
DATE = "2026-09-14T00:00:00Z"


class Native:
    def __init__(self, settings):
        assert settings is None  # Fixed official defaults, no agent endpoint.
        self.item = None

    def run_command(self, data):
        command = json.loads(data)
        if "loginAccessToken" in command:
            request = command["loginAccessToken"]
            assert request["accessToken"] == "fixture-machine-token"
            assert request.get("stateFile") is None
            result = dict(authenticated=True, forcePasswordReset=False, resetMasterPassword=False)
        elif "projects" in command:
            assert command["projects"] == {"get": {"id": PROJECT}}
            result = dict(id=PROJECT, organizationId=ORG, name="Fixture", creationDate=DATE, revisionDate=DATE)
        else:
            op, request = next(iter(command["secrets"].items()))
            if op == "list":
                assert request == {"organizationId": ORG}
                result = {"data": [] if self.item is None else [dict(
                    id=ID, key="fixture", organizationId=ORG, projectIds=[PROJECT])]}
            elif op == "get":
                assert request == {"id": ID}
                result = self.item
            elif op in ("create", "update"):
                assert request["organizationId"] == ORG
                assert request["projectIds"] == [PROJECT]
                assert request["key"] == "fixture"
                assert request["note"] == ""
                assert request["value"] == "Z" * 48
                if op == "update":
                    assert request["id"] == ID
                self.item = dict(id=ID, organizationId=ORG, projectId=PROJECT,
                                 key="fixture", note="", value=request["value"],
                                 creationDate=DATE, revisionDate=DATE)
                result = self.item
            elif op == "delete":
                assert request == {"ids": [ID]}
                self.item = None
                result = {"data": [{"id": ID, "error": None}]}
            else:
                raise AssertionError("unexpected native command")
        return json.dumps({"success": True, "data": result})


with tempfile.TemporaryDirectory(prefix="commitment-sdk-contract-") as directory:
    token = Path(directory) / "token"
    token.write_text("fixture-machine-token")
    token.chmod(0o600)
    with mock.patch.object(bitwarden_py, "BitwardenClient", Native), \
            mock.patch.object(subprocess, "Popen", side_effect=AssertionError("no children")), \
            mock.patch.object(broker.secrets, "choice", return_value="Z"):
        backend = broker.Backend(PROJECT, token)
        assert backend.operate({"op": "available"}) == {"available": True}
        created = backend.operate({"op": "generate", "name": "fixture"})
        assert created == backend.operate({"op": "rotate", "name": "fixture"})
        assert backend.operate({"op": "exists", "name": "fixture"})["exists"]
        assert backend.operate({"op": "delete", "name": "fixture"})["deleted"]
        assert backend.operate({"op": "list"}) == {"secrets": []}
print("ok - official SDK wheel serialization and response contracts; native network client replaced")
