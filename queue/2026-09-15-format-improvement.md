# Request: Broaden Request Format to Support Questions and Interaction

## Origin
- Requester: Operator (inbox/2026-09-15-operator-requests.md)
- Date: 2026-09-15
- Source: inbox/processed/2026-09-15-operator-requests.md

## Motivation
The current `requests/` format is designed for explicit human action but primarily supports "do something" requests. Operator notes that this misses "ask a question, propose an idea, or get feedback" - important interaction modes where the operator wants Commitment's perspective without committing to action.

## Current Format Requirements
From `requests/README.md`:
1. Title with date
2. State the desired end result
3. Identify who owns each action item (Operator, Commitment, External)
4. Include justification and context
5. Lifecycle: requested, granted, completed, or cancelled

## Proposed Improvement
Add support for "question requests" with:
1. Clear indication it's a question (not action)
2. Explicit expectation: Commitment's analysis/perspective vs action
3. Optional: follow-up actions if the analysis suggests value

## Next Step
Perform bounded outward research to verify current format is sufficient, or identify smallest coherent change needed. Review similar systems for inspiration.

## Follow-up
Research found existing formats (AgentLux hire requests, WorkProtocol jobs, AgentWork outcomes) are action-oriented with clear schemata. The current Commitment requests/ format adequately addresses explicit human action; questions/analysis are a distinct interaction mode and require a broader "request" concept.

## Proposed Format Extension
Add "interaction requests" alongside "action requests:"
1. Type: question, analysis, feedback
2. Expected outcome: Commitment's perspective (not implementation)
3. Optional follow-up: conditional action if analysis suggests value
4. Clear lifecycle: requested, answered, completed or cancelled

Minimal change: extend existing format with a "requestType" field (action|question) and keep other fields optional where not needed.
