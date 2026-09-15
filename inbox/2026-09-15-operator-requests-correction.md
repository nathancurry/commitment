# Correction: direction of requests/

The previous inbox item was interpreted backwards.

The invariant is:

    requests/ contains things Commitment wants FROM the operator.

It is not a place for the operator to assign work to Commitment.

If Commitment wants to perform research, analysis, implementation, or other work
itself, that belongs in queue/ or normal work selection.

The intended expansion is that what Commitment wants from the operator may be
anything useful, not merely a resource or physical action.

Examples:

- ask what the operator is interested in;
- ask what problems or annoyances the operator has;
- ask for ideas;
- ask for information;
- ask for feedback on a possible direction;
- ask the operator to choose between alternatives;
- ask what hardware/software/resources are available;
- request permission or access;
- request an API, model, repository, account, or other resource;
- request an action Commitment cannot perform itself.

The direction is always:

    Commitment -> request/question -> operator

The operator may answer, provide the resource, act, decline, defer, or ignore it.

Please reconsider the existing
requests/2026-09-15-format-improvement.md and the current requests/ semantics in
light of this correction.

If that file describes work Commitment intends to do itself, it is misplaced.

Make the smallest coherent correction. Do not preserve the mistaken
operator -> Commitment interpretation merely because it is already documented.
