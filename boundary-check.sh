#!/bin/bash

# Repository Boundary Validation Script
# Validates that repository boundaries are maintained

set -e

echo "=== Repository Boundary Validation ==="
echo ""

# 1. Check that node_modules is not tracked in lab repository
cd /workspace/commitment-lab
echo "1. Checking node_modules tracking in lab repository..."
if git ls-files "node_modules" | grep -q "."; then
    echo "ERROR: node_modules is still tracked in lab repository!"
    exit 1
fi
echo "   ✓ node_modules not tracked in lab repository"
echo ""

# 2. Check that CURRENT.md exists only in commitment repository
cd /workspace/commitment
echo "2. Checking CURRENT.md location..."
if [ ! -f "CURRENT.md" ]; then
    echo "ERROR: CURRENT.md does not exist in commitment repository!"
    exit 1
fi
echo "   ✓ CURRENT.md exists in commitment repository"
echo ""

# 3. Check that CURRENT.md is Commitment-specific (not lab project state)
echo "3. Validating CURRENT.md content..."
content=$(cat CURRENT.md)
# Check for lab project state contamination patterns
if echo "$content" | grep -q "Observer Core"; then
    echo "ERROR: CURRENT.md contains lab project state (Observer Core)!"
    exit 1
fi
if echo "$content" | grep -q "Runtime Monitor"; then
    echo "ERROR: CURRENT.md contains lab project state (Runtime Monitor)!"
    exit 1
fi
echo "   ✓ CURRENT.md appears to be Commitment-specific"
echo ""

# 4. Check repository separation
cd /workspace/commitment
echo "4. Checking repository separation..."
if [ -d "commitment-lab" ]; then
    echo "ERROR: Orphaned commitment-lab directory found in commitment repository!"
    exit 1
fi
cd /workspace/commitment-lab
if [ -f "CURRENT.md" ]; then
    echo "ERROR: CURRENT.md should not exist in lab repository!"
    exit 1
fi
echo "   ✓ Repository separation maintained"
echo ""

echo "=== All Boundary Checks Passed ==="
exit 0