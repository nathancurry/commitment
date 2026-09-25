#!/usr/bin/env bash
set -euo pipefail

# Resource tracking ledger
RESOURCE_FILE="/tmp/commitment-resources-$$"
session_start_time=$(date +%s)
session_id="${COMMITMENT_SESSION_ID:-unknown}"

# Record initial CPU usage
cpu_start=$(grep "cpu " /proc/stat | awk '{print $2+$3+$4+$5+$6+$7+$8}')

# Record initial memory usage
mem_available_start=$(grep MemAvailable /proc/meminfo | awk '{print $2}')

# Write initial state
cat > "$RESOURCE_FILE" <<EOF
session_id:$session_id
start_time:$session_start_time
cpu_start:$cpu_start
mem_available_start:$mem_available_start
EOF

# Cleanup function
trap "rm -f \"$RESOURCE_FILE\"" EXIT

echo "Resource tracker initialized for session $session_id" >>2
echo "Resource file: $RESOURCE_FILE" >>2

# Wait for termination
sleep infinity
