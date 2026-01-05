# Cached Interactor Wrapper Implementation Plan

## Overview

Provide an opt-in `Cached` higher-order interactor that caches its child interactor, solving the problem where stateful interactors like `Debounce` are recreated on every `body` access. Users explicitly wrap interactors that need caching, giving them full control over cache lifecycle and invalidation.

## Current State Analysis

### The Problem

**File**: `Sources/UnoArchitecture/Domain/Interactor.swift:72-76`

```swift
extension Interactor where Body: Interactor<DomainState, Action> {
    public func interact(state: inout DomainState, action: Action) -> Emission<Action> {
        body.interact(state: &state, action: action)  // body recomputed EVERY call
    }
}
```

Every `interact` call accesses the `body` computed property, which rebuilds the entire interactor tree.

### Why This Breaks Debounce

```swift
@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor {
    var body: some InteractorOf<Self> {
        Interact { ... }
            .when(state: \.results, action: \.search) {
                Interactors.Debounce(for: .milliseconds(300)) {  // NEW instance each call
                    SearchQueryInteractor()                       // NEW debouncer each call
                }
            }
    }
}
```

1. User types "n" → `body` accessed → new `Debounce` → new `Debouncer` (generation=0)
2. User types "e" → `body` accessed → new `Debounce` → new `Debouncer` (generation=0)
3. Both debouncers think they're the first call, both fire after 300ms

### Why Tests Pass

Tests create Debounce outside the body and store it:

```swift
let debounced = Interactors.Debounce(...) { CounterInteractor() }  // Created ONCE
let harness = InteractorTestHarness(interactor: debounced)         // Same instance reused
```

### Key Discoveries

- Body is a computed property, rebuilt on every access
- Stateful interactors (Debounce) need identity persistence across calls
- Automatic macro-level caching is complex due to opaque types and conditional bodies
- An explicit opt-in wrapper is simpler and gives users control

## Desired End State

After implementation:

1. **`Interactors.Cached` wrapper available** - Opt-in caching for any interactor
2. **Simple key-based invalidation** - Cache rebuilds when key changes
3. **Type-preserving** - Uses generics, no type erasure required
4. **Thread-safe** - Safe for concurrent access
5. **Explicit and predictable** - Users control when caching happens

### Verification

```swift
@Interactor<State, Action>
struct MyInteractor {
    var featureEnabled: Bool

    var body: some InteractorOf<Self> {
        Interact { ... }
            .when(state: \.results, action: \.search) {
                Interactors.Cached(key: featureEnabled) {
                    Interactors.Debounce(for: .milliseconds(300)) {
                        SearchQueryInteractor()
                    }
                }
            }
    }
}

// Behavior:
// - First access: builds and caches Debounce + SearchQueryInteractor
// - Subsequent accesses with same key: returns cached interactor
// - When featureEnabled changes: rebuilds with new key
```

## What We're NOT Doing

- **Not implementing automatic macro-level caching** - Too complex, opaque type issues
- **Not implementing automatic dependency tracking** - Requires observation machinery
- **Not making this the default** - Explicit opt-in keeps behavior predictable
- **Not type-erasing** - Generic wrapper preserves concrete types

## Risks and Mitigations

### Risk 1: Stale Cache Key (MEDIUM)

**Problem**: User forgets to include a dependency in the cache key:

```swift
Interactors.Cached(key: featureA) {  // Forgot featureB!
    if featureA && featureB { ... }
}
```

**Impact**: Cache not invalidated when `featureB` changes.

**Mitigation**:
- Document that ALL dependencies affecting the cached interactor must be in the key
- Consider a tuple-based key: `key: (featureA, featureB)`

### Risk 2: Thread Safety (MEDIUM)

**Problem**: Multiple threads could race to initialize or invalidate the cache.

**Impact**: Double initialization, stale reads.

**Mitigation**: Use lock-protected cache operations (included in implementation).

### Risk 3: Memory Retention (LOW)

**Problem**: Cached interactor holds references to captured dependencies.

