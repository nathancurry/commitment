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
OUTCOME_HELPER=${COMMITMENT_OUTCOME_HELPER:-"$RUNTIME_DIR/session-outcome.sh"}
LOG_HELPER=${COMMITMENT_LOG_HELPER:-"$RUNTIME_DIR/commitment-log.sh"}

[[ -r "$CONFIG_FILE" ]] || die "configuration not found: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
# The machine token is read only by the dedicated host broker from its file.
unset BWS_ACCESS_TOKEN
BITWARDEN_SECRETS_ENABLED=${BITWARDEN_SECRETS_ENABLED:-false}
[[ $BITWARDEN_SECRETS_ENABLED == true || $BITWARDEN_SECRETS_ENABLED == false ]] || die "BITWARDEN_SECRETS_ENABLED must be true or false"

for name in COMMITMENT_REPO COMMITMENT_BRANCH COMMITMENT_UPSTREAM_URL LAB_REPO LAB_BRANCH LAB_UPSTREAM_URL OLLAMA_ENDPOINT OLLAMA_MODEL OLLAMA_CONTEXT OLLAMA_OUTPUT SESSION_TIMEOUT PUBLISH_MODE CONTAINER_IMAGE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL; do
    [[ -n ${!name:-} ]] || die "$name is required in $CONFIG_FILE"
done
ALLOW_SUBAGENTS=${ALLOW_SUBAGENTS-false}
GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}
GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}
[[ $OLLAMA_CONTEXT =~ ^[1-9][0-9]*$ ]] || die "OLLAMA_CONTEXT must be a positive integer"
[[ $OLLAMA_OUTPUT =~ ^[1-9][0-9]*$ ]] || die "OLLAMA_OUTPUT must be a positive integer"
[[ $SESSION_TIMEOUT =~ ^[1-9][0-9]*$ ]] || die "SESSION_TIMEOUT must be a positive integer"
[[ $ALLOW_SUBAGENTS == true || $ALLOW_SUBAGENTS == false ]] || die "ALLOW_SUBAGENTS must be true or false"
[[ $PUBLISH_MODE == checkpoint || $PUBLISH_MODE == push ]] || die "PUBLISH_MODE must be checkpoint or push"
[[ -d "$COMMITMENT_REPO/.git" ]] || die "not a Git repository: $COMMITMENT_REPO"
[[ -d "$LAB_REPO/.git" ]] || die "not a Git repository: $LAB_REPO"
[[ -x "$PUBLISHER" ]] || die "trusted publisher not installed: $PUBLISHER"
[[ -x "$OUTCOME_HELPER" ]] || die "session outcome helper not installed: $OUTCOME_HELPER"
[[ -x "$LOG_HELPER" ]] || die "runlog helper not installed: $LOG_HELPER"

mkdir -p -m 700 "$STATE_DIR" "$STATE_DIR/opencode-config" "$STATE_DIR/opencode-data"
# Cleanup takes the same lock before inspecting residue; active sessions win.
python3 -I "$RUNTIME_DIR/secret-broker.py" --cleanup "$STATE_DIR" ||
    die "unsafe secret runtime state; check ownership and permissions"
exec 9>"$STATE_DIR/run.lock"
flock -n 9 || die "another run is active"
COMMITMENT_SESSION_ID="$(date +'%Y%m%dT%H%M%S%z')-$$"

