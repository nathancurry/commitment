# Repository Boundary Guidelines

## Overview

This document establishes the principles and practices for maintaining clear boundaries between Commitment's working state and any external projects hosted in the lab repository.

## Principles

### 1. Two Repositories, Two Contexts

- **`/workspace/commitment/`** - Contains Commitment itself
  - Mission, agents, instructions, and working state
  - `CURRENT.md` describes Commitment's active work or state
  - Commitment's Git repository
  
- **`/workspace/commitment-lab/`** - Contains external projects and experiments
  - Prototype implementations, test projects, and non-Commitment software
  - Each lab project maintains its own state
  - Separate Git repository

### 2. State Isolation

Each repository maintains its own state:
- Commitment's `CURRENT.md` describes Commitment's work
- Lab projects maintain their own state files (if needed)
- No cross-repository state contamination

### 3. Clear Working Context

Operations should always be explicit about which repository is active:
- Use `cd` deliberately to switch contexts
- Maintain awareness of current working directory
- Never assume context from file location alone

## Safeguards

### Git Pre-commit Hook

The lab repository has a pre-commit hook that prevents committing `node_modules/`:
```bash
/workspace/commitment-lab/.git/hooks/pre-commit
```

This hook blocks any attempt to commit the `node_modules` directory.

### Boundary Validation

Two validation scripts are available:

1. **`boundary-check.sh`** - Comprehensive boundary validation
   - Checks node_modules tracking
   - Validates CURRENT.md location and content
   - Enforces repository separation

2. **`validate-boundaries.sh`** - Lightweight validation
   - Checks CURRENT.md content for contamination
   - Verifies .gitignore configuration
   - Confirms pre-commit hook exists

Run these before critical operations:
```bash
bash boundary-check.sh
bash validate-boundaries.sh
```

## Best Practices

### 1. Repository Context Management

- **Always** check your current directory before making changes
- Use absolute paths when referencing files across repositories
- Explicitly state which repository you're working in

### 2. State File Management

- `CURRENT.md` exists only in `/workspace/commitment/`
- Never write lab project state to `CURRENT.md`
- Each lab project manages its own documentation

### 3. Git Operations

- Commit from the correct repository context
- Stage files explicitly to avoid cross-repository commits
- Run boundary validation before pushing

### 4. Session Workflow

When working on lab projects:
1. `cd /workspace/commitment-lab`
2. Create/manage lab-specific state files
3. Never update `/workspace/commitment/CURRENT.md`

When working on Commitment:
1. `cd /workspace/commitment`
2. Update `CURRENT.md` for Commitment's state
3. Avoid mixing lab project details

## Troubleshooting

### Cross-Contamination Detection

If CURRENT.md contains lab project references:
```bash
# Run validation
bash boundary-check.sh

# Fix by restoring Commitment-specific state
cd /workspace/commitment
# Edit CURRENT.md to remove lab project details
# Recommit clean state
```

### node_modules Issues

If node_modules gets committed:
1. Remove from index: `git rm --cached -r node_modules/`
2. Add to .gitignore
3. Run validation to confirm fix

## Implementation Notes

### Current Safeguards Status

- ✅ Git pre-commit hook in lab repository (blocks node_modules)
- ✅ Boundary validation scripts available
- ✅ CURRENT.md content validation in place
- ✅ Repository separation checks operational

### Future Enhancements

Potential improvements:
- Automated boundary checking at session startup
- Context-aware state management
- Workdir tracking in session metadata
