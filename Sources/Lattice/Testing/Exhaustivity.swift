/// Controls how strictly ``TestModel`` and ``TestViewModel`` require a test to describe every commit
/// made outside the action it sends: an action an effect sent, or a modification an effect made.
public enum Exhaustivity: Sendable {
    /// Every commit must be described: actions an effect sent with `receive`, modifications an
    /// effect made with `expect`, or folded into the enclosing `send` or `receive`. Anything still
    /// pending is reported at the next `send` or `expect`, at `finish`, and, as a warning that cannot
    /// fail the test, when the test model is deallocated. A modification that leaves the state equal
    /// to what it was is exempt.
    case on

    /// Pending commits that no assertion describes are skipped to the latest state before the next
    /// assertion, which then compares against that state.
    ///
    /// Use this when a test intentionally cares about only a subset of what its effects do. With
    /// `showSkippedAssertions`, each skip is reported as a warning.
    case off(showSkippedAssertions: Bool = true)
}
