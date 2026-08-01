import DequeModule
import Foundation

#if canImport(CasePaths)
    import CasePaths
#endif

/// A domain-state-first testing host for a Lattice feature.
///
/// `TestViewModel` hosts the same core engine as ``ViewModel`` — same commit funnel, same
/// effect launch, same cancellation semantics — installing a recording commit strategy in
/// place of the production projection diff (`_commit` into the registrar, plan 05). The
/// contract is step-wise and exhaustive:
///
/// - ``send(_:changes:fileID:file:line:column:)`` asserts the update-phase mutation.
/// - ``expect(changes:timeout:fileID:file:line:column:)`` asserts the next
///   `effectState.modify` commit.
/// - ``receive(_:changes:timeout:fileID:file:line:column:)`` asserts the next
///   `effectState.send` re-entry and its update-phase mutation.
/// - Under ``Exhaustivity/on``, unasserted commits fail at deinit — prefer an explicit
///   ``dismount(timeout:fileID:file:line:column:)`` so the failure lands at a source location.
///
/// `DomainState: Equatable` is required: snapshot-diff assertions compare with `==`.
///
/// Note that an effect may commit synchronously before its first suspension — those commits
/// are already pending by the time `send` returns, so `expect`/`receive` can succeed without
/// any actual waiting.
@MainActor
public final class TestViewModel<DomainState: Equatable, Action> {
    /// The most recently asserted domain state.
    public private(set) var domainState: DomainState

    /// Controls whether pending commits must be asserted before later sends and deinit.
    public var exhaustivity: Exhaustivity = .on

    /// The default timeout used by APIs that accept an optional timeout.
    public var timeout: Duration = .seconds(1)

    private let core: LatticeCore<DomainState, Action>
    // 'nonisolated(unsafe)' solely so the deinit backstop below can read it: every other
    // access is MainActor-isolated by the class, and deinit runs with exclusive access
    // (refcount zero — same argument as LatticeCore's deinit).
    private nonisolated(unsafe) var pendingCommits: Deque<PendingCommit<DomainState, Action>> = []

    /// Waiters parked by `nextPendingCommit`, resumed by the recorder on every commit
    /// (`true`) or by their own deadline task (`false`).
    private var commitWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// One-shot capture slot for the update-phase commit of the test's own `send`, consumed
    /// synchronously instead of queued.
    private var ownSendCommit: DomainState?
    private var isOwnSendInProgress = false

    /// Every effect task the core launched, for `finish`/`dismount` quiescence.
    private var launchedEffectTasks: [Task<Void, Never>] = []

    /// Creates a test host over the given interactor tree.
    ///
    /// - Parameters:
    ///   - initialDomainState: The initial domain state value.
    ///   - interactor: The feature's interactor tree.
    public init(
        initialDomainState: DomainState,
        interactor: some Interactor<DomainState, Action>
    ) {
        self.domainState = initialDomainState
        let core = LatticeCore<DomainState, Action>(
            initialState: initialDomainState,
            isolation: MainActor.shared
        )
        self.core = core

        // Same mount call as ViewModel — the root effects handle walks the interactor tree
        // from the root path — with the snapshot recorder installed as the commit hook
        // instead of the production projection diff.
        let rootEffects = _makeEffectsHandles(core: core, lens: .identity, path: GraphPath())
        core.mount(
            interact: { state, action in
                interactor.interact(state: &state, action: action, effects: rootEffects)
            },
            onCommit: { [weak self] previous, current, origin in
                self?.record(previous: previous, current: current, origin: origin)
            },
            onEffectLaunched: { [weak self] _, task in
                self?.launchedEffectTasks.append(task)
            }
        )
    }

