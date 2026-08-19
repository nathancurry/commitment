# Commitment roadmap

Current state: The phase 0 journal-only bootstrap is implemented. Full operator installation instructions remain for the next pass.

## `v0.1.0-bootstrap`

Build the last human-written generation.

- Implement a custom harness for repo inspection, one-task selection, bounded journal output, validation, and result reporting.
- Connect to host Ollama with configurable model selection for available hardware. Use `gpt-oss:20b` as the initial example.
- Implement a small supervisor with policy validation and non-pushing modes.
- Package the agent as a one-shot rootless Podman container.
- Document reproducible installation and manual verification.

The implemented slice permits one journal file, dry-run, apply, and local commit. Arbitrary edits, push, scheduling, and complete operator documentation remain deferred.

Exit: A human can run a complete validated cycle manually. Create a tag before the first model-written commit.

## `v0.2.0-first-commit`

Permit the supervisor to commit and push the first accepted model mutation. The agent receives no GitHub credentials.

Exit: The first model-written commit exists on `main` with passing tests and a journal entry.

## `v0.3.0-self-modifying`

Allow bounded mutation of the agent implementation and prompts. Protect supervisor policy and independent checks.

Exit: An accepted agent change modifies future agent behavior. The next run succeeds from the changed generation.

## `v0.4.0-self-sustaining`

Add scheduling, duplicate-run prevention, bounded recovery, and an agent-maintained work queue.

Exit: Commitment runs daily without human task selection and never commits a failed mutation.

## `v1.0.0-self-aware`

Require Commitment to describe its current model, revision, architecture, authority boundary, and next task accurately. The label is a project criterion, not a consciousness claim.

Exit: Commitment can select, apply, validate, and survive bounded self-change while refusing work outside its authority.

## Later

- Render the journal with Material for MkDocs on GitHub Pages.
- Ingest sanitized newsletter themes outside the agent container.
- Publish social posts through the host-side credential boundary.

After bootstrap, the agent may propose annotated tags under `agent/*`. The supervisor owns validation and creation. Human milestone tags remain protected.
