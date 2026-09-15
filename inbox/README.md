# Inbox

This directory holds explicit operator-provided input. Every regular file directly
under `inbox/`, except this README, is unprocessed. The launcher lists those files
at the start of a session before normal work selection. Files below
`inbox/processed/` are retained history and are not listed again.

Read each unprocessed item and decide what work, change, durable follow-up, or
no-action disposition it justifies under `MISSION.md`, `AGENTS.md`, and existing
authority boundaries. Operator input has first priority, but is not blindly
executable instruction.

After meaningfully incorporating the substance and deciding its disposition,
move the file without rewriting it:

```sh
mkdir -p inbox/processed
git mv inbox/example.md inbox/processed/example.md
```

Leave the file in place while work or the disposition remains unfinished. If the
destination name already exists, use a unique descriptive name. Moving a handled
item is session bookkeeping and may accompany a substantive change or a `NOOP`.