**Impact**: Dependencies retained for cache lifetime.

**Mitigation**:
- Cache lifetime tied to `Cached` wrapper lifetime
- Invalidation on key change releases old cached interactor
- This is expected behavior for caching

### Risk 4: Key Equality Semantics (LOW)

**Problem**: Complex keys might have unexpected equality behavior.

**Impact**: Cache invalidates unexpectedly or not at all.

**Mitigation**:
- Require `Key: Equatable`
- Document that keys should be simple value types
- Recommend using tuples or structs with value semantics

## Implementation Approach

Create a simple `Interactors.Cached` higher-order interactor that wraps any child interactor and caches it. Users explicitly opt-in to caching where needed.

The key insight is using the **Box pattern**: a reference-type wrapper stored as a `let` property inside the value-type `Cached` struct. This allows the cache to persist across struct copies and `body` recomputation.

```swift
// Usage:
var body: some InteractorOf<Self> {
    Interact { ... }
        .when(state: \.results, action: \.search) {
            Interactors.Cached(key: featureEnabled) {
                Interactors.Debounce(for: .milliseconds(300)) {
                    SearchQueryInteractor()
                }
            }
        }
}
```

---

## Phase 1: Implement Cached Wrapper

### Overview

Create the `Interactors.Cached` higher-order interactor with key-based cache invalidation.

### Changes Required

#### 1. Create Cached Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Cached.swift` (new file)

```swift
import Foundation

extension Interactors {
    /// A higher-order interactor that caches its child interactor.
    ///
    /// Use this wrapper around stateful interactors (like `Debounce`) that need
    /// to persist across multiple `body` accesses. The cache invalidates when
    /// the key changes.
    ///
    /// ## Example
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     Interact { ... }
    ///         .when(state: \.results, action: \.search) {
    ///             Interactors.Cached(key: searchConfig) {
    ///                 Interactors.Debounce(for: .milliseconds(300)) {
    ///                     SearchQueryInteractor()
    ///                 }
    ///             }
    ///         }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - key: A value that determines cache validity. When it changes, the
    ///          child interactor is rebuilt. Use `()` for unconditional caching.
    ///   - content: A closure that builds the child interactor.
    public struct Cached<Key: Equatable & Sendable, Child: Interactor>: Interactor, Sendable
    where Child: Sendable {
        public typealias DomainState = Child.DomainState
        public typealias Action = Child.Action

        private let _cache: CacheBox<Key, Child>
        private let key: Key
        private let build: @Sendable () -> Child

        public init(
            key: Key,
            @InteractorBuilder<DomainState, Action> content: @escaping @Sendable () -> Child
        ) {
            self._cache = CacheBox()
            self.key = key
            self.build = content
        }

        public var body: some InteractorOf<Self> {
            self
        }

        public func interact(
            state: inout DomainState,
            action: Action
        ) -> Emission<Action> {
            let child = _cache.getOrBuild(key: key, build: build)
            return child.interact(state: &state, action: action)
        }
    }
}

// MARK: - Convenience initializer for unconditional caching

extension Interactors.Cached where Key == Void {
    /// Creates a cached wrapper that never invalidates.
    ///
    /// Use this when the child interactor has no dependencies that could change.
    ///
    /// ```swift
    /// Interactors.Cached {
    ///     Interactors.Debounce(for: .milliseconds(300)) {
    ///         SearchQueryInteractor()
    ///     }
    /// }
    /// ```
    public init(
        @InteractorBuilder<DomainState, Action> content: @escaping @Sendable () -> Child
    ) {
        self.init(key: (), content: content)
    }
}

// MARK: - Cache Box (Reference-type storage)

private final class CacheBox<Key: Equatable & Sendable, Child: Sendable>: @unchecked Sendable {
    private var cachedKey: Key?
    private var cachedValue: Child?
    private let lock = NSLock()

    init() {}

