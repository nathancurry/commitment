#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
C1="commitment-integration-a-$$"
C2="commitment-integration-b-$$"
IMAGE="localhost/commitment-test:$(<"$ROOT/VERSION")-$$"
trap 'podman rm -f "$C1" "$C2" >/dev/null 2>&1 || true; podman image rm "$IMAGE" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

podman build --build-arg OPENCODE_VERSION=1.18.30 -t "$IMAGE" -f "$ROOT/Containerfile" "$ROOT"
[[ $(podman info --format '{{.Host.Security.Rootless}}') == true ]]
version=$(podman run --http-proxy=false --rm --network=none "$IMAGE" opencode --version)
[[ $version == *1.18.30* ]] || { printf 'unexpected OpenCode version: %s\n' "$version" >&2; exit 1; }
podman run --http-proxy=false --rm --network=none "$IMAGE" sh -c \
    'python3 --version && node --version && npm --version && cc --version >/dev/null && c++ --version >/dev/null'
printf 'ok - Containerfile builds with pinned OpenCode, Python, Node/npm, and C/C++ toolchain (%s)\n' "$version"

for repo in commitment lab; do
    git init -b main "$TMP/$repo" >/dev/null
    git -C "$TMP/$repo" config user.name Test
    git -C "$TMP/$repo" config user.email test@example.invalid
    printf '%s\n' initial >"$TMP/$repo/README.md"
    git -C "$TMP/$repo" add README.md
    git -C "$TMP/$repo" commit -m initial >/dev/null
    git -C "$TMP/$repo" config --unset user.name
    git -C "$TMP/$repo" config --unset user.email
done
mkdir -p "$TMP/config" "$TMP/state"
cat >"$TMP/config/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ollama/devstral-small-2-32k",
  "enabled_providers": ["ollama"],
  "autoupdate": false,
  "share": "disabled",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (operator configured)",
      "options": { "baseURL": "http://host.containers.internal:11434/v1" },
      "models": {
        "devstral-small-2-32k": {
          "name": "devstral-small-2-32k",
          "limit": { "context": 32768, "output": 8192 }
        }
      }
    }
  },
  "permission": {
    "*": "allow",
    "question": "deny",
    "task": "deny",
    "webfetch": "allow",
    "websearch": "allow",
    "external_directory": { "/workspace/commitment-lab/**": "allow" },
    "bash": { "*": "allow", "git push": "deny", "git push *": "deny", "gh": "deny", "gh *": "deny" }
  }
}
EOF
printf '%s\n' commitment-fake-token >"$TMP/commitment-github-token"
printf '%s\n' lab-fake-token >"$TMP/lab-github-token"

podman run --http-proxy=false --rm --network=none \
    -v "$TMP/config/opencode.json:/home/commitment/.config/opencode/opencode.json:ro,Z" \
    "$IMAGE" opencode debug config | jq -e '.model == "ollama/devstral-small-2-32k" and .permission.question == "deny" and .permission.task == "deny" and .provider.ollama.models["devstral-small-2-32k"].limit.context == 32768 and .provider.ollama.models["devstral-small-2-32k"].limit.output == 8192' >/dev/null
printf 'ok - OpenCode accepts the generated provider and permission configuration\n'

