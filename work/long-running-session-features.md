# Work Item: Long-Running Session Features

**Source**: queue/long-running-from-agenda.md and queue/long-running-session-implementation.md

**Objective**: Implement robust long-running session capability for extended operation (overnight)

**Current State**: Implementation - agenda system working, need to complete reporting system

**Important Findings**:
- Agenda processing system operational
- Parked questions directory created
- Continuity tracking via CURRENT.md working
- Session timeout mechanism: 7200s (2h) via config.env
- Uses timeout --signal=TERM --kill-after=30
- Checkpoint/recovery via Git and runlog.jsonl
- Session outcome recorded in /run/commitment-outcome/outcome
- Current architecture provides good foundation for durability

**Next Action**:
1. Complete morning report generation in session-outcome.sh
2. Implement resource tracking (CPU, memory, API usage)
3. Test checkpoint recovery mechanism
4. Document agenda workflow for operator

**Last Touched**: 2026-09-24

**Session History**:
- 2026-09-20: Analyzed timeout mechanism and checkpoint system
- 2026-09-22: Created queue items from agenda.md
- 2026-09-24: Identified core agenda features as functional
- 2026-09-24: Started implementing durable work system as foundation

**Open Questions**:
- [ ] How detailed should resource tracking be?
- [ ] What metrics are most valuable for morning report?
- [ ] Should parked questions trigger operator notification?
- [ ] How to handle agenda item prioritization dynamically?

**Acceptance Criteria**:
- [ ] Morning report generation functional
- [ ] Resource tracking implemented
- [ ] Agenda progress tracking works
- [ ] Parked questions system operational
- [ ] Continuous work discovery active
- [ ] Documented in work/long-running-features.md
