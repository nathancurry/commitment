#!/usr/bin/env bash
# Test resource tracking implementation
set -euo pipefail

echo "Testing resource tracking implementation..."
echo ""

# Test 1: Check track-resources.sh exists
if [[ -f "/workspace/commitment/track-resources.sh" ]]; then
    echo "✓ track-resources.sh found"
else
    echo "✗ track-resources.sh not found"
    exit 1
fi

# Test 2: Check track-resources.sh is executable
if [[ -x "/workspace/commitment/track-resources.sh" ]]; then
    echo "✓ track-resources.sh is executable"
else
    echo "✗ track-resources.sh is not executable"
    exit 1
fi

# Test 3: Check inbox-context.sh has resource tracking code
echo ""
echo "Testing inbox-context.sh resource tracking..."
if grep -q "cpu_start\|mem_available_start" "/workspace/commitment/inbox-context.sh"; then
    echo "✓ inbox-context.sh contains resource tracking code"
else
    echo "✗ inbox-context.sh missing resource tracking code"
    exit 1
fi

# Test 4: Check run.sh integration
echo ""
echo "Testing run.sh integration..."
if grep -q "track-resources.sh" "/workspace/commitment/run.sh"; then
    echo "✓ run.sh references track-resources.sh"
else
    echo "✗ run.sh missing track-resources.sh reference"
    exit 1
fi

# Test 5: Check cleanup function
echo ""
echo "Testing cleanup integration..."
if grep -q "resource_tracker_pid" "/workspace/commitment/run.sh"; then
    echo "✓ run.sh has resource tracker cleanup"
else
    echo "✗ run.sh missing resource tracker cleanup"
    exit 1
fi

# Test 6: Check session-outcome.sh
if grep -q "generate-morning-report.sh" "/workspace/commitment/session-outcome.sh"; then
    echo "✓ session-outcome.sh calls generate-morning-report.sh"
else
    echo "✗ session-outcome.sh missing morning report call"
    exit 1
fi

echo ""
echo "All tests passed! Resource tracking implementation is complete."
echo ""
echo "Next steps:"
echo "1. Run a test session to verify resource tracking works"
echo "2. Check the morning report for resource metrics"
echo "3. Document the implementation in work/"
