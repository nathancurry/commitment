# Architecture Review — Commitment

Reviewed revision: `53757d7` (`VERSION` = `0.5.0`), 2026-09-26.
Line references are to files at that revision. "Reproduced" means the behaviour
was demonstrated in this review environment. Each reproduction is described in
§6. Anything else is from reading the code and is marked as such where it
matters.

## 1. Architecture

Commitment is an autonomous agent that is allowed to change itself. It runs as a
scheduled, sandboxed OpenCode session whose working material is its own Git
repository.

| Layer | Components | Where it runs |
|---|---|---|
| Scheduling | `systemd/commitment.service.in:6-9` (oneshot `ExecStart=%h/.local/bin/commitment`), timer rendered by `install.sh:90-96` | host |
| Trusted launcher | `run.sh` (installed copy in `~/.local/libexec/commitment`, `install.sh:75-88`) | host |
| Trusted Git/publication | `publish.sh` (host side, trusted bare mirror at `$STATE_DIR/trusted/*.git`, `publish.sh:40,106-137`) and `agent-git.sh` (runs in a `--network=none` container against the agent repo, `publish.sh:139-164`) | host + helper container |
| Brokers | `secret-broker.py`, `planner-broker.py` start on the host (`run.sh:257-311`) and the container reaches them only through request/response directories mounted `ro` | host |
| Creative session | `podman run … opencode run` (`run.sh:314-341`), with both repos mounted `rw`, a `rw` outcome directory, and helper scripts mounted `ro` | container |
| Agent instructions | `MISSION.md`, `AGENTS.md`, `.opencode/agents/commitment.md`, `CURRENT.md`, plus the prompt assembled from `prompt.txt` and context helpers (`run.sh:166-180`) | read by the model |
| Durable state | `CURRENT.md`, `inbox/`, `queue/`, `memory/`, `requests/`, `runlog.jsonl` (`AGENTS.md:5-11`; `processed/` convention at `AGENTS.md:13`). A `work/` directory is also used (`work-protocol.md:10`) but is not in the `AGENTS.md:5-11` list | agent repo |

Session lifecycle in `run.sh`:

1. Load and validate config (`run.sh:20-50`). Clean up leftover broker state (`57-67`). Take a single-run `flock` (`68-69`). Check that credential files are outside every creative mount (`76-95`).
2. Fast-forward both working repos from the trusted mirror (`97-99`; `publish.sh:166-175`; `agent-git.sh:124-141`). Record base heads (`100-101`).
3. Write the OpenCode config. Everything is `allow` except `question`, optionally `task`, and the pattern denies for `git push`/`gh` (`118-161`).
4. Build the prompt: continuity, inbox, and queue context are prepended to `prompt.txt` (`163-180`).
5. Start the brokers (`257-311`) and run the container under `timeout` (`343-361`). Poll for a valid outcome marker every 0.5 s and stop the container when one appears (`350-359`).
6. Remove the container (`365`) and read the outcome. If there is no valid marker, classify the diffs and choose `CHECKPOINT_UNFINISHED` or `FAILED` (`371-395`).
7. Log `session_end` (`399`) and `finalize` (commit dirty work) in each repo (`400-409`). Only in `PUBLISH_MODE=push`, and only when the outcome is not `FAILED` or interrupted, import the agent history through a verified bundle and push (`411-428`; `publish.sh:181-218`).

## 2. Strengths

