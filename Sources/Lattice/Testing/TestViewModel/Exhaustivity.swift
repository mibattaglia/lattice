import Foundation

/// Controls how strictly ``TestViewModel`` enforces pending receives between assertions.
public enum Exhaustivity: Sendable {
    case on
    case off(showSkippedAssertions: Bool = true)
}
