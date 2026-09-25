#!/usr/bin/env bash
set -euo pipefail

RESOURCE_FILE="/tmp/commitment-resources-$$"

session_start_time=$(date +%s)
echo "start_time:$session_start_time" > "$RESOURCE_FILE"
echo "cpu_start:" >> "$RESOURCE_FILE"
echo "memory_start:" >> "$RESOURCE_FILE"

# Record initial CPU usage
cpu_start=$(grep "cpu " /proc/stat | awk '{print $2+$3+$4+$5+$6+$7+$8}')
echo "$cpu_start" >> "$RESOURCE_FILE"

# Record initial memory usage
mem_free=$(grep MemFree /proc/meminfo | awk '{print $2}')
emAvailable=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
echo "$mem_free $memAvailable" >> "$RESOURCE_FILE"

# Cleanup function
trap "rm -f \"$RESOURCE_FILE\"" EXIT

echo "Resource tracker initialized for session $$"
echo "Resource file: $RESOURCE_FILE"

# Wait for termination
sleep infinity
