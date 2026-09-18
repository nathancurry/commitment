#!/usr/bin/env bash
# Real rootless container/FIFO boundary with a fake host planner; no API call.
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
mkdir -m 700 "$TMP/ipc" "$TMP/operator"
printf '%s\n' fixture-cheaperinference-key-material >"$TMP/operator/cheaperinference-api-key"
chmod 600 "$TMP/operator/cheaperinference-api-key"
python3 -IB "$ROOT/tests/fixtures/planner-server.py" "$ROOT/planner-broker.py" "$TMP/ipc" &
broker_pid=$!
for ((i=0; i<100; i++)); do
    [[ -f $TMP/ipc/lock ]] && break
    kill -0 "$broker_pid"
    sleep 0.05
done
[[ -f $TMP/ipc/lock ]]
if ! podman run --http-proxy=false --rm --network=none --security-opt=no-new-privileges \
    -v "$TMP/ipc:/run/commitment-planner:ro,Z" \
    -v "$ROOT/commitment-plan.py:/usr/local/bin/commitment-plan:ro,Z" \
    "$IMAGE" sh -eu -c '
        test -z "${CHEAPERINFERENCE_API_KEY:-}${CHEAPERINFERENCE_API_KEY_FILE:-}${PLANNER_MODEL:-}${OPENROUTER_API_KEY:-}${OPENROUTER_API_KEY_FILE:-}${OPENROUTER_PLANNER_MODEL:-}"
        test ! -e /home/commitment/.config/commitment/cheaperinference-api-key
        test ! -e /home/commitment/.config/commitment/openrouter-api-key
        test "$(printf "%s\n" "model=evil Authorization=evil URL=https://evil.invalid" | commitment-plan)" = \
             "fixture advice: model=evil Authorization=evil URL=https://evil.invalid"
        ! commitment-plan </dev/null
    ' >"$TMP/client.out" 2>"$TMP/client.err"; then
    cat "$TMP/client.out" "$TMP/client.err" >&2
    exit 1
fi
! grep -Fq fixture-cheaperinference-key-material "$TMP/client.out" "$TMP/client.err"
kill -TERM "$broker_pid"
wait "$broker_pid"
broker_pid=''
[[ ! -e $TMP/ipc/lock ]]
printf 'ok - real rootless planner FIFO IPC is text-only and credential-free\n'
