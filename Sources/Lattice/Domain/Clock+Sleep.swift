extension Clock {
    /// Suspends for `duration`, starting on the caller's isolation.
    ///
    /// Effects sleep with `try await clock.sleep(for:)`, and this is the overload that spelling
    /// calls. The standard library's `sleep(for:tolerance:)` and the `sleep(until:tolerance:)`
    /// requirement are `@concurrent`: through them, an effect hops to the global executor before the
    /// clock's own code runs, so a test clock learns of the sleep only after `send` has returned.
    /// This overload is `nonisolated(nonsending)`, so it runs on the effect's isolation, and a test's
    /// `EffectClock` registers the sleep right there, before the effect first suspends: the sleep is
    /// registered when `send` returns. Every other clock sleeps as before, through
    /// `sleep(until:tolerance:)`, and hops there.
    ///
    /// It shadows the standard library's overload for the one-argument spelling: it needs no
    /// defaulted `tolerance:` argument, so overload resolution prefers it at generic, existential and
    /// concrete call sites. It is an extension member, so the file that sleeps imports Lattice.
    /// `sleep(for:tolerance:)`, `sleep(until:tolerance:)` and `Task.sleep(for:clock:)` bypass it;
    /// `EffectClock` reports a sleep that reaches it after such a hop.
    nonisolated(nonsending) public func sleep(for duration: Instant.Duration) async throws {
        if let registrar = self as? any SleepRegistrar<Instant.Duration> {
            try await registrar.registerSleep(for: duration)
        } else {
            try await sleep(until: now.advanced(by: duration), tolerance: nil)
        }
    }
}

/// A clock that registers a sleep on the caller's isolation, before it suspends.
protocol SleepRegistrar<SleepDuration>: Sendable {
    associatedtype SleepDuration

    /// Registers a sleep of `duration` on the caller's isolation, then suspends until it ends.
    nonisolated(nonsending) func registerSleep(for duration: SleepDuration) async throws
}
