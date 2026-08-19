# Commitment operations

Phase 0 runs one bounded journal mutation. A dry-run is the default. Apply and local commit need explicit flags. No command pushes.

## Prerequisites

You need:

- A Linux host.
- A normal non-root account.
- Git.
- `curl`.
- Ollama with a loopback API.
- `uv`.
- Rootless Podman.
- A normal Git worktree on a local branch.

Bare repos, linked worktrees, detached `HEAD`, and root-run Podman are unsupported.

Install Podman with the platform package manager. Follow the [official Podman installation guide](https://podman.io/docs/installation). Verify rootless mode:

```sh
podman --version
podman info --format '{{.Host.Security.Rootless}}'
```

The second command must print `true`.

## Install and start Ollama

The official Linux installer needs system write access:

```sh
curl -fsSL https://ollama.com/install.sh | sh
```

Start the foreground service:

```sh
ollama serve
```

When the installer creates a system service, use this alternative:

```sh
sudo systemctl enable --now ollama.service
sudo systemctl status ollama.service
```

Verify the client and loopback API:

```sh
ollama --version
curl --fail --silent --show-error http://127.0.0.1:11434/api/version
curl --fail --silent --show-error http://127.0.0.1:11434/api/tags
```

Commitment accepts only plain HTTP on `127.0.0.1` or `::1`. Redirects and credentials are rejected.

## Select a model

List installed models:

```sh
ollama list
```

The default is `gpt-oss:20b`. Pull only after checking model size and host capacity:

```sh
ollama pull gpt-oss:20b
```

The current `gpt-oss:20b` download is about 14 GB. An optional example sizing is 16 GB of memory for the model. This is not a project minimum. Another model may use less.

Select a model per command:

```sh
uv run --locked commitment --repo /path/to/repository --model installed-model:tag
```

Or set the default for the shell:

```sh
export COMMITMENT_MODEL=installed-model:tag
```

Commitment requests a 16,384-token context. It reserves 4,096 tokens for reasoning and output plus 2,048 tokens for the model template and prompt framing. The remaining prompt is limited to 10,240 UTF-8 bytes using a conservative worst case of one token per byte.

The repository snapshot limits remain larger and separate. Prepare always lists every tracked regular file in a manifest, then includes complete UTF-8 contents in this order: `VOICE.md`, `README.md`, `DESIGN.md`, `ROADMAP.md`, `OPERATIONS.md`, then remaining paths in UTF-8 byte order. The prompt reports each omitted file and byte count. It never silently includes part of a file. Non-UTF-8 files are listed but not included as content. When framing and the complete manifest do not fit, the run fails before calling Ollama.

## Set up uv

Install `uv` with the package manager or official installer:

```sh
curl -LsSf https://astral.sh/uv/install.sh | sh
uv --version
```

From the `commitment` clone, keep the environment outside the target repo. Apply rejects ignored files, including a local `.venv` and build artifacts:

```sh
export UV_PROJECT_ENVIRONMENT=/path/outside/repository/commitment-venv
uv sync --locked
uv lock --check
```

`uv.lock` must match `pyproject.toml`.

## Build the image

From the `commitment` clone:

```sh
podman build -t commitment:latest .
podman image inspect commitment:latest
```

The build must finish with the image tagged `localhost/commitment:latest`.

## Dry-run

Check Ollama and the repo first:

```sh
curl --fail --silent --show-error http://127.0.0.1:11434/api/version
ollama list
git -C /path/to/repository branch --show-current
git -C /path/to/repository status --short --untracked-files=all --ignored=matching --no-renames
```

Run:

```sh
uv run --locked commitment \
  --repo /path/to/repository \
  --image commitment:latest \
  --model gpt-oss:20b
```

Expected end:

```text
dry run done.
working tree unchanged.
journal: journal/YYYY-MM-DD-slug.md
```

Dry-run allows an existing worktree state. Its source snapshot comes from the resolved `HEAD` commit. A dry-run does not invoke apply, index-publication, commit, or ref-update paths, and does not write Git refs, the index, or the working tree. Unrelated concurrent Git activity is not captured or attributed to Commitment.

## Apply

Apply requires a completely clean target. Tracked, untracked, and ignored entries all cause rejection.

```sh
git -C /path/to/repository status --short --untracked-files=all --ignored=matching --no-renames
uv run --locked commitment \
  --repo /path/to/repository \
  --image commitment:latest \
  --model gpt-oss:20b \
  --apply
```

The expected result is one untracked `journal/*.md` file. There are no index or ref changes.

Inspect it:

```sh
git -C /path/to/repository status --short
git -C /path/to/repository diff --no-index /dev/null /path/to/repository/journal/YYYY-MM-DD-slug.md
```

## Local commit

Local commit requires a clean target and `--apply`:

```sh
uv run --locked commitment \
  --repo /path/to/repository \
  --image commitment:latest \
  --model gpt-oss:20b \
  --apply \
  --commit
```

Verify the local result:

```sh
git -C /path/to/repository show --stat --oneline --decorate HEAD
git -C /path/to/repository status --short
```

The commit author is the fixed supervisor identity. Hooks do not run. No push occurs.

## Recover index residue

A crash before branch compare-and-swap may leave a supervisor journal file, staged journal entry, or unreachable objects. Inspect before cleanup:

```sh
git -C /path/to/repository branch --show-current
git -C /path/to/repository status --short
git -C /path/to/repository reflog --date=iso -n 10
git -C /path/to/repository diff --cached -- journal/YYYY-MM-DD-slug.md
git -C /path/to/repository diff -- journal/YYYY-MM-DD-slug.md
```

When the reflog shows a Commitment commit, keep the file and index. The commit succeeded.

When the branch did not advance and the staged entry is exact supervisor journal residue, remove only that index entry:

```sh
git -C /path/to/repository restore --staged -- journal/YYYY-MM-DD-slug.md
git -C /path/to/repository status --short
```

Preserve the unwanted worktree file before retrying:

```sh
mv /path/to/repository/journal/YYYY-MM-DD-slug.md /path/to/safe/recovery-copy.md
```

Do not reset the branch or the whole index. Unreachable objects need no immediate action. Retry only after the expected repo state is clear.

## Common failures

`ollama: command not found`: Install Ollama. Restart the shell if the installer changed `PATH`.

`Ollama connection failed`: Start the service. Verify `/api/version` on the configured loopback URL.

`Ollama bounded request timed out`: Warm the selected model with `ollama run installed-model:tag "reply ok"`. Choose a faster model if generation cannot finish inside the 120-second upstream limit.

`Ollama response exceeds 262144 bytes`: Choose a model that follows the bounded request. The response envelope includes reasoning and context metadata.

`model returned malformed mutation JSON`: The model missed the exact JSON contract. Retry or choose a better instruction-following model.

`prompt framing and manifest exceed 10240 UTF-8 bytes`: The repository has too many or unusually long tracked paths for the bounded prompt view. Reduce the tracked-path manifest before retrying.

`apply target has uncommitted, untracked, or ignored changes`: Inspect the full status. Move or finish every entry. Keep the uv environment outside the target repo.

`commitment requires rootless Podman`: Run from a normal non-root account. Verify the Podman rootless state.

image not found: Rebuild `commitment:latest` or pass the correct `--image`.

container cleanup failure: Inspect exact names only:

```sh
podman ps -a --filter name=commitment-
```

repository lock error: Wait for the other Commitment process. Inspect the process before treating `.git/commitment.lock` as stale.

## Current limits

- One new bounded `journal/*.md` path only.
- Dry-run prints the path, not proposed content.
- A later apply run regenerates output. Fixed settings do not make the model deterministic.
- The host validates structure, path, bytes, size, and digest. The operator still owns the meaning review.
- Apply and commit require no tracked, untracked, or ignored target changes.
- No push, scheduling, issues, blog publication, tags, arbitrary mutation, or self-modification.
- No bare repo, linked worktree, detached `HEAD`, executable hooks, or custom hooks behavior.
- Custom hooks are ignored. Repository code and tests do not run during mutation.
- Only a loopback Ollama endpoint works.
- Hostile same-UID processes and filesystem crash consistency are out of scope.
