# operations

current state: phase 0 CLI and Containerfile exist. complete operator installation and live Ollama verification remain next pass. do not infer missing environment-specific setup from this checklist.

future operator instructions must cover, in order:

1. install Ollama on Linux workstation.
2. select and configure model for available host hardware. use `gpt-oss:20b` as initial example, not required model.
3. install and configure rootless Podman.
4. build commitment container.
5. verify the host-mediated Ollama call and both network-disabled, read-only container stages.
6. run dry-run mutation with no commit or push.
7. run validated mutation with commit and push disabled.
8. configure scheduling and duplicate-run protection.
9. enable supervisor-owned pushing with repository-scoped credentials.
10. later, configure Material for MkDocs and GitHub Pages.

instructions must also explain expected files, validation output, local diagnostics, safe retry, scheduler disablement, and recovery without history rewrite. each step needs prerequisites, exact verified command, expected result, and failure check.

phase 0 recovery boundary is branch compare-and-swap. failure before it may leave untracked or staged journal state and unreachable objects. inspect current branch, `git status`, and reflogs before retry. success after it is not rolled back even when final narration is interrupted.

do not configure hooks for phase 0. supervisor forces empty hooks directory for every Git command. custom `core.hooksPath` has no effect. bare repositories, linked worktrees, detached `HEAD`, filesystem crash consistency, and hostile same-UID actors are unsupported.
