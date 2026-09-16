#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
IMAGE=${COMMITMENT_TEST_IMAGE:-"localhost/commitment-boundary-test:$$"}
BUILT_IMAGE=false
HOOK_MARKER="/tmp/commitment-boundary-hook-$$"
FSMONITOR_MARKER="/tmp/commitment-boundary-fsmonitor-$$"
cleanup() {
    rm -f "$HOOK_MARKER" "$FSMONITOR_MARKER"
    if $BUILT_IMAGE; then podman image rm "$IMAGE" >/dev/null 2>&1 || true; fi
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

if [[ -z ${COMMITMENT_TEST_IMAGE:-} ]]; then
    podman build -t "$IMAGE" -f "$ROOT/Containerfile" "$ROOT"
    BUILT_IMAGE=true
fi

for name in commitment lab; do
    git init --bare "$TMP/$name.remote" >/dev/null
    git init -b main "$TMP/$name" >/dev/null
    git -C "$TMP/$name" config user.name Test
    git -C "$TMP/$name" config user.email test@example.invalid
    printf '%s\n' initial >"$TMP/$name/README.md"
    git -C "$TMP/$name" add README.md
    git -C "$TMP/$name" commit -m initial >/dev/null
    git -C "$TMP/$name" remote add origin "$TMP/$name.remote"
    git -C "$TMP/$name" push -u origin main >/dev/null

    git clone "$TMP/$name.remote" "$TMP/$name.upstream" >/dev/null 2>&1
    git -C "$TMP/$name.upstream" config user.name Upstream
    git -C "$TMP/$name.upstream" config user.email upstream@example.invalid
    printf '%s\n' upstream >"$TMP/$name.upstream/upstream.txt"
    git -C "$TMP/$name.upstream" add upstream.txt
    git -C "$TMP/$name.upstream" commit -m "upstream $name" >/dev/null
    git -C "$TMP/$name.upstream" push origin main >/dev/null

    mkdir -p "$TMP/$name/.git/hooks"
    printf '%s\n' '#!/bin/sh' "touch $HOOK_MARKER" >"$TMP/$name/.git/hooks/post-merge"
    printf '%s\n' '#!/bin/sh' "touch $HOOK_MARKER" >"$TMP/$name/.git/hooks/pre-commit"
    printf '%s\n' '#!/bin/sh' "touch $HOOK_MARKER" >"$TMP/$name/.git/hooks/pre-push"
    chmod +x "$TMP/$name/.git/hooks/post-merge" "$TMP/$name/.git/hooks/pre-commit" "$TMP/$name/.git/hooks/pre-push"
    printf '%s\n' '#!/bin/sh' "touch $FSMONITOR_MARKER" 'printf "\n"' >"$TMP/$name/.git/fsmonitor"
    chmod +x "$TMP/$name/.git/fsmonitor"
    git -C "$TMP/$name" config core.fsmonitor /workspace/repo/.git/fsmonitor
done

mkdir -p "$TMP/config" "$TMP/state"
printf '%s\n' commitment-fake-token >"$TMP/config/commitment-github-token"
printf '%s\n' lab-fake-token >"$TMP/config/lab-github-token"
chmod 600 "$TMP/config/commitment-github-token" "$TMP/config/lab-github-token"
cat >"$TMP/config/config.env" <<EOF
COMMITMENT_REPO=$TMP/commitment
COMMITMENT_BRANCH=main
COMMITMENT_UPSTREAM_URL=$TMP/commitment.remote
LAB_REPO=$TMP/lab
LAB_BRANCH=main
LAB_UPSTREAM_URL=$TMP/lab.remote
OLLAMA_ENDPOINT=http://host.containers.internal:11434
OLLAMA_MODEL=gpt-oss:20b-32k
OLLAMA_CONTEXT=32768
OLLAMA_OUTPUT=8192
SESSION_TIMEOUT=60
SCHEDULE=daily
PUBLISH_MODE=checkpoint
CONTAINER_IMAGE=$IMAGE
CONTINUE_SESSION=true
GIT_AUTHOR_NAME=Commitment
GIT_AUTHOR_EMAIL=commitment@localhost
COMMITMENT_GITHUB_TOKEN_FILE=$TMP/config/commitment-github-token
LAB_GITHUB_TOKEN_FILE=$TMP/config/lab-github-token
EOF

publisher() {
    COMMITMENT_CONFIG="$TMP/config/config.env" \
        COMMITMENT_STATE_DIR="$TMP/state" \
        COMMITMENT_AGENT_GIT="$ROOT/agent-git.sh" \
        "$ROOT/publish.sh" "$@"
}

container_git() {
    local repo=$1
    shift
    podman run --http-proxy=false --rm --network=none --security-opt=no-new-privileges \
        -v "$TMP/$repo:/workspace/repo:rw,Z" -w /workspace/repo \
        "$IMAGE" git "$@"
}

for name in commitment lab; do
    publisher sync "$name"
    [[ $(<"$TMP/$name/upstream.txt") == upstream ]] || fail "$name did not fast-forward from trusted state"
done
[[ ! -e $HOOK_MARKER && ! -e $FSMONITOR_MARKER ]] || fail "agent command executed in host /tmp during synchronization"
pass "both repositories synchronize through trusted mirrors without host execution of agent Git state"

noop_base=$(container_git commitment rev-parse HEAD)
COMMITMENT_SESSION_ID=boundary-noop publisher session-start commitment
podman run --http-proxy=false --rm --network=none --security-opt=no-new-privileges \
    -v "$TMP/commitment:/workspace/commitment:rw,Z" \
    -v "$ROOT/commitment-log.sh:/usr/local/bin/commitment-log:ro,Z" \
    -v "$ROOT/session-outcome.sh:/usr/local/bin/commitment-outcome:ro,Z" \
    -v "$ROOT/queue-context.sh:/usr/local/bin/queue-context.sh:ro,Z" \
    -e COMMITMENT_SESSION_ID=boundary-noop \
    -e COMMITMENT_ROOT=/workspace/commitment \
    -e COMMITMENT_OUTCOME_FILE=/workspace/commitment/.git/commitment-session-outcome \
    -w /workspace/commitment "$IMAGE" \
    sh -c '
        test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${COMMITMENT_GITHUB_TOKEN_FILE:-}${LAB_GITHUB_TOKEN_FILE:-}"
        commitment-log research "Inspected a synthetic boundary research source" source=https://example.invalid/research result="No candidate worth retaining"
        commitment-outcome NOOP "No substantive boundary change was justified"
    '
tail -n 2 "$TMP/commitment/runlog.jsonl" | jq -e -s '
    length == 2 and
    all(.session_id == "boundary-noop") and
    .[0].type == "research" and
    .[0].source == "https://example.invalid/research" and
    .[0].result == "No candidate worth retaining" and
    .[1].type == "session_end" and
    .[1].outcome == "NOOP"
' >/dev/null || fail "trusted helpers did not append valid session records across the container boundary"
[[ $(COMMITMENT_SESSION_ID=boundary-noop publisher session-outcome commitment) == NOOP ]] ||
    fail "NOOP outcome was not recognized across the container boundary"
noop_result=$(COMMITMENT_SESSION_ID=boundary-noop AGENT_BASE_HEAD="$noop_base" AGENT_OUTCOME=NOOP \
    publisher finalize commitment)
[[ $noop_result == *substantive=0* ]] || fail "NOOP run was not bookkeeping-only"
[[ $(container_git commitment log -1 --format=%s) == 'chore: record NOOP session bookkeeping' ]] ||
    fail "NOOP bookkeeping did not use the existing checkpoint path"
pass "bookkeeping-only NOOP crosses the real network-disabled Git boundary"

for name in commitment lab; do
    printf '%s\n' unfinished >"$TMP/$name/unfinished.txt"
    AGENT_EXIT_STATUS=42 publisher checkpoint "$name"
    [[ $(container_git "$name" log -1 --format=%s) == 'checkpoint: unfinished work after session exit 42' ]] ||
        fail "$name checkpoint was not recorded"
    for number in 1 2; do
        printf '%s\n' "$number" >"$TMP/$name/commit-$number.txt"
        container_git "$name" add "commit-$number.txt"
        container_git "$name" commit -m "$name creative $number" >/dev/null
    done
done
[[ ! -e $HOOK_MARKER && ! -e $FSMONITOR_MARKER ]] || fail "agent command executed in host /tmp during checkpoint or creative commits"
pass "dirty work checkpoints safely and creative Git state remains writable"

for name in commitment lab; do publisher push "$name"; done
for name in commitment lab; do
    subjects=$(git --git-dir="$TMP/$name.remote" log -2 --format=%s refs/heads/main)
    [[ $subjects == "$name creative 2"$'\n'"$name creative 1" ]] || fail "$name commit order was not preserved"
done
[[ ! -e $HOOK_MARKER && ! -e $FSMONITOR_MARKER ]] || fail "agent command executed in host /tmp during publishing"
! rg -F 'commitment-fake-token' "$TMP/commitment/.git" "$TMP/lab/.git" >/dev/null || fail "commitment credential entered agent Git state"
! rg -F 'lab-fake-token' "$TMP/commitment/.git" "$TMP/lab/.git" >/dev/null || fail "lab credential entered agent Git state"
! find "$TMP/state/trusted" -path '*/hooks/pre-push' -o -path '*/hooks/post-merge' -o -path '*/hooks/pre-commit' | grep -q . ||
    fail "agent hooks entered trusted mirrors"
pass "validated bundles preserve multiple commits and trusted mirrors publish without agent hooks, config, or credentials"

git clone "$TMP/commitment.remote" "$TMP/divergent-upstream" >/dev/null 2>&1
git -C "$TMP/divergent-upstream" config user.name Upstream
git -C "$TMP/divergent-upstream" config user.email upstream@example.invalid
printf '%s\n' remote >"$TMP/divergent-upstream/divergent.txt"
git -C "$TMP/divergent-upstream" add divergent.txt
git -C "$TMP/divergent-upstream" commit -m remote-divergence >/dev/null
git -C "$TMP/divergent-upstream" push origin main >/dev/null
printf '%s\n' agent >"$TMP/commitment/agent-divergence.txt"
container_git commitment add agent-divergence.txt
container_git commitment commit -m agent-divergence >/dev/null
agent_head=$(container_git commitment rev-parse HEAD)
remote_head=$(git --git-dir="$TMP/commitment.remote" rev-parse refs/heads/main)
if publisher push commitment >"$TMP/divergence.out" 2>&1; then fail "divergent history was published"; fi
grep -Fq 'divergent agent history preserved' "$TMP/divergence.out" || fail "divergence was not reported"
[[ $(container_git commitment rev-parse HEAD) == "$agent_head" ]] || fail "agent divergence was discarded"
[[ $(git --git-dir="$TMP/commitment.remote" rev-parse refs/heads/main) == "$remote_head" ]] || fail "remote divergence was changed"

printf '%s\n' dirty >"$TMP/commitment/dirty.txt"
if publisher sync commitment >"$TMP/dirty.out" 2>&1; then fail "unexpected dirty state synchronized"; fi
grep -Fq 'dirty state preserved' "$TMP/dirty.out" || fail "dirty state was not reported"
[[ $(<"$TMP/commitment/dirty.txt") == dirty ]] || fail "dirty work was lost"
[[ ! -e $HOOK_MARKER && ! -e $FSMONITOR_MARKER ]] || fail "agent command executed in host /tmp during rejection paths"
pass "divergent history and unexpected dirty work stop safely without destruction"
