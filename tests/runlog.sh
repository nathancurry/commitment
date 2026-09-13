#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }

[[ -e "$ROOT/runlog.jsonl" ]] || fail "runlog.jsonl is missing from the Commitment workspace"
git -C "$ROOT" check-ignore -q runlog.jsonl && fail "runlog.jsonl is ignored instead of version-controlled"

assert_contains "$ROOT/prompt.txt" 'Begin an autonomous Commitment session now.'
assert_contains "$ROOT/prompt.txt" 'Do not wait for a user request.'
assert_contains "$ROOT/prompt.txt" 'Do not invent low-value repository changes to produce a commit.'
assert_contains "$ROOT/prompt.txt" 'a plan alone is insufficient'
assert_contains "$ROOT/prompt.txt" 'implement, execute, and test'
assert_contains "$ROOT/prompt.txt" 'recent runlog entries'
assert_contains "$ROOT/prompt.txt" 'ready evidenced queue work'
assert_contains "$ROOT/prompt.txt" 'use the provided COMMITMENT_SESSION_ID for every event'
assert_contains "$ROOT/prompt.txt" 'commitment-outcome OUTCOME'
for outcome in COMMITTED_CHANGE NOOP CHECKPOINT_UNFINISHED FAILED; do
    assert_contains "$ROOT/prompt.txt" "$outcome"
done

assert_contains "$ROOT/AGENTS.md" 'one valid JSON object per line'
assert_contains "$ROOT/AGENTS.md" 'never rewrite prior entries'
for field in ts session_id type summary; do
    assert_contains "$ROOT/AGENTS.md" "\`$field\`"
done
assert_contains "$ROOT/AGENTS.md" 'orchestration records `session_start`'
assert_contains "$ROOT/AGENTS.md" 'End every normal agent run by executing `commitment-outcome'
assert_contains "$ROOT/AGENTS.md" 'Use that exact ID for every later event through `session_end`'
assert_contains "$ROOT/AGENTS.md" 'instead of fabricating an ID'
assert_contains "$ROOT/AGENTS.md" 'A `test` event additionally requires `command` and `result`'
assert_contains "$ROOT/AGENTS.md" 'executed during the current session and its result was observed'
assert_contains "$ROOT/AGENTS.md" 'Never claim tests passed'
assert_contains "$ROOT/AGENTS.md" 'Do not choose work merely because it is easy'
assert_contains "$ROOT/AGENTS.md" 'brief outward research if nothing substantive is apparent'
assert_contains "$ROOT/AGENTS.md" '`NOOP` is successful'
assert_contains "$ROOT/AGENTS.md" 'bookkeeping'
assert_contains "$ROOT/AGENTS.md" 'new `session_end` entries require `outcome`'

log="$TMP/runlog.jsonl"
first='{"ts":"2026-09-13T12:00:00Z","session_id":"test-run","type":"session_start","summary":"Started targeted test"}'
second='{"ts":"2026-09-13T12:00:01Z","session_id":"test-run","type":"test","summary":"Append behavior test completed","command":"printf then append","result":"pass"}'
third='{"ts":"2026-09-13T12:00:02Z","session_id":"test-run","type":"session_end","summary":"No change warranted","outcome":"NOOP"}'
printf '%s\n' "$first" >"$log"
printf '%s\n' "$second" >>"$log"
printf '%s\n' "$third" >>"$log"
[[ $(sed -n '1p' "$log") == "$first" ]] || fail "append changed the existing JSONL entry"
[[ $(wc -l <"$log") -eq 3 ]] || fail "append did not preserve all JSONL entries"
while IFS= read -r entry; do
    printf '%s\n' "$entry" | jq -e '
        type == "object" and
        (["ts", "session_id", "type", "summary"] - keys | length == 0) and
        (if .type == "test" then has("command") and has("result") else true end) and
        (if .type == "session_end" then (.outcome | IN("COMMITTED_CHANGE", "NOOP", "CHECKPOINT_UNFINISHED", "FAILED")) else true end)
    ' >/dev/null || fail "run-log entry is not a valid object with core fields"
done <"$log"

invalid_test='{"ts":"2026-09-13T12:00:03Z","session_id":"test-run","type":"test","summary":"Unsupported pass claim","result":"pass"}'
if printf '%s\n' "$invalid_test" | jq -e 'if .type == "test" then has("command") and has("result") else true end' >/dev/null; then
    fail "test event without an observed command was accepted"
fi

historical="$TMP/historical.jsonl"
printf '%s\n' '{ts:legacy,session_id:old,type:session_end,summary:preserved}' >"$historical"
printf '%s\n' "$third" >>"$historical"
[[ $(sed -n '1p' "$historical") == '{ts:legacy,session_id:old,type:session_end,summary:preserved}' ]] ||
    fail "historical entry was rewritten"
tail -n 1 "$historical" | jq -e '.outcome == "NOOP"' >/dev/null || fail "new outcome did not coexist with historical data"

references=$(rg -l 'runlog\.jsonl' "$ROOT" --glob '!.git/**' | sed "s|$ROOT/||" | sort)
expected=$(printf '%s\n' AGENTS.md README.md agent-git.sh memory/README.md session-outcome.sh tests/memory-queue-noop.sh tests/runlog.sh | sort)
[[ $references == "$expected" ]] || fail "run-log machinery exists outside the log, instructions, documentation, and focused test"

printf 'ok - append-only runlog, evidence fields, outcomes, and historical compatibility\n'
