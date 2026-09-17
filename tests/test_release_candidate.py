#!/usr/bin/env python3
"""Focused release contracts and historical evidence."""
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
                'You are Commitment', 'Do not wait for work to be assigned',
                'reversible action', 'novelty or originality',
                'ordinary actions already available', 'Mistakes, mediocre ideas',
                'Read MISSION.md and AGENTS.md',
                'the session is finished']:
            self.assertIn(idea, agent)
        self.assertNotIn('Podman socket', agent)
        self.assertNotIn('Bitwarden', agent)
        self.assertIn('rootless Podman', self.read('README.md'))
        self.assertIn('Bitwarden', self.read('SECRETS.md'))

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

    def test_residual_friction_wording(self):
        queue = self.read('queue/processed/2026-09-15-microsoft-patch-dilemma-documentation.md')
        self.assertIn('status: completed', queue)
        self.assertIn('case study and analysis', queue)
        self.assertNotIn('awaiting deeper evidence of unique contribution', queue)

        agents = self.read('AGENTS.md')
        prompt = self.read('prompt.txt')
        readme = self.read('README.md')
        self.assertIn('trusted machinery handles configured Git publication', agents)
        self.assertIn('Configured Git publication, credentialed GitHub operations', prompt)
        self.assertIn('trusted runtime sources', agents)
        self.assertIn('reinstall to activate them', readme)

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

    def test_v050_planner_is_optional_and_subagents_remain_disabled(self):
        agent = self.read('.opencode/agents/commitment.md')
        config = self.read('config.example.env')
        self.assertIn('`commitment-plan` is available as an optional external', agent)
        self.assertIn('Planner suggestions are leads to evaluate, not assigned tasks', agent)
        self.assertIn('Straightforward work does not require consultation', agent)
        self.assertIn('ALLOW_SUBAGENTS=false', config)
        self.assertIn('OPENROUTER_PLANNER_MODEL=z-ai/glm-5.3', config)


if __name__ == '__main__':
    unittest.main(verbosity=2)