for value in "$COMMITMENT_REPO" "$LAB_REPO" "$STATE_DIR"; do
    [[ $value == /* ]] || die "repository and state paths must be absolute"
done
[[ $COMMITMENT_REPO != "$LAB_REPO" ]] || die "repository paths must differ"
if [[ $BITWARDEN_SECRETS_ENABLED == true ]]; then
    command -v python3 >/dev/null || die "secret capability requires host Python 3"
    BITWARDEN_SECRETS_TOKEN_FILE=${BITWARDEN_SECRETS_TOKEN_FILE:-$CONFIG_HOME/commitment/bitwarden-secrets-token}
    # Reject misplaced credential paths before even the uncredentialed Git helper
    # mounts a repository. This checks paths only; it never reads token contents.
    python3 -I "$RUNTIME_DIR/secret-broker.py" --check-paths "$BITWARDEN_SECRETS_TOKEN_FILE" \
        "$COMMITMENT_REPO" "$LAB_REPO" "$STATE_DIR/opencode-config" "$STATE_DIR/opencode-data" ||
        die "Bitwarden token path must stay outside all creative mounts"
fi

"$PUBLISHER" sync commitment
"$PUBLISHER" sync lab
commitment_base=$(COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" "$PUBLISHER" session-head commitment)
lab_base=$(COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" "$PUBLISHER" session-head lab)

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
task_permission=deny
[[ $ALLOW_SUBAGENTS == true ]] && task_permission=allow

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
    "task": "$task_permission",
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
COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" "$PUBLISHER" session-start commitment

continue_args=()
if [[ ${CONTINUE_SESSION:-false} == true && -e "$STATE_DIR/session-started" ]]; then
    continue_args=(--continue)
fi

container_name="commitment-session-$$"
secret_args=()
secret_pid=''
secret_directory=''
cleanup_secrets() {
    if [[ -n $secret_pid ]]; then
        kill -TERM "$secret_pid" 2>/dev/null || true
        # A native SDK call may delay Python signal handling. Bound shutdown
        # without logging backend data or depending on SDK responsiveness.
        for (( secret_wait=0; secret_wait<30; secret_wait++ )); do
            kill -0 "$secret_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$secret_pid" 2>/dev/null || true
        wait "$secret_pid" 2>/dev/null || true
        secret_pid=''
    fi
    if [[ -n $secret_directory ]]; then
        rm -f -- "$secret_directory/request" "$secret_directory/response" "$secret_directory/lock"
        rmdir -- "$secret_directory" 2>/dev/null || true
        secret_directory=''
    fi
}
trap cleanup_secrets EXIT
stop_session() {
    if [[ -n ${agent_pid:-} ]]; then
        kill -TERM "$agent_pid" 2>/dev/null || true
        wait "$agent_pid" 2>/dev/null || true
        podman rm -f "$container_name" >/dev/null 2>&1 || true
    fi
    exit "$1"
}
trap 'stop_session 143' TERM
trap 'stop_session 130' INT
[[ -x "$RUNTIME_DIR/commitment-secret.py" ]] || die "secret client not installed; reinstall trusted runtime"
if [[ $BITWARDEN_SECRETS_ENABLED == true ]]; then
    command -v python3 >/dev/null || die "secret capability requires host Python 3"
    [[ -x "$RUNTIME_DIR/secrets-venv/bin/python" ]] || die "secret SDK environment missing; reinstall trusted runtime"
    secret_directory=$(mktemp -d "$STATE_DIR/secrets-session.XXXXXX")
    BITWARDEN_SECRETS_ENABLED=true \
        BITWARDEN_PROJECT_ID="${BITWARDEN_PROJECT_ID:-}" \
        BITWARDEN_SECRETS_TOKEN_FILE="${BITWARDEN_SECRETS_TOKEN_FILE:-$CONFIG_HOME/commitment/bitwarden-secrets-token}" \
        "$RUNTIME_DIR/secrets-venv/bin/python" -IB "$RUNTIME_DIR/secret-broker.py" "$secret_directory" "$$" \
        "$COMMITMENT_REPO" "$LAB_REPO" "$STATE_DIR/opencode-config" "$STATE_DIR/opencode-data" &
    secret_pid=$!
    for (( attempt=0; attempt<300; attempt++ )); do
        [[ -f "$secret_directory/lock" ]] && break
        kill -0 "$secret_pid" 2>/dev/null || die "secret broker startup failed"
        sleep 0.1
    done
    [[ -f "$secret_directory/lock" ]] || die "secret broker startup timed out"
    secret_args=(-v "$secret_directory:/run/commitment-secrets:ro,Z")
fi
container_args=(run --http-proxy=false --rm --name "$container_name"
    --add-host=host.containers.internal:host-gateway
    --security-opt=no-new-privileges
    --pids-limit=512
    --memory=8g
    --cpus=4
    -v "$COMMITMENT_REPO:/workspace/commitment:rw,Z"
    -v "$LAB_REPO:/workspace/commitment-lab:rw,Z"
    -v "$STATE_DIR/opencode-config/opencode.json:/home/commitment/.config/opencode/opencode.json:ro,Z"
    -v "$STATE_DIR/opencode-data:/home/commitment/.local/share/opencode:rw,Z"
    -v "$OUTCOME_HELPER:/usr/local/bin/commitment-outcome:ro,Z"
    -v "$LOG_HELPER:/usr/local/bin/commitment-log:ro,Z"
    -v "$RUNTIME_DIR/commitment-secret.py:/usr/local/bin/commitment-secret:ro,Z"
    "${secret_args[@]}"
    -w /workspace/commitment
    -e HOME=/home/commitment
    -e XDG_CONFIG_HOME=/home/commitment/.config
    -e XDG_DATA_HOME=/home/commitment/.local/share
    -e OPENCODE_ENABLE_EXA=1
    -e COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID"
    -e COMMITMENT_ROOT=/workspace/commitment
    -e COMMITMENT_OUTCOME_FILE=/workspace/commitment/.git/commitment-session-outcome
    -e GIT_AUTHOR_NAME="$GIT_AUTHOR_NAME"
    -e GIT_AUTHOR_EMAIL="$GIT_AUTHOR_EMAIL"
    -e GIT_COMMITTER_NAME="$GIT_COMMITTER_NAME"
    -e GIT_COMMITTER_EMAIL="$GIT_COMMITTER_EMAIL"
    "$CONTAINER_IMAGE" opencode run "${continue_args[@]}" --model "ollama/$OLLAMA_MODEL" "$prompt")

note "starting OpenCode session (timeout ${SESSION_TIMEOUT}s)"
agent_status=0
outcome_recorded=false
timeout --signal=TERM --kill-after=30 "$SESSION_TIMEOUT" podman "${container_args[@]}" &
agent_pid=$!
while kill -0 "$agent_pid" 2>/dev/null; do
    if COMMITMENT_ROOT="$COMMITMENT_REPO" COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" \
        "$OUTCOME_HELPER" --read >/dev/null 2>&1; then
        outcome_recorded=true
        note "trusted session outcome recorded; stopping OpenCode"
        podman stop --time 5 "$container_name" >/dev/null 2>&1 || true
        if kill -0 "$agent_pid" 2>/dev/null; then
            kill -TERM "$agent_pid" 2>/dev/null || true
        fi
        break
    fi
    sleep 0.5
done
wait "$agent_pid" || agent_status=$?
podman rm -f "$container_name" >/dev/null 2>&1 || true
cleanup_secrets
if (( agent_status != 125 && agent_status != 126 && agent_status != 127 )); then
    touch "$STATE_DIR/session-started"
fi

if outcome=$(COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" "$PUBLISHER" session-outcome commitment); then
    outcome_recorded=true
else
    outcome_recorded=false
fi

if ! $outcome_recorded && (( agent_status != 0 )); then
    failure_summary="OpenCode exited with status $agent_status"
    COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" AGENT_FAILURE_SUMMARY="$failure_summary" \
        "$PUBLISHER" session-failure commitment || true
    AGENT_EXIT_STATUS=$agent_status "$PUBLISHER" checkpoint commitment || true
    AGENT_EXIT_STATUS=$agent_status "$PUBLISHER" checkpoint lab || true
    note "$failure_summary; work was checkpointed where possible; nothing was published"
    exit "$agent_status"
elif ! $outcome_recorded; then
    failure_summary="OpenCode exited without a valid session outcome"
    COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" AGENT_FAILURE_SUMMARY="$failure_summary" \
        "$PUBLISHER" session-failure commitment || true
    AGENT_EXIT_STATUS=1 "$PUBLISHER" checkpoint commitment || true
    AGENT_EXIT_STATUS=1 "$PUBLISHER" checkpoint lab || true
    die "$failure_summary; work was checkpointed where possible and nothing was published"
fi

finalize_failed=0
commitment_result=''
lab_result=''
if ! commitment_result=$(COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" AGENT_EXIT_STATUS=0 \
    AGENT_BASE_HEAD="$commitment_base" AGENT_OUTCOME="$outcome" "$PUBLISHER" finalize commitment); then
    finalize_failed=1
fi
if ! lab_result=$(COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" AGENT_EXIT_STATUS=0 \
    AGENT_BASE_HEAD="$lab_base" AGENT_OUTCOME="$outcome" "$PUBLISHER" finalize lab); then
    finalize_failed=1
fi
if [[ $outcome == COMMITTED_CHANGE && $commitment_result != *substantive=1* && $lab_result != *substantive=1* ]]; then
    finalize_failed=1
fi
if (( finalize_failed != 0 )); then
    failure_summary="Session outcome did not match repository state"
    COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" AGENT_FAILURE_SUMMARY="$failure_summary" \
        "$PUBLISHER" session-failure commitment || true
    AGENT_EXIT_STATUS=1 "$PUBLISHER" checkpoint commitment || true
    AGENT_EXIT_STATUS=1 "$PUBLISHER" checkpoint lab || true
    die "$failure_summary; work was checkpointed where possible and nothing was published"
fi

if [[ $outcome == FAILED ]]; then
    note "session reported FAILED; work was checkpointed and nothing was published"
    exit 1
fi

if [[ $PUBLISH_MODE == push ]]; then
    if ! "$PUBLISHER" push commitment; then
        failure_summary="Commitment publication failed"
        COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" AGENT_FAILURE_SUMMARY="$failure_summary" \
            "$PUBLISHER" session-failure commitment || true
        AGENT_EXIT_STATUS=1 "$PUBLISHER" checkpoint commitment || true
        die "commitment push failed; local commits preserved"
    fi
    if ! "$PUBLISHER" push lab; then
        failure_summary="Lab publication failed"
        COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" AGENT_FAILURE_SUMMARY="$failure_summary" \
            "$PUBLISHER" session-failure commitment || true
        AGENT_EXIT_STATUS=1 "$PUBLISHER" checkpoint commitment || true
        die "lab push failed; local commits preserved"
    fi
fi

note "session completed with outcome $outcome in $PUBLISH_MODE mode"
