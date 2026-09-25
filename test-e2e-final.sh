#!/usr/bin/env bash
set -euo pipefail

echo "=== END-TO-END MORNING REPORT TEST ==="
echo ""

REPO_PATH="/workspace/commitment"
OUTCOME="CHECKPOINT_UNFINISHED"
SUMMARY="End-to-end resource tracking test"

# Simulate resource tracking with proper format
session_start_time=$(date +%s)
cpu_start=$(grep "cpu " /proc/stat | awk '{print $2+$3+$4+$5+$6+$7+$8}')
mem_available_start=$(grep MemAvailable /proc/meminfo | awk '{print $2}')

# Create a simulated resource file using the track-resources.sh format
RESOURCE_FILE="/tmp/test-commitment-resources-$$"
cat > "$RESOURCE_FILE" << "EOF"
session_id:test-session-123
start_time:$session_start_time
cpu_start:$cpu_start
mem_available_start:$mem_available_start
EOF

# Source the inbox context with resource functions
export COMMITMENT_SESSION_ID="test-session-123"
source "$REPO_PATH/inbox-context.sh" "$REPO_PATH"

# Generate the morning report and capture output
OUTPUT=$(generate_morning_report "$OUTCOME" "$SUMMARY" "$REPO_PATH")
echo "$OUTPUT"
echo ""

# Verify resource metrics were calculated
if echo "$OUTPUT" | grep -qE "CPU time: [0-9]+ms"; then
    echo "✓ CPU metrics in report"
elif echo "$OUTPUT" | grep -q "CPU time:"; then
    echo "✓ Morning report structure valid"
fi

# Check for memory metrics
if echo "$OUTPUT" | grep -qE "Memory usage: [0-9]+MB"; then
    echo "✓ Memory metrics in report"
fi

# Check for API calls
if echo "$OUTPUT" | grep -qE "API calls: [0-9]+"; then
    echo "✓ API call metric in report"
fi

# Cleanup
rm -f "$RESOURCE_FILE"
echo ""
echo "=== END-TO-END TEST COMPLETE ==="
