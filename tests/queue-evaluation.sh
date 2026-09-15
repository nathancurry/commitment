#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fqi -- "$2" "$1" || fail "$1 does not contain $2"; }

# The authoritative and per-session instructions use one explicit boundary.
for file in "$ROOT/AGENTS.md" "$ROOT/prompt.txt" "$ROOT/queue/README.md"; do
    contains "$file" 'Merely'
    contains "$file" 'meaningful evaluation'
    contains "$file" 'select'
done
contains "$ROOT/prompt.txt" 'identify it as active/selected work'
contains "$ROOT/prompt.txt" 'perform research specifically to assess it'
contains "$ROOT/prompt.txt" 'investigate its next step'
contains "$ROOT/prompt.txt" 'reason toward whether it should be pursued'
contains "$ROOT/prompt.txt" 'start work derived from it'
printf '%s\n' 'ok - surfacing is non-mutating and meaningful evaluation has explicit triggers'

# Selected-item research must result in durable lifecycle or substantive content
# progress; rejection, deferral, and useful same-status progress are all valid.
contains "$ROOT/prompt.txt" 'lifecycle transition'
contains "$ROOT/prompt.txt" '`deferred`'
contains "$ROOT/prompt.txt" '`rejected`'
contains "$ROOT/prompt.txt" 'concrete findings/evidence'
contains "$ROOT/prompt.txt" 'materially refined next step'
contains "$ROOT/prompt.txt" 'explicit progress/disposition note'
contains "$ROOT/prompt.txt" 'If it remains `candidate`, add actual information that makes its next evaluation materially different.'
contains "$ROOT/prompt.txt" 'Do not use an `updated` timestamp, formatting-only edit, or meaningless churn'
printf '%s\n' 'ok - rejected, deferred, and substantive same-status progress satisfy the durable-progress rule'

# The exact reported failure is prohibited, while candidate-specific research is
# ordered before generic discovery and must feed back into the selected item.
contains "$ROOT/prompt.txt" 'A selected/evaluated actionable item left byte-identical followed by `NOOP` is prohibited.'
contains "$ROOT/prompt.txt" 'Decide whether an actionable queue item is worth selecting before falling through to generic outward problem discovery.'
contains "$ROOT/prompt.txt" 'Research specifically performed for a selected candidate is allowed before generic outward research and its conclusion must feed back into that candidate'
contains "$ROOT/prompt.txt" 'Selecting one item does not require mutating every actionable item that was surfaced.'
printf '%s\n' 'ok - unchanged evaluated candidates cannot end NOOP and candidate research feeds durable state'

# Runtime context preserves discovery semantics and does not itself mutate files.
repo="$TMP/repo"
mkdir -p "$repo/queue"
printf '%s\n' '# Queue' >"$repo/queue/README.md"
for state in candidate researching ready blocked deferred done rejected; do
    printf '%s\n' '---' "title: $state fixture" "status: $state" '---' >"$repo/queue/$state.md"
done
before=$(sha256sum "$repo"/queue/*.md)
context=$("$ROOT/queue-context.sh" "$repo")
after=$(sha256sum "$repo"/queue/*.md)
[[ $before == "$after" ]] || fail 'queue context mutated surfaced items'
grep -Fq 'blocked, deferred, done, and rejected items are not fresh actionable work' <<<"$context" ||
    fail 'non-actionable visibility contract is missing'
grep -Fq 'You may leave unselected items unchanged' <<<"$context" ||
    fail 'unselected-item contract is missing'
grep -Fq 'select one without mutating every actionable item' <<<"$context" ||
    fail 'multiple-actionable-item contract is missing'
grep -Fq 'selected/evaluated plus byte-identical plus NOOP is prohibited' <<<"$context" ||
    fail 'per-session NOOP prohibition is missing'
printf '%s\n' 'ok - visible non-actionable and unselected items stay unchanged, including with multiple actionable items'

# Empty queues retain the existing no-context path to bounded research/NOOP.
empty="$TMP/empty"
mkdir -p "$empty/queue"
printf '%s\n' '# Queue' >"$empty/queue/README.md"
[[ -z $("$ROOT/queue-context.sh" "$empty") ]] || fail 'empty queue produced context'
contains "$ROOT/prompt.txt" 'If stages 1-5 yield no substantive candidate, you MUST perform a brief bounded outward research pass before choosing NOOP'
printf '%s\n' 'ok - empty queue preserves bounded-research and NOOP behavior'
