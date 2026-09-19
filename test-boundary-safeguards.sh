#!/bin/bash

# Comprehensive Boundary Safeguard Testing Script

echo "=== Comprehensive Boundary Safeguard Testing ==="
echo ""

# Test 1: Test pre-commit hook effectiveness
echo "Test 1: Verifying pre-commit hook blocks node_modules commits"
cd /workspace/commitment-lab

# Create node_modules and force add it to staging
mkdir -p node_modules/test_package
echo "test" > node_modules/test_package/index.js

git add -f node_modules/

# Try to commit - should be blocked by pre-commit hook
if git commit -m "Test commit with node_modules" 2>&1 | grep -q "ERROR: Attempting to commit node_modules"; then
    echo "   ✓ Pre-commit hook correctly blocks node_modules commits"
else
    echo "   ✗ ERROR: Pre-commit hook did not block node_modules commit"
    exit 1
fi

git reset --hard HEAD
rm -rf node_modules


echo ""

# Test 2: Test boundary validation scripts
echo "Test 2: Running boundary validation scripts"
cd /workspace/commitment

if bash boundary-check.sh > /dev/null 2>&1; then
    echo "   ✓ boundary-check.sh passes"
else
    echo "   ✗ ERROR: boundary-check.sh failed"
    exit 1
fi

if bash validate-boundaries.sh > /dev/null 2>&1; then
    echo "   ✓ validate-boundaries.sh passes"
else
    echo "   ✗ ERROR: validate-boundaries.sh failed"
    exit 1
fi

echo ""

# Test 3: Test cross-contamination detection
echo "Test 3: Testing cross-contamination detection"

# Create a backup of CURRENT.md
cp CURRENT.md CURRENT.md.backup

# Add lab project contamination
{ cat CURRENT.md.backup; echo "## Lab Project: Observer Core Implementation"; } > CURRENT.md

if bash boundary-check.sh 2>&1 | grep -q "contains lab project state"; then
    echo "   ✓ Boundary check detects CURRENT.md contamination"
else
    echo "   ✗ ERROR: Boundary check did not detect contamination"
    exit 1
fi

# Restore original file
mv CURRENT.md.backup CURRENT.md

echo ""

# Test 4: Test repository separation checks
echo "Test 4: Testing repository separation"

if [ ! -f "commitment-lab/CURRENT.md" ]; then
    echo "   ✓ No CURRENT.md in lab repository"
else
    echo "   ✗ ERROR: CURRENT.md exists in lab repository"
    exit 1
fi

cd /workspace/commitment-lab
if [ ! -d "../commitment/commitment-lab" ]; then
    echo "   ✓ No orphaned lab directory in commitment repo"
else
    echo "   ✗ ERROR: Orphaned lab directory found"
    exit 1
fi

echo ""
echo "=== All Safeguard Tests Passed ==="
exit 0
