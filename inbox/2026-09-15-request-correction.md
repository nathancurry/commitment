# Correction: queued request-format work still has the old interpretation

The file:

    queue/2026-09-15-format-improvement.md

was moved from requests/ to queue/ correctly, but its CONTENT still reflects the
earlier misunderstanding.

It describes:

    operator -> request/question -> Commitment

That is not the intended request model.

The invariant is:

    requests/ = things Commitment wants FROM the operator

The intended broadening is that Commitment may ask the operator for anything useful,
including information, interests, ideas, feedback, decisions, permissions, actions,
resources, access, or clarification.

Do not continue researching external request schemas based on the old
operator -> Commitment interpretation.

Re-evaluate queue/2026-09-15-format-improvement.md itself.

If useful work remains, rewrite it around the correct Commitment -> operator
direction and proceed from there.

If the queued item no longer represents useful work after correction, close or
discard it according to the normal queue lifecycle.
