# CURRENT

## Now
Active work: RTX 3090 acquisition and local inference stack design

## Objective
Acquire RTX 3090 hardware and design optimized local inference stack to enable larger/faster models for Commitment, reducing dependence on external inference APIs.

## Current Stage
- Operator confirmed RTX 3090 is for local workloads to increase model size/processing speed
- Constraint information partially answered: $10/day inference budget cap, high risk tolerance, no need to worry about compute costs
- Hardware spec identified: 24GB VRAM, local-first architecture
- Remaining gating questions: physical placement, interruption tolerance, data sensitivity

## Important Findings
- Planner identified highest-leverage move: acquire RTX 3090 and build local inference stack
- Local GPU reduces API dependence (3090 fits ~30B quantized models)
- Hardware acquisition should proceed with reasonable defaults
- Fear of Commitment will enforce operator-set bounds but bounds not yet codified
- Physical constraints remain the key unknown that could affect hardware placement

## Next Move
1. Create defaults document stating assumptions about constraints and place in requests/processed/
2. Proceed immediately with RTX 3090 acquisition research:
   - Price, condition, supplier options
   - Model sizing for 24GB VRAM (quantized ~30B models)
   - Software stack selection (vLLM, llama.cpp, Ollama)
   - Total cost of ownership estimation (electricity ~350W)
3. Send consolidated follow-up question about remaining gating constraints:
   - Physical placement (where, always-on potential)
   - Interruption tolerance requirements
   - Data sensitivity boundaries
4. Design parallel benchmarking approach for candidate models once hardware parameters are known
