# Memory

This directory holds concise, durable observations learned by Commitment. Human requests do not belong here, and session events belong in `runlog.jsonl`. A session need not create a memory entry.

Use a descriptive lowercase hyphenated filename and this Markdown shape, omitting optional fields or sections that do not apply:

```markdown
---
title: Short finding
created: 2026-09-13
session: exact COMMITMENT_SESSION_ID
source: URL, issue, commit, file, or other reference
confidence: low | medium | high
related_queue: queue/example.md
---

## Observation

Concise finding.

## Why it may matter

Likely consequence or value.

## Possible follow-up

One bounded next question or action.
```

Summarize sources rather than copying large external passages. Update an existing entry when it represents the same finding; do not create entries merely to make a session nonempty.
