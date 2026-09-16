#!/usr/bin/env python3
"""Disposable launcher tests only: real local Git, synthetic creative process."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

args = sys.argv[1:]
root = Path(os.environ['FIXTURE_ROOT'])
if args[0] == 'info':
    print('true')
    sys.exit(0)
if args[0] in ('stop', 'rm'):
    try:
        os.kill(int((root / 'creative.pid').read_text()), signal.SIGTERM)
    except (FileNotFoundError, ProcessLookupError):
        pass
    sys.exit(0)
assert args[0] == 'run', args
assert '--http-proxy=false' in args
assert '--security-opt=no-new-privileges' in args
assert '--privileged' not in args and '--network=host' not in args
mounts, passed = {}, {}
for i, arg in enumerate(args):
    if arg == '-v':
        source, target, flags = args[i+1].rsplit(':', 2)
        mounts[target] = (source, flags)
    if arg == '-e':
        key, value = args[i+1].split('=', 1)
        passed[key] = value
assert not any('TOKEN' in key or key.startswith('BITWARDEN_') for key in passed)
assert not any('podman.sock' in target for target in mounts)
command = args[args.index('fixture')+1:]

def translate(value):
    for target in sorted(mounts, key=len, reverse=True):
        if value == target or value.startswith(target + '/'):
            return mounts[target][0] + value[len(target):]
    return value

env = {'PATH': os.environ['PATH'], 'HOME': str(root / 'home'),
       'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null', **passed}
if command[0] != 'opencode':
    assert '--network=none' in args
    env['AGENT_REPO'] = mounts['/workspace/repo'][0]
    result = subprocess.run([translate(value) for value in command], env=env)
    sys.exit(result.returncode)

(root / 'creative.pid').write_text(str(os.getpid()))
(root / 'creative.args').write_text(json.dumps(args))
mode = os.environ.get('FIXTURE_MODE', 'NOOP')
repo = Path(mounts['/workspace/commitment'][0])
lab = Path(mounts['/workspace/commitment-lab'][0])
if mode != 'empty':
    (lab / 'progress.txt').write_text('useful unfinished work\n')
(root / 'ready').touch()
if os.environ.get('FIXTURE_BREAK_REMOTE'):
    remote = root / 'lab.remote'
    remote.rename(root / 'lab.offline')
marker = Path(translate(passed['COMMITMENT_OUTCOME_FILE']))
env['COMMITMENT_OUTCOME_FILE'] = str(marker)
env['COMMITMENT_ROOT'] = str(repo)
if mode in {'NOOP', 'COMMITTED_CHANGE', 'CHECKPOINT_UNFINISHED', 'FAILED'}:
    subprocess.run([translate('/usr/local/bin/commitment-outcome'), mode,
                    'Synthetic completed execution'], env=env, check=True)
    time.sleep(30)
    (root / 'post-outcome').touch()
elif mode in {'stale', 'malformed'}:
    marker.write_text('{broken' if mode == 'malformed' else json.dumps({
        'session_id': 'old-session', 'outcome': 'NOOP', 'summary': 'stale'}))
    time.sleep(1)
    (root / 'natural-exit').touch()
elif mode == 'wait':
    time.sleep(30)
elif mode == 'nonzero':
    sys.exit(42)
