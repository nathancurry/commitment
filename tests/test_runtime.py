#!/usr/bin/env python3
"""Behavioral contracts for the small runtime, without model or external services."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Runtime(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='commitment-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {**os.environ, 'GIT_CONFIG_NOSYSTEM': '1',
                    'GIT_CONFIG_GLOBAL': '/dev/null', 'COMMITMENT_SESSION_ID': 'fixture',
                    'COMMITMENT_OUTCOME_FILE': str(self.root / 'outcome')}
        for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
            self.env.pop(key, None)
        self.repo = self.new_repo('commitment')
        self.lab = self.new_repo('lab')
        self.env['COMMITMENT_ROOT'] = str(self.repo)
        self.env.update(AGENT_REPO=str(self.repo), AGENT_BRANCH='main',
                        AGENT_REPO_KIND='commitment', AGENT_GIT_NAME='Fixture',
                        AGENT_GIT_EMAIL='fixture@example.invalid',
                        AGENT_BASE_HEAD=self.git(self.repo, 'rev-parse', 'HEAD').stdout.strip())

    def call(self, *args, env=None, check=True):
        result = subprocess.run([str(x) for x in args], env=env or self.env,
                                text=True, capture_output=True, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def git(self, repo, *args, **kw):
        return self.call('git', '-C', repo, *args, **kw)

    def new_repo(self, name):
        repo = self.root / name
        self.call('git', 'init', '-q', '-b', 'main', repo)
        self.git(repo, 'config', 'user.name', 'Fixture')
        self.git(repo, 'config', 'user.email', 'fixture@example.invalid')
        (repo / 'base').write_text('original\n')
        (repo / 'VERSION').write_text('0.3.7\n')
        self.git(repo, 'add', '.')
        self.git(repo, 'commit', '-qm', 'initial')
        self.call('git', 'init', '-q', '--bare', '--initial-branch=main', self.root / f'{name}.remote')
        self.git(repo, 'remote', 'add', 'origin', str(self.root / f'{name}.remote'))
        self.git(repo, 'push', '-q', '-u', 'origin', 'main')
        return repo

    def test_outcomes_have_no_workflow_prerequisites(self):
        queue = self.repo / 'queue'
        queue.mkdir()
        for i, content in enumerate(['no metadata', 'status: ready', '---\nstatus: strange',
                                     '---\nstatus: candidate\nstatus: done\n---']):
            (queue / str(i)).write_text(content)
        for outcome in ['NOOP', 'COMMITTED_CHANGE', 'CHECKPOINT_UNFINISHED', 'FAILED']:
            with self.subTest(outcome=outcome):
                marker = Path(self.env['COMMITMENT_OUTCOME_FILE'])
                marker.unlink(missing_ok=True)
                self.call(ROOT / 'session-outcome.sh', outcome, '  safe\nsummary\t ')
                self.assertEqual(self.call(ROOT / 'session-outcome.sh', '--read').stdout.strip(), outcome)
                self.assertEqual(json.loads(marker.read_text())['summary'], 'safe summary')
                self.assertNotEqual(self.call(ROOT / 'session-outcome.sh', outcome, 'again', check=False).returncode, 0)
                self.assertFalse((self.repo / 'runlog.jsonl').exists())

    def test_marker_rejects_stale_malformed_multirecord_and_unsafe_summary(self):
        marker = Path(self.env['COMMITMENT_OUTCOME_FILE'])
        valid = {'session_id': 'fixture', 'outcome': 'NOOP', 'summary': 'ok'}
        for content in ['{', json.dumps({**valid, 'session_id': 'old'}),
                        json.dumps({**valid, 'outcome': 'UNKNOWN'}),
                        json.dumps({**valid, 'summary': 'unsafe\x00'}),
                        json.dumps(valid) + '\n' + json.dumps(valid),
                        json.dumps({**valid, 'summary': ''})]:
            marker.write_text(content)
            self.assertNotEqual(self.call(ROOT / 'session-outcome.sh', '--read', check=False).returncode, 0)
        marker.unlink()
        marker.symlink_to(self.repo / 'base')
        self.assertNotEqual(self.call(ROOT / 'session-outcome.sh', '--read', check=False).returncode, 0)
        self.assertNotEqual(self.call(ROOT / 'session-outcome.sh', 'NOOP', 'ok', check=False).returncode, 0)
        self.assertEqual((self.repo / 'base').read_text(), 'original\n')

    def test_context_lists_filenames_without_reading_notes(self):
        for directory, helper, label in [('queue', 'queue-context.sh', 'Queue file:'),
                                          ('inbox', 'inbox-context.sh', 'Operator inbox file:')]:
            folder = self.repo / directory
            folder.mkdir()
            (folder / 'README.md').write_text('ignored')
            (folder / 'nested').mkdir()
            (folder / 'nested' / 'hidden').touch()
            (folder / '2026-note.md').write_text('status: made-up\nsecret policy words')
            (folder / 'space name').write_text('status: ready')
            before = (folder / '2026-note.md').read_bytes()
            output = self.call(ROOT / helper, self.repo).stdout
            self.assertEqual(len(output.splitlines()), 2)
            self.assertIn(f'{label} {directory}/2026-note.md', output)
            self.assertNotIn('status', output)
            self.assertNotIn('README', output)
            self.assertNotIn('hidden', output)
            self.assertEqual((folder / '2026-note.md').read_bytes(), before)

    def test_logging_tolerates_fields_schemas_and_storage_errors(self):
        log = self.repo / 'runlog.jsonl'
        log.write_text('legacy non-JSON\n')
        for kind in ['research', 'test', 'whatever']:
            self.call(ROOT / 'commitment-log.sh', kind, 'quoted "line"\nnext',
                      'custom=value', 'result=', 'bad-argument', 'session_id=forged')
        self.assertTrue(log.read_text().startswith('legacy non-JSON\n'))
        rows = [json.loads(x) for x in log.read_text().splitlines()[1:]]
        self.assertEqual(len(rows), 3)
        self.assertTrue(all(r['session_id'] == 'fixture' and r['custom'] == 'value' for r in rows))
        log.unlink()
        log.mkdir()
        result = self.call(ROOT / 'commitment-log.sh', 'test', 'no storage')
        self.assertIn('not recorded', result.stderr)

    def test_conservative_changes_and_preservation_for_every_label(self):
        self.call(ROOT / 'agent-git.sh', 'session-start')
        self.assertEqual(self.call(ROOT / 'agent-git.sh', 'classify').stdout.strip(), 'changed=0')
        for i, outcome in enumerate(['NOOP', 'COMMITTED_CHANGE', 'FAILED', 'CHECKPOINT_UNFINISHED']):
            folder = self.repo / ['queue', 'requests', 'memory', 'inbox'][i]
            folder.mkdir()
            (folder / 'arbitrary').write_text(outcome)
            self.assertEqual(self.call(ROOT / 'agent-git.sh', 'classify').stdout.strip(), 'changed=1')
            self.call(ROOT / 'agent-git.sh', 'finalize', env={**self.env, 'AGENT_OUTCOME': outcome})
            self.assertEqual(self.git(self.repo, 'status', '--porcelain').stdout, '')
            self.assertEqual(self.git(self.repo, 'show', f'HEAD:{folder.name}/arbitrary').stdout, outcome)
        self.assertEqual((self.repo / 'VERSION').read_text(), '0.3.7\n')

    def test_staged_untracked_deleted_and_committed_work_is_detected(self):
        (self.repo / 'base').unlink()
        self.assertIn('changed=1', self.call(ROOT / 'agent-git.sh', 'classify').stdout)
        self.git(self.repo, 'add', '-A')
        self.assertIn('changed=1', self.call(ROOT / 'agent-git.sh', 'classify').stdout)
        self.git(self.repo, 'commit', '-qm', 'delete base')
        self.assertIn('changed=1', self.call(ROOT / 'agent-git.sh', 'classify').stdout)
        # Runlog is excluded only in Commitment, not arbitrary lab software.
        base = self.git(self.lab, 'rev-parse', 'HEAD').stdout.strip()
        (self.lab / 'runlog.jsonl').write_text('lab output')
        self.assertIn('changed=1', self.call(ROOT / 'agent-git.sh', 'classify', env={
            **self.env, 'AGENT_REPO': str(self.lab), 'AGENT_REPO_KIND': 'lab',
            'AGENT_BASE_HEAD': base}).stdout)

    def test_checkpoint_on_experiment_branch_and_conflict_preservation(self):
        self.git(self.repo, 'switch', '-qc', 'experiment')
        (self.repo / 'base').write_text('experiment\n')
        self.call(ROOT / 'agent-git.sh', 'checkpoint')
        self.assertEqual(self.git(self.repo, 'branch', '--show-current').stdout.strip(), 'experiment')
        self.assertNotEqual(self.call(ROOT / 'agent-git.sh', 'export', self.root / 'export.bundle', check=False).returncode, 0)
        self.git(self.repo, 'switch', '-q', 'main')
        (self.repo / 'base').write_text('main\n')
        self.git(self.repo, 'commit', '-qam', 'main edit')
        self.git(self.repo, 'merge', 'experiment', check=False)
        before = self.git(self.repo, 'ls-files', '-u').stdout
        self.assertTrue(before)
        self.assertNotEqual(self.call(ROOT / 'agent-git.sh', 'checkpoint', check=False).returncode, 0)
        self.assertEqual(self.git(self.repo, 'ls-files', '-u').stdout, before)

    def prepare_launcher(self, **settings):
        runtime = self.root / 'runtime'
        runtime.mkdir(exist_ok=True)
        for name in ['run.sh', 'publish.sh', 'agent-git.sh', 'session-outcome.sh',
                     'commitment-log.sh', 'queue-context.sh', 'inbox-context.sh',
                     'secret-broker.py', 'commitment-secret.py', 'planner-broker.py',
                     'commitment-plan.py', 'prompt.txt']:
            shutil.copy2(ROOT / name, runtime / name)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir(exist_ok=True)
        shutil.copy2(ROOT / 'tests/fixtures/podman.py', bin_dir / 'podman')
        (self.root / 'home').mkdir(exist_ok=True)
        config = dict(COMMITMENT_REPO=str(self.repo), LAB_REPO=str(self.lab),
                      COMMITMENT_BRANCH='main', LAB_BRANCH='main',
                      COMMITMENT_UPSTREAM_URL=str(self.root / 'commitment.remote'),
                      LAB_UPSTREAM_URL=str(self.root / 'lab.remote'),
                      OLLAMA_ENDPOINT='http://host.containers.internal:11434',
                      OLLAMA_MODEL='fixture', OLLAMA_CONTEXT='32768', OLLAMA_OUTPUT='8192',
                      SESSION_TIMEOUT='10', PUBLISH_MODE='checkpoint', CONTAINER_IMAGE='fixture',
                      GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                      BITWARDEN_SECRETS_ENABLED='false',
                      CHEAPERINFERENCE_API_KEY_FILE=str(self.root / 'operator/cheaperinference-api-key'))
        config.update(settings)
        (self.root / 'config.env').write_text(''.join(f'{k}={v}\n' for k, v in config.items()))
        self.launch_env = {**self.env, 'FIXTURE_ROOT': str(self.root),
                           'COMMITMENT_CONFIG': str(self.root / 'config.env'),
                           'COMMITMENT_STATE_DIR': str(self.root / 'state'),
                           'PATH': str(bin_dir) + ':' + os.environ['PATH']}
        # These are deliberately supplied to the HOST, never the creative arguments.
        self.launch_env['BWS_ACCESS_TOKEN'] = 'host-only-fixture'
        self.launch_env['OPENROUTER_API_KEY'] = 'host-env-openrouter-fixture'
        self.launch_env['CHEAPERINFERENCE_API_KEY'] = 'host-env-cheaperinference-fixture'
        return runtime / 'run.sh'

    def launch(self, mode='NOOP', check=True, **settings):
        path = self.prepare_launcher(**settings)
        return self.call(path, env={**self.launch_env, 'FIXTURE_MODE': mode}, check=check)

    def ends(self):
        return [r for r in (json.loads(x) for x in (self.repo / 'runlog.jsonl').read_text().splitlines())
                if r.get('type') == 'session_end']

    def assert_saved(self):
        self.assertEqual(self.git(self.lab, 'show', 'HEAD:progress.txt').stdout, 'useful unfinished work\n')
        self.assertEqual(self.git(self.lab, 'status', '--porcelain').stdout, '')

    def test_commitment_agent_is_visible_default_and_explicitly_selected(self):
        agent = self.repo / '.opencode/agents/commitment.md'
        agent.parent.mkdir(parents=True)
        shutil.copy2(ROOT / '.opencode/agents/commitment.md', agent)
        self.launch()

        config = json.loads((self.root / 'state/opencode-config/opencode.json').read_text())
        self.assertEqual(config['default_agent'], 'commitment')
        self.assertNotEqual(config['default_agent'], 'build')

        args = json.loads((self.root / 'creative.args').read_text())
        command = args[args.index('fixture') + 1:]
        self.assertEqual(command[:2], ['opencode', 'run'])
        self.assertEqual(command[command.index('--agent') + 1], 'commitment')
        self.assertNotIn('build', command)
        self.assertEqual(agent.read_bytes(),
                         (ROOT / '.opencode/agents/commitment.md').read_bytes())

    def test_valid_outcomes_stop_and_preserve(self):
        for outcome in ['NOOP', 'COMMITTED_CHANGE', 'CHECKPOINT_UNFINISHED', 'FAILED']:
            with self.subTest(outcome=outcome):
                result = self.launch(outcome, check=False)
                self.assertEqual(result.returncode, 1 if outcome == 'FAILED' else 0, result.stderr)
                self.assertFalse((self.root / 'post-outcome').exists())
                self.assertEqual(self.ends()[-1]['outcome'], outcome)
                self.assert_saved()

    def test_missing_stale_malformed_and_nonzero_preserve(self):
        for mode in ['missing', 'stale', 'malformed', 'nonzero']:
            # Each run must have new work, including after the preceding checkpoint.
            (self.lab / 'progress.txt').unlink(missing_ok=True)
            if self.git(self.lab, 'status', '--porcelain').stdout:
                self.git(self.lab, 'commit', '-qam', 'prepare next fixture')
            result = self.launch(mode)
            self.assertIn('CHECKPOINT_UNFINISHED', result.stderr)
            self.assertEqual(self.ends()[-1]['outcome'], 'CHECKPOINT_UNFINISHED')
            if mode in ['stale', 'malformed']:
                self.assertTrue((self.root / 'natural-exit').exists())
                (self.root / 'natural-exit').unlink()
            self.assert_saved()

    def test_empty_missing_outcome_is_failed(self):
        result = self.launch('empty', check=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.ends()[-1]['outcome'], 'FAILED')

    def test_timeout_preserves(self):
        result = self.launch('wait', SESSION_TIMEOUT='1')
        self.assertIn('exit 124', result.stderr)
        self.assert_saved()

    def test_term_and_int_preserve(self):
        for sig in [signal.SIGTERM, signal.SIGINT]:
            path = self.prepare_launcher()
            (self.root / 'ready').unlink(missing_ok=True)
            env = {**self.launch_env, 'FIXTURE_MODE': 'wait'}
            with subprocess.Popen([str(path)], env=env, text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE) as proc:
                deadline = time.monotonic() + 10
                while not (self.root / 'ready').exists() and proc.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue((self.root / 'ready').exists())
                proc.send_signal(sig)
                out, err = proc.communicate(timeout=15)
            self.assertEqual(proc.returncode, 128 + sig, out + err)
            self.assert_saved()

    def test_dirty_and_experiment_work_remain_inspectable(self):
        self.git(self.lab, 'switch', '-qc', 'experiment')
        (self.lab / 'interrupted').write_text('prior work')
        result = self.launch()
        self.assertIn('local work remains inspectable', result.stderr)
        self.assertEqual(self.git(self.lab, 'show', 'HEAD:interrupted').stdout, 'prior work')
        self.assertEqual(self.git(self.lab, 'branch', '--show-current').stdout.strip(), 'experiment')

    def test_optional_secret_and_logging_failures_do_not_block(self):
        (self.repo / 'runlog.jsonl').mkdir()
        result = self.launch(BITWARDEN_SECRETS_ENABLED='true')
        self.assertIn('continuing without secret access', result.stderr)
        self.assertIn('not logged', result.stderr)
        self.assert_saved()

    def test_planner_key_and_controls_stay_outside_creative_surfaces(self):
        operator = self.root / 'operator'
        operator.mkdir()
        key = operator / 'cheaperinference-api-key'
        material = 'fixture-cheaperinference-key-material'
        key.write_text(material + '\n')
        key.chmod(0o600)
        path = self.prepare_launcher(CHEAPERINFERENCE_API_KEY_FILE=str(key))
        result = self.call(path, env={**self.launch_env, 'FIXTURE_MODE': 'NOOP'})
        args = json.loads((self.root / 'creative.args').read_text())
        config = (self.root / 'state/opencode-config/opencode.json').read_text()
        surfaces = result.stdout + result.stderr + json.dumps(args) + config
        self.assertNotIn(material, surfaces)
        self.assertNotIn(str(key), json.dumps(args))
        self.assertNotIn('OPENROUTER_', json.dumps(args))
        self.assertNotIn('CHEAPERINFERENCE_', json.dumps(args))
        self.assertNotIn('PLANNER_', json.dumps(args))
        self.assertNotIn('openrouter', config.lower())
        self.assertNotIn('cheaperinference', config.lower())
        self.assertNotIn('host-env-openrouter-fixture', surfaces)
        self.assertNotIn('host-env-cheaperinference-fixture', surfaces)
        self.assertTrue(any('/usr/local/bin/commitment-plan:ro,Z' in arg for arg in args))
        self.assertTrue(any('/run/commitment-planner:ro,Z' in arg for arg in args))
        self.assertEqual(json.loads(config)['permission']['task'], 'deny')
        self.assertEqual(list((self.root / 'state').glob('planner-session.*')), [])

    def test_missing_planner_key_does_not_block_startup(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0)
        self.assert_saved()
        args = json.loads((self.root / 'creative.args').read_text())
        self.assertTrue(any('/run/commitment-planner:ro,Z' in arg for arg in args))

    def test_existing_config_without_planner_fields_remains_compatible(self):
        path = self.prepare_launcher()
        config = self.root / 'config.env'
        config.write_text(''.join(
            line for line in config.read_text().splitlines(keepends=True)
            if not (line.startswith('OPENROUTER_') or line.startswith('CHEAPERINFERENCE_')
                    or line.startswith('PLANNER_'))))
        result = self.call(path, env={
            **self.launch_env, 'FIXTURE_MODE': 'NOOP',
            'XDG_CONFIG_HOME': str(self.root / 'old-config-home')})
        self.assertEqual(result.returncode, 0)
        self.assert_saved()

    def test_planner_key_path_cannot_be_any_creative_mount_source(self):
        path = self.prepare_launcher(CHEAPERINFERENCE_API_KEY_FILE=str(
            self.root / 'runtime/commitment-plan.py'))
        result = self.call(path, env={**self.launch_env, 'FIXTURE_MODE': 'NOOP'}, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('outside all creative mounts', result.stderr)
        self.assertFalse((self.root / 'ready').exists())

    def test_unavailable_backend_with_installed_sdk_is_optional(self):
        path = self.prepare_launcher(BITWARDEN_SECRETS_ENABLED='true',
                                     BITWARDEN_PROJECT_ID='11111111-1111-4111-8111-111111111111')
        self.call('bash', ROOT / 'tests/fixtures/setup-sdk.sh', self.root / 'runtime')
        # No token file: the broker must expose an unavailable backend, not veto work.
        self.call(path, env={**self.launch_env, 'FAKE_SDK_DIR': str(self.root / 'fake-sdk')})
        self.assert_saved()
        self.assertEqual(list((self.root / 'state').glob('secrets-session.*')), [])

    def test_unsafe_secret_path_is_still_rejected_before_mounts(self):
        result = self.launch(check=False, BITWARDEN_SECRETS_TOKEN_FILE=str(self.repo / 'token'))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'ready').exists())
        self.assertIn('outside all creative mounts', result.stderr)

    def test_publication_and_failure_preserve(self):
        self.launch(PUBLISH_MODE='push')
        self.assertEqual(self.git(self.lab, 'rev-parse', 'HEAD').stdout,
                         self.call('git', '--git-dir', self.root / 'lab.remote', 'rev-parse', 'main').stdout)
        path = self.prepare_launcher(PUBLISH_MODE='push')
        result = self.call(path, env={**self.launch_env, 'FIXTURE_BREAK_REMOTE': '1'}, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn('local commits preserved', result.stderr)
        self.assert_saved()

    def test_divergence_blocks_publication_but_not_local_work(self):
        self.launch(PUBLISH_MODE='push')
        upstream = self.root / 'other'
        self.call('git', 'clone', '-q', self.root / 'lab.remote', upstream)
        self.git(upstream, 'config', 'user.name', 'Fixture')
        self.git(upstream, 'config', 'user.email', 'fixture@example.invalid')
        (upstream / 'remote-only').write_text('remote')
        self.git(upstream, 'add', '.')
        self.git(upstream, 'commit', '-qm', 'remote')
        self.git(upstream, 'push', '-q')
        remote_head = self.git(upstream, 'rev-parse', 'HEAD').stdout
        (self.lab / 'local-only').write_text('local')
        self.git(self.lab, 'add', '.')
        self.git(self.lab, 'commit', '-qm', 'local')
        result = self.launch(check=False, PUBLISH_MODE='push')
        self.assertEqual(result.returncode, 1)
        self.assertTrue((self.lab / 'local-only').exists())
        self.assertEqual(self.call('git', '--git-dir', self.root / 'lab.remote', 'rev-parse', 'main').stdout, remote_head)
        self.assert_saved()

    def test_installed_copies_require_explicit_reinstall(self):
        # All installer writes and service commands are confined to this fixture.
        self.prepare_launcher()
        source = self.root / 'source'
        source.mkdir()
        for pattern in ['*.sh', '*.py', 'prompt.txt', 'config.example.env', 'requirements-secrets.txt']:
            for path in ROOT.glob(pattern):
                shutil.copy2(path, source / path.name)
        shutil.copytree(ROOT / 'systemd', source / 'systemd')
        systemctl = self.root / 'bin/systemctl'
        systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >>"$FIXTURE_ROOT/systemctl.log"\n')
        systemctl.chmod(0o755)
        env = {**self.launch_env, 'HOME': str(self.root / 'home'),
               'XDG_CONFIG_HOME': str(self.root / 'config'),
               'XDG_DATA_HOME': str(self.root / 'data'), 'COMMITMENT_SKIP_BUILD': '1'}
        planner_key = self.root / 'config/commitment/cheaperinference-api-key'
        planner_key.parent.mkdir(parents=True)
        planner_key.write_text('operator-owned-fixture-key\n')
        planner_key.chmod(0o600)
        planner_key_before = planner_key.read_bytes()
        self.call(source / 'install.sh', env=env)
        installed = self.root / 'home/.local/libexec/commitment/run.sh'
        before = installed.read_bytes()
        (source / 'run.sh').write_text('#!/bin/sh\nexit 37\n')
        self.assertEqual(installed.read_bytes(), before)
        self.call(source / 'install.sh', env=env)
        self.assertEqual(installed.read_bytes(), (source / 'run.sh').read_bytes())
        self.assertEqual((self.root / 'systemctl.log').read_text().splitlines(),
                         ['--user daemon-reload', '--user daemon-reload'])
        self.call(source / 'uninstall.sh', env=env)
        self.assertFalse(installed.exists())
        self.assertFalse((installed.parent / 'planner-broker.py').exists())
        self.assertFalse((installed.parent / 'commitment-plan.py').exists())
        self.assertTrue((self.root / 'config/commitment/config.env').exists())
        self.assertEqual(planner_key.read_bytes(), planner_key_before)

    def test_repository_credentials_stay_in_trusted_publishing(self):
        self.launch()
        config = self.root / 'config.env'
        for name in ['commitment', 'lab']:
            token = self.root / (name + '.token')
            token.write_text(name + '-fixture-secret')
            token.chmod(0o600)
            with config.open('a') as handle:
                handle.write(f'{name.upper()}_GITHUB_TOKEN_FILE={token}\n')
                handle.write(f'{name.upper()}_UPSTREAM_URL=https://github.com/fixture/{name}.git\n')
            mirror = self.root / f'state/trusted/{name}.git'
            self.call('git', '--git-dir', mirror, 'config',
                      f'url.{self.root}/{name}.remote.insteadOf', f'https://github.com/fixture/{name}.git')
        real_git = shutil.which('git')
        wrapper = self.root / 'bin/git'
        wrapper.write_text('#!/bin/sh\nif [ -n "${COMMITMENT_GITHUB_TOKEN:-}" ]; then\n'
                           '  printf "%s|%s\\n" "$COMMITMENT_GITHUB_TOKEN" "$*" >>"$FIXTURE_ROOT/auth.log"\n'
                           f'fi\nexec {real_git} "$@"\n')
        wrapper.chmod(0o755)
        for name in ['commitment', 'lab']:
            self.call(self.root / 'runtime/publish.sh', 'push', name, env=self.launch_env)
        lines = (self.root / 'auth.log').read_text().splitlines()
        self.assertTrue(lines)
        for line in lines:
            token, command = line.split('|', 1)
            name = token.split('-')[0]
            self.assertIn(f'trusted/{name}.git', command)
        self.assertFalse(any('fixture-secret' in p.read_text(errors='replace')
                             for repo in [self.repo, self.lab] for p in repo.rglob('*') if p.is_file()))


if __name__ == '__main__':
    unittest.main(verbosity=2)
