# Long-Running Session Implementation Plan

## Current State Analysis

### Already Implemented:
1. ✅ Session timeout mechanism (SESSION_TIMEOUT in config.env, default 7200s)
2. ✅ Checkpoint/recovery via Git and runlog.jsonl
3. ✅ Parked questions directory with README and park-question.sh script
4. ✅ Session continuity script (session-continuity.sh)
5. ✅ Agenda processing in inbox-context.sh (basic parsing)
6. ✅ CURRENT.md as rolling state tracker

### Missing Components:

1. **Agenda Processing in run.sh**
   - Need to add logic to extract actionable items from agenda.md
   - Should populate queue with appropriate tasks

2. **Morning Report Generation**
   - Need to implement generate_morning_report() function
   - Should summarize work completed
   - Include parked questions list
   - Calculate resource usage
   - Report on agenda progress

3. **Enhanced Agenda Parsing**
   - Improve agenda item extraction in inbox-context.sh
   - Handle status markers (PENDING, IN-PROGRESS, COMPLETED)

4. **Agenda to Queue Conversion**
   - Create logic to convert agenda items to actionable queue items

## Implementation Tasks

### Phase 1: Morning Report Generation

Location: `inbox-context.sh`

Add implementation to the `generate_morning_report()` function:

```bash
# Generate morning report for long-running sessions
generate_morning_report() {
    local outcome=$1
    local summary=$2
    local repo_path=$3
    
    echo "# Morning Report"
    echo ""
    echo "## Session Summary"
    echo "- Outcome: $outcome"
    echo "- Summary: $summary"
    
    echo ""
    echo "## Work Completed"
    echo "- List of accomplished tasks from CURRENT.md"
    echo "- Changes made to repositories"
    
    echo ""
    echo "## Active Agenda Items"
    # List agenda items with status
    
    echo ""
    echo "## Parked Questions"
    # List number of parked questions
    
    echo ""
    echo "## Resource Usage"
    echo "- CPU time: TODO"
    echo "- Memory usage: TODO"
    echo "- API calls: TODO"
    
    echo ""
    echo "## Recommendations"
    echo "- Next steps based on current state"
    echo "- Blockers requiring operator input"
}
```

### Phase 2: Agenda Processing Enhancement

Location: `inbox-context.sh`

Enhance `process_agenda()` function to:
- Extract agenda items more robustly
- Identify PENDING items as actionable
- Return formatted items ready for queue population

### Phase 3: run.sh Integration

Location: `run.sh` (after line 179)

Add agenda processing logic:

```bash
# Process agenda and populate queue
deprecated""Agenda Context""$agenda_context
"""
fi

# Build session continuity context
"""
[[ -n "$agenda_context" ]] && echo "$agenda_context"
[[ -n "$parked_context" ]] && echo "$parked_context"

""A"""
[[ -n "$parked_context" ]] && echo "$parked_context"

""A""
[[ -n "$agenda_context" ]] && echo "$agenda_context"
[[ -n "$parked_context" ]] && echo "$parked_context"

""E""
[[ -n "$agenda_context" ]] && echo "$agenda_context"
```

### Phase 4: Queue Population Logic

Create a helper script or function to convert agenda items to queue items.

### Phase 5: Testing

Test the complete workflow:
- Session starts with agenda items
- Agenda items populate queue
- Work progresses on agenda items
- Morning report generated on completion
- Checkpoint recovery preserves state

## Key Integration Points

1. **run.sh lines 173-179**: Add agenda processing before building prompt
2. **inbox-context.sh**: Enhance agenda parsing and add morning report generation
3. **session-outcome.sh**: Connect to morning report generation trigger
4. **CURRENT.md**: Update with progress tracking

## Resource Tracking Requirements

To properly estimate resource usage:
- Track API calls in session
- Monitor CPU and memory usage
- Calculate time spent on tasks
- Identify blocked states requiring operator input

This can be added incrementally as the system evolves.
