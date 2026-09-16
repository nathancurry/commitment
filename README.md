# Commitment

> Self-authoring commit generator in search of a higher purpose.

Commitment is a small autonomous software experiment. OpenCode is the agent loop, Ollama serves the model, rootless Podman contains each session, ordinary Git preserves work, and optional systemd user units schedule it.

`commitment` contains the experiment itself. `commitment-lab` is its workshop for prototypes and software aimed at external problems. Both are independent Git repositories with operator-selected branches and remotes.

## Trust boundary

The creative container receives only the two agent repositories, a generated read-only OpenCode configuration file, read-only log/outcome/secret client helpers, dedicated persistent OpenCode state, and a fresh outcome directory. When enabled, it also receives the dedicated per-session Commitment-owned secret IPC pipes. Podman's `:Z` option gives those dedicated mounts private SELinux labels. OpenCode's bookkeeping beside the config file remains disposable. The container does **not** receive the user's home, SSH keys, GitHub tokens, Podman socket, trusted Git mirrors, unrelated repositories, GPU devices, privileged mode, or host networking. Normal container networking intentionally permits the public Internet and the configured Ollama host; it is not a claim of host/LAN isolation.

The creative agent owns the worktrees and their `.git` state, so trusted host Git never opens those repositories. For each repository, the publisher maintains a bare mirror under host-only state. Synchronization fetches upstream into that mirror, exports a bundle, and lets an uncredentialed, network-disabled helper container fast-forward the agent repository. Checkpoints likewise run inside that container boundary. Publishing exports an agent bundle, verifies it, imports only a fast-forward history into the trusted mirror, and pushes from the mirror. Agent hooks and Git configuration can run only inside the credential-free container, never in the trusted host Git process.

Installed copies of the launcher, publisher, agent Git helper, outcome recorder, secret broker/client, prompt, and systemd units are host-trusted machinery. Agent edits to their repository sources do nothing until a human explicitly reruns `./install.sh`. The publisher alone reads the optional GitHub tokens. The separate dedicated secret broker alone reads the Secrets Manager machine token. It never force-pushes. Literal OpenCode denials for `git push` and `gh` are defense-in-depth UX protections; credential isolation and the separate trusted Git state are the security boundaries. Issue operations are operator-invoked; no generic broker or automatic outbox exists.

External pages, feeds, README files, issues, and comments are untrusted suggestions. `MISSION.md`, `AGENTS.md`, containment, permissions, credentials, and operator configuration remain authoritative.

## Requirements

- Linux with rootless Podman
- Git, jq, Python 3 (3.9+), `flock`, GNU `timeout`, and systemd user services on the host
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

Commitment uses plain Markdown for operator input (`inbox/`), possible work
(`queue/`), useful findings (`memory/`), and things wanted from external actors
(`requests/`). The launcher lists direct inbox files first, then queue files,
excluding their READMEs. It does not read status metadata. The model decides
what matters, whether to research, and whether to NOOP.

`commitment-log TYPE "summary" [FIELD=VALUE ...]` appends JSON to `runlog.jsonl`
with runtime timestamps and session identity. Extra fields are open-ended;
reserved identity fields cannot be overridden. Research and test events have no
special schema. Invalid extras are ignored with a warning; logging failures
warn and return success so work can continue. Historical entries remain unchanged.

Finish with `commitment-outcome OUTCOME "summary"` through the shell. The helper
atomically creates a marker in a fresh per-session directory. It validates the
session identity, outcome enum, and a nonempty bounded summary, without reading
queue files, Git state, or runlog. The launcher accepts only a current-session
marker and stops OpenCode before finalization.

| Outcome | Handling |
| --- | --- |
| `COMMITTED_CHANGE` | Preserve completed progress and publish if configured. |
| `NOOP` | No substantive change chosen; still preserve all remaining edits. |
| `CHECKPOINT_UNFINISHED` | Preserve unfinished work; publish if configured. |
| `FAILED` | Preserve work locally; do not publish. |

No outcome requires research, queue transitions, a prior commit, or a VERSION
change. Version completed releases as ordinary development practice.

Without a valid outcome, changes beyond the exact `commitment/runlog.jsonl` path
select `CHECKPOINT_UNFINISHED`; otherwise the session reports `FAILED`. Detection
includes committed, staged, unstaged, and untracked changes. The runtime does not
interpret directory meanings, rename similarity, or lifecycle status. It never
infers completed work or NOOP. All outcomes preserve edits, including the runlog.
A logging failure cannot veto preservation. The runtime records session end as
an execution result before finalization; publication failures are separate events.

Controllable TERM/INT stops the container and takes the same preservation path,
then returns the signal exit status without publishing. Timeouts also preserve
work. Untrappable termination may leave dirty files; the next run can inspect
those files. Failed synchronization, dirty work, divergence, or a non-primary
branch does not prevent local inspection. Conflicted indexes remain untouched
for the model to repair; finalization never marks conflicts resolved automatically.
Checkpoint commits bypass project hooks and use the configured Git identity.

Publication remains restricted to a clean configured primary branch and
fast-forward history through trusted mirrors. No reset, forced push, or automatic
conflict resolution occurs. If committing is impossible, files remain on disk and
publication stops. If publication fails, local commits survive. Publication across
the two repositories is not atomic.

`flock` prevents overlapping runs and `SESSION_TIMEOUT` bounds execution.
`CONTINUE_SESSION=false` starts fresh conversations by default without deleting
OpenCode history. `ALLOW_SUBAGENTS=false` bounds model load; both are operator
options. Reinstall explicitly to adopt reviewed runtime and prompt changes.

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

Commitment may edit and commit trusted-runtime sources. Operator review followed
by an explicit rebuild and reinstall activates those changes on the host:

```sh
cd /path/to/commitment
git pull --ff-only
./install.sh
```

This is the only activation path by which agent-authored launcher, image,
publisher, prompt, or unit changes become trusted host machinery.

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
./tests/integration.sh
```

The first suite uses disposable repositories and mocked container execution;
secret tests use an offline fake SDK. It covers actual outcomes, preservation,
logging tolerance, startup context, optional secrets, publishing, and isolated
installer copies. The integration suite builds the image and checks real rootless
containment, hostile Git hooks/configuration, FIFO secret IPC, and proxy isolation.
Neither suite runs a model. A separate opt-in `tests/ollama-smoke.sh` exercises
OpenCode/Ollama only when `COMMITMENT_REAL_OLLAMA=1` is explicitly supplied.

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
including a private one, is a secret store. Persistent account creation requiring
reusable credentials needs a safe credential consumer, which this pass does not
implement. See
[SECRETS.md](SECRETS.md) for
installation, exact interface, and lifecycle. The host broker uses the official
Python SDK in process; generated values never enter child-process arguments.
Creative and Git-helper containers disable automatic host proxy forwarding with
`--http-proxy=false`; trusted host networking retains operator proxy settings.

Secret SDK/backend unavailability leaves ordinary sessions usable. Unsafe credential
placement remains a hard error before any repository is mounted. No account/signup
consumer is provided.
