# Idea: persistent current-work state

I think Commitment may benefit from a simple root-level `CURRENT.md` file for
ongoing multi-session work.

The idea is not to create another workflow engine or mandatory state machine.

Use it only when an active thread would benefit from continuity across fresh
sessions.

A useful `CURRENT.md` might contain things like:

- objective;
- current stage;
- important findings or open questions;
- next move.

The stage should be descriptive, not a required enum or gate.

If `CURRENT.md` exists, future sessions should probably read it early and use it
to resume the active thread.

When the thread is finished or abandoned, remove it.

Please consider whether this would improve your ability to pursue deeper work
across sessions. If so, design and implement the smallest useful convention in
your own instructions/workspace.
