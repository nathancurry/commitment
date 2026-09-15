#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}
queue="$repo/queue"
[[ -d $queue ]] || exit 0

items=()
while IFS= read -r -d '' item; do
    items+=("$item")
done < <(find "$queue" -maxdepth 1 -type f ! -name README.md -print0 | LC_ALL=C sort -z)
((${#items[@]} > 0)) || exit 0

printf '%s\n' 'Queue items (direct files under queue/; lifecycle comes from frontmatter status, never the filename):'
for item in "${items[@]}"; do
    status=$(awk '
        NR == 1 && $0 == "---" { frontmatter = 1; next }
        frontmatter && $0 == "---" { exit }
        frontmatter && $0 ~ /^[[:space:]]*status:[[:space:]]*/ {
            sub(/^[[:space:]]*status:[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$item")
    case $status in
        candidate|researching|ready|blocked|deferred|done|rejected) ;;
        '') status=missing ;;
        *) status="invalid ($status)" ;;
    esac
    printf -- '- %q (status: %s)\n' "${item#"$repo/"}" "$status"
done
printf '%s\n' 'Inspect these items before falling through to outward research. Their presence does not require action: evaluate their content, evidence, priority, and status; blocked, deferred, done, and rejected items are not fresh actionable work.'
