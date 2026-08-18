# commitment

funny self-mutating GitHub contribution padder.

commitment asks an operator-configured local model for one bounded journal change. `gpt-oss:20b` is the initial example model. model choice depends on available host hardware. custom prepare and render harness stages run in separate one-shot rootless Podman containers. a small host-side supervisor validates the result and may apply it or create a local commit without giving credentials to either stage.

repo is memory, journal, and fossil record. accepted run adds useful change and honest narration. failed run adds no commit.

## current state

phase 0 bootstrap is implemented. host-side Python supervisor locks repo, pins exact branch and `HEAD`, extracts bounded regular Git blobs into a read-only snapshot without `.git`, and runs two network-disabled rootless Podman stages as `10001:10001` under `--userns=nomap`. the wheel-installed package runs with `python -I` from `/opt/commitment`, outside the read-only `/repo` snapshot mount and import path. `prepare` reads the snapshot and emits bounded Ollama request JSON. `render` reads the bounded Ollama response from stdin and emits a validated structured journal result. neither stage has a writable mount. default run is dry-run. `--apply` atomically copies validated bytes into a clean working tree. `--commit` requires `--apply` and creates a local commit from an isolated index plus one narrow real-index update and branch compare-and-swap.

model and host Ollama endpoint use `--model`, `--ollama-url`, `COMMITMENT_MODEL`, and `COMMITMENT_OLLAMA_URL`. the endpoint is restricted to HTTP IP loopback. between the two container stages, the host supervisor sends exactly one bounded `POST /api/generate` directly to Ollama with redirects disabled and separate connection, header, body, and total deadlines. low-variance generation settings reduce variation. they do not make the model strictly deterministic.

push, scheduling, arbitrary code mutation, and full operator installation instructions are not implemented.

## design

- Linux workstation runs Ollama and supervisor.
- Ollama serves model selected for available host hardware. `gpt-oss:20b` is initial example.
- prepare and render run in separate uniquely named, network-disabled rootless Podman containers.
- prepare receives only the pinned repository snapshot as a read-only mount. render receives only bounded stdin. both return bounded stdout and have read-only root filesystems.
- supervisor enforces journal-only boundary and entry, input, output, HTTP, process, and timeout budgets.
- supervisor alone may apply and locally commit accepted result with pinned-state checks and compare-and-swap ref update.
- Markdown journal stays useful in repo and may later feed Material for MkDocs on GitHub Pages.

phase 0 runs no repository code, tests, or Git hooks. bare repos, linked worktrees, detached `HEAD`, executable hooks, and custom hooks-path behavior are unsupported. [DESIGN.md](DESIGN.md) states exact threat model, crash windows, and recovery behavior.

read [DESIGN.md](DESIGN.md) for boundary and run lifecycle. read [ROADMAP.md](ROADMAP.md) for build order. [OPERATIONS.md](OPERATIONS.md) records future operator documentation. [VOICE.md](VOICE.md) defines commitment's public speech.
