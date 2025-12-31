# Phase 3.1: Adopt Point-Free's swift-clocks Library

## Overview

Replace our custom `TestClock` and `TestInstant` implementations with Point-Free's battle-tested [swift-clocks](https://github.com/pointfreeco/swift-clocks) library. This eliminates actor re-entrancy issues and provides a proven, well-maintained testing infrastructure.

## Current State Analysis

**Problem**: Our `TestClock` is an actor, which causes re-entrancy issues:
- When `advance(by:)` is called, it's an async operation through the actor's serial queue
- Rapid emissions (e.g., debounce tests with multiple actions) can interleave unpredictably
- Actor suspension points make deterministic testing difficult

**Current Files**:
- `Sources/UnoArchitecture/Testing/TestClock.swift` - Actor-based clock (problematic)
- `Sources/UnoArchitecture/Testing/TestInstant.swift` - Custom instant type

**Point-Free's Solution**:
- `TestClock` is a `final class` with `@unchecked Sendable` and `NSRecursiveLock`
- Manual synchronization gives precise control over suspension points
- Includes `Task.megaYield()` patterns for reliable async testing
- Already used by TCA and other major Swift projects

## Desired End State

**Dependency**: Add `swift-clocks` package
**Removed Files**: `TestClock.swift`, `TestInstant.swift`
**Updated Tests**: Use `Clocks.TestClock` from swift-clocks

### Verification

```bash
swift build
swift test --filter DebounceTests
swift test --filter TestClockTests
```

## What We're NOT Doing

- Modifying `AsyncStreamRecorder` (still useful, works well)
- Modifying `InteractorTestHarness` (still useful, works well)
- Changing the `Debounce` interactor API (already generic over `Clock`)
- Adding ImmediateClock usage (future enhancement)

---

## Implementation Steps

### Step 1: Add swift-clocks Dependency

**File**: `Package.swift`

Add to dependencies array:
```swift
.package(
    url: "https://github.com/pointfreeco/swift-clocks",
    .upToNextMajor(from: "1.0.0")
),
```

Add to UnoArchitecture target dependencies:
```swift
.product(name: "Clocks", package: "swift-clocks"),
```

---

### Step 2: Delete Custom TestClock Files

**Delete**:
- `Sources/UnoArchitecture/Testing/TestClock.swift`
- `Sources/UnoArchitecture/Testing/TestInstant.swift`

---

### Step 3: Update Debounce Tests

**File**: `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+DebounceTests.swift`

**Changes**:

1. Add import:
```swift
import Clocks
```

2. Replace `TestClock()` with Point-Free's version. The API is slightly different:
   - Our `TestClock` used `TestInstant(offset:)` for deadlines
   - Point-Free's uses its own `TestClock.Instant` type
   - `pendingSleepersCount` may not be available; use `await clock.advance(by:)` directly

**Updated test pattern**:
```swift
@Test
func debounceDelaysActions() async throws {
    let clock = TestClock()

    let debounced = Interactors.Debounce<TestClock, CounterInteractor>(
        for: .milliseconds(300),
        clock: clock
    ) {
        CounterInteractor()
    }

    let recorder = AsyncStreamRecorder<CounterInteractor.State>()
    let (actionStream, actionCont) = AsyncStream<CounterInteractor.Action>.makeStream()

    recorder.record(debounced.interact(actionStream))

    // Wait for initial state
    try await recorder.waitForEmissions(count: 1, timeout: .seconds(2))
    #expect(recorder.values == [.init(count: 0)])

    // Send action
    actionCont.yield(.increment)

    // Advance past debounce period
    await clock.advance(by: .milliseconds(300))
    try await recorder.waitForEmissions(count: 2, timeout: .seconds(2))
    #expect(recorder.values == [.init(count: 0), .init(count: 1)])

    actionCont.finish()
}

@Test
func debounceCoalescesRapidActions() async throws {
    let clock = TestClock()

    let debounced = Interactors.Debounce<TestClock, CounterInteractor>(
        for: .milliseconds(300),
        clock: clock
    ) {
        CounterInteractor()
    }

    let recorder = AsyncStreamRecorder<CounterInteractor.State>()
    let (actionStream, actionCont) = AsyncStream<CounterInteractor.Action>.makeStream()

    recorder.record(debounced.interact(actionStream))

    // Wait for initial state
    try await recorder.waitForEmissions(count: 1, timeout: .seconds(2))
    #expect(recorder.values == [.init(count: 0)])

    // Send multiple rapid actions
    actionCont.yield(.increment)
    actionCont.yield(.increment)
    actionCont.yield(.increment)

    // Advance past debounce period
    await clock.advance(by: .seconds(1))
    try await recorder.waitForEmissions(count: 2, timeout: .seconds(2))

    // Only one state change because debounce emits only the last value
    #expect(recorder.values == [.init(count: 0), .init(count: 1)])

    actionCont.finish()
}
```

**Key changes**:
- Removed `while await clock.pendingSleepersCount == 0` polling loops
- Point-Free's TestClock handles task scheduling internally with `Task.megaYield()`

---

### Step 4: Update or Remove TestClockTests

**File**: `Tests/UnoArchitectureTests/TestingInfrastructureTests/TestClockTests.swift`

**Option A (Recommended)**: Delete the file entirely since we no longer own the TestClock implementation.

**Option B**: Keep integration tests that verify Point-Free's TestClock works with our patterns:

```swift
import Clocks
import Testing

@testable import UnoArchitecture

@Suite
struct TestClockIntegrationTests {
    @Test
    func advanceByDuration() async {
        let clock = TestClock()
        var woken = false

        Task {
            try? await clock.sleep(for: .seconds(1))
            woken = true
        }

        #expect(!woken)
        await clock.advance(by: .seconds(1))
        #expect(woken)
    }
}
```

---

### Step 5: Re-export TestClock for Convenience (Optional)

**File**: `Sources/UnoArchitecture/Testing/Testing.swift` (NEW, optional)

If we want to provide a single import for tests:
```swift
@_exported import Clocks
```

This allows test files to just `import UnoArchitecture` and get TestClock.

---

## Success Criteria

### Automated Verification:
- [ ] `swift build` succeeds
- [ ] `swift test --filter DebounceTests` passes
- [ ] `swift test --filter TestClockTests` passes (or removed)
- [ ] `swift test` (all tests) passes

### Manual Verification:
- [ ] Debounce tests run deterministically (no flakiness)
- [ ] Rapid action coalescing test passes reliably

---

## Dependencies

- Phase 1 & 2 complete (Interactor protocol, Debounce interactor exist)

## Critical Files

| File | Action |
|------|--------|
| `Package.swift` | Add swift-clocks dependency |
| `Sources/UnoArchitecture/Testing/TestClock.swift` | DELETE |
| `Sources/UnoArchitecture/Testing/TestInstant.swift` | DELETE |
| `Tests/.../Interactors+DebounceTests.swift` | Update imports, remove polling |
| `Tests/.../TestClockTests.swift` | Delete or simplify |

## References

- [swift-clocks GitHub](https://github.com/pointfreeco/swift-clocks)
- [Point-Free Episode #238-242: Reliable Async Tests](https://www.pointfree.co/episodes/ep238-reliable-async-tests-the-problem)
- Phase 3 plan: `thoughts/shared/plans/async-stream-migration/phase-3-testing-infrastructure.md`
