#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
assert_file() { [[ -e $1 ]] || fail "missing $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }

fixture_current=7.8.9
fixture_prior=6.7.8

for script in "$ROOT"/*.sh "$ROOT"/tests/*.sh; do bash -n "$script"; done
[[ -f "$ROOT/VERSION" ]] || fail "VERSION is missing"
version=$(<"$ROOT/VERSION")
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
[[ $version =~ $semver ]] || fail "VERSION is not valid SemVer"
assert_contains "$ROOT/Containerfile" 'OPENCODE_VERSION=1.18.30'
assert_contains "$ROOT/AGENTS.md" 'must contain valid SemVer'
assert_contains "$ROOT/AGENTS.md" "configured primary branch by default"
assert_contains "$ROOT/AGENTS.md" 'Multiple commits may form one update'
assert_contains "$ROOT/AGENTS.md" 'memory, queue, runlog, exploratory, incomplete, and checkpoint-only changes need no bump'
assert_contains "$ROOT/AGENTS.md" 'Before declaring a coherent substantive Commitment update `COMMITTED_CHANGE`'
assert_contains "$ROOT/AGENTS.md" 'include the appropriate VERSION bump'
grep -Fxq 'OLLAMA_ENDPOINT=http://host.containers.internal:11434' "$ROOT/config.example.env" || fail "default Ollama endpoint changed"
grep -Fxq 'OLLAMA_MODEL=devstral-small-2-32k' "$ROOT/config.example.env" || fail "default Ollama model is incorrect"
grep -Fxq 'OLLAMA_CONTEXT=32768' "$ROOT/config.example.env" || fail "default Ollama context is incorrect"
grep -Fxq 'OLLAMA_OUTPUT=8192' "$ROOT/config.example.env" || fail "default Ollama output limit is incorrect"
grep -Fxq 'GIT_AUTHOR_NAME=Commitment' "$ROOT/config.example.env" || fail "default Git author name is incorrect"
grep -Fxq 'GIT_AUTHOR_EMAIL=commitment@localhost' "$ROOT/config.example.env" || fail "default Git author email is incorrect"
grep -Fxq 'CONTINUE_SESSION=false' "$ROOT/config.example.env" || fail "native session continuation is not disabled by default"
grep -Fxq 'ALLOW_SUBAGENTS=false' "$ROOT/config.example.env" || fail "subagents are not disabled by default"
"$ROOT/tests/runlog.sh"
"$ROOT/tests/memory-queue-noop.sh"
"$ROOT/tests/queue-discovery.sh"
"$ROOT/tests/queue-evaluation.sh"
"$ROOT/tests/inbox.sh"
"$ROOT/tests/git-change-classifier.sh"
"$ROOT/tests/session-regressions.sh"
"$ROOT/tests/terminal-outcome.sh"
"$ROOT/tests/requests.sh"
python3 -IB "$ROOT/tests/test_secrets.py"
shared_token_key=GITHUB_TOKEN
shared_token_key+=_FILE
commitment_remote_key=COMMITMENT_
commitment_remote_key+=REMOTE
lab_remote_key=LAB_
lab_remote_key+=REMOTE
for stale_key in "$shared_token_key" "$commitment_remote_key" "$lab_remote_key"; do
    if rg -n "(^|[^A-Z_])${stale_key}([^A-Z_]|$)" "$ROOT" --glob '!.git/**' >/dev/null; then
        fail "stale configuration remains: $stale_key"
    fi
done
pass "shell syntax, pinned dependency, SemVer, and version policy"

make_repo() {
    local name=$1
    git init --bare "$TMP/$name.remote" >/dev/null
    git init -b main "$TMP/$name" >/dev/null
    git -C "$TMP/$name" config user.name Test
    git -C "$TMP/$name" config user.email test@example.invalid
    printf '%s\n' "$name" >"$TMP/$name/README.md"
    if [[ $name == commitment ]]; then
        printf '%s\n' "$fixture_current" >"$TMP/$name/VERSION"
    fi
    git -C "$TMP/$name" add -A
    git -C "$TMP/$name" commit -m initial >/dev/null
    git -C "$TMP/$name" remote add origin "$TMP/$name.remote"
    git -C "$TMP/$name" push -u origin main >/dev/null
}
make_repo commitment
make_repo lab

REAL_GIT=$(command -v git)
export REAL_GIT
mkdir -p "$TMP/fakebin" "$TMP/home"
cat >"$TMP/fakebin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TMP/fakebin/podman" <<'EOF'
#!/bin/sh
[ "${1:-}" = info ] && { printf '%s\n' true; exit 0; }
[ "${1:-}" = rm ] && exit 0
[ "${1:-}" = stop ] && exit 0
repo=''
helper=''
outcome_helper=''
log_helper=''
transfer=''
branch=''
git_name=''
git_email=''
exit_status=''
repo_kind=''
base_head=''
agent_outcome=''
session_id=''
commitment_root=''
failure_summary=''
operation=''
previous=''
for argument do
    if [ "$previous" = -v ]; then
        case $argument in
            *:/workspace/repo:rw,Z) repo=${argument%:/workspace/repo:rw,Z} ;;
            *:/usr/local/libexec/commitment-agent-git:ro,Z) helper=${argument%:/usr/local/libexec/commitment-agent-git:ro,Z} ;;
            *:/usr/local/bin/commitment-outcome:ro,Z) outcome_helper=${argument%:/usr/local/bin/commitment-outcome:ro,Z} ;;
            *:/usr/local/bin/commitment-log:ro,Z) log_helper=${argument%:/usr/local/bin/commitment-log:ro,Z} ;;
            *:/transfer/upstream.bundle:ro,Z) transfer=${argument%:/transfer/upstream.bundle:ro,Z} ;;
            *:/transfer:rw,Z) transfer=${argument%:/transfer:rw,Z} ;;
            *:/workspace/commitment:rw,Z) commitment=${argument%:/workspace/commitment:rw,Z} ;;
            *:/workspace/commitment-lab:rw,Z) lab=${argument%:/workspace/commitment-lab:rw,Z} ;;
        esac
    elif [ "$previous" = -e ]; then
        case $argument in
            AGENT_BRANCH=*) branch=${argument#AGENT_BRANCH=} ;;
            AGENT_GIT_NAME=*) git_name=${argument#AGENT_GIT_NAME=} ;;
            AGENT_GIT_EMAIL=*) git_email=${argument#AGENT_GIT_EMAIL=} ;;
            AGENT_EXIT_STATUS=*) exit_status=${argument#AGENT_EXIT_STATUS=} ;;
            AGENT_REPO_KIND=*) repo_kind=${argument#AGENT_REPO_KIND=} ;;
            AGENT_BASE_HEAD=*) base_head=${argument#AGENT_BASE_HEAD=} ;;
            AGENT_OUTCOME=*) agent_outcome=${argument#AGENT_OUTCOME=} ;;
            AGENT_FAILURE_SUMMARY=*) failure_summary=${argument#AGENT_FAILURE_SUMMARY=} ;;
            COMMITMENT_SESSION_ID=*) session_id=${argument#COMMITMENT_SESSION_ID=} ;;
            COMMITMENT_ROOT=*) commitment_root=${argument#COMMITMENT_ROOT=} ;;
        esac
    fi
    case $argument in session-head|session-start|session-outcome|session-failure|classify|finalize|sync|checkpoint|export) operation=$argument ;; esac
    previous=$argument
done
if [ -n "${FAKE_PODMAN_ALL_ARGS:-}" ]; then
    printf '%s\n' "$@" >>"$FAKE_PODMAN_ALL_ARGS"
fi
if [ "${FAKE_OUTCOME_PROSE:-0}" = 1 ] && [ -z "$helper" ]; then
    printf '%s\n' 'Outcome: NOOP'
fi
if [ -n "$helper" ]; then
    [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${COMMITMENT_GITHUB_TOKEN:-}${COMMITMENT_GITHUB_TOKEN_FILE:-}${LAB_GITHUB_TOKEN_FILE:-}" ] || exit 90
    export AGENT_REPO=$repo AGENT_BRANCH=$branch AGENT_GIT_NAME=$git_name AGENT_GIT_EMAIL=$git_email AGENT_EXIT_STATUS=$exit_status
    export AGENT_REPO_KIND=$repo_kind AGENT_BASE_HEAD=$base_head AGENT_OUTCOME=$agent_outcome
    export AGENT_FAILURE_SUMMARY=$failure_summary COMMITMENT_SESSION_ID=$session_id
    case $operation in
        sync) exec "$helper" sync "$transfer" ;;
        checkpoint) exec "$helper" checkpoint ;;
        export) exec "$helper" export "$transfer/agent.bundle" ;;
        *) exec "$helper" "$operation" ;;
    esac
    exit 2
fi
printf '%s\n' "$@" >"$FAKE_PODMAN_ARGS"
if [ "${FAKE_BOOKKEEPING_ONLY:-0}" != 1 ] && [ -n "${commitment:-}" ]; then
    printf '%s\n' agent-change >>"$commitment/agent.txt"
fi
if [ "${FAKE_BOOKKEEPING_ONLY:-0}" != 1 ] && [ -n "${lab:-}" ]; then
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" first' >"$lab/small-program"
    chmod +x "$lab/small-program"
    test "$("$lab/small-program")" = first
    sed -i s/first/revised/ "$lab/small-program"
    test "$("$lab/small-program")" = revised
fi
if [ "${FAKE_SKIP_OUTCOME_HELPER:-0}" != 1 ] && [ -n "${commitment:-}" ] && [ -n "$outcome_helper" ]; then
    (
        cd "$commitment"
        if [ "${FAKE_SESSION_OUTCOME:-CHECKPOINT_UNFINISHED}" = NOOP ]; then
            COMMITMENT_SESSION_ID=$session_id COMMITMENT_ROOT="$commitment" \
                "$log_helper" research "Inspected a synthetic integration source" \
                source=https://example.invalid/research result="No candidate found"
        fi
        COMMITMENT_SESSION_ID=$session_id \
            COMMITMENT_ROOT="$commitment" \
            COMMITMENT_OUTCOME_FILE="$commitment/.git/commitment-session-outcome" \
            "$outcome_helper" "${FAKE_SESSION_OUTCOME:-CHECKPOINT_UNFINISHED}" "Synthetic autonomous session"
    )
fi
if [ "${FAKE_BREAK_REMOTE:-0}" = 1 ]; then
    mv "$FAKE_UPSTREAM" "$FAKE_UPSTREAM.off"
fi
exit 0
EOF
chmod +x "$TMP/fakebin/systemctl" "$TMP/fakebin/podman"

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_DATA_HOME="$TMP/data"
export PATH="$TMP/fakebin:$PATH"
export FAKE_PODMAN_ARGS="$TMP/podman.args"
export FAKE_PODMAN_ALL_ARGS="$TMP/podman-all.args"
export FAKE_UPSTREAM="$TMP/commitment.remote"
COMMITMENT_SKIP_BUILD=1 "$ROOT/install.sh" >/dev/null
CONFIG="$XDG_CONFIG_HOME/commitment/config.env"
sed -i \
    -e "s|^COMMITMENT_REPO=.*|COMMITMENT_REPO=$TMP/commitment|" \
    -e "s|^COMMITMENT_UPSTREAM_URL=.*|COMMITMENT_UPSTREAM_URL=$TMP/commitment.remote|" \
    -e "s|^LAB_REPO=.*|LAB_REPO=$TMP/lab|" \
    -e "s|^LAB_UPSTREAM_URL=.*|LAB_UPSTREAM_URL=$TMP/lab.remote|" \
    -e "s|^GIT_AUTHOR_NAME=.*|GIT_AUTHOR_NAME='Creative Author'|" \
    -e 's|^GIT_AUTHOR_EMAIL=.*|GIT_AUTHOR_EMAIL=creative@example.invalid|' \
    "$CONFIG"
assert_file "$HOME/.local/bin/commitment"
assert_file "$HOME/.local/libexec/commitment/commitment-log.sh"
assert_file "$HOME/.local/libexec/commitment/inbox-context.sh"
assert_file "$HOME/.local/libexec/commitment/queue-context.sh"
for helper in secret-broker.py commitment-secret.py; do
    assert_file "$HOME/.local/libexec/commitment/$helper"
    [[ ! "$ROOT/$helper" -ef "$HOME/.local/libexec/commitment/$helper" ]] || fail "secret helper is not an installed copy"
done
[[ -x "$HOME/.local/libexec/commitment/commitment-log.sh" ]] || fail "installed runlog helper is not executable"
[[ ! -L "$HOME/.local/libexec/commitment/commitment-log.sh" ]] || fail "installed runlog helper follows source edits"
[[ ! "$ROOT/commitment-log.sh" -ef "$HOME/.local/libexec/commitment/commitment-log.sh" ]] ||
    fail "installed runlog helper is not an explicit copy"
[[ ! "$ROOT/inbox-context.sh" -ef "$HOME/.local/libexec/commitment/inbox-context.sh" ]] ||
    fail "installed inbox helper is not an explicit copy"
[[ ! "$ROOT/queue-context.sh" -ef "$HOME/.local/libexec/commitment/queue-context.sh" ]] ||
    fail "installed queue helper is not an explicit copy"
assert_file "$XDG_CONFIG_HOME/systemd/user/commitment.timer"
assert_contains "$XDG_CONFIG_HOME/systemd/user/commitment.timer" 'OnCalendar=daily'
grep -Fxq 'CONTINUE_SESSION=false' "$CONFIG" || fail "fresh install enabled native session continuation"
grep -Fxq 'ALLOW_SUBAGENTS=false' "$CONFIG" || fail "fresh install enabled subagents"
pass "disposable install"

printf '%s\n' preserve >"$XDG_CONFIG_HOME/commitment/preserved"
printf '%s\n' "$fixture_current" >"$XDG_DATA_HOME/commitment/opencode-data/current-version"
printf 'Prior session says VERSION should be %s, not %s\n' "$fixture_prior" "$fixture_current" >"$XDG_DATA_HOME/commitment/opencode-data/preserved"
COMMITMENT_SKIP_BUILD=1 "$ROOT/install.sh" >/dev/null
assert_file "$XDG_CONFIG_HOME/commitment/preserved"
assert_file "$XDG_DATA_HOME/commitment/opencode-data/preserved"
pass "reinstall preserves configuration and continuity"

"$HOME/.local/bin/commitment" >/dev/null
session_id=$(sed -n 's/^COMMITMENT_SESSION_ID=//p' "$FAKE_PODMAN_ARGS")
[[ $(printf '%s\n' "$session_id" | wc -l) -eq 1 && $session_id =~ ^[0-9]{8}T[0-9]{6}[+-][0-9]{4}-[0-9]+$ ]] ||
    fail "launcher did not generate exactly one recognizable session ID"
grep -Fxq 'GIT_AUTHOR_NAME=Creative Author' "$FAKE_PODMAN_ARGS" || fail "Git author name was not passed to creative container"
grep -Fxq 'GIT_AUTHOR_EMAIL=creative@example.invalid' "$FAKE_PODMAN_ARGS" || fail "Git author email was not passed to creative container"
grep -Fxq 'GIT_COMMITTER_NAME=Creative Author' "$FAKE_PODMAN_ARGS" || fail "Git committer name did not default to author"
grep -Fxq 'GIT_COMMITTER_EMAIL=creative@example.invalid' "$FAKE_PODMAN_ARGS" || fail "Git committer email did not default to author"
first_session_id=$session_id
"$HOME/.local/bin/commitment" >/dev/null
second_session_id=$(sed -n 's/^COMMITMENT_SESSION_ID=//p' "$FAKE_PODMAN_ARGS")
[[ -n $second_session_id && $second_session_id != "$first_session_id" ]] || fail "sequential runs reused a session ID"
! grep -Fxq -- '--continue' "$FAKE_PODMAN_ARGS" || fail "fresh default resumed stale OpenCode session state"
grep -Fq "$fixture_prior" "$XDG_DATA_HOME/commitment/opencode-data/preserved" || fail "historical OpenCode state was deleted"
[[ $(<"$TMP/commitment/VERSION") == "$fixture_current" ]] || fail "fresh run changed VERSION based on stale session text"
jq -e --arg session_id "$second_session_id" '.session_id == $session_id and .outcome == "CHECKPOINT_UNFINISHED"' \
    "$TMP/commitment/.git/commitment-session-outcome" >/dev/null || fail "helper invocation did not establish the session outcome"
pass "fresh default ignores stale session text, preserves state, and records helper outcome"

if FAKE_SKIP_OUTCOME_HELPER=1 FAKE_OUTCOME_PROSE=1 FAKE_BOOKKEEPING_ONLY=1 \
    "$HOME/.local/bin/commitment" >"$TMP/prose-outcome.out" 2>&1; then
    fail "prose-only outcome was accepted"
fi
assert_contains "$TMP/prose-outcome.out" 'OpenCode exited without a valid session outcome'
[[ $(git -C "$TMP/commitment" log -1 --format=%s) == checkpoint:* ]] || fail "missing-outcome session was not checkpointed"
[[ ! -e "$TMP/commitment/.git/commitment-session-outcome" ]] || fail "prose created a trusted outcome marker"
pass "prose alone is not an outcome; missing helper invocation fails and checkpoints"
assert_contains "$XDG_DATA_HOME/commitment/opencode-config/opencode.json" 'http://host.containers.internal:11434/v1'
assert_contains "$XDG_DATA_HOME/commitment/opencode-config/opencode.json" 'ollama/devstral-small-2-32k'
jq -e '
    .model == "ollama/devstral-small-2-32k" and
    .provider.ollama.options.baseURL == "http://host.containers.internal:11434/v1" and
    .provider.ollama.models["devstral-small-2-32k"].name == "devstral-small-2-32k" and
    .provider.ollama.models["devstral-small-2-32k"].limit.context == 32768 and
    .provider.ollama.models["devstral-small-2-32k"].limit.output == 8192 and
    .permission.question == "deny" and
    .permission.task == "deny"
' "$XDG_DATA_HOME/commitment/opencode-config/opencode.json" >/dev/null || fail "generated OpenCode JSON is invalid"

cp "$CONFIG" "$TMP/config.valid"
sed -i 's/^ALLOW_SUBAGENTS=.*/ALLOW_SUBAGENTS=true/' "$CONFIG"
"$HOME/.local/bin/commitment" >/dev/null
jq -e '.permission.task == "allow"' "$XDG_DATA_HOME/commitment/opencode-config/opencode.json" >/dev/null ||
    fail "ALLOW_SUBAGENTS=true did not allow OpenCode task"
cp "$TMP/config.valid" "$CONFIG"
for value in yes 1 FALSE; do
    sed -i "s/^ALLOW_SUBAGENTS=.*/ALLOW_SUBAGENTS=$value/" "$CONFIG"
    if "$HOME/.local/bin/commitment" >"$TMP/subagents-$value.out" 2>&1; then
        fail "ALLOW_SUBAGENTS=$value was accepted"
    fi
    assert_contains "$TMP/subagents-$value.out" 'ALLOW_SUBAGENTS must be true or false'
    if COMMITMENT_SKIP_BUILD=1 "$ROOT/install.sh" >"$TMP/install-subagents-$value.out" 2>&1; then
        fail "installer accepted ALLOW_SUBAGENTS=$value"
    fi
    assert_contains "$TMP/install-subagents-$value.out" 'ALLOW_SUBAGENTS must be true or false'
    cp "$TMP/config.valid" "$CONFIG"
done
pass "single-agent default, explicit task opt-in, and boolean validation"

cp "$CONFIG" "$TMP/config.valid"
for name in OLLAMA_CONTEXT OLLAMA_OUTPUT; do
    sed -i "/^$name=/d" "$CONFIG"
    if "$HOME/.local/bin/commitment" >"$TMP/$name-missing.out" 2>&1; then fail "$name missing value was accepted"; fi
    assert_contains "$TMP/$name-missing.out" "$name is required"
    cp "$TMP/config.valid" "$CONFIG"
    for value in 0 -1 invalid; do
        sed -i "s/^$name=.*/$name=$value/" "$CONFIG"
        if "$HOME/.local/bin/commitment" >"$TMP/$name-$value.out" 2>&1; then fail "$name=$value was accepted"; fi
        assert_contains "$TMP/$name-$value.out" "$name must be a positive integer"
        cp "$TMP/config.valid" "$CONFIG"
    done
    sed -i "s/^$name=.*/$name=invalid/" "$CONFIG"
    if COMMITMENT_SKIP_BUILD=1 "$ROOT/install.sh" >"$TMP/install-$name.out" 2>&1; then fail "installer accepted invalid $name"; fi
    assert_contains "$TMP/install-$name.out" "$name must be a positive integer"
    cp "$TMP/config.valid" "$CONFIG"
done
pass "Ollama context and output validation"

sed -i \
    -e 's|^OLLAMA_MODEL=.*|OLLAMA_MODEL=operator/model:custom|' \
    -e 's|^OLLAMA_CONTEXT=.*|OLLAMA_CONTEXT=16384|' \
    -e 's|^OLLAMA_OUTPUT=.*|OLLAMA_OUTPUT=4096|' \
    "$CONFIG"
"$HOME/.local/bin/commitment" >/dev/null
jq -e '
    .model == "ollama/operator/model:custom" and
    .provider.ollama.models["operator/model:custom"].name == "operator/model:custom" and
    .provider.ollama.models["operator/model:custom"].limit.context == 16384 and
    .provider.ollama.models["operator/model:custom"].limit.output == 4096
' "$XDG_DATA_HOME/commitment/opencode-config/opencode.json" >/dev/null || fail "custom Ollama model limits were not generated"
cp "$TMP/config.valid" "$CONFIG"
pass "operator-selected Ollama model and limits"

[[ $(git -C "$TMP/commitment" log -1 --format=%s) == checkpoint:* ]] || fail "commitment checkpoint missing"
[[ $(git -C "$TMP/lab" log -1 --format=%s) == checkpoint:* ]] || fail "lab checkpoint missing"
[[ $("$TMP/lab/small-program") == revised ]] || fail "program revision did not survive"
mount_count=$(grep -cE ':/workspace/commitment(-lab)?:rw,Z|:/home/commitment/\.config/opencode/opencode.json:ro,Z|:/home/commitment/\.local/share/opencode:rw,Z|:/usr/local/bin/commitment-(outcome|log|secret):ro,Z' "$FAKE_PODMAN_ARGS")
[[ $mount_count -eq 7 ]] || fail "expected exactly seven intended mounts with secrets disabled"
grep -Fxq "$HOME/.local/libexec/commitment/commitment-log.sh:/usr/local/bin/commitment-log:ro,Z" "$FAKE_PODMAN_ARGS" ||
    fail "installed runlog helper was not mounted read-only"
! grep -Fq "$HOME:" "$FAKE_PODMAN_ARGS" || fail "home directory was mounted"
! grep -Fq 'GITHUB_TOKEN' "$FAKE_PODMAN_ARGS" || fail "GitHub credential was passed"
! grep -Eq 'BWS_ACCESS_TOKEN|BITWARDEN_|bitwarden-secrets-token' "$FAKE_PODMAN_ARGS" || fail "Bitwarden credential/config was passed"
grep -Fxq -- '--http-proxy=false' "$FAKE_PODMAN_ARGS" || fail "creative proxy forwarding enabled"
pass "configuration generation, both workspaces, checkpoints, program revision, and mount boundary"

exec 8>"$XDG_DATA_HOME/commitment/run.lock"
flock -n 8
if "$HOME/.local/bin/commitment" >"$TMP/overlap.out" 2>&1; then fail "overlap was allowed"; fi
assert_contains "$TMP/overlap.out" 'another run is active'
flock -u 8
pass "overlapping run prevention"

printf '%s\n' dirty >"$TMP/commitment/dirty.txt"
if "$HOME/.local/bin/commitment" >"$TMP/dirty.out" 2>&1; then fail "dirty start was allowed"; fi
assert_file "$TMP/commitment/dirty.txt"
assert_contains "$TMP/dirty.out" 'dirty state preserved'
git -C "$TMP/commitment" clean -f >/dev/null
pass "unexpected dirty state preservation"

git -C "$TMP/commitment" remote set-url origin 'https://example:secret@example.invalid/repo.git'
if "$HOME/.local/bin/commitment" >"$TMP/credential.out" 2>&1; then fail "embedded credential reached container launch"; fi
assert_contains "$TMP/credential.out" 'credential-bearing remote URL is forbidden'
git -C "$TMP/commitment" remote set-url origin "$TMP/commitment.remote"
pass "embedded repository credential rejection"

sed -i 's/^PUBLISH_MODE=.*/PUBLISH_MODE=push/' "$CONFIG"
sed -i 's/^CONTINUE_SESSION=.*/CONTINUE_SESSION=true/' "$CONFIG"
"$HOME/.local/bin/commitment" >/dev/null
grep -Fxq -- '--continue' "$FAKE_PODMAN_ARGS" || fail "native session continuation was not requested"
local_head=$(git -C "$TMP/lab" rev-parse HEAD)
remote_head=$(git --git-dir="$TMP/lab.remote" rev-parse refs/heads/main)
[[ $local_head == "$remote_head" ]] || fail "push mode did not publish lab"
pass "trusted local publishing"

lab_before_noop=$(git --git-dir="$TMP/lab.remote" rev-parse refs/heads/main)
FAKE_BOOKKEEPING_ONLY=1 FAKE_SESSION_OUTCOME=NOOP "$HOME/.local/bin/commitment" >/dev/null
[[ $(git --git-dir="$TMP/commitment.remote" log -1 --format=%s) == 'chore: record NOOP session bookkeeping' ]] ||
    fail "bookkeeping-only NOOP was not published through the existing path"
[[ $(git --git-dir="$TMP/lab.remote" rev-parse refs/heads/main) == "$lab_before_noop" ]] ||
    fail "NOOP changed the lab repository"
pass "bookkeeping-only NOOP checkpoint and publication"

COMMITMENT_FAKE_TOKEN=commitment-fake-token
LAB_FAKE_TOKEN=lab-fake-token
export FAKE_GIT_AUTH_LOG="$TMP/git-auth.log"
export FAKE_GH_LOG="$TMP/gh.log"
printf '%s\n' "$COMMITMENT_FAKE_TOKEN" >"$XDG_CONFIG_HOME/commitment/commitment-github-token"
printf '%s\n' "$LAB_FAKE_TOKEN" >"$XDG_CONFIG_HOME/commitment/lab-github-token"
chmod 600 "$XDG_CONFIG_HOME/commitment/commitment-github-token" "$XDG_CONFIG_HOME/commitment/lab-github-token"
cat >"$TMP/fakebin/git" <<'EOF'
#!/bin/sh
case " $* " in
    *' fetch '*|*' push '*)
        if [ -n "${GIT_ASKPASS:-}" ]; then
            printf '%s|%s\n' "$("$GIT_ASKPASS" Password)" "$*" >>"$FAKE_GIT_AUTH_LOG"
        fi
        ;;
