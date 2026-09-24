# Durable Work Protocol

## Overview
This system prevents work loss by ensuring each work item has:
1. A dedicated file with durable state
2. Git commit tracking for audit trail
3. Session start/end ritual to preserve context

## Work File Format
Each work item is stored in `work/` directory with this structure:

```markdown
# Work Item: [Short Title]

**Source**: [origin - inbox/file.md, queue/file.md, or agenda]

**Objective**: Clear statement of what to accomplish

**Current State**: Where the work currently stands (active/in-progress/completed/blocked)

**Important Findings**: Key insights discovered so far

**Next Action**: Specific step to continue progress

**Last Touched**: YYYY-MM-DD timestamp

**Session History**:
- 2026-09-24: Started research on X
- 2026-09-25: Identified gap Y, needs operator clarification

**Open Questions**:
- [ ] Question 1 waiting on operator
- [ ] Question 2 needs research
```

## Session Ritual Protocol

### Session Start (in run.sh)
```bash
# 1. Read all active work items from work/
# 2. Update CURRENT.md to reflect active work
# 3. Continue from last known state
```

### Session End (in session-outcome.sh)
```bash
# 1. Save work state to work/[title].md
# 2. Commit changes to git with clear message
# 3. Update CURRENT.md to point to active work files
# 4. Generate summary of work done
```

## Implementation Plan

### Phase 1: Create work/ directory structure
- Create `/workspace/commitment/work/` directory
- Move existing agenda queue items to work/ as foundation
- Create initial work tracking files

### Phase 2: Update run.sh for session start
- Add work/ directory reading at session beginning
- Populate CURRENT.md from work files
- Handle session recovery from work state

### Phase 3: Update session-outcome.sh
- Create work state serialization function
- Implement git-based audit trail
- Generate session summary from work changes

### Phase 4: Create work migration tool
- Convert existing queue/ items to work format
- PreserveFear of Commitment history in work/
- Document migration process

## Key Benefits

1. **Nothing lost**: Git provides append-only audit trail
2. **Multiple simultaneous work items**: Each gets own file
3. **Easy recovery**: Last state always readable from work/
4. **Visibility**: Open questions and blocking items clear
5. **Accountability**: Session history tracks progress

## Migration Strategy

1. Current queue/ items become starting work files
2. CURRENT.md references work/ files instead of inline
3. Fear of Commitment work preserved as case study
4. Agenda items drive new work creation
