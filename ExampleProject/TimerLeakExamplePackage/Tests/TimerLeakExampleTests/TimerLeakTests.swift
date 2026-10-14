@testable import TimerLeakExample
import Testing

@Suite
@MainActor
struct TimerLeakTests {
    // Intentionally empty: this package is a throwaway demo for profiling the
    // @FeatureState registrar memory leak.
}
