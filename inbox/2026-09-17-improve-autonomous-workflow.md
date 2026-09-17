> Previous attempt was interrupted after this item was moved to `processed/`
> but before the analysis and durable working state were written. Treat this task
> as unfinished. This failure is itself evidence for the continuity problem:
> important conclusions should become durable before an input is retired or before
> relying on end-of-session cleanup.

> Before implementing additional continuity machinery, use `commitment-plan` to
> adversarially review the proposed design.
>
> In particular, evaluate:
>
> - whether `BOOT.md` duplicates `CURRENT.md`;
> - whether separate task files and CHECKPOINT.md create unnecessary sources of
>   truth;
> - whether periodic 15-minute checkpoints or 24/48-hour stale thresholds are
>   supported by observed failures;
> - whether the existing Git checkpoint/recovery mechanism already solves part of
>   the persistence problem;
> - whether a much smaller design could achieve fast initialization and reliable
>   interruption recovery.
>
> Prefer fewer authoritative representations. Do not implement a checkpoint tool
> or automatic checkpoint schedule until the planner review shows that simpler
> mechanisms are insufficient.

# Research and improve autonomous continuity, initialization, working state, and information encoding

Evaluate how Commitment maintains continuity across autonomous runs and improve the
design where doing so would materially increase usefulness.

The underlying goal is not to improve `CURRENT.md` specifically. The goal is for a
fresh session to cheaply and accurately recover what matters, understand what it
can do, resume unfinished work after arbitrary interruption, and avoid repeatedly
rediscovering established context.

Treat the current implementation as a working prototype, not a required
architecture.

## Desired properties

A good design should make it easy for a fresh session to determine:

- what Commitment is trying to accomplish;
- whether active work exists;
- what was already learned or decided;
- what remains uncertain;
- what was being attempted when the previous session ended;
- the intended next move;
- what capabilities and resources are available;
- what new operator input or retained work deserves attention.

It should also:

- survive normal session endings, premature model exits, timeouts, crashes, and
  other interruption;
- preserve unfinished intent early enough that useful reasoning is not lost;
- minimize repeated scanning of Git history, runlogs, memory, and repository
  contents;
- consume little model context during initialization;
- remain understandable and debuggable by the operator;
- prefer state and mechanisms that are directly human-auditable;
- make important active state inspectable without requiring specialized tooling,
  opaque databases, hidden model state, or reconstruction from implementation
  internals;
- keep machine-oriented representations explainable through a concise
  human-readable view when a structured store is justified;
- avoid turning autonomous work into a rigid workflow.

## Do not assume the storage mechanism

`CURRENT.md` is evidence that persistent working state is useful, but it does not
need to remain the final mechanism.

Research and compare whatever designs seem appropriate, including combinations of:

- `CURRENT.md` or another concise working-state file;
- append-only journals or event logs;
- session handoff records;
- structured state files;
- SQLite or another small local store;
- explicit checkpoints or snapshots;
- Git-backed state;
- automatically distilled working context;
- selective continuation of prior OpenCode sessions;
- transcript summaries;
- startup-generated context;
- other mechanisms you identify.

The representation should follow from the requirements rather than the other way
around.

Prefer the simplest mechanism that provides reliable continuity and recovery.

## Session initialization

Treat initialization as part of the continuity problem.

A fresh session should receive or discover important context in an efficient order
instead of reconstructing its situation from scratch.

Investigate:

- what should always be available at startup;
- what should be loaded only when relevant;
- what should be summarized versus retained verbatim;
- whether recent history should be selected automatically;
- whether an explicit startup manifest or generated context would help;
- how to avoid repeatedly reading long runlogs or unrelated memory;
- how initialization can distinguish active work from durable background
  knowledge;
- whether recent interrupted work should be surfaced automatically;
- whether fresh sessions should receive a compact summary of available
  capabilities and resources;
- whether startup should differ when active work exists versus when Commitment is
  between tasks.

Measure success partly by how quickly a fresh session can reach an informed useful
action.

## Capability awareness

Evaluate whether Commitment needs a concise capability index such as
`CAPABILITIES.md`, a generated equivalent, or another mechanism.

Stable, frequently needed facts should be cheap to discover.

For example, Commitment should not need to inspect source code or search the
filesystem merely to determine that commands such as:

- `commitment-plan`;
- `commitment-secret`;
- `commitment-log`;
- `commitment-outcome`;

exist and what they are for.

Also consider whether the capability representation should communicate useful
facts such as:

- ability to execute code and tests;
- internet/research access;
- available repositories;
- external planning capability;
- secret-management capability;
- publication or communication capabilities;
- important limitations of the environment.

Avoid documenting generic shell knowledge that the model already possesses.

Detailed implementation information should remain available on demand rather than
being loaded into every session.

## Work persistence

When Commitment selects a meaningful direction, enough state should become durable
early enough that an unexpected exit does not erase the reasoning that led to the
choice.

Investigate how best to preserve:

- objective;
- current understanding;
- important findings;
- unresolved questions;
- decisions already made;
- experiments or actions already attempted;
- rejected alternatives when that rejection matters;
- intended next move.

Do not require all of these fields if a better representation exists.

Do not rely entirely on final-session cleanup. A session may end unexpectedly at
any time.

Prefer mechanisms that naturally preserve useful working state as the work
progresses.

## Session handoff

Determine whether explicit end-of-session handoff is useful and, if so, what the
minimum valuable handoff contains.

A useful handoff might include:

- what was attempted;
- what changed;
- what was learned;
- unresolved questions;
- exact next move.

Avoid duplicating history already preserved elsewhere.

A handoff should complement durable working state rather than being the only place
where continuity is preserved.

