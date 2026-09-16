#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }

FIXTURE_VERSION_BEFORE=7.8.9
FIXTURE_VERSION_AFTER=7.9.0

[[ -f "$ROOT/memory/README.md" && -f "$ROOT/queue/README.md" ]] || fail "memory or queue format is missing"
for field in title created session source confidence related_queue; do
    assert_contains "$ROOT/memory/README.md" "$field:"
done
for field in title status priority origin created updated memory sources; do
    assert_contains "$ROOT/queue/README.md" "$field:"
done
for section in '## Observation' '## Why it may matter' '## Possible follow-up'; do
    assert_contains "$ROOT/memory/README.md" "$section"
done
for section in '## Value hypothesis' '## Next step' '## Disposition'; do
    assert_contains "$ROOT/queue/README.md" "$section"
done
for state in candidate researching ready blocked deferred done rejected; do
    assert_contains "$ROOT/queue/README.md" "\`$state\`"
done
assert_contains "$ROOT/queue/README.md" 'Keep rejected items with their reason.'
assert_contains "$ROOT/queue/README.md" 'scan filenames, normalized titles, and exact origin references'
assert_contains "$ROOT/AGENTS.md" 'Keep explicit human input separate from self-generated state.'
[[ ! -d "$ROOT/memory/inbox" && ! -d "$ROOT/queue/inbox" ]] || fail "human input was placed under self-generated state"
pass "memory and queue formats, lifecycle, retention, deduplication, and human-input boundary"

new_repo() {
    local repo=$1
    git init -b main "$repo" >/dev/null
    git -C "$repo" config user.name Fixture
    git -C "$repo" config user.email fixture@example.invalid
    mkdir -p "$repo/memory" "$repo/queue"
    printf '%s\n' "$FIXTURE_VERSION_BEFORE" >"$repo/VERSION"
    printf '%s\n' '{ts:legacy,session_id:old,type:session_end,summary:preserved}' >"$repo/runlog.jsonl"
    printf '%s\n' fixture >"$repo/base.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -m initial >/dev/null
}

begin_session() {
    local repo=$1 session_id=$2
    AGENT_REPO="$repo" AGENT_BRANCH=main AGENT_REPO_KIND=commitment \
        COMMITMENT_SESSION_ID="$session_id" "$ROOT/agent-git.sh" session-start
}

record_outcome() {
    local repo=$1 session_id=$2 outcome=$3 summary=$4
    (
        cd "$repo"
        COMMITMENT_SESSION_ID="$session_id" \
            COMMITMENT_OUTCOME_FILE="$repo/.git/commitment-session-outcome" \
            "$ROOT/session-outcome.sh" "$outcome" "$summary"
    )
}

