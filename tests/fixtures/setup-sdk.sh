#!/usr/bin/env bash
# Usage: bash setup-sdk.sh DISPOSABLE_RUNTIME_DIRECTORY
set -euo pipefail
fixture_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$1/secrets-venv/bin"
install -m 0755 "$fixture_dir/sdk-python" "$1/secrets-venv/bin/python"
install -m 0644 "$fixture_dir/fake-sdk.py" "$1/secrets-venv/bin/fake-sdk.py"
