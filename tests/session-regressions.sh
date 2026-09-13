#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }

current_version=$(<"$ROOT/VERSION")
if rg -n -F "$current_version" "$ROOT/tests" >/dev/null; then
    fail "tests encode the current Commitment release as an invariant: $current_version"
fi
assert_contains "$ROOT/config.example.env" 'CONTINUE_SESSION=false'
assert_contains "$ROOT/run.sh" '${CONTINUE_SESSION:-false}'
assert_contains "$ROOT/prompt.txt" '(1) explicit human input'
assert_contains "$ROOT/prompt.txt" '(2) unfinished substantive work and checkpoints'
assert_contains "$ROOT/prompt.txt" '(3) ready evidenced queue work'
assert_contains "$ROOT/prompt.txt" '(4) relevant memory'
assert_contains "$ROOT/prompt.txt" '(5) repository state and demonstrated defects'
assert_contains "$ROOT/prompt.txt" '(6) bounded outward research'
assert_contains "$ROOT/prompt.txt" '(7) NOOP if nothing worthwhile is found'
assert_contains "$ROOT/prompt.txt" 'If stages 1-5 yield no substantive candidate, you MUST perform a brief bounded outward research pass before choosing NOOP'
assert_contains "$ROOT/prompt.txt" 'This research requirement does not apply when meaningful work from stages 1-5 already justifies the session.'
assert_contains "$ROOT/prompt.txt" 'browse indefinitely, or force a memory/queue entry'
assert_contains "$ROOT/prompt.txt" '`git status --short`'
assert_contains "$ROOT/prompt.txt" '`git log --oneline -n 5`'
assert_contains "$ROOT/AGENTS.md" 'Inspect ordinary Git state and recent history in both repositories'

git init -b main "$TMP/repo" >/dev/null
git -C "$TMP/repo" config user.name Fixture
git -C "$TMP/repo" config user.email fixture@example.invalid
printf '%s\n' '{"ts":"fixture","session_id":"old","type":"session_end","summary":"preserved","outcome":"NOOP"}' >"$TMP/repo/runlog.jsonl"
git -C "$TMP/repo" add runlog.jsonl
git -C "$TMP/repo" commit -m initial >/dev/null

printf '%s\n' 'Outcome: NOOP' >"$TMP/repo/model-response.txt"
if AGENT_REPO="$TMP/repo" AGENT_BRANCH=main AGENT_REPO_KIND=commitment COMMITMENT_SESSION_ID=prose-only \
    "$ROOT/agent-git.sh" session-outcome >"$TMP/prose.out" 2>&1; then
    fail "plain model prose established an outcome"
fi
grep -Fq 'session outcome was not recorded' "$TMP/prose.out" || fail "missing helper outcome was not rejected"

assert_contains "$ROOT/prompt.txt" 'The helper must succeed before the final response'
assert_contains "$ROOT/prompt.txt" 'plain prose such as `Outcome: NOOP` does not count'

printf 'ok - release-independent VERSION checks, fresh-session default, durable startup order, and trusted outcomes\n'
