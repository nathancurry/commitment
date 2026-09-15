#!/usr/bin/env bash
set -euo pipefail

[[ ${COMMITMENT_REAL_OLLAMA:-0} == 1 ]] || { printf 'skip - set COMMITMENT_REAL_OLLAMA=1 to permit a real model call\n'; exit 0; }

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPERATOR_CONFIG=${COMMITMENT_CONFIG:-"${XDG_CONFIG_HOME:-$HOME/.config}/commitment/config.env"}
[[ -r $OPERATOR_CONFIG ]] || { printf 'operator configuration not found: %s\n' "$OPERATOR_CONFIG" >&2; exit 1; }
# shellcheck source=/dev/null
source "$OPERATOR_CONFIG"
endpoint=${OLLAMA_ENDPOINT%/}
host_endpoint=${endpoint/host.containers.internal/127.0.0.1}
curl -fsS "$host_endpoint/api/tags" | jq -e --arg model "$OLLAMA_MODEL" '.models[] | select(.name == $model)' >/dev/null || {
    printf 'skip - configured Ollama/model is not reachable: %s (%s)\n' "$host_endpoint" "$OLLAMA_MODEL"
    exit 0
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for repo in commitment lab; do
    git init --bare "$TMP/$repo.remote" >/dev/null
    git init -b main "$TMP/$repo" >/dev/null
    git -C "$TMP/$repo" config user.name Test
    git -C "$TMP/$repo" config user.email test@example.invalid
    printf '%s\n' initial >"$TMP/$repo/README.md"
    git -C "$TMP/$repo" add README.md
    git -C "$TMP/$repo" commit -m initial >/dev/null
    git -C "$TMP/$repo" remote add origin "$TMP/$repo.remote"
    git -C "$TMP/$repo" push -u origin main >/dev/null
done
cp "$ROOT/MISSION.md" "$ROOT/AGENTS.md" "$ROOT/VERSION" "$TMP/commitment/"
git -C "$TMP/commitment" add .
git -C "$TMP/commitment" commit -m framework >/dev/null
git -C "$TMP/commitment" push origin main >/dev/null

mkdir -p "$TMP/runtime" "$TMP/config" "$TMP/data"
cp "$ROOT/run.sh" "$ROOT/inbox-context.sh" "$ROOT/publish.sh" "$TMP/runtime/"
cat >"$TMP/runtime/prompt.txt" <<'EOF'
Work only in /workspace/commitment-lab. Create probe.sh which prints "first", execute and inspect it, then revise it to print exactly "revised". Execute and inspect the revised result. Commit the completed lab change. Do nothing else.
EOF
cat >"$TMP/config/config.env" <<EOF
COMMITMENT_REPO=$TMP/commitment
COMMITMENT_BRANCH=main
COMMITMENT_UPSTREAM_URL=$TMP/commitment.remote
LAB_REPO=$TMP/lab
LAB_BRANCH=main
LAB_UPSTREAM_URL=$TMP/lab.remote
OLLAMA_ENDPOINT=$OLLAMA_ENDPOINT
OLLAMA_MODEL=$OLLAMA_MODEL
OLLAMA_CONTEXT=$OLLAMA_CONTEXT
OLLAMA_OUTPUT=$OLLAMA_OUTPUT
SESSION_TIMEOUT=600
SCHEDULE=daily
PUBLISH_MODE=checkpoint
CONTAINER_IMAGE=$CONTAINER_IMAGE
CONTINUE_SESSION=false
GIT_AUTHOR_NAME=Commitment
GIT_AUTHOR_EMAIL=commitment@localhost
COMMITMENT_GITHUB_TOKEN_FILE=
LAB_GITHUB_TOKEN_FILE=
EOF
chmod +x "$TMP/runtime/run.sh" "$TMP/runtime/inbox-context.sh" "$TMP/runtime/publish.sh"
COMMITMENT_CONFIG="$TMP/config/config.env" COMMITMENT_STATE_DIR="$TMP/data" "$TMP/runtime/run.sh"
[[ -x "$TMP/lab/probe.sh" ]]
[[ $("$TMP/lab/probe.sh") == revised ]]
printf 'ok - real Ollama/OpenCode created, executed, inspected, and revised a program\n'
