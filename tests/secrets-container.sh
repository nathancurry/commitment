#!/usr/bin/env bash
# Real rootless mount/IPC boundary, fake host SDK, no network or live secrets.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${COMMITMENT_TEST_IMAGE:?Set COMMITMENT_TEST_IMAGE to the integration image}
TMP=$(mktemp -d)
broker_pid=''
cleanup() {
    if [[ -n $broker_pid ]]; then
        kill -TERM "$broker_pid" 2>/dev/null || true
        wait "$broker_pid" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -m 700 "$TMP/backend" "$TMP/ipc" "$TMP/operator"
printf '%s\n' fixture-machine-token >"$TMP/operator/bitwarden-secrets-token"
chmod 600 "$TMP/operator/bitwarden-secrets-token"
FAKE_SDK_DIR="$TMP/backend" BITWARDEN_SECRETS_ENABLED=true \
    BITWARDEN_PROJECT_ID=11111111-1111-4111-8111-111111111111 \
    BITWARDEN_SECRETS_TOKEN_FILE="$TMP/operator/bitwarden-secrets-token" \
    python3 -IB "$ROOT/tests/fixtures/fake-sdk.py" "$ROOT/secret-broker.py" "$TMP/ipc" "$$" >"$TMP/broker.out" 2>"$TMP/broker.err" &
broker_pid=$!
for ((i=0; i<100; i++)); do
    [[ -f $TMP/ipc/lock ]] && break
    kill -0 "$broker_pid" || exit 1
    sleep 0.05
done
[[ -f $TMP/ipc/lock ]]
for name in http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY; do
    export "$name=http://synthetic-$name:synthetic-password-$name@example.invalid:1234"
done
if ! podman run --http-proxy=false --rm --network=none --security-opt=no-new-privileges \
    -v "$TMP/ipc:/run/commitment-secrets:ro,Z" \
    -v "$ROOT/commitment-secret.py:/usr/local/bin/commitment-secret:ro,Z" \
    "$IMAGE" sh -eu -c '
        for name in http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY; do
            if env | grep -q "^$name="; then exit 91; fi
        done
        if env | grep -qi synthetic-; then exit 92; fi
        test -z "${BWS_ACCESS_TOKEN:-}${BITWARDEN_SECRETS_TOKEN_FILE:-}${COMMITMENT_GITHUB_TOKEN_FILE:-}${LAB_GITHUB_TOKEN_FILE:-}"
        test ! -e /run/podman/podman.sock
        test ! -e /home/commitment/.config/commitment/bitwarden-secrets-token
        test "$(stat -c %a /run/commitment-secrets/request)" = 600
        test "$(stat -c %u /run/commitment-secrets/request)" = "$(id -u)"
        commitment-secret available
        commitment-secret generate integration-fixture
        commitment-secret rotate integration-fixture
        commitment-secret exists integration-fixture
        commitment-secret list
        commitment-secret delete integration-fixture
        ! commitment-secret get integration-fixture
    ' >"$TMP/client.out" 2>"$TMP/client.err"; then
    printf 'FAIL - container secret IPC (backend diagnostics suppressed)\n' >&2
    exit 1
fi
status=0
podman run --http-proxy=false --rm --network=none --security-opt=no-new-privileges --user 1000:1000 \
    -v "$TMP/ipc:/run/commitment-secrets:ro,Z" \
    -v "$ROOT/commitment-secret.py:/usr/local/bin/commitment-secret:ro,Z" \
    "$IMAGE" commitment-secret available >"$TMP/other.out" 2>"$TMP/other.err" || status=$?
[[ $status == 1 ]] || { printf 'FAIL - unrelated UID could access secret IPC or container failed\n' >&2; exit 1; }
kill -TERM "$broker_pid"
wait "$broker_pid"
broker_pid=''
[[ ! -e $TMP/ipc/lock ]]
python3 - "$TMP" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
state = json.loads((root / 'backend/backend.json').read_text())
assert state['items'] == []
secrets = ['fixture-machine-token', 'Z' * 48]
for path in list(root.glob('*.out')) + list(root.glob('*.err')):
    for secret in secrets:
        assert secret not in path.read_text(), path
for path in (root / 'backend').rglob('*'):
    if path.is_file():
        assert 'Z' * 48 not in path.read_text(), path
PY
printf 'ok - real rootless container FIFO IPC, host-only token, fake SDK generation/rotation/deletion, and cleanup\n'
