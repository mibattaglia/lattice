import Testing

@testable import TimerLeakExample

@Suite
@MainActor
struct TimerLeakTests {
    // Intentionally empty: this package is a rendering-stress demo (continuous TimelineView
    // re-renders over a ~50 Hz timer effect) meant for manual profiling in the example app.
}
