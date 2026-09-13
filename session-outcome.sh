#!/usr/bin/env bash
set -euo pipefail

die() { printf 'commitment-outcome: %s\n' "$*" >&2; exit 1; }

outcome=${1:-}
summary=${2:-}
case $outcome in
    COMMITTED_CHANGE|NOOP|CHECKPOINT_UNFINISHED|FAILED) ;;
    *) die "outcome must be COMMITTED_CHANGE, NOOP, CHECKPOINT_UNFINISHED, or FAILED" ;;
esac
[[ -n ${COMMITMENT_SESSION_ID:-} ]] || die "COMMITMENT_SESSION_ID is required"
[[ -n $summary && $summary != *$'\n'* ]] || die "a one-line summary is required"

root=${COMMITMENT_ROOT:-$(git rev-parse --show-toplevel)}
[[ -d "$root/.git" ]] || die "Commitment repository is unavailable: $root"
[[ -f "$root/runlog.jsonl" ]] || die "runlog.jsonl is missing"
marker=${COMMITMENT_OUTCOME_FILE:-"$root/.git/commitment-session-outcome"}
[[ ! -e $marker ]] || die "an outcome is already recorded for this session"

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
