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

# A: an unchanged, same-name move from inbox/ to inbox/processed/ is bookkeeping.
repo="$TMP/inbox-noop"
new_repo "$repo"
printf '%s\n' input >"$repo/inbox/foo.md"
git -C "$repo" add -A
git -C "$repo" commit -m initial >/dev/null
base=$(git -C "$repo" rev-parse HEAD)
start_session "$repo" inbox-noop
mv "$repo/inbox/foo.md" "$repo/inbox/processed/foo.md"
COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=inbox-noop "$ROOT/commitment-log.sh" \
    research 'Synthetic research fixture' source=https://example.invalid result=none
record_outcome "$repo" inbox-noop NOOP
result=$(finalize "$repo" "$base" NOOP)
[[ $result == *substantive=0* ]] || fail 'inbox processing became substantive'
git -C "$repo" diff-tree --name-status -r -M --no-commit-id HEAD |
    grep -Fq $'R100\tinbox/foo.md\tinbox/processed/foo.md' ||
    fail 'unchanged inbox processing was not detected as R100'

assert_substantive_move() {
    local name=$1 source=$2 destination=$3 expected_status=$4
    local repo="$TMP/$name" base result
    new_repo "$repo"
    if [[ $expected_status == R052 ]]; then
        for number in {001..100}; do
            printf 'line-%s-abcdefghij\n' "$number"
        done >"$repo/$source"
    else
        printf '%s\n' identical >"$repo/$source"
    fi
    git -C "$repo" add -A
    git -C "$repo" commit -m initial >/dev/null
    base=$(git -C "$repo" rev-parse HEAD)
    mv "$repo/$source" "$repo/$destination"
    if [[ $expected_status == R052 ]]; then
        sed -i '53,100s/abcdefghij/klmnopqrst/' "$repo/$destination"
    fi
    result=$(finalize "$repo" "$base" COMMITTED_CHANGE)
    [[ $result == *substantive=1* ]] || fail "$source -> $destination was not substantive"
    git -C "$repo" diff-tree --name-status -r -M --no-commit-id HEAD |
        grep -Fq "$expected_status"$'\t'"$source"$'\t'"$destination" ||
        fail "$source -> $destination was not detected as $expected_status"
}

# B-G: content-changing inbox moves and all cross-domain moves are substantive.
# Plain mv deliberately leaves the destination untracked until trusted finalization.
assert_substantive_move changed-inbox inbox/foo.md inbox/processed/foo.md R052
assert_substantive_move queue-archive queue/foo.md inbox/processed/foo.md R100
assert_substantive_move changed-queue-archive queue/foo.md inbox/processed/foo.md R052
assert_substantive_move request-archive requests/foo.md inbox/processed/foo.md R100
assert_substantive_move memory-archive memory/foo.md inbox/processed/foo.md R100
assert_substantive_move requests-to-queue requests/foo.md queue/foo.md R100
assert_substantive_move queue-to-requests queue/foo.md requests/foo.md R100
assert_substantive_move memory-to-queue memory/foo.md queue/foo.md R100
assert_substantive_move renamed-inbox inbox/foo.md inbox/processed/bar.md R100
assert_substantive_move changed-memory-rename memory/foo.md memory/bar.md R052

# H: normal inbox processing does not hide a substantive queue lifecycle update.
repo="$TMP/inbox-and-queue"
new_repo "$repo"
printf '%s\n' input >"$repo/inbox/foo.md"
printf '%s\n' $'---\nstatus: candidate\n---\n\n## Disposition' >"$repo/queue/foo.md"
git -C "$repo" add -A
git -C "$repo" commit -m initial >/dev/null
base=$(git -C "$repo" rev-parse HEAD)
start_session "$repo" inbox-and-queue
mv "$repo/inbox/foo.md" "$repo/inbox/processed/foo.md"
sed -i 's/status: candidate/status: rejected/' "$repo/queue/foo.md"
record_outcome "$repo" inbox-and-queue COMMITTED_CHANGE
[[ $(COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID=inbox-and-queue \
    "$ROOT/session-outcome.sh" --read) == COMMITTED_CHANGE ]] || fail 'COMMITTED_CHANGE was not accepted'
result=$(finalize "$repo" "$base" COMMITTED_CHANGE)
[[ $result == *substantive=1* ]] || fail 'queue lifecycle update was hidden by inbox processing'
[[ $(git -C "$repo" log -1 --format=%s) == 'chore: record session bookkeeping' ]] ||
    fail 'trusted COMMITTED_CHANGE finalization path changed'
[[ $(<"$repo/VERSION") == 7.8.9 ]] || fail 'durable-state update required a release bump'

# Ordinary queue/request content modifications remain substantive.
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

printf '%s\n' 'ok - exact inbox processing and substantive durable-state move classification'