    func getOrBuild(key: Key, build: () -> Child) -> Child {
        lock.lock()
        defer { lock.unlock() }

        if let cachedKey, let cachedValue, cachedKey == key {
            return cachedValue
        }

        let value = build()
        cachedKey = key
        cachedValue = value
        return value
    }
}
```

### Success Criteria

#### Automated Verification:
- [ ] `swift build` compiles successfully
- [ ] New file is properly included in package

---

## Phase 2: Add Cached Wrapper Tests

### Overview

Add comprehensive tests for the `Cached` wrapper.

### Changes Required

#### 1. Add Cached Tests

**File**: `Tests/UnoArchitectureTests/DomainTests/InteractorTests/CachedInteractorTests.swift` (new file)

```swift
import Clocks
import Foundation
import Testing

@testable import UnoArchitecture

@Suite(.serialized)
@MainActor
struct CachedInteractorTests {

    @Test
    func cachedInteractorReturnsSameInstanceAcrossCalls() async throws {
        var instanceCount = 0
        let cached = Interactors.Cached {
            CountingInteractor(onInit: { instanceCount += 1 })
        }

        var state = TestState()

        // Multiple interact calls
        _ = cached.interact(state: &state, action: .trigger)
        _ = cached.interact(state: &state, action: .trigger)
        _ = cached.interact(state: &state, action: .trigger)

        // Child was only created once
        #expect(instanceCount == 1)
    }

    @Test
    func cachedInteractorInvalidatesOnKeyChange() async throws {
        var instanceCount = 0
        var key = "initial"

        func makeInteractor() -> Interactors.Cached<String, CountingInteractor> {
            Interactors.Cached(key: key) {
                CountingInteractor(onInit: { instanceCount += 1 })
            }
        }

        var state = TestState()

        // First call with initial key
        _ = makeInteractor().interact(state: &state, action: .trigger)
        #expect(instanceCount == 1)

        // Same key - should reuse cache
        _ = makeInteractor().interact(state: &state, action: .trigger)
        #expect(instanceCount == 1)

        // Change key - should rebuild
        key = "changed"
        _ = makeInteractor().interact(state: &state, action: .trigger)
        #expect(instanceCount == 2)
    }

    @Test
    func cachedDebounceActuallyDebounces() async throws {
        let clock = TestClock()
        let effectCounter = Counter()

        let cached = Interactors.Cached {
            Interactors.Debounce(for: .milliseconds(300), clock: clock) {
                EffectCountingInteractor(counter: effectCounter)
            }
        }

        var state = TestState()

        // Rapid fire actions
        _ = cached.interact(state: &state, action: .trigger)
        _ = cached.interact(state: &state, action: .trigger)
        let emission = cached.interact(state: &state, action: .trigger)

        // All state changes happened
        #expect(state.count == 3)

        // No effects yet
        #expect(await effectCounter.value == 0)

        // Advance past debounce window
        await clock.advance(by: .milliseconds(300))

        // Execute the effect
        if case .perform(let work) = emission.kind {
            _ = await work()
        }

        // Only ONE effect fired
        #expect(await effectCounter.value == 1)
    }

    @Test
    func separateCachedInstancesAreSeparate() async throws {
        var instanceCount1 = 0
        var instanceCount2 = 0

        let cached1 = Interactors.Cached {
            CountingInteractor(onInit: { instanceCount1 += 1 })
        }

        let cached2 = Interactors.Cached {
            CountingInteractor(onInit: { instanceCount2 += 1 })
        }

        var state = TestState()

        _ = cached1.interact(state: &state, action: .trigger)
        _ = cached2.interact(state: &state, action: .trigger)

        #expect(instanceCount1 == 1)
        #expect(instanceCount2 == 1)
    }
}

// MARK: - Test Helpers

private struct TestState: Equatable, Sendable {
    var count = 0
}

private enum TestAction: Sendable, Equatable {
    case trigger
    case effectCompleted
}

private struct CountingInteractor: Interactor, Sendable {
    typealias DomainState = TestState
    typealias Action = TestAction

    let onInit: @Sendable () -> Void

