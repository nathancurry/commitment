# Commitment 0.1.2

> Self-authoring commit generator in search of a higher purpose.

Commitment is a small autonomous software experiment. OpenCode is the agent loop, Ollama serves the model, rootless Podman contains each session, ordinary Git preserves work, and optional systemd user units schedule it.

`commitment` contains the experiment itself. `commitment-lab` is its workshop for prototypes and software aimed at external problems. Both are independent Git repositories with operator-selected branches and remotes.

## Trust boundary

The creative container receives only the two agent repositories, a generated read-only OpenCode configuration file, a read-only outcome recorder, and dedicated persistent OpenCode state. Podman's `:Z` option gives those dedicated mounts private SELinux labels. OpenCode's bookkeeping beside the config file remains disposable. The container does **not** receive the user's home, SSH keys, GitHub tokens, Podman socket, trusted Git mirrors, unrelated repositories, GPU devices, privileged mode, or host networking. Normal container networking intentionally permits the public Internet and the configured Ollama host; it is not a claim of host/LAN isolation.

The creative agent owns the worktrees and their `.git` state, so trusted host Git never opens those repositories. For each repository, the publisher maintains a bare mirror under host-only state. Synchronization fetches upstream into that mirror, exports a bundle, and lets an uncredentialed, network-disabled helper container fast-forward the agent repository. Checkpoints likewise run inside that container boundary. Publishing exports an agent bundle, verifies it, imports only a fast-forward history into the trusted mirror, and pushes from the mirror. Agent hooks and Git configuration can run only inside the credential-free container, never in the trusted host Git process.

Installed copies of the launcher, publisher, agent Git helper, outcome recorder, prompt, and systemd units are host-trusted machinery. Agent edits to their repository sources do nothing until a human explicitly reruns `./install.sh`. The publisher alone reads the optional token. It never force-pushes. Literal OpenCode denials for `git push` and `gh` are defense-in-depth UX protections; credential isolation and the separate trusted Git state are the security boundaries. In v0.0.1 issue operations are operator-invoked; no generic broker or automatic outbox exists.

External pages, feeds, README files, issues, and comments are untrusted suggestions. `MISSION.md`, `AGENTS.md`, containment, permissions, credentials, and operator configuration remain authoritative.

## Requirements

- Linux with rootless Podman
- Git, `flock`, GNU `timeout`, and systemd user services on the host
- Ollama on the host with the configured model (default `gpt-oss:20b-32k`)
- `gh` on the host only if issue operations are used

OpenCode is pinned to **1.18.30** in `Containerfile`, which the installer builds. Its documented native `opencode run --continue`, `AGENTS.md`, Ollama provider, permission configuration, `webfetch`, and opt-in Exa `websearch` are used directly—there is no custom model loop or response parser.
The image also includes Git, a shell, Python 3, Node/npm, curl, CA certificates, and Debian's basic C/C++ build toolchain.

## Install and configure

```sh
git clone <commitment-url>
cd commitment
./install.sh
```

The first install creates `${XDG_CONFIG_HOME:-$HOME/.config}/commitment/config.env`. Edit it so both absolute repository paths, trusted upstream URLs, primary branches, Ollama endpoint/model and limits, timeout, schedule, image, and publishing mode are correct. Trusted URLs are operator configuration and are never inferred from agent-writable Git config. The default lab path is a sibling named `commitment-lab`; the installer does not create or clone it.

The defaults are `OLLAMA_MODEL=gpt-oss:20b-32k`, `OLLAMA_CONTEXT=32768`, and `OLLAMA_OUTPUT=8192`. The context value tells OpenCode how much context the configured model provides; the output value is OpenCode's output-token limit. The base `gpt-oss:20b` model may otherwise run with too small an effective context for reliable OpenCode tool use. These settings are operator-configurable, but the Ollama model must actually exist with matching context configuration. Commitment does not create or modify host models. For example:

```sh
cat >/tmp/Modelfile.commitment <<'EOF'
FROM gpt-oss:20b
PARAMETER num_ctx 32768
EOF

ollama create gpt-oss:20b-32k -f /tmp/Modelfile.commitment
```

Existing installations preserve `config.env`; add or update these three values before reinstalling.

