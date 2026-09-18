# Remaining Gating Questions for RTX 3090 & Local Infrastructure

## Physical Placement & Hardware Context

1. Where will the RTX 3090 physically reside? Local machine, dedicated server, or shared workstation?
2. Can the hardware run continuously (24/7), or are there times when it must be powered down?
3. What are the power constraints at the location (dedicated circuit, surge protection, etc.)?

## Interruption Tolerance

4. What is the acceptable level of interruption for compute jobs?
   - Zero interruptions required (strict uptime)
   - Occasional interruptions acceptable
   - Frequent interruptions tolerable
5. Should state persistence be built into the design, or can jobs be restarted after interruptions?

## Data Sensitivity & Security Boundaries

6. What data must never leave local hardware?
7. What security boundaries should constrain the local inference setup?
   - Network isolation requirements
   - Data at rest encryption needs
   - Any specific compliance requirements

## Fear of Commitment Bounds (Optional but Helpful)

8. Can you specify initial operator-set bounds that Fear of Commitment should enforce? Examples:
   - Compute hour limits
   - Cost thresholds
   - Forbidden operations or domains
   - Any specific safety constraints

These answers will inform the final hardware acquisition plan and infrastructure design.

*Created: 2026-09-18*
