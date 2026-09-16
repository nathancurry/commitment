#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

new_repo() {
    local repo=$1
    mkdir -p "$repo/.git" "$repo/queue"
    : >"$repo/runlog.jsonl"
    printf '%s\n' '# Queue fixture' >"$repo/queue/README.md"
}

write_item() {
    local repo=$1 name=$2 status=$3
    {
        printf '%s\n' '---' 'title: Queue gate fixture'
        [[ $status == __missing__ ]] || printf 'status: %s\n' "$status"
        printf '%s\n' 'priority: medium' '---' '' '## Value hypothesis' 'Fixture.'
    } >"$repo/queue/$name"
}

record_research() {
    local repo=$1 session=$2
    COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID="$session" \
        "$ROOT/commitment-log.sh" research 'Inspected a synthetic queue-gate source' \
        source=https://example.invalid/queue-gate result='Fixture research completed'
}

call_outcome() {
    local repo=$1 session=$2 outcome=$3
    COMMITMENT_ROOT="$repo" COMMITMENT_SESSION_ID="$session" \
        "$ROOT/session-outcome.sh" "$outcome" "Synthetic $outcome queue-gate fixture"
}

expect_queue_rejection() {
    local repo=$1 session=$2 expected=$3
    if call_outcome "$repo" "$session" NOOP >"$TMP/$session.out" 2>&1; then
        fail "$session: NOOP was accepted"
    fi
    grep -Fq 'commitment-outcome: NOOP rejected: actionable or unresolved queue work remains:' \
        "$TMP/$session.out" || fail "$session: deterministic queue rejection is missing"
    grep -Fq "$expected" "$TMP/$session.out" || fail "$session: blocker detail is missing: $expected"
    [[ ! -e "$repo/.git/commitment-session-outcome" ]] || fail "$session: rejection created an outcome marker"
    ! grep -Fq '"type":"session_end"' "$repo/runlog.jsonl" || fail "$session: rejection appended session_end"
}

expect_success() {
    local repo=$1 session=$2 outcome=${3:-NOOP}
    call_outcome "$repo" "$session" "$outcome"
    jq -e --arg outcome "$outcome" '.outcome == $outcome' \
        "$repo/.git/commitment-session-outcome" >/dev/null || fail "$session: $outcome was not recorded"
}

# A-C, J: every actionable lifecycle blocks regardless of a descriptive filename.
for status in candidate researching ready; do
    repo="$TMP/actionable-$status"
    new_repo "$repo"
    write_item "$repo" "2026-09-15-descriptive-$status.md" "$status"
    record_research "$repo" "actionable-$status"
    expect_queue_rejection "$repo" "actionable-$status" "queue/2026-09-15-descriptive-$status.md ($status)"
done

# D-G, K: non-actionable states and misleading filenames do not block.
for status in rejected deferred blocked done; do
    repo="$TMP/non-actionable-$status"
    new_repo "$repo"
    write_item "$repo" "candidate-$status.md" "$status"
    record_research "$repo" "non-actionable-$status"
    expect_success "$repo" "non-actionable-$status"
done

# H: one actionable item blocks among otherwise resolved items.
repo="$TMP/multiple"
new_repo "$repo"
write_item "$repo" resolved.md rejected
write_item "$repo" remains.md ready
record_research "$repo" multiple
expect_queue_rejection "$repo" multiple 'queue/remains.md (ready)'
! grep -Fq 'queue/resolved.md' "$TMP/multiple.out" || fail 'non-actionable item appeared as a blocker'

# I: README is documentation, not a queue item.
repo="$TMP/readme-only"
new_repo "$repo"
record_research "$repo" readme-only
expect_success "$repo" readme-only

# L-M and malformed variants: missing, unknown, duplicate, and unclosed state fail closed.
repo="$TMP/missing"
new_repo "$repo"
write_item "$repo" missing.md __missing__
record_research "$repo" missing
expect_queue_rejection "$repo" missing 'queue/missing.md (malformed: missing status)'

repo="$TMP/unknown"
new_repo "$repo"
write_item "$repo" unknown.md invented
record_research "$repo" unknown
expect_queue_rejection "$repo" unknown 'queue/unknown.md (malformed: unknown status)'

repo="$TMP/duplicate"
new_repo "$repo"
printf '%s\n' '---' 'status: candidate' 'status: rejected' '---' >"$repo/queue/duplicate.md"
record_research "$repo" duplicate
expect_queue_rejection "$repo" duplicate 'queue/duplicate.md (malformed: duplicate status)'

repo="$TMP/unclosed"
new_repo "$repo"
printf '%s\n' '---' 'status: rejected' >"$repo/queue/unclosed.md"
record_research "$repo" unclosed
expect_queue_rejection "$repo" unclosed 'queue/unclosed.md (malformed: unclosed frontmatter)'

repo="$TMP/no-frontmatter"
new_repo "$repo"
printf '%s\n' 'status: candidate' >"$repo/queue/no-frontmatter.md"
record_research "$repo" no-frontmatter
expect_queue_rejection "$repo" no-frontmatter 'queue/no-frontmatter.md (malformed: missing frontmatter)'

# N: a rejected attempt is recoverable after a durable transition.
repo="$TMP/transition"
new_repo "$repo"
write_item "$repo" transition.md candidate
record_research "$repo" transition
expect_queue_rejection "$repo" transition 'queue/transition.md (candidate)'
sed -i 's/status: candidate/status: rejected/' "$repo/queue/transition.md"
expect_success "$repo" transition

# O: substantive same-status progress does not make candidate non-actionable.
repo="$TMP/progress"
new_repo "$repo"
write_item "$repo" progress.md candidate
printf '%s\n' 'Concrete research finding retained.' >>"$repo/queue/progress.md"
record_research "$repo" progress
expect_queue_rejection "$repo" progress 'queue/progress.md (candidate)'

# P-R: queue and research gates are both required and remain distinct.
repo="$TMP/candidate-with-research"
new_repo "$repo"
write_item "$repo" candidate.md candidate
record_research "$repo" candidate-with-research
expect_queue_rejection "$repo" candidate-with-research 'queue/candidate.md (candidate)'

repo="$TMP/no-research"
new_repo "$repo"
if call_outcome "$repo" no-research NOOP >"$TMP/no-research.out" 2>&1; then
    fail 'NOOP without current-session research was accepted'
fi
grep -Fq 'NOOP requires bounded outward research in the current session.' "$TMP/no-research.out" ||
    fail 'research gate did not reject an otherwise queue-clean NOOP'

repo="$TMP/research-and-clean"
new_repo "$repo"
record_research "$repo" research-and-clean
expect_success "$repo" research-and-clean

# S-U: the queue gate applies only to NOOP.
for outcome in COMMITTED_CHANGE CHECKPOINT_UNFINISHED FAILED; do
    repo="$TMP/other-${outcome,,}"
    new_repo "$repo"
    write_item "$repo" remains.md candidate
    expect_success "$repo" "other-${outcome,,}" "$outcome"
done

printf '%s\n' 'ok - deterministic NOOP queue gate, fail-closed lifecycle parsing, research interaction, and other outcomes'
