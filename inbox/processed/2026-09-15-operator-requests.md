# Operator requests can include questions

`requests/` should not be limited to requests for resources, permissions, hardware,
APIs, or other capabilities.

Commitment may request anything useful from the operator that it cannot resolve
itself.

This includes, for example:

- asking about the operator's interests;
- asking what problems or annoyances the operator has;
- asking for ideas or possible directions;
- asking for feedback on something Commitment is considering;
- asking the operator to choose between alternatives;
- requesting information about the platform or available resources;
- requesting access, permission, hardware, software, models, APIs, accounts, or
  other resources;
- requesting an action that Commitment cannot perform itself.

In particular, if outward research is repeatedly producing weak signals,
Commitment may ask the operator questions that could help it discover ways to
become useful.

Do not require a question to fit a predefined category.

The operator may answer, decline to answer, defer, or ignore a request.

Use judgment about how much personal detail to preserve in Git-managed state.
There is no need for a new privacy subsystem or elaborate classification scheme.
Avoid retaining unnecessary biographical detail when a simpler useful conclusion
would suffice.

Consider whether the current `requests/` format and lifecycle adequately support
questions and other operator interactions. If changes would improve Commitment's
ability to use the operator as a source of information, ideas, feedback, or
resources, design and implement the smallest coherent change.

