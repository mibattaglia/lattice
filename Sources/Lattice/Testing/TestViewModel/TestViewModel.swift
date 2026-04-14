import DequeModule
import Foundation
import OrderedCollections

#if canImport(CasePaths)
    import CasePaths
#endif

/// A domain-state-first testing model for a Lattice feature.
///
/// `TestViewModel` mirrors the production execution helpers used by ``ViewModel``, but buffers
/// effect-emitted actions until tests explicitly receive or skip them.
@MainActor
public final class TestViewModel<F: FeatureProtocol> {
    public typealias Action = F.Action
    public typealias DomainState = F.DomainState

    /// The most recently asserted or committed domain state.
    public private(set) var domainState: DomainState

    /// Controls whether pending receives must be handled before later assertions.
    public var exhaustivity: Exhaustivity = .on

    /// The default timeout used by APIs that accept an optional timeout.
    public var timeout: Duration = .seconds(1)

    private var assertedState: DomainState
    private var latestState: DomainState

    private var bufferedActions: Deque<BufferedAction<Action>> = []
    private var pendingReceives: Deque<PendingReceive<DomainState, Action>> = []
    private var rootScopes: OrderedDictionary<SendScopeID, RootScopeState> = [:]
    private var effectTasks: OrderedDictionary<EffectID, Task<Void, Never>> = [:]
    private var inFlightEffects: OrderedDictionary<EffectID, InFlightEffectRecord<Action>> = [:]
    private var rootSendOrigins: OrderedDictionary<SendScopeID, RootSendOrigin<Action>> = [:]
    private var startedRootScopes: Set<SendScopeID> = []
    private var isSending = false

    private let interactor: AnyInteractor<DomainState, Action>
    private let areStatesEqual: (_ lhs: DomainState, _ rhs: DomainState) -> Bool
    private nonisolated let taskRegistry = EffectTaskRegistry()

    /// Creates a test model for a concrete feature.
    public convenience init(
        initialDomainState: DomainState,
        feature: F
    ) {
        self.init(
            initialDomainState: initialDomainState,
            interactor: feature.interactor,
            areStatesEqual: feature.areStatesEqual
        )
    }

    init(
        initialDomainState: DomainState,
        interactor: AnyInteractor<DomainState, Action>,
        areStatesEqual: @escaping (_ lhs: DomainState, _ rhs: DomainState) -> Bool
    ) {
        self.domainState = initialDomainState
        self.assertedState = initialDomainState
        self.latestState = initialDomainState
        self.interactor = interactor
        self.areStatesEqual = areStatesEqual
    }

    deinit {
        taskRegistry.cancelAll()
    }

