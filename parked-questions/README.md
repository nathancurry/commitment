# Parked Questions

## Purpose
This directory contains questions or decisions that are blocked waiting for operator input. Questions are parked when:

1. The question genuinely requires operator input
2. The system cannot make useful progress without an answer
3. The situation is not an emergency

## Parking a Question

When a question needs to be parked:

1. Create a new file in this directory with a descriptive name (e.g., "2026-09-20-should-we-purchase-x.md")
2. Include:
   - Clear question/decision needed
   - Context for why the answer is needed
   - Timestamp when parked
   - Any relevant information

## Morning Report Integration

The morning report generator will:
- List all parked questions
- Show how long each has been waiting
- Suggest priority order for operator review

## Operator Response

When responding to parked questions:
- Move the file to `inbox/` directory
- Add your response at the bottom of the file
- Or create a new response file if preferred

## Current Parked Questions

Files in this directory represent questions waiting for operator response.
