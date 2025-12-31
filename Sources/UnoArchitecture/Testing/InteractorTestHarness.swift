import Foundation

/// A test harness that simplifies interactor testing.
///
/// `InteractorTestHarness` provides a convenient API for testing interactors
/// by handling stream setup, action sending, and state assertions.
///
/// ## Basic Usage
///
/// ```swift
/// @Test
/// func testCounter() async throws {
///     let harness = await InteractorTestHarness(CounterInteractor())
///
///     harness.send(.increment)
///     harness.send(.increment)
///
///     try await harness.assertStates([
///         CounterState(count: 0),  // Initial state
///         CounterState(count: 1),
///         CounterState(count: 2)
///     ])
/// }
/// ```
///
/// ## Sending Actions
///
/// ```swift
/// harness.send(.increment)
/// harness.send(.decrement, .reset)  // Multiple actions
/// ```
///
/// ## Assertions
///
/// Assert a sequence of states:
/// ```swift
/// try await harness.assertStates([state1, state2, state3])
/// ```
///
/// Assert only the latest state:
/// ```swift
/// try await harness.assertLatestState(expectedState)
/// ```
///
/// ## Async Effects
///
/// For interactors with async effects, use timeouts:
/// ```swift
/// try await harness.waitForStates(count: 3, timeout: .seconds(2))
/// ```
@MainActor
public final class InteractorTestHarness<State: Sendable, Action: Sendable> {
    private let actionContinuation: AsyncStream<Action>.Continuation
    private let recorder: AsyncStreamRecorder<State>

    /// Creates a test harness for the given interactor.
    ///
    /// - Parameter interactor: The interactor to test.
    public init<I: Interactor>(_ interactor: I) async
    where I.DomainState == State, I.Action == Action {
        let (actionStream, continuation) = AsyncStream<Action>.makeStream()
        self.actionContinuation = continuation
        self.recorder = AsyncStreamRecorder<State>()

        let stateStream = interactor.interact(actionStream)
        recorder.record(stateStream)
    }

    /// Sends a single action to the interactor.
    ///
    /// - Parameter action: The action to send.
    public func send(_ action: Action) {
        actionContinuation.yield(action)
    }

    /// Sends multiple actions to the interactor.
    ///
    /// - Parameter actions: The actions to send in order.
    public func send(_ actions: Action...) {
        for action in actions { actionContinuation.yield(action) }
    }

    /// Signals that no more actions will be sent.
    ///
    /// Call this when the test is complete to allow the interactor to clean up.
    public func finish() {
        actionContinuation.finish()
    }

    /// All recorded states in order of emission.
    public var states: [State] {
        recorder.values
    }

    /// The most recently emitted state.
    public var latestState: State? {
        recorder.lastValue
    }

    /// Waits for a specific number of state emissions.
    ///
    /// - Parameters:
    ///   - count: The minimum number of states to wait for.
    ///   - timeout: Maximum time to wait.
    /// - Throws: `TimeoutError` if the timeout expires.
    public func waitForStates(count: Int, timeout: Duration = .seconds(5)) async throws {
        try await recorder.waitForEmissions(count: count, timeout: timeout)
    }

    /// Asserts that the recorded states match the expected sequence.
    ///
    /// - Parameters:
    ///   - expected: The expected sequence of states.
    ///   - timeout: Maximum time to wait for states.
    ///   - file: The file where the assertion is called.
    ///   - line: The line where the assertion is called.
    /// - Throws: `AssertionError` if the states do not match.
    public func assertStates(
        _ expected: [State],
        timeout: Duration = .seconds(5),
        file: StaticString = #file,
        line: UInt = #line
    ) async throws where State: Equatable {
        try await waitForStates(count: expected.count, timeout: timeout)
        let actual = states

        guard actual.prefix(expected.count) == expected[...] else {
            throw AssertionError(
                message: "States mismatch.\nExpected: \(expected)\nActual: \(Array(actual.prefix(expected.count)))",
                file: file,
                line: line
            )
        }
    }

    /// Asserts that the latest state matches the expected value.
    ///
    /// - Parameters:
    ///   - expected: The expected latest state.
    ///   - file: The file where the assertion is called.
    ///   - line: The line where the assertion is called.
    /// - Throws: `AssertionError` if the latest state does not match.
    public func assertLatestState(
        _ expected: State,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws where State: Equatable {
        let latest = latestState
        guard latest == expected else {
            throw AssertionError(
                message: "Latest state mismatch.\nExpected: \(expected)\nActual: \(String(describing: latest))",
                file: file,
                line: line
            )
        }
    }

    /// Error thrown when a test assertion fails.
    public struct AssertionError: Error, CustomStringConvertible {
        public let message: String
        public let file: StaticString
        public let line: UInt
        public var description: String { message }
    }

    deinit {
        actionContinuation.finish()
        recorder.cancelAsync()
    }
}
