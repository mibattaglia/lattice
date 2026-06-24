@testable import TimerLeakExample
import Testing

@Suite
@MainActor
struct TimerLeakTests {
    // Intentionally empty: this package is a throwaway demo for profiling the
    // @ObservableState registrar memory leak. See
    // specs/observable-state-identity-preserving-merge.md.
}
