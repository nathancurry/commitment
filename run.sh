#!/usr/bin/env bash
set -euo pipefail

die() { printf 'commitment: %s\n' "$*" >&2; exit 1; }
note() { printf 'commitment: %s\n' "$*" >&2; }

CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
CONFIG_FILE=${COMMITMENT_CONFIG:-"$CONFIG_HOME/commitment/config.env"}
STATE_DIR=${COMMITMENT_STATE_DIR:-"$DATA_HOME/commitment"}
runtime_path=$(readlink -f -- "$0")
RUNTIME_DIR=$(CDPATH= cd -- "$(dirname -- "$runtime_path")" && pwd)
PUBLISHER=${COMMITMENT_PUBLISHER:-"$RUNTIME_DIR/publish.sh"}

[[ -r "$CONFIG_FILE" ]] || die "configuration not found: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

for name in COMMITMENT_REPO COMMITMENT_BRANCH COMMITMENT_UPSTREAM_URL LAB_REPO LAB_BRANCH LAB_UPSTREAM_URL OLLAMA_ENDPOINT OLLAMA_MODEL OLLAMA_CONTEXT OLLAMA_OUTPUT SESSION_TIMEOUT PUBLISH_MODE CONTAINER_IMAGE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL; do
    [[ -n ${!name:-} ]] || die "$name is required in $CONFIG_FILE"
done
GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}
GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}
[[ $OLLAMA_CONTEXT =~ ^[1-9][0-9]*$ ]] || die "OLLAMA_CONTEXT must be a positive integer"
[[ $OLLAMA_OUTPUT =~ ^[1-9][0-9]*$ ]] || die "OLLAMA_OUTPUT must be a positive integer"
[[ $SESSION_TIMEOUT =~ ^[1-9][0-9]*$ ]] || die "SESSION_TIMEOUT must be a positive integer"
[[ $PUBLISH_MODE == checkpoint || $PUBLISH_MODE == push ]] || die "PUBLISH_MODE must be checkpoint or push"
[[ -d "$COMMITMENT_REPO/.git" ]] || die "not a Git repository: $COMMITMENT_REPO"
[[ -d "$LAB_REPO/.git" ]] || die "not a Git repository: $LAB_REPO"
[[ -x "$PUBLISHER" ]] || die "trusted publisher not installed: $PUBLISHER"

mkdir -p "$STATE_DIR" "$STATE_DIR/opencode-config" "$STATE_DIR/opencode-data"
exec 9>"$STATE_DIR/run.lock"
flock -n 9 || die "another run is active"
COMMITMENT_SESSION_ID="$(date +'%Y%m%dT%H%M%S%z')-$$"

for value in "$COMMITMENT_REPO" "$LAB_REPO" "$STATE_DIR"; do
    [[ $value == /* ]] || die "repository and state paths must be absolute"
done
[[ $COMMITMENT_REPO != "$LAB_REPO" ]] || die "repository paths must differ"

"$PUBLISHER" sync commitment
"$PUBLISHER" sync lab

json_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    printf '%s' "$value"
}

endpoint=${OLLAMA_ENDPOINT%/}
[[ $endpoint == */v1 ]] || endpoint="$endpoint/v1"
endpoint_json=$(json_escape "$endpoint")
model_json=$(json_escape "$OLLAMA_MODEL")

tmp_config=$(mktemp "$STATE_DIR/opencode-config/opencode.json.XXXXXX")
cat >"$tmp_config" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "ollama/$model_json",
  "enabled_providers": ["ollama"],
  "autoupdate": false,
  "share": "disabled",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (operator configured)",
      "options": { "baseURL": "$endpoint_json" },
      "models": {
        "$model_json": {
          "name": "$model_json",
          "limit": {
            "context": $OLLAMA_CONTEXT,
            "output": $OLLAMA_OUTPUT
          }
        }
      }
    }
  },
  "permission": {
    "*": "allow",
    "question": "deny",
    "webfetch": "allow",
    "websearch": "allow",
    "external_directory": { "/workspace/commitment-lab/**": "allow" },
    "bash": {
      "*": "allow",
      "git push": "deny",
      "git push *": "deny",
      "gh": "deny",
      "gh *": "deny"
    }
  }
}
EOF
chmod 600 "$tmp_config"
mv -f "$tmp_config" "$STATE_DIR/opencode-config/opencode.json"

prompt_file="$RUNTIME_DIR/prompt.txt"
[[ -r "$prompt_file" ]] || die "session prompt not found: $prompt_file"
prompt=$(<"$prompt_file")

continue_args=()
if [[ ${CONTINUE_SESSION:-true} == true && -e "$STATE_DIR/session-started" ]]; then
    continue_args=(--continue)
fi

container_name="commitment-session-$$"
container_args=(run --rm --name "$container_name"
    --add-host=host.containers.internal:host-gateway
    --security-opt=no-new-privileges
    --pids-limit=512
    --memory=8g
    --cpus=4
    -v "$COMMITMENT_REPO:/workspace/commitment:rw,Z"
    -v "$LAB_REPO:/workspace/commitment-lab:rw,Z"
    -v "$STATE_DIR/opencode-config/opencode.json:/home/commitment/.config/opencode/opencode.json:ro,Z"
    -v "$STATE_DIR/opencode-data:/home/commitment/.local/share/opencode:rw,Z"
    -w /workspace/commitment
    -e HOME=/home/commitment
    -e XDG_CONFIG_HOME=/home/commitment/.config
    -e XDG_DATA_HOME=/home/commitment/.local/share
    -e OPENCODE_ENABLE_EXA=1
    -e COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID"
    -e GIT_AUTHOR_NAME="$GIT_AUTHOR_NAME"
    -e GIT_AUTHOR_EMAIL="$GIT_AUTHOR_EMAIL"
    -e GIT_COMMITTER_NAME="$GIT_COMMITTER_NAME"
    -e GIT_COMMITTER_EMAIL="$GIT_COMMITTER_EMAIL"
    "$CONTAINER_IMAGE" opencode run "${continue_args[@]}" --model "ollama/$OLLAMA_MODEL" "$prompt")

note "starting OpenCode session (timeout ${SESSION_TIMEOUT}s)"
agent_status=0
timeout --signal=TERM --kill-after=30 "$SESSION_TIMEOUT" podman "${container_args[@]}" || agent_status=$?
podman rm -f "$container_name" >/dev/null 2>&1 || true
if (( agent_status != 125 && agent_status != 126 && agent_status != 127 )); then
    touch "$STATE_DIR/session-started"
fi

checkpoint_failed=0
AGENT_EXIT_STATUS=$agent_status "$PUBLISHER" checkpoint commitment || checkpoint_failed=1
AGENT_EXIT_STATUS=$agent_status "$PUBLISHER" checkpoint lab || checkpoint_failed=1

if (( agent_status != 0 )); then
    if (( checkpoint_failed == 0 )); then
        note "OpenCode exited with status $agent_status; checkpoint handling succeeded; nothing was published"
    else
        note "OpenCode exited with status $agent_status; checkpoint handling failed; dirty work remains preserved and nothing was published"
    fi
    exit "$agent_status"
fi
(( checkpoint_failed == 0 )) || die "session succeeded but checkpoint creation failed"

if [[ $PUBLISH_MODE == push ]]; then
    "$PUBLISHER" push commitment || die "commitment push failed; local commits preserved"
    "$PUBLISHER" push lab || die "lab push failed; local commits preserved"
fi

note "session completed in $PUBLISH_MODE mode"
