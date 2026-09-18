# Fear of Commitment Architecture

## Core Components

### 1. Observer Core
- Main event loop
- Module loading and coordination
- Report generation
- State management

### 2. Observation Modules

#### a. Runtime Monitor (src/modules/runtime.js)
- Process tracking (commitment processes)
- Resource usage (CPU, memory, disk, network)
- Process lifecycle events
- Environment variable observation

#### b. Container Monitor (src/modules/containers.js)
- Docker/Podman container lifecycle
- Resource allocation
- Network activity
- Volume mounts

#### c. Git Monitor (src/modules/git.js)
- Repository state observation
- Commit/push/clone operations
- Remote synchronization
- Branch/tag tracking

#### d. Broker Monitor (src/modules/broker.js)
- Secret access patterns
- Credential usage
- Broker process health

#### e. Network Monitor (src/modules/network.js)
- Connection metadata
- API calls (to external services)
- Data volume tracking

## Observability Principles

1. **Non-interference**: Observations do not modify runtime behavior
2. **Temporal correlation**: Events are timestamped and correlated
3. **State preservation**: Reports can be exported and analyzed
4. **Modular design**: Modules can be enabled/disabled independently

## Data Flow

```
Events → Modules → Central Observer → Reports
```

Each module emits events with:
- timestamp
- module type
- event type
- metadata (process IDs, filenames, sizes, etc.)
- (optional) associated data

## Implementation Strategy

1. Start with basic process observation
2. Add container monitoring
3. Implement Git observation
4. Add secret broker monitoring
5. Implement network observation
6. Create report generation
7. Add configuration system