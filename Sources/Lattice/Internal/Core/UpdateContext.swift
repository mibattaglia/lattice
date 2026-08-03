/// The core's mutation-phase state machine.
///
/// Any phase other than `idle` means a mutation body has exclusive `inout` access to the
/// state, so re-entrant `send`/`modify`/state reads pattern-match the phase and fail with a
/// loud, named precondition instead of Swift's opaque dynamic-exclusivity crash. Type-level
/// phase separation (the update-phase handle exposes only `perform`; the effect-phase handle
/// exposes only `modify`/`send`/`state`) is the first line of defense; these runtime checks
/// are the backstop for handles smuggled across phases and for exclusivity violations.
///
/// Phase discipline (enforced by loud runtime preconditions):
/// - `launchEffect` (backing `perform`) is legal only in `.updating`.
/// - `modify` / `send` / `currentState` are legal only in `.idle`.
enum Phase {
    /// No mutation in progress.
    case idle
    /// `interact` is running for one action — the update phase.
    case updating(UpdateContext)
    /// A `modify` closure is running.
    case modifying
}

/// Present on the core exactly while `interact` runs for one action — the update phase.
struct UpdateContext {
    /// Effects registered by `perform`, launched after the commit funnel runs so their
    /// synchronous prefixes observe committed state and may legally call `modify`/`send`.
    /// Recorded in `perform` order; the launch loop derives replace-vs-track per key from
    /// that order.
    var pendingEffects: [PendingEffect] = []
}

/// One `perform` recorded during an update, awaiting launch.
struct PendingEffect {
    let key: TaskKey
    let operation: () async throws -> Void
}
