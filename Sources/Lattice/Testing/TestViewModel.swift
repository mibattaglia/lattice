import Foundation

#if canImport(CasePaths)
    import CasePaths
#endif
#if canImport(Testing)
    import Testing
#endif

@MainActor
public final class TestViewModel<F: FeatureProtocol> {
    public typealias Action = F.Action
    public typealias DomainState = F.DomainState
    public typealias ViewState = F.ViewState

    public enum Exhaustivity: Sendable {
        case on
        case off(showSkippedAssertions: Bool = false)
    }

    private struct ReceivedStep {
        let action: Action
        let domainState: DomainState
        let viewState: ViewState
        let originID: UUID
    }

    private struct SentStepSnapshot {
        let domainState: DomainState
        let viewState: ViewState
        let previousState: DomainState
    }

    public private(set) var domainState: DomainState
    public private(set) var viewState: ViewState
    public var exhaustivity: Exhaustivity = .on

    private let defaultTimeout: Duration
    private let taskRegistry: EffectTaskRegistry
    private let runtime: FeatureRuntime<DomainState, Action>
    private let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    private let areStatesEqual: (_ lhs: DomainState, _ rhs: DomainState) -> Bool

    private var bufferedReceivedSteps: [ReceivedStep] = []
    private var bufferedViewState: ViewState
    private var pendingSentSnapshots: [UUID: SentStepSnapshot] = [:]

    public init(
        initialDomainState: DomainState,
        feature: F,
        timeout: Duration = .seconds(1)
    ) {
        self.defaultTimeout = timeout
        self.taskRegistry = EffectTaskRegistry()
        self.runtime = FeatureRuntime(
            initialState: initialDomainState,
            interactor: feature.interactor,
            taskRegistry: taskRegistry
        )
        self.viewStateReducer = feature.viewStateReducer
        self.areStatesEqual = feature.areStatesEqual
        self.domainState = initialDomainState

        var initialViewState = feature.makeInitialViewState(initialDomainState)
        feature.viewStateReducer.reduce(initialDomainState, into: &initialViewState)
        self.viewState = initialViewState
        self.bufferedViewState = initialViewState

        runtime.setStepHandler { [weak self] step in
            self?.handle(step: step)
        }
    }

