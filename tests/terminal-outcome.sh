#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }

mkdir -p "$TMP/fakebin" "$TMP/config" "$TMP/state" "$TMP/commitment/.git" "$TMP/lab/.git"
touch "$TMP/commitment/runlog.jsonl" "$TMP/lab/runlog.jsonl"

cat >"$TMP/fake-publisher" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command=${1:-}
repo=${2:-}
printf '%s|%s|%s|%s\n' "$command" "$repo" "${AGENT_OUTCOME:-}" "${AGENT_EXIT_STATUS:-}" >>"$FAKE_PUBLISH_LOG"
case $command in
    sync) ;;
    session-head) printf '%040d\n' 0 ;;
    session-start)
        rm -f "$FAKE_COMMITMENT_REPO/.git/commitment-session-outcome"
        jq -cn --arg session_id "$COMMITMENT_SESSION_ID" \
            '{ts:"fixture",session_id:$session_id,type:"session_start",summary:"fixture"}' \
            >>"$FAKE_COMMITMENT_REPO/runlog.jsonl"
        ;;
    session-outcome)
        COMMITMENT_ROOT="$FAKE_COMMITMENT_REPO" \
            "$FAKE_OUTCOME_HELPER" --read
        ;;
    session-failure|checkpoint|push) ;;
    finalize)
        if [[ ${AGENT_OUTCOME:-} == COMMITTED_CHANGE && $repo == commitment ]]; then
            printf 'substantive=1\n'
        else
            printf 'substantive=0\n'
        fi
        ;;
    *) exit 2 ;;
esac
EOF

cat >"$TMP/fakebin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case ${1:-} in
    stop)
        printf 'stop|%s\n' "${*: -1}" >>"$FAKE_PROCESS_LOG"
        if [[ -s $FAKE_PODMAN_PID ]]; then
            kill -TERM "$(<"$FAKE_PODMAN_PID")" 2>/dev/null || true
        fi
        exit 0
        ;;
    rm) exit 0 ;;
    run) ;;
    *) exit 2 ;;
esac

session_id=''
previous=''
for argument in "$@"; do
    if [[ $previous == -e && $argument == COMMITMENT_SESSION_ID=* ]]; then
        session_id=${argument#COMMITMENT_SESSION_ID=}
    fi
    previous=$argument
done
[[ -n $session_id ]]
printf '%s\n' "$$" >"$FAKE_PODMAN_PID"
printf 'running|%s\n' "$session_id" >>"$FAKE_PROCESS_LOG"
trap 'printf "terminated|%s\n" "$session_id" >>"$FAKE_PROCESS_LOG"; exit 143' TERM INT

sleep 0.2
case $FAKE_AGENT_MODE in
    outcome)
        if [[ $FAKE_OUTCOME == NOOP ]]; then
            COMMITMENT_ROOT="$FAKE_COMMITMENT_REPO" COMMITMENT_SESSION_ID="$session_id" \
                "$FAKE_LOG_HELPER" research "Synthetic terminal NOOP research" \
                source=https://example.invalid/terminal result="No candidate found"
            printf 'bookkeeping\n' >"$FAKE_COMMITMENT_REPO/bookkeeping.txt"
        fi
        COMMITMENT_ROOT="$FAKE_COMMITMENT_REPO" COMMITMENT_SESSION_ID="$session_id" \
            "$FAKE_OUTCOME_HELPER" "$FAKE_OUTCOME" "Synthetic terminal outcome"
        printf 'recorded|%s\n' "$FAKE_OUTCOME" >>"$FAKE_PROCESS_LOG"
        sleep 5
        touch "$FAKE_COMMITMENT_REPO/post-outcome-action"
        ;;
    stale)
        record=$(jq -cn '{ts:"fixture",session_id:"another-session",type:"session_end",summary:"stale",outcome:"NOOP"}')
        printf '%s\n' "$record" >>"$FAKE_COMMITMENT_REPO/runlog.jsonl"
        printf '%s\n' "$record" >"$FAKE_COMMITMENT_REPO/.git/commitment-session-outcome"
        sleep 1.2
        touch "$FAKE_COMMITMENT_REPO/process-completed"
        ;;
    malformed)
        printf '%s\n' '{malformed' >"$FAKE_COMMITMENT_REPO/.git/commitment-session-outcome"
        printf '%s\n' '{malformed' >>"$FAKE_COMMITMENT_REPO/runlog.jsonl"
        sleep 1.2
        touch "$FAKE_COMMITMENT_REPO/process-completed"
        ;;
    missing) exit 0 ;;
    timeout) sleep 10 ;;
    nonzero) exit 42 ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$TMP/fake-publisher" "$TMP/fakebin/podman"

