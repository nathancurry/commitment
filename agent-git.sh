#!/usr/bin/env bash
set -euo pipefail

die() { printf 'commitment-agent-git: %s\n' "$*" >&2; exit 1; }

repo=${AGENT_REPO:-/workspace/repo}
branch=${AGENT_BRANCH:?AGENT_BRANCH is required}

[[ -d "$repo/.git" ]] || die "not a Git repository: $repo"

verify_repo() {
    local remote url
    if git -C "$repo" config --local --get-regexp '^(credential\.|http\..*\.extraheader)' >/dev/null 2>&1; then
        die "credential-bearing local Git configuration is forbidden"
    fi
    while IFS= read -r remote; do
        url=$(git -C "$repo" remote get-url "$remote")
        [[ ! $url =~ ^https?://[^/]*@ ]] || die "credential-bearing remote URL is forbidden"
    done < <(git -C "$repo" remote)
    if [[ -f $repo/.gitmodules ]] &&
        git -C "$repo" config -f .gitmodules --get-regexp '^submodule\..*\.url' |
            awk '{print $2}' | grep -Eq '^https?://[^/]*@'; then
        die "credential-bearing submodule URL is forbidden"
    fi
    [[ $(git -C "$repo" branch --show-current) == "$branch" ]] ||
        die "repository is not on configured branch $branch"
}

require_clean() {
    [[ -z $(git -C "$repo" status --porcelain) ]] ||
        die "dirty state preserved; refusing operation"
}

append_runlog() {
    local type=$1 summary=$2 outcome=${3:-} record
    [[ -f "$repo/runlog.jsonl" ]] || : >"$repo/runlog.jsonl"
    record=$(jq -cn \
        --arg ts "$(date --iso-8601=seconds)" \
        --arg session_id "${COMMITMENT_SESSION_ID:?COMMITMENT_SESSION_ID is required}" \
        --arg type "$type" --arg summary "$summary" --arg outcome "$outcome" \
        '$ARGS.named | if .outcome == "" then del(.outcome) else . end')
    printf '%s\n' "$record" >>"$repo/runlog.jsonl"
}

is_bookkeeping_path() {
    [[ ${AGENT_REPO_KIND:-} == commitment ]] || return 1
    case $1 in
        memory/README.md|queue/README.md|requests/README.md|inbox/README.md) return 1 ;;
        runlog.jsonl|memory/*.md|queue/*.md|requests/*.md|inbox/*) return 0 ;;
        *) return 1 ;;
    esac
}

classify_changes() {
    local path
    HAS_CHANGES=0
    HAS_SUBSTANTIVE=0
    HAS_DIRTY=0
    HAS_DIRTY_SUBSTANTIVE=0
    while IFS= read -r -d '' path; do
        HAS_CHANGES=1
        is_bookkeeping_path "$path" || HAS_SUBSTANTIVE=1
    done < <(git -C "$repo" diff --name-only -z "$AGENT_BASE_HEAD..HEAD")
    while IFS= read -r -d '' path; do
        HAS_CHANGES=1
        HAS_DIRTY=1
        if ! is_bookkeeping_path "$path"; then
            HAS_SUBSTANTIVE=1
            HAS_DIRTY_SUBSTANTIVE=1
        fi
    done < <({
        git -C "$repo" diff --name-only -z
        git -C "$repo" diff --cached --name-only -z
        git -C "$repo" ls-files --others --exclude-standard -z
    })
}

commit_dirty() {
    local message=$1
    [[ -n $(git -C "$repo" status --porcelain) ]] || return 0
    [[ -z ${AGENT_GIT_NAME:-} ]] || git -C "$repo" config user.name "$AGENT_GIT_NAME"
    [[ -z ${AGENT_GIT_EMAIL:-} ]] || git -C "$repo" config user.email "$AGENT_GIT_EMAIL"
    git -C "$repo" add -A
    git -C "$repo" commit -m "$message"
    require_clean
}

case ${1:-} in
    session-head)
        verify_repo
        require_clean
        git -C "$repo" rev-parse HEAD
        ;;
    session-start)
        verify_repo
        require_clean
        rm -f "$repo/.git/commitment-session-outcome"
        append_runlog session_start "Autonomous Commitment session started"
        ;;
    session-outcome)
        verify_repo
        marker="$repo/.git/commitment-session-outcome"
        [[ -f $marker && ! -L $marker ]] || die "session outcome was not recorded"
        jq -e \
            --arg session_id "${COMMITMENT_SESSION_ID:?COMMITMENT_SESSION_ID is required}" '
                type == "object" and
                .session_id == $session_id and
                (.outcome | IN("COMMITTED_CHANGE", "NOOP", "CHECKPOINT_UNFINISHED", "FAILED")) and
                (.summary | type == "string" and length > 0)
            ' "$marker" >/dev/null || die "session outcome is invalid"
        grep -Fqx -- "$(<"$marker")" "$repo/runlog.jsonl" ||
            die "session outcome is missing from runlog.jsonl"
        jq -r .outcome "$marker"
        ;;
    session-failure)
        verify_repo
        append_runlog failure "${AGENT_FAILURE_SUMMARY:-Session runtime failed}"
        append_runlog session_end "${AGENT_FAILURE_SUMMARY:-Session runtime failed}" FAILED
        ;;
    finalize)
        verify_repo
        [[ ${AGENT_BASE_HEAD:-} =~ ^[0-9a-fA-F]{40,64}$ ]] || die "valid AGENT_BASE_HEAD is required"
        git -C "$repo" merge-base --is-ancestor "$AGENT_BASE_HEAD" HEAD ||
            die "session history diverged from its starting point"
        classify_changes
        case ${AGENT_OUTCOME:-} in
            NOOP)
                (( HAS_SUBSTANTIVE == 0 )) || die "NOOP contains substantive changes"
                commit_dirty "chore: record NOOP session bookkeeping"
                ;;
            COMMITTED_CHANGE)
                (( HAS_DIRTY_SUBSTANTIVE == 0 )) ||
                    die "COMMITTED_CHANGE left substantive work uncommitted"
                if [[ ${AGENT_REPO_KIND:-} == commitment && $HAS_SUBSTANTIVE == 1 ]]; then
                    before_version=$(git -C "$repo" show "$AGENT_BASE_HEAD:VERSION" 2>/dev/null || true)
                    after_version=$(<"$repo/VERSION")
                    [[ -n $before_version && $after_version != "$before_version" ]] ||
                        die "completed substantive Commitment change requires a VERSION bump"
                fi
                commit_dirty "chore: record session bookkeeping"
                ;;
            CHECKPOINT_UNFINISHED)
                commit_dirty "checkpoint: unfinished work after session exit ${AGENT_EXIT_STATUS:-0}"
                ;;
            FAILED)
                commit_dirty "checkpoint: unfinished work after session failure ${AGENT_EXIT_STATUS:-unknown}"
                ;;
            *) die "invalid AGENT_OUTCOME: ${AGENT_OUTCOME:-missing}" ;;
        esac
        printf 'substantive=%s\n' "$HAS_SUBSTANTIVE"
        ;;
    sync)
        bundle=${2:?bundle path is required}
        verify_repo
        require_clean
        git -C "$repo" update-ref -d refs/commitment/trusted-sync
        git -C "$repo" fetch --no-tags "$bundle" \
            "refs/heads/$branch:refs/commitment/trusted-sync"
        local_head=$(git -C "$repo" rev-parse HEAD)
        trusted_head=$(git -C "$repo" rev-parse refs/commitment/trusted-sync)
        base=$(git -C "$repo" merge-base HEAD refs/commitment/trusted-sync)
        if [[ $local_head == "$trusted_head" || $trusted_head == "$base" ]]; then
            exit 0
        fi
        [[ $local_head == "$base" ]] ||
            die "divergent history preserved; refusing synchronization"
        git -C "$repo" merge --ff-only refs/commitment/trusted-sync
        ;;
    checkpoint)
        verify_repo
        if [[ -n $(git -C "$repo" status --porcelain) ]]; then
            commit_dirty "checkpoint: unfinished work after session exit ${AGENT_EXIT_STATUS:-unknown}"
            printf 'checkpoint-created\n'
        fi
        ;;
    export)
        output=${2:?bundle output path is required}
        verify_repo
        require_clean
        git -C "$repo" bundle create "$output" "refs/heads/$branch"
        ;;
    *)
        die "usage: $0 {session-head|session-start|session-outcome|session-failure|finalize|sync BUNDLE|checkpoint|export BUNDLE}"
        ;;
esac
