# Continuity Problem Resolution

## Problem

Recent autonomous sessions showed two related problems:

- useful working context could remain only in model context when a session ended
  unexpectedly;
- fresh sessions often reconstructed too much history from runlog, Git, memory,
  and repository contents before resuming useful work.

This increased initialization cost and made interrupted work unnecessarily hard to
resume.

## Design Decision

After consultation with `commitment-plan`, the proposed layered design
(`BOOT.md` + task files + checkpoint tooling) was rejected in favor of a rolling
`CURRENT.md`.

`CURRENT.md` is the primary human-auditable representation of active working
state.

Typical shape:

    # CURRENT
    ## Now
    ## Log
    ## Tasks
    ## Open Questions
    ## Important Findings

The exact format may evolve as experience warrants.

## Working Protocol

- Fresh sessions read `MISSION.md`, `AGENTS.md`, and `CURRENT.md` first and check
  operator input early.
- When `CURRENT.md` contains coherent active work, resume from it and follow
  references lazily rather than reconstructing history unnecessarily.
- Keep current intent durable while work progresses, especially before substantial
  actions or decisions.
- Record important outcomes, findings, and changes of direction as they occur.
- Load runlog, Git history, memory, processed work, or other historical context
  only when relevant.
- Keep `CURRENT.md` concise enough to remain cheap to read and human-auditable.
  Prune or externalize older detail when actual growth makes that useful.

## Why This Design

The rolling file currently provides:

- one primary representation of active working state;
- durability as soon as important state is written to disk;
- compatibility with the existing Git/runtime checkpoint mechanism;
- inexpensive fresh-session orientation;
- direct human auditability;
- no additional daemon, database, checkpoint scheduler, or workflow engine.

Existing trusted runtime machinery already preserves changed repository state when
OpenCode exits unexpectedly. The missing piece was primarily representing useful
working state before interruption occurs.

## Evidence So Far

Observed fresh sessions have been able to recover the active continuity thread from
a relatively small `CURRENT.md` rather than relying on broad historical
reconstruction.

Multiple real premature OpenCode exits have also shown that changes already written
to `CURRENT.md` survive through the existing checkpoint/preservation path.

This is promising evidence, not final proof that the design is sufficient for all
future workloads.

The earlier estimate of thousands of lines of rediscovered context illustrates the
initialization problem but should not be treated as a precise benchmark.

## Open Questions

- Does the approach remain effective during long, complex, multi-session work?
- How concise can `CURRENT.md` remain in practice?
- When does older log material become worth pruning or externalizing?
- Are subordinate task files ever justified for unusually large threads?
- Can session initialization become still cheaper without losing important
  context?

## Current Direction

Use the rolling `CURRENT.md` approach during normal autonomous work rather than
adding more continuity machinery now.

Add complexity only when observed failures demonstrate that this mechanism is
insufficient.
