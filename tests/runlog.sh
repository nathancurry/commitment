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
assert_contains "$ROOT/prompt.txt" 'Do not invent low-value repository changes to produce a commit'
assert_contains "$ROOT/prompt.txt" 'a plan alone is insufficient'
assert_contains "$ROOT/prompt.txt" 'implement, execute, and test'
assert_contains "$ROOT/prompt.txt" 'recent runlog entries'
assert_contains "$ROOT/prompt.txt" 'ready evidenced queue work'
assert_contains "$ROOT/prompt.txt" 'Never edit or rewrite runlog.jsonl directly.'
assert_contains "$ROOT/prompt.txt" 'commitment-log TYPE'
assert_contains "$ROOT/prompt.txt" 'commitment-log research'
assert_contains "$ROOT/prompt.txt" 'Use websearch, webfetch, or an equivalent existing web capability to inspect each source during the current session before recording it.'
assert_contains "$ROOT/prompt.txt" 'NOOP requires at least one valid current-session `research` event with non-empty `source` and `result`'
assert_contains "$ROOT/prompt.txt" 'other outcomes do not require research'
assert_contains "$ROOT/prompt.txt" 'commitment-outcome OUTCOME'
for outcome in COMMITTED_CHANGE NOOP CHECKPOINT_UNFINISHED FAILED; do
    assert_contains "$ROOT/prompt.txt" "$outcome"
done

assert_contains "$ROOT/AGENTS.md" 'Never edit, append to, or rewrite `runlog.jsonl` directly.'
assert_contains "$ROOT/AGENTS.md" 'Use `commitment-log TYPE'
assert_contains "$ROOT/AGENTS.md" 'appends one valid JSON object per line'
for field in ts session_id type summary; do
    assert_contains "$ROOT/AGENTS.md" "\`$field\`"
done
assert_contains "$ROOT/AGENTS.md" 'orchestration records `session_start`'
assert_contains "$ROOT/AGENTS.md" 'Before producing the final assistant response, you MUST invoke the installed helper'
assert_contains "$ROOT/AGENTS.md" 'Plain prose such as `Outcome: NOOP` does not count.'
assert_contains "$ROOT/AGENTS.md" 'The helper must succeed before the final response.'
assert_contains "$ROOT/AGENTS.md" 'exact `COMMITMENT_SESSION_ID`'
assert_contains "$ROOT/AGENTS.md" 'never generate or supply those fields yourself'
assert_contains "$ROOT/AGENTS.md" 'A `test` event additionally requires `command` and `result`'
assert_contains "$ROOT/AGENTS.md" 'A `research` event requires non-empty `source` and `result`'
assert_contains "$ROOT/AGENTS.md" 'Record it only after actually inspecting that source during the current session with an available web capability'
assert_contains "$ROOT/AGENTS.md" 'Prior knowledge, invented or unopened URLs, hypothetical searches, and sources found only in old memory, queue, or runlog state do not qualify.'
assert_contains "$ROOT/AGENTS.md" 'Never edit, append to, or rewrite `runlog.jsonl` directly.'
assert_contains "$ROOT/AGENTS.md" 'executed during the current session and its result was observed'
assert_contains "$ROOT/AGENTS.md" 'Never claim tests passed'
assert_contains "$ROOT/AGENTS.md" 'Do not choose work merely because it is easy'
assert_contains "$ROOT/AGENTS.md" 'perform a brief bounded outward research pass before choosing `NOOP`'
assert_contains "$ROOT/AGENTS.md" '`NOOP` is successful'
assert_contains "$ROOT/AGENTS.md" 'bookkeeping'
assert_contains "$ROOT/AGENTS.md" 'new `session_end` entries require `outcome`'

repo="$TMP/repo"
mkdir -p "$repo/.git"
log="$repo/runlog.jsonl"
historical='{ts:legacy,session_id:old,type:session_end,summary:preserved}'
printf '%s\n' "$historical" >"$log"
cp "$log" "$TMP/original-runlog"
original_size=$(wc -c <"$log")
special_summary=$'Quoted "summary" with \\ slash, spaces, and\na newline'
special_source=$'https://example.invalid/a path?quote="yes"\\tail\nsecond-line'

COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=trusted-session \
    "$ROOT/commitment-log.sh" observation "$special_summary" "source=$special_source"
[[ $(wc -l <"$log") -eq 2 ]] || fail "one helper call did not append exactly one line"
cmp -n "$original_size" "$TMP/original-runlog" "$log" >/dev/null || fail "helper changed existing runlog bytes"
[[ $(sed -n '1p' "$log") == "$historical" ]] || fail "historical malformed entry changed"

