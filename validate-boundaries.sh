#!/bin/bash

# Repository Boundary Validation Script
# Validates that repository boundaries are respected

set -e

echo "Validating repository boundaries..."
echo

# Test 1: Check that CURRENT.md only exists in commitment repository
echo "Test 1: Checking CURRENT.md location..."
if [ ! -f "CURRENT.md" ]; then
    echo "ERROR: CURRENT.md not found in /workspace/commitment/"
    exit 1
fi

# Check that CURRENT.md is in the correct location
if [ "$(pwd)" != "/workspace/commitment" ]; then
    echo "ERROR: CURRENT.md validation must be run from /workspace/commitment/"
    exit 1
fi

# Test 2: Validate that CURRENT.md content is Commitment-specific (not lab project state)
echo "Test 2: Checking CURRENT.md content..."
if grep -q "Observer Core" CURRENT.md || \
   grep -q "Runtime Monitor" CURRENT.md || \
   grep -q "Fear of Commitment prototype" CURRENT.md; then
    echo "ERROR: CURRENT.md contains lab project state!"
    echo "CURRENT.md should only contain Commitment-specific state."
    exit 1
fi

# Test 3: Check that node_modules is properly ignored in lab repository
echo "Test 3: Checking lab repository .gitignore..."
if [ ! -f "/workspace/commitment-lab/.gitignore" ]; then
    echo "ERROR: .gitignore not found in commitment-lab"
    exit 1
else
    if ! grep -q "node_modules" /workspace/commitment-lab/.gitignore; then
        echo "WARNING: node_modules not in .gitignore for commitment-lab"
    fi
fi

# Test 4: Check that pre-commit hook exists in lab
echo "Test 4: Checking lab pre-commit hook..."
if [ ! -f "/workspace/commitment-lab/.git/hooks/pre-commit" ]; then
    echo "ERROR: pre-commit hook not found in commitment-lab"
    exit 1
else
    echo "Pre-commit hook exists in commitment-lab"
fi

echo
echo "All boundary validation tests passed!"
echo "Repository boundaries are intact."
exit 0
