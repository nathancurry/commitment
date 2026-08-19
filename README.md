# Commitment

A funny, self-mutating GitHub contribution padder.

Commitment asks an operator-selected local model for one bounded journal entry. The host supervisor validates the result. The default run is a dry-run. Optional modes apply the entry or create a local commit. No mode pushes.

## Current state

The phase 0 bootstrap works.

The supervisor resolves `HEAD` once and extracts tracked blobs from that exact commit into a bounded snapshot without `.git`. Separate one-shot rootless Podman containers prepare the request and render the response. Both use read-only filesystems, no network, UID/GID `10001:10001`, and no writable mount. The host alone calls loopback Ollama, validates the journal result, and may change the repo.

Live acceptance uses `gpt-oss:20b`. The request gives the model explicit context and output budgets, low reasoning, and an exact JSON contract. The 16,384-token context reserves 4,096 output tokens and 2,048 template and framing tokens. Prompt input is at most 10,240 UTF-8 bytes under a conservative one-token-per-byte bound.

The prompt contains a manifest of every tracked regular file. It includes only complete UTF-8 files, prioritizing `VOICE.md`, `README.md`, `DESIGN.md`, `ROADMAP.md`, and `OPERATIONS.md`, then byte-sorted paths. The manifest and summary identify omitted files and bytes. An oversized manifest fails instead of silently truncating. Model output remains untrusted. The host accepts only one bounded `journal/*.md` result.

Push, scheduling, issues, blog publication, arbitrary code mutation, and self-modification do not exist. They remain on the roadmap.

## Quick start

You need Linux, Git, `curl`, Ollama, `uv`, and rootless Podman. Use a normal non-root account. Keep the uv environment outside the target repo because apply mode rejects ignored files too.

Install Ollama:

```sh
curl -fsSL https://ollama.com/install.sh | sh
ollama serve
```

In a second terminal:

```sh
curl --fail --silent --show-error http://127.0.0.1:11434/api/version
ollama pull gpt-oss:20b
ollama list
```

`gpt-oss:20b` is an optional example. The current download is about 14 GB. Choose a smaller installed model when the host needs it.

From the `commitment` clone:

```sh
export UV_PROJECT_ENVIRONMENT=/path/outside/repository/commitment-venv
uv sync --locked
podman build -t commitment:latest .
uv run --locked commitment --repo . --image commitment:latest --model gpt-oss:20b
```

Success says `dry run done.` and `working tree unchanged.` A dry-run does not invoke apply, index-publication, commit, or ref-update paths. It does not write Git refs, the index, or the working tree. Unrelated concurrent Git activity is outside that statement and is not captured or attributed to Commitment.

Read [OPERATIONS.md](OPERATIONS.md) before apply or commit. [DESIGN.md](DESIGN.md) states the boundary and crash windows. [VOICE.md](VOICE.md) controls Commitment speech.