    @discardableResult
    public func send(
        _ action: Action,
        assert updateExpectedState: ((_ state: inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestEventTask {
        if case .on = exhaustivity, !bufferedReceivedSteps.isEmpty {
            reportFailure(
                """
                Must handle \(bufferedReceivedSteps.count) received action\(bufferedReceivedSteps.count == 1 ? "" : "s") before sending another action.

                Unhandled actions:
                \(bufferedReceivedSteps.map { "  \(String(describing: $0.action))" }.joined(separator: "\n"))
                """,
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
            return TestEventTask()
        }

        bufferedViewState = bufferedReceivedSteps.last?.viewState ?? viewState

        let result = runtime.send(action)
        if result.startedEmissionCount > 0 {
            await Task.yield()
        }

        guard let sentSnapshot = pendingSentSnapshots.removeValue(forKey: result.originID) else {
            reportFailure(
                "Missing sent-step snapshot for \(String(describing: action)).",
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
            return makeTestEventTask(originID: result.originID)
        }

        assertStateChange(
            from: domainState,
            to: sentSnapshot.domainState,
            updateExpectedState: updateExpectedState,
            fileID: fileID,
            file: file,
            line: line,
            column: column
        )

        domainState = sentSnapshot.domainState
        viewState = sentSnapshot.viewState
        refreshBufferedViewState()

        return makeTestEventTask(originID: result.originID)
    }

    public func receive(
        _ expectedAction: Action,
        timeout: Duration? = nil,
        assert updateExpectedState: ((_ state: inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async where Action: Equatable {
        await receive(
            { $0 == expectedAction },
            timeout: timeout,
            actionDescription: String(describing: expectedAction),
            assert: updateExpectedState,
            fileID: fileID,
            file: file,
            line: line,
            column: column
        )
    }

    public func receive(
        _ isMatching: (Action) -> Bool,
        timeout: Duration? = nil,
        assert updateExpectedState: ((_ state: inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        await receive(
            isMatching,
            timeout: timeout,
            actionDescription: "matching received action",
            assert: updateExpectedState,
            fileID: fileID,
            file: file,
            line: line,
            column: column
        )
    }

    #if canImport(CasePaths)
        public func receive<Case>(
            _ casePath: AnyCasePath<Action, Case>,
            timeout: Duration? = nil,
            assert updateExpectedState: ((_ state: inout DomainState) throws -> Void)? = nil,
            fileID: StaticString = #fileID,
            file: StaticString = #filePath,
            line: UInt = #line,
            column: UInt = #column
        ) async {
            await receive(
                { casePath.extract(from: $0) != nil },
                timeout: timeout,
                actionDescription: casePath.debugDescription,
                assert: updateExpectedState,
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
        }
    #endif

    public func finish(
        timeout: Duration? = nil,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        guard bufferedReceivedSteps.isEmpty else {
            reportFailure(
                """
                Must handle \(bufferedReceivedSteps.count) received action\(bufferedReceivedSteps.count == 1 ? "" : "s") before finishing.

                Unhandled actions:
                \(bufferedReceivedSteps.map { "  \(String(describing: $0.action))" }.joined(separator: "\n"))
                """,
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
            return
        }

        let result = await runtime.finish(timeout: timeout ?? defaultTimeout)
        guard result.didTimeout else { return }

        reportFailure(
            finishTimeoutMessage(
                timeout: timeout ?? defaultTimeout,
                inFlightEmissionCount: result.inFlightEmissionCount
            ),
            fileID: fileID,
            file: file,
            line: line,
            column: column
        )
    }

    public func skipReceivedActions(
        strict: Bool = true,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        guard let lastStep = bufferedReceivedSteps.last else {
            if strict {
                reportFailure(
                    "There are no buffered received actions to skip.",
                    fileID: fileID,
                    file: file,
                    line: line,
                    column: column
                )
            }
            return
        }

        if shouldShowSkippedAssertions {
            reportFailure(
                """
                Skipped received actions:
                \(bufferedReceivedSteps.map { "  \(String(describing: $0.action))" }.joined(separator: "\n"))
                """,
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
        }

        domainState = lastStep.domainState
        viewState = lastStep.viewState
        bufferedReceivedSteps.removeAll()
        refreshBufferedViewState()
    }

    public func skipInFlightEffects(
        strict: Bool = true,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        guard runtime.hasInFlightEmissions() else {
            if strict {
                reportFailure(
                    "There are no in-flight emissions to skip.",
                    fileID: fileID,
                    file: file,
                    line: line,
                    column: column
                )
            }
            return
        }

        taskRegistry.cancelAll()
        let result = await runtime.finish(timeout: defaultTimeout)

        if shouldShowSkippedAssertions {
            reportFailure(
                """
                Skipped \(result.inFlightEmissionCount) in-flight emission\(result.inFlightEmissionCount == 1 ? "" : "s").
                """,
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
        }
    }

    public func assertViewState(
        _ expected: ViewState,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) where ViewState: Equatable {
        guard viewState == expected else {
            reportFailure(
                """
                View state does not match expectation.

                  expected: \(String(describing: expected))
                  actual:   \(String(describing: viewState))
                """,
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
            return
        }
    }

    private var shouldShowSkippedAssertions: Bool {
        if case .off(let showSkippedAssertions) = exhaustivity {
            return showSkippedAssertions
        }
        return false
    }

    private func receive(
        _ isMatching: (Action) -> Bool,
        timeout: Duration?,
        actionDescription: String,
        assert updateExpectedState: ((_ state: inout DomainState) throws -> Void)?,
        fileID: StaticString,
        file: StaticString,
        line: UInt,
        column: UInt
    ) async {
        guard let receivedStep = await nextReceivedStep(timeout: timeout ?? defaultTimeout) else {
            reportFailure(
                "Expected to receive \(actionDescription), but no buffered received action arrived before the timeout.",
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
            return
        }

        guard isMatching(receivedStep.action) else {
            reportFailure(
                """
                Received an unexpected action.

                  expected: \(actionDescription)
                  actual:   \(String(describing: receivedStep.action))
                """,
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
            return
        }

        bufferedReceivedSteps.removeFirst()
        assertStateChange(
            from: domainState,
            to: receivedStep.domainState,
            updateExpectedState: updateExpectedState,
            fileID: fileID,
            file: file,
            line: line,
            column: column
        )

        domainState = receivedStep.domainState
        viewState = receivedStep.viewState
        refreshBufferedViewState()
    }

    private func nextReceivedStep(timeout: Duration) async -> ReceivedStep? {
        if let firstStep = bufferedReceivedSteps.first {
            return firstStep
        }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while bufferedReceivedSteps.isEmpty {
            guard clock.now < deadline else { return nil }
            await Task.yield()
        }

        return bufferedReceivedSteps.first
    }

    private func handle(step: FeatureRuntime<DomainState, Action>.Step) {
        var nextViewState = bufferedViewState
        let shouldReduceViewState =
            step.source == .emitted || !areStatesEqual(step.previousState, step.currentState)

        if shouldReduceViewState {
            viewStateReducer.reduce(step.currentState, into: &nextViewState)
        }

        bufferedViewState = nextViewState

        switch step.source {
        case .sent:
            pendingSentSnapshots[step.originID] = SentStepSnapshot(
                domainState: step.currentState,
                viewState: nextViewState,
                previousState: step.previousState
            )

        case .emitted:
            bufferedReceivedSteps.append(
                ReceivedStep(
                    action: step.action,
                    domainState: step.currentState,
                    viewState: nextViewState,
                    originID: step.originID
                )
            )
        }
    }

    private func assertStateChange(
        from currentState: DomainState,
        to actualState: DomainState,
        updateExpectedState: ((_ state: inout DomainState) throws -> Void)?,
        fileID: StaticString,
        file: StaticString,
        line: UInt,
        column: UInt
    ) {
        var expectedState = currentState

        do {
            try updateExpectedState?(&expectedState)
        } catch {
            reportFailure(
                "State assertion threw an error: \(String(describing: error))",
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
            return
        }

        guard areStatesEqual(expectedState, actualState) else {
            reportFailure(
                """
                A state change does not match expectation.

                  expected: \(String(describing: expectedState))
                  actual:   \(String(describing: actualState))
                """,
                fileID: fileID,
                file: file,
                line: line,
                column: column
            )
            return
        }
    }

    private func refreshBufferedViewState() {
        bufferedViewState = bufferedReceivedSteps.last?.viewState ?? viewState
    }

    private func makeTestEventTask(originID: UUID) -> TestEventTask {
        let taskRegistry = self.taskRegistry
        return TestEventTask(
            cancelOperation: {
                taskRegistry.cancel(originID: originID)
            },
            finishOperation: { [weak runtime, defaultTimeout] timeout, fileID, file, line, column in
                guard let runtime else { return }
                let resolvedTimeout = timeout ?? defaultTimeout
                let result = await runtime.finish(originID: originID, timeout: resolvedTimeout)
                guard result.didTimeout else { return }

                await MainActor.run {
                    reportFailure(
                        finishTimeoutMessage(
                            timeout: resolvedTimeout,
                            inFlightEmissionCount: result.inFlightEmissionCount
                        ),
                        fileID: fileID,
                        file: file,
                        line: line,
                        column: column
                    )
                }
            },
            isCancelledOperation: { [taskRegistry] in
                taskRegistry.isCancelled(originID: originID)
            }
        )
    }
}

private func finishTimeoutMessage(
    timeout: Duration,
    inFlightEmissionCount: Int
) -> String {
    return """
    Expected emissions to finish, but there are still \(inFlightEmissionCount) in flight after \(timeout).

    If this feature uses a test clock, advance it so that the effect may complete.
    If this is a long-living effect, cancel it explicitly or call skipInFlightEffects().
    """
}

@MainActor
private func reportFailure(
    _ message: String,
    fileID: StaticString,
    file: StaticString,
    line: UInt,
    column: UInt
) {
    #if canImport(Testing)
        Issue.record("\(message)\nLocation: \(file):\(line):\(column)")
    #else
        fatalError("\(message)\nLocation: \(file):\(line):\(column)")
    #endif
}
