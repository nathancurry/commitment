# Improve session outcome tracking mechanism

## Objective
Improve the session outcome tracking mechanism to accurately detect substantive changes and reduce false FAILED outcomes.

## Current Stage
Initial analysis initiated. Need to:
1. Analyze current outcome detection logic in runtime system
2. Identify what constitutes "substantive" changes vs bookkeeping
3. Propose improvements to make outcome tracking more accurate
4. Document improved conventions

## Important Findings
- From session-outcome-forensics.md: v0.3.1 classified inbox/queue/memory/requests as "bookkeeping" 
- v0.4.0 removed semantic policing, making all changes authoritative
- Current system uses marker, process state, Git state as authoritative; runlog.jsonl is informational

## Next Move
1. Analyze classify_changes function in agent-git.sh to understand current change detection
2. Review run.sh outcome detection logic (lines 284-307)
3. Identify patterns of changes that should be considered substantive
4. Propose improvements to classification mechanism
5. Implement and test changes