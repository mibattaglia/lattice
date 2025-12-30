import Foundation

/// A test harness that simplifies interactor testing.
///
/// Usage:
/// ```swift
/// @Test func testCounter() async throws {
///     let harness = await InteractorTestHarness(CounterInteractor())
///
///     harness.send(.increment)
///     harness.send(.increment)
///
///     try await harness.assertStates([
///         .init(count: 0),
///         .init(count: 1),
///         .init(count: 2)
///     ])
/// }
/// ```
@MainActor
public final class InteractorTestHarness<State: Sendable, Action: Sendable> {
    private let actionContinuation: AsyncStream<Action>.Continuation
    private let recorder: AsyncStreamRecorder<State>

    public init<I: Interactor>(_ interactor: I) async
    where I.DomainState == State, I.Action == Action {
        let (actionStream, continuation) = AsyncStream<Action>.makeStream()
        self.actionContinuation = continuation
        self.recorder = AsyncStreamRecorder<State>()

        let stateStream = interactor.interact(actionStream)
        recorder.record(stateStream)
    }

    public func send(_ action: Action) {
        actionContinuation.yield(action)
    }

    public func send(_ actions: Action...) {
        for action in actions { actionContinuation.yield(action) }
    }

    public func finish() {
        actionContinuation.finish()
    }

    public var states: [State] {
        recorder.values
    }

    public var latestState: State? {
        recorder.lastValue
    }

    public func waitForStates(count: Int, timeout: Duration = .seconds(5)) async throws {
        try await recorder.waitForEmissions(count: count, timeout: timeout)
    }

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