    /// Sends an action into the feature and asserts the immediately visible state mutation.
    @discardableResult
    public func send(
        _ action: Action,
        assert update: ((inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async throws -> TestEventTask {
        switch exhaustivity {
        case .on:
            guard pendingReceives.isEmpty else {
                throw TestFailure.mustHandleReceivedActionsBeforeSending(
                    pendingReceives.map(\.action)
                )
            }

        case .off:
            try skipPendingReceives(strict: false)
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
        await awaitEffectStartup(for: rootScopeID)

        try assertStateChange(
            operation: "send(\(describe(action)))",
            previousState: previousState,
            actualState: domainState,
            assert: update
        )

        return makeEventTask(for: rootScopeID)
    }

    /// Receives the next effect-emitted action matching the expected action.
    public func receive(
        _ expectedAction: Action,
        timeout duration: Duration? = nil,
        assert update: ((inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async throws where Action: Equatable {
        try await receive(
            matching: { $0 == expectedAction },
            expectedActionDescription: describe(expectedAction),
            timeout: duration,
            assert: update,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// Receives the next effect-emitted action matching the predicate.
    public func receive(
        _ isMatching: (_ action: Action) -> Bool,
        timeout duration: Duration? = nil,
        assert update: ((inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async throws {
        try await receive(
            matching: isMatching,
            expectedActionDescription: "an action matching predicate",
            timeout: duration,
            assert: update,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    #if canImport(CasePaths)
        /// Receives the next effect-emitted action matching a case path.
        public func receive<Value>(
            _ actionCase: KeyPath<Action.AllCasePaths, AnyCasePath<Action, Value>>,
            timeout duration: Duration? = nil,
            assert update: ((inout DomainState) throws -> Void)? = nil,
            fileID: StaticString = #fileID,
            file filePath: StaticString = #filePath,
            line: UInt = #line,
            column: UInt = #column
        ) async throws where Action: CasePathable {
            try await receive(
                Action.allCasePaths[keyPath: actionCase],
                timeout: duration,
                assert: update,
                fileID: fileID,
                file: filePath,
                line: line,
                column: column
            )
        }

        func receive<Value>(
            _ actionCase: AnyCasePath<Action, Value>,
            timeout duration: Duration? = nil,
            assert update: ((inout DomainState) throws -> Void)? = nil,
            fileID: StaticString = #fileID,
            file filePath: StaticString = #filePath,
            line: UInt = #line,
            column: UInt = #column
        ) async throws {
            try await receive(
                matching: { actionCase.extract(from: $0) != nil },
                expectedActionDescription: "an action matching case path",
                timeout: duration,
                assert: update,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    #endif

    /// Waits for the feature to finish all in-flight effects.
    public func finish(
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async throws {
        guard pendingReceives.isEmpty else {
            throw TestFailure.unhandledReceivedActions(pendingReceives.map(\.action))
        }

        _ = (fileID, filePath, line, column)
        try await waitForEffectsToFinish(timeout: duration ?? timeout)

        guard pendingReceives.isEmpty else {
            throw TestFailure.unhandledReceivedActions(pendingReceives.map(\.action))
        }
    }

    /// Explicitly advances visible state past any currently buffered received actions.
    public func skipReceivedActions(
        strict: Bool = true,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async throws {
        _ = (fileID, filePath, line, column)
        await Task.yield()
        try skipPendingReceives(strict: strict)
    }

    /// Cancels and waits for any currently in-flight effects.
    public func skipInFlightEffects(
        strict: Bool = true,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async throws {
        _ = (fileID, filePath, line, column)
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
        _ transition: ActionTransition<DomainState, Action>
    ) {
        latestState = transition.currentState

        switch transition.source {
        case .sent:
            assertedState = transition.currentState
            domainState = transition.currentState

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
        await Task.yield()
    }

    private func receive(
        matching predicate: (Action) -> Bool,
        expectedActionDescription: String,
        timeout: Duration?,
        assert update: ((inout DomainState) throws -> Void)?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async throws {
        _ = (fileID, filePath, line, column)
        try await waitForPendingReceive(
            matching: predicate,
            expectedActionDescription: expectedActionDescription,
            timeout: timeout
        )
        try consumePendingReceive(
            matching: predicate,
            expectedActionDescription: expectedActionDescription,
            assert: update
        )
    }

    private func waitForPendingReceive(
        matching predicate: (Action) -> Bool,
        expectedActionDescription: String,
        timeout duration: Duration?
    ) async throws {
        if isReceiveReady(matching: predicate) {
            return
        }

        let timeout = duration ?? self.timeout
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            await Task.yield()

            if isReceiveReady(matching: predicate) {
                return
            }

            if pendingReceives.isEmpty && inFlightEffects.isEmpty {
                break
            }
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
        assert update: ((inout DomainState) throws -> Void)?
    ) throws {
        if case .off = exhaustivity {
            while let firstPendingReceive = pendingReceives.first,
                !predicate(firstPendingReceive.action)
            {
                let skippedPendingReceive = pendingReceives.removeFirst()
                assertedState = skippedPendingReceive.resultingState
                domainState = skippedPendingReceive.resultingState
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
            throw TestFailure.unexpectedReceivedAction(
                pendingReceive.action,
                expected: expectedActionDescription,
                receivedActionLater: receivedActionLater
            )
        }

        let previousState = domainState

        try assertStateChange(
            operation: "receive(\(expectedActionDescription))",
            previousState: previousState,
            actualState: pendingReceive.resultingState,
            assert: update
        )

        assertedState = pendingReceive.resultingState
        domainState = pendingReceive.resultingState
    }

    private func skipPendingReceives(strict: Bool) throws {
        guard !pendingReceives.isEmpty else {
            guard strict else { return }
            throw TestFailure.noReceivedActionsToSkip()
        }

        guard let latestPendingReceive = pendingReceives.last else { return }
        assertedState = latestPendingReceive.resultingState
        domainState = latestPendingReceive.resultingState
        pendingReceives.removeAll()
    }

    private func waitForEffectsToFinish(timeout: Duration) async throws {
        guard !inFlightEffects.isEmpty else { return }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

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
        previousState: DomainState,
        actualState: DomainState,
        assert update: ((inout DomainState) throws -> Void)?
    ) throws {
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
                operation: operation,
                expected: expectedState,
                actual: actualState
            )
        }
    }
}

private func describe<T>(_ value: T) -> String {
    String(reflecting: value)
}