export FAKE_COMMITMENT_REPO="$TMP/commitment"
export FAKE_OUTCOME_HELPER="$ROOT/session-outcome.sh"
export FAKE_LOG_HELPER="$ROOT/commitment-log.sh"
export FAKE_PUBLISH_LOG="$TMP/publish.log"
export FAKE_PROCESS_LOG="$TMP/process.log"
export FAKE_PODMAN_PID="$TMP/podman.pid"

write_config() {
    local timeout=$1
    cat >"$TMP/config/config.env" <<EOF
COMMITMENT_REPO=$TMP/commitment
COMMITMENT_BRANCH=main
COMMITMENT_UPSTREAM_URL=$TMP/commitment-upstream
LAB_REPO=$TMP/lab
LAB_BRANCH=main
LAB_UPSTREAM_URL=$TMP/lab-upstream
OLLAMA_ENDPOINT=http://host.containers.internal:11434
OLLAMA_MODEL=devstral-small-2-32k
OLLAMA_CONTEXT=32768
OLLAMA_OUTPUT=8192
SESSION_TIMEOUT=$timeout
SCHEDULE=daily
PUBLISH_MODE=checkpoint
CONTAINER_IMAGE=fixture
CONTINUE_SESSION=false
ALLOW_SUBAGENTS=false
GIT_AUTHOR_NAME=Fixture
GIT_AUTHOR_EMAIL=fixture@example.invalid
EOF
}

reset_case() {
    : >"$TMP/commitment/runlog.jsonl"
    : >"$TMP/lab/runlog.jsonl"
    : >"$FAKE_PUBLISH_LOG"
    : >"$FAKE_PROCESS_LOG"
    rm -f "$TMP/commitment/.git/commitment-session-outcome" \
        "$TMP/commitment/post-outcome-action" "$TMP/commitment/process-completed" \
        "$TMP/commitment/bookkeeping.txt" "$FAKE_PODMAN_PID"
}

run_launcher() {
    local output=$1
    PATH="$TMP/fakebin:$PATH" \
        COMMITMENT_CONFIG="$TMP/config/config.env" \
        COMMITMENT_STATE_DIR="$TMP/state" \
        COMMITMENT_PUBLISHER="$TMP/fake-publisher" \
        COMMITMENT_OUTCOME_HELPER="$ROOT/session-outcome.sh" \
        COMMITMENT_LOG_HELPER="$ROOT/commitment-log.sh" \
        "$ROOT/run.sh" >"$output" 2>&1
}