## Work progression

Consider how Commitment should move naturally among:

- prospecting;
- research;
- planning;
- experimentation;
- implementation;
- testing;
- review;
- completion;
- abandonment;
- returning to earlier stages when evidence changes.

These are descriptive activities, not mandatory stages or gates.

Do not build a workflow engine merely to represent them.

Use `commitment-plan` when stronger reasoning would materially improve work
selection, planning, architecture, evaluation, or prospecting.

## Prompt and instruction architecture

All repository-owned prompts and instructions are editable, including:

- `MISSION.md`;
- `AGENTS.md`;
- the primary agent definition;
- `prompt.txt`;
- workspace conventions;
- related documentation.

They may be changed, reorganized, consolidated, replaced, or retired when doing so
clearly improves Commitment.

However, err on the side of preserving the existing prompt and instruction stack
until reliable durable working state and session recovery exist.

Do not remove or radically restructure currently useful orientation merely because
a cleaner theoretical design exists.

Before retiring or replacing an existing source of orientation, ensure that the
replacement demonstrably preserves the information and behavioral continuity
necessary for future sessions.

Once durable state and initialization are demonstrably reliable, prompt structure
itself may be reconsidered more aggressively.

Trusted-runtime activation boundaries still apply: repository changes to trusted
runtime source do not become active until the operator installs them.

## Information encoding

Look for broader opportunities to improve how information is represented to the
agent.

The goal is not merely to shorten files. Optimize for useful information per unit
of model context and attention.

Consider:

- concise indexes and manifests;
- high-value startup context versus on-demand documentation;
- duplication across MISSION, AGENTS, CURRENT, memory, README, SECRETS, agent
  instructions, and runtime documentation;
- whether stable facts are buried in historical files;
- compact representation of conclusions, uncertainty, and next moves;
- whether generated summaries can replace repeated expensive discovery;
- whether some current prose could be made more actionable without becoming more
  rigid;
- whether capability and environment facts should be generated from runtime state
  rather than manually duplicated;
- whether recent working context can be distilled without losing important
  uncertainty or rationale;
- whether indexes over memory or durable findings would reduce unnecessary reads.

Stable, frequently needed facts should be cheap to discover.

Detailed information should generally remain available on demand.

## Human auditability

Prefer designs whose important state can be inspected and understood directly by
the operator.

Human-auditable does not require plain Markdown for everything.

SQLite, structured files, generated indexes, journals, or other machine-oriented
mechanisms are acceptable when they provide clear operational value.

However, the following should remain easy for a human to inspect:

- current objective;
- important active decisions;
- unfinished work;
- important uncertainty;
- intended next move;
- major capability assumptions;
- recovery state after interruption.

If an opaque or structured store becomes authoritative, provide a concise
human-readable view or inspection interface.

Do not make opaque machine state the only source of truth for information that is
important to recovery or operator oversight.

Prefer designs that can be debugged without reverse-engineering implementation
details.

## Research approach

Inspect actual recent sessions and identify concrete sources of:

- wasted initialization work;
- repeated rediscovery;
- lost working context;
- premature session endings;
- incorrect assumptions about available capabilities;
- unnecessary self-referential work;
- repeated reading of historical runlog or Git state;
- context consumption that does not contribute to useful action;
- failure to preserve a chosen direction before interruption.

Use `commitment-plan` when stronger reasoning would help:

- compare designs;
- challenge assumptions;
- identify alternatives;
- evaluate tradeoffs;
- determine whether a proposed mechanism is actually simpler or more reliable.

Research and design before making substantial architectural changes.

Small experiments are encouraged when they can cheaply resolve uncertainty.

Use actual observed session behavior as stronger evidence than speculative
architecture.

## Architectural freedom

Existing mechanisms such as:

- `CURRENT.md`;
- `memory/`;
- inbox;
- queue;
- requests;
- Git;
- `runlog.jsonl`;
- persisted OpenCode sessions;
- repository-owned prompts and instructions;

are available building blocks, not permanent requirements.

Preserve, combine, replace, or retire them according to what produces the simplest
reliable design.

Do not preserve a mechanism solely because it already exists.

Do not replace a working mechanism solely because another design is more novel.

Prefer designs whose important state remains directly human-auditable.

## Avoid unnecessary machinery

Do not recreate the complexity deliberately removed in v0.4.x.

In particular, avoid introducing without strong evidence:

- rigid workflow stages;
- semantic Git classification;
- mandatory planner approval;
- elaborate lifecycle schemas;
- large metadata requirements;
- another authoritative state machine;
- complicated status taxonomies;
- process that exists primarily to satisfy process.

Complexity is acceptable when it buys concrete reliability, continuity,
recoverability, context efficiency, or capability.

Do not confuse simplicity with minimal file count. A small structured mechanism may
be simpler operationally than repeated model reconstruction from many loosely
related files.

## Deliverable

Produce a concrete assessment of the current continuity, initialization, working
state, and information-encoding design.

Identify the most important observed failure modes.

Compare plausible improvements against criteria including:

- reliability;
- interruption recovery;
- context cost;
- startup speed;
- human auditability;
- implementation complexity;
- maintenance burden;
- compatibility with autonomous work;
- ability to evolve later.

Then either:

- implement the smallest clearly valuable improvement and validate it; or
- preserve the current implementation and record why a proposed alternative is
  not yet justified.

Do not implement a new mechanism merely because one is possible.

While performing this work, ensure that the investigation itself leaves durable
state sufficient for another fresh session to understand:

- what has been learned;
- what remains uncertain;
- what design options were considered;
- what has been decided;
- what should happen next.

The continuity research should itself demonstrate good continuity.
