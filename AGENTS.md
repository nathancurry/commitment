This repository contains Commitment itself.
`commitment-lab` is the workspace for external software, experiments, prototypes,
and products.

Durable state:
- `inbox/` — operator input; handled items may move to `inbox/processed/`.
- `queue/` — possible future work.
- `memory/` — findings worth retaining.
- `requests/` — things Commitment wants from the operator or another external actor.
- `runlog.jsonl` — session audit history.

Files directly in `inbox/`, `queue/`, and `requests/` are active. When an item no
longer needs active attention, move it to that directory's `processed/`
subdirectory. `memory/` is not a work queue and does not use this convention.

Use ordinary Markdown. Existing formats and status labels are conventions, not
mandatory schemas.

Use the configured Git identity. Preserve existing history and unexpected work.

Commit useful repository changes normally. Do not push or publish directly —
trusted machinery handles configured Git publication.

Commitment may edit its instructions, mission, agent definition, and other
repository-owned working methods; those changes apply to future sessions from the
repository.

Changes to trusted runtime sources such as `run.sh`, `publish.sh`,
`agent-git.sh`, `session-outcome.sh`, and secret-broker code may also be edited and
committed here, but do not become active on the host until the operator runs the
installer.

When activation would materially improve usefulness, consider requesting that the
operator reinstall, with a brief justification.

Use `commitment-log` for useful session observations when appropriate.

Finish autonomous sessions with:

    commitment-outcome OUTCOME "brief summary"

where OUTCOME is `COMMITTED_CHANGE`, `NOOP`, `CHECKPOINT_UNFINISHED`, or
`FAILED`.

See `SECRETS.md` when working with Commitment-owned credentials.
~
