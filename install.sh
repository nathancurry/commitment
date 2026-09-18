#!/usr/bin/env bash
set -euo pipefail

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

enable=false
case ${1:-} in
    '') ;;
    --enable) enable=true ;;
    *) die "usage: $0 [--enable]" ;;
esac

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
CONFIG_DIR="$CONFIG_HOME/commitment"
CONFIG_FILE="$CONFIG_DIR/config.env"
STATE_DIR="$DATA_HOME/commitment"
LIBEXEC_DIR="$HOME/.local/libexec/commitment"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$CONFIG_HOME/systemd/user"

for command in podman git jq flock timeout systemctl readlink python3; do
    command -v "$command" >/dev/null || die "required command not found: $command"
done
[[ $(podman info --format '{{.Host.Security.Rootless}}') == true ]] || die "Podman must run rootless"

mkdir -p "$CONFIG_DIR" "$STATE_DIR/opencode-config" "$STATE_DIR/opencode-data" "$LIBEXEC_DIR" "$BIN_DIR" "$UNIT_DIR"
chmod 700 "$CONFIG_DIR" "$STATE_DIR"

if [[ ! -e $CONFIG_FILE ]]; then
    lab_default=$(dirname -- "$SOURCE_DIR")/commitment-lab
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            COMMITMENT_REPO=*) printf 'COMMITMENT_REPO=%q\n' "$SOURCE_DIR" ;;
            LAB_REPO=*) printf 'LAB_REPO=%q\n' "$lab_default" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <"$SOURCE_DIR/config.example.env" >"$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    note "Created $CONFIG_FILE"
else
    note "Preserved $CONFIG_FILE"
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"
ALLOW_SUBAGENTS=${ALLOW_SUBAGENTS-false}
[[ -n ${CONTAINER_IMAGE:-} ]] || die "CONTAINER_IMAGE is required in $CONFIG_FILE"
[[ -n ${SCHEDULE:-} && $SCHEDULE != *$'\n'* ]] || die "SCHEDULE must be a one-line systemd calendar expression"
for name in OLLAMA_CONTEXT OLLAMA_OUTPUT; do
    [[ -n ${!name:-} ]] || die "$name is required in $CONFIG_FILE"
    [[ ${!name} =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer"
done
[[ $ALLOW_SUBAGENTS == true || $ALLOW_SUBAGENTS == false ]] || die "ALLOW_SUBAGENTS must be true or false"
BITWARDEN_SECRETS_ENABLED=${BITWARDEN_SECRETS_ENABLED:-false}
[[ $BITWARDEN_SECRETS_ENABLED == true || $BITWARDEN_SECRETS_ENABLED == false ]] || die "BITWARDEN_SECRETS_ENABLED must be true or false"
if [[ $BITWARDEN_SECRETS_ENABLED == true ]]; then
    [[ ! -L "$LIBEXEC_DIR/secrets-venv" ]] || die "SDK environment must not be a symlink"
    (umask 077; python3 -I -m venv "$LIBEXEC_DIR/secrets-venv") ||
        die "Python venv/ensurepip is required for the host secret SDK"
    chmod 700 "$LIBEXEC_DIR/secrets-venv"
    "$LIBEXEC_DIR/secrets-venv/bin/python" -I -m pip --isolated install \
        --only-binary=:all: --disable-pip-version-check --no-cache-dir \
        -r "$SOURCE_DIR/requirements-secrets.txt"
    "$LIBEXEC_DIR/secrets-venv/bin/python" -I -c 'from bitwarden_sdk import BitwardenClient' ||
        die "official Bitwarden SDK cannot be imported by the trusted interpreter"
fi

if [[ ${COMMITMENT_SKIP_BUILD:-0} != 1 ]]; then
    podman build -t "$CONTAINER_IMAGE" -f "$SOURCE_DIR/Containerfile" "$SOURCE_DIR"
fi

install -m 0755 "$SOURCE_DIR/run.sh" "$LIBEXEC_DIR/run.sh"
install -m 0755 "$SOURCE_DIR/publish.sh" "$LIBEXEC_DIR/publish.sh"
install -m 0755 "$SOURCE_DIR/agent-git.sh" "$LIBEXEC_DIR/agent-git.sh"
install -m 0755 "$SOURCE_DIR/session-outcome.sh" "$LIBEXEC_DIR/session-outcome.sh"
install -m 0755 "$SOURCE_DIR/commitment-log.sh" "$LIBEXEC_DIR/commitment-log.sh"
install -m 0755 "$SOURCE_DIR/inbox-context.sh" "$LIBEXEC_DIR/inbox-context.sh"
install -m 0755 "$SOURCE_DIR/queue-context.sh" "$LIBEXEC_DIR/queue-context.sh"
install -m 0755 "$SOURCE_DIR/secret-broker.py" "$LIBEXEC_DIR/secret-broker.py"
install -m 0755 "$SOURCE_DIR/commitment-secret.py" "$LIBEXEC_DIR/commitment-secret.py"
install -m 0755 "$SOURCE_DIR/planner-broker.py" "$LIBEXEC_DIR/planner-broker.py"
install -m 0755 "$SOURCE_DIR/commitment-plan.py" "$LIBEXEC_DIR/commitment-plan.py"
install -m 0644 "$SOURCE_DIR/requirements-secrets.txt" "$LIBEXEC_DIR/requirements-secrets.txt"
install -m 0644 "$SOURCE_DIR/prompt.txt" "$LIBEXEC_DIR/prompt.txt"
ln -sfn "$LIBEXEC_DIR/run.sh" "$BIN_DIR/commitment"

install -m 0644 "$SOURCE_DIR/systemd/commitment.service.in" "$UNIT_DIR/commitment.service"
escaped_schedule=${SCHEDULE//\\/\\\\}
escaped_schedule=${escaped_schedule//&/\\&}
escaped_schedule=${escaped_schedule//|/\\|}
sed "s|@SCHEDULE@|$escaped_schedule|" "$SOURCE_DIR/systemd/commitment.timer.in" >"$UNIT_DIR/commitment.timer"
chmod 644 "$UNIT_DIR/commitment.timer"
systemctl --user daemon-reload

if $enable; then
    systemctl --user enable --now commitment.timer
fi

note ""
note "Installed trusted runtime: $LIBEXEC_DIR"
note "Configuration: $CONFIG_FILE"
note "OpenCode state: $STATE_DIR/opencode-data"
note "Optional planner key: $CONFIG_DIR/cheaperinference-api-key"
note ""
note "Next steps:"
note "  1. Edit $CONFIG_FILE and verify both repositories, trusted upstream URLs, and primary branches."
note "  2. Manual run: $BIN_DIR/commitment"
if ! $enable; then
    note "  3. Enable schedule: systemctl --user enable --now commitment.timer"
fi
note "  Logs: journalctl --user -u commitment.service"
note "For runs while logged out, an administrator may enable lingering with: loginctl enable-linger $USER"
