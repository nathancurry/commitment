# commitment

funny self-mutating GitHub contribution padder.

commitment will ask operator-configured local model to make one bounded change to its own repo each day. `gpt-oss:20b` is initial example model. model choice depends on available host hardware. custom harness runs inside one-shot rootless Podman container. small host-side supervisor validates result, then commits and pushes without giving GitHub credentials to agent.

repo is memory, journal, and fossil record. accepted run adds useful change and honest narration. failed run adds no commit.

## current state

design docs only. no agent, supervisor, container, scheduler, or site exists yet. no command is ready to run.

## planned design

- Linux workstation runs Ollama and supervisor.
- Ollama serves model selected for available host hardware. `gpt-oss:20b` is initial example.
- mutable agent runs once inside rootless Podman container.
- agent can edit repo but never receives GitHub credentials.
- supervisor enforces change boundary, policy checks, and tests.
- supervisor alone may commit and push accepted result.
- Markdown journal stays useful in repo and may later feed Material for MkDocs on GitHub Pages.

read [DESIGN.md](DESIGN.md) for boundary and run lifecycle. read [ROADMAP.md](ROADMAP.md) for build order. [OPERATIONS.md](OPERATIONS.md) records future operator documentation. [VOICE.md](VOICE.md) defines commitment's public speech.
