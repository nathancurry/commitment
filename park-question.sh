#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}
[[ -d "$repo/parked-questions" ]] || mkdir -p "$repo/parked-questions"

# Create parked question file
question_file="$repo/parked-questions/$(date +%Y%m%d-%H%M%S)-parked.md"

cat > "$question_file" <<EOF
timeparked: $(date -Iseconds)
question: ${@:2}
status: awaiting Clarke
EOF

printf "Parked question saved to: parked-questions/%s\n" "${question_file#"$repo/"}"
