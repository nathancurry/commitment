#!/usr/bin/env bash
set -euo pipefail

die() { printf 'commitment-outcome: %s\n' "$*" >&2; exit 1; }

[[ ${COMMITMENT_SESSION_ID:-} =~ ^[a-zA-Z0-9_.:-]{1,128}$ ]] || die "valid COMMITMENT_SESSION_ID is required"
marker=${COMMITMENT_OUTCOME_FILE:?COMMITMENT_OUTCOME_FILE is required}

if [[ ${1:-} == --read ]]; then
    [[ -f $marker && ! -L $marker ]] || die "session outcome was not recorded"
    [[ $(stat -c %s -- "$marker") -le 65536 ]] || die "session outcome is too large"
    jq -ers --arg session_id "$COMMITMENT_SESSION_ID" '
        select(length == 1) | .[0] |
        select(type == "object" and .session_id == $session_id and
            (.outcome | IN("COMMITTED_CHANGE", "NOOP", "CHECKPOINT_UNFINISHED", "FAILED")) and
            (.summary | type == "string" and length > 0 and length <= 4096 and
                (test("[[:cntrl:]]") | not) and test("[^[:space:]]"))) | .outcome
    ' "$marker" || die "session outcome is invalid"
    exit 0
fi

outcome=${1:-}
case $outcome in
    COMMITTED_CHANGE|NOOP|CHECKPOINT_UNFINISHED|FAILED) ;;
    *) die "invalid outcome" ;;
esac
summary=$(jq -nr --arg value "${2:-}" '$value | gsub("[[:cntrl:][:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "")')
[[ -n $summary && ${#summary} -le 4096 ]] || die "a summary of 1-4096 characters is required"

# A fresh session directory is supplied by the launcher. Publish a complete
# marker atomically without replacing a prior outcome, symlink, or stale file.
tmp=$(mktemp "${marker}.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
jq -cn --arg session_id "$COMMITMENT_SESSION_ID" --arg outcome "$outcome" \
    --arg summary "$summary" '{session_id:$session_id, outcome:$outcome, summary:$summary}' >"$tmp"
ln -- "$tmp" "$marker" || die "an outcome marker already exists"
