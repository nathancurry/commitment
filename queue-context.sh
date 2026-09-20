#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}
[[ -d $repo/queue ]] || exit 0

# Queue files
while IFS= read -r -d '' item; do
    printf 'Queue file: %q\n' "${item#"$repo/"}"
done < <(find "$repo/queue" -maxdepth 1 -type f ! -name README.md -print0 | LC_ALL=C sort -z)

# Agenda items
if [[ -f "$repo/inbox/agenda.md" ]]; then
    printf '\n'  # Separator
    printf 'Agenda items from inbox/agenda.md:\n'
    grep -A 1000 "## Active Agenda Items" "$repo/inbox/agenda.md" | grep -B 1000 "## Completed Items" | tail -n +3 | head -n -3 | sed 's/^/  /'
fi
