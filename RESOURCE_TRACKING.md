# Resource Tracking Specification

## Overview
Resource tracking is an append-only ledger that records Commitment's session activity for transparency and reporting.

## Format
JSON Lines (JSONL) - one JSON object per line for easy appending and parsing.

## Schema
```json
{
  "timestamp": "2026-09-22T05:15:23Z",  // ISO 8601 UTC
  "session_id": "20260922T051523-12345",  // Commitment session ID
  "event": "start|end|checkpoint",  // Session lifecycle event
  "context_tokens": 12345,  // Number of context tokens used
  "output_tokens": 2345,  // Number of output tokens generated
  "agenda_items_touched": ["career", "income"],  // Agenda items worked on
  "tasks_completed": 3,  // Number of tasks from queue completed
  "parked_questions_created": 1,  // Number of questions parked
  "memory_entries_created": 2,  // Number of memory entries added
  "resources": {
    "cpu_usage": 4.2,  // CPU cores used (avg)
    "memory_usage_mb": 4096,  // Memory used
    "api_calls": 5,  // Total API calls
    "api_tokens": 15000  // Total tokens across all API calls
  },
  "notes": "Session focused on agenda implementation"  // Free-form notes
}
```

## Acceptance Criteria
- Ledger file exists at `runlog.jsonl` (session runlog)
- Entries are appended on session start/end
- Morning report includes resource summary
- Format is stable and parseable

## Implementation Plan
1. Add ledger append logic to session-continuity.sh
2. Connect to resource tracking in run.sh
3. Integrate summary into morning report
4. Add validation script

## Design Decisions
- **Append-only**: Prevents data loss from overwrites
- **JSONL**: Simple to append, easy to parse
- **Session-scoped**: Tracks per-session resource usage
- **UTC timestamps**: Consistent timezone handling
