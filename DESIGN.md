# Commitment design

## Current state

Phase 0 implements one journal-only vertical slice. The host supervisor, containerized agent, Ollama client, validation policy, local apply, and local commit exist. Push, scheduling, and arbitrary self-modification remain planned.

## Architecture

Commitment uses a custom harness with minimal dependencies. It has four parts.

### Host model

Ollama runs on a Linux workstation. The operator configures model selection for available hardware. `gpt-oss:20b` is an initial example model, not a universal requirement. An RTX 5070 Ti with 16 GB and 32 GB of system RAM is one example sizing profile, not the project identity or a minimum requirement. The model stays outside the container so mutable code cannot administer the model service.

### Isolated container stages

Two rootless Podman containers run per invocation. Prepare receives the pinned repository snapshot read-only, inspects tracked files, and emits bounded Ollama request JSON through stdout. The request uses a 16,384-token context, reserves 4,096 output tokens and 2,048 template and framing tokens, and limits the prompt to 10,240 UTF-8 bytes under a conservative one-token-per-byte upper bound. Render receives the bounded Ollama response through stdin, validates model output, and emits a structured journal result through stdout.

Snapshot inspection and prompt selection have separate limits. Prepare manifests every tracked regular file from the snapshot. It includes only whole UTF-8 file contents, prioritizing `VOICE.md`, `README.md`, `DESIGN.md`, `ROADMAP.md`, and `OPERATIONS.md`, then remaining paths in UTF-8 byte order. Manifest states mark included, omitted, and non-UTF-8 files. Fixed-width summary fields report included and omitted byte totals and zero partial files. Prepare fails when the framing and full manifest cannot fit. Omission changes model visibility, so a journal may use only the included evidence.

Both stages use `--userns=nomap`, fixed UID/GID `10001:10001`, `--network none`, a read-only root filesystem, dropped capabilities, `no-new-privileges`, resource limits, bounded stdin/stdout/stderr, and bounded runtime. The wheel-installed package runs with `python -I` from `/opt/commitment`; the repository mount at `/repo` is neither the working directory nor the import path. Neither stage has a writable bind, volume, or tmpfs. Prepare has one read-only repository mount. Render has no mounts. Model output stays data and is never executed.

### Host supervisor

The small host-side supervisor owns locking, pinned snapshot creation, the host-mediated Ollama call, policy, validation, apply, and local commit. It accepts only an HTTP IP-loopback Ollama endpoint, disables redirects, and bounds connection time, response headers, response body, and total request time. It verifies that each uniquely named container is removed. Phase 0 does not execute repository code, tests, or Git hooks on the host.

The supervisor is the trusted control plane. The agent may propose changes. The proposal has no publication authority.

### Repository

The repo is durable state. Code and prompts define current behavior. Git history records actual behavior. The Markdown journal records Commitment’s narration. The roadmap records intended work. Tags mark surviving generations.

Published history stays append-only. A correction uses a later commit. The journal can later become Material for an MkDocs site on GitHub Pages without becoming a separate source of truth.

## Phase 0 threat model

The container, model output, repository files, repository Git configuration, ambient environment, and ambient Git configuration are untrusted. The installed supervisor, host kernel, Git and Podman executables found through the controlled system path, and operator account are trusted. The repository lock prevents concurrent Commitment runs. Hostile same-UID local processes are out of scope.

The supervisor builds small subprocess environments instead of inheriting ambient `GIT_*` variables. Every Git command names the exact worktree and Git directory, disables replacement objects, pagers, prompts, external diffs, global and system configuration, and fsmonitor, and forces `core.hooksPath` to a supervisor-owned empty directory. Replacement refs and configured clean, smudge, or process filters are rejected before worktree-aware inspection. Validated journal bytes are hashed through raw stdin with filters disabled. Index changes use cacheinfo or index-info object IDs only. Explicit author and committer identity does not depend on Git configuration.

