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
}

require_primary() {
    [[ $(git -C "$repo" branch --show-current) == "$branch" ]] ||
        die "repository is not on configured branch $branch"
}

require_clean() {
    [[ -z $(git -C "$repo" status --porcelain) ]] ||
        die "dirty state preserved; refusing operation"
}

append_runlog() {
    local type=$1 summary=$2 outcome=${3:-} record
    [[ ! -L "$repo/runlog.jsonl" ]] || return 1
    record=$(jq -cn \
        --arg ts "$(date --iso-8601=seconds)" \
        --arg session_id "${COMMITMENT_SESSION_ID:?COMMITMENT_SESSION_ID is required}" \
        --arg type "$type" --arg summary "$summary" --arg outcome "$outcome" \
        '$ARGS.named | if .outcome == "" then del(.outcome) else . end') || return 1
    printf '%s\n' "$record" >>"$repo/runlog.jsonl"
}

classify_changes() {
    local paths path changed=0
    paths=$(mktemp)
    # Include committed, staged, unstaged, and untracked work. Do not infer
    # meaning from directories, rename similarity, metadata, or version strings.
    git -C "$repo" diff --name-only --no-renames -z "$AGENT_BASE_HEAD" HEAD >"$paths"
    git -C "$repo" diff --name-only --no-renames -z HEAD >>"$paths"
    git -C "$repo" diff --cached --name-only --no-renames -z >>"$paths"
    git -C "$repo" ls-files --others --exclude-standard -z >>"$paths"
    while IFS= read -r -d '' path; do
        [[ ${AGENT_REPO_KIND:-} == commitment && $path == runlog.jsonl ]] && continue
        changed=1
    done <"$paths"
    rm -f -- "$paths"
    printf 'changed=%s\n' "$changed"
}

commit_dirty() {
    local message=$1
    [[ -n $(git -C "$repo" status --porcelain) ]] || return 0
    [[ -z $(git -C "$repo" ls-files -u) ]] ||
        die "unmerged files preserved for inspection; refusing to mark conflicts resolved"
    export GIT_AUTHOR_NAME=${AGENT_GIT_NAME:?configured Git identity is required}
    export GIT_AUTHOR_EMAIL=${AGENT_GIT_EMAIL:?configured Git identity is required}
    export GIT_COMMITTER_NAME=${AGENT_GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}
    export GIT_COMMITTER_EMAIL=${AGENT_GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}
    
    # Build meaningful commit message with work description
    local work_desc=""
    if [[ -n ${AGENT_SUMMARY:-} ]]; then
        # Truncate summary to prevent excessively long commit messages
        local summary_max_len=140
        if [[ ${#AGENT_SUMMARY} -gt $summary_max_len ]]; then
            work_desc=" - ${AGENT_SUMMARY:0:$summary_max_len}..."
        else
            work_desc=" - ${AGENT_SUMMARY}"
        fi
    fi
    
    # Recovery must not depend on a project's commit hooks accepting unfinished work.
    git -C "$repo" -c core.hooksPath=/dev/null add -A
    git -C "$repo" -c core.hooksPath=/dev/null commit -m "${message}${work_desc}"
    require_clean
}

case ${1:-} in
    session-head)
        verify_repo
        git -C "$repo" rev-parse HEAD
        ;;
    session-start)
        verify_repo
        append_runlog session_start "Autonomous Commitment session started" ||
            printf 'commitment-agent-git: session start was not logged\n' >&2
        ;;
    session-end)
        append_runlog session_end "${AGENT_SUMMARY:-Session ended}" "${AGENT_OUTCOME:-FAILED}" ||
            printf 'commitment-agent-git: session end was not logged\n' >&2
        ;;
    session-failure)
        append_runlog failure "${AGENT_FAILURE_SUMMARY:-Session runtime failed}" ||
            printf 'commitment-agent-git: failure was not logged\n' >&2
        ;;
    classify)
        [[ ${AGENT_BASE_HEAD:-} =~ ^[0-9a-fA-F]{40,64}$ ]] || die "valid AGENT_BASE_HEAD is required"
        classify_changes
        ;;
    finalize)
        case ${AGENT_OUTCOME:-} in
            COMMITTED_CHANGE|NOOP) commit_dirty "session: ${AGENT_OUTCOME}" ;;
            CHECKPOINT_UNFINISHED|FAILED)
                commit_dirty "checkpoint: ${AGENT_OUTCOME} after session exit ${AGENT_EXIT_STATUS:-unknown}"
                ;;
            *) die "invalid AGENT_OUTCOME" ;;
        esac
        ;;
    sync)
        bundle=${2:?bundle path is required}
        verify_repo
        require_primary
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
        if [[ -n $(git -C "$repo" status --porcelain) ]]; then
            commit_dirty "checkpoint: unfinished work after session exit ${AGENT_EXIT_STATUS:-unknown}"
            printf 'checkpoint-created\n'
        fi
        ;;
    export)
        output=${2:?bundle output path is required}
        verify_repo
        require_primary
        require_clean
        git -C "$repo" bundle create "$output" "refs/heads/$branch"
        ;;
    *)
        die "usage: $0 {session-head|session-start|session-end|session-failure|classify|finalize|sync BUNDLE|checkpoint|export BUNDLE}"
        ;;
esac
