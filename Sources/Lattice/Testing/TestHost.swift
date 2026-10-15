/// The test engine shared by ``TestModel`` and ``TestViewModel``: it runs the feature's `Core` and
/// records every commit made outside the action under test until an assertion describes it.
///
/// Nonisolated and non-Sendable like `Core`, and only touched on the test shell's isolation: its
/// `async` members are `nonisolated(nonsending)`, so they run, and resume after every suspension,
/// on the isolation of the shell that calls them. Two things cross isolations: the signal stream,
/// which commits and effect starts and finishes yield to wake a waiting `receive`, `finish` or
/// `skipInFlightEffects`, and the one detached deadline task per wait that yields it on timeout.
/// Nothing waits by yielding, sleeping or polling.
///
/// Folding follows TCA 2's test core. During a test `send`, the first commit with an action is the
/// root transition and becomes the baseline; every later commit (a modification an effect made, an
/// action an effect sent) is pending until an assertion consumes it. An assertion folds the run of
/// pending entries it describes into one comparison against `assertedState` plus its `update`.
/// Entries that no assertion describes are consumed once handled: reported (exhaustive) or skipped
/// (`.off`), and the baseline advances past them.
final class TestHost<State: FeatureState, Action> {
    let core: Core<State, Action>
    var exhaustivity: Exhaustivity
    var timeout: Duration

    private let areStatesEqual: ((State, State) -> Bool)?
    /// Where the test created the model; the deinit report points here.
    private let creationLocation: TestIssueLocation
    /// The baseline of the next assertion.
    private var assertedState: State
    /// Commits made outside the send under test, oldest first.
    private var pending: [Received<State, Action>] = []
    /// Set while the send under test runs, until its root transition commits.
    private var isTestSend = false
    /// Set while a `receive`, `finish` or `skipInFlightEffects` waits on `signal`. An `AsyncStream`
    /// takes one waiter at a time.
    private var isWaiting = false
    private var signal: AsyncStream<Void>
    private var signalContinuation: AsyncStream<Void>.Continuation

    /// - Parameter areStatesEqual: Compares states when the feature has no equality of its own.
    init<F: FeatureProtocol>(
        isolation: any Actor,
        initialState: State,
        feature: F,
        areStatesEqual: ((State, State) -> Bool)?,
        exhaustivity: Exhaustivity,
        timeout: Duration,
        location: TestIssueLocation
    ) where F.State == State, F.Action == Action {
        // Commits are gated by the feature's own equality, as in production.
        core = Core(
            isolation: isolation,
            initialState: initialState,
            interactor: feature.interactor,
            areStatesEqual: feature.areStatesEqual
        )
        self.areStatesEqual = feature.areStatesEqual ?? areStatesEqual
        self.exhaustivity = exhaustivity
        self.timeout = timeout
        creationLocation = location
        assertedState = initialState
        (signal, signalContinuation) = Self.makeSignal()
        core.didCommit = { [weak self] action, state in
            self?.didCommit(action, state)
        }
        core.effectsDidChange = { [weak self] in
            self?.signalContinuation.yield()
        }
        if self.areStatesEqual == nil {
            reportTestFailure(.missingStateEquality(State.self), at: location)
        }
    }

    /// The baseline of the next assertion: the state the test last asserted or skipped to.
    var state: State { assertedState }

    /// Handles what is pending (reported when exhaustive, skipped when `.off`), then sends
    /// `action`. Its root transition is the new baseline; the modifications its effects committed
    /// synchronously, up to the first action they sent, are folded in, so `update` describes the
    /// action's change and theirs.
    func send(
        _ action: Action,
        assert update: ((inout State) throws -> Void)?,
        at location: TestIssueLocation
    ) -> Task<Void, Never>? {
        settlePending(at: .send, location: location)
        let previousState = assertedState
        isTestSend = true
        let task = core.send(action)
        isTestSend = false
        foldLeadingModifications()
        assertStateChange(
            operation: "send(\(testDescription(of: action)))",
            previousState: previousState,
            update: update,
            at: location
        )
        return task
    }

