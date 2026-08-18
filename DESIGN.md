# design

## current state

phase 0 implements one journal-only vertical slice. host supervisor, containerized agent, Ollama client, validation policy, local apply, and local commit exist. push, scheduling, and arbitrary self-modification remain planned.

## architecture

commitment uses custom harness with minimal dependencies. it has four parts.

### host model

Ollama runs on Linux workstation. operator configures model selection for available hardware. `gpt-oss:20b` is initial example model, not universal requirement. RTX 5070 Ti 16 GB and 32 GB system RAM are one example sizing profile, not project identity or minimum requirement. model stays outside container so mutable code cannot administer model service.

### isolated container stages

two rootless Podman containers run per invocation. prepare receives the pinned repository snapshot read-only, inspects tracked files, and emits bounded Ollama request JSON through stdout. render receives the bounded Ollama response through stdin, validates model output, and emits a structured journal result through stdout.

both stages use `--userns=nomap`, fixed UID/GID `10001:10001`, `--network none`, a read-only root filesystem, dropped capabilities, `no-new-privileges`, resource limits, bounded stdin/stdout/stderr, and bounded runtime. the wheel-installed package runs with `python -I` from `/opt/commitment`; the repository mount at `/repo` is neither working directory nor import path. neither stage has a writable bind, volume, or tmpfs. prepare has one read-only repository mount. render has no mounts. model output stays data and is never executed.

### host supervisor

small host-side supervisor owns locking, pinned snapshot creation, the host-mediated Ollama call, policy, validation, apply, and local commit. it accepts only an HTTP IP-loopback Ollama endpoint, disables redirects, and bounds connection time, response headers, response body, and total request time. it verifies each uniquely named container is removed. phase 0 does not execute repository code, tests, or Git hooks on host.

supervisor is trusted control plane. agent may propose changes. proposal has no publication authority.

### repository

repo is durable state. code and prompts define current behavior. Git history records actual behavior. Markdown journal records commitment's narration. roadmap records intended work. tags mark surviving generations.

published history stays append-only. correction uses later commit. journal can later become Material for MkDocs site on GitHub Pages without becoming separate source of truth.

## phase 0 threat model

container, model output, repository files, repository Git configuration, ambient environment, and ambient Git configuration are untrusted. installed supervisor, host kernel, Git and Podman executables found through controlled system path, and operator account are trusted. repository lock prevents concurrent commitment runs. hostile same-UID local processes are out of scope.

supervisor builds small subprocess environments instead of inheriting ambient `GIT_*` variables. every Git command names exact worktree and Git directory, disables replacement objects, pagers, prompts, external diffs, global and system configuration, and fsmonitor, and forces `core.hooksPath` to a supervisor-owned empty directory. replacement refs and configured clean, smudge, or process filters are rejected before worktree-aware inspection. validated journal bytes are hashed through raw stdin with filters disabled. index changes use cacheinfo or index-info object IDs only. explicit author and committer identity does not depend on Git configuration.

phase 0 permits only one new `journal/*.md` path under fixed size budget. it never executes repository content. broader mutation may become available after bootstrap. dependency and container changes need additional validation because they change next runtime.

agent never commits, pushes, or handles GitHub credentials. after bootstrap it may propose annotated tags under `agent/*`; supervisor validates and creates them.

## phase 0 run lifecycle

1. operator starts supervisor and acquires repository-scoped host lock.
2. supervisor rejects replacement refs and pins local branch, exact `HEAD`, index bytes, index flags, and worktree status. apply or commit also requires no reported tracked, untracked, or ignored changes.
3. supervisor extracts bounded regular blobs from pinned commit with replacement objects disabled. temporary snapshot has no `.git`. symlinks, gitlinks, special entries, unsafe paths, excessive entries, and excessive bytes are rejected.
4. supervisor starts uniquely named prepare container with networking disabled and the pinned snapshot mounted read-only. bounded stdout must be valid Ollama request JSON using the configured local model and fixed generation settings.
5. supervisor sends that request directly to configured loopback Ollama with no redirect handling and bounded connection, header, body, and total deadlines.
6. supervisor passes the bounded response to a separate uniquely named render container through stdin. render validates the Ollama envelope and journal mutation, then emits path, content, size, and digest through bounded stdout.
7. supervisor independently validates exact rendered bytes and rejects unexpected paths, oversized or malformed data, timeout, and failed container cleanup.
8. dry-run removes snapshot and leaves working tree unchanged.
9. apply atomically copies validated bytes after rechecking pinned state. optional commit hashes exact validated bytes, builds tree from pinned commit in isolated temporary index, and creates commit with explicit identity. Git edits only journal entry in real index. final operation is one compare-and-swap update of pinned branch ref. successful update adds one normal entry to branch and `HEAD` reflogs.

before successful compare-and-swap, failure cleanup removes only the exact supervisor-owned journal index entry and supervisor journal file. index cleanup exclusively creates Git's canonical `.git/index.lock` before reading the current index, rechecks the owned path, stage, mode, and blob while holding it, preserves unrelated or replacement entries, writes and fsyncs the corrected lock, atomically renames it over the index, and fsyncs `.git`. an existing canonical lock is preserved and cleanup fails safely. exact pinned index bytes and mode are restored when the supervisor's staged entry is the only change. object writes before publication may leave unreachable Git objects.

after successful compare-and-swap, commit is published. supervisor does not move ref back or perform broad rollback. if interrupt loses command confirmation, supervisor reads branch ref and preserves journal and index when new commit is visible. push does not exist.

host Ollama URL must be an HTTP IP-loopback endpoint. the supervisor makes one direct request and never follows redirects. request size, aggregate response headers, header count, response body, connection time, header time, body time, and total time are bounded.

## limits and recovery

bare repositories, linked worktrees, detached `HEAD`, executable hooks, and custom `core.hooksPath` behavior are unsupported. hooks and custom hooks path are ignored, not executed. phase 0 also does not run repository tests.

process crash before compare-and-swap can leave supervisor journal file or journal index entry. unreachable Git objects are also possible. operator must inspect `git status`, current branch, and reflogs before retry. process crash after compare-and-swap may leave valid published commit without success narration. supervisor does not promise filesystem crash consistency. processes that deliberately mutate the index without acquiring Git's canonical index lock are outside the threat model.

accepted code and docs take effect on later run. running process does not replace itself in place.

## deferred scope

newsletter ingestion, social posting, and GitHub Pages build come later. external text must be treated as untrusted input. credentials for any publisher remain host-side.
