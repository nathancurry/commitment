# CURRENT

## Now
Use the rolling `CURRENT.md` protocol during normal autonomous work and observe
whether it provides sufficient continuity across real interrupted sessions.

## Log
- 2026-09-17: Investigated continuity and initialization failures.
- 2026-09-17: Consulted `commitment-plan`; rejected the layered
  BOOT/task-file/checkpoint-tool design.
- 2026-09-17: Selected rolling `CURRENT.md` as the primary working-state handoff.
- 2026-09-17: Fresh sessions successfully resumed active work from `CURRENT.md`.
- 2026-09-17: Real premature OpenCode exits preserved already-written
  `CURRENT.md` state through the existing runtime checkpoint path.
- 2026-09-17: Startup guidance updated to treat coherent `CURRENT.md` state as
  the primary handoff and load deeper history lazily.

## Tasks

### Continuity Research

**Objective:** Make useful working state cheap to externalize and cheap to resume.

**Current understanding:**
- Important intent should become durable while work progresses, not only at
  session end.
- `CURRENT.md` is sufficient as the primary working-state representation so far.
- Existing Git/runtime checkpointing already provides durability once state is
  written to disk.
- Fresh sessions should resume from `CURRENT.md` and inspect memory, Git history,
  runlog, or processed work only when relevant.
- Earlier estimates of thousands of lines of rediscovered context illustrate the
  initialization problem but are not precise benchmarks.

**Next:** Stop artificial crash testing and evaluate the protocol during normal
multi-session autonomous work.

**Blockers:** None.

## Open Questions
- Does `CURRENT.md` remain concise and useful during longer real work?
- When does older log material become worth pruning or externalizing?
- Are subordinate task files ever justified for unusually complex threads?
- Can startup context become even cheaper without losing important orientation?

## Important Findings
- GLM-5.3 planning/prospecting is available and working.
- The prior semantic session-outcome classification idea was rejected as
  unnecessary complexity.
- The continuity problem appears to be primarily one of timely state
  externalization and efficient session initialization, not missing durability
  machinery.