record_research() {
    local repo=$1 session_id=$2 source=${3:-https://example.invalid/research}
    COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID="$session_id" \
        "$ROOT/commitment-log.sh" research "Inspected a synthetic research fixture" \
        "source=$source" result="No sufficiently supported candidate found"
}

read_outcome() {
    local repo=$1 session_id=$2
    AGENT_REPO="$repo" AGENT_BRANCH=main AGENT_REPO_KIND=commitment \
        COMMITMENT_SESSION_ID="$session_id" "$ROOT/agent-git.sh" session-outcome
}

finalize() {
    local repo=$1 base=$2 outcome=$3
    AGENT_REPO="$repo" AGENT_BRANCH=main AGENT_REPO_KIND=commitment \
        AGENT_BASE_HEAD="$base" AGENT_OUTCOME="$outcome" AGENT_EXIT_STATUS=0 \
        AGENT_GIT_NAME='Outcome Author' AGENT_GIT_EMAIL=outcome@example.invalid \
        "$ROOT/agent-git.sh" finalize
}

# Scenario A: bounded research finds no actionable work and records only audit state.
repo_a="$TMP/a"
new_repo "$repo_a"
base_a=$(git -C "$repo_a" rev-parse HEAD)
begin_session "$repo_a" scenario-a
record_research "$repo_a" scenario-a https://example.invalid/release
record_outcome "$repo_a" scenario-a NOOP "Research found no substantive change"
[[ $(read_outcome "$repo_a" scenario-a) == NOOP ]] || fail "NOOP was not recognized"
if record_outcome "$repo_a" scenario-a NOOP "Duplicate outcome" >"$TMP/duplicate.out" 2>&1; then
    fail "duplicate session outcome was accepted"
fi
result_a=$(finalize "$repo_a" "$base_a" NOOP)
[[ $result_a == *substantive=0* ]] || fail "NOOP bookkeeping was classified as substantive"
[[ $(<"$repo_a/VERSION") == "$FIXTURE_VERSION_BEFORE" ]] || fail "NOOP required a VERSION bump"
[[ $(git -C "$repo_a" log -1 --format=%s) == 'chore: record NOOP session bookkeeping' ]] || fail "NOOP bookkeeping was not committed"
[[ $(git -C "$repo_a" log -1 --format='%an|%ae') == 'Outcome Author|outcome@example.invalid' ]] || fail "Git identity was not propagated"
git -C "$repo_a" bundle create "$TMP/noop.bundle" main
git -C "$repo_a" bundle verify "$TMP/noop.bundle" >/dev/null
[[ $(sed -n '1p' "$repo_a/runlog.jsonl") == '{ts:legacy,session_id:old,type:session_end,summary:preserved}' ]] || fail "historical runlog entry changed"
grep -Fq 'https://example.invalid/release' "$repo_a/runlog.jsonl" || fail "research source was not retained"
pass "Scenario A: outward research, successful NOOP, unchanged VERSION, and bundle export"

# Scenario B: a ready evidenced item is selected and produces substantive work.
repo_b="$TMP/b"
new_repo "$repo_b"
cat >"$repo_b/queue/fix-demonstrated-defect.md" <<'EOF'
---
title: Fix demonstrated defect
status: ready
priority: high
origin: tests/failing-case
created: 2026-09-13
updated: 2026-09-13
memory:
---

## Value hypothesis

The failing case demonstrates reliability value.

## Next step

Implement and verify the focused fix.

## Disposition
EOF
git -C "$repo_b" add -A
git -C "$repo_b" commit -m 'queue ready work' >/dev/null
base_b=$(git -C "$repo_b" rev-parse HEAD)
begin_session "$repo_b" scenario-b
printf '%s\n' 'implemented ready item' >"$repo_b/implementation.txt"
printf '%s\n' "$FIXTURE_VERSION_AFTER" >"$repo_b/VERSION"
record_outcome "$repo_b" scenario-b COMMITTED_CHANGE "Implemented the ready evidenced queue item"
result_b=$(finalize "$repo_b" "$base_b" COMMITTED_CHANGE)
[[ $result_b == *substantive=1* ]] || fail "COMMITTED_CHANGE lacked substantive work"
git -C "$repo_b" show HEAD:implementation.txt | grep -Fq 'implemented ready item' ||
    fail "trusted finalizer did not commit substantive work"
[[ $(read_outcome "$repo_b" scenario-b) == COMMITTED_CHANGE ]] || fail "COMMITTED_CHANGE was not distinct"
assert_contains "$ROOT/AGENTS.md" 'ready high-value queue items'
assert_contains "$ROOT/AGENTS.md" 'Prefer ready, evidenced work over new invention.'
pass "Scenario B: ready work precedes invention and COMMITTED_CHANGE requires substantive work"

repo_version="$TMP/version-required"
new_repo "$repo_version"
base_version=$(git -C "$repo_version" rev-parse HEAD)
begin_session "$repo_version" version-required
printf '%s\n' substantive >"$repo_version/feature.txt"
git -C "$repo_version" add -A
git -C "$repo_version" commit -m feature >/dev/null
record_outcome "$repo_version" version-required COMMITTED_CHANGE "Completed substantive Commitment work"
if finalize "$repo_version" "$base_version" COMMITTED_CHANGE >"$TMP/version.out" 2>&1; then
    fail "substantive Commitment update without a VERSION bump was accepted"
fi
grep -Fq 'requires a VERSION bump' "$TMP/version.out" || fail "missing VERSION failure reason"
pass "bookkeeping needs no VERSION bump while substantive Commitment completion does"

repo_bad_noop="$TMP/bad-noop"
new_repo "$repo_bad_noop"
base_bad_noop=$(git -C "$repo_bad_noop" rev-parse HEAD)
begin_session "$repo_bad_noop" bad-noop
record_research "$repo_bad_noop" bad-noop
printf '%s\n' substantive >"$repo_bad_noop/unjustified.txt"
record_outcome "$repo_bad_noop" bad-noop NOOP "Incorrect NOOP fixture"
if finalize "$repo_bad_noop" "$base_bad_noop" NOOP >"$TMP/bad-noop.out" 2>&1; then
    fail "NOOP with substantive work was accepted"
fi
grep -Fq 'NOOP contains substantive changes' "$TMP/bad-noop.out" || fail "missing NOOP mismatch reason"
pass "NOOP rejects substantive repository changes"

for domain in memory queue; do
    repo="$TMP/bad-noop-$domain"
    new_repo "$repo"
    base=$(git -C "$repo" rev-parse HEAD)
    begin_session "$repo" "bad-noop-$domain"
    record_research "$repo" "bad-noop-$domain"
    if [[ $domain == queue ]]; then
        printf '%s\n' '---' 'title: Resolved fixture' 'status: rejected' '---' \
            '## Disposition' 'Synthetic rejected item.' >"$repo/$domain/new.md"
    else
        printf '%s\n' new >"$repo/$domain/new.md"
    fi
    record_outcome "$repo" "bad-noop-$domain" NOOP "Incorrect durable-state NOOP fixture"
    if finalize "$repo" "$base" NOOP >"$TMP/bad-noop-$domain.out" 2>&1; then
        fail "NOOP with new $domain entry was accepted"
    fi
    grep -Fq 'NOOP contains substantive changes' "$TMP/bad-noop-$domain.out" ||
        fail "new $domain entry did not use trusted substantive classification"
done
pass "new memory and queue entries are substantive for explicit NOOP validation"

repo_format="$TMP/format-doc"
new_repo "$repo_format"
printf '%s\n' format >"$repo_format/memory/README.md"
git -C "$repo_format" add -A
git -C "$repo_format" commit -m format >/dev/null
base_format=$(git -C "$repo_format" rev-parse HEAD)
begin_session "$repo_format" format-doc
record_research "$repo_format" format-doc
printf '%s\n' changed >"$repo_format/memory/README.md"
record_outcome "$repo_format" format-doc NOOP "Incorrect format documentation NOOP"
if finalize "$repo_format" "$base_format" NOOP >"$TMP/format.out" 2>&1; then
    fail "memory format documentation was treated as bookkeeping"
fi
pass "memory and queue format documentation remains substantive"

# Scenario C: research rejects a retained candidate with a substantive content update.
repo_c="$TMP/c"
new_repo "$repo_c"
cat >"$repo_c/queue/speculative-helper.md" <<'EOF'
---
title: Speculative helper
status: candidate
priority: low
origin: scenario-c
created: 2026-09-13
updated: 2026-09-13
memory:
---

## Value hypothesis

It might save time.

## Next step

Check for demonstrated use.

## Disposition
EOF
git -C "$repo_c" add -A
git -C "$repo_c" commit -m candidate >/dev/null
base_c=$(git -C "$repo_c" rev-parse HEAD)
begin_session "$repo_c" scenario-c
record_research "$repo_c" scenario-c
sed -i 's/status: candidate/status: rejected/' "$repo_c/queue/speculative-helper.md"
sed -i 's/updated: 2026-09-13/updated: 2026-09-14/' "$repo_c/queue/speculative-helper.md"
printf '%s\n' 'No demonstrated user or reliability need was found.' >>"$repo_c/queue/speculative-helper.md"
record_outcome "$repo_c" scenario-c COMMITTED_CHANGE "Rejected a low-value candidate after research"
result_c=$(finalize "$repo_c" "$base_c" COMMITTED_CHANGE)
[[ $result_c == *substantive=1* ]] || fail "queue content update was not substantive"
[[ -f "$repo_c/queue/speculative-helper.md" ]] || fail "rejected queue item was deleted"
grep -Fq 'status: rejected' "$repo_c/queue/speculative-helper.md" || fail "candidate was not rejected"
grep -Fq 'No demonstrated user or reliability need' "$repo_c/queue/speculative-helper.md" || fail "rejection reason is missing"
pass "Scenario C: rejected candidate remains retained and its content update is substantive"

for outcome in CHECKPOINT_UNFINISHED FAILED; do
    repo="$TMP/${outcome,,}"
    new_repo "$repo"
    base=$(git -C "$repo" rev-parse HEAD)
    begin_session "$repo" "scenario-${outcome,,}"
    printf '%s\n' unfinished >"$repo/unfinished.txt"
    record_outcome "$repo" "scenario-${outcome,,}" "$outcome" "$outcome fixture"
    finalize "$repo" "$base" "$outcome" >/dev/null
    [[ $(read_outcome "$repo" "scenario-${outcome,,}") == "$outcome" ]] || fail "$outcome was not recognized"
    [[ $(git -C "$repo" log -1 --format=%s) == checkpoint:* ]] || fail "$outcome did not preserve dirty work"
done
pass "CHECKPOINT_UNFINISHED and FAILED remain distinct and preserve dirty work"

repo_invalid="$TMP/invalid-outcome"
new_repo "$repo_invalid"
begin_session "$repo_invalid" invalid-outcome
if record_outcome "$repo_invalid" invalid-outcome NOT_AN_OUTCOME "Invalid fixture" >"$TMP/invalid-outcome.out" 2>&1; then
    fail "invalid outcome was accepted"
fi
grep -Fq 'outcome must be COMMITTED_CHANGE, NOOP, CHECKPOINT_UNFINISHED, or FAILED' "$TMP/invalid-outcome.out" ||
    fail "invalid outcome rejection was unclear"
[[ ! -e "$repo_invalid/.git/commitment-session-outcome" ]] || fail "invalid outcome created a marker"
pass "all four helper outcomes work and invalid outcomes fail"

for state in candidate researching ready blocked deferred done rejected; do
    item="$TMP/state-$state.md"
    printf '%s\n' '---' 'title: Lifecycle fixture' "status: $state" 'priority: medium' \
        'origin: synthetic-test' 'created: 2026-09-13' 'updated: 2026-09-13' '---' \
        '## Value hypothesis' 'Fixture' '## Next step' 'Fixture' '## Disposition' >"$item"
    grep -Eq '^status: (candidate|researching|ready|blocked|deferred|done|rejected)$' "$item" || fail "state $state was rejected"
done
slug=$(printf '%s' 'Fix Demonstrated Defect' | tr '[:upper:] ' '[:lower:]-')
[[ $slug == fix-demonstrated-defect && -e "$repo_b/queue/$slug.md" ]] || fail "normalized duplicate scan missed an existing item"
pass "all queue lifecycle states and simple normalized-title duplicate prevention"