- **Named credential files are kept out of the main creative mounts by path checks.** The token environment variables are unset on the host (`run.sh:24,28`), and the container only receives the explicit `-e` variables at `run.sh:330-340`. Each credential file is then checked against a list of mount sources. The lists differ, and §3.3 gives the exact coverage and its limits. Brokers use the credentials on the host and only answer requests through IPC directories mounted `ro` (`run.sh:275,306`). The secret broker never returns secret values (`secret-broker.py:21,123`).
- **Publication goes through a trusted mirror, not the agent's `.git`.** The agent's history arrives as a bundle. The host verifies it (`publish.sh:190-191`), runs `fsck --strict` (`198`), confirms the head (`199`), and accepts only fast-forwards (`201-205`). Divergence is kept for inspection instead of being forced (`publish.sh:134-135`, `agent-git.sh:138-139`).
- **Git operations on agent-controlled repos run in a network-less, resource-limited container** (`publish.sh:146-147`). They reject credential-bearing remote, config, and submodule URLs (`agent-git.sh:11-25`).
- **The container is bounded:** `no-new-privileges`, pids/memory/CPU limits (`run.sh:316-319`), a wall-clock timeout with a KILL fallback (`run.sh:348`), and rootless Podman enforced at install (`install.sh:27`).
- **The outcome file is validated before it is trusted:** it must be a regular file (not a symlink), ≤64 KiB, contain exactly one JSON object with the matching session id, an enum outcome, and a bounded control-free summary (`session-outcome.sh:9-19`).
- **Changes to the trusted runtime need operator action.** `run.sh` executes installed copies from `RUNTIME_DIR` (`run.sh:11-18`), which change only when the operator runs `install.sh` (`install.sh:75-87`). §4.3 covers the exceptions.
- **The upstream test suite is substantive.** `tests/test_runtime.py` exercises `run.sh` end to end with a fake Podman and fixture repos, for example outcome handling and preservation (`tests/test_runtime.py:230-251`), timeout (`tests/test_runtime.py:258-261`), and rejecting a Bitwarden token path inside the repo (`tests/test_runtime.py:357-361`). `tests/test_runtime.py:74-88` covers marker validation only. In this environment the suite fails (§6 R5).

## 3. Safety guarantees — qualified to what `run.sh` actually enforces

### 3.1 Preservation commits are best-effort

`run.sh` tries to commit session work in both repos (`run.sh:400-406` → `agent-git.sh:115-123,65-91`). This is **not guaranteed**. `run.sh` can exit without making a preservation commit on these paths:

- **Container removal failure.** `podman rm -f … || die "cannot stop creative container; work remains on disk"` (`run.sh:365`) exits before any `finalize`. The work stays as uncommitted files.
- **Finalize failure.** If `publish.sh finalize` fails for a repo, `run.sh:402-409` records it and then `die`s ("preservation incomplete; nothing published"). The helper also refuses to commit when there are unmerged paths (`agent-git.sh:68-69`). Any failure of `podman run` in `publish.sh:146-163` (image missing, Podman error) leads to the same result.
- **`set -euo pipefail` aborts** (`run.sh:2`) anywhere between the session and `finalize`, for example in `touch` (`369`), `jq` (`373`), or `session-head` (`100-101`). The script then exits without committing.
- **Uncatchable termination.** `run.sh:364` ignores TERM/INT from that point on. Before that point, TERM/INT go to `stop_session` (`247-256`), which then falls through to the preservation path. SIGKILL (for example from systemd) runs no handler at all.
- **Ignored files are never committed.** `git add -A` (`agent-git.sh:88`) respects `.gitignore` (`config.env`, `.commitment/`, `*.log`, `*~`).

"Preserved" in `run.sh` messages therefore means one of two things. Either a local commit was made, or the files were left on disk untouched for manual inspection. Commits are local only; publication is a separate step that only runs in push mode (`run.sh:419-428`).

### 3.2 The outcome marker can be overwritten; `ln` only makes creation atomic

- The outcome directory is bind-mounted **read-write** into the container (`run.sh:325`). The session id that validation checks is passed into the container environment (`run.sh:334`). Any process in the container can therefore delete, replace, or directly write a valid marker, without using `commitment-outcome`.
- `session-outcome.sh:32-36` writes a temp file and `ln`s it into place. That makes **creating** the marker atomic: readers never see a partial file, and the helper will not replace an existing marker. It does nothing to prevent later `rm` + re-create or `mv -f` over the marker (reproduced, §6 R4).
- The host polls every 0.5 s (`run.sh:350-359`) and then gives `podman stop` 5 s. The marker can change between the first valid read and container removal. The value that decides the outcome is read after `podman rm -f` (`run.sh:372-373`), when no container process can write any more.
- `cleanup` deletes the marker on exit (`run.sh:242`). The only record left is the summary in the `session_end` runlog entry (`run.sh:399`).

The marker is therefore a self-report by the agent, checked for shape and session id. It is not an attestation. It controls the outcome label, whether a `FAILED` session skips publishing (`run.sh:415-418`), and early termination.

### 3.3 Credential isolation covers specific files and paths only