Phase 0 permits only one new `journal/*.md` path under a fixed size budget. It never executes repository content. Broader mutation may become available after bootstrap. Dependency and container changes need additional validation because they change the next runtime.

The agent never commits, pushes, or handles GitHub credentials. After bootstrap, it may propose annotated tags under `agent/*`; the supervisor validates and creates them.

## Phase 0 run lifecycle

1. The operator starts the supervisor and acquires the repository-scoped host lock.
2. The supervisor rejects replacement refs, resolves the local branch and exact `HEAD`, and records index bytes, index flags, and worktree status. Apply or commit also requires no reported tracked, untracked, or ignored changes.
3. The supervisor extracts bounded regular blobs from the resolved `HEAD` commit with replacement objects disabled. The temporary snapshot has no `.git`. Symlinks, gitlinks, special entries, unsafe paths, excessive entries, and excessive bytes are rejected.
4. The supervisor starts a uniquely named prepare container with networking disabled and the pinned snapshot mounted read-only. Bounded stdout must be valid Ollama request JSON using the configured local model and fixed generation settings.
5. The supervisor sends that request directly to configured loopback Ollama with no redirect handling and bounded connection, header, body, and total deadlines.
6. The supervisor passes the bounded response to a separate uniquely named render container through stdin. Render validates the Ollama envelope and journal mutation, then emits the path, content, size, and digest through bounded stdout.
7. The supervisor independently validates the exact rendered bytes and rejects unexpected paths, oversized or malformed data, timeouts, and failed container cleanup.
8. A dry-run removes the snapshot without invoking apply, index-publication, commit, or ref-update paths. It does not write Git refs, the index, or the working tree. Unrelated concurrent Git activity is not captured or attributed to Commitment.
9. Apply atomically copies validated bytes after rechecking pinned state. An optional commit hashes exact validated bytes, builds a tree from the pinned commit in an isolated temporary index, and creates a commit with explicit identity. Git edits only the journal entry in the real index. The final operation is one compare-and-swap update of the pinned branch ref. A successful update adds one normal entry to the branch and `HEAD` reflogs.

Before a successful compare-and-swap, failure cleanup removes only the exact supervisor-owned journal index entry and supervisor journal file. Index cleanup exclusively creates Git's canonical `.git/index.lock` before reading the current index, rechecks the owned path, stage, mode, and blob while holding it, preserves unrelated or replacement entries, writes and fsyncs the corrected lock, atomically renames it over the index, and fsyncs `.git`. An existing canonical lock is preserved, and cleanup fails safely. Exact pinned index bytes and mode are restored when the supervisor's staged entry is the only change. Object writes before publication may leave unreachable Git objects.

After a successful compare-and-swap, the commit is published. The supervisor does not move the ref back or perform broad rollback. If an interrupt loses command confirmation, the supervisor reads the branch ref and preserves the journal and index when the new commit is visible. Push does not exist.

The host Ollama URL must be an HTTP IP-loopback endpoint. The supervisor makes one direct request and never follows redirects. Request size, aggregate response headers, header count, response body, connection time, header time, body time, and total time are bounded.

## Limits and recovery

Bare repositories, linked worktrees, detached `HEAD`, executable hooks, and custom `core.hooksPath` behavior are unsupported. Hooks and a custom hooks path are ignored, not executed. Phase 0 also does not run repository tests.

A process crash before compare-and-swap can leave a supervisor journal file or journal index entry. Unreachable Git objects are also possible. The operator must inspect `git status`, the current branch, and reflogs before retrying. A process crash after compare-and-swap may leave a valid published commit without success narration. The supervisor does not promise filesystem crash consistency. Processes that deliberately mutate the index without acquiring Git's canonical index lock are outside the threat model.

Accepted code and docs take effect on a later run. A running process does not replace itself in place.

## Deferred scope

Newsletter ingestion, social posting, and a GitHub Pages build come later. External text must be treated as untrusted input. Credentials for any publisher remain host-side.