for outcome in NOOP COMMITTED_CHANGE CHECKPOINT_UNFINISHED FAILED; do
    reset_case
    write_config 10
    export FAKE_AGENT_MODE=outcome FAKE_OUTCOME=$outcome
    SECONDS=0
    status=0
    run_launcher "$TMP/$outcome.out" || status=$?
    elapsed=$SECONDS
    if [[ $outcome == FAILED ]]; then
        [[ $status == 1 ]] || fail "FAILED outcome returned status $status"
    else
        [[ $status == 0 ]] || fail "$outcome outcome returned status $status"
    fi
    (( elapsed < 5 )) || fail "$outcome waited for the synthetic process or session timeout"
    assert_contains "$FAKE_PROCESS_LOG" 'running|'
    assert_contains "$FAKE_PROCESS_LOG" "recorded|$outcome"
    assert_contains "$FAKE_PROCESS_LOG" 'stop|commitment-session-'
    assert_contains "$FAKE_PROCESS_LOG" 'terminated|'
    [[ ! -e $TMP/commitment/post-outcome-action ]] || fail "$outcome allowed a post-outcome action"
    jq -e --arg outcome "$outcome" '.outcome == $outcome' \
        "$TMP/commitment/.git/commitment-session-outcome" >/dev/null || fail "$outcome marker changed"
    [[ $(jq -Rr 'fromjson? | select(.type == "session_end") | .outcome' \
        "$TMP/commitment/runlog.jsonl" | wc -l) -eq 1 ]] || fail "$outcome produced multiple session ends"
    ! jq -eR 'fromjson? | select(.type == "failure")' "$TMP/commitment/runlog.jsonl" >/dev/null ||
        fail "$outcome added a failure event"
    ! grep -Fq 'session-failure|' "$FAKE_PUBLISH_LOG" || fail "$outcome invoked session-failure"
    ! grep -Fq 'checkpoint|' "$FAKE_PUBLISH_LOG" || fail "$outcome invoked exit-failure checkpointing"
    grep -Fq "finalize|commitment|$outcome|0" "$FAKE_PUBLISH_LOG" || fail "$outcome missed commitment finalization"
    grep -Fq "finalize|lab|$outcome|0" "$FAKE_PUBLISH_LOG" || fail "$outcome missed lab finalization"
    if [[ $outcome == NOOP ]]; then
        [[ -f $TMP/commitment/bookkeeping.txt ]] || fail "NOOP bookkeeping was not preserved for finalization"
    fi
done
printf 'ok - all trusted outcomes terminate OpenCode promptly and retain normal finalization semantics\n'

for mode in stale malformed; do
    reset_case
    write_config 5
    export FAKE_AGENT_MODE=$mode FAKE_OUTCOME=NOOP
    if run_launcher "$TMP/$mode.out"; then
        fail "$mode outcome state was accepted"
    fi
    [[ -e $TMP/commitment/process-completed ]] || fail "$mode outcome state terminated the process"
    ! grep -Fq 'stop|' "$FAKE_PROCESS_LOG" || fail "$mode outcome state stopped the process"
    assert_contains "$TMP/$mode.out" 'OpenCode exited without a valid session outcome'
    assert_contains "$FAKE_PUBLISH_LOG" 'session-failure|commitment'
done
printf 'ok - stale-session and malformed outcome state cannot terminate the current session\n'

reset_case
write_config 5
export FAKE_AGENT_MODE=missing FAKE_OUTCOME=NOOP
if run_launcher "$TMP/missing.out"; then fail "missing outcome reported success"; fi
assert_contains "$TMP/missing.out" 'OpenCode exited without a valid session outcome'
assert_contains "$FAKE_PUBLISH_LOG" 'session-failure|commitment'

reset_case
write_config 1
export FAKE_AGENT_MODE=timeout FAKE_OUTCOME=NOOP
status=0
run_launcher "$TMP/timeout.out" || status=$?
[[ $status == 124 ]] || fail "timeout returned status $status"
assert_contains "$TMP/timeout.out" 'OpenCode exited with status 124'
assert_contains "$FAKE_PUBLISH_LOG" 'checkpoint|commitment||124'

reset_case
write_config 5
export FAKE_AGENT_MODE=nonzero FAKE_OUTCOME=NOOP
status=0
run_launcher "$TMP/nonzero.out" || status=$?
[[ $status == 42 ]] || fail "nonzero process returned status $status"
assert_contains "$TMP/nonzero.out" 'OpenCode exited with status 42'
assert_contains "$FAKE_PUBLISH_LOG" 'checkpoint|commitment||42'
printf 'ok - missing outcome, timeout, and nonzero exit retain distinct failure handling\n'
