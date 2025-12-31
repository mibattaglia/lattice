# Phase 6: Cleanup & Documentation - Implementation Plan

## Overview

Phase 6 is the final phase. Its goal is to remove all legacy Combine code, update documentation, and create an Architecture Decision Record (ADR) documenting the migration rationale.

**Prerequisites:** Phases 1-5 must be complete.

---

## Phase 6a: File Deletions

### Files to Delete

**Internal Combine Directory (delete entire directory):**
```
Sources/UnoArchitecture/Internal/Combine/
  - Combine+FeedbackLoop.swift
  - Combine+Async.swift
```

**Extensions Directory:**
```
Sources/UnoArchitecture/Extensions/
  - Combine+Arch.swift
```

### Implementation Steps

```bash
# Verify no remaining references
grep -r "Combine+FeedbackLoop" Sources/
grep -r "Combine+Async" Sources/
grep -r "Publishers.Async" Sources/
grep -r "\.feedback(" Sources/

# Delete files
rm -rf Sources/UnoArchitecture/Internal/Combine/
rm Sources/UnoArchitecture/Extensions/Combine+Arch.swift

# Verify build
swift build
```

---

## Phase 6b: Verify No Combine Imports Remain

### Files to Verify

After Phases 1-5, verify no `import Combine` or `import CombineSchedulers` remain:

```bash
grep -r "^import Combine" Sources/UnoArchitecture/
grep -r "^import CombineSchedulers" Sources/UnoArchitecture/

# Check for Combine-specific types
grep -r "AnyPublisher" Sources/UnoArchitecture/
grep -r "PassthroughSubject" Sources/UnoArchitecture/
grep -r "CurrentValueSubject" Sources/UnoArchitecture/
grep -r "AnyCancellable" Sources/UnoArchitecture/
grep -r "AnySchedulerOf" Sources/UnoArchitecture/
```

All commands should return empty results.

---

## Phase 6c: Update Package.swift

### Remove CombineSchedulers Dependency

**Current:**
```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-async-algorithms", ...),
    .package(url: "https://github.com/pointfreeco/combine-schedulers", ...),  // REMOVE
    ...
],
targets: [
    .target(
        name: "UnoArchitecture",
        dependencies: [
            .product(name: "CombineSchedulers", package: "combine-schedulers"),  // REMOVE
            ...
        ]
    ),
```

**After:**
```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-async-algorithms", ...),
    // combine-schedulers REMOVED
    ...
],
targets: [
    .target(
        name: "UnoArchitecture",
        dependencies: [
            // CombineSchedulers REMOVED
            ...
        ]
    ),
```

### Verification

```bash
swift package resolve
swift build
swift test
```

---

## Phase 6d: Update README.md

Replace with comprehensive documentation:

```markdown
# UnoArchitecture

A lightweight, pure Swift library for building complex features using MVVM with unidirectional data flow. Built on Swift's native async/await and AsyncStream.

## Features

- **Unidirectional Data Flow**: Actions flow in, state flows out
- **AsyncStream-Based**: Native Swift concurrency
- **Declarative Composition**: Result builders for composing interactors
- **Type-Safe**: Strong generic constraints
- **Testable**: First-class testing support with TestClock and AsyncStreamRecorder
- **SwiftUI Integration**: @ViewModel macro for seamless view binding

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/[org]/swift-uno-architecture", from: "1.0.0")
]
```

## Quick Start

### Define Domain State and Actions

```swift
struct CounterState: Sendable {
    var count: Int = 0
}

enum CounterAction {
    case increment
    case decrement
}
```

### Create an Interactor

```swift
@Interactor<CounterState, CounterAction>
struct CounterInteractor {
    var body: some InteractorOf<Self> {
        Interact(initialValue: CounterState()) { state, action in
            switch action {
            case .increment: state.count += 1
            case .decrement: state.count -= 1
            }
            return .state
        }
    }
}
```

### Create a ViewModel

```swift
@ViewModel<CounterViewState, CounterAction>
final class CounterViewModel {
    init(interactor: AnyInteractor<CounterState, CounterAction>) {
        self.viewState = .initial
        #subscribe { builder in
            builder.interactor(interactor)
        }
    }
}
```

## Architecture

```
┌─────────────────────┐
│     SwiftUI View    │
└─────────┬───────────┘
          │ sendViewEvent()
          ▼
┌─────────────────────┐
│     ViewModel       │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│     Interactor      │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│  ViewStateReducer   │
└─────────────────────┘
```

## Requirements

