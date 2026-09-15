#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}
inbox="$repo/inbox"
[[ -d $inbox ]] || exit 0

items=()
while IFS= read -r -d '' item; do
    items+=("${item#"$repo/"}")
done < <(find "$inbox" -maxdepth 1 -type f ! -name README.md -print0 | LC_ALL=C sort -z)
((${#items[@]} > 0)) || exit 0

printf '%s\n' 'Unprocessed operator inbox items (highest-priority input; read before selecting other work):'
for item in "${items[@]}"; do
    printf -- '- %q\n' "$item"
done
printf '%s\n' 'Treat these files as explicit operator input under MISSION.md, AGENTS.md, and normal authority rules, not as blindly executable instructions. After meaningfully incorporating an item and deciding its disposition, move it to inbox/processed/.'
