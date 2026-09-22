#!/usr/bin/env bash
set -euo pipefail

# Test morning report generation

REPO_PATH="/workspace/commitment"
OUTCOME="CHECKPOINT_UNFINISHED"
SUMMARY="Test overnight session with agenda items"

echo "Testing morning report generation..."
./inbox-context.sh "$REPO_PATH" > /dev/null 2>>/var/tmp/inbox-context-test.log

echo "Testing generate_morning_report function..."

# Call the generate_morning_report function directly
 if [ -f "/workspace/commitment/inbox-context.sh" ]; then
    # Source the functions - the repo param check happens when executed but we're just sourcing
    . /workspace/commitment/inbox-context.sh "$REPO_PATH" 2>/dev/null || true
    echo ""
    echo "===== MORNING REPORT TEST OUTPUT ====="
    echo ""
    generate_morning_report "$OUTCOME" "$SUMMARY" "$REPO_PATH"
    echo ""
    echo "===== END OF TEST ====="
    echo ""
    echo "Test completed successfully"
 fi