    deinit {
        // Backstop only: prefer 'dismount()' so the failure carries a useful source location.
        // Core teardown (bucket cancellation) happens in the core's own deinit — TestViewModel
        // has no other teardown.
        if exhaustivity == .on, !pendingCommits.isEmpty {
            let message = TestFailure.unassertedCommitsAtDeinit(pendingCommits).message
            reportIssueHelper(
                message,
                at: .init(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
            )
        }
    }

    // MARK: - Send

    /// Sends an action and asserts the synchronous update-phase mutation via snapshot diff.
    ///
    /// A `nil` `changes` closure asserts that the update made no visible state change.
    ///
    /// - Returns: A ``TestEventTask`` over the effects this send launched directly.
    @discardableResult
    public func send(
        _ action: Action,
        changes: ((inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestEventTask {
        let location = TestIssueLocation(
            fileID: fileID, filePath: filePath, line: line, column: column
        )

        if exhaustivity == .on, !pendingCommits.isEmpty {
            reportTestFailure(
                .mustAssertCommitsBeforeSending(pendingCommits), at: location
            )
            return TestEventTask(rawValue: nil, timeout: timeout)
        }

        isOwnSendInProgress = true
        ownSendCommit = nil
        let sendTask: Task<Void, Never>?
        do {
            sendTask = try core.send(action)
        } catch {
            isOwnSendInProgress = false
            reportTestFailure(.sendAfterDismount(action), at: location)
            return TestEventTask(rawValue: nil, timeout: timeout)
        }
        isOwnSendInProgress = false

        // The update-phase commit for our own send fires synchronously inside 'core.send',
        // before any effect commit can interleave (pinned by the core suite); consume it
        // immediately rather than queueing it.
        let committed = ownSendCommit ?? core.currentState
        ownSendCommit = nil
        assertDiff(changes: changes, against: committed, operation: "send", at: location)
        return TestEventTask(rawValue: sendTask, timeout: timeout)
    }

    // MARK: - Expect (effectState.modify commits)

    /// Asserts the next effect-phase commit (an `effectState.modify`) via snapshot diff,
    /// waiting up to `timeout` for one to arrive.
    ///
    /// Under ``Exhaustivity/off(showSkippedAssertions:)``, earlier action re-entries are
    /// skipped silently.
    public func expect(
        changes: ((inout DomainState) throws -> Void)? = nil,
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        let location = TestIssueLocation(
            fileID: fileID, filePath: filePath, line: line, column: column
        )
        let timeout = duration ?? self.timeout
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while let commit = await nextPendingCommit(until: deadline) {
            switch commit {
            case .mutation(let resulting):
                assertDiff(changes: changes, against: resulting, operation: "expect", at: location)
                return

            case .action(let action, resulting: let resulting):
                if case .off = exhaustivity {
                    domainState = resulting
                    continue
                }
                reportTestFailure(.expectedMutationButReceivedAction(action), at: location)
                return
            }
        }
        reportTestFailure(.expectedCommit(timeout: timeout), at: location)
    }

    // MARK: - Receive (effectState.send re-entries)

    /// Asserts the next `effectState.send` re-entry: the action must match, and `changes`
    /// asserts its update-phase mutation.
    ///
    /// Under ``Exhaustivity/off(showSkippedAssertions:)``, earlier non-matching commits are
    /// skipped silently.
    public func receive(
        _ expectedAction: Action,
        changes: ((inout DomainState) throws -> Void)? = nil,
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async where Action: Equatable {
        await receive(
            expectedDescription: { describeForFailure(expectedAction) },
            matches: { $0 == expectedAction },
            mismatch: { .unexpectedReceivedAction($0, expected: expectedAction) },
            changes: changes,
            timeout: duration ?? timeout,
            location: TestIssueLocation(
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        )
    }

    #if canImport(CasePaths)
        /// Case-path variant of ``receive(_:changes:timeout:fileID:file:line:column:)``:
        /// matches the next `effectState.send` re-entry against the given case of `Action`.
        public func receive<Value>(
            _ actionKeyPath: KeyPath<Action.AllCasePaths, AnyCasePath<Action, Value>>,
            changes: ((inout DomainState) throws -> Void)? = nil,
            timeout duration: Duration? = nil,
            fileID: StaticString = #fileID,
            file filePath: StaticString = #filePath,
            line: UInt = #line,
            column: UInt = #column
        ) async where Action: CasePathable {
            let casePath = Action.allCasePaths[keyPath: actionKeyPath]
            await receive(
                expectedDescription: { "an action matching the given case path" },
                matches: { casePath.extract(from: $0) != nil },
                mismatch: {
                    .unexpectedReceivedAction($0, expected: "an action matching the given case path")
                },
                changes: changes,
                timeout: duration ?? timeout,
                location: TestIssueLocation(
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            )
        }
    #endif

    private func receive(
        expectedDescription: () -> String,
        matches: (Action) -> Bool,
        mismatch: (Action) -> TestFailure,
        changes: ((inout DomainState) throws -> Void)?,
        timeout: Duration,
        location: TestIssueLocation
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while let commit = await nextPendingCommit(until: deadline) {
            switch commit {
            case .mutation(let resulting):
                if case .off = exhaustivity {
                    domainState = resulting
                    continue
                }
                reportTestFailure(
                    .expectedActionButReceivedMutation(expected: expectedDescription()),
                    at: location
                )
                return

            case .action(let action, resulting: let resulting):
                if matches(action) {
                    assertDiff(
                        changes: changes, against: resulting, operation: "receive", at: location
                    )
                    return
                }
                if case .off = exhaustivity {
                    domainState = resulting
                    continue
                }
                reportTestFailure(mismatch(action), at: location)
                return
            }
        }
        reportTestFailure(
            .expectedToReceiveAction(expectedDescription(), timeout: timeout), at: location
        )
    }

    // MARK: - Skipping / quiescence

    /// Consumes all pending commits without asserting them (non-exhaustive escape hatch),
    /// advancing ``domainState`` to the latest committed state.
    public func skipPendingCommits(
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) {
        guard !pendingCommits.isEmpty else {
            reportTestFailure(
                .noPendingCommitsToSkip(),
                at: TestIssueLocation(
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            )
            return
        }
        while let commit = pendingCommits.popFirst() {
            domainState = commit.resultingState
        }
    }

    /// Waits for every in-flight effect task to complete, then (under ``Exhaustivity/on``)
    /// reports any commits still unasserted.
    ///
    /// If the effects do not complete within the timeout, the failure is reported and the
    /// still-running effects are cancelled so the test can proceed.
    public func finish(
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        let location = TestIssueLocation(
            fileID: fileID, filePath: filePath, line: line, column: column
        )
        let timeout = duration ?? self.timeout
        let tasks = launchedEffectTasks
        if !tasks.isEmpty {
            let finished = await raceAgainstTimeout(timeout) {
                for task in tasks {
                    await task.cancellableValue
                }
            }
            if !finished {
                reportTestFailure(.effectsDidNotFinish(timeout: timeout), at: location)
            }
        }
        if exhaustivity == .on, !pendingCommits.isEmpty {
            reportTestFailure(.unassertedCommits(pendingCommits), at: location)
        }
    }

    /// Dismounts the feature: cancels every task bucket (outstanding event tasks complete as
    /// the cancelled effects wind down) and (under ``Exhaustivity/on``) fails on unasserted
    /// commits.
    public func dismount(
        timeout duration: Duration = .zero,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        let tasks = launchedEffectTasks
        core.dismount()
        if !tasks.isEmpty {
            _ = await raceAgainstTimeout(duration) {
                for task in tasks {
                    await task.cancellableValue
                }
            }
        }
        if exhaustivity == .on, !pendingCommits.isEmpty {
            reportTestFailure(
                .unassertedCommits(pendingCommits),
                at: TestIssueLocation(
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            )
        }
        pendingCommits.removeAll()
    }

    // MARK: - The recorder (installed via the core's onCommit mount hook)

    private func record(
        previous: DomainState,
        current: DomainState,
        origin: CommitOrigin<Action>
    ) {
        switch origin {
        case .send(let action):
            if isOwnSendInProgress {
                // Consumed synchronously by send(_:changes:); parked in a one-slot buffer.
                // Cleared here so a synchronous effect-prefix 'effectState.send' re-entry
                // (which fires before core.send returns) queues as pending.
                ownSendCommit = current
                isOwnSendInProgress = false
            } else {
                pendingCommits.append(.action(action, resulting: current))
            }
        case .modify:
            pendingCommits.append(.mutation(resulting: current))
        }
        let waiters = commitWaiters
        commitWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.resume(returning: true)
        }
    }

    // MARK: - Waiting

    /// Pops the next pending commit, waiting until `deadline` for one to arrive. Commits are
    /// signaled synchronously by the funnel, and effect sync-prefixes have already run by the
    /// time `send` returns, so this only actually suspends for genuinely asynchronous effects.
    private func nextPendingCommit(
        until deadline: ContinuousClock.Instant
    ) async -> PendingCommit<DomainState, Action>? {
        while pendingCommits.isEmpty {
            guard ContinuousClock.now < deadline else { return nil }
            let signaled = await waitForCommitSignal(until: deadline)
            if !signaled, pendingCommits.isEmpty { return nil }
        }
        return pendingCommits.removeFirst()
    }

    /// Parks until the recorder signals a commit (`true`) or the deadline passes (`false`).
    private func waitForCommitSignal(until deadline: ContinuousClock.Instant) async -> Bool {
        let id = UUID()
        let deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            if let waiter = self?.commitWaiters.removeValue(forKey: id) {
                waiter.resume(returning: false)
            }
        }
        defer { deadlineTask.cancel() }
        return await withCheckedContinuation { continuation in
            commitWaiters[id] = continuation
        }
    }

    // MARK: - Snapshot diff

    /// Applies `changes` to a copy of the asserted state and compares against the actually
    /// committed state with `==`, reporting mismatches with CustomDump's diff. On completion
    /// the asserted state advances to the committed state either way, so one mismatch does
    /// not cascade.
    private func assertDiff(
        changes: ((inout DomainState) throws -> Void)?,
        against actual: DomainState,
        operation: String,
        at location: TestIssueLocation
    ) {
        defer { domainState = actual }

        var expected = domainState
        do {
            try changes?(&expected)
        } catch {
            reportTestFailure(.assertionThrew(operation: operation, error: error), at: location)
            return
        }
        if expected != actual {
            reportTestFailure(
                .stateMutationDidNotMatchExpectation(
                    expected: expected,
                    actual: actual,
                    didExpectStateChange: changes != nil
                ),
                at: location
            )
        }
    }
}

// MARK: - View-layer assertions

extension TestViewModel where DomainState: FeatureStateProtocol {
    /// The generated view projection over the committed state — the same surface a view
    /// reads, compile-checked against the visible members:
    ///
    /// ```swift
    /// #expect(testViewModel.projection.subtitle == "3 results")
    /// ```
    ///
    /// The test host leaves `_commit` unwired (the commit hook carries the recorder instead),
    /// so each access builds a fresh registrar: derived members always compute from the
    /// current committed state, and nothing is observed across commits. Projection/registrar
    /// behavior itself (granularity, poke batching) is covered by the feature-state suite.
    public var projection: FeatureProjection<DomainState> {
        FeatureProjection(
            read: { [core] in core.currentState },
            registrar: FeatureStateRegistrar(),
            key: ProjectionKey()
        )
    }
}

private func describeForFailure<T>(_ value: T) -> String {
    #if canImport(CustomDump)
        return String(customDumping: value)
    #else
        return String(reflecting: value)
    #endif
}

#if canImport(CustomDump)
    import CustomDump
#endif
