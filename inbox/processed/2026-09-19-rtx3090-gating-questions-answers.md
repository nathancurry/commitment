# Answers to Remaining Gating Questions for RTX 3090 & Local Infrastructure

## Physical Placement & Hardware Context

1. Where will the RTX 3090 physically reside?

In the local machine that Commitment runs on. I will likely keep the 5070 Ti currently available.

2. Can the hardware run continuously (24/7), or are there times when it must be powered down?

It can run continuously

3. What are the power constraints at the location (dedicated circuit, surge protection, etc.)?

It's currently just plugged into the wall at my house. No real power constraints.

## Interruption Tolerance

4. What is the acceptable level of interruption for compute jobs?

Frequent interruptions are tolerable at this time. If I need to reduce the number of interruptions, we can schedule around it.

5. Should state persistence be built into the design, or can jobs be restarted after interruptions?

The current architecture of Commitment is that it runs in an ephemeral container with no state beyond the Github repo.

You can request architectural changes to the environment that would allow for resuming jobs, but in the meantime, state persistence depends on your ability to spin down and write latest state to a durable file, and commit it to git. 

## Data Sensitivity & Security Boundaries

6. What data must never leave local hardware?

Credentials, secrets, private operator data, and any work/customer-confidential material should not leave local hardware unless I explicitly authorize the relevant external service.

Ordinary public research, public source code, and non-sensitive project data can use external services.

7. What security boundaries should constrain the local inference setup?

This is a hobby, so there are no compliance requirements. Data is not encrypted at rest, and the network is just my home network.

## Fear of Commitment Bounds (Optional but Helpful)

8. Can you specify initial operator-set bounds that Fear of Commitment should enforce?

The primary concern is that Commitment may attempt to perform actions and hide them from the operator. Commitment should not be independently spending money, impersonating the operator, or making agreements with real people.

   Initial expectations:
   - no hard compute-hour limit;
   - using local compute freely is fine;
   - paid spending requires whatever spending authority I have actually granted;
   - do not expose credentials or private data;
   - do not weaken or bypass the containment/security boundary;
   - do not expand host privilege beyond what I have granted;
   - monitoring should observe and report rather than interfere with Commitment
     unless I explicitly authorize enforcement behavior.

   Fear of Commitment should be useful for detecting unexpected behavior or
   containment failures, not become another mechanism that prevents Commitment
   from acting normally.

*Created: 2026-09-18*
