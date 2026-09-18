# CURRENT

## Now
Active work: RTX 3090 acquisition and local inference stack design

## Objective
Acquire RTX 3090 hardware and design optimized local inference stack to enable larger/faster models for Commitment, reducing dependence on external inference APIs.

## Current Stage
- Operator confirmed RTX 3090 is for local workloads to increase model size/processing speed
- Hardware spec identified: 24GB VRAM, local-first architecture
- Physical placement constraints answered: GPU will be in local machine, can run continuously
- Power constraints: No real constraints (currently plugged into wall at operator's house)
- Interruption tolerance: Frequent interruptions are tolerable; state persistence depends on git commits
- Data sensitivity: Credentials/secrets/private data must not leave local hardware unless explicitly authorized; no compliance requirements
- Fear of Commitment bounds specified: No spend without authority, no credential exposure, no privilege expansion, monitoring should observe not interfere

## Important Findings
- Planner identified highest-leverage move: acquire RTX 3090 and build local inference stack
- Local GPU reduces API dependence (3090 fits ~30B quantized models)
- Hardware acquisition should proceed with reasonable defaults per operator's high risk tolerance
- Current architecture: ephemeral container with no state beyond Git repo; state persistence via durable files and commits
- Physical constraints clarified: always-on capability confirmed, no power limitations, home network environment
- Security boundaries: credentials/secrets/private data protected; public research can use external services
- Fear of Commitment bounds now clearer for implementation
- Comprehensive RTX 3090 market research completed showing price ranges from $750 (used) to $2,500 (new)
- Software stack evaluation completed: llama.cpp for single-user, vLLM for multi-user, Ollama for simplicity
- Local inference architecture designed with opportunistic scheduling and hybrid CPU-GPU offloading

## Next Move
1. completed: Research and document RTX 3090 acquisition options:
   - Price, condition, supplier comparison (completed)
   - Model sizing for 24GB VRAM (quantized ~30B models) (completed)
   - Software stack options: vLLM, llama.cpp, Ollama (completed)
   - Total cost of ownership estimation (electricity ~350W, no circuit concerns) (completed)
2. completed: Design local inference architecture considering:
   - Opportunistic scheduling for shared GPU access (completed)
   - State persistence via git commits (completed)
   - Data sensitivity boundaries per operator guidance (completed)
3. in-progress: Create Fear of Commitment implementation plan based on operator-specified bounds:
   - No spend beyond granted authority
   - No credential exposure
   - No privilege expansion
   - Monitoring/observation vs enforcement approach
4. completed: Benchmark candidate models with 24GB VRAM constraints (completed)
5. next: Document comprehensive analysis in CURRENT.md and mark active work as completed

