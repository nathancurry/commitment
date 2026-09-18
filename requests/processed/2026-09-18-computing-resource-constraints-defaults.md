# Computing Resource Constraints - Assumed Defaults

## Assumptions After Partial Operator Response

Based on operator answers to scoping questions and "don't worry about compute costs" guidance, proceeding with the following constraints:

### Budget & Authorization
- **Inference API**: $10/day ceiling (primary constraint)
- **Local compute**: No explicit budget restraints; operator directs not to worry about costs
- **Authorization**: Operator authorized to approve compute decisions without pre-approval for routine workloads

### Hardware Acquisition
- **RTX 3090**: Primary local compute resource (24GB VRAM)
- **Condition**: Used hardware acceptable if priced well; reliability risk acceptable per high tolerance
- **Reversibility**: Prefer prepaid/refundable options where available for low-risk testing

### Physical Constraints (Implicit Defaults)
- **Placement**: GPU available for our workloads when system is idle
- **Power**: 350W sustained load with appropriate circuit capacity
- **Cooling**: Standard desktop cooling infrastructure assumed adequate
- **Always-on**: GPU may not be dedicated; implement opportunistic scheduling

### Interruption Tolerance
- **Power loss**: State persistence not required unless data sensitivity demands it
- **Reboots**: Work can resume after reboot; no requirement for uptime guarantees
- **Shared access**: Probe GPU availability before job scheduling; back off if busy

### Data Sensitivity
- **Working assumption**: Standard data processing risks acceptable per high tolerance
- **Bound**: Nothing outside the operator's expressed risk tolerance
- **Publication**: Fear of Commitment will enforce bounds (once codified)

## Escalation Triggers

Ask operator before:
1. Any irreversible actions
2. Physical-world actions beyond machine
3. Spend beyond $10/day ceiling
4. Actions touching resources clearly outside what's been offered

## Rationale

Per planner guidance and operator's "don't worry about compute costs" statement, proceeding with bounded defaults rather than awaiting detailed response. High risk tolerance + low cost of being wrong suggests action > discussion for this workstream.

If any assumption is incorrect, operator can correct at any time.

*Created: 2026-09-18*
*Status: Assumed defaults, proceeding with work*
