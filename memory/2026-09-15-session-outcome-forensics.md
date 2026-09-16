# Session outcome forensics

## Duplicate FAILED records

The duplicate terminal records for sessions
`20260915T142912-0400-2983102` and
`20260915T152624-0400-3016614` were produced by trusted v0.3.1 runtime code, not
fabricated by the model.

Both sessions began while release commit `4bca5f7` (`VERSION` 0.3.1) was the
active release. Its `agent-git.sh` classified `runlog.jsonl`, `memory/*.md`,
`queue/*.md`, `requests/*.md`, and `inbox/*` as non-substantive bookkeeping. Its
`run.sh` rejected `COMMITTED_CHANGE` when both repository finalizers reported
`substantive=0`, set the literal summary `Session outcome did not match repository
state`, and called `session-failure`. That command appended both a `failure` and a
second `session_end` with `outcome=FAILED`.

The first session added a request and processed an inbox item in commit `6ab485f`;
the second moved a request to the queue and processed an inbox item in commit
`d20e53d`. Under the installed v0.3.1 classifier those paths were all bookkeeping,
so the launcher's semantic outcome check generated commits `ada3f79` and
`e6d966b` containing the later FAILED pairs. Git history contains the exact
literal and code path. Retained OpenCode logs contain only the model's successful
`commitment-outcome COMMITTED_CHANGE` calls, not tool calls writing the later
records.

v0.4.0 commit `b3a86e0` removed this semantic outcome policing. The current
single-shot marker, process state, Git state, and publication results are
authoritative; `runlog.jsonl` is informational. No new runlog provenance scheme
is warranted for this removed behavior.

## Outcome-less exits

Retained OpenCode 1.18.30 state also explains the investigated missing outcomes:

- `20260915T161435-0400-3064588` compacted after accumulated research context,
  resumed with OpenCode's continuation prompt, and ended with “No next steps
  identified” instead of calling `commitment-outcome`.
- `20260915T171620-0400-3124250` compacted after creating the Microsoft patch
  memory and queue items, resumed, and ended with “Task completed.” instead of
  calling the helper.
- `20260915T202240-0400-3322515` made a queue edit and then ended normally without
  an outcome call; its retained messages show no compaction or context-length
  error.

The first two support a compaction-related loss of the outcome obligation, not a
raw context-exhaustion failure: retained messages and logs contain normal `stop`
finishes and no context-limit/API error. OpenCode's persisted database and log
already retain message finishes, token totals, compaction activity, and tool
calls, but `opencode run` does not expose a cheap current-launch diagnostic that
maps those details to Commitment's session ID. Transcript parsing or a custom
loop would cost more complexity than it adds evidence. Current recovery remains
the intended rule: missing outcome plus changed work becomes
`CHECKPOINT_UNFINISHED`.