podman create --http-proxy=false --name "$C1" \
    --add-host=host.containers.internal:host-gateway \
    --security-opt=no-new-privileges \
    -v "$TMP/commitment:/workspace/commitment:rw,Z" \
    -v "$TMP/lab:/workspace/commitment-lab:rw,Z" \
    -v "$TMP/config/opencode.json:/home/commitment/.config/opencode/opencode.json:ro,Z" \
    -v "$TMP/state:/home/commitment/.local/share/opencode:rw,Z" \
    --env GIT_AUTHOR_NAME='Creative Author' \
    --env GIT_AUTHOR_EMAIL=creative@example.invalid \
    --env GIT_COMMITTER_NAME='Creative Author' \
    --env GIT_COMMITTER_EMAIL=creative@example.invalid \
    -w /workspace/commitment "$IMAGE" sh -c '
        test -d /workspace/commitment/.git
        test -d /workspace/commitment-lab/.git
        test ! -e /run/podman/podman.sock
        test ! -e /home/commitment/.ssh
        test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${COMMITMENT_GITHUB_TOKEN_FILE:-}${LAB_GITHUB_TOKEN_FILE:-}"
        printf "%s\n" "#!/bin/sh" "printf first" > /workspace/commitment-lab/probe
        chmod +x /workspace/commitment-lab/probe
        test "$(/workspace/commitment-lab/probe)" = first
        sed -i s/first/revised/ /workspace/commitment-lab/probe
        test "$(/workspace/commitment-lab/probe)" = revised
        printf changed > /workspace/commitment/from-container
        git -C /workspace/commitment add from-container
        git -C /workspace/commitment commit -m creative-commit >/dev/null
        git -C /workspace/commitment-lab add probe
        git -C /workspace/commitment-lab commit -m creative-lab-commit >/dev/null
        git -C /workspace/commitment config commitment.agent-writable true
        printf state > /home/commitment/.local/share/opencode/survives
    ' >/dev/null

mounts=$(podman inspect "$C1" --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}')
podman inspect "$C1" | jq -e '.[0].HostConfig.Privileged == false and .[0].HostConfig.NetworkMode != "host" and ((.[0].HostConfig.Devices // []) | length) == 0' >/dev/null
podman inspect "$C1" | jq -e 'all(.[0].Mounts[];
    .Destination | IN("/workspace/commitment", "/workspace/commitment-lab",
        "/home/commitment/.config/opencode/opencode.json", "/home/commitment/.local/share/opencode"))' >/dev/null
for intended in "$TMP/commitment" "$TMP/lab" "$TMP/config/opencode.json" "$TMP/state"; do
    grep -Fq "$intended ->" <<<"$mounts"
done
! grep -Fq "$HOME ->" <<<"$mounts"
! grep -Fq "$TMP/commitment-github-token" <<<"$mounts"
! grep -Fq "$TMP/lab-github-token" <<<"$mounts"
podman start --attach "$C1" >/dev/null
podman rm "$C1" >/dev/null
for repo in commitment lab; do
    [[ $(git -C "$TMP/$repo" log -1 --format='%an|%ae|%cn|%ce') == \
        'Creative Author|creative@example.invalid|Creative Author|creative@example.invalid' ]]
    [[ -z $(git -C "$TMP/$repo" config --local --get user.name || true) ]]
    [[ -z $(git -C "$TMP/$repo" config --local --get user.email || true) ]]
done
printf 'ok - configured author and committer identity applies in both workspaces without local identity configuration\n'

podman run --http-proxy=false --rm --name "$C2" \
    --network=none \
    -v "$TMP/commitment:/workspace/commitment:rw,Z" \
    -v "$TMP/lab:/workspace/commitment-lab:rw,Z" \
    -v "$TMP/state:/home/commitment/.local/share/opencode:rw,Z" \
    "$IMAGE" sh -c '
        test "$(/workspace/commitment-lab/probe)" = revised
        test "$(cat /workspace/commitment/from-container)" = changed
        test "$(git -C /workspace/commitment config commitment.agent-writable)" = true
        test "$(cat /home/commitment/.local/share/opencode/survives)" = state
    '
printf 'ok - intended mounts only, no credential/socket, both workspaces writable, execution/revision and recreation persistence\n'

COMMITMENT_TEST_IMAGE="$IMAGE" "$ROOT/tests/git-boundary.sh"
COMMITMENT_TEST_IMAGE="$IMAGE" "$ROOT/tests/secrets-container.sh"
COMMITMENT_TEST_IMAGE="$IMAGE" bash "$ROOT/tests/proxy-environment.sh"
