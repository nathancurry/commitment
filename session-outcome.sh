#!/usr/bin/env bash
set -euo pipefail

die() { printf 'commitment-outcome: %s\n' "$*" >&2; exit 1; }

normalize_summary() {
    jq -nr --arg value "$1" '$value | gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "")'
}

read_outcome() {
    local root marker
    root=${COMMITMENT_ROOT:-$(git rev-parse --show-toplevel)}
    [[ -d "$root/.git" ]] || die "Commitment repository is unavailable: $root"
    [[ -f "$root/runlog.jsonl" ]] || die "runlog.jsonl is missing"
    marker=${COMMITMENT_OUTCOME_FILE:-"$root/.git/commitment-session-outcome"}
    [[ -f $marker && ! -L $marker ]] || die "session outcome was not recorded"
    jq -e --arg session_id "$COMMITMENT_SESSION_ID" '
        type == "object" and
        .session_id == $session_id and
        (.outcome | IN("COMMITTED_CHANGE", "NOOP", "CHECKPOINT_UNFINISHED", "FAILED")) and
        (.summary | type == "string" and length > 0)
    ' "$marker" >/dev/null || die "session outcome is invalid"
    grep -Fqx -- "$(<"$marker")" "$root/runlog.jsonl" ||
        die "session outcome is missing from runlog.jsonl"
    jq -r .outcome "$marker"
}

[[ -n ${COMMITMENT_SESSION_ID:-} ]] || die "COMMITMENT_SESSION_ID is required"
if [[ ${1:-} == --read ]]; then
    read_outcome
    exit 0
fi

outcome=${1:-}
summary=${2:-}
case $outcome in
    COMMITTED_CHANGE|NOOP|CHECKPOINT_UNFINISHED|FAILED) ;;
    *) die "outcome must be COMMITTED_CHANGE, NOOP, CHECKPOINT_UNFINISHED, or FAILED" ;;
esac
summary=$(normalize_summary "$summary")
[[ -n $summary ]] || die "a summary is required"

root=${COMMITMENT_ROOT:-$(git rev-parse --show-toplevel)}
[[ -d "$root/.git" ]] || die "Commitment repository is unavailable: $root"
[[ -f "$root/runlog.jsonl" ]] || die "runlog.jsonl is missing"
marker=${COMMITMENT_OUTCOME_FILE:-"$root/.git/commitment-session-outcome"}
[[ ! -e $marker ]] || die "an outcome is already recorded for this session"

if [[ $outcome == NOOP ]]; then
    queue_helper=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/queue-context.sh
    [[ -x $queue_helper ]] || die "trusted queue helper is unavailable: $queue_helper"
    if ! queue_blockers=$("$queue_helper" "$root" noop-blockers); then
        die "NOOP rejected: queue state could not be inspected"
    fi
    if [[ -n $queue_blockers ]]; then
        die $'NOOP rejected: actionable or unresolved queue work remains:\n'"$queue_blockers"$'\nProgress actionable work and choose another legitimate outcome, or transition it to a non-actionable disposition; repair malformed queue state before concluding NOOP.'
    fi
fi

if [[ $outcome == NOOP ]] && ! jq -eRn --arg session_id "$COMMITMENT_SESSION_ID" '
    [inputs
     | (fromjson? // empty)
     | select(
         type == "object" and
         .session_id == $session_id and
         .type == "research" and
         (.summary | type == "string" and length > 0) and
         (.source | type == "string" and length > 0) and
         (.result | type == "string" and length > 0)
       )]
    | length > 0
' <"$root/runlog.jsonl" >/dev/null; then
    die $'NOOP requires bounded outward research in the current session.\nUse websearch/webfetch or equivalent, then record it with commitment-log research SUMMARY source=SOURCE result=RESULT.'
fi

record=$(jq -cn \
    --arg ts "$(date --iso-8601=seconds)" \
    --arg session_id "$COMMITMENT_SESSION_ID" \
    --arg summary "$summary" \
    --arg outcome "$outcome" \
    '{ts: $ts, session_id: $session_id, type: "session_end", summary: $summary, outcome: $outcome}')
tmp=$(mktemp "$root/.git/commitment-session-outcome.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$record" >"$tmp"
printf '%s\n' "$record" >>"$root/runlog.jsonl"
mv "$tmp" "$marker"
trap - EXIT
