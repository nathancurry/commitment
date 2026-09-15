"""Offline SDK double and test-only interpreter runner; never imports real SDK.

Persistent fixture state contains metadata and value hashes only. Values stay in
memory, including in deliberate backend failures. No production injection hook.
"""
import hashlib
import json
import os
from pathlib import Path
import runpy
import sys
import time
from types import SimpleNamespace as Object
import uuid

PROJECT = "11111111-1111-4111-8111-111111111111"
ORGANIZATION = "33333333-3333-4333-8333-333333333333"


def response(data):
    return Object(success=True, data=data)


class BitwardenClient:
    def __init__(self, root=None):
        self.root = Path(root or os.environ["FAKE_SDK_DIR"])
        self.values = []
        self.token = None
        self.kind = None

    def auth(self):
        return self

    def login_access_token(self, access_token, state_file=None):
        assert state_file is None
        if access_token != "fixture-machine-token":
            raise RuntimeError(access_token)
        self.token = access_token
        return response(Object(authenticated=True))

    def projects(self):
        self.kind = "project"
        return self

    def secrets(self):
        self.kind = "secret"
        return self

    def state(self):
        store = self.root / "backend.json"
        return json.loads(store.read_text()) if store.exists() else {"items": [], "calls": []}

    def save(self, state):
        (self.root / "backend.json").write_text(json.dumps(state))

    def check(self):
        if (self.root / "sleep").exists():
            time.sleep(60)
        if (self.root / "fail").exists():
            # Exercise both native fd and Python diagnostics suppression in broker.
            os.write(1, self.token.encode())
            os.write(2, self.token.encode())
            print(self.token, file=sys.stderr)
            raise RuntimeError(self.token + "".join(self.values))

    def get(self, id):
        self.check()
        if self.kind == "project":
            assert id == PROJECT
            return response(Object(id=uuid.UUID(PROJECT), organization_id=uuid.UUID(ORGANIZATION)))
        item = next(item for item in self.state()["items"] if item["id"] == id)
        return response(Object(**item, note="preserved note", value="fixture-old-value"))

    def list(self, organization_id):
        self.check()
        assert organization_id == ORGANIZATION
        if (self.root / "malformed").exists():
            return response(Object(data=None))
        return response(Object(data=[Object(
            id=uuid.UUID(item["id"]), key=item["key"],
            project_ids=[uuid.UUID(item["project_id"])],
            organization_id=uuid.UUID(item["organization_id"])) for item in self.state()["items"]]))

    def write(self, op, organization_id, id, key, value, note, project_ids):
        self.values.append(value)
        self.check()
        assert organization_id == ORGANIZATION and project_ids == [PROJECT]
        assert note == (None if op == "create" else "preserved note")
        state = self.state()
        item = dict(id=id, key=key, project_id=PROJECT, organization_id=ORGANIZATION)
        if op == "create":
            state["items"].append(item)
        else:
            assert any(old["id"] == id for old in state["items"])
        state["calls"].append([op, id, hashlib.sha256(value.encode()).hexdigest(), len(value)])
        self.save(state)
        return response(Object(**item, value=value, note=value, unexpected=value))

    def create(self, organization_id, key, value, note, project_ids=None):
        return self.write("create", organization_id, str(uuid.uuid4()), key, value, note, project_ids)

    def update(self, organization_id, id, key, value, note, project_ids=None):
        return self.write("update", organization_id, id, key, value, note, project_ids)

    def delete(self, ids):
        self.check()
        assert len(ids) == 1
        state = self.state()
        state["items"] = [item for item in state["items"] if item["id"] != ids[0]]
        state["calls"].append(["delete", ids])
        self.save(state)
        return response(Object(data=[Object(id=uuid.UUID(ids[0]), error=None)]))


if __name__ == "__main__":
    # Invoked only by tests instead of the installed SDK interpreter.
    import secrets
    secrets.choice = lambda alphabet: "Z"
    sys.modules["bitwarden_sdk"] = Object(BitwardenClient=BitwardenClient)
    args = sys.argv[1:]
    while args[0].startswith("-"):
        args.pop(0)
    sys.argv = args
    runpy.run_path(args[0], run_name="__main__")