esac
exec "$REAL_GIT" "$@"
EOF
cat >"$TMP/fakebin/gh" <<'EOF'
#!/bin/sh
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >>"$FAKE_GH_LOG"
EOF
chmod +x "$TMP/fakebin/git" "$TMP/fakebin/gh"

"$REAL_GIT" --git-dir="$XDG_DATA_HOME/commitment/trusted/commitment.git" config \
    url."$TMP/commitment.remote".insteadOf https://github.com/example/commitment.git
"$REAL_GIT" --git-dir="$XDG_DATA_HOME/commitment/trusted/lab.git" config \
    url."$TMP/lab.remote".insteadOf https://github.com/example/commitment-lab.git
sed -i \
    -e 's|^COMMITMENT_UPSTREAM_URL=.*|COMMITMENT_UPSTREAM_URL=https://github.com/example/commitment.git|' \
    -e 's|^LAB_UPSTREAM_URL=.*|LAB_UPSTREAM_URL=https://github.com/example/commitment-lab.git|' \
    "$CONFIG"
PUBLISHER="$HOME/.local/libexec/commitment/publish.sh"
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" sync commitment
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" sync lab
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" push commitment
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" push lab
grep -Fq "$COMMITMENT_FAKE_TOKEN|--git-dir=$XDG_DATA_HOME/commitment/trusted/commitment.git fetch" "$FAKE_GIT_AUTH_LOG" ||
    fail "commitment fetch did not use its token"
