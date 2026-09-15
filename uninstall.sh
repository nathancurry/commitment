#!/usr/bin/env bash
set -euo pipefail

CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
UNIT_DIR="$CONFIG_HOME/systemd/user"
LIBEXEC_DIR="$HOME/.local/libexec/commitment"
LAUNCHER="$HOME/.local/bin/commitment"

if command -v systemctl >/dev/null; then
    systemctl --user disable --now commitment.timer >/dev/null 2>&1 || true
    systemctl --user stop commitment.service >/dev/null 2>&1 || true
fi

rm -f "$UNIT_DIR/commitment.timer" "$UNIT_DIR/commitment.service" "$LAUNCHER"
rm -f "$LIBEXEC_DIR/run.sh" "$LIBEXEC_DIR/publish.sh" "$LIBEXEC_DIR/agent-git.sh"
rm -f "$LIBEXEC_DIR/session-outcome.sh" "$LIBEXEC_DIR/commitment-log.sh" "$LIBEXEC_DIR/inbox-context.sh" "$LIBEXEC_DIR/prompt.txt"
rm -f "$LIBEXEC_DIR/secret-broker.py" "$LIBEXEC_DIR/commitment-secret.py" "$LIBEXEC_DIR/requirements-secrets.txt"
rmdir "$LIBEXEC_DIR" 2>/dev/null || true
if command -v systemctl >/dev/null; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

printf '%s\n' "Commitment host launcher and systemd units removed."
printf '%s\n' "Preserved configuration/credentials: $CONFIG_HOME/commitment"
printf '%s\n' "Preserved OpenCode continuity and trusted Git state: $DATA_HOME/commitment"
printf '%s\n' "Preserved both repositories, generated work, and shared Podman image/storage."
printf '%s\n' "Preserved optional host SDK environment: $LIBEXEC_DIR/secrets-venv"