- iOS 16.0+ / macOS 14.0+
- Swift 6.0+
- Xcode 16.0+
```

---

## Phase 6e: Create ADR Documentation

### Create ADR Directory

```bash
mkdir -p docs/adr
```

### Create ADR-001

**File**: `docs/adr/001-combine-to-asyncstream-migration.md`

```markdown
# ADR-001: Migration from Combine to AsyncStream

## Status

Accepted

## Date

2025-12-30

## Context

The UnoArchitecture library was initially built using Apple's Combine framework for reactive stream processing. The core `Interactor` protocol transformed `AnyPublisher<Action, Never>` into `AnyPublisher<DomainState, Never>`.

### Problems with Combine

1. **Learning Curve**: Combine's Publisher model is complex
2. **Verbosity**: Type erasure required everywhere
3. **Semi-Deprecated**: Not receiving active development
4. **Debugging Difficulty**: Stack traces lost in Combine chains
5. **Resource Management**: AnyCancellable patterns are error-prone
6. **Swift 6 Compatibility**: Doesn't integrate with actors

### Alternatives Considered

1. **Keep Combine**: Maintain status quo
2. **Hybrid Adapter**: Bridge incrementally
3. **Direct AsyncStream Replacement** (Chosen)

## Decision

Direct AsyncStream Replacement because:

1. **Library Under Development**: No backward compatibility needed
2. **Clean Architecture**: Single paradigm
3. **Native Swift**: Idiomatic concurrency model
4. **Better Tooling**: Improved debugging
5. **Swift 6 Ready**: First-class actor support

### Key Technical Decisions

1. `AsyncStream<State>` over `some AsyncSequence`
2. `@MainActor` isolation for Interactor protocol
3. `Send` callback pattern for effects
4. swift-async-algorithms for operators
5. `Clock` protocol replaces CombineSchedulers

## Consequences

### Positive

- Simpler mental model
- Better debugging
- Reduced dependencies
- Native Swift patterns

### Negative

- Breaking API change
- Team learning curve

## References

- [System Design](../thoughts/shared/plans/async-stream-migration/system-design.md)
- [MainActor Send Pattern](../thoughts/shared/plans/async-stream-migration/main-actor-send-pattern.md)
```

---

## Phase 6f: Verification Checklist

### Automated Verification

```bash
# Build succeeds
swift build

# All tests pass
swift test

# No Combine imports in library
grep -r "^import Combine" Sources/UnoArchitecture/
# Expected: No output

# No CombineSchedulers imports
grep -r "^import CombineSchedulers" Sources/UnoArchitecture/
# Expected: No output

# Internal/Combine directory deleted
ls Sources/UnoArchitecture/Internal/Combine/
# Expected: No such file or directory

# Combine+Arch.swift deleted
ls Sources/UnoArchitecture/Extensions/Combine+Arch.swift
# Expected: No such file or directory

# No combine-schedulers in Package.swift
grep "combine-schedulers" Package.swift
# Expected: No output

# Example builds and tests pass
cd Examples/Search && xcodebuild -scheme Search build test
```

---

## Success Criteria

Phase 6 is complete when:

1. **No unused Combine code remains**
   - Internal/Combine/ directory deleted
   - Combine+Arch.swift deleted
   - No `import Combine` in library sources
   - No `import CombineSchedulers` in library sources

2. **Documentation reflects current implementation**
   - README updated with AsyncStream patterns
   - API examples use new signatures

3. **ADR captures decision rationale**
   - ADR-001 created in docs/adr/
   - Documents context, decision, consequences

4. **All verification passes**
   - `swift build` succeeds
   - `swift test` passes
   - Example project builds and tests

---

## Files Summary

### Files to Delete

| Path | Reason |
|------|--------|
| `Sources/.../Internal/Combine/Combine+FeedbackLoop.swift` | Replaced by AsyncStream feedback loop |
| `Sources/.../Internal/Combine/Combine+Async.swift` | Publishers.Async no longer needed |
| `Sources/.../Extensions/Combine+Arch.swift` | Combine operators replaced |

### Files to Modify

| Path | Change |
|------|--------|
| `Package.swift` | Remove combine-schedulers |
| `README.md` | Complete rewrite |

### Files to Create

| Path | Purpose |
|------|---------|
| `docs/adr/001-combine-to-asyncstream-migration.md` | ADR |

---

## Critical Files for Implementation

| File | Purpose |
|------|---------|
| `Sources/.../Internal/Combine/Combine+FeedbackLoop.swift` | Primary deletion target |
| `Sources/.../Internal/Combine/Combine+Async.swift` | Deletion target |
| `Sources/.../Extensions/Combine+Arch.swift` | Deletion target |
| `Package.swift` | Remove CombineSchedulers |
| `README.md` | Documentation rewrite |