record=$(tail -n 1 "$log")
printf '%s\n' "$record" | jq -e \
    --arg summary "$special_summary" --arg source "$special_source" '
        type == "object" and
        .session_id == "trusted-session" and
        .type == "observation" and
        .summary == $summary and
        .source == $source and
        (["ts", "session_id", "type", "summary"] - keys | length == 0)
    ' >/dev/null || fail "helper output is invalid JSON or did not preserve escaped strings"
ts=$(printf '%s\n' "$record" | jq -r .ts)
[[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]] ||
    fail "helper timestamp is not ISO 8601: $ts"
date -d "$ts" >/dev/null 2>&1 || fail "helper timestamp cannot be parsed"

line_count=$(wc -l <"$log")
if COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=trusted-session \
    "$ROOT/commitment-log.sh" decision override session_id=forged >"$TMP/override.out" 2>&1; then
    fail "caller overrode session_id"
fi
assert_contains "$TMP/override.out" 'session_id is owned by trusted runtime machinery'
[[ $(wc -l <"$log") -eq $line_count ]] || fail "rejected session_id override appended a record"

if COMMITMENT_ROOT="$repo" "$ROOT/commitment-log.sh" decision missing >"$TMP/missing-session.out" 2>&1; then
    fail "helper accepted a missing COMMITMENT_SESSION_ID"
fi
assert_contains "$TMP/missing-session.out" 'COMMITMENT_SESSION_ID is required'

for fields in 'result=pass' 'command=./tests/test.sh'; do
    if COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=trusted-session \
        "$ROOT/commitment-log.sh" test "Unsupported pass claim" "$fields" >"$TMP/test-fields.out" 2>&1; then
        fail "test event without command and result was accepted"
    fi
    assert_contains "$TMP/test-fields.out" 'test events require command and result'
done
for fields in 'command= result=pass' 'command=./tests/test.sh result='; do
    read -r first_field second_field <<<"$fields"
    if COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=trusted-session \
        "$ROOT/commitment-log.sh" test "Empty evidence" "$first_field" "$second_field" >"$TMP/empty-test-field.out" 2>&1; then
        fail "test event accepted an empty command or result"
    fi
done

COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=trusted-session \
    "$ROOT/commitment-log.sh" test "Lifecycle suite completed" command="./tests/test.sh" result=pass
COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=trusted-session \
    "$ROOT/commitment-log.sh" decision "No substantive internal work is justified"
[[ $(wc -l <"$log") -eq 4 ]] || fail "multiple helper calls did not append independent records"
tail -n 2 "$log" | jq -e -s '
    length == 2 and
    .[0].type == "test" and .[0].command == "./tests/test.sh" and .[0].result == "pass" and
    .[1].type == "decision" and
    all(.session_id == "trusted-session")
' >/dev/null || fail "multiple helper records are not independent valid JSON objects"

if COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=trusted-session \
    "$ROOT/commitment-log.sh" session_end bypass >"$TMP/session-end.out" 2>&1; then
    fail "commitment-log replaced the outcome helper"
fi
assert_contains "$TMP/session-end.out" 'unsupported agent event type: session_end'

outcome_repo="$TMP/outcome-repo"
mkdir -p "$outcome_repo/.git" "$outcome_repo/memory" "$outcome_repo/queue"
outcome_log="$outcome_repo/runlog.jsonl"
printf '%s\n' \
    '{malformed historical line' \
    '{"ts":"fixture","session_id":"older-session","type":"research","summary":"Old research","source":"https://example.invalid/old","result":"No candidate"}' \
    >"$outcome_log"
cp "$outcome_log" "$TMP/outcome-prefix"
outcome_prefix_size=$(wc -c <"$outcome_log")

call_outcome() {
    local session_id=$1 outcome=$2
    shift 2
    COMMITMENT_ROOT="$outcome_repo" COMMITMENT_SESSION_ID="$session_id" \
        COMMITMENT_OUTCOME_FILE="$outcome_repo/.git/outcome-$session_id" \
        "$ROOT/session-outcome.sh" "$outcome" "$*"
}

if call_outcome no-research NOOP "Plain prose says research happened" >"$TMP/no-research.out" 2>&1; then
    fail "NOOP without current-session research was accepted"
