# Workload Analysis for Computing Resources

## Current Limitations Analysis

### Model Capabilities
- Current model: devstral-small-2-64k (ollama/devstral-small-2-64k)
- Context window: 64k tokens
- Model size: ~5.3B parameters (estimated based on name)
- Architecture: GLM variant

### Observed Session Patterns
From runlog.jsonl analysis:
- Typical session duration: 5-30 minutes
- Most sessions complete within 1-2 hours
- NOOP sessions occur when no actionable work is found
- Work sessions involve file operations, research, and analysis

### Current Bottlenecks (Hypothesized)
1. **Memory limiting**: 64k context window may be restrictive for multi-file analysis
2. **Model capacity**: 5.3B parameters limits complex reasoning
3. **Throughput**: Inference speed may be CPU-bound on local hardware
4. **Multi-tasking**: Limited ability to maintain multiple conversation threads

### Proposed Workload Requirements

#### Immediate Needs (0-3 months)
- **Context window**: 128k-256k for comprehensive multi-file analysis
- **Model size**: 13B-30B parameters for superior reasoning capability
- **Concurrent operations**: Support for 2-4 parallel research threads
- **Session duration**: Maintain 1-2 hour time limit comfortably

#### Medium Term Needs (3-12 months)
- **Model size**: 65B-100B parameters for advanced problem solving
- **RAM**: 64GB+ for large context windows and data processing
- **Long-running tasks**: Support sustained multi-day research projects
- **Multi-model support**: Access to specialized Models for different tasks

## Decision Matrix

| Option | Description | VRAM | RAM | Inference Speed | Cost (Monthly) | Interruption Risk | Setup Complexity | Trust Risk |
|--------|-------------|------|-----|-----------------|----------------|-------------------|------------------|-----------|
| Used RTX 3090 | Local DIY build | 24GB | Varies | Medium | ~$15-$40 (elec) | None | High (physical) | Low |
| Cloud Inference | RunPod/Vast.ai | Variable | Variable | High | $50-$300 | Medium | Low | Medium |
| Spot Instances | AWS/GCP/Azure | Variable | Variable | High | $20-$150 | High | Medium | Low |
| RAM Box Only | 64GB RAM Epyc/Ryzen | 0GB | 64GB+ | Fast (CPU) | ~$5-$20 | None | Medium | Low |
| Hybrid Approach | Combined local + cloud | Combined | Combined | Highest | Variable | Variable | High | Medium |

## Recommended Research Path

1. **Immediate action**: Create workload specification document
2. **Identify budget constraints from operator**
3. **Research specific hardware options** based on operator's constraints
4. **Develop decision criteria**: cost, performance, reliability, ease of use
5. **Prepare procurement recommendation** with multiple viable options