| Credential | Checked by | Paths it must be outside of | Not checked |
|---|---|---|---|
| Bitwarden machine token (`BITWARDEN_SECRETS_TOKEN_FILE`, default `$CONFIG_HOME/commitment/bitwarden-secrets-token`, `run.sh:78`) | `run.sh:79-85`, always; the secret broker again when secrets are enabled (`secret-broker.py:326-329`) | Five directories: `COMMITMENT_REPO`, `LAB_REPO`, `$STATE_DIR/opencode-config`, `$STATE_DIR/opencode-data`, `$STATE_DIR/outcomes` (`run.sh:80`). The broker receives the same five directories, except that it gets the per-session outcome directory instead of `$STATE_DIR/outcomes` (`run.sh:266-267`, `run.sh:231`) | The mounted single files `OUTCOME_HELPER`, `LOG_HELPER`, `commitment-secret.py`, and `commitment-plan.py` (`run.sh:258,286,313,324`). A token path that is one of those files is accepted (reproduced, §6 R6) |
| CheaperInference planner key (`CHEAPERINFERENCE_API_KEY_FILE`) | `run.sh:86-95`; the planner broker again (`planner-broker.py:71-80`, `run.sh:294-298`) | The same five directories plus the four helper files (`run.sh:87-90`) | — |
| GitHub tokens (`COMMITMENT_GITHUB_TOKEN_FILE`, `LAB_GITHUB_TOKEN_FILE`, `config.example.env:48-49`) | `publish.sh:46-65`, only when the file exists at check time (`publish.sh:48`) | The same five directories as Bitwarden (`publish.sh:53`), and the file must not be group/world accessible (`publish.sh:62-64`) | The four helper files |
| `BWS_ACCESS_TOKEN`, `OPENROUTER_API_KEY`, `CHEAPERINFERENCE_API_KEY` in the host environment | Unset at `run.sh:24,28` | — | — |

What is assumed rather than enforced:

- No check covers the per-session broker IPC directories (`run.sh:262,289`, both under `$STATE_DIR` and mounted `ro` at `run.sh:275,306`). A token is only safe there if the operator does not put one there.
- The checks resolve symlinks at check time (`readlink -m` at `run.sh:79,81`; `readlink -f` at `publish.sh:52,55`). Hard links to a token placed inside a mounted directory are not detected, and neither are changes made after the check.
- Any other host credential (for example SSH keys, cloud CLI config, or another service's token) is protected only because the operator did not place it under a mounted path. No code checks for it.
- The container has default network access plus `host.containers.internal` mapped to the host gateway (`run.sh:314-315`). Services on the host that trust local network clients without a credential are reachable.

So the accurate statement is: the four named credentials above are kept out of the listed mount sources by path checks, if the default layout and these assumptions hold. This review does not claim that no credential is present in the sandbox.

### 3.4 Other boundaries that are policy rather than enforcement

- The `git push`/`gh` denials (`run.sh:150-156`) are OpenCode permission patterns, not a sandbox, and the container has default network access (no `--network` in `run.sh:314-341`). What actually prevents unauthorised pushes is that the GitHub token files are used only by host-side `publish.sh` and are path-checked against the repo, OpenCode, and outcome directories (`publish.sh:46-65`). This holds only under the configuration assumptions in §3.3. It is not a guarantee that no credential of any kind is reachable from the container.
- `runlog.jsonl` is described as the "session audit history" (`AGENTS.md:11`), but it is an ordinary file in the agent-writable repo. The agent also appends to it (`commitment-log.sh:31`). It is not tamper-evident. The first record, `runlog.jsonl:1`, uses a hand-made session id (`autonomous-20260913T213000`) and is out of timestamp order with line 2.

## 4. Risks

### 4.1 Safety

- **S1 — The self-reported outcome decides whether work is published** (§3.2). Severity: medium. It is limited by fast-forward-only import (`publish.sh:201-205`) and by publication being off unless `PUBLISH_MODE=push`.
- **S2 — Best-effort preservation** (§3.1). Severity: low to medium. Work stays on disk, but an unattended timer run may leave it uncommitted with only a journal note.
- **S3 — Broad in-container authority.** Everything is allowed: bash, webfetch, websearch (`run.sh:143-156`), plus network access and write access to both repos. This is intended by `MISSION.md:13-33`. It means that prompt-injected web content can modify the agent's own instructions and the trusted-runtime sources (activation of the latter is gated; see 4.3).
- **S4 — Credential path checks are narrower than they look** (§3.3). Severity: low. The Bitwarden and GitHub checks skip the mounted helper files (`run.sh:80`, `publish.sh:53`), and no check covers the broker IPC directories or credentials other than the four named in §3.3. Exploiting this needs an unusual operator configuration.

### 4.2 Determinism and correctness

Each of these was confirmed by reproduction or by the repo's own tests (§6):

- **D1 — The resource tracker never starts.** `run.sh:345` runs `export COMMITMENT_SESSION_ID=… "$RUNTIME_DIR/track-resources.sh" && …`. `export` rejects the path as an identifier and returns non-zero, so the script is never run and `resource_tracker_pid` stays empty (R1). Separately, `install.sh:75-87` never installs `track-resources.sh`, so the `-f` test fails on a real install anyway. The reader side also cannot match: `inbox-context.sh:102` looks for `/tmp/commitment-resources-$$` using the *reader's* PID inside the container, while `track-resources.sh:5` writes to the host `/tmp` using the tracker's PID.
- **D2 — The EXIT trap can abort under `set -u`.** `cleanup` (`run.sh:234-244`, trap set at `245`) reads `$resource_tracker_pid`, which is not assigned until `run.sh:344`. If the script exits between lines 245 and 344, the trap fails with "unbound variable" and skips removing the outcome directory (R2). Broker cleanup runs before that line, so it is unaffected.
- **D3 — Reinstalling from HEAD would break every run.** `run.sh:163-164` `die`s unless `session-continuity.sh` is executable in `RUNTIME_DIR`, but `install.sh:75-87` does not install it. This is from reading the code; the installed host copy was not observed.
- **D4 — Operator inbox context was lost.** At `b3a86e0` (v0.4.0), `inbox-context.sh` was an executable script that printed `Operator inbox file:` lines. At HEAD it is a mode-`0644` library of shell functions with no main body (`inbox-context.sh:1-138`, mode change in `3d0a8c9`). `run.sh:52` now `die`s when the file is not executable (R5). After `install -m 0755` it would print nothing, so operator inbox items would disappear from the prompt (`run.sh:173-176`).
- **D5 — `>>2` writes to a file named `2`.** `session-outcome.sh:39` and `track-resources.sh:26-27` use `>>2` where `>&2` was probably meant. The committed file `2` at the repo root (`2:1-2`, added in `18389ee`) shows the same mistake. Its text, `Generating morning report...`, does not appear in the current code, so it was probably written by an earlier version of this redirect. `session-outcome.sh:39` also calls `/workspace/commitment/generate-morning-report.sh` by absolute path (R3).
- **D6 — `AGENT_SUMMARY` is not passed to `finalize`.** `run.sh:402` passes only exit status and outcome, so `agent-git.sh:77-85` never adds the work description to commit messages. Recent history (`checkpoint: … after session exit N`) matches this.
- **D7 — Most sessions end without a valid outcome.** Across the 88 `session_end` records in `runlog.jsonl:1-203` (counted with a Python script over every line): 47 `CHECKPOINT_UNFINISHED`, 17 `FAILED`, 18 `NOOP`, 6 `COMMITTED_CHANGE`. Of these, 46 have the summary "No valid outcome; changed work preserved as unfinished" (the text written by `run.sh:386-388`). Five sessions ended with exit 137 (`runlog.jsonl:157,171,173,197,199`).
  - *Evidence:* 137 is 128 + SIGKILL. The runlog records only the status, not what sent the signal.
  - *Inference, not proven:* these were probably session timeouts. `timeout --kill-after=30` sends KILL 30 s after TERM (`run.sh:348`). Each of the five sessions lasted exactly 2:00:43 from the start time in its session id (format from `run.sh:70`) to its `ts`, which fits the example `SESSION_TIMEOUT=7200` (`config.example.env:17`) plus the 30 s kill delay. The host's actual `SESSION_TIMEOUT` was not observed. The exit status alone could also come from the 8 GiB memory limit (`run.sh:318`) or from an external kill.

### 4.3 Self-modification loops

- **L1 — The agent rewrites trusted-runtime sources.** Commit `3d0a8c9` changed `run.sh`, `session-outcome.sh`, and `inbox-context.sh`, which introduced D1–D5. The install gate (`AGENTS.md:27-30`; `install.sh:75-87`) is the only control. The operator is asked to reinstall "when activation would materially improve usefulness" (`AGENTS.md:32-33`). If they do so without review, these regressions become active.
- **L2 — The install gate can be bypassed.** Once the current `session-outcome.sh` is installed, line 39 runs an agent-writable script (`/workspace/commitment/generate-morning-report.sh`, which sources `/workspace/commitment/inbox-context.sh`, `generate-morning-report.sh:6,16`) every time an outcome is recorded. This runs inside the container, where the agent can already execute code, so it is not a privilege escalation. It does mean that part of an installed helper's behaviour changes without reinstall. The `--read` path the host uses exits at `session-outcome.sh:19`, before line 39.
- **L3 — Instructions and prompt context are live without reinstall.** `.opencode/agents/commitment.md`, `AGENTS.md`, `MISSION.md`, and `CURRENT.md` are read from the agent-writable repo. `queue-context.sh:13-16` and `session-continuity.sh:8-12` put the contents of the agent-editable `inbox/agenda.md` into the next session's prompt. Text written by one session therefore becomes instructions for the next.
- **L4 — Self-assessment drifts from reality.** `CURRENT.md:1-5,26-31` says "ALL FEATURES COMPLETE" and "all automated tests passing". The "tests" behind that claim only check that files exist or contain certain strings (`test-resource-tracking.sh:9-40`). The repo's real suite fails (R5). Because `CURRENT.md` is the main handoff between sessions (`.opencode/agents/commitment.md:12-18`), the false status carries forward.

## 5. Prioritized recommendations

1. **Gate reinstall on the real suite (addresses L1, D3, D4).** Before any reinstall request, run `tests/test.sh` (which runs `tests/test_runtime.py`). Have `install.sh` refuse to proceed if it fails. Fix or revert the `3d0a8c9` runtime changes: restore `inbox-context.sh` from `b3a86e0`, add `session-continuity.sh` to `install.sh:75-87` or drop the requirement at `run.sh:163-164`, and fix `run.sh:345`.
2. **Make the outcome host-attested, or say clearly that it is advisory (S1).** One option is to mount the outcome directory `ro` and have the helper write through a broker, like the secret and planner brokers (`run.sh:257-311`). Another is to document that only the post-removal read (`run.sh:372`) counts. At minimum, keep the marker or its hash in the host journal instead of deleting it (`run.sh:242`).
3. **Report preservation outcomes accurately (S2).** Emit a distinct, greppable status for "no commit made" on the `run.sh:365` and `run.sh:407-409` paths. Consider a host-side `checkpoint` retry after a failed container removal, once removal succeeds.
4. **Fix the trap and redirection bugs (D2, D5, D6).** Initialise `resource_tracker_pid=''` before `trap cleanup EXIT`. Replace `>>2` with `>&2` and delete the stray `2` file. Pass `AGENT_SUMMARY` to `finalize`.
5. **Remove agent-writable code paths from installed helpers (L2).** Installed helpers should not call into `/workspace/commitment/*`.
6. **Separate the audit log from agent-writable state.** Mirror `session_start`/`session_end` into the host journal or a host-only file, so the runlog can be checked for tampering.
7. **Use one mount list for every credential check (S4).** Build the list once from the actual `container_args` sources (`run.sh:320-328`) and use it at `run.sh:80-95`, `run.sh:266-267`, `run.sh:295-298`, and `publish.sh:53`.
8. **Make agent-written status verifiable (L4).** Require `CURRENT.md` test claims to name a command that the next session re-runs, and prefer `tests/test.sh` over grep-based checks.

## 6. Verification log (this review)

| # | What | Result |
|---|---|---|
| R1 | `bash -c 'set -euo pipefail; pid=""; [[ -f /workspace/track-resources.sh ]] && export X=1 "/workspace/track-resources.sh" && pid=$!; echo "pid=[$pid]"'` | `export: '/workspace/track-resources.sh': not a valid identifier`, `pid=[]`, exit 0. The tracker never runs. |
| R2 | `bash -c 'set -euo pipefail; cleanup(){ if [[ -n $resource_tracker_pid ]]; then :; fi; echo done; }; trap cleanup EXIT; exit 1'` | `resource_tracker_pid: unbound variable`; `done` is never printed. |
| R3 | `bash -c 'set -euo pipefail; false >>2 && echo ok >>2 \|\| echo "not generated" >>2'` in a temp dir | Creates a file named `2` containing `not generated`. |
| R4 | In a temp dir: `ln t1 outcome` (ok) → `ln t2 outcome` (fails: File exists) → `rm -f outcome; ln t2 outcome` (ok, content B) → `mv -f t3 outcome` (ok, content C) | Shows that `ln` blocks only a second creation. Anything with write access to the directory can replace the marker. The full helper could not be run here because `jq` is not installed in this environment. |
| R5 | `python3 -IB tests/test_runtime.py` (as run by `tests/test.sh:13`) | `Ran 25 tests … FAILED (failures=24, errors=3)`. The main cause (15 failures, plus 2 that fail for the same reason) is `commitment: inbox context helper not installed: …/runtime/inbox-context.sh`, because the file is mode `0644` (D4). Other failures come from `jq` missing in this environment (`jq: command not found`; `install: required command not found: jq`) and one `PermissionError` executing `inbox-context.sh`. |
| R6 | In a temp dir, ran `run.sh:78-95` via `eval "$(sed -n 78,95p run.sh)"` with fixture paths and `OUTCOME_HELPER=$RUNTIME_DIR/session-outcome.sh`. Case A: `BITWARDEN_SECRETS_TOKEN_FILE=$OUTCOME_HELPER`. Case B: token at `$COMMITMENT_REPO/token`. Case C: `CHEAPERINFERENCE_API_KEY_FILE=$OUTCOME_HELPER` | A: accepted (no `die`), so a Bitwarden token at a mounted helper-file path passes the check. B: `die: Bitwarden token path must stay outside all creative mounts`. C: `die: CheaperInference key path must stay outside all creative mounts`. This confirms §3.3: the planner check covers the helper files and the Bitwarden check does not. |

No repository code was changed by this review. See §7 for why no fix was applied. The Bitwarden check gap (R6) is reported, not fixed. Its fix would be to use the planner list at `run.sh:87-90` for `run.sh:80` and `run.sh:266-267`, and the same for `publish.sh:53`.

## 7. Retry investigation: the previous failed architecture-review run

**Goal:** find out why the previous architecture-review attempt failed.

**Sources checked:**

- Working tree and Git: `git log --all`, `git for-each-ref`, reflogs (`.git/logs/HEAD`, `.git/logs/refs/heads/main`, `.git/logs/refs/remotes/origin/HEAD`), and `git stash list`. The only refs are `main`/`origin/main` at the base commit `53757d7`, and the reflog shows only this checkout's clone. There is no branch, commit, or stash from an earlier review attempt. `docs/` did not exist.
- Repository content: case-insensitive search for `architecture review` / `ARCHITECTURE_REVIEW` in all tracked files found no matches. Searching `runlog.jsonl` for "review" and "architect" finds only unrelated research entries (for example `runlog.jsonl:6-26`, Hacker News reviews). `CURRENT.md`, `inbox/`, `queue/`, and `requests/` do not mention an architecture-review task.
- Pipeline context: `/contract.json` contains this retry's objective, criteria, and limits. It holds no log, reviewer output, or error from the earlier attempt. `/tmp` contains only this session's state, and there is no `.teem/` directory in the checkout.

**Finding:** The cause of the previous failed architecture-review run **could not be determined**. None of the sources available to this run contain its logs, output, or reviewer verdict. The only information about it is the retry objective itself. That text implies the reviewer objected to (a) safety guarantees stated more strongly than `run.sh` enforces and (b) an investigation that swapped in an unrelated defect. Sections 3 and 7 of this document address those two points. Whether the earlier run also failed for other reasons, such as a timeout or tool error, cannot be established from here.

**Not substituted:** The defects in §4.2 (D1–D7) and the failing test suite (R5) are properties of the reviewed commit `53757d7`. There is no evidence connecting them to the earlier review run, and they are not offered as its cause.

**Fix applied for a diagnosed cause:** None, because no cause was diagnosed. For the same reason, there is nothing to verify by reproduction. The reproductions in §6 support the review's findings, not a fix for the earlier run.
