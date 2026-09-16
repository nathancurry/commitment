#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for script in "$ROOT"/*.sh "$ROOT"/tests/*.sh; do bash -n "$script"; done
python3 -IB - "$ROOT" <<'PY'
import ast
from pathlib import Path
import sys
for path in Path(sys.argv[1]).rglob('*.py'):
    if '.git' not in path.parts:
        ast.parse(path.read_text(), filename=str(path))
PY
python3 -IB "$ROOT/tests/test_runtime.py"
python3 -IB "$ROOT/tests/test_release_candidate.py"
python3 -IB "$ROOT/tests/test_secrets.py"
