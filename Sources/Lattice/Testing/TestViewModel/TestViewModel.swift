#if canImport(Clocks)
import Clocks
import DequeModule
import Foundation
import OrderedCollections

#if canImport(CasePaths)
    import CasePaths
#endif

/// A state-first testing model for a Lattice feature.
///
/// `TestViewModel` mirrors the production execution helpers used by ``ViewModel``, but buffers
/// actions emitted from emissions until tests explicitly receive or skip them.
///
/// The testing contract is step-wise:
///
/// - ``send(_:assert:fileID:file:line:column:)`` asserts the immediately visible mutation.
/// - ``receive(_:timeout:assert:fileID:file:line:column:)`` advances through buffered emission output.
/// - ``state`` reflects the last asserted or received state, not hidden buffered state.
/// - ``finish(timeout:fileID:file:line:column:)`` waits for emissions, but does not implicitly drain receives.
///
/// Assertions compare states with the feature's ``FeatureProtocol/areStatesEqual``, or with the
/// equality passed to ``init(initialState:feature:areStatesEqual:)`` when the feature has none.
@MainActor
public final class TestViewModel<F: FeatureProtocol> {
    public typealias Action = F.Action
    public typealias State = F.State

    /// The most recently asserted or committed state.
    public private(set) var state: State

    /// Controls whether pending receives must be handled before later assertions.
    public var exhaustivity: Exhaustivity = .on

    /// The default timeout used by APIs that accept an optional timeout.
    public var timeout: Duration = .seconds(1)

    private var assertedState: State
    private var latestState: State

    private var bufferedActions: Deque<BufferedAction<Action>> = []
    private var pendingReceives: Deque<PendingReceive<State, Action>> = []
    private var rootScopes: OrderedDictionary<SendScopeID, RootScopeState> = [:]
    private var effectTasks: OrderedDictionary<EffectID, Task<Void, Never>> = [:]
    private var inFlightEffects: OrderedDictionary<EffectID, InFlightEffectRecord<Action>> = [:]
    private var rootSendOrigins: OrderedDictionary<SendScopeID, RootSendOrigin<Action>> = [:]
    private var startedRootScopes: Set<SendScopeID> = []
    private var isSending = false
    private let effectDidStart = AsyncStream.makeStream(of: Void.self)

    private let interactor: AnyInteractor<State, Action>
    private let areStatesEqual: ((_ lhs: State, _ rhs: State) -> Bool)?
    private nonisolated let taskRegistry = EffectTaskRegistry()
    private nonisolated let cancellationRegistry = EffectCancellationRegistry()

    /// Creates a test model for a concrete feature.
    ///
    /// Assertions compare states with the feature's ``FeatureProtocol/areStatesEqual``. If the
    /// feature has none, an issue is reported here and every state assertion fails; use
    /// ``init(initialState:feature:areStatesEqual:)`` for such a feature.
    public convenience init(
        initialState: State,
        feature: F,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.init(
            initialState: initialState,
            interactor: feature.interactor,
            areStatesEqual: feature.areStatesEqual
        )
        if feature.areStatesEqual == nil {
            reportTestFailure(
                TestFailure.missingStateEquality(State.self),
                at: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
            )
        }
    }

    /// Creates a test model for a concrete feature, comparing states with `areStatesEqual` when
    /// the feature has no ``FeatureProtocol/areStatesEqual`` of its own.
    ///
    /// Use it for a state that is not `Equatable`. The feature's equality takes precedence, so a
    /// custom comparison for an `Equatable` state belongs in `Feature(interactor:areStatesEqual:)`.
    public convenience init(
        initialState: State,
        feature: F,
        areStatesEqual: @escaping (_ lhs: State, _ rhs: State) -> Bool
    ) {
        self.init(
            initialState: initialState,
            interactor: feature.interactor,
            areStatesEqual: feature.areStatesEqual ?? areStatesEqual
        )
    }

    private init(
        initialState: State,
        interactor: AnyInteractor<State, Action>,
        areStatesEqual: ((_ lhs: State, _ rhs: State) -> Bool)?
    ) {
        self.state = initialState
        self.assertedState = initialState
        self.latestState = initialState
        self.interactor = interactor
        self.areStatesEqual = areStatesEqual
    }

    deinit {
        taskRegistry.cancelAll()
        cancellationRegistry.cancelAll()
    }

