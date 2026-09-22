#!/usr/bin/env bash
set -euo pipefail

# Morning report generator for long-running sessions

INBOX_CONTEXT_SCRIPT="/workspace/commitment/inbox-context.sh"
REPO_PATH="${COMMITMENT_REPO:-$COMMITMENT_ROOT}"
REPO_PATH="${REPO_PATH:-.}"

if [[ ! -f "$INBOX_CONTEXT_SCRIPT" ]]; then
    echo "ERROR: Inbox context script not found at $INBOX_CONTEXT_SCRIPT" >>2
    exit 1
fi

# Source the functions - provide the repo path as argument
source "$INBOX_CONTEXT_SCRIPT" "$REPO_PATH"

OUTCOME="${1:-CHECKPOINT_UNFINISHED}"
SUMMARY="${2:-Session morning report}"

# Generate and output the morning report
generate_morning_report "$OUTCOME" "$SUMMARY" "$REPO_PATH"