    /// Waits on the signal until a pending action matches, until no effect is in flight (failing
    /// right away), or until `timeout` (default ``timeout``). Folds into the assertion the commits
    /// pending before the match (exhaustive: each non-matching action fails; `.off`: they are
    /// skipped) and the modifications committed right after it. A failed `receive` consumes
    /// everything pending.
    nonisolated(nonsending) func receive(
        matching isMatching: (Action) -> Bool,
        expectation: ReceiveExpectation<Action>,
        timeout duration: Duration?,
        assert update: ((inout State) throws -> Void)?,
        at location: TestIssueLocation
    ) async {
        let timeout = duration ?? self.timeout
        if !pending.contains(where: { $0.action.map(isMatching) ?? false }) {
            _ = await waitForSignal(until: .now.advanced(by: timeout), at: location) {
                pending.contains(where: { $0.action.map(isMatching) ?? false }) || core.inFlightTasks.isEmpty
            }
        }
        guard var matchIndex = pending.firstIndex(where: { $0.action.map(isMatching) ?? false }) else {
            failReceive(expectation, timeout: timeout, at: location)
            return
        }
        switch exhaustivity {
        case .on:
            for case let action? in pending[..<matchIndex].map(\.action) {
                reportTestFailure(expectation.unexpected(action, receivedActionLater: true), at: location)
            }
        case .off:
            guard matchIndex > 0 else { break }
            let skipped = Array(pending[..<matchIndex])
            pending.removeFirst(matchIndex)
            matchIndex = 0
            settle(skipped, at: .receive(expectation.description), location: location)
        }
        let previousState = assertedState
        let end = pending[(matchIndex + 1)...].firstIndex { $0.action != nil } ?? pending.endIndex
        assertedState = pending[end - 1].resultingState
        pending.removeFirst(end)
        assertStateChange(
            operation: "receive(\(expectation.description))",
            previousState: previousState,
            update: update,
            at: location
        )
    }

    /// Synchronous. Handles the actions pending ahead of the modifications (reported when
    /// exhaustive: they need `receive`; skipped when `.off`), then folds every modification up to
    /// the next action into one assertion against `assertedState + update`. With nothing left
    /// pending, it asserts the live state.
    func expect(_ update: (inout State) throws -> Void, at location: TestIssueLocation) {
        let leadingActionCount = pending.firstIndex { $0.action == nil } ?? pending.endIndex
        let leadingActions = Array(pending[..<leadingActionCount])
        pending.removeFirst(leadingActionCount)
        settle(leadingActions, at: .expect, location: location)
        let previousState = assertedState
        foldLeadingModifications()
        if pending.isEmpty {
            assertedState = core.committedState
        }
        withoutActuallyEscaping(update) { update in
            assertStateChange(operation: "expect", previousState: previousState, update: update, at: location)
        }
    }

    /// Waits on the signal until `core.inFlightTasks` is empty, re-reading it on every signal since
    /// effects start effects, failing after `timeout` (default ``timeout``); then handles what is
    /// pending (reported when exhaustive, skipped when `.off`).
    nonisolated(nonsending) func finish(timeout duration: Duration?, at location: TestIssueLocation) async {
        let timeout = duration ?? self.timeout
        let didFinish = await waitForSignal(until: .now.advanced(by: timeout), at: location) {
            core.inFlightTasks.isEmpty
        }
        if !didFinish {
            reportTestFailure(
                .expectedEffectsToFinish(count: core.inFlightTasks.count, timeout: timeout),
                at: location
            )
        }
        settlePending(at: .finish, location: location)
    }

    /// Advances the baseline past every pending entry, actions and modifications alike.
    func skipReceived(strict: Bool, at location: TestIssueLocation) {
        guard let last = pending.last else {
            if strict {
                reportTestFailure(.noReceivedCommitsToSkip(), at: location)
            }
            return
        }
        assertedState = last.resultingState
        pending.removeAll()
    }

