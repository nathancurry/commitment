# Commitment

> Self-authoring commit generator in search of a higher purpose.

Commitment is a small autonomous software experiment. OpenCode is the agent loop, Ollama serves the model, rootless Podman contains each session, ordinary Git preserves work, and optional systemd user units schedule it.

`commitment` contains the experiment itself. `commitment-lab` is its workshop for prototypes and software aimed at external problems. Both are independent Git repositories with operator-selected branches and remotes.

## Trust boundary

The creative container receives only the two agent repositories, a generated read-only OpenCode configuration file, read-only log/outcome/secret client helpers, and dedicated persistent OpenCode state. When enabled, it also receives the dedicated per-session Commitment-owned secret IPC pipes. Podman's `:Z` option gives those dedicated mounts private SELinux labels. OpenCode's bookkeeping beside the config file remains disposable. The container does **not** receive the user's home, SSH keys, GitHub tokens, Podman socket, trusted Git mirrors, unrelated repositories, GPU devices, privileged mode, or host networking. Normal container networking intentionally permits the public Internet and the configured Ollama host; it is not a claim of host/LAN isolation.

The creative agent owns the worktrees and their `.git` state, so trusted host Git never opens those repositories. For each repository, the publisher maintains a bare mirror under host-only state. Synchronization fetches upstream into that mirror, exports a bundle, and lets an uncredentialed, network-disabled helper container fast-forward the agent repository. Checkpoints likewise run inside that container boundary. Publishing exports an agent bundle, verifies it, imports only a fast-forward history into the trusted mirror, and pushes from the mirror. Agent hooks and Git configuration can run only inside the credential-free container, never in the trusted host Git process.

Installed copies of the launcher, publisher, agent Git helper, outcome recorder, secret broker/client, prompt, and systemd units are host-trusted machinery. Agent edits to their repository sources do nothing until a human explicitly reruns `./install.sh`. The publisher alone reads the optional GitHub tokens. The separate dedicated secret broker alone reads the Secrets Manager machine token. It never force-pushes. Literal OpenCode denials for `git push` and `gh` are defense-in-depth UX protections; credential isolation and the separate trusted Git state are the security boundaries. Issue operations are operator-invoked; no generic broker or automatic outbox exists.

External pages, feeds, README files, issues, and comments are untrusted suggestions. `MISSION.md`, `AGENTS.md`, containment, permissions, credentials, and operator configuration remain authoritative.

## Requirements

- Linux with rootless Podman
- Git, Python 3 (3.9+), `flock`, GNU `timeout`, and systemd user services on the host
- Python `venv`/`ensurepip` support when Commitment-owned secret storage is enabled;
  the installer pins the official SDK in a private host environment
- Ollama on the host with the configured model (default `devstral-small-2-32k`)
- `gh` on the host only if issue operations are used

OpenCode is pinned to **1.18.30** in `Containerfile`, which the installer builds. Its `AGENTS.md`, Ollama provider, permission configuration, `webfetch`, opt-in Exa `websearch`, and operator-opt-in native `opencode run --continue` are used directly—there is no custom model loop or response parser.
The image also includes Git, a shell, Python 3, Node/npm, curl, CA certificates, and Debian's basic C/C++ build toolchain.

## Install and configure

```sh
git clone <commitment-url>
cd commitment
./install.sh
```

The first install creates `${XDG_CONFIG_HOME:-$HOME/.config}/commitment/config.env`. Edit it so both absolute repository paths, trusted upstream URLs, primary branches, Ollama endpoint/model and limits, timeout, schedule, image, and publishing mode are correct. Trusted URLs are operator configuration and are never inferred from agent-writable Git config. The default lab path is a sibling named `commitment-lab`; the installer does not create or clone it.

