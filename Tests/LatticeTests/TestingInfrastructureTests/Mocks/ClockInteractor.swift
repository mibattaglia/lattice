import Foundation
import Lattice

// The features the `EffectClock` suites drive: a debounced search, a ticker and a load that waits on
// something other than the clock, all over a generic clock, and a search and a ticker that record
// the order in which their sleeps woke. Declared at file scope, so the interactors and their effect
// literals are nonisolated, as `TestModel` requires.

@FeatureState
struct ClockState: Equatable, Sendable {
    var query = ""
    var results: [String] = []
    var tick = 0
    var isLoaded = false
}

enum ClockAction: Equatable, Sendable {
    /// Debounce by sleep: its effect sleeps for the debounce, then writes `[query.uppercased()]`. The
    /// next `.query` auto-cancels it while it sleeps; `.query("")` starts none.
    case query(String)
    /// `.query` with the sleep spelled another way, which reaches the clock only after a hop off the
    /// model's isolation.
    case bypassQuery(String, SleepSpelling)
    /// The ticker: `while true { sleep for the interval; tick += 1 }`.
    case start
    /// Waits for the load's answer, a suspension that is not the clock's, then sets `isLoaded`.
    case load
}

/// The spellings of a sleep that reach the clock only after hopping off the effect's isolation.
enum SleepSpelling: Equatable, Sendable, CaseIterable {
    /// `clock.sleep(for: d, tolerance: nil)`
    case sleepForTolerance
    /// `clock.sleep(until: clock.now.advanced(by: d), tolerance: nil)` on a generic clock
    case sleepUntilTolerance
    /// `Task.sleep(for: d, clock: clock)`
    case taskSleepForClock
    /// `clock.sleep(for: d)` inside a `@concurrent` function
    case concurrentSleepFor
}

@Interactor<ClockState, ClockAction>
struct ClockInteractor<C: Clock> {
    let clock: C
    let debounce: C.Duration
    let interval: C.Duration
    /// The load's answer, which the test opens.
    var loadGate = Gate()

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .query(let query):
                state.query = query
                guard !query.isEmpty else { return }
                effects.perform {
                    try await clock.sleep(for: debounce)  // the next `.query` auto-cancels this sleep
                    try Task.checkCancellation()  // a newer query superseded this one
                    try effects.modify { $0.results = [query.uppercased()] }
                }

            case .bypassQuery(let query, let spelling):
                state.query = query
                effects.perform {
                    switch spelling {
                    case .sleepForTolerance:
                        try await clock.sleep(for: debounce, tolerance: nil)
                    case .sleepUntilTolerance:
                        try await clock.sleep(until: clock.now.advanced(by: debounce), tolerance: nil)
                    case .taskSleepForClock:
                        try await Task.sleep(for: debounce, clock: clock)
                    case .concurrentSleepFor:
                        try await sleepOffTheEffectsIsolation(on: clock, for: debounce)
                    }
                    try effects.modify { $0.results = [query.uppercased()] }
                }

            case .start:
                effects.perform {
                    while true {
                        try await clock.sleep(for: interval)
                        try effects.modify { $0.tick += 1 }
                    }
                }

            case .load:
                effects.perform {
                    await loadGate.wait()
                    try effects.modify { $0.isLoaded = true }
                }
            }
        }
    }
}

/// Sleeps with `clock.sleep(for:)`, but from a `@concurrent` function, so off the effect's isolation:
/// the shape of a dependency method that sleeps on the global executor.
@concurrent
private func sleepOffTheEffectsIsolation<C: Clock>(on clock: C, for duration: C.Duration) async throws {
    try await clock.sleep(for: duration)
}

/// `.query` sleeping with `sleep(until:)` called on a concrete `EffectClock`: it runs on the
/// effect's isolation, so the sleep registers before `send` returns.
@Interactor<ClockState, ClockAction>
struct ConcreteSleepUntilInteractor {
    let clock: EffectClock
    let delay: Duration

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            guard case .query(let query) = action else { return }
            state.query = query
            effects.perform {
                try await clock.sleep(until: clock.now.advanced(by: delay))
                try effects.modify { $0.results = [query.uppercased()] }
            }
        }
    }
}

@FeatureState
struct WakeOrderState: Equatable, Sendable {
    /// What each woken effect did, in the order the effects ran after their sleeps.
    var wakes: [String] = []
}

enum WakeOrderAction: Equatable, Sendable {
    /// Sleeps for the debounce, then records "search".
    case search
    /// The ticker: `while true { sleep for the interval; record "tick" }`.
    case start
}

@Interactor<WakeOrderState, WakeOrderAction>
struct WakeOrderInteractor {
    let clock: EffectClock
    let debounce: Duration
    let interval: Duration

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .search:
                effects.perform {
                    try await clock.sleep(for: debounce)
                    try effects.modify { $0.wakes.append("search") }
                }

            case .start:
                effects.perform {
                    while true {
                        try await clock.sleep(for: interval)
                        try effects.modify { $0.wakes.append("tick") }
                    }
                }
            }
        }
    }
}