    /// Cancels every in-flight effect and waits, up to ``timeout``, until they have all finished.
    /// What they commit while unwinding stays pending.
    nonisolated(nonsending) func skipInFlightEffects(strict: Bool, at location: TestIssueLocation) async {
        guard !core.inFlightTasks.isEmpty else {
            if strict {
                reportTestFailure(.noInFlightEffectsToSkip(), at: location)
            }
            return
        }
        let didFinish = await waitForSignal(until: .now.advanced(by: timeout), at: location) {
            // Cancels on every signal: a cancelled effect can still send an action that starts more.
            let inFlightTasks = core.inFlightTasks
            for task in inFlightTasks {
                task.cancel()
            }
            return inFlightTasks.isEmpty
        }
        if !didFinish {
            reportTestFailure(
                .expectedEffectsToFinish(count: core.inFlightTasks.count, timeout: timeout),
                at: location
            )
        }
    }

    /// Teardown, from the shell's `isolated deinit`: handles what is still pending at the line that
    /// created the model, then cancels every effect.
    ///
    /// Best effort: an isolated deinit runs without the test's task-locals, so Swift Testing records
    /// the report as an unattributed warning that cannot fail the test. Exhaustive tests end with
    /// `finish()`.
    func invalidate() {
        settlePending(at: .deallocation, location: creationLocation)
        core.invalidate()
    }

    private func didCommit(_ action: Action?, _ state: State) {
        if isTestSend, action != nil {
            isTestSend = false
            assertedState = state  // the root transition of the send under test
            return
        }
        pending.append(Received(action: action, resultingState: state))
        signalContinuation.yield()
    }

    /// Advances the baseline past the modifications at the front of `pending`, up to its first
    /// action.
    private func foldLeadingModifications() {
        let end = pending.firstIndex { $0.action != nil } ?? pending.endIndex
        guard end > 0 else { return }
        assertedState = pending[end - 1].resultingState
        pending.removeFirst(end)
    }

    private func settlePending(at checkpoint: PendingCheckpoint, location: TestIssueLocation) {
        let entries = pending
        pending.removeAll()
        settle(entries, at: checkpoint, location: location)
    }

    /// Advances the baseline past `entries`, the oldest pending ones (already removed), and handles
    /// them: exhaustive, reported as unhandled; `.off`, reported as skipped when
    /// `showSkippedAssertions`. A modification that left the state equal to what it was is exempt.
    private func settle(
        _ entries: [Received<State, Action>],
        at checkpoint: PendingCheckpoint,
        location: TestIssueLocation
    ) {
        guard let last = entries.last else { return }
        var previousState = assertedState
        var actions: [Action] = []
        var modifications: [ReportedModification<State>] = []
        for entry in entries {
            if let action = entry.action {
                actions.append(action)
            } else if areStatesEqual?(previousState, entry.resultingState) != true {
                modifications.append(ReportedModification(previous: previousState, resulting: entry.resultingState))
            }
            previousState = entry.resultingState
        }
        assertedState = last.resultingState
        guard !actions.isEmpty || !modifications.isEmpty else { return }
        switch exhaustivity {
        case .on:
            reportTestFailure(
                .unhandledCommits(actions: actions, modifications: modifications, at: checkpoint),
                at: location
            )
        case .off(let showSkippedAssertions):
            guard showSkippedAssertions else { return }
            reportTestFailure(
                .skippedCommits(actions: actions, modifications: modifications, at: checkpoint),
                severity: .warning,
                at: location
            )
        }
    }