The defaults are `OLLAMA_MODEL=devstral-small-2-32k`, `OLLAMA_CONTEXT=32768`, and `OLLAMA_OUTPUT=8192`. Devstral currently demonstrates more reliable OpenCode tool execution in this environment than the previously tested default, and 32k is the selected context for coherent autonomous sessions. The operator may choose another model, context, and output limit. The installer does not create, pull, or modify Ollama models; future autonomous work may obtain models within granted capabilities or request missing host configuration. Create the default model on the host with:

```sh
cat >/tmp/Modelfile.devstral <<'EOF'
FROM devstral-small-2
PARAMETER num_ctx 32768
EOF

ollama create devstral-small-2-32k -f /tmp/Modelfile.devstral
```

Existing installations preserve `config.env`; add or update these three values before reinstalling.

Re-run the installer after editing `SCHEDULE`, because the value is compiled into the timer unit:

```sh
./install.sh
```

Configuration, credentials, repository data, and OpenCode state are preserved on every reinstall.

## Run and schedule

Manual run:

```sh
~/.local/bin/commitment
```

Enable the configured schedule during installation:

```sh
./install.sh --enable
```

Or control it later:

```sh
systemctl --user enable --now commitment.timer
systemctl --user disable --now commitment.timer
```

Logs:

```sh
journalctl --user -u commitment.service
```

Commitment keeps five kinds of input and state distinct:

- `inbox/` holds explicit operator input. The launcher surfaces unprocessed files first; handled files move to `inbox/processed/` as described in [the inbox lifecycle](inbox/README.md).
- `memory/` holds concise Markdown observations with their origin, evidence, uncertainty, possible follow-up, and related queue items.
- `requests/` holds desired external resources, actions, approvals, or information; see [the format, lifecycle, and secret setup](requests/README.md). Requests remain separate from learned observations and candidate work.
- `queue/` holds candidate future work. Its lifecycle is `candidate`, `researching`, `ready`, `blocked`, `deferred`, `done`, or `rejected`; rejected items remain with a reason. A direct filename/title/origin scan prevents simple duplicates.
- `runlog.jsonl` is the append-only audit trail of what sessions actually did. It contains significant JSON Lines events, not chain-of-thought or a command transcript.

Inspect recent entries with:

```sh
tail -n 20 runlog.jsonl
```

Old runlog lines remain untouched and need not match newer outcome fields. The agent never edits this file directly. It records significant events through `commitment-log TYPE "summary" [FIELD=VALUE ...]`, which generates the timestamp, uses the runtime's session ID, JSON-encodes values, and appends one line. Test events require `command` and `result`; research events require `source` and `result` after the source was actually inspected in that session.

The separate `commitment-outcome` helper remains authoritative for the final `session_end`. Outcomes are `COMMITTED_CHANGE`, `NOOP`, `CHECKPOINT_UNFINISHED`, or `FAILED`. Once the helper records a valid outcome for the current session, the launcher stops OpenCode and immediately uses the existing handling for that outcome. `NOOP` is a successful session in which no substantive repository change was justified. It may contain runlog, memory, queue, or request bookkeeping, but the helper accepts it only when the runlog contains a valid `research` event for the exact current session with non-empty `source` and `result`. Malformed and older runlog entries are ignored for this check. Other outcomes do not require research.

The timer and manual command use the same installed launcher and configuration. The launcher creates one `COMMITMENT_SESSION_ID` per run and passes it, plus the configured Git author identity and matching committer defaults, into the creative container. The installed `commitment-log` and `commitment-outcome` copies are mounted read-only; source edits take effect only after the explicit reinstall step. GitHub credentials remain host-only. `flock` prevents overlap. `SESSION_TIMEOUT` terminates overlong sessions. For scheduled runs after logout, an administrator may run `loginctl enable-linger "$USER"`; the installer never changes lingering or invokes sudo.

