import Foundation

/// A test harness that simplifies interactor testing.
///
/// `InteractorTestHarness` provides a convenient API for testing interactors
/// with the synchronous API by handling state management, action sending,
/// effect tracking, and state assertions.
///
/// ## Basic Usage
///
/// ```swift
/// @Test
/// func testCounter() async throws {
///     let harness = InteractorTestHarness(
///         initialState: CounterState(count: 0),
///         interactor: CounterInteractor()
///     )
///
///     harness.send(.increment)
///     harness.send(.increment)
///
///     try harness.assertStates([
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
/// ## Awaiting Effects
///
/// For interactors with async effects, await their completion:
/// ```swift
/// await harness.send(.fetchData).finish()
/// // or
/// await harness.sendAndAwait(.fetchData)
/// ```
///
/// ## Assertions
///
/// Assert a sequence of states:
/// ```swift
/// try harness.assertStates([state1, state2, state3])
/// ```
///
/// Assert only the latest state:
/// ```swift
/// try harness.assertLatestState(expectedState)
/// ```
///
/// Assert actions received (including from effects):
/// ```swift
/// try harness.assertActions([.fetchData, .dataLoaded(data)])
/// ```
@MainActor
public final class InteractorTestHarness<State: Sendable, Action: Sendable> {
    private var state: State
    private let interactor: AnyInteractor<State, Action>
    private var stateHistory: [State] = []
    private var actionHistory: [Action] = []
    private var effectTasks: [Task<Void, Never>] = []
    private let areStatesEqual: (_ lhs: State, _ rhs: State) -> Bool

    /// Creates a test harness for the given interactor.
    ///
    /// - Parameters:
    ///   - initialState: The initial state to start with.
    ///   - interactor: The interactor to test.
    public init<I: Interactor & Sendable>(
        initialState: State,
        interactor: I,
        areStatesEqual: @escaping (_ lhs: State, _ rhs: State) -> Bool
    )
    where I.DomainState == State, I.Action == Action {
        self.interactor = interactor.eraseToAnyInteractor()
        self.state = initialState
        self.stateHistory = [initialState]
        self.areStatesEqual = areStatesEqual
    }

    public init<I: Interactor & Sendable>(
        initialState: State,
        interactor: I
    )
    where I.DomainState == State, I.Action == Action, State: Equatable {
        self.interactor = interactor.eraseToAnyInteractor()
        self.state = initialState
        self.stateHistory = [initialState]
        self.areStatesEqual = { lhs, rhs in lhs == rhs }
    }

    private func appendToHistory() {
        guard let lastState = stateHistory.last else {
            stateHistory.append(state)
            return
        }
        guard !areStatesEqual(lastState, state) else { return }
        stateHistory.append(state)
    }

    /// Sends a single action to the interactor and returns an EventTask.
    ///
    /// - Parameter action: The action to send.
    /// - Returns: An ``EventTask`` representing the spawned effects.
    @discardableResult
    public func send(_ action: Action) -> EventTask {
        actionHistory.append(action)
        let emission = interactor.interact(state: &state, action: action)
        appendToHistory()

        let tasks = spawnTasks(from: emission)

        guard !tasks.isEmpty else {
            return EventTask(rawValue: nil)
        }

        let compositeTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for task in tasks {
                    group.addTask { await task.value }
                }
            }
        }

        return EventTask(rawValue: compositeTask)
    }

    /// Sends multiple actions to the interactor.
    ///
    /// - Parameter actions: The actions to send in order.
    public func send(_ actions: Action...) {
        for action in actions {
            send(action)
        }
    }

    /// Sends an action and awaits completion of all spawned effects.
    ///
    /// - Parameter action: The action to send.
    public func sendAndAwait(_ action: Action) async {
        await send(action).finish()
    }

    private func spawnTasks(from emission: Emission<Action>) -> [Task<Void, Never>] {
        switch emission.kind {
        case .none:
            return []

        case .action(let action):
            _ = send(action)
            return []

        case .perform(let work):
            let task = Task { [weak self] in
                guard let action = await work() else { return }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    _ = self?.send(action)
                }
            }
            effectTasks.append(task)
            return [task]

        case .observe(let stream):
            let task = Task { [weak self] in
                for await action in await stream() {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        _ = self?.send(action)
                    }
                }
            }
            effectTasks.append(task)
            return [task]

        case .merge(let emissions):
            return emissions.flatMap { spawnTasks(from: $0) }
        }
    }

    /// All recorded states in order of change.
    public var states: [State] {
        stateHistory
    }

    /// All actions received (including from effects).
    public var receivedActions: [Action] {
        actionHistory
    }

    /// The current state value.
    public var currentState: State {
        state
    }

    /// The most recently recorded state.
    public var latestState: State? {
        stateHistory.last
    }

    /// Asserts that the recorded states match the expected sequence.
    ///
    /// - Parameters:
    ///   - expected: The expected sequence of states.
    ///   - file: The file where the assertion is called.
    ///   - line: The line where the assertion is called.
    /// - Throws: `AssertionError` if the states do not match.
    public func assertStates(
        _ expected: [State],
        file: StaticString = #file,
        line: UInt = #line
    ) throws where State: Equatable {
        guard stateHistory == expected else {
            throw AssertionError(
                message: "States mismatch.\nExpected: \(expected)\nActual: \(stateHistory)",
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
    ) throws where State: Equatable {
        guard latestState == expected else {
            throw AssertionError(
                message: "Latest state mismatch.\nExpected: \(expected)\nActual: \(String(describing: latestState))",
                file: file,
                line: line
            )
        }
    }

    /// Asserts that the received actions match the expected sequence.
    ///
    /// - Parameters:
    ///   - expected: The expected sequence of actions.
    ///   - file: The file where the assertion is called.
    ///   - line: The line where the assertion is called.
    /// - Throws: `AssertionError` if the actions do not match.
    public func assertActions(
        _ expected: [Action],
        file: StaticString = #file,
        line: UInt = #line
    ) throws where Action: Equatable {
        guard actionHistory == expected else {
            throw AssertionError(
                message: "Actions mismatch.\nExpected: \(expected)\nActual: \(actionHistory)",
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
        effectTasks.forEach { $0.cancel() }
    }
}
