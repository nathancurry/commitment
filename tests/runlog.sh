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
assert_contains "$ROOT/prompt.txt" 'Choose substantive work that would most increase your usefulness'
assert_contains "$ROOT/prompt.txt" 'a plan alone is not sufficient'
assert_contains "$ROOT/prompt.txt" 'implement, execute, and test'
assert_contains "$ROOT/prompt.txt" 'recent runlog.jsonl entries'
assert_contains "$ROOT/prompt.txt" 'do not spend the session on cosmetic housekeeping merely because it is easy'
assert_contains "$ROOT/prompt.txt" 'evidenced external problems, useful experiments, or substantive self-improvement'
assert_contains "$ROOT/prompt.txt" 'Use the provided COMMITMENT_SESSION_ID for every runlog event'

assert_contains "$ROOT/AGENTS.md" 'one valid JSON object per line'
assert_contains "$ROOT/AGENTS.md" 'never rewrite prior entries'
for field in ts session_id type summary; do
    assert_contains "$ROOT/AGENTS.md" "\`$field\`"
done
assert_contains "$ROOT/AGENTS.md" 'At session start'
assert_contains "$ROOT/AGENTS.md" '`session_end` before exiting'
assert_contains "$ROOT/AGENTS.md" 'read `COMMITMENT_SESSION_ID` from the environment'
assert_contains "$ROOT/AGENTS.md" 'Every later event through `session_end` must use the same value'
assert_contains "$ROOT/AGENTS.md" 'instead of silently fabricating an ID'
assert_contains "$ROOT/AGENTS.md" 'A `test` event additionally requires `command` and `result`'
assert_contains "$ROOT/AGENTS.md" 'executed during the current session and its result was observed'
assert_contains "$ROOT/AGENTS.md" 'Never claim tests passed'
assert_contains "$ROOT/AGENTS.md" 'Do not choose work merely because it is easy'
assert_contains "$ROOT/AGENTS.md" 'look outward briefly for real demand or capability signals'

log="$TMP/runlog.jsonl"
first='{"ts":"2026-09-13T12:00:00Z","session_id":"test-run","type":"session_start","summary":"Started targeted test"}'
second='{"ts":"2026-09-13T12:00:01Z","session_id":"test-run","type":"test","summary":"Append behavior test completed","command":"printf then append","result":"pass"}'
printf '%s\n' "$first" >"$log"
printf '%s\n' "$second" >>"$log"
[[ $(sed -n '1p' "$log") == "$first" ]] || fail "append changed the existing JSONL entry"
[[ $(wc -l <"$log") -eq 2 ]] || fail "append did not produce two JSONL entries"
while IFS= read -r entry; do
    printf '%s\n' "$entry" | jq -e '
        type == "object" and
        (["ts", "session_id", "type", "summary"] - keys | length == 0) and
        (if .type == "test" then has("command") and has("result") else true end)
    ' >/dev/null || fail "run-log entry is not a valid object with core fields"
done <"$log"

references=$(rg -l 'runlog\.jsonl' "$ROOT" --glob '!.git/**' | sed "s|$ROOT/||" | sort)
expected=$(printf '%s\n' AGENTS.md README.md prompt.txt tests/runlog.sh | sort)
[[ $references == "$expected" ]] || fail "run-log machinery exists outside the log, instructions, documentation, and focused test"

printf 'ok - autonomous startup and append-only JSONL run-log contract\n'
