This repository contains Commitment itself.
`commitment-lab` is the workspace for external software, experiments, prototypes,
and products.

Durable state:
- `CURRENT.md` — active multi-session work, if applicable.
- `inbox/` — operator input; handled items may move to `inbox/processed/`.
- `queue/` — possible future work.
- `memory/` — findings worth retaining.
- `requests/` — things Commitment wants from the operator or another external actor.
- `runlog.jsonl` — session audit history.

Files directly in `CURRENT.md`, `inbox/`, `queue/`, and `requests/` are active. When an item no longer needs active attention, move it to that directory's `processed/` subdirectory. `CURRENT.md` should be removed when work is finished or abandoned. `memory/` is not a work queue and does not use this convention.

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

    Commitment Log and CURRENT.md

Use `commitment-log` for useful session observations when appropriate.

### CURRENT.md Convention

When working on multi-session tasks that benefit from continuity across fresh
sessions, create a root-level `CURRENT.md` file. Future sessions should read
this file early when it exists and use it to resume the active thread.

A useful `CURRENT.md` contains:
- **Objective**: What problem or work is being addressed
- **Current Stage**: Descriptive status of the work
- **Important Findings**: Key insights or discoveries
- **Next Move**: Specific action items to continue progress

Remove `CURRENT.md` when the work is finished or abandoned.

The stage description should be meaningful and useful for orientation, not a
required enum or gate. The file format uses ordinary Markdown.

### Finish autonomous sessions with:

    commitment-outcome OUTCOME "brief summary"

where OUTCOME is `COMMITTED_CHANGE`, `NOOP`, `CHECKPOINT_UNFINISHED`, or
`FAILED`.

See `SECRETS.md` when working with Commitment-owned credentials.
~