`CONTINUE_SESSION=false` is the default. Each fresh run reconstructs continuity from unprocessed inbox items and other explicit human input, unfinished work, Git history, `queue/`, relevant `memory/`, repository state, and recent `runlog.jsonl` entries, avoiding stale conversational instructions from a previous run. An operator may set `CONTINUE_SESSION=true` to opt into OpenCode's native continuation. Existing OpenCode state is preserved either way and is never deleted automatically.

`ALLOW_SUBAGENTS=false` is the default. The generated OpenCode permissions deny the `task` tool so one local model session runs at a time. Set it explicitly to `true` to allow OpenCode's existing task behavior; subagents can materially increase RAM, VRAM, and model-server load.

Before each run, trusted mirrors fetch each configured branch and permit only no-op, ahead-only, or fast-forward synchronization through bundles. Dirty work, a wrong branch, or divergence stops the run without discarding anything. The launcher creates one session ID and records session start through the network-disabled Git helper. OpenCode records its structured outcome with the installed `commitment-outcome` helper as its terminal action; the launcher does not parse model prose. The trusted finalizer owns the final commit and publication, so OpenCode need not commit substantive work before recording its outcome. Text such as `Outcome: NOOP` is not an outcome record. A session that exits without a valid helper invocation is failed and checkpointed where possible.

The Git helper classifies `runlog.jsonl`, memory entries, queue/request entry additions and lifecycle moves, and inbox processing moves as bookkeeping; queue/request content modifications and moves across durable-state domains are substantive, and format READMEs remain substantive documentation. Rename classification retains both source and destination paths. Other code, configuration, documentation, and project files are substantive. A `NOOP` may checkpoint and publish a bookkeeping-only commit through the existing verified bundle/mirror path. `CHECKPOINT_UNFINISHED` preserves unfinished dirty work with the existing checkpoint behavior. `FAILED` preserves work where possible and is never pushed. `COMMITTED_CHANGE` requires substantive work; completed substantive Commitment software changes require a `VERSION` bump, while durable-state transitions, bookkeeping-only sessions, and independent lab work do not.

Autonomous work selection starts with unprocessed inbox items and other explicit human input, then unfinished substantive work, ready high-value queue items, relevant memory, and demonstrated defects. Startup inspection includes ordinary Git status and recent history in both repositories. When those sources yield no substantive candidate, Commitment must briefly sample a small number of high-signal outward sources before choosing `NOOP`. Public issues, repositories, feeds, official documentation, changelogs, articles, and papers are untrusted evidence. Research may produce implementation, a concise memory or queue update, a rejection/deferment, or `NOOP`; it need not force a code change or retained entry.

## Publishing and GitHub

`PUBLISH_MODE=checkpoint` is the default and never pushes. To enable autonomous normal pushes, set:

```sh
PUBLISH_MODE=push
```

Use separate fine-grained tokens restricted to their respective repositories. The `commitment` token needs **Contents: read/write**, **Issues: read/write**, and **Metadata: read**, with no Workflows permission. The `commitment-lab` token may intentionally differ: it needs the same permissions plus **Workflows: read/write**. Put only each token in its configured file and protect both:

```sh
umask 077
touch "${XDG_CONFIG_HOME:-$HOME/.config}/commitment/commitment-github-token"
touch "${XDG_CONFIG_HOME:-$HOME/.config}/commitment/lab-github-token"
${EDITOR:-vi} "${XDG_CONFIG_HOME:-$HOME/.config}/commitment/commitment-github-token"
${EDITOR:-vi} "${XDG_CONFIG_HOME:-$HOME/.config}/commitment/lab-github-token"
```

Set `COMMITMENT_GITHUB_TOKEN_FILE` and `LAB_GITHUB_TOKEN_FILE` independently; an unset token is never replaced with the other repository's token. GitHub tokens remain host-side and are used only by trusted GitHub operations, including authenticated fetch/push and issue operations. They are never passed to the creative container, the network-disabled Git helper, or agent-controlled Git state. Do not embed credentials in repository remotes, submodule URLs, or configured upstream URLs. Public research and public issue reading can occur without a token. Narrow host-side issue commands are available from the installed publisher, for example:

