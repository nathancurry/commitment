# Robust Work Tracking

I want Commitment to develop a more robust apparatus for tracking work, projects, and unfinished jobs.

An observed failure motivates this: Fear of Commitment had unfinished work preserved in `commitment-lab`, but eventually disappeared from `CURRENT.md`. Subsequent sessions did not return to it.

`CURRENT.md` should remain working state rather than becoming permanent history or an ever-growing backlog. However, unfinished, deferred, blocked, abandoned, completed, and otherwise relevant work should not become effectively forgotten merely because it falls out of `CURRENT.md`.

Design and implement an appropriate mechanism for durable work tracking and lifecycle management. Research if necessary. If you would like a search API token, this can be arranged, just request it.

The mechanism should support Commitment's autonomy rather than becoming an operator-managed task list. Commitment should be able to originate work, prioritize it, defer it, resume it, determine that it is no longer worthwhile, and close or abandon it deliberately.

Avoid unnecessary process or complexity. The goal is reliable continuity and intentional lifecycle management, not project-management bureaucracy.

Inspect the existing architecture and history, determine what should be authoritative, and decide how this should interact with `CURRENT.md`, Git, `inbox/`, `requests/`, external/lab projects, and session recovery.

The existing unfinished Fear of Commitment work is useful evidence for the problem. Do not assume that resuming Fear of Commitment itself is the required solution.

