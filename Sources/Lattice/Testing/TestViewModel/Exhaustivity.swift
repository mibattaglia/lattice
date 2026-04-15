import Foundation

/// Controls how strictly ``TestViewModel`` enforces pending receives between assertions.
public enum Exhaustivity: Sendable {
    /// Every buffered received action must be handled explicitly before later sends or finish checks.
    case on

    /// Buffered received actions may be skipped implicitly when a later assertion needs to advance.
    ///
    /// Use this when a test intentionally cares about only a subset of the emitted sequence.
    case off(showSkippedAssertions: Bool = true)
}