    /// A failed `receive` (TCA 2): reports the first pending action as the unexpected one when
    /// exhaustive, or that none arrived, then consumes everything pending.
    private func failReceive(
        _ expectation: ReceiveExpectation<Action>,
        timeout: Duration,
        at location: TestIssueLocation
    ) {
        let hasInFlightEffects = !core.inFlightTasks.isEmpty
        if case .on = exhaustivity, let action = pending.lazy.compactMap(\.action).first {
            reportTestFailure(expectation.unexpected(action, receivedActionLater: false), at: location)
        } else {
            reportTestFailure(
                expectation.missing(
                    timeout: hasInFlightEffects ? timeout : nil,
                    hasInFlightEffects: hasInFlightEffects
                ),
                at: location
            )
        }
        if let last = pending.last {
            assertedState = last.resultingState
        }
        pending.removeAll()
    }

    /// Compares `previousState` with `update` applied against `assertedState`, which the caller has
    /// advanced to the state the assertion describes. No `update` asserts that nothing changed.
    private func assertStateChange(
        operation: @autoclosure () -> String,
        previousState: State,
        update: ((inout State) throws -> Void)?,
        at location: TestIssueLocation
    ) {
        guard let areStatesEqual else {
            reportTestFailure(.missingStateEquality(State.self), at: location)
            return
        }
        var expectedState = previousState
        if let update {
            do {
                try update(&expectedState)
            } catch {
                reportTestFailure(.assertionThrew(operation: operation(), error: error), at: location)
                return
            }
        }
        if !areStatesEqual(expectedState, assertedState) {
            reportTestFailure(
                .stateMutationDidNotMatchExpectation(
                    expected: expectedState,
                    actual: assertedState,
                    didExpectStateChange: update != nil
                ),
                at: location
            )
        }
    }

    /// Suspends on `signal` until `isDone()` holds, re-evaluating it after every signal: a commit,
    /// an effect starting or finishing, or the deadline. Returns `false` once `deadline` has passed
    /// or the waiting task is cancelled (which ends the stream), `true` when `isDone()` holds.
    private nonisolated(nonsending) func waitForSignal(
        until deadline: ContinuousClock.Instant,
        at location: TestIssueLocation,
        _ isDone: () -> Bool
    ) async -> Bool {
        guard !isDone() else { return true }
        guard !isWaiting else {
            reportTestFailure(.overlappingWait(), at: location)
            return false
        }
        isWaiting = true
        defer { isWaiting = false }
        let continuation = signalContinuation
        let deadlineTask = Task.detached {
            guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
            continuation.yield()
        }
        defer { deadlineTask.cancel() }
        for await _ in signal {
            if isDone() { return true }
            if ContinuousClock.now >= deadline { return false }
        }
        // Only a cancelled wait ends the stream, and an ended stream never yields again: later waits
        // get a new one.
        (signal, signalContinuation) = Self.makeSignal()
        return isDone()
    }

    private static func makeSignal() -> (AsyncStream<Void>, AsyncStream<Void>.Continuation) {
        AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }
}

/// What a `receive` waits for, and how its failures describe it.
enum ReceiveExpectation<Action> {
    /// The `Equatable` overload: failures show the expected action, diffed against a received one.
    case action(Action)
    /// The predicate and case-path overloads.
    case matching(String)

    var description: String {
        switch self {
        case .action(let action):
            testDescription(of: action)
        case .matching(let description):
            description
        }
    }

    func unexpected(_ action: Action, receivedActionLater: Bool) -> TestFailure {
        switch self {
        case .action(let expectedAction):
            .unexpectedReceivedAction(action, expected: expectedAction, receivedActionLater: receivedActionLater)
        case .matching(let description):
            .unexpectedReceivedAction(action, expected: description, receivedActionLater: receivedActionLater)
        }
    }

    func missing(timeout: Duration?, hasInFlightEffects: Bool) -> TestFailure {
        switch self {
        case .action(let expectedAction):
            .expectedToReceiveAction(expectedAction, timeout: timeout, hasInFlightEffects: hasInFlightEffects)
        case .matching(let description):
            .expectedToReceiveAction(description, timeout: timeout, hasInFlightEffects: hasInFlightEffects)
        }
    }
}
