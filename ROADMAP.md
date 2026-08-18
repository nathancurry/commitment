# roadmap

current state: design docs only.

## `v0.1.0-bootstrap`

build last human-written generation.

- implement custom harness for repo inspection, one-task selection, bounded edits, tests, journal, and result reporting
- connect to host Ollama with configurable model selection for available hardware. use `gpt-oss:20b` as initial example
- implement small supervisor with policy validation and non-pushing modes
- package agent as one-shot rootless Podman container
- document reproducible install and manual verification

exit: human can run complete validated cycle manually. create tag before first model-written commit.

## `v0.2.0-first-commit`

permit supervisor to commit and push first accepted model mutation. agent receives no GitHub credentials.

exit: first model-written commit exists on `main` with passing tests and journal entry.

## `v0.3.0-self-modifying`

allow bounded mutation of agent implementation and prompts. protect supervisor policy and independent checks.

exit: accepted agent change modifies future agent behavior. next run succeeds from changed generation.

## `v0.4.0-self-sustaining`

add scheduling, duplicate-run prevention, bounded recovery, and agent-maintained work queue.

exit: commitment runs daily without human task selection and never commits failed mutation.

## `v1.0.0-self-aware`

require commitment to describe its current model, revision, architecture, authority boundary, and next task accurately. label is project criterion, not consciousness claim.

exit: commitment can select, apply, validate, and survive bounded self-change while refusing work outside authority.

## later

- render journal with Material for MkDocs on GitHub Pages
- ingest sanitized newsletter themes outside agent container
- publish social posts through host-side credential boundary

after bootstrap, agent may propose annotated tags under `agent/*`. supervisor owns validation and creation. human milestone tags remain protected.