    init(onInit: @escaping @Sendable () -> Void) {
        self.onInit = onInit
        onInit()
    }

    var body: some InteractorOf<Self> { self }

    func interact(state: inout TestState, action: TestAction) -> Emission<TestAction> {
        state.count += 1
        return .none
    }
}

private struct EffectCountingInteractor: Interactor, Sendable {
    typealias DomainState = TestState
    typealias Action = TestAction

    let counter: Counter

    var body: some InteractorOf<Self> { self }

    func interact(state: inout TestState, action: TestAction) -> Emission<TestAction> {
        switch action {
        case .trigger:
            state.count += 1
            return .perform { [counter] in
                await counter.increment()
                return .effectCompleted
            }
        case .effectCompleted:
            return .none
        }
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
```

### Success Criteria

#### Automated Verification:
- [ ] `swift test --filter CachedInteractorTests` - all tests pass

---

## Phase 3: Update Search Example

### Overview

Update the Search example to use `Interactors.Cached` around the Debounce wrapper.

### Changes Required

#### 1. Add Cached wrapper in SearchInteractor

**File**: `Examples/Search/Search/Architecture/SearchInteractor.swift`

Remove the manual `BodyCache` workaround and use `Interactors.Cached`:

```swift
@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor: Sendable {
    private let weatherService: WeatherService

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
    }

    var body: some InteractorOf<Self> {
        Interact { state, event in
            // ... existing event handling ...
        }
        .when(state: \.results, action: \.search) {
            Interactors.Cached {
                Interactors.Debounce(for: .milliseconds(300)) {
                    SearchQueryInteractor(weatherService: weatherService)
                }
            }
        }
    }
}
```

#### 2. Clean up SearchQueryInteractor

**File**: `Examples/Search/Search/Architecture/SearchQueryInteractor.swift`

Remove any manual debouncer storage if present:

```swift
@Interactor<SearchDomainState.ResultState, SearchQueryEvent>
struct SearchQueryInteractor: Sendable {
    private let weatherService: WeatherService

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
    }

    var body: some InteractorOf<Self> {
        Interact { state, event in
            // ... existing logic ...
        }
    }
}
```

### Success Criteria

#### Automated Verification:
- [ ] `swift build` compiles the Search example

#### Manual Verification:
- [ ] Run Search app, type rapidly in search box
- [ ] Verify only one API call fires after typing stops
- [ ] Verify results match final query text

---

## Phase 4: Documentation

### Overview

Document the `Cached` wrapper usage.

### Changes Required

#### 1. Add documentation to Cached.swift

Already included in the Phase 1 implementation.

#### 2. Update Debounce documentation

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift`

Add a note about using with `Cached`:

```swift
/// ## Usage in Body
///
/// When using `Debounce` inside an interactor's `body` property, wrap it
/// with `Interactors.Cached` to ensure the debouncer persists across
/// body recomputation:
///
/// ```swift
/// var body: some InteractorOf<Self> {
///     Interact { ... }
///         .when(state: \.search, action: \.search) {
///             Interactors.Cached {
///                 Interactors.Debounce(for: .milliseconds(300)) {
///                     SearchQueryInteractor()
///                 }
///             }
///         }
/// }
/// ```
```

### Success Criteria

#### Automated Verification:
- [ ] `swift build` compiles successfully

---

## Testing Strategy

### Unit Tests

1. **CachedInteractorTests** - Cache persistence, key invalidation, thread safety
2. **Debounce integration** - Verify debouncing works when wrapped with Cached

### Manual Testing Steps

1. Run Search example app
2. Type "new york" rapidly in search field
3. Verify network inspector shows only 1 API call (after typing stops)
4. Verify results show "New York" locations
5. Clear and repeat to verify consistent behavior

---

## Migration Notes

### Breaking Changes

**None** - This is a new opt-in feature.

### Upgrade Path

1. Add `Interactors.Cached { }` wrapper around stateful interactors like `Debounce`
2. If you have conditional body structures, add dependencies to the cache key
3. Remove any manual debouncer injection workarounds

---

## Risk Summary

| Risk | Severity | Mitigation |
|------|----------|------------|
| Stale cache key | MEDIUM | Document that all dependencies must be in key |
| Thread safety | LOW | Lock-protected cache operations |
| Memory retention | LOW | Expected behavior for caching |

---

## References

- Debounce interactor: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift`
- Debouncer: `Sources/UnoArchitecture/Internal/Debouncer.swift`
- Search example: `Examples/Search/Search/Architecture/SearchInteractor.swift`

