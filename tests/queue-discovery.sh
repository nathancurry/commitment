#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" <<<"$1" || fail "context does not contain $2"; }
not_contains() { ! grep -Fq -- "$2" <<<"$1" || fail "context unexpectedly contains $2"; }

repo="$TMP/repo"
mkdir -p "$repo/queue/nested"
printf '%s\n' '# Queue format' >"$repo/queue/README.md"
printf '%s\n' nested >"$repo/queue/nested/ignored.md"

item() {
    local path=$1 status=$2
    printf '%s\n' '---' 'title: Queue fixture' "status: $status" 'priority: medium' \
        'origin: test' 'created: 2026-09-15' 'updated: 2026-09-15' '---' \
        '## Value hypothesis' 'Fixture' '## Next step' 'Inspect it.' '## Disposition' >"$repo/queue/$path"
}

# Date/descriptive filenames and the current naming style are classified by content.
item 2026-09-15-example.md candidate
item 2026-09-15-microsoft-patch-dilemma-documentation.md candidate
item candidate-looking-name.md rejected
item unrelated-research.md researching
item arbitrary-ready-work.md ready
item historical.md done
item later.md deferred
item waiting.md blocked

context=$("$ROOT/queue-context.sh" "$repo")
contains "$context" '- queue/2026-09-15-example.md (status: candidate)'
contains "$context" '- queue/2026-09-15-microsoft-patch-dilemma-documentation.md (status: candidate)'
contains "$context" '- queue/candidate-looking-name.md (status: rejected)'
not_contains "$context" '- queue/candidate-looking-name.md (status: candidate)'
for status in candidate researching ready blocked deferred done rejected; do
    contains "$context" "status: $status"
done
[[ $(grep -c '^- queue/' <<<"$context") -eq 8 ]] || fail 'not all direct queue items were enumerated independently'
not_contains "$context" 'queue/README.md'
not_contains "$context" 'nested/ignored.md'
contains "$context" 'Inspect these items before falling through to outward research.'
contains "$context" 'blocked, deferred, done, and rejected items are not fresh actionable work.'

# README-only queues preserve the normal research/NOOP fallback by adding no context.
empty="$TMP/empty"
mkdir -p "$empty/queue"
printf '%s\n' '# Queue format' >"$empty/queue/README.md"
[[ -z $("$ROOT/queue-context.sh" "$empty") ]] || fail 'README-only queue produced work context'

# Runtime instructions and assembly prohibit prefix-based lifecycle discovery.
for file in "$ROOT/AGENTS.md" "$ROOT/prompt.txt" "$ROOT/queue/README.md"; do
    grep -Fqi 'filename prefix' "$file" || fail "$file lacks filename-prefix guidance"
done
for pattern in 'ready-*.md' 'candidate-*.md' 'blocked-*.md'; do
    ! rg -F "$pattern" "$ROOT/AGENTS.md" "$ROOT/prompt.txt" "$ROOT/queue/README.md" "$ROOT/queue-context.sh" >/dev/null ||
        fail "instructions require prefix glob $pattern"
done
grep -Fq 'queue_context=$("$QUEUE_CONTEXT_HELPER" "$COMMITMENT_REPO")' "$ROOT/run.sh" ||
    fail 'launcher does not surface queue context'
grep -Fq 'prompt="$queue_context"' "$ROOT/run.sh" || fail 'queue context does not reach the session prompt'

printf '%s\n' 'ok - direct queue discovery, content statuses, README exclusion, lifecycle independence, and fallback behavior'