grep -Fq "$COMMITMENT_FAKE_TOKEN|--git-dir=$XDG_DATA_HOME/commitment/trusted/commitment.git push" "$FAKE_GIT_AUTH_LOG" ||
    fail "commitment push did not use its token"
grep -Fq "$LAB_FAKE_TOKEN|--git-dir=$XDG_DATA_HOME/commitment/trusted/lab.git fetch" "$FAKE_GIT_AUTH_LOG" ||
    fail "lab fetch did not use its token"
grep -Fq "$LAB_FAKE_TOKEN|--git-dir=$XDG_DATA_HOME/commitment/trusted/lab.git push" "$FAKE_GIT_AUTH_LOG" ||
    fail "lab push did not use its token"
! grep -F "$COMMITMENT_FAKE_TOKEN|" "$FAKE_GIT_AUTH_LOG" | grep -Fq '/trusted/lab.git' || fail "commitment token reached lab Git"
! grep -F "$LAB_FAKE_TOKEN|" "$FAKE_GIT_AUTH_LOG" | grep -Fq '/trusted/commitment.git' || fail "lab token reached commitment Git"

printf '%s\n' body >"$TMP/issue-body"
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" issue-list commitment >/dev/null
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" issue-list lab >/dev/null
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" issue-create commitment title "$TMP/issue-body" >/dev/null
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" issue-create lab title "$TMP/issue-body" >/dev/null
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" issue-comment commitment 1 "$TMP/issue-body" >/dev/null
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" issue-comment lab 1 "$TMP/issue-body" >/dev/null
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" issue-close commitment 1 >/dev/null
COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" issue-close lab 1 >/dev/null
[[ $(grep -Fc "$COMMITMENT_FAKE_TOKEN|" "$FAKE_GH_LOG") -eq 4 ]] || fail "commitment issue operations used the wrong token"
[[ $(grep -Fc "$LAB_FAKE_TOKEN|" "$FAKE_GH_LOG") -eq 4 ]] || fail "lab issue operations used the wrong token"
! grep -F "$COMMITMENT_FAKE_TOKEN|" "$FAKE_GH_LOG" | grep -Fq 'example/commitment-lab' || fail "commitment token reached lab issues"
! grep -F "$LAB_FAKE_TOKEN|" "$FAKE_GH_LOG" | grep -Fq 'example/commitment ' || fail "lab token reached commitment issues"

