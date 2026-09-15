#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }

contains "$ROOT/AGENTS.md" 'Before normal work selection, read every unprocessed operator file listed from `inbox/`.'
contains "$ROOT/AGENTS.md" 'not as blindly executable instructions'
contains "$ROOT/prompt.txt" '(1) unprocessed inbox items and other explicit human input'
contains "$ROOT/inbox/README.md" '`inbox/processed/` are retained history and are not listed again.'
contains "$ROOT/run.sh" 'inbox_context=$("$INBOX_CONTEXT_HELPER" "$COMMITMENT_REPO")'
contains "$ROOT/run.sh" 'prompt="$inbox_context"'

repo="$TMP/repo"
mkdir -p "$repo/inbox"
printf '%s\n' documentation >"$repo/inbox/README.md"
[[ -z $("$ROOT/inbox-context.sh" "$repo") ]] || fail 'empty inbox changed prompt context'

printf '%s\n' 'operator input' >"$repo/inbox/operator-direction.md"
context=$("$ROOT/inbox-context.sh" "$repo")
[[ $context == Unprocessed\ operator\ inbox* ]] || fail 'inbox was not surfaced before work selection'
grep -Fq -- '- inbox/operator-direction.md' <<<"$context" || fail 'unprocessed item was not listed'
grep -Fq 'explicit operator input' <<<"$context" || fail 'inbox was not identified as operator input'

mkdir -p "$repo/inbox/processed"
mv "$repo/inbox/operator-direction.md" "$repo/inbox/processed/operator-direction.md"
[[ -z $("$ROOT/inbox-context.sh" "$repo") ]] || fail 'processed item was surfaced again'

git -C "$repo" init -b main >/dev/null
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@example.invalid
printf '%s\n' 7.8.9 >"$repo/VERSION"
mv "$repo/inbox/processed/operator-direction.md" "$repo/inbox/operator-direction.md"
git -C "$repo" add -A
git -C "$repo" commit -m initial >/dev/null
base=$(git -C "$repo" rev-parse HEAD)
mkdir -p "$repo/inbox/processed"
git -C "$repo" mv inbox/operator-direction.md inbox/processed/operator-direction.md
result=$(AGENT_REPO="$repo" AGENT_BRANCH=main AGENT_REPO_KIND=commitment \
    AGENT_BASE_HEAD="$base" AGENT_OUTCOME=NOOP AGENT_EXIT_STATUS=0 \
    AGENT_GIT_NAME=Fixture AGENT_GIT_EMAIL=fixture@example.invalid \
    "$ROOT/agent-git.sh" finalize)
[[ $result == *substantive=0* ]] || fail 'processed inbox move was not bookkeeping'
[[ $(<"$repo/VERSION") == 7.8.9 ]] || fail 'processing-only NOOP changed VERSION'

printf '%s\n' 'ok - inbox priority, operator-input semantics, processing lifecycle, empty behavior, and NOOP bookkeeping'
