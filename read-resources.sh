#!/usr/bin/env bash
set -euo pipefail

# Read resource metrics
if [[ -f "/tmp/commitment-resources-$$" ]]; then
    # Parse resource file
    while IFS=: read -r key value; do
        case $key in
            start_time) echo "$value" ;;
            cpu_start) echo "$value" ;;
            memory_start) echo "$value" ;;
        esac
    done < "/tmp/commitment-resources-$$"
else
    echo "0"  # Default values if tracking not available
fi

# Count API calls from runlog
apicount=0
if [[ -f "/workspace/commitment/runlog.jsonl" ]]; then
    apicount=$(grep -c "webfetch\|websearch" /workspace/commitment/runlog.jsonl 2>/dev/null || echo "0")
fi

echo "$apicount"