sed -i 's|^COMMITMENT_GITHUB_TOKEN_FILE=.*|COMMITMENT_GITHUB_TOKEN_FILE=|' "$CONFIG"
if COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" issue-list commitment >"$TMP/no-commitment-token.out" 2>&1; then
    fail "lab token substituted for missing commitment token"
fi
assert_contains "$TMP/no-commitment-token.out" 'GitHub token is not configured for commitment; set COMMITMENT_GITHUB_TOKEN_FILE'
sed -i "s|^COMMITMENT_GITHUB_TOKEN_FILE=.*|COMMITMENT_GITHUB_TOKEN_FILE=$XDG_CONFIG_HOME/commitment/commitment-github-token|" "$CONFIG"
sed -i 's|^LAB_GITHUB_TOKEN_FILE=.*|LAB_GITHUB_TOKEN_FILE=|' "$CONFIG"
if COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" issue-list lab >"$TMP/no-lab-token.out" 2>&1; then
    fail "commitment token substituted for missing lab token"
fi
assert_contains "$TMP/no-lab-token.out" 'GitHub token is not configured for lab; set LAB_GITHUB_TOKEN_FILE'
sed -i "s|^LAB_GITHUB_TOKEN_FILE=.*|LAB_GITHUB_TOKEN_FILE=$XDG_CONFIG_HOME/commitment/lab-github-token|" "$CONFIG"
! rg -F "$COMMITMENT_FAKE_TOKEN" "$TMP/commitment" "$TMP/lab" >/dev/null || fail "commitment token entered agent repositories"
! rg -F "$LAB_FAKE_TOKEN" "$TMP/commitment" "$TMP/lab" >/dev/null || fail "lab token entered agent repositories"
! grep -Fq "$COMMITMENT_FAKE_TOKEN" "$FAKE_PODMAN_ARGS" || fail "commitment token entered creative container arguments"
! grep -Fq "$LAB_FAKE_TOKEN" "$FAKE_PODMAN_ARGS" || fail "lab token entered creative container arguments"
! grep -Eq 'COMMITMENT_GITHUB_TOKEN|LAB_GITHUB_TOKEN|commitment-github-token|lab-github-token' "$FAKE_PODMAN_ALL_ARGS" ||
    fail "GitHub token configuration entered agent container arguments"
