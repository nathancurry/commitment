#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
RUNLOG=runlog
RUNLOG+=.jsonl

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

new_repo() {
    local repo=$1
    git init -b main "$repo" >/dev/null
    git -C "$repo" config user.name Fixture
    git -C "$repo" config user.email fixture@example.invalid
    mkdir -p "$repo/inbox/processed" "$repo/memory" "$repo/queue" "$repo/requests"
    printf '%s\n' 7.8.9 >"$repo/VERSION"
    : >"$repo/$RUNLOG"
}

finalize() {
    local repo=$1 base=$2 outcome=$3
    AGENT_REPO="$repo" AGENT_BRANCH=main AGENT_REPO_KIND=commitment \
        AGENT_BASE_HEAD="$base" AGENT_OUTCOME="$outcome" AGENT_EXIT_STATUS=0 \
        AGENT_GIT_NAME=Fixture AGENT_GIT_EMAIL=fixture@example.invalid \
        "$ROOT/agent-git.sh" finalize
}

start_session() {
    local repo=$1 session=$2
    AGENT_REPO="$repo" AGENT_BRANCH=main AGENT_REPO_KIND=commitment \
        COMMITMENT_SESSION_ID="$session" "$ROOT/agent-git.sh" session-start
}

record_outcome() {
    local repo=$1 session=$2 outcome=$3
    COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID="$session" \
        "$ROOT/session-outcome.sh" "$outcome" "Synthetic $outcome classifier fixture"
}

# Exact regression: both moves and the runlog remain dirty for trusted finalization.
repo="$TMP/exact"
new_repo "$repo"
printf '%s\n' input >"$repo/inbox/item"
printf '%s\n' work >"$repo/requests/work.md"
git -C "$repo" add -A
git -C "$repo" commit -m initial >/dev/null
base=$(git -C "$repo" rev-parse HEAD)
start_session "$repo" exact-regression
git -C "$repo" mv inbox/item inbox/processed/item
git -C "$repo" mv requests/work.md queue/work.md
record_outcome "$repo" exact-regression COMMITTED_CHANGE
[[ $(COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=exact-regression \
    "$ROOT/session-outcome.sh" --read) == COMMITTED_CHANGE ]] || fail 'COMMITTED_CHANGE was not accepted'
result=$(finalize "$repo" "$base" COMMITTED_CHANGE)
[[ $result == *substantive=1* ]] || fail 'cross-domain R100 move was not substantive'
[[ $(git -C "$repo" log -1 --format=%s) == 'chore: record session bookkeeping' ]] ||
    fail 'normal COMMITTED_CHANGE finalization path was not used'
[[ $(git -C "$repo" diff-tree --name-status -r -M --no-commit-id HEAD) == *$'R100\trequests/work.md\tqueue/work.md'* ]] ||
    fail 'trusted finalization did not retain the R100 move'
[[ $(<"$repo/VERSION") == 7.8.9 ]] || fail 'durable-state move required a release bump'

# A: inbox processing plus runlog remains valid NOOP bookkeeping.
repo="$TMP/inbox-noop"
new_repo "$repo"
printf '%s\n' input >"$repo/inbox/item"
git -C "$repo" add -A
git -C "$repo" commit -m initial >/dev/null
base=$(git -C "$repo" rev-parse HEAD)
start_session "$repo" inbox-noop
git -C "$repo" mv inbox/item inbox/processed/item
COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=inbox-noop "$ROOT/commitment-log.sh" \
    research 'Synthetic research fixture' source=https://example.invalid result=none
record_outcome "$repo" inbox-noop NOOP
result=$(finalize "$repo" "$base" NOOP)
[[ $result == *substantive=0* ]] || fail 'inbox processing became substantive'

assert_cross_domain() {
    local name=$1 source=$2 destination=$3
    local repo="$TMP/$name" base result
    new_repo "$repo"
    printf '%s\n' identical >"$repo/$source"
    git -C "$repo" add -A
    git -C "$repo" commit -m initial >/dev/null
    base=$(git -C "$repo" rev-parse HEAD)
    git -C "$repo" mv "$source" "$destination"
    result=$(finalize "$repo" "$base" COMMITTED_CHANGE)
    [[ $result == *substantive=1* ]] || fail "$source -> $destination was not substantive"
    git -C "$repo" diff-tree --name-status -r -M --no-commit-id HEAD |
        grep -Fq $'R100\t' || fail "$source -> $destination was not detected as R100"
}

# B/C: direction does not erase cross-domain meaning.
assert_cross_domain requests-to-queue requests/foo.md queue/foo.md
assert_cross_domain queue-to-requests queue/foo.md requests/foo.md
assert_cross_domain memory-to-queue memory/foo.md queue/foo.md

# A scored rename still carries both semantic domains.
repo="$TMP/scored-rename"
new_repo "$repo"
for number in {1..20}; do printf 'line %s\n' "$number"; done >"$repo/memory/foo.md"
git -C "$repo" add -A
git -C "$repo" commit -m initial >/dev/null
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" mv memory/foo.md queue/foo.md
sed -i '1s/.*/changed/' "$repo/queue/foo.md"
result=$(finalize "$repo" "$base" COMMITTED_CHANGE)
[[ $result == *substantive=1* ]] || fail 'cross-domain Rnn move was not substantive'
git -C "$repo" diff-tree --name-status -r -M --no-commit-id HEAD |
    grep -Eq '^R0[0-9]{2}[[:space:]]' || fail 'modified cross-domain move was not detected as Rnn'

# D: an in-domain processed-inbox rename retains bookkeeping behavior.
repo="$TMP/processed-rename"
new_repo "$repo"
printf '%s\n' input >"$repo/inbox/processed/old"
git -C "$repo" add -A
git -C "$repo" commit -m initial >/dev/null
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" mv inbox/processed/old inbox/processed/new
result=$(finalize "$repo" "$base" NOOP)
[[ $result == *substantive=0* ]] || fail 'inbox/processed rename became substantive'

# E: ordinary queue/request content modifications remain substantive.
for domain in queue requests; do
    repo="$TMP/modified-$domain"
    new_repo "$repo"
    printf '%s\n' before >"$repo/$domain/foo.md"
    git -C "$repo" add -A
    git -C "$repo" commit -m initial >/dev/null
    base=$(git -C "$repo" rev-parse HEAD)
    printf '%s\n' after >"$repo/$domain/foo.md"
    result=$(finalize "$repo" "$base" COMMITTED_CHANGE)
    [[ $result == *substantive=1* ]] || fail "$domain content modification was not substantive"
done

printf '%s\n' 'ok - semantic durable-state rename and content classification'
