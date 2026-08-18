# operations

current state: no runnable implementation. commands and exact configuration must be documented after they exist and are verified. do not infer commands from this checklist.

future operator instructions must cover, in order:

1. install Ollama on Linux workstation.
2. select and configure model for available host hardware. use `gpt-oss:20b` as initial example, not required model.
3. install and configure rootless Podman.
4. build commitment container.
5. verify container can reach host Ollama without broader host access.
6. run dry-run mutation with no commit or push.
7. run validated mutation with commit and push disabled.
8. configure scheduling and duplicate-run protection.
9. enable supervisor-owned pushing with repository-scoped credentials.
10. later, configure Material for MkDocs and GitHub Pages.

instructions must also explain expected files, validation output, local diagnostics, safe retry, scheduler disablement, and recovery without history rewrite. each step needs prerequisites, exact verified command, expected result, and failure check.
