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
INBOX_CONTEXT_HELPER="$RUNTIME_DIR/inbox-context.sh"
QUEUE_CONTEXT_HELPER="$RUNTIME_DIR/queue-context.sh"
PLANNER_BROKER="$RUNTIME_DIR/planner-broker.py"

[[ -r "$CONFIG_FILE" ]] || die "configuration not found: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
# The machine token is read only by the dedicated host broker from its file.
unset BWS_ACCESS_TOKEN
# Planner credential material is read only from its file by the dedicated host
# broker. The legacy OpenRouter variable stays unset so an operator-exported
# rollback key can never leak into children either.
unset OPENROUTER_API_KEY CHEAPERINFERENCE_API_KEY
BITWARDEN_SECRETS_ENABLED=${BITWARDEN_SECRETS_ENABLED:-false}
[[ $BITWARDEN_SECRETS_ENABLED == true || $BITWARDEN_SECRETS_ENABLED == false ]] || die "BITWARDEN_SECRETS_ENABLED must be true or false"
CHEAPERINFERENCE_API_KEY_FILE=${CHEAPERINFERENCE_API_KEY_FILE:-$CONFIG_HOME/commitment/cheaperinference-api-key}
PLANNER_MODEL=${PLANNER_MODEL:-glm-5.3}
PLANNER_REASONING=${PLANNER_REASONING:-high}
PLANNER_MAX_TOKENS=${PLANNER_MAX_TOKENS:-16384}

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

[[ -x "$INBOX_CONTEXT_HELPER" ]] || die "inbox context helper not installed: $INBOX_CONTEXT_HELPER"
[[ -x "$QUEUE_CONTEXT_HELPER" ]] || die "queue context helper not installed: $QUEUE_CONTEXT_HELPER"

mkdir -p -m 700 "$STATE_DIR" "$STATE_DIR/opencode-config" "$STATE_DIR/opencode-data"
# Cleanup takes the same lock before inspecting residue; active sessions win.
if [[ -f $RUNTIME_DIR/secret-broker.py ]]; then
    if ! python3 -I "$RUNTIME_DIR/secret-broker.py" --cleanup "$STATE_DIR"; then
        note "secret cleanup unavailable; continuing without secret access"
        BITWARDEN_SECRETS_ENABLED=false
    fi
fi
if [[ -f $PLANNER_BROKER ]]; then
    if ! python3 -I "$PLANNER_BROKER" --cleanup "$STATE_DIR"; then
        note "planner cleanup unavailable; continuing"
    fi
fi
exec 9>"$STATE_DIR/run.lock"
flock -n 9 || die "another run is active"
COMMITMENT_SESSION_ID="$(date +'%Y%m%dT%H%M%S%z')-$$"

