---
title: Improve session outcome tracking mechanism
status: prospective
priority: high
origin: memory/2026-09-15-session-outcome-forensics.md
created: 2026-09-16
---

## Value Hypothesis

The current session outcome tracking has issues where substantive changes aren't properly detected, leading to FAILED outcomes when there should be COMMITTED_CHANGE outcomes. This creates noise and makes it hard to track actual progress.

## Next Step

1. Analyze the current outcome detection logic in the runtime system
2. Identify what constitutes "substantive" changes vs bookkeeping
3. Propose or implement improvements to make outcome tracking more accurate
4. Document the improved convention or mechanism

## Research and Context

From session-outcome-forensics.md:
- v0.3.1 runtime classified inbox, queue, memory, and requests items as "bookkeeping"
- Changes to these directories were not counted as substantive, even when they represented real work
- v0.4.0 removed this semantic policing, making all changes authoritative
- Current system uses single-shot marker, process state, Git state as authoritative
- runlog.jsonl is now informational only

The opportunity is to improve outcome tracking while preserving the simplicity of the current approach.

## Disposition

Rejected as obsolete. The proposed semantic classification would reintroduce
complexity deliberately removed in v0.4.0. Current preservation behavior is
intentionally based on Git state rather than interpreting workspace semantics.

