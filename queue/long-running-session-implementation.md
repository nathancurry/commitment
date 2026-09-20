# Long-Running Session Implementation Plan

## Objective
Implement long-running session capability that allows Commitment to operate for extended periods (overnight) without artificial limits, while maintaining useful work tracking and reporting.

## Current Implementation Analysis

From `run.sh` analysis:
- `SESSION_TIMEOUT` is configurable via `config.env` (default: 7200s = 2h)
- Uses `timeout --signal=TERM --kill-after=30` command
- Checkpoint/recovery via Git and `runlog.jsonl`
- Session outcome recorded in `/run/commitment-outcome/outcome`
- Clean preservation of work on timeout/crash

## Required Components

### 1. State Preservation System
- Track work progress across sessions
- Save interrupted tasks
- Restore context on continuation

### 2. Pre-Approved Agenda System
- Allow operator to specify high-level goals before overnight session
- System identifies useful sub-tasks from agenda
- Reports progress on agenda items

### 3. Question Parking Lot
- When blocked on operator input, park the question
- Continue with other useful work
- Generate morning report with parked questions

### 4. Morning Report Generation
- Summarize work completed
- Identify parked questions
- Suggest next steps
- Calculate resource usage (CPU, memory, API calls)

### 5. Continuous Work Discovery
- Identify new useful work while session progresses
- Adapt to findings and change direction as appropriate

## Implementation Strategy

### Phase 1: State Preservation
1. Enhance CURRENT.md to track work threads across sessions
2. Create work queue system in queue/ directory
3. Implement session continuity markers

### Phase 2: Agenda System
1. Create agenda input system (inbox/agenda.md)
2. Implement task decomposition logic
3. Add progress tracking for agenda items

### Phase 3: Parking Lot
1. Create parked-questions/ directory
2. Implement question parking mechanism
3. Add question to agenda when operator responds

### Phase 4: Reporting
1. Implement morning report generator
2. Add resource tracking
3. Include agenda progress
4. List parked questions

### Phase 5: Testing
1. Test overnight scenarios
2. Rehearse with operator
3. Validate resource tracking
4. Ensure checkpoint recovery works

## Key Integration Points

1. **run.sh modifications**: Add agenda processing, parking lot check, continuity handling
2. **session-outcome.sh**: Enhance to generate comprehensive reports
3. **CURRENT.md**: Update format to support multiple work threads
4. **queue/ directory**: Use for task queue management
5. **inbox/agenda.md**: New file for operator-preapproved work
6. **parked-questions/**: New directory for blocked questions

## Operator Input Summary

- $5 USD per day external API spending limit (not to exceed without authorization)
- No artificial limits on CPU, memory, GPU, tokens, commits, or wall-time
- Host resources: 12 CPU, 32 GB RAM, NVIDIA RTX 5070 Ti with 16 GB VRAM
- Can investigate models/inference stacks for local hardware
- May request additional capabilities
- No prescribed overnight work - determine what's useful
- Two particularly useful directions:
  1. Help operator improve AI skills and career opportunities
  2. Find opportunities to increase operator's income/wealth
