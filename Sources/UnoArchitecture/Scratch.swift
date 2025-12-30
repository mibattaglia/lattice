import Foundation

// MARK: - Actor Isolation Demonstration for Emission.perform with _DynamicState

// This file demonstrates how actor isolation works with _DynamicState
// in the context of .perform emissions.

// MARK: - Core Types (Simplified for demonstration)

/// Holds mutable state on the MainActor.
/// All reads and writes are synchronized through MainActor isolation.

/// Provides read-only access to state from non-isolated contexts.
/// The async getter automatically hops to MainActor for each read.
@dynamicMemberLookup
struct _DynamicState<State>: Sendable {
    private let getCurrentState: @Sendable () async -> State

    init(getCurrentState: @escaping @Sendable () async -> State) {
        self.getCurrentState = getCurrentState
    }

    subscript<T>(dynamicMember keyPath: KeyPath<State, T>) -> T {
        get async {
            await getCurrentState()[keyPath: keyPath]
        }
    }

    var current: State {
        get async {
            await getCurrentState()
        }
    }
}

// MARK: - Demonstration

struct DemoState: Sendable {
    var count: Int
    var items: [String]
}

/// Demonstrates the actor isolation flow:
///
/// 1. Effect closure runs on cooperative thread pool (NOT MainActor)
/// 2. Reading state via `await currentState.count` hops TO MainActor
/// 3. Emitting state via `await send(...)` hops TO MainActor
/// 4. Effect resumes on cooperative thread pool after each await
//@MainActor
func demonstrateActorIsolation() async {
    let stateBox = await StateBox(DemoState(count: 0, items: []))

    // This is how _DynamicState is constructed in Interact.interact()
    // The closure captures stateBox and reads from MainActor
    let state = _DynamicState {
        await MainActor.run { stateBox.value }
    }

    // This is how Send is constructed
    let send = await Send<DemoState> { newState in
        print("[MainActor] Receiving state: count=\(newState.count)")
        stateBox.value = newState
    }

    // Simulate what happens inside a .perform closure
    // This Task runs on cooperative thread pool, NOT MainActor
    let effectTask = Task {

        // Simulate async work (network call, etc.)
        try? await Task.sleep(for: .milliseconds(100))

        // READ: This await hops to MainActor to read state
        let currentCount = await state.count
        print("[Effect] Read count=\(currentCount) (hopped to MainActor and back)")

        // More async work
        try? await Task.sleep(for: .milliseconds(100))

        // READ AGAIN: State might have changed!
        let freshCount = await state.count
        print("[Effect] Fresh read count=\(freshCount)")

        // EMIT: This await hops to MainActor to emit
        await send(DemoState(count: freshCount + 1, items: ["new item"]))
        print("[Effect] Emitted new state (hopped to MainActor and back)")
    }

    // Meanwhile, on MainActor, state can be modified
    try? await Task.sleep(for: .milliseconds(50))
    await MainActor.run {
        stateBox.value.count = 42
    }
    print("[MainActor] Modified count to 42 while effect is running")

    await effectTask.value
    await print("[MainActor] Final state: count=\(stateBox.value.count)")
}

// MARK: - Key Insight: Why This Works

/*
 The synchronization is implicit in Swift's actor model:

 1. StateBox is @MainActor isolated
    - All access to `stateBox.value` must happen on MainActor

 2. _DynamicState wraps an async closure that does `await MainActor.run { ... }`
    - When called from a non-isolated context, Swift suspends the caller
    - Executes the closure on MainActor
    - Returns control to caller (on cooperative thread pool)

 3. Send is @MainActor isolated
    - When callAsFunction is called from non-isolated context, Swift:
      - Suspends the caller
      - Hops to MainActor
      - Executes the yield closure
      - Returns control to caller

 The "await" keyword is the synchronization point. Every `await` on
 an @MainActor-isolated value is a potential context switch.

 This is safer than manual locking because:
 - Swift compiler enforces actor boundaries at compile time
 - No risk of deadlocks from forgotten unlocks
 - No data races possible (enforced by Sendable)
 */

// MARK: - Comparison: Old vs New .perform Signature

/*
 OLD: .perform { send in ... }
 - Effect could only emit state
 - To read state, had to capture it before starting effect (stale!)

 NEW: .perform { currentState, send in ... }
 - Effect can read fresh state at any point via `await currentState.xxx`
 - Effect can emit state via `await send(...)`
 - Both operations are synchronized through MainActor

 Example scenario where this matters:

 1. User triggers "Add Item" action
 2. Handler captures current items and starts effect
 3. While effect is fetching new item from server...
 4. User triggers "Add Item" again (different item)
 5. Second effect also running
 6. First effect completes, reads FRESH state (includes second item)
 7. First effect emits correctly merged state

 Without _DynamicState, step 6 would use stale captured state,
 potentially losing the second item.
 */
