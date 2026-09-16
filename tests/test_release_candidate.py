#!/usr/bin/env python3
"""Focused v0.4.1 release contracts and historical evidence."""
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReleaseCandidate(unittest.TestCase):
    def read(self, relative):
        return (ROOT / relative).read_text()

    def git_show(self, spec):
        return subprocess.run(
            ['git', '-C', ROOT, 'show', spec], text=True, capture_output=True,
            check=True, timeout=30).stdout

    def test_primary_agent_personality_and_policy_separation(self):
        agent = self.read('.opencode/agents/commitment.md')
        self.assertRegex(agent, r'(?m)^mode: primary$')
        for idea in [
                'You are Commitment', 'Do not wait for a user request',
                'reversible action', 'Usefulness does not require novelty',
                'ordinary actions already permitted', 'Mistakes, mediocre ideas',
                'Follow MISSION.md and AGENTS.md',
                'Once commitment-outcome succeeds']:
            self.assertIn(idea, agent)
        self.assertNotIn('Podman socket', agent)
        self.assertNotIn('Bitwarden', agent)
        self.assertIn('Podman\nsocket', self.read('AGENTS.md'))
        self.assertIn('Bitwarden', self.read('AGENTS.md'))

    def test_no_action_or_research_gate_for_noop(self):
        instructions = '\n'.join(self.read(path) for path in [
            '.opencode/agents/commitment.md', 'AGENTS.md', 'MISSION.md', 'prompt.txt'])
        forbidden = [
            r'must (?:act|take action|research).*before (?:a )?NOOP',
            r'(?:action|research) (?:is )?required before (?:a )?NOOP',
            r'NOOP requires', r'eligible for NOOP']
        for pattern in forbidden:
            self.assertIsNone(re.search(pattern, instructions, re.IGNORECASE))
        self.assertIn('Research when useful', instructions)
        self.assertIn('or NOOP', instructions)

    def test_residual_friction_wording(self):
        queue = self.read('queue/2026-09-15-microsoft-patch-dilemma-documentation.md')
        self.assertIn('novelty is not a prerequisite', queue)
        self.assertNotIn('awaiting deeper evidence of unique contribution', queue)

        agents = self.read('AGENTS.md')
        prompt = self.read('prompt.txt')
        readme = self.read('README.md')
        self.assertIn('Configured Git publication and credentialed\nGitHub operations', agents)
        self.assertIn('configured Git publication, credentialed\nGitHub operations', prompt)
        self.assertIn('Persistent account creation needing reusable credentials', agents)
        self.assertIn('Persistent account creation requiring\nreusable credentials', readme)
        self.assertIn('Commitment may edit and commit trusted-runtime sources', readme)
        self.assertIn('explicit rebuild and reinstall activates those changes', readme)

    def test_duplicate_failure_forensics_are_backed_by_history(self):
        report = self.read('memory/2026-09-15-session-outcome-forensics.md')
        historical_run = self.git_show('4bca5f7:run.sh')
        historical_git = self.git_show('4bca5f7:agent-git.sh')
        self.assertIn('Session outcome did not match repository state', historical_run)
        self.assertIn('$outcome == COMMITTED_CHANGE', historical_run)
        self.assertIn('session-failure commitment', historical_run)
        self.assertIn('runlog.jsonl|memory/*.md|queue/*.md|requests/*.md|inbox/*',
                      historical_git)
        for commit in ['4bca5f7', '6ab485f', 'ada3f79', 'd20e53d', 'e6d966b']:
            self.assertIn(commit, report)

        rows = [json.loads(line) for line in self.read('runlog.jsonl').splitlines()]
        for session_id in ['20260915T142912-0400-2983102',
                           '20260915T152624-0400-3016614']:
            terminal = [row for row in rows if row.get('session_id') == session_id
                        and row.get('type') in {'failure', 'session_end'}]
            self.assertTrue(any(row.get('outcome') == 'COMMITTED_CHANGE'
                                for row in terminal))
            self.assertTrue(any(row.get('outcome') == 'FAILED'
                                and row.get('summary') ==
                                'Session outcome did not match repository state'
                                for row in terminal))


if __name__ == '__main__':
    unittest.main(verbosity=2)
