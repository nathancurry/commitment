# Repository Boundary Hygiene Analysis

## Boundary Failure Causes Identified

1. **CURRENT.md Cross-Contamination**: When working on the Fear of Commitment prototype in `commitment-lab`, the session wrote lab project implementation state (Observer Core implemented, Runtime Monitor functional, test suite created) into `/workspace/commitment/CURRENT.md` instead of maintaining separate state for each repository.

2. **node_modules Committed in Lab**: The `node_modules` directory was committed and pushed to the lab repository before being properly cleaned up.

## Root Causes

### 1. Context Confusion
- The session switched between repositories without maintaining clear context separation
- Working directory changes weren't properly tracked or enforced
- No mechanism to detect when CURRENT.md content doesn't match the current working repository

### 2. Missing Safeguards
- No git pre-commit hook to prevent committing `node_modules/`
- No validation that CURRENT.md content matches the active repository context
- No repository boundary checks to ensure state files remain repository-specific

## Proposed Solutions

### Immediate Fixes (Minimal, Reversible)

1. **Git pre-commit hook for lab repository** to block commits containing `node_modules/`

2. **Repository context validation script** that:
   - Checks that CURRENT.md only exists in `/workspace/commitment/`
   - Validates that CURRENT.md content is Commitment-specific (not lab project state)
   - Can be run before key operations

3. **Working state separation**:
   - Create separate state files for each repository
   - Update instructions to enforce clear repository context rules

### Longer-term Improvements

1. **Workdir-aware session wrapper** that explicitly declares which repository is active
2. **Automated boundary checking** integrated into session startup/shutdown
3. **Context-aware state management** that prevents cross-repository state leakage

Let me implement the immediate fixes first:

## Implementation Plan

1. Add git pre-commit hook to lab repository
2. Create repository boundary validation script  
3. Add validation to pre-session checks
4. Update CURRENT.md with boundary hygiene focus