---

## Summary

| Phase | Description | Key Files |
|-------|-------------|-----------|
| 1 | Implement Cached wrapper | `Cached.swift` (new) |
| 2 | Add tests | `CachedInteractorTests.swift` (new) |
| 3 | Update Search example | `SearchInteractor.swift` |
| 4 | Documentation | `Cached.swift`, `Debounce.swift` |

**New Files**: 2
**Modified Files**: 2

---

## Alternative Approaches Considered

During the design of this solution, several alternative approaches were explored:

### Option A: Automatic Macro-Level Caching

**Approach**: Modify the `@Interactor` macro to automatically cache the `body` property.

```swift
// Macro would transform this:
@Interactor<State, Action>
struct MyInteractor {
    var body: some InteractorOf<Self> { ... }
}

// Into this:
struct MyInteractor {
    private let _bodyCache = BodyCache<State, Action>()
    private var _uncachedBody: some InteractorOf<Self> { ... }
    var body: some InteractorOf<Self> {
        _bodyCache.getOrSet { _uncachedBody.eraseToAnyInteractor() }
    }
}
```

**Pros**:
- Zero effort for users - "it just works"
- All stateful interactors benefit automatically

**Cons**:
- Requires type erasure to `AnyInteractor` (opaque types can't be stored)
- Conditional bodies become stale (no way to detect dependency changes)
- Struct copies share cached body (surprising behavior)
- Complex macro implementation

**Why Rejected**: The conditional body problem is a fundamental issue. If a body has `if featureEnabled { A() } else { B() }`, automatic caching would lock in whichever branch was taken first.

### Option B: Observation-Based Automatic Invalidation

**Approach**: Use Swift's Observation framework to automatically track which properties the body accesses and invalidate when they change.

```swift
@Observable @Interactor<State, Action>
struct MyInteractor {
    var featureEnabled: Bool  // Automatically tracked

    var body: some InteractorOf<Self> {
        if featureEnabled { A() } else { B() }  // Access detected
    }
}
```

**Pros**:
- Automatic dependency tracking
- Cache invalidates correctly when dependencies change

**Cons**:
- Swift's Observation only works with classes, not structs
- Would require fundamental architecture change
- Significant complexity in macro implementation
- Still has the type erasure problem

**Why Rejected**: The struct-incompatibility is a blocker, and the complexity doesn't justify the benefit over explicit key-based caching.

### Option C: Identity-Based Debouncer Registry

**Approach**: Store debouncers in a global/singleton registry keyed by call site identity.

```swift
// Debouncer would use #fileID and #line to create stable identity
Interactors.Debounce(for: .milliseconds(300)) {  // #fileID:#line = "Search.swift:42"
    SearchQueryInteractor()
}
```

**Pros**:
- No wrapper needed
- Works for Debounce specifically

**Cons**:
- Global state is problematic for testing
- Doesn't generalize to other stateful interactors
- Identity can be confusing in loops or generic contexts
- Memory management complexity

**Why Rejected**: Global state makes testing difficult and the solution doesn't generalize.

### Chosen: Explicit Cached Wrapper

The `Interactors.Cached` wrapper was chosen because:
- **Explicit is better than implicit** - Users know exactly what's being cached
- **Key-based invalidation is simple** - Users control when cache rebuilds
- **No macro changes** - Simpler implementation, fewer surprises
- **Generalizes** - Works for any interactor, not just Debounce
- **Easy to reason about** - Cache lifetime tied to wrapper lifetime
