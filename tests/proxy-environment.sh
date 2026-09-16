#!/usr/bin/env bash
# Real production launch paths, offline probe in place of the model. No host config.
set -euo pipefail
ROOT=${COMMITMENT_TEST_SOURCE:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
IMAGE=${COMMITMENT_TEST_IMAGE:?Set COMMITMENT_TEST_IMAGE}
TMP=$(mktemp -d)
cleanup() {
    local status=$?
    if (( status != 0 )); then
        for output in "$TMP/creative.err" "$TMP/git.err"; do
            [[ ! -f $output ]] || cat "$output" >&2
        done
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
export PROXY_TEST_ROOT="$TMP" PROXY_TEST_IMAGE="$IMAGE"
export PROXY_TEST_PODMAN
PROXY_TEST_PODMAN=$(command -v podman)
[[ $("$PROXY_TEST_PODMAN" info --format '{{.Host.Security.Rootless}}') == true ]]
mkdir -m 700 "$TMP/bin" "$TMP/state" "$TMP/runtime" "$TMP/commitment" "$TMP/lab"
for repo in commitment lab; do
    git init -q -b main "$TMP/$repo"
    git -C "$TMP/$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
        commit -q --allow-empty -m fixture
done
cp "$ROOT/run.sh" "$ROOT/inbox-context.sh" "$ROOT/queue-context.sh" "$ROOT/secret-broker.py" "$ROOT/commitment-secret.py" \
    "$ROOT/prompt.txt" "$ROOT/session-outcome.sh" "$ROOT/commitment-log.sh" "$TMP/runtime/"
cat >"$TMP/config.env" <<EOF
COMMITMENT_REPO=$TMP/commitment
LAB_REPO=$TMP/lab
COMMITMENT_BRANCH=main
LAB_BRANCH=main
COMMITMENT_UPSTREAM_URL=$TMP/commitment.remote
LAB_UPSTREAM_URL=$TMP/lab.remote
OLLAMA_ENDPOINT=http://host.containers.internal:11434
OLLAMA_MODEL=devstral-small-2-32k
OLLAMA_CONTEXT=32768
OLLAMA_OUTPUT=8192
SESSION_TIMEOUT=20
PUBLISH_MODE=checkpoint
CONTAINER_IMAGE=$IMAGE
GIT_AUTHOR_NAME=ProxyFixture
GIT_AUTHOR_EMAIL=fixture@example.invalid
BITWARDEN_SECRETS_ENABLED=false
EOF
cat >"$TMP/publisher" <<'EOF'
#!/bin/sh
case "$1" in
    session-head) printf '%040d\n' 0 ;;
    classify) printf '%s\n' changed=0 ;;
    sync|session-start|session-end|session-failure|checkpoint|finalize) exit 0 ;;
    *) exit 2 ;;
esac
EOF
cat >"$TMP/probe.py" <<'PY'
import os
import sys
names = ('http_proxy', 'https_proxy', 'ftp_proxy', 'no_proxy')
names += tuple(name.upper() for name in names)
assert not any(name in os.environ for name in names), 'proxy variable inherited'
assert not any('synthetic-' in value.lower() for value in os.environ.values()), 'proxy value inherited'
assert not any(name.startswith('BITWARDEN_') or name == 'BWS_ACCESS_TOKEN' for name in os.environ)
assert os.readlink('/proc/self/ns/pid') != os.environ['PROBE_HOST_PID_NAMESPACE']
assert not os.path.exists('/run/podman/podman.sock')
if sys.argv[1] == 'creative':
    assert os.environ['HOME'] == '/home/commitment'
    assert os.environ['GIT_AUTHOR_NAME'] == 'ProxyFixture'
    assert os.environ['COMMITMENT_SESSION_ID']
    assert os.path.isdir('/workspace/commitment/.git')
else:
    assert os.environ['AGENT_BRANCH'] == 'main'
    assert os.environ['AGENT_GIT_NAME'] == 'ProxyFixture'
print('PROXY_CHECK_OK_' + sys.argv[1], flush=True)
PY
cat >"$TMP/bin/podman" <<'PY'
#!/usr/bin/python3 -I
import os
import sys
args = sys.argv[1:]
if args[0] != 'run':
    os.execv(os.environ['PROXY_TEST_PODMAN'], ['podman', *args])
index = args.index(os.environ['PROXY_TEST_IMAGE'])
options, command = args[:index], args[index + 1:]
creative = command[0] == 'opencode'
assert not any(arg in ('--privileged', '--pid=host', '--network=host') for arg in options)
mounts = [options[i + 1] for i, arg in enumerate(options) if arg == '-v']
assert all(mount.startswith(os.environ['PROXY_TEST_ROOT'] + '/') or
           mount.startswith(os.environ.get('COMMITMENT_AGENT_GIT', '/not-mounted') + ':') for mount in mounts)
assert all('podman.sock' not in mount and 'token' not in mount for mount in mounts)
# Only replace the model command. Git runs its real helper after the probe.
probe = ['python3', '/proxy-probe.py', 'creative' if creative else 'git']
if not creative:
    probe = ['sh', '-ec', 'python3 /proxy-probe.py git; exec "$@"', 'probe', *command]
if creative:
    options += ['--network=none']
options += ['-v', os.environ['PROXY_TEST_ROOT'] + '/probe.py:/proxy-probe.py:ro,Z',
            '-e', 'PROBE_HOST_PID_NAMESPACE=' + os.readlink('/proc/self/ns/pid')]
os.execv(os.environ['PROXY_TEST_PODMAN'], ['podman', *options, os.environ['PROXY_TEST_IMAGE'], *probe])
PY
chmod 700 "$TMP/bin/podman" "$TMP/publisher"
# Overwrite ALL recognized names, regardless of the invoking shell's settings.
for name in http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY; do
    export "$name=http://synthetic-$name:synthetic-password-$name@example.invalid:1234"
done
export PATH="$TMP/bin:$PATH" COMMITMENT_CONFIG="$TMP/config.env" COMMITMENT_STATE_DIR="$TMP/state"
status=0
COMMITMENT_PUBLISHER="$TMP/publisher" "$TMP/runtime/run.sh" >"$TMP/creative.out" 2>"$TMP/creative.err" || status=$?
# A probe has no trusted outcome; the launcher must report that expected failure.
[[ $status == 1 ]]
grep -Fxq PROXY_CHECK_OK_creative "$TMP/creative.out"
COMMITMENT_AGENT_GIT="$ROOT/agent-git.sh" "$ROOT/publish.sh" session-head commitment >"$TMP/git.out" 2>"$TMP/git.err"
grep -Fxq PROXY_CHECK_OK_git "$TMP/git.out"
printf 'ok - real creative and publisher Git-helper paths reject all eight host proxies; required env and private PID namespace survive\n'
