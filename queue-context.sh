#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}
mode=${2:-context}
queue="$repo/queue"
[[ -d $queue ]] || exit 0

items=()
while IFS= read -r -d '' item; do
    items+=("$item")
done < <(find "$queue" -maxdepth 1 -type f ! -name README.md -print0 | LC_ALL=C sort -z)
((${#items[@]} > 0)) || exit 0

parse_status() {
    local item=$1 line line_number=0 status_count=0 status_value='' closed=false

    QUEUE_STATUS=''
    QUEUE_STATUS_KIND=malformed
    QUEUE_STATUS_LABEL='malformed: missing frontmatter'
    [[ -r $item ]] || { QUEUE_STATUS_LABEL='malformed: unreadable item'; return; }

    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number += 1))
        if ((line_number == 1)); then
            [[ $line == '---' ]] || return 0
            continue
        fi
        if [[ $line == '---' ]]; then
            closed=true
            break
        fi
        if [[ $line =~ ^[[:space:]]*status[[:space:]]*:(.*)$ ]]; then
            ((status_count += 1))
            status_value=${BASH_REMATCH[1]}
            status_value=${status_value#"${status_value%%[![:space:]]*}"}
            status_value=${status_value%"${status_value##*[![:space:]]}"}
        fi
    done <"$item"

    if ! $closed; then
        QUEUE_STATUS_LABEL='malformed: unclosed frontmatter'
        return
    fi
    if ((status_count == 0)); then
        QUEUE_STATUS_LABEL='malformed: missing status'
        return
    fi
    if ((status_count > 1)); then
        QUEUE_STATUS_LABEL='malformed: duplicate status'
        return
    fi

    QUEUE_STATUS=$status_value
    case $status_value in
        candidate|researching|ready)
            QUEUE_STATUS_KIND=actionable
            QUEUE_STATUS_LABEL=$status_value
            ;;
        blocked|deferred|done|rejected)
            QUEUE_STATUS_KIND=non_actionable
            QUEUE_STATUS_LABEL=$status_value
            ;;
        '') QUEUE_STATUS_LABEL='malformed: empty status' ;;
        *) QUEUE_STATUS_LABEL='malformed: unknown status' ;;
    esac
}

case $mode in
    noop-blockers)
        for item in "${items[@]}"; do
            parse_status "$item"
            if [[ $QUEUE_STATUS_KIND == actionable || $QUEUE_STATUS_KIND == malformed ]]; then
                printf -- '  - %q (%s)\n' "${item#"$repo/"}" "$QUEUE_STATUS_LABEL"
            fi
        done
        exit 0
        ;;
    context) ;;
    *) printf 'queue-context: unsupported mode: %s\n' "$mode" >&2; exit 2 ;;
esac

printf '%s\n' 'Queue items (direct files under queue/; lifecycle comes from frontmatter status, never the filename):'
for item in "${items[@]}"; do
    parse_status "$item"
    printf -- '- %q (status: %s)\n' "${item#"$repo/"}" "$QUEUE_STATUS_LABEL"
done
printf '%s\n' 'Inspect these items before falling through to outward research. Their presence does not require action: evaluate their content, evidence, priority, and status; blocked, deferred, done, and rejected items are not fresh actionable work.'
printf '%s\n' 'Merely surfacing or reading an item is not meaningful evaluation and does not force a change. Meaningful evaluation begins when you select an actionable item as active work, research it specifically, investigate its next step, reason whether to pursue it, or start derived work.'
printf '%s\n' 'Before concluding after meaningful evaluation, update that same item with a lifecycle transition or substantive same-status evidence, findings, value/next-step refinement, or progress/disposition note. Timestamp-only or formatting churn is insufficient; selected/evaluated plus byte-identical plus NOOP is prohibited.'
printf '%s\n' 'You may leave unselected items unchanged and may select one without mutating every actionable item. Candidate-specific research is allowed before generic outward discovery, but its conclusion must feed back into the selected item.'
printf '%s\n' 'NOOP is unavailable while any candidate, researching, or ready item remains, or while any queue status is malformed or unknown. Use another legitimate outcome after substantive progress, or transition each remaining actionable item to blocked, deferred, done, or rejected before NOOP.'