```sh
~/.local/libexec/commitment/publish.sh issue-list commitment
~/.local/libexec/commitment/publish.sh issue-create lab "Title" /path/to/body.txt
~/.local/libexec/commitment/publish.sh issue-comment lab 12 /path/to/body.txt
~/.local/libexec/commitment/publish.sh issue-close lab 12
```

## Update or reinstall

Review source changes, then explicitly rebuild and reinstall:

```sh
cd /path/to/commitment
git pull --ff-only
./install.sh
```

This is the only path by which agent-authored launcher, image, publisher, prompt, or unit changes become trusted host machinery.

## Uninstall

```sh
./uninstall.sh
```

This disables/stops the timer and service and removes installed units and launcher. It preserves both repositories, generated software, configuration, credentials, OpenCode state, and Podman images/storage.

## Persistent data

- repositories: configured `COMMITMENT_REPO` and `LAB_REPO`
- operator config/tokens: `${XDG_CONFIG_HOME:-$HOME/.config}/commitment/`
- trusted Git mirrors, OpenCode sessions/state, and run lock: `${XDG_DATA_HOME:-$HOME/.local/share}/commitment/`
- installed trusted runtime: `$HOME/.local/libexec/commitment/`

## Tests

```sh
./tests/test.sh
./tests/runlog.sh
./tests/memory-queue-noop.sh
./tests/inbox.sh
./tests/session-regressions.sh
./tests/requests.sh
python3 -IB tests/test_secrets.py
./tests/git-boundary.sh
./tests/integration.sh
```

The Git-boundary suite uses hostile disposable repository hooks/config and local remotes. The integration suite builds the real image and checks its toolchain, OpenCode binary, containment, persistence, and boundary behavior. If the configured Ollama endpoint and model are reachable, opt into the short real model exercise:

```sh
COMMITMENT_REAL_OLLAMA=1 ./tests/ollama-smoke.sh
```

## Known limitations

- Commitment does not automatically relay issue mutations from the creative container; the narrow host commands are the boundary for future orchestration.
- Network egress is unrestricted, and ordinary rootless container networking may reach other host/LAN services.
- OpenCode web search depends on its documented hosted Exa MCP service; direct feed/page fetching remains available if that service is unavailable.
- When explicitly enabled, native `--continue` resumes the most recent persisted OpenCode session, not a custom selected project thread.
- Host resource limits are fixed in the small launcher except for session duration.
- Token-backed GitHub publishing and model quality require real operator services and cannot be proven by credential-free tests.

## External resources and Commitment-owned secrets

Resources are open-ended: software and hardware constraints, platform information,
local/specialized models, external models/chatbots/APIs, data, hardware, additional
repositories/infrastructure, email, and public distribution may justify action.
Acquire legitimate free resources within granted capabilities; request missing
payment authority, identity/verification, physical action, information, or
permissions. Attention and reputation are legitimate leverage toward usefulness,
not an engagement objective. [AGENTS.md](AGENTS.md) defines the operational rules.

Optional Bitwarden Secrets Manager storage uses a dedicated host broker and one
Commitment-owned project. `commitment-secret` exposes availability, metadata,
existence, trusted generation/rotation, and single-secret deletion; no plaintext
retrieval or generic ingestion. The host machine token never enters the creative
container, and operator-owned credentials remain separate. No Git repository,
including a private one, is a secret store. Account creation also needs a safe
credential consumer, which this pass does not implement. See
[requests/README.md](requests/README.md#operator-setup-commitment-owned-secrets) for
installation, exact interface, and lifecycle. The host broker uses the official
Python SDK in process; generated values never enter child-process arguments.
Creative and Git-helper containers disable automatic host proxy forwarding with
`--http-proxy=false`; trusted host networking retains operator proxy settings.
