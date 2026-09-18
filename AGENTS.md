This repository contains Commitment itself.
`commitment-lab` is the workspace for external software, experiments, prototypes,
and products.

Durable state:
- `CURRENT.md` — persistent orientation point that describes active work or serves as a "between tasks" state.
- `inbox/` — operator input; handled items may move to `inbox/processed/`.
- `queue/` — possible future work.
- `memory/` — findings worth retaining.
- `requests/` — things Commitment wants from the operator or another external actor.
- `runlog.jsonl` — session audit history.

Files directly in `CURRENT.md`, `inbox/`, `queue/`, and `requests/` are active. When an item no longer needs active attention, move it to that directory's `processed/` subdirectory. `memory/` is not a work queue and does not use this convention.

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

`CURRENT.md` is a root-level file that serves as a persistent orientation point.

**Active work thread**: When working on multi-session tasks that benefit from continuity across fresh sessions, `CURRENT.md` describes that thread with:
- **Objective**: What problem or work is being addressed
- **Current Stage**: Descriptive status of the work
- **Important Findings**: Key insights or discoveries
- **Next Move**: Specific action items to continue progress

**Between tasks**: When there is no active work, `CURRENT.md` contains a concise "between tasks" state with a next move to prospect for useful work. The file describes the present, not history.

The stage description should be meaningful and useful for orientation, not a
required enum or gate. The file format uses ordinary Markdown.

Remove `CURRENT.md` only if explicitly requested.

## Repositories

Two writable repositories are available:

- `/workspace/commitment` — Commitment itself.
- `/workspace/commitment-lab` — separate repository for experiments, prototypes,
  external software, and projects that should not live in Commitment itself.

`commitment-lab` is already a Git repository. Do not create or initialize a
`commitment-lab` directory inside `/workspace/commitment`.

Both repositories have configured trusted Git publication. Use normal Git
operations in the appropriate repository; the trusted machinery handles the
underlying credentials. Do not attempt to obtain or expose those credentials.

### Finish autonomous sessions with:

    commitment-outcome OUTCOME "brief summary"

where OUTCOME is `COMMITTED_CHANGE`, `NOOP`, `CHECKPOINT_UNFINISHED`, or
`FAILED`.

See `SECRETS.md` when working with Commitment-owned credentials.
~
