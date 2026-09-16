#!/usr/bin/env bash
set -euo pipefail

die() { printf 'commitment-publish: %s\n' "$*" >&2; exit 1; }

CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
CONFIG_FILE=${COMMITMENT_CONFIG:-"$CONFIG_HOME/commitment/config.env"}
STATE_DIR=${COMMITMENT_STATE_DIR:-"$DATA_HOME/commitment"}
runtime_path=$(readlink -f -- "$0")
RUNTIME_DIR=$(CDPATH= cd -- "$(dirname -- "$runtime_path")" && pwd)
AGENT_GIT=${COMMITMENT_AGENT_GIT:-"$RUNTIME_DIR/agent-git.sh"}

[[ -r "$CONFIG_FILE" ]] || die "configuration not found: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

select_repo() {
    case ${1:-} in
        commitment)
            KEY=commitment REPO=${COMMITMENT_REPO:-} BRANCH=${COMMITMENT_BRANCH:-}
            UPSTREAM_URL=${COMMITMENT_UPSTREAM_URL:-}
            TOKEN_FILE=${COMMITMENT_GITHUB_TOKEN_FILE:-}
            TOKEN_SETTING=COMMITMENT_GITHUB_TOKEN_FILE
            ;;
        lab)
            KEY=lab REPO=${LAB_REPO:-} BRANCH=${LAB_BRANCH:-}
            UPSTREAM_URL=${LAB_UPSTREAM_URL:-}
            TOKEN_FILE=${LAB_GITHUB_TOKEN_FILE:-}
            TOKEN_SETTING=LAB_GITHUB_TOKEN_FILE
            ;;
        *) die "repository must be commitment or lab" ;;
    esac
    [[ -n $REPO && -d "$REPO/.git" ]] || die "not a Git repository: $REPO"
    [[ $REPO == /* && $STATE_DIR == /* ]] || die "repository and state paths must be absolute"
    [[ -n $UPSTREAM_URL && $UPSTREAM_URL != *$'\n'* ]] || die "trusted upstream URL is required"
    [[ ! $UPSTREAM_URL =~ ^https?://[^/]*@ ]] || die "credential-bearing upstream URLs are forbidden"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git check-ref-format "refs/heads/$BRANCH" >/dev/null ||
        die "invalid configured branch: $BRANCH"
    TRUSTED_REPO="$STATE_DIR/trusted/$KEY.git"
    validate_token_file
}

token=''

validate_token_file() {
    [[ -n $TOKEN_FILE ]] || return 0
    [[ -e $TOKEN_FILE ]] || return 0
    [[ -f $TOKEN_FILE && ! -L $TOKEN_FILE && -r $TOKEN_FILE ]] ||
        die "$TOKEN_SETTING must be a readable regular file: $TOKEN_FILE"
    local token_mode token_path protected_path
    token_path=$(readlink -f -- "$TOKEN_FILE")
    for protected_path in "$COMMITMENT_REPO" "$LAB_REPO" "$STATE_DIR/opencode-data" "$STATE_DIR/opencode-config" "$STATE_DIR/outcomes"; do
        [[ -n $protected_path ]] || continue
        protected_path=$(readlink -f -- "$protected_path") || continue
        case $token_path in
            "$protected_path"|"$protected_path"/*)
                die "$TOKEN_SETTING must be outside agent-mounted paths: $TOKEN_FILE"
                ;;
        esac
    done
    token_mode=$(stat -c '%a' "$TOKEN_FILE")
    (( (8#$token_mode & 8#077) == 0 )) ||
        die "GitHub token file must not be group/world accessible: $TOKEN_FILE"
}

load_token() {
    token=''
    validate_token_file
    [[ -n $TOKEN_FILE && -e $TOKEN_FILE ]] || return 0
    token=$(<"$TOKEN_FILE")
    [[ -n $token ]] || die "$TOKEN_SETTING is empty: $TOKEN_FILE"
}

require_github_token() {
    load_token
    [[ -n $token ]] || die "GitHub token is not configured for $KEY; set $TOKEN_SETTING"
}

trusted_git() {
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git --git-dir="$TRUSTED_REPO" "$@"
}

git_auth() {
    local askpass status=0
    case $UPSTREAM_URL in
        git@github.com:*|ssh://git@github.com/*)
            die "GitHub remotes must use HTTPS so repository-scoped token auth is enforceable"
            ;;
    esac
    if [[ $UPSTREAM_URL == https://github.com/* ]]; then
        load_token
    fi
    if [[ -n $token ]]; then
        askpass=$(mktemp "$STATE_DIR/askpass.XXXXXX")
        chmod 700 "$askpass"
        printf '%s\n' '#!/bin/sh' 'case "$1" in *Username*) printf "%s\n" x-access-token;; *) printf "%s\n" "$COMMITMENT_GITHUB_TOKEN";; esac' >"$askpass"
        COMMITMENT_GITHUB_TOKEN=$token GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$@" || status=$?
        rm -f "$askpass"
        return "$status"
    fi
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$@"
}

ensure_trusted_repo() {
    mkdir -p "$STATE_DIR/trusted"
    chmod 700 "$STATE_DIR" "$STATE_DIR/trusted"
    if [[ ! -f $TRUSTED_REPO/HEAD ]]; then
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            git -c init.templateDir= init --bare --initial-branch="$BRANCH" "$TRUSTED_REPO" >/dev/null
    fi
    trusted_git config remote.upstream.url "$UPSTREAM_URL"
    trusted_git config remote.upstream.fetch "+refs/heads/*:refs/remotes/upstream/*"
}

fetch_upstream() {
    ensure_trusted_repo
    git_auth git --git-dir="$TRUSTED_REPO" fetch --no-tags upstream \
        "refs/heads/$BRANCH:refs/remotes/upstream/$BRANCH"

    local remote_ref="refs/remotes/upstream/$BRANCH" local_ref="refs/heads/$BRANCH"
    local remote_head local_head base
    remote_head=$(trusted_git rev-parse "$remote_ref")
    if ! trusted_git show-ref --verify --quiet "$local_ref"; then
        trusted_git update-ref "$local_ref" "$remote_head"
        return
    fi
    local_head=$(trusted_git rev-parse "$local_ref")
    base=$(trusted_git merge-base "$local_ref" "$remote_ref")
    if [[ $local_head == "$remote_head" || $remote_head == "$base" ]]; then
        return
    fi
    [[ $local_head == "$base" ]] ||
        die "divergent upstream history preserved for $KEY; refusing synchronization"
    trusted_git update-ref "$local_ref" "$remote_head" "$local_head"
}

run_agent_git() {
    local operation=$1 transfer=${2:-} mount_args=() container_arg=()
    [[ -x $AGENT_GIT ]] || die "trusted agent Git helper not installed: $AGENT_GIT"
    if [[ -n $transfer ]]; then
        mount_args=(-v "$transfer:$3:$4,Z")
        container_arg=("$5")
    fi
    podman run --http-proxy=false --rm --network=none --security-opt=no-new-privileges \
        --pids-limit=128 --memory=1g --cpus=2 \
        -v "$REPO:/workspace/repo:rw,Z" \
        -v "$AGENT_GIT:/usr/local/libexec/commitment-agent-git:ro,Z" \
        "${mount_args[@]}" \
        -e AGENT_BRANCH="$BRANCH" \
        -e AGENT_GIT_NAME="${GIT_AUTHOR_NAME:-Commitment}" \
        -e AGENT_GIT_EMAIL="${GIT_AUTHOR_EMAIL:-commitment@localhost}" \
        -e AGENT_GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-${GIT_AUTHOR_NAME:-Commitment}}" \
        -e AGENT_GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-${GIT_AUTHOR_EMAIL:-commitment@localhost}}" \
        -e AGENT_SUMMARY="${AGENT_SUMMARY:-}" \
        -e AGENT_EXIT_STATUS="${AGENT_EXIT_STATUS:-unknown}" \
        -e AGENT_REPO_KIND="$KEY" \
        -e AGENT_BASE_HEAD="${AGENT_BASE_HEAD:-}" \
        -e AGENT_OUTCOME="${AGENT_OUTCOME:-}" \
        -e AGENT_FAILURE_SUMMARY="${AGENT_FAILURE_SUMMARY:-}" \
        -e COMMITMENT_SESSION_ID="${COMMITMENT_SESSION_ID:-}" \
        "$CONTAINER_IMAGE" /usr/local/libexec/commitment-agent-git "$operation" "${container_arg[@]}"
}

sync_repo() {
    fetch_upstream
    local transfer bundle status=0
    transfer=$(mktemp -d "$STATE_DIR/transfer.$KEY.XXXXXX")
    bundle="$transfer/upstream.bundle"
    trusted_git bundle create "$bundle" "refs/heads/$BRANCH"
    run_agent_git sync "$bundle" /transfer/upstream.bundle ro /transfer/upstream.bundle || status=$?
    rm -rf "$transfer"
    (( status == 0 )) || die "agent-side synchronization failed for $KEY; work was preserved"
}

checkpoint_repo() {
    AGENT_EXIT_STATUS=${AGENT_EXIT_STATUS:-unknown} run_agent_git checkpoint
}

import_agent_history() {
    local transfer bundle incoming bundle_head current_head status=0
    transfer=$(mktemp -d "$STATE_DIR/transfer.$KEY.XXXXXX")
    bundle="$transfer/agent.bundle"
    run_agent_git export "$transfer" /transfer rw /transfer/agent.bundle || status=$?
    if (( status != 0 )); then
        rm -rf "$transfer"
        die "agent-side publishing preparation failed for $KEY; work was preserved"
    fi
    [[ -f $bundle && ! -L $bundle ]] || { rm -rf "$transfer"; die "agent did not produce a regular bundle for $KEY"; }
    trusted_git bundle verify "$bundle" >/dev/null || { rm -rf "$transfer"; die "agent bundle validation failed for $KEY"; }
    bundle_head=$(trusted_git bundle list-heads "$bundle" "refs/heads/$BRANCH" | awk 'NR == 1 { print $1 }')
    [[ $bundle_head =~ ^[0-9a-fA-F]+$ ]] || { rm -rf "$transfer"; die "agent bundle lacks configured branch $BRANCH"; }

    incoming="refs/commitment/incoming/$KEY"
    trusted_git update-ref -d "$incoming"
    trusted_git fetch --no-tags "$bundle" "refs/heads/$BRANCH:$incoming" >/dev/null
    trusted_git fsck --strict --no-reflogs "$incoming" >/dev/null
    [[ $(trusted_git rev-parse "$incoming") == "$bundle_head" ]] || { rm -rf "$transfer"; die "agent bundle head changed during import"; }
    current_head=$(trusted_git rev-parse "refs/heads/$BRANCH")
    if ! trusted_git merge-base --is-ancestor "$current_head" "$incoming"; then
        rm -rf "$transfer"
        die "divergent agent history preserved for $KEY; refusing publishing preparation"
    fi
    trusted_git update-ref "refs/heads/$BRANCH" "$bundle_head" "$current_head"
    trusted_git update-ref -d "$incoming"
    rm -rf "$transfer"
}

push_repo() {
    fetch_upstream
    import_agent_history
    if [[ $UPSTREAM_URL == https://github.com/* ]]; then
        require_github_token
    fi
    git_auth git --git-dir="$TRUSTED_REPO" push upstream \
        "refs/heads/$BRANCH:refs/heads/$BRANCH"
}

github_slug() {
    local url=$UPSTREAM_URL
    case $url in
        https://github.com/*) url=${url#https://github.com/} ;;
        git@github.com:*) url=${url#git@github.com:} ;;
        ssh://git@github.com/*) url=${url#ssh://git@github.com/} ;;
        *) die "issue operations require a github.com upstream URL" ;;
    esac
    printf '%s\n' "${url%.git}"
}

gh_auth() {
    command -v gh >/dev/null || die "gh is required for issue operations"
    require_github_token
    GH_TOKEN=$token gh "$@"
}

command=${1:-}
case $command in
    sync|checkpoint|push)
        select_repo "${2:-}"
        "${command}_repo"
        ;;
    session-head|session-start|session-end|session-failure|classify|finalize)
        select_repo "${2:-}"
        run_agent_git "$command"
        ;;
    issue-list)
        select_repo "${2:-}"
        gh_auth issue list --repo "$(github_slug)" --limit "${3:-30}"
        ;;
    issue-create)
        select_repo "${2:-}"
        [[ -n ${3:-} && -r ${4:-} ]] || die "usage: $0 issue-create REPO TITLE BODY_FILE"
        gh_auth issue create --repo "$(github_slug)" --title "$3" --body-file "$4"
        ;;
    issue-comment)
        select_repo "${2:-}"
        [[ ${3:-} =~ ^[1-9][0-9]*$ && -r ${4:-} ]] || die "usage: $0 issue-comment REPO NUMBER BODY_FILE"
        gh_auth issue comment "$3" --repo "$(github_slug)" --body-file "$4"
        ;;
    issue-close)
        select_repo "${2:-}"
        [[ ${3:-} =~ ^[1-9][0-9]*$ ]] || die "usage: $0 issue-close REPO NUMBER"
        gh_auth issue close "$3" --repo "$(github_slug)"
        ;;
    *) die "usage: $0 {session-head|session-start|session-end|session-failure|classify|finalize|sync|checkpoint|push|issue-list|issue-create|issue-comment|issue-close} ..." ;;
esac
