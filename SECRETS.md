# Commitment-owned secrets

## Operator setup: Commitment-owned Secrets Manager

Use the **Bitwarden Secrets Manager** machine account/project dedicated only to
Commitment-owned resources, with read/write access only to that project. Do not
use the personal Bitwarden Password Manager vault. Operator-owned GitHub PATs,
personal/API/infrastructure credentials, and the machine-account token remain
trusted host state. A private Git repository is not a secret store.

Install host Python 3.9+ with `venv` and `ensurepip` support. The trusted broker
uses the [official Python SDK](https://bitwarden.com/help/secrets-manager-sdk/),
verified against the published `bitwarden-sdk==2.1.0` wheel and its Python API.
[Bitwarden SDK/releases](https://github.com/bitwarden/sdk/releases) is the release
entry point; GitHub may redirect repository aliases. No `bws` executable is used.

After enabling the settings below, explicitly rerun `./install.sh`. It installs
the versions in `requirements-secrets.txt` (SDK, python-dateutil, six) using pip
inside `$HOME/.local/libexec/commitment/secrets-venv`, with private permissions.
Only binary wheels are accepted; Linux wheels require compatible glibc on x86_64
or aarch64. There is no system/global pip installation, broad packaging tool,
runtime auto-install, or creative-container SDK dependency. The launcher uses
this venv's absolute Python path with `-IB`, including under minimal systemd PATH.
Installation checks importability without authentication. Unsupported platforms,
missing SDK/token, wrong permissions, or service failures disable secret operations
with fixed non-secret errors; ordinary repository work can continue. Host proxy settings remain available to trusted SDK networking.

Set in the trusted host `config.env`:

```sh
BITWARDEN_SECRETS_ENABLED=true
BITWARDEN_SECRETS_TOKEN_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/commitment/bitwarden-secrets-token
BITWARDEN_PROJECT_ID=<Commitment-project-UUID>
```

The existing token file must be owned by the runtime user, readable only by that
user (typically mode 600), regular, not a symlink or hard link, and outside all
creative mounts. Never copy it into this repository. The project identifier is
the project UUID, not an organization ID or project name. The broker derives the
organization UUID from that exact project's authenticated SDK response; the
client cannot supply either identifier or alternate service endpoints.
Existing installations preserve configuration; add these settings explicitly.
Rerun `./install.sh` yourself to adopt the reviewed trusted helpers. Repository
edits cannot change the installed broker. No timer change is needed for this
capability. Secret backend or SDK unavailability does not block unrelated work.
Uninstall removes the helpers, preserving configuration/credentials
and Bitwarden data; it never deletes stored secrets. Uninstall also preserves the
optional SDK venv for explicit operator removal or reuse.

The launcher starts one small host Python broker per enabled session. Its two
named pipes (FIFOs) and client lock live in a fresh mode-700 `secrets-session.*`
directory within dedicated Commitment runtime state; all three entries are mode
600 and owned by the runtime UID. Only this IPC directory is mounted read-only
into the creative container, alongside a read-only client command. Rootless
container root maps to the host user; filesystem permissions exclude other UIDs.
Trusted host processes with the same UID are not isolated from one another.
FIFOs avoid the host Unix-socket `connectto` restriction without weakening
SELinux labels or container security. No Podman socket, host PID namespace, host
networking, arbitrary host command execution, or arbitrary file reads are exposed.
The client lock serializes normal callers, and request IDs reject late responses
from an abandoned call. All creative processes share the same authority; a
malicious caller can interfere with availability, but cannot retrieve values.

The broker reads the token file into host memory and authenticates in process via
`client.auth().login_access_token(token, None)`. `None` disables persistent SDK
authentication state. Token contents are never environment variables, argv, or
IPC data. The token file, SDK venv, project configuration, and broker itself are
never mounted. The creative container never receives `BWS_ACCESS_TOKEN`, and all
agent-facing Podman runs disable automatic proxy forwarding. The session trap stops
the broker and removes the pipes/lock; normal/terminal outcome, timeout, launch
failure, and termination use the same cleanup. If the launcher is killed without
traps, the broker checks parent loss between requests. The launcher allows three
seconds for graceful broker termination, then kills a stuck native SDK call.
If both processes disappear during an untrappable failure,
residue may remain. A later startup takes the existing shared run lock before cleanup,
so live launchers/brokers (which inherit that lock) are protected. Cleanup accepts
only owner-owned mode-700 directories under the dedicated runtime root, with the
expected mode-600 FIFOs/lock; it rejects symlinks and unexpected contents/types.
Empty legacy `bws-*` directories are also removed. Nonempty legacy homes or other
unrecognized residue are preserved for operator inspection. No recursive deletion
or remote operation occurs. There is no SDK temporary HOME or state file.

All Bitwarden operations now use the SDK in process. `secrets().list(org)` returns
identifiers; every entry must name exactly the configured project and derived
organization. `secrets().get(id)` revalidates scope before rotate/delete and
preserves notes on rotation; no retrieved value leaves trusted memory.
`secrets().create(org, name, value, None, [project])` and
`secrets().update(org, id, name, value, note, [project])` return objects whose
scope/name/reference are checked. `secrets().delete([id])` must confirm exactly
that ID without an object-level error. There is no child process or CLI fallback.
Generated values stay in broker/SDK memory and remote Bitwarden storage only.
Python and native stdout/stderr go directly to `/dev/null` before SDK import;
exceptions become fixed IPC errors and core dumps are disabled. No unbounded
subprocess output capture remains. Only validated names/UUID references cross
IPC, never notes, values, raw SDK objects, or exception text.

## Creative command

Invoke through OpenCode's **bash** tool, like the log/outcome commands:

```sh
commitment-secret available
commitment-secret list
commitment-secret exists NAME
commitment-secret generate NAME --length 48
commitment-secret rotate NAME --length 48
commitment-secret delete NAME
```

Names start with an ASCII letter and contain at most 80 letters, digits, dots,
underscores, or hyphens. Values are cryptographically generated alphanumeric
strings, 32–128 characters (48 by default), entirely inside trusted machinery.
`generate` never overwrites. `rotate` requires one existing name and preserves its
reference. `delete` permanently removes exactly one matching secret. Missing or
duplicate names cannot trigger bulk changes. The client cannot supply a project,
token path, server URL, executable, or raw ID to mutate. All operations check
project scope; the machine account must also be restricted to this project by
Bitwarden, including against concurrent operator moves to other projects.

Success prints JSON containing `ok` plus availability, names/references, or
existence/deletion status. `available` verifies a read operation but cannot prove
write permission without a write; generation will fail clearly if permission is
missing. `exists` returns exit 1 for absence, 0 for existence. All errors exit
nonzero without printing backend output. `list` and `exists` never reveal values.
There is no `get`, `reveal`, `put`, `run`, signup, or authentication operation.
After an uncertain write failure/timeout, inspect references with `exists`/`list`
before retrying; a remote write may have succeeded. Rotation changes Bitwarden
only, not a provider account password. Do not rotate/delete in-use credentials
without coordinating the consumer.

Store references only, such as `secret_ref: bitwarden:<opaque-id>`. Before creating
an account needing reusable credentials, verify backend availability, generate
through trusted machinery, retain the reference, and verify a safe credential
consumer for signup and later authentication. **This pass has no such consumer.**
Request that missing capability instead of creating an account you cannot safely
authenticate to or persist a provider-issued token for. Never echo a value, place
it in public shell argv, or use Git/logs/transcripts as temporary storage.

Tests use only an offline fake SDK and disposable state. Fake persisted records
contain metadata and value hashes, never generated plaintext. No live smoke test is run by
default; this implementation supplies no automated live smoke test. An operator
may explicitly opt into a later live check, but ordinary tests require neither a
Bitwarden account nor service access.

`python3 -IB tests/test_secrets.py` covers IPC, scope, plaintext suppression,
process argv, and stale cleanup. `tests/proxy-environment.sh` uses real rootless
Podman with a short environment probe instead of a model session; set
`COMMITMENT_TEST_IMAGE` to an existing image. Optional packaging checks use
`python3 -IB tests/secrets-install.py /path/to/local/wheelhouse` (all three pinned
wheels) or the SDK interpreter with `-IB tests/sdk-contract.py`. These validate
the actual wheel offline with its native network client replaced, without
authenticating. Installation checks use disposable configuration and mock
systemd/Podman commands; they do not change the operator's schedule.