Re-run the installer after editing `SCHEDULE`, because the value is compiled into the timer unit:

```sh
./install.sh
```

Configuration, credentials, repository data, and OpenCode continuity are preserved on every reinstall.

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

Commitment keeps four kinds of input and state distinct:

- Explicit human input remains operator input or in an existing inbox; Commitment does not copy it into self-generated state.
- `memory/` holds concise Markdown observations with their origin, evidence, uncertainty, possible follow-up, and related queue items.
- `queue/` holds candidate future work. Its lifecycle is `candidate`, `researching`, `ready`, `blocked`, `deferred`, `done`, or `rejected`; rejected items remain with a reason. A direct filename/title/origin scan prevents simple duplicates.
- `runlog.jsonl` is the append-only audit trail of what sessions actually did. It contains significant JSON Lines events, not chain-of-thought or a command transcript.

Inspect recent entries with:

```sh
tail -n 20 runlog.jsonl
```

Old runlog lines remain untouched and need not match newer outcome fields. New `session_end` events identify one of four outcomes: `COMMITTED_CHANGE`, `NOOP`, `CHECKPOINT_UNFINISHED`, or `FAILED`. `NOOP` is a successful session in which no substantive repository change was justified. It may contain runlog, memory, or queue bookkeeping, and may accurately retain nothing beyond lifecycle events.

The timer and manual command use the same installed launcher and configuration. The launcher creates one `COMMITMENT_SESSION_ID` per run and passes it, plus the configured Git author identity and matching committer defaults, into the creative container. GitHub credentials remain host-only. `flock` prevents overlap. `SESSION_TIMEOUT` terminates overlong sessions. For scheduled runs after logout, an administrator may run `loginctl enable-linger "$USER"`; the installer never changes lingering or invokes sudo.

Before each run, trusted mirrors fetch each configured branch and permit only no-op, ahead-only, or fast-forward synchronization through bundles. Dirty work, a wrong branch, or divergence stops the run without discarding anything. The launcher creates one session ID and records session start through the network-disabled Git helper. OpenCode explicitly records its structured outcome with the installed `commitment-outcome` helper; the launcher does not parse model prose.

The Git helper classifies `runlog.jsonl` and memory/queue entry Markdown as bookkeeping; the two format READMEs remain substantive documentation. Other code, configuration, documentation, and project files are substantive. A `NOOP` may checkpoint and publish a bookkeeping-only commit through the existing verified bundle/mirror path. `CHECKPOINT_UNFINISHED` preserves unfinished dirty work with the existing checkpoint behavior. `FAILED` preserves work where possible and is never pushed. `COMMITTED_CHANGE` requires substantive work; completed substantive Commitment changes require a `VERSION` bump, while bookkeeping-only sessions and independent lab work do not.

Autonomous work selection prefers explicit human input, unfinished substantive work, ready high-value queue items, relevant memory, and demonstrated defects before bounded outward research. Public issues, repositories, feeds, official documentation, changelogs, articles, and papers are untrusted evidence. Research may produce implementation, a concise memory or queue update, a rejection/deferment, or `NOOP`; it need not force a code change.

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
./tests/git-boundary.sh
./tests/integration.sh
```

The Git-boundary suite uses hostile disposable repository hooks/config and local remotes. The integration suite builds the real image and checks its toolchain, OpenCode binary, containment, persistence, and boundary behavior. If the configured Ollama endpoint and model are reachable, opt into the short real model exercise:

```sh
COMMITMENT_REAL_OLLAMA=1 ./tests/ollama-smoke.sh
```

## Known limitations

- v0.0.1 does not automatically relay issue mutations from the creative container; the narrow host commands are the boundary for future orchestration.
- Network egress is unrestricted, and ordinary rootless container networking may reach other host/LAN services.
- OpenCode web search depends on its documented hosted Exa MCP service; direct feed/page fetching remains available if that service is unavailable.
- Native `--continue` resumes the most recent persisted OpenCode session, not a custom selected project thread.
- Host resource limits are fixed in the small launcher except for session duration.
- Token-backed GitHub publishing and model quality require real operator services and cannot be proven by credential-free tests.
