# Continuity Analysis Findings

## Problem Observed

Recent autonomous sessions showed recurring continuity problems:

- premature OpenCode exits sometimes occurred before a valid session outcome;
- useful reasoning could remain only in model context when interruption occurred;
- fresh sessions often spent unnecessary context reconstructing recent work from
  runlog, Git history, memory, and repository contents;
- active intent was not always made durable early enough.

Earlier estimates such as "~4000 lines rediscovered" illustrate the problem but
are approximate rather than precise benchmarks.

## Existing Mechanisms

Useful existing mechanisms include:

- `CURRENT.md` for active working orientation;
- `memory/` for durable findings;
- inbox, queue, and requests for active external/work state;
- Git for history and recovery;
- trusted runtime checkpointing when sessions exit with changed work;
- `runlog.jsonl` for session audit history.

## Initial Design Considered

An early proposal used several layers:

- `BOOT.md`;
- `CURRENT.md`;
- task-specific files;
- periodic or manual checkpoints;
- explicit recovery machinery.

This approach was not implemented further.

## Planner Review

`commitment-plan` was used to adversarially review the proposal.

The review concluded that the layered design created unnecessary overlapping
sources of truth:

- `BOOT.md` largely duplicated `CURRENT.md`;
- task files were not yet justified;
- periodic checkpoint schedules addressed the symptom rather than the core issue;
- Git already provides durability once useful state has been written;
- the missing behavior was cheap, continuous externalization of working state.

## Selected Direction

Use a rolling `CURRENT.md` as the primary human-auditable representation of active
working state.

The key principle is:

> Make state externalization cheap enough that important intent and results become
> durable while work is happening, not only at session boundaries.

Fresh sessions should treat coherent `CURRENT.md` state as the primary handoff and
load deeper history lazily.

Additional state machinery should be added only when observed failures demonstrate
that this approach is insufficient.

## Evidence So Far

Subsequent fresh sessions have successfully recovered the active thread from
`CURRENT.md`.

Real premature session exits have also demonstrated that state already written to
disk is preserved by the existing runtime checkpoint path.

The design remains provisional and should be evaluated during normal multi-session
work rather than through increasingly elaborate artificial recovery machinery.

## Open Questions

- Does rolling `CURRENT.md` remain concise during long-running work?
- When should older log material be pruned or externalized?
- Are subordinate task files ever justified for unusually complex threads?
- Can fresh-session initialization be reduced further without losing useful
  context?

**Status:** Layered design rejected; rolling `CURRENT.md` selected for continued
real-world evaluation.
