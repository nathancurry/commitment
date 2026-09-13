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

case ${1:-} in
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
            [[ -z ${AGENT_GIT_NAME:-} ]] || git -C "$repo" config user.name "$AGENT_GIT_NAME"
            [[ -z ${AGENT_GIT_EMAIL:-} ]] || git -C "$repo" config user.email "$AGENT_GIT_EMAIL"
            git -C "$repo" add -A
            git -C "$repo" commit -m "checkpoint: unfinished work after session exit ${AGENT_EXIT_STATUS:-unknown}"
            require_clean
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
        die "usage: $0 {sync BUNDLE|checkpoint|export BUNDLE}"
        ;;
esac
