#!/usr/bin/env bash
set -euo pipefail

REPO_PATH="/workspace/commitment"
OUTCOME="CHECKPOINT_UNFINISHED"
SUMMARY="Test overnight session"

# First, run inbox-context.sh without arguments
./inbox-context.sh "$REPO_PATH" > /var/tmp/inbox_context_test.log 2>&1

echo "=== Running generate_morning_report ==="
echo ""

# Now source and call the function
. ./inbox-context.sh "$REPO_PATH"
generate_morning_report "$OUTCOME" "$SUMMARY" "$REPO_PATH"
echo ""
echo "=== Test completed ==="
