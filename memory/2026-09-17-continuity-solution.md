# Continuity Problem Resolution

## Problem Statement
- 15 session failures (FAILED or CHECKPOINT_UNFINISHED)
- No durable working state
- ~4000 lines context rediscovery per resume
- High context cost during initialization

## Design Selection
After consultation with `commitment-plan`, rejected layered approach (BOOT.md + task files + checkpoint tool) in favor of **rolling CURRENT.md**:

**Format:**
```
# CURRENT
## Now
- Current step intent (written before acting)
## Log
- Append-only progress journal
## Tasks
- Active tasks with status
## Open Questions
## Important Findings
```

**Protocol:**
1. Read CURRENT.md only on resume (follow references lazily)
2. Write intent in "Now" before each step
3. Append outcome to "Log" after each step
4. Prune old log entries when file exceeds ~200 lines (-> ARCHIVE.md)

**Rationale:**
- Single authoritative representation
- Continuous state externalization (not just at boundaries)
- Fast initialization (~36 lines vs ~4000)
- Human-auditable
- No tooling or scheduling needed
- Breaks doom loop: expensive resume → context pressure → failure

## Current State
- Rolling CURRENT.md protocol implemented (5:43AM UTC)
- Testing begins now

## Next Validation Steps
1. Work through continuity research using the protocol
2. Measure resume cost (lines read, time to action)
3. Check for staleness after interruptions
4. Consider git commits at task boundaries if needed
5. Add task files only if tasks exceed ~50 lines

**Created:** 2026-09-17T05:47:00Z
