#!/usr/bin/env bash
set -euo pipefail

warn() { printf 'commitment-log: %s\n' "$*" >&2; }
append_event() (
    [[ -n ${COMMITMENT_SESSION_ID:-} && $# -ge 2 ]] || return 1
    event_type=$1 summary=$2
    shift 2
    [[ -n $event_type && -n $summary ]] || return 1
    root=${COMMITMENT_ROOT:-$(git rev-parse --show-toplevel)}
    [[ ! -L $root/runlog.jsonl ]] || return 1
    fields=()
    for field in "$@"; do
        if [[ $field != *=* ]]; then
            warn "ignored extra argument without '='"
            continue
        fi
        key=${field%%=*}
        case $key in
            ''|ts|session_id|type|summary) warn "ignored reserved or empty field" ;;
            *) fields+=("$field") ;;
        esac
    done
    record=$(jq -cn --arg ts "$(date --iso-8601=seconds)" \
        --arg session_id "$COMMITMENT_SESSION_ID" --arg type "$event_type" \
        --arg summary "$summary" --args '
        reduce $ARGS.positional[] as $item
            ({ts:$ts, session_id:$session_id, type:$type, summary:$summary};
             ($item | index("=")) as $at | .[$item[0:$at]] = $item[$at+1:])
    ' "${fields[@]}") || return 1
    printf '%s\n' "$record" >>"$root/runlog.jsonl"
)

# Logging is observational. Bad extras, unavailable storage, and missing context
# must not turn useful work into a failed shell workflow.
append_event "$@" || warn "event not recorded; work may continue"
exit 0
