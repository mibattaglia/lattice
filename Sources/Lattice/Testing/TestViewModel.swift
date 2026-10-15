#if canImport(CasePaths)
    import CasePaths
#endif

/// The main-actor test shell: ``TestModel``'s contract for features that must run on the main actor.
///
/// Use it for an interactor that is main-actor-isolated (declared in a module with main-actor
/// default isolation, or capturing `@MainActor` values) and for tests that must run on the main
/// actor; ``TestModel`` cannot host either. Effects run on the main actor, as under ``ViewModel``.
/// Unlike ``TestModel``, the initializer and ``send(_:assert:fileID:filePath:line:column:)`` are
/// synchronous and ``exhaustivity`` and ``timeout`` are settable properties.
///
/// The testing contract:
///
/// - ``send(_:assert:fileID:filePath:line:column:)`` asserts the action's change, plus the
///   modifications its effects made before their first suspension.
/// - ``receive(_:timeout:assert:fileID:filePath:line:column:)`` waits for an action an effect sent
///   and asserts it, folding in the modifications around it.
/// - ``expect(_:fileID:filePath:line:column:)`` asserts the modifications effects made, which are
///   how effects deliver their results.
/// - ``state`` is the state the test last asserted, not commits still pending.
/// - ``finish(timeout:fileID:filePath:line:column:)`` waits for every effect, then fails on what was
///   never asserted.
///
/// With ``Exhaustivity/on`` every commit must be asserted. End exhaustive tests with `finish()`: the
/// model also reports what is still pending when it is deallocated, but its deinit runs without the
/// test's context, so that report is a warning that cannot fail the test. Deallocating the model
/// cancels its effects.
///
/// Assertions compare states with the feature's ``FeatureProtocol/areStatesEqual``, or with the
/// equality passed to ``init(initialState:feature:areStatesEqual:exhaustivity:timeout:fileID:filePath:line:column:)``
/// when the feature has none.
@MainActor
public final class TestViewModel<F: FeatureProtocol> {
    public typealias Action = F.Action
    public typealias State = F.State

    private let host: TestHost<State, Action>