printf '%s\n' agent-mounted-fake-token >"$XDG_DATA_HOME/commitment/opencode-data/token"
chmod 600 "$XDG_DATA_HOME/commitment/opencode-data/token"
sed -i "s|^COMMITMENT_GITHUB_TOKEN_FILE=.*|COMMITMENT_GITHUB_TOKEN_FILE=$XDG_DATA_HOME/commitment/opencode-data/token|" "$CONFIG"
if COMMITMENT_STATE_DIR="$XDG_DATA_HOME/commitment" "$PUBLISHER" checkpoint commitment >"$TMP/mounted-token.out" 2>&1; then
    fail "token file in an agent-mounted path was accepted"
fi
assert_contains "$TMP/mounted-token.out" 'COMMITMENT_GITHUB_TOKEN_FILE must be outside agent-mounted paths'
sed -i "s|^COMMITMENT_GITHUB_TOKEN_FILE=.*|COMMITMENT_GITHUB_TOKEN_FILE=$XDG_CONFIG_HOME/commitment/commitment-github-token|" "$CONFIG"
rm -f "$XDG_DATA_HOME/commitment/opencode-data/token"
pass "repository-specific GitHub tokens route across fetch, push, and issue operations without crossing agent boundaries"

sed -i \
    -e "s|^COMMITMENT_UPSTREAM_URL=.*|COMMITMENT_UPSTREAM_URL=$TMP/commitment.remote|" \
    -e "s|^LAB_UPSTREAM_URL=.*|LAB_UPSTREAM_URL=$TMP/lab.remote|" \
    "$CONFIG"

