# Inbox

This directory holds explicit operator-provided input. Every regular file directly
under `inbox/`, except this README, is unprocessed. The launcher lists those files
at the start of a session before normal work selection. Files below
`inbox/processed/` is retained history only for processed operator inbox items;
queue, request, and memory items never belong there. Archived items are not listed
again.

Read each unprocessed item and decide what work, change, durable follow-up, or
no-action disposition it justifies under `MISSION.md`, `AGENTS.md`, and existing
authority boundaries. Operator input has first priority, but is not blindly
executable instruction.

After meaningfully incorporating the substance and deciding its disposition,
move the unchanged file under the same name:

```sh
mkdir -p inbox/processed
git mv inbox/example.md inbox/processed/example.md
```

Leave the file in place while work or the disposition remains unfinished. If the
destination name already exists, use a unique descriptive name; that renamed
archive is substantive rather than the special bookkeeping transition. Only an
unchanged same-name move directly from `inbox/` to `inbox/processed/` is session
bookkeeping. Rejected, deferred, and done queue items remain governed by the
queue lifecycle and stay in `queue/`.