    /// Creates a test model for a feature.
    ///
    /// Assertions compare states with the feature's ``FeatureProtocol/areStatesEqual``. If the
    /// feature has none, an issue is reported here and every state assertion fails; use
    /// ``init(initialState:feature:areStatesEqual:exhaustivity:timeout:fileID:filePath:line:column:)``
    /// for such a feature.
    ///
    /// - Parameters:
    ///   - initialState: The initial state value.
    ///   - feature: The feature bundle containing the interactor and the state equality.
    ///   - exhaustivity: Whether every commit must be asserted.
    ///   - timeout: How long `receive`, `finish` and `skipInFlightEffects` wait by default.
    public init(
        initialState: State,
        feature: F,
        exhaustivity: Exhaustivity = .on,
        timeout: Duration = .seconds(1),
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) {
        host = TestHost(
            isolation: MainActor.shared,
            initialState: initialState,
            feature: feature,
            areStatesEqual: nil,
            exhaustivity: exhaustivity,
            timeout: timeout,
            location: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    /// Creates a test model for a feature, comparing states with `areStatesEqual` when the feature
    /// has no ``FeatureProtocol/areStatesEqual`` of its own.
    ///
    /// Use it for a state that is not `Equatable`. The feature's equality takes precedence, so a
    /// custom comparison for an `Equatable` state belongs in `Feature(interactor:areStatesEqual:)`.
    public init(
        initialState: State,
        feature: F,
        areStatesEqual: @escaping (_ lhs: State, _ rhs: State) -> Bool,
        exhaustivity: Exhaustivity = .on,
        timeout: Duration = .seconds(1),
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) {
        host = TestHost(
            isolation: MainActor.shared,
            initialState: initialState,
            feature: feature,
            areStatesEqual: areStatesEqual,
            exhaustivity: exhaustivity,
            timeout: timeout,
            location: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    /// The state the test last asserted (or skipped to). Commits still pending are not in it.
    public var state: State {
        host.state
    }

    /// Whether every commit must be asserted.
    public var exhaustivity: Exhaustivity {
        get { host.exhaustivity }
        set { host.exhaustivity = newValue }
    }

    /// How long `receive`, `finish` and `skipInFlightEffects` wait when not given a timeout.
    public var timeout: Duration {
        get { host.timeout }
        set { host.timeout = newValue }
    }

    /// Sends an action and asserts the resulting state.
    ///
    /// The action is processed synchronously: when `send` returns, every effect it started has run
    /// to its first suspension. `update` describes the action's change plus the modifications those
    /// effects made before suspending. Exhaustive: anything still pending is reported first; `.off`:
    /// it is skipped.
    ///
    /// - Returns: The task for the effects this action started (not for effects those effects
    ///   start), or `nil` when it started none.
    @discardableResult
    public func send(
        _ action: Action,
        assert update: ((inout State) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> Task<Void, Never>? {
        host.send(
            action,
            assert: update,
            at: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    /// Waits for an effect to send `expectedAction` and asserts the resulting state.
    ///
    /// Waits until the action is pending, until no effect is left in flight, or for `timeout`
    /// (default: ``timeout``). `update` describes the modifications pending before the action, the
    /// action's change and the modifications committed right after it. Exhaustive: a different
    /// action pending before it fails.
    public func receive(
        _ expectedAction: Action,
        timeout duration: Duration? = nil,
        assert update: ((inout State) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async where Action: Equatable {
        await host.receive(
            matching: { $0 == expectedAction },
            expectation: .action(expectedAction),
            timeout: duration,
            assert: update,
            at: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    /// Waits for an effect to send an action matching `isMatching` and asserts the resulting state,
    /// like ``receive(_:timeout:assert:fileID:filePath:line:column:)``.
    public func receive(
        _ isMatching: (_ action: Action) -> Bool,
        timeout duration: Duration? = nil,
        assert update: ((inout State) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        await host.receive(
            matching: isMatching,
            expectation: .matching("an action matching predicate"),
            timeout: duration,
            assert: update,
            at: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    #if canImport(CasePaths)
        /// Waits for an effect to send an action of the case `actionCase` and asserts the resulting
        /// state, like ``receive(_:timeout:assert:fileID:filePath:line:column:)``.
        public func receive<Value>(
            _ actionCase: KeyPath<Action.AllCasePaths, AnyCasePath<Action, Value>>,
            timeout duration: Duration? = nil,
            assert update: ((inout State) throws -> Void)? = nil,
            fileID: StaticString = #fileID,
            filePath: StaticString = #filePath,
            line: UInt = #line,
            column: UInt = #column
        ) async where Action: CasePathable {
            let casePath = Action.allCasePaths[keyPath: actionCase]
            await host.receive(
                matching: { casePath.extract(from: $0) != nil },
                expectation: .matching("an action matching case path"),
                timeout: duration,
                assert: update,
                at: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
            )
        }
    #endif

    /// Waits for every in-flight effect, including those effects start, to finish within `timeout`
    /// (default: ``timeout``), then fails on anything never asserted (exhaustive) or skips it
    /// (`.off`).
    public func finish(
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        await host.finish(
            timeout: duration,
            at: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    /// Asserts the modifications effects made: the results they wrote into state directly.
    ///
    /// Synchronous: it does not wait. Every modification pending up to the next action is folded
    /// into one assertion; with nothing pending, `update` is asserted against the current state.
    /// Exhaustive: an action pending ahead of the modifications fails first (it needs `receive`).
    public func expect(
        _ update: (inout State) throws -> Void,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) {
        host.expect(
            update,
            at: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    /// Advances ``state`` past every pending action and modification without asserting them.
    ///
    /// - Parameter strict: Whether to fail when nothing is pending.
    public func skipReceived(
        strict: Bool = true,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) {
        host.skipReceived(
            strict: strict,
            at: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    /// Cancels every in-flight effect and waits for them to finish. What they commit while unwinding
    /// stays pending and must still be asserted or skipped.
    ///
    /// - Parameter strict: Whether to fail when no effect is in flight.
    public func skipInFlightEffects(
        strict: Bool = true,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        await host.skipInFlightEffects(
            strict: strict,
            at: TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    #if swift(<6.4)
        @_optimize(none)
    #endif
    isolated deinit {
        host.invalidate()
    }
}