fi
assert_contains "$TMP/no-research.out" 'NOOP requires bounded outward research in the current session.'
assert_contains "$TMP/no-research.out" 'Use websearch/webfetch or equivalent, then record it with commitment-log research'
[[ ! -e "$outcome_repo/.git/outcome-no-research" ]] || fail "rejected NOOP created an outcome marker"
! rg -F '"session_id":"no-research","type":"session_end"' "$outcome_log" >/dev/null ||
    fail "rejected NOOP appended a session_end"

printf '%s\n' \
    '{"session_id":"missing-source","type":"research","summary":"Incomplete","result":"Observed"}' \
    '{"session_id":"missing-result","type":"research","summary":"Incomplete","source":"https://example.invalid/incomplete"}' \
    '{"session_id":"missing-summary","type":"research","source":"https://example.invalid/incomplete","result":"Observed"}' \
    >>"$outcome_log"
for session_id in missing-source missing-result missing-summary; do
    if call_outcome "$session_id" NOOP "Incomplete research fixture" >"$TMP/$session_id.out" 2>&1; then
        fail "NOOP accepted research missing a required field: $session_id"
    fi
done

for fields in \
    'result=Observed' \
    'source=https://example.invalid/research' \
    'source= result=Observed' \
    'source=https://example.invalid/research result='; do
    read -r first_field second_field <<<"$fields"
    args=(research "Incomplete research")
    [[ -n ${first_field:-} ]] && args+=("$first_field")
    [[ -n ${second_field:-} ]] && args+=("$second_field")
    if COMMITMENT_ROOT="$outcome_repo" COMMITMENT_SESSION_ID=invalid-research \
        "$ROOT/commitment-log.sh" "${args[@]}" >"$TMP/research-fields.out" 2>&1; then
        fail "research event without non-empty source and result was accepted"
    fi
done

research_source=$'https://example.invalid/research?q="quoted"\\tail'
research_result=$'Observed a repeated workflow; no actionable candidate\nwithin the bounded pass'
COMMITMENT_ROOT="$outcome_repo" COMMITMENT_SESSION_ID=accepted-noop \
    "$ROOT/commitment-log.sh" research "Inspected synthetic high-signal source" \
    "source=$research_source" "result=$research_result"
call_outcome accepted-noop NOOP "No candidate survived bounded research"
jq -eRn --arg source "$research_source" --arg result "$research_result" '
    [inputs | fromjson? | select(
        .session_id == "accepted-noop" and .type == "research" and
        .source == $source and .result == $result
    )] | length == 1
' <"$outcome_log" >/dev/null || fail "research JSON escaping or session ID was not preserved"

for number in 1 2; do
    COMMITMENT_ROOT="$outcome_repo" COMMITMENT_SESSION_ID=multiple-research \
        "$ROOT/commitment-log.sh" research "Inspected source $number" \
        "source=https://example.invalid/$number" "result=Observed result $number"
done
call_outcome multiple-research NOOP "Multiple sources yielded no candidate"
jq -eRn '[inputs | fromjson? | select(.session_id == "multiple-research" and .type == "research")] | length == 2' \
    <"$outcome_log" >/dev/null ||
    fail "multiple valid research events were not preserved"

for outcome in COMMITTED_CHANGE CHECKPOINT_UNFINISHED FAILED; do
    call_outcome "no-research-${outcome,,}" "$outcome" "$outcome without research"
done

cmp -n "$outcome_prefix_size" "$TMP/outcome-prefix" "$outcome_log" >/dev/null ||
    fail "outcome qualification changed malformed or legacy runlog bytes"
[[ ! -s "$outcome_repo/memory/.unexpected" && ! -s "$outcome_repo/queue/.unexpected" ]] ||
    fail "outcome qualification changed memory or queue behavior"
! rg -n 'GITHUB|TOKEN' "$ROOT/commitment-log.sh" >/dev/null || fail "runlog helper references GitHub credentials"

references=$(rg -l 'runlog\.jsonl' "$ROOT" --glob '!.git/**' | sed "s|$ROOT/||" | sort)
expected=$(printf '%s\n' AGENTS.md README.md agent-git.sh commitment-log.sh config.example.env memory/README.md prompt.txt session-outcome.sh tests/git-boundary.sh tests/memory-queue-noop.sh tests/runlog.sh tests/session-regressions.sh | sort)
[[ $references == "$expected" ]] || fail "run-log machinery exists outside the log, instructions, documentation, and focused test"

printf 'ok - append-only runlog, research-gated NOOP, other outcomes, and historical compatibility\n'
