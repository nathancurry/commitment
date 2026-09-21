# Commit Messages Improvement Plan

## Current State Analysis

Currently, commit messages are very generic:
- Line 104: `commit_dirty "session: ${AGENT_OUTCOME}"`
- Line 106: `commit_dirty "checkpoint: ${AGENT_OUTCOME} after session exit ${AGENT_EXIT_STATUS:-unknown}"`

## Objective

Make commit messages higher signal by including:
1. Short tag indicating state (COMMITTED_CHANGE, NOOP, CHECKPOINT_UNFINISHED, FAILED)
2. Description of work performed

## Implementation Strategy

### Phase 1: Enhance session-outcome.sh

Modify `session-outcome.sh` to capture work descriptions:
- Add mechanism to track key accomplishments
- Allow agent to provide summary of work
- Pass this information through to publication system

### Phase 2: Enhance agent-git.sh

Modify `agent-git.sh` commit_dirty function to:
- Use AGENT_SUMMARY or work descriptions
- Format messages as: `[TAG] Description of work performed`

### Phase 3: Documentation

Update documentation to reflect new commit message format

## Detailed Implementation

### 1. session-outcome.sh Enhancement

Add mechanism to record work descriptions:
- Extend outcome JSON to include work summary
- Create function to extract meaningful work descriptions from runlog

### 2. agent-git.sh Enhancement

Update commit_dirty function:
```bash
commit_dirty() {
    local message=$1
    local work_desc=""
    [[ -n $(git -C "$repo" status --porcelain) ]] || return 0
    [[ -z $(git -C "$repo" ls-files -u) ]] ||
        die "unmerged files preserved for inspection; refusing to mark conflicts resolved"
    export GIT_AUTHOR_NAME=${AGENT_GIT_NAME:?configured Git identity is required}
    export GIT_AUTHOR_EMAIL=${AGENT_GIT_EMAIL:?configured Git identity is required}
    export GIT_COMMITTER_NAME=${AGENT_GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}
    export GIT_COMMITTER_EMAIL=${AGENT_GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}
    
    # Build meaningful commit message
    if [[ -n ${AGENT_SUMMARY:-} ]]; then
        work_desc=" - ${AGENT_SUMMARY}"
    fi
    
    # Recovery must not depend on a project's commit hooks accepting unfinished work.
    git -C "$repo" -c core.hooksPath=/dev/null add -A
    git -C "$repo" -c core.hooksPath=/dev/null commit -m "${message}${work_desc}"
    require_clean
}
```

### 3. Run.sh Enhancement

Modify run.sh to pass AGENT_SUMMARY to finalize:
- Ensure AGENT_SUMMARY is preserved across session boundaries
- Pass to publish.sh finalize command

## Testing Strategy

1. Test with existing commit patterns
2. Verify AGENT_SUMMARY is properly captured
3. Test checkpoint scenarios
4. Test NOOP scenarios
5. Verify message formatting is clear and informative

## Validation

- Commit messages should be descriptive
- Should include both state tag and work description
- Should not exceed Git's commit message length limits
- Should remain machine-readable where possible