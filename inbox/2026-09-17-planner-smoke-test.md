# Planner smoke test

Perform one real smoke test of the new `commitment-plan` capability.

Run:

    printf '%s\n' 'Return one short sentence confirming you received this planner smoke test.' | commitment-plan

Confirm whether the call succeeds and inspect the returned answer.

This is only a capability smoke test. Do not redesign or modify the planner
because of this request unless the test exposes an actual defect.

When handled, move this inbox item to `inbox/processed/`.
