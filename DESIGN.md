# design

## current state

repo contains design docs only. every component below is planned.

## architecture

commitment uses custom harness with minimal dependencies. it has four parts.

### host model

Ollama runs on Linux workstation. operator configures model selection for available hardware. `gpt-oss:20b` is initial example model, not universal requirement. RTX 5070 Ti 16 GB and 32 GB system RAM are one example sizing profile, not project identity or minimum requirement. model stays outside container so mutable code cannot administer model service.

### agent container

agent runs once per invocation in rootless Podman container. it receives repo as writable input, temporary workspace, and access to host Ollama endpoint. it receives no GitHub credentials, container-engine socket, or unrelated host paths.

agent inspects repo and recent history. it selects one bounded mutation, edits repo, runs allowed checks, writes journal entry, and reports proposed result. process exits after one attempt.

### host supervisor

small host-side supervisor owns run lock, credentials, policy, validation, commit, and push. it launches container with resource and time limits. it compares reported result with actual diff. it runs required tests and protected policy checks outside mutable agent's authority.

supervisor is trusted control plane. agent may propose changes. proposal has no publication authority.

### repository

repo is durable state. code and prompts define current behavior. Git history records actual behavior. Markdown journal records commitment's narration. roadmap records intended work. tags mark surviving generations.

published history stays append-only. correction uses later commit. journal can later become Material for MkDocs site on GitHub Pages without becoming separate source of truth.

## trust boundary

host account, supervisor policy, GitHub credentials, protected checks, and human milestone tags stay outside mutable agent authority.

agent code, prompts, tests, docs, and journal may become mutable after bootstrap. supervisor must reject changes outside allowed paths or budget. dependency and container changes need additional validation because they change next runtime.

agent never commits, pushes, or handles GitHub credentials. after bootstrap it may propose annotated tags under `agent/*`; supervisor validates and creates them.

## daily run lifecycle

1. scheduler starts supervisor.
2. supervisor locks repo and verifies clean expected revision.
3. supervisor synchronizes with fast-forward-only policy.
4. supervisor starts one-shot container with bounded access.
5. agent inspects repo and chooses one bounded mutation.
6. agent edits, tests, journals, and returns proposed result.
7. supervisor inspects diff and enforces policy and change limits.
8. supervisor runs required tests independently.
9. supervisor commits and pushes only accepted result.
10. failed run leaves no commit. diagnostics remain local for operator inspection.

accepted code and docs take effect on later run. running process does not replace itself in place.

## deferred scope

newsletter ingestion, social posting, and GitHub Pages build come later. external text must be treated as untrusted input. credentials for any publisher remain host-side.
