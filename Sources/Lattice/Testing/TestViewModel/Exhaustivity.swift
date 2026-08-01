import Foundation

/// Controls how strictly ``TestViewModel`` enforces pending commits between assertions.
public enum Exhaustivity: Sendable, Equatable {
    /// Every pending commit must be asserted explicitly before later sends and before deinit.
    case on

    /// Pending commits may be skipped implicitly when a later assertion needs to advance.
    ///
    /// Use this when a test intentionally cares about only a subset of the commit sequence.
    case off(showSkippedAssertions: Bool = true)
}