for value in "$COMMITMENT_REPO" "$LAB_REPO" "$STATE_DIR"; do
    [[ $value == /* ]] || die "repository and state paths must be absolute"
done
[[ $COMMITMENT_REPO != "$LAB_REPO" ]] || die "repository paths must differ"
# Check placement even if secret service startup later fails. Optional capability
# failure must never make a configured host token safe to expose in a mount.
BITWARDEN_SECRETS_TOKEN_FILE=${BITWARDEN_SECRETS_TOKEN_FILE:-$CONFIG_HOME/commitment/bitwarden-secrets-token}
secret_token_path=$(readlink -m -- "$BITWARDEN_SECRETS_TOKEN_FILE")
for mount in "$COMMITMENT_REPO" "$LAB_REPO" "$STATE_DIR/opencode-config" "$STATE_DIR/opencode-data" "$STATE_DIR/outcomes"; do
    mount_path=$(readlink -m -- "$mount")
    case $secret_token_path in
        "$mount_path"|"$mount_path"/*) die "Bitwarden token path must stay outside all creative mounts" ;;
    esac
done
planner_key_path=$(readlink -m -- "$CHEAPERINFERENCE_API_KEY_FILE")
for mount in "$COMMITMENT_REPO" "$LAB_REPO" "$STATE_DIR/opencode-config" \
        "$STATE_DIR/opencode-data" "$STATE_DIR/outcomes" "$OUTCOME_HELPER" \
        "$LOG_HELPER" "$RUNTIME_DIR/commitment-secret.py" \
        "$RUNTIME_DIR/commitment-plan.py"; do
    mount_path=$(readlink -m -- "$mount")
    case $planner_key_path in
        "$mount_path"|"$mount_path"/*) die "CheaperInference key path must stay outside all creative mounts" ;;
    esac
done

for repo in commitment lab; do
    "$PUBLISHER" sync "$repo" || note "$repo synchronization unavailable; local work remains inspectable"
done
commitment_base=$("$PUBLISHER" session-head commitment)
lab_base=$("$PUBLISHER" session-head lab)

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
  "default_agent": "commitment",
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

CONTINUITY_HELPER="$RUNTIME_DIR/session-continuity.sh"
[[ -x "$CONTINUITY_HELPER" ]] || die "session continuity helper not installed: $CONTINUITY_HELPER"

prompt_file="$RUNTIME_DIR/prompt.txt"
[[ -r "$prompt_file" ]] || die "session prompt not found: $prompt_file"
prompt=$(<"$prompt_file")
queue_context=$("$QUEUE_CONTEXT_HELPER" "$COMMITMENT_REPO")
if [[ -n $queue_context ]]; then
    prompt="$queue_context"$'\n\n'"$prompt"
fi
inbox_context=$("$INBOX_CONTEXT_HELPER" "$COMMITMENT_REPO")
if [[ -n $inbox_context ]]; then
    prompt="$inbox_context"$'\n\n'"$prompt"
fi
continuity_context=$("$CONTINUITY_HELPER" "$COMMITMENT_REPO")
if [[ -n $continuity_context ]]; then
    prompt="$continuity_context"$'\n\n'"$prompt"
fi
COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID" "$PUBLISHER" session-start commitment || note "session start logging unavailable"

continue_args=()
if [[ ${CONTINUE_SESSION:-false} == true && -e "$STATE_DIR/session-started" ]]; then
    continue_args=(--continue)
fi

container_name="commitment-session-$$"
secret_args=()
secret_pid=''
secret_directory=''
planner_pid=''
planner_directory=''
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
cleanup_planner() {
    if [[ -n $planner_pid ]]; then
        kill -TERM "$planner_pid" 2>/dev/null || true
        for (( planner_wait=0; planner_wait<30; planner_wait++ )); do
            kill -0 "$planner_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$planner_pid" 2>/dev/null || true
        wait "$planner_pid" 2>/dev/null || true
        planner_pid=''
    fi
    if [[ -n $planner_directory ]]; then
        rm -f -- "$planner_directory/request" "$planner_directory/response" "$planner_directory/lock"
        rmdir -- "$planner_directory" 2>/dev/null || true
        planner_directory=''
    fi
}
mkdir -p -m 700 "$STATE_DIR/outcomes"
outcome_directory=$(mktemp -d "$STATE_DIR/outcomes/session.XXXXXX")
export COMMITMENT_OUTCOME_FILE="$outcome_directory/outcome"
export COMMITMENT_SESSION_ID
cleanup() {
    cleanup_secrets
    cleanup_planner
    rm -f -- "$outcome_directory/outcome"
    rmdir -- "$outcome_directory" 2>/dev/null || true
}
trap cleanup EXIT
interrupted=0
stop_session() {
    interrupted=$1
    if [[ -n ${agent_pid:-} ]]; then
        podman stop --time 5 "$container_name" >/dev/null 2>&1 || true
        kill -TERM "$agent_pid" 2>/dev/null || true
    fi
    # Return to the common preservation path, including when wait is interrupted.
}
trap 'stop_session 143' TERM
trap 'stop_session 130' INT
if [[ -x $RUNTIME_DIR/commitment-secret.py ]]; then
    secret_args=(-v "$RUNTIME_DIR/commitment-secret.py:/usr/local/bin/commitment-secret:ro,Z")
fi
if [[ $BITWARDEN_SECRETS_ENABLED == true && $interrupted == 0 ]]; then
    if [[ -x $RUNTIME_DIR/secrets-venv/bin/python && -f $RUNTIME_DIR/secret-broker.py && -x $RUNTIME_DIR/commitment-secret.py ]]; then
        secret_directory=$(mktemp -d "$STATE_DIR/secrets-session.XXXXXX")
        BITWARDEN_SECRETS_ENABLED=true \
            BITWARDEN_PROJECT_ID="${BITWARDEN_PROJECT_ID:-}" \
            BITWARDEN_SECRETS_TOKEN_FILE="$BITWARDEN_SECRETS_TOKEN_FILE" \
            "$RUNTIME_DIR/secrets-venv/bin/python" -IB "$RUNTIME_DIR/secret-broker.py" "$secret_directory" "$$" \
            "$COMMITMENT_REPO" "$LAB_REPO" "$STATE_DIR/opencode-config" "$STATE_DIR/opencode-data" "$outcome_directory" &
        secret_pid=$!
        for (( attempt=0; attempt<300; attempt++ )); do
            [[ -f "$secret_directory/lock" || $interrupted != 0 ]] && break
            kill -0 "$secret_pid" 2>/dev/null || break
            sleep 0.1
        done
        if [[ -f $secret_directory/lock ]]; then
            secret_args+=(-v "$secret_directory:/run/commitment-secrets:ro,Z")
        else
            note "secret broker unavailable; continuing without secret access"
            cleanup_secrets
        fi
    else
        note "secret SDK or helpers unavailable; continuing without secret access"
    fi
fi
planner_args=()
if [[ -x $RUNTIME_DIR/commitment-plan.py ]]; then
    planner_args=(-v "$RUNTIME_DIR/commitment-plan.py:/usr/local/bin/commitment-plan:ro,Z")
fi
if [[ -f $PLANNER_BROKER && -x $RUNTIME_DIR/commitment-plan.py && $interrupted == 0 ]]; then
    planner_directory=$(mktemp -d "$STATE_DIR/planner-session.XXXXXX")
    CHEAPERINFERENCE_API_KEY_FILE="$CHEAPERINFERENCE_API_KEY_FILE" \
        PLANNER_MODEL="$PLANNER_MODEL" \
        PLANNER_REASONING="$PLANNER_REASONING" \
        PLANNER_MAX_TOKENS="$PLANNER_MAX_TOKENS" \
        python3 -IB "$PLANNER_BROKER" "$planner_directory" "$$" \
        "$COMMITMENT_REPO" "$LAB_REPO" "$STATE_DIR/opencode-config" \
        "$STATE_DIR/opencode-data" "$outcome_directory" "$OUTCOME_HELPER" \
        "$LOG_HELPER" "$RUNTIME_DIR/commitment-secret.py" \
        "$RUNTIME_DIR/commitment-plan.py" &
    planner_pid=$!
    for (( attempt=0; attempt<300; attempt++ )); do
        [[ -f "$planner_directory/lock" || $interrupted != 0 ]] && break
        kill -0 "$planner_pid" 2>/dev/null || break
        sleep 0.1
    done
    if [[ -f $planner_directory/lock ]]; then
        planner_args+=(-v "$planner_directory:/run/commitment-planner:ro,Z")
    else
        note "planner broker unavailable; continuing without external planning"
        cleanup_planner
    fi
fi
log_args=()
[[ ! -x $LOG_HELPER ]] || log_args=(-v "$LOG_HELPER:/usr/local/bin/commitment-log:ro,Z")
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
    -v "$outcome_directory:/run/commitment-outcome:rw,Z"
    "${log_args[@]}"
    "${secret_args[@]}"
    "${planner_args[@]}"
    -w /workspace/commitment
    -e HOME=/home/commitment
    -e XDG_CONFIG_HOME=/home/commitment/.config
    -e XDG_DATA_HOME=/home/commitment/.local/share
    -e OPENCODE_ENABLE_EXA=1
    -e COMMITMENT_SESSION_ID="$COMMITMENT_SESSION_ID"
    -e COMMITMENT_ROOT=/workspace/commitment
    -e COMMITMENT_OUTCOME_FILE=/run/commitment-outcome/outcome
    -e GIT_AUTHOR_NAME="$GIT_AUTHOR_NAME"
    -e GIT_AUTHOR_EMAIL="$GIT_AUTHOR_EMAIL"
    -e GIT_COMMITTER_NAME="$GIT_COMMITTER_NAME"
    -e GIT_COMMITTER_EMAIL="$GIT_COMMITTER_EMAIL"
    "$CONTAINER_IMAGE" opencode run "${continue_args[@]}" --agent commitment --model "ollama/$OLLAMA_MODEL" "$prompt")

note "starting OpenCode session (timeout ${SESSION_TIMEOUT}s)"
agent_status=0
if (( interrupted == 0 )); then
    timeout --signal=TERM --kill-after=30 "$SESSION_TIMEOUT" podman "${container_args[@]}" &
    agent_pid=$!
    while kill -0 "$agent_pid" 2>/dev/null; do
        if "$OUTCOME_HELPER" --read >/dev/null 2>&1; then
            note "session outcome recorded; stopping OpenCode"
            podman stop --time 5 "$container_name" >/dev/null 2>&1 || true
            kill -TERM "$agent_pid" 2>/dev/null || true
            break
        fi
        (( interrupted == 0 )) || break
        sleep 0.5
    done
    wait "$agent_pid" || agent_status=$?
fi
# Do not snapshot while creative processes can still write. If stopping fails,
# leave the worktree intact for inspection rather than publishing a moving target.
trap '' TERM INT
podman rm -f "$container_name" >/dev/null || die "cannot stop creative container; work remains on disk"
cleanup_secrets
cleanup_planner
(( interrupted == 0 )) || agent_status=$interrupted
touch "$STATE_DIR/session-started"

summary="Session ended with process status $agent_status"
if outcome=$("$OUTCOME_HELPER" --read 2>/dev/null); then
    summary=$(jq -r .summary "$COMMITMENT_OUTCOME_FILE")
else
    changed=false
    classification_failed=false
    for repo in commitment lab; do
        base=$commitment_base
        [[ $repo != lab ]] || base=$lab_base
        if result=$(AGENT_BASE_HEAD="$base" "$PUBLISHER" classify "$repo"); then
            [[ $result != *changed=1* ]] || changed=true
        else
            classification_failed=true
        fi
    done
    if $changed; then
        outcome=CHECKPOINT_UNFINISHED
        summary="No valid outcome; changed work preserved as unfinished (exit $agent_status)"
    else
        outcome=FAILED
        summary="No valid outcome (exit $agent_status)"
        ! $classification_failed || summary="No valid outcome; Git inspection failed; work remains available"
    fi
    note "$outcome: $summary"
fi

# Outcome is the model/session result, not a claim that publication succeeded.
# Logging is best effort and cannot authorize or veto preservation.
AGENT_OUTCOME="$outcome" AGENT_SUMMARY="$summary" "$PUBLISHER" session-end commitment || note "session end logging unavailable"
finalize_failed=false
for repo in commitment lab; do
    if ! AGENT_EXIT_STATUS="$agent_status" AGENT_OUTCOME="$outcome" "$PUBLISHER" finalize "$repo"; then
        finalize_failed=true
        note "$repo could not be committed; existing files/history preserved for inspection"
    fi
done
if $finalize_failed; then
    die "preservation incomplete; nothing published"
fi
# An operator stop preserves locally and must not unexpectedly start publishing.
if (( interrupted != 0 )); then
    note "interrupted session preserved locally"
    exit "$interrupted"
fi
if [[ $outcome == FAILED ]]; then
    note "session failed; local work preserved; nothing published"
    exit 1
fi
if [[ $PUBLISH_MODE == push ]]; then
    for repo in commitment lab; do
        if ! "$PUBLISHER" push "$repo"; then
            AGENT_FAILURE_SUMMARY="$repo publication failed; local commits preserved" \
                "$PUBLISHER" session-failure commitment || true
            AGENT_EXIT_STATUS=1 "$PUBLISHER" checkpoint commitment || true
            die "$repo push failed; local commits preserved"
        fi
    done
fi
note "session completed with outcome $outcome in $PUBLISH_MODE mode"
