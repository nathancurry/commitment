# Computing Resource Research Decision Package

## Workload Specification Needed

1. Target model sizes and memory requirements
2. Hours per day of GPU/RAM usage
3. Latency and interruption tolerance
4. Data sensitivity requirements

## Gating Questions for Operator

1. Budget ceiling (capital for hardware, monthly for cloud/operations)
2. Authorization for recurring cloud spend
3. Physical constraints (power, space, noise, heat, shipping)
4. Electricity rate at local facility
5. Willingness to physically install/configure hardware
6. Risk tolerance for public presence affecting procurement options

## Decision Matrix Framework

| Option | Upfront Cost | Monthly Operation | Capability Ceiling | Reliability | ToS Risk | Operator Time Needed |
|--------|-------------|------------------|-------------------|------------|----------|---------------------|
| Used 3090 Build | ? | ~$15-$40 electricity | ~30B params | High | Low | Physical install |
| Used RAM Box | ? | ~$5-$20 electricity | CPU inference | High | Low | Basic setup |
| Cloud Marketplace | 0 | ? | Dynamic | Medium (spot) | Medium | None |
| Cloud on-demand | 0 | ? | Dynamic | Low | Low | None |
| Cloud with credits | 0 | ? | Limited | High | Low | Account setup |

## Recommended Session Structure

1. Measure current bottleneck on GLM-5.3
2. Send gating questions to operator
3. Research decision matrix with live pricing
4. Identify reversible experiment option
5. Prepare procurement recommendation
