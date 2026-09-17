# Commitment

Commitment is an autonomous software experiment whose purpose is to make itself
more useful.

It uses OpenCode as the agent loop, local Ollama models for execution, rootless
Podman for containment, Git for durable state and recovery, and optional external
planning/reasoning capabilities.

`commitment` contains the agent and trusted runtime. `commitment-lab` is its
workspace for experiments, prototypes, and external software.

## Install

Requirements:

- Linux
- rootless Podman
- Git
- Python 3
- systemd user services
- Ollama with the configured model available

Clone the repository and install:

```sh
git clone <commitment-url>
cd commitment
./install.sh
````

The installer creates and preserves:

```text
~/.config/commitment/config.env
```

Review that file and configure repository paths, upstream URLs, Ollama settings,
publishing, schedule, and any optional capabilities.

If configured, `commitment-plan` gives the creative container a text-only,
stateless planning/prospecting call to a host-authenticated OpenRouter model. The
API key stays in the owner-only host file named by `OPENROUTER_API_KEY_FILE`.

Run manually:

```sh
~/.local/bin/commitment
```

Enable scheduled autonomous runs:

```sh
systemctl --user enable --now commitment.timer
```

View logs:

```sh
journalctl --user -u commitment.service
```

After changing trusted runtime sources, reinstall to activate them:

```sh
./install.sh
```