    /// Sends an action into the feature and asserts the immediately visible state mutation.
    ///
    /// In exhaustive mode, all previously buffered received actions must be handled before a new
    /// send can proceed. The returned ``TestEventTask`` is scoped to the downstream work started
    /// from this send only.
    @discardableResult
    public func send(
        _ action: Action,
        assert update: ((inout State) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestEventTask {
        let location = TestIssueLocation(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        switch exhaustivity {
        case .on:
            guard pendingReceives.isEmpty else {
                reportTestFailure(
                    TestFailure.mustHandleReceivedActionsBeforeSending(
                        pendingReceives.map(\.action)
                    ),
                    at: location
                )
                return TestEventTask(
                    rawValue: nil,
                    timeout: timeout
                )
            }

        case .off:
            do {
                try skipPendingReceives(strict: false)
            } catch let failure as TestFailure {
                reportTestFailure(
                    failure,
                    at: location
                )
                return TestEventTask(
                    rawValue: nil,
                    timeout: timeout
                )
            } catch {
                reportUnexpectedTestError(
                    error,
                    at: location
                )
                return TestEventTask(
                    rawValue: nil,
                    timeout: timeout
                )
            }
        }

        let previousState = assertedState
        let rootScopeID = SendScopeID()

        rootSendOrigins[rootScopeID] = .init(
            action: action,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        enqueue(action, source: .sent, rootScopeID: rootScopeID)
        drainBufferedActionsIfNeeded()
        let task = makeEventTask(for: rootScopeID)
        await awaitEffectStartup(for: rootScopeID)

        do {
            try assertStateChange(
                operation: "send(\(describe(action)))",
                previousState: previousState,
                actualState: state,
                assert: update
            )
        } catch let failure as TestFailure {
            reportTestFailure(
                failure,
                at: location
            )
        } catch {
            reportUnexpectedTestError(
                error,
                at: location
            )
        }

        await Task.megaYield()
        return task
    }

    /// Receives the next action emitted from an emission matching the expected action.
    ///
    /// Receiving does not re-enter execution. It advances visible state by consuming the next
    /// buffered receive whose action matches `expectedAction`.
    public func receive(
        _ expectedAction: Action,
        timeout duration: Duration? = nil,
        assert update: ((inout State) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async where Action: Equatable {
        let location = TestIssueLocation(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        await withReportedTestFailures(at: location) {
            try await receive(
                matching: { $0 == expectedAction },
                expectedActionDescription: describe(expectedAction),
                unexpectedActionFailure: { receivedAction, receivedActionLater in
                    TestFailure.unexpectedReceivedAction(
                        receivedAction,
                        expected: expectedAction,
                        receivedActionLater: receivedActionLater
                    )
                },
                missingActionFailure: {
                    TestFailure.expectedToReceiveAction(
                        expectedAction,
                        timeout: duration ?? self.timeout,
                        hasInFlightEffects: !self.inFlightEffects.isEmpty
                    )
                },
                timeout: duration,
                assert: update
            )
        }

        await Task.megaYield()
    }

    /// Receives the next action emitted from an emission matching the predicate.
    public func receive(
        _ isMatching: (_ action: Action) -> Bool,
        timeout duration: Duration? = nil,
        assert update: ((inout State) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        let location = TestIssueLocation(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        await withReportedTestFailures(at: location) {
            try await receive(
                matching: isMatching,
                expectedActionDescription: "an action matching predicate",
                timeout: duration,
                assert: update
            )
        }

        await Task.megaYield()
    }

    #if canImport(CasePaths)
        /// Receives the next action emitted from an emission matching a case path.
        public func receive<Value>(
            _ actionCase: KeyPath<Action.AllCasePaths, AnyCasePath<Action, Value>>,
            timeout duration: Duration? = nil,
            assert update: ((inout State) throws -> Void)? = nil,
            fileID: StaticString = #fileID,
            file filePath: StaticString = #filePath,
            line: UInt = #line,
            column: UInt = #column
        ) async where Action: CasePathable {
            let location = TestIssueLocation(
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )

            await withReportedTestFailures(at: location) {
                try await receive(
                    Action.allCasePaths[keyPath: actionCase],
                    timeout: duration,
                    assert: update
                )
            }

            await Task.megaYield()
        }

        private func receive<Value>(
            _ actionCase: AnyCasePath<Action, Value>,
            timeout duration: Duration? = nil,
            assert update: ((inout State) throws -> Void)? = nil
        ) async throws {
            try await receive(
                matching: { actionCase.extract(from: $0) != nil },
                expectedActionDescription: "an action matching case path",
                timeout: duration,
                assert: update
            )
        }
    #endif

    /// Waits for the feature to finish all in-flight emissions.
    ///
    /// This checks for unhandled received actions before and after waiting. It does not
    /// automatically consume buffered receives.
    public func finish(
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        let location = TestIssueLocation(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        await withReportedTestFailures(at: location) {
            guard pendingReceives.isEmpty else {
                throw TestFailure.unhandledReceivedActions(pendingReceives.map(\.action))
            }

            try await waitForEffectsToFinish(timeout: duration ?? timeout)

            guard pendingReceives.isEmpty else {
                throw TestFailure.unhandledReceivedActions(pendingReceives.map(\.action))
            }
        }
    }

    /// Explicitly advances visible state past any currently buffered received actions.
    ///
    /// This is the escape hatch for non-exhaustive tests that want to acknowledge already buffered
    /// emission output without asserting each step individually.
    public func skipReceivedActions(
        strict: Bool = true,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        let location = TestIssueLocation(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        await withReportedTestFailures(at: location) {
            await Task.yield()
            try skipPendingReceives(strict: strict)
        }
    }

    /// Cancels and waits for any currently in-flight emissions.
    ///
    /// Already buffered receives remain buffered after cancellation and must still be handled or
    /// skipped separately.
    public func skipInFlightEffects(
        strict: Bool = true,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        let location = TestIssueLocation(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        await withReportedTestFailures(at: location) {
            await Task.yield()

            guard !inFlightEffects.isEmpty else {
                guard strict else { return }
                throw TestFailure.noInFlightEffectsToSkip()
            }

            let tasks = Array(effectTasks.values)
            for task in tasks {
                task.cancel()
            }

            try await waitForEffectsToFinish(timeout: timeout)
        }
    }

    private func enqueue(
        _ action: Action,
        source: ActionSource,
        rootScopeID: SendScopeID
    ) {
        bufferedActions.append(
            .init(
                action: action,
                source: source,
                rootScopeID: rootScopeID
            )
        )

        var rootScope = rootScopes[rootScopeID] ?? .init()
        rootScope.bufferedActionCount += 1
        rootScopes[rootScopeID] = rootScope
    }

    private func drainBufferedActionsIfNeeded() {
        guard !isSending else { return }

        isSending = true
        defer { isSending = false }

        while let bufferedAction = bufferedActions.popFirst() {
            guard var rootScope = rootScopes[bufferedAction.rootScopeID] else {
                continue
            }

            rootScope.bufferedActionCount -= 1
            rootScopes[bufferedAction.rootScopeID] = rootScope

            var workingState = latestState
            let transition = ActionTransition.apply(
                bufferedAction.action,
                source: bufferedAction.source,
                rootScopeID: bufferedAction.rootScopeID,
                to: &workingState,
                using: interactor
            )

            commitTestTransition(transition)
            spawnEffects(
                from: transition.emission,
                rootScopeID: bufferedAction.rootScopeID
            )
            pruneRootScopeIfQuiescent(bufferedAction.rootScopeID)
        }
    }

    private func commitTestTransition(
        _ transition: ActionTransition<State, Action>
    ) {
        latestState = transition.currentState

        switch transition.source {
        case .sent:
            assertedState = transition.currentState
            state = transition.currentState

        case .emitted:
            pendingReceives.append(
                .init(
                    action: transition.action,
                    resultingState: transition.currentState,
                    rootScopeID: transition.rootScopeID
                )
            )
        }
    }

    private func spawnEffects(
        from emission: Emission<Action>,
        rootScopeID: SendScopeID
    ) {
        let spawnedTasks = EmissionExecution.spawnTasks(
            from: emission,
            rootScopeID: rootScopeID,
            cancellationRegistry: cancellationRegistry,
            makeEffectID: { EffectID() },
            effectDidStart: { [weak self] effectID in
                self?.enrollEffect(effectID, rootScopeID: rootScopeID)
            },
            effectDidComplete: { [weak self] effectID in
                self?.completeEffect(effectID, rootScopeID: rootScopeID)
            },
            effectDidCancel: { [weak self] effectID in
                self?.cancelEffect(effectID, rootScopeID: rootScopeID)
            },
            enqueueEmittedAction: { [weak self] action, rootScopeID in
                guard let self else { return }
                self.enqueue(action, source: .emitted, rootScopeID: rootScopeID)
                self.drainBufferedActionsIfNeeded()
            }
        )

        for (effectID, task) in spawnedTasks {
            effectTasks[effectID] = task
        }
        taskRegistry.insert(spawnedTasks)
    }

    private func enrollEffect(
        _ effectID: EffectID,
        rootScopeID: SendScopeID
    ) {
        var rootScope = rootScopes[rootScopeID] ?? .init()
        rootScope.inFlightEffectIDs.insert(effectID)
        rootScopes[rootScopeID] = rootScope

        inFlightEffects[effectID] = .init(
            id: effectID,
            rootScopeID: rootScopeID
        )
        startedRootScopes.insert(rootScopeID)
        effectDidStart.continuation.yield()
    }

    private func completeEffect(
        _ effectID: EffectID,
        rootScopeID: SendScopeID
    ) {
        effectTasks[effectID] = nil
        inFlightEffects[effectID] = nil
        taskRegistry.remove([effectID])

        guard var rootScope = rootScopes[rootScopeID] else { return }
        rootScope.inFlightEffectIDs.remove(effectID)
        rootScopes[rootScopeID] = rootScope

        pruneRootScopeIfQuiescent(rootScopeID)
    }

    private func cancelEffect(
        _ effectID: EffectID,
        rootScopeID: SendScopeID
    ) {
        completeEffect(effectID, rootScopeID: rootScopeID)
    }

    private func makeEventTask(for rootScopeID: SendScopeID) -> TestEventTask {
        guard rootScopes[rootScopeID] != nil else {
            return TestEventTask(rawValue: nil, timeout: timeout)
        }

        return TestEventTask(
            rawValue: RootScopeTasks.makeTask(
                rootScopeID: rootScopeID,
                isQuiescent: { [weak self] rootScopeID in
                    self?.isRootScopeQuiescent(rootScopeID) ?? true
                },
                cancelScope: { [weak self] rootScopeID in
                    self?.cancelRootScope(rootScopeID)
                }
            ),
            timeout: timeout
        )
    }

    private func isRootScopeQuiescent(_ rootScopeID: SendScopeID) -> Bool {
        rootScopes[rootScopeID]?.isQuiescent ?? true
    }

    private func cancelRootScope(_ rootScopeID: SendScopeID) {
        guard let rootScope = rootScopes[rootScopeID] else { return }

        for effectID in rootScope.inFlightEffectIDs {
            effectTasks[effectID]?.cancel()
        }
    }

    private func pruneRootScopeIfQuiescent(_ rootScopeID: SendScopeID) {
        guard rootScopes[rootScopeID]?.isQuiescent == true else { return }

        rootScopes[rootScopeID] = nil
        rootSendOrigins[rootScopeID] = nil
        startedRootScopes.remove(rootScopeID)
    }

    private func awaitEffectStartup(for rootScopeID: SendScopeID) async {
        guard !startedRootScopes.contains(rootScopeID) else { return }
        guard rootScopes[rootScopeID] != nil else { return }

        for await _ in effectDidStart.stream {
            if startedRootScopes.contains(rootScopeID) || rootScopes[rootScopeID] == nil {
                return
            }
        }
    }

    private func receive(
        matching predicate: (Action) -> Bool,
        expectedActionDescription: String,
        unexpectedActionFailure: ((Action, Bool) -> TestFailure)? = nil,
        missingActionFailure: (() -> TestFailure)? = nil,
        timeout: Duration?,
        assert update: ((inout State) throws -> Void)?
    ) async throws {
        try await waitForPendingReceive(
            matching: predicate,
            expectedActionDescription: expectedActionDescription,
            missingActionFailure: missingActionFailure,
            timeout: timeout
        )
        try consumePendingReceive(
            matching: predicate,
            expectedActionDescription: expectedActionDescription,
            unexpectedActionFailure: unexpectedActionFailure,
            assert: update
        )
    }

    private func waitForPendingReceive(
        matching predicate: (Action) -> Bool,
        expectedActionDescription: String,
        missingActionFailure: (() -> TestFailure)?,
        timeout duration: Duration?
    ) async throws {
        if isReceiveReady(matching: predicate) {
            return
        }

        let timeout = duration ?? self.timeout
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        await Task.megaYield()
        while !Task.isCancelled {
            await Task.detached(priority: .background) {
                await Task.yield()
            }.value

            if isReceiveReady(matching: predicate) {
                return
            }

            if pendingReceives.isEmpty && inFlightEffects.isEmpty {
                break
            }

            guard clock.now < deadline else {
                break
            }
        }

        if let missingActionFailure {
            throw missingActionFailure()
        }

        throw TestFailure.expectedToReceiveAction(
            expectedActionDescription,
            timeout: timeout,
            hasInFlightEffects: !inFlightEffects.isEmpty
        )
    }

    private func isReceiveReady(
        matching predicate: (Action) -> Bool
    ) -> Bool {
        switch exhaustivity {
        case .on:
            return !pendingReceives.isEmpty

        case .off:
            return pendingReceives.contains(where: { predicate($0.action) })
        }
    }

    private func consumePendingReceive(
        matching predicate: (Action) -> Bool,
        expectedActionDescription: String,
        unexpectedActionFailure: ((Action, Bool) -> TestFailure)?,
        assert update: ((inout State) throws -> Void)?
    ) throws {
        if case .off = exhaustivity {
            while let firstPendingReceive = pendingReceives.first,
                !predicate(firstPendingReceive.action)
            {
                let skippedPendingReceive = pendingReceives.removeFirst()
                assertedState = skippedPendingReceive.resultingState
                state = skippedPendingReceive.resultingState
            }
        }

        guard let pendingReceive = pendingReceives.popFirst() else {
            throw TestFailure.expectedToReceiveAction(
                expectedActionDescription,
                timeout: nil,
                hasInFlightEffects: !inFlightEffects.isEmpty
            )
        }

        guard predicate(pendingReceive.action) else {
            let receivedActionLater = pendingReceives.contains(where: { predicate($0.action) })
            if let unexpectedActionFailure {
                throw unexpectedActionFailure(pendingReceive.action, receivedActionLater)
            }

            throw TestFailure.unexpectedReceivedAction(
                pendingReceive.action,
                expected: expectedActionDescription,
                receivedActionLater: receivedActionLater
            )
        }

        let previousState = state

        try assertStateChange(
            operation: "receive(\(expectedActionDescription))",
            previousState: previousState,
            actualState: pendingReceive.resultingState,
            assert: update
        )

        assertedState = pendingReceive.resultingState
        state = pendingReceive.resultingState
    }

    private func skipPendingReceives(strict: Bool) throws {
        guard !pendingReceives.isEmpty else {
            guard strict else { return }
            throw TestFailure.noReceivedActionsToSkip()
        }

        guard let latestPendingReceive = pendingReceives.last else { return }
        assertedState = latestPendingReceive.resultingState
        state = latestPendingReceive.resultingState
        pendingReceives.removeAll()
    }

    private func waitForEffectsToFinish(timeout: Duration) async throws {
        guard !inFlightEffects.isEmpty else { return }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        await Task.megaYield()
        while !inFlightEffects.isEmpty {
            guard clock.now < deadline else {
                throw TestFailure.expectedEffectsToFinish(
                    count: inFlightEffects.count,
                    timeout: timeout
                )
            }

            await Task.yield()
        }
    }

    private func assertStateChange(
        operation: String,
        previousState: State,
        actualState: State,
        assert update: ((inout State) throws -> Void)?
    ) throws {
        guard let areStatesEqual else {
            throw TestFailure.missingStateEquality(State.self)
        }

        var expectedState = previousState

        do {
            try update?(&expectedState)
        } catch {
            throw TestFailure.assertionThrew(
                operation: operation,
                error: error
            )
        }

        if update != nil,
            areStatesEqual(expectedState, previousState),
            !areStatesEqual(actualState, previousState)
        {
            throw TestFailure.assertionClosureMadeNoChanges(
                operation: operation,
                state: actualState
            )
        }

        guard areStatesEqual(expectedState, actualState) else {
            throw TestFailure.stateMutationDidNotMatchExpectation(
                expected: expectedState,
                actual: actualState,
                didExpectStateChange: update != nil
            )
        }
    }
}

private func describe<T>(_ value: T) -> String {
    String(reflecting: value)
}
#endif