old_head=$(git -C "$TMP/commitment" rev-parse HEAD)
if FAKE_BREAK_REMOTE=1 "$HOME/.local/bin/commitment" >"$TMP/push-fail.out" 2>&1; then fail "push failure reported success"; fi
new_head=$(git -C "$TMP/commitment" rev-parse HEAD)
[[ $new_head != "$old_head" ]] || fail "local checkpoint was not preserved after push failure"
assert_contains "$TMP/push-fail.out" 'push failed; local commits preserved'
mv "$TMP/commitment.remote.off" "$TMP/commitment.remote"
pass "accurate push failure with local preservation"

"$ROOT/uninstall.sh" >/dev/null
[[ ! -e "$HOME/.local/bin/commitment" ]] || fail "launcher survived uninstall"
[[ ! -e "$XDG_CONFIG_HOME/systemd/user/commitment.timer" ]] || fail "timer survived uninstall"
[[ ! -e "$HOME/.local/libexec/commitment/commitment-log.sh" ]] || fail "runlog helper survived uninstall"
[[ ! -e "$HOME/.local/libexec/commitment/session-outcome.sh" ]] || fail "outcome helper survived uninstall"
[[ ! -e "$HOME/.local/libexec/commitment/inbox-context.sh" ]] || fail "inbox helper survived uninstall"
[[ ! -e "$HOME/.local/libexec/commitment/queue-context.sh" ]] || fail "queue helper survived uninstall"
assert_file "$XDG_CONFIG_HOME/commitment/config.env"
assert_file "$XDG_DATA_HOME/commitment/opencode-data/preserved"
assert_file "$TMP/lab/small-program"
pass "uninstall preserves user and workspace data"

if command -v systemd-analyze >/dev/null; then
    unit_tmp="$TMP/units"
    mkdir -p "$unit_tmp"
    cp "$ROOT/systemd/commitment.service.in" "$unit_tmp/commitment.service"
    sed 's/@SCHEDULE@/daily/' "$ROOT/systemd/commitment.timer.in" >"$unit_tmp/commitment.timer"
    if systemd-analyze --user verify "$unit_tmp/commitment.service" "$unit_tmp/commitment.timer"; then
        pass "generated systemd units validate"
    else
        printf 'skip - systemd user verification unavailable in this sandbox\n'
    fi
else
    printf 'skip - systemd-analyze unavailable\n'
fi
