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
printf '%s\n' 'Merely surfacing or reading an item is not meaningful evaluation and does not force a change. Meaningful evaluation begins when you select an actionable item as active work, research it specifically, investigate its next step, reason whether to pursue it, or start derived work.'
printf '%s\n' 'Before concluding after meaningful evaluation, update that same item with a lifecycle transition or substantive same-status evidence, findings, value/next-step refinement, or progress/disposition note. Timestamp-only or formatting churn is insufficient; selected/evaluated plus byte-identical plus NOOP is prohibited.'
printf '%s\n' 'You may leave unselected items unchanged and may select one without mutating every actionable item. Candidate-specific research is allowed before generic outward discovery, but its conclusion must feed back into the selected item.'
