#!/usr/bin/env bash
set -euo pipefail

die() { printf 'commitment-log: %s\n' "$*" >&2; exit 1; }

event_type=${1:-}
summary=${2:-}
case $event_type in
    observation|candidate|decision|change|research|test|failure|checkpoint) ;;
    '') die "usage: commitment-log TYPE SUMMARY [FIELD=VALUE ...]" ;;
    *) die "unsupported agent event type: $event_type" ;;
esac
[[ -n ${COMMITMENT_SESSION_ID:-} ]] || die "COMMITMENT_SESSION_ID is required"
[[ -n $summary ]] || die "a summary is required"
shift 2

fields=()
seen=' '
has_command=false
has_source=false
has_result=false
for field in "$@"; do
    [[ $field == *=* ]] || die "optional fields must use FIELD=VALUE"
    key=${field%%=*}
    value=${field#*=}
    case $key in
        ts|session_id|type|summary|outcome) die "$key is owned by trusted runtime machinery" ;;
        repo|source|reason|next|version|commit|command|result) ;;
        *) die "unsupported field: $key" ;;
    esac
    [[ $seen != *" $key "* ]] || die "duplicate field: $key"
    seen+="$key "
    case $key in
        command)
            [[ -n $value ]] || die "test command must not be empty"
            has_command=true
            ;;
        source)
            [[ -n $value ]] && has_source=true
            ;;
        result)
            [[ -n $value ]] || die "test result must not be empty"
            has_result=true
            ;;
    esac
    fields+=("$key=$value")
done

if [[ $event_type == test ]]; then
    $has_command && $has_result || die "test events require command and result"
elif [[ $event_type == research ]]; then
    $has_source && $has_result || die "research events require source and result"
fi

root=${COMMITMENT_ROOT:-$(git rev-parse --show-toplevel)}
[[ -d "$root/.git" ]] || die "Commitment repository is unavailable: $root"
[[ -f "$root/runlog.jsonl" ]] || die "runlog.jsonl is missing"

record=$(jq -cn \
    --arg ts "$(date --iso-8601=seconds)" \
    --arg session_id "$COMMITMENT_SESSION_ID" \
    --arg type "$event_type" \
    --arg summary "$summary" \
    --args '
        def field:
            (index("=")) as $separator |
            {key: .[0:$separator], value: .[$separator + 1:]};
        reduce $ARGS.positional[] as $item
            ({ts: $ts, session_id: $session_id, type: $type, summary: $summary};
             ($item | field) as $field | .[$field.key] = $field.value)
    ' "${fields[@]}")
printf '%s\n' "$record" >>"$root/runlog.jsonl"
