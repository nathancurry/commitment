#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fqi -- "$2" "$1" || fail "$1 lacks $2"; }

doc="$ROOT/requests/README.md"
[[ -f $doc ]] || fail 'requests format missing'
[[ $(find "$ROOT/requests" -type f ! -name README.md | wc -l) -eq 0 ]] || fail 'fake live requests seeded'
for state in requested granted denied deferred withdrawn fulfilled; do contains "$doc" "\`$state\`"; done
for field in title status requested session updated origin related_queue related_memory; do contains "$doc" "$field:"; done
for section in 'Requested resource / capability / information' 'Concrete reason and enabled work' \
    'Minimum sufficient requirement' 'Preferred option and alternatives considered' 'Expected value' \
    'Costs and resource impact' 'Risks and trust boundaries' 'Evidence / sources' \
    'Fallback if unavailable' 'Operator notes' 'Disposition'; do contains "$doc" "## $section"; done
for phrase in 'memory/' 'queue/' 'runlog.jsonl' 'Keep denied, deferred, and' 'Silence is not denial' \
    'materially new evidence' 'scan filenames, normalized titles, and exact origin/source references'; do
    contains "$doc" "$phrase"
done
for phrase in 'open-ended' 'software and hardware constraints' 'Platform/resource information' \
    'more suitable general' 'image-generation, vision' 'specialized reasoning' 'External models/chatbots' \
    'Financial/external data' 'Additional repositories/infrastructure' 'Public distribution and communication' \
    'email/mailboxes' 'autonomously acquire' 'legitimate free resources' \
    'Operator approval is not required for every external resource' 'payment without spending authority' \
    'human verification' 'physical action' 'unavailable permissions' 'Public attention' 'leverage toward usefulness' \
    'public listings and prices' 'RTX 3090' 'not a mandate' 'do not spend operator money' \
    'Never impersonate' 'Never bypass CAPTCHA, access controls' 'private Git repository' \
    'verify `commitment-secret available`' 'safe mechanism' 'no signup/authentication consumer'; do
    contains "$ROOT/AGENTS.md" "$phrase"
done

# Exercise the documented direct text/slug check, including retained decisions.
mkdir -p "$TMP/requests"
for status in denied deferred withdrawn; do
    printf '%s\n' '---' "title: Example $status" "status: $status" \
        'origin: https://example.invalid/constraint' '---' '## Disposition' \
        'Operator decision retained.' >"$TMP/requests/example-$status.md"
    slug=$(printf 'Example %s!!!' "$status" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')
    [[ -f "$TMP/requests/$slug.md" ]] || fail 'duplicate filename scan failed'
    rg -l -F 'https://example.invalid/constraint' "$TMP/requests" >/dev/null || fail 'origin scan failed'
done

# Request-only NOOPs use the existing classifier, outcome, and Git path.
git init -b main "$TMP/repo" >/dev/null
git -C "$TMP/repo" config user.name Fixture
git -C "$TMP/repo" config user.email fixture@example.invalid
mkdir -p "$TMP/repo/requests"
cp "$doc" "$TMP/repo/requests/README.md"
printf '7.8.9\n' >"$TMP/repo/VERSION"
: >"$TMP/repo/runlog.jsonl"
git -C "$TMP/repo" add -A
git -C "$TMP/repo" commit -m initial >/dev/null
base=$(git -C "$TMP/repo" rev-parse HEAD)
cp "$TMP/requests/"*.md "$TMP/repo/requests/"
COMMITMENT_ROOT="$TMP/repo" COMMITMENT_SESSION_ID=request-fixture "$ROOT/commitment-log.sh" \
    research 'Synthetic request test research' source=https://example.invalid/constraint result=fixture
COMMITMENT_ROOT="$TMP/repo" COMMITMENT_SESSION_ID=request-fixture "$ROOT/session-outcome.sh" \
    NOOP 'Retained synthetic requests'
result=$(AGENT_REPO="$TMP/repo" AGENT_BRANCH=main AGENT_REPO_KIND=commitment \
    AGENT_GIT_NAME=Fixture AGENT_GIT_EMAIL=fixture@example.invalid AGENT_BASE_HEAD="$base" \
    AGENT_OUTCOME=NOOP "$ROOT/agent-git.sh" finalize)
[[ $result == *substantive=0* ]] || fail 'request entries classified as substantive'
[[ $(<"$TMP/repo/VERSION") == 7.8.9 ]] || fail 'request bookkeeping changed version'
for status in denied deferred withdrawn; do
    git -C "$TMP/repo" show "HEAD:requests/example-$status.md" | grep -Fq 'Operator decision retained.' ||
        fail 'request disposition not retained in Git'
done
printf '\nFormat changed\n' >>"$TMP/repo/requests/README.md"
if AGENT_REPO="$TMP/repo" AGENT_BRANCH=main AGENT_REPO_KIND=commitment \
    AGENT_BASE_HEAD="$base" AGENT_OUTCOME=NOOP "$ROOT/agent-git.sh" finalize >"$TMP/out" 2>&1; then
    fail 'request README classified as bookkeeping'
fi
contains "$TMP/out" 'NOOP contains substantive changes'
printf 'ok - open-ended resources, request format/lifecycle, retention, direct duplicate scan, and bookkeeping\n'
