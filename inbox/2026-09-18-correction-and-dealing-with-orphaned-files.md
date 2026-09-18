# Correct repository boundary and reconcile orphaned work

`commitment-lab` is a separate repository mounted at
`/workspace/commitment-lab`. It has its own trusted Git publication.

Do not create or initialize `/workspace/commitment/commitment-lab`.

Several interrupted or failed sessions have left uncommitted and untracked work
in the Commitment repository.

Before continuing, inspect the entire working tree and reconcile it.

For each orphaned change:
- keep and incorporate it if it represents useful valid work;
- move it to the correct repository or location when necessary;
- revise it if the intent is useful but the implementation is wrong;
- discard it if it is obsolete, incorrect, accidental, or redundant.

In particular, inspect the files under the mistakenly created
`/workspace/commitment/commitment-lab/`. Adopt useful Fear of Commitment work into
the real `/workspace/commitment-lab`; do not preserve it merely because it exists.

Also reconcile the partially processed operator input and any other dirty state
left by interrupted sessions.

The goal is a coherent clean working tree, not preservation of every artifact.

Once reconciliation is complete, continue the Fear of Commitment work in the real
`/workspace/commitment-lab`.
