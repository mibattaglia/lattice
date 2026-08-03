// Plan 07 §9: new suite for the `expect` contract — the assertion for `effectState.modify`
// commits — plus the deinit exhaustivity backstop, scoped-drop silence, and the projection
// read surface.

import CasePaths
import Clocks
import Foundation
import Testing

@testable import Lattice

// MARK: - Fixtures

private struct ExpectState: Equatable {
    var count = 0
    var flag = false
}

@CasePathable
private enum ExpectAction: Equatable {
    case load
    case loadSlow
    case ping
    case pong
    case commitNoChange
}

private struct ExpectInteractor: Interactor {
    let clock: TestClock<Duration>

    var body: some Interactor<ExpectState, ExpectAction> {
        Interact { [clock] state, action, effects in
            switch action {
            case .load:
                effects.perform { effectState in
                    try await clock.sleep(for: .seconds(1))
                    try effectState.modify { $0.count = 42 }
                }

            case .loadSlow:
                effects.perform { effectState in
                    try await clock.sleep(for: .seconds(60))
                    try effectState.modify { $0.count = 1 }
                }

            case .ping:
                effects.perform { effectState in
                    try effectState.send(.pong)
                }

            case .pong:
                state.flag = true

            case .commitNoChange:
                effects.perform { effectState in
                    try effectState.modify { _ in }
                }
            }
        }
    }
}

// Scoped-drop fixture: a When child whose case can depart mid-effect.

private struct DropChildState: Equatable {
    var value = 0
}

@CasePathable
private enum DropChildAction: Equatable {
    case fetchGated
}

@CasePathable
private enum DropState: Equatable {
    case detail(DropChildState)
    case idle
}

@CasePathable
private enum DropAction: Equatable {
    case detail(DropChildAction)
    case dismiss
}

private struct DropChildInteractor: Interactor {
    let gate: Gate

    var body: some Interactor<DropChildState, DropChildAction> {
        Interact { [gate] state, action, effects in
            switch action {
            case .fetchGated:
                effects.perform { effectState in
                    await gate.wait()
                    try effectState.modify { $0.value = 99 }
                }
            }
        }
    }
}

private struct DropRootInteractor: Interactor {
    let gate: Gate

    var body: some Interactor<DropState, DropAction> {
        Interactors.When<DropState, DropAction, _>(
            state: \.detail,
            action: \.detail
        ) {
            DropChildInteractor(gate: gate)
        }
        Interact { (state: inout DropState, action: DropAction) in
            if case .dismiss = action {
                state = .idle
            }
        }
    }
}

// MARK: - Tests

extension TestingInfrastructureTests {
    @Suite
    @MainActor
    struct TestViewModelExpectTests {
    @Test
    func expectAssertsTheNextEffectCommit() async {
        let clock = TestClock()
        let model = makeModel(clock: clock)

        let task = await model.send(.load)
        await clock.advance(by: .seconds(1))

        await model.expect {
            $0.count = 42
        }

        #expect(model.domainState.count == 42)
        await task.finish()
    }

    @Test
    func expectReportsTimeoutWhenNoCommitArrives() async {
        let clock = TestClock()
        let model = makeModel(clock: clock)

        let task = await model.send(.loadSlow)

        let expectLine = #line + 2
        await expectIssue(containing: "but none arrived after 0.01 seconds", line: expectLine) {
            await model.expect(timeout: .milliseconds(10))
        }

        await task.cancel()
    }

    @Test
    func expectReportsActionReentryAsMismatch() async {
        let clock = TestClock()
        let model = makeModel(clock: clock)

        // The sync-prefix effect re-enters with .pong before send returns.
        _ = await model.send(.ping)

        let expectLine = #line + 2
        await expectIssue(containing: "Expected the next commit to be a state mutation", line: expectLine) {
            await model.expect { $0.flag = true }
        }
    }

    @Test
    func expectWithoutChangesAssertsNoVisibleChange() async {
        let clock = TestClock()
        let model = makeModel(clock: clock)

        _ = await model.send(.commitNoChange)

        // The no-op modify still committed; expect() consumes it and asserts no change.
        await model.expect()

        #expect(model.domainState == ExpectState())
    }

    @Test
    func unassertedCommitsFailAtDeinit() async {
        let clock = TestClock()
        await withKnownIssue {
            do {
                let model = makeModel(clock: clock)
                _ = await model.send(.ping)
                // The pending .pong re-entry is never asserted; the deinit backstop reports.
            }
        } matching: { issue in
            issue.description.contains("deinitialized with 1 pending commit")
        }
    }

    @Test
    func scopedDropRecordsNoPendingCommit() async {
        let gate = Gate()
        let model = TestViewModel(
            initialDomainState: DropState.detail(DropChildState()),
            interactor: DropRootInteractor(gate: gate)
        )

        let task = await model.send(.detail(.fetchGated))
        await model.send(.dismiss) { $0 = .idle }

        // Releasing the gate lets the cancelled effect reach its modify, which is dropped
        // silently (departed scope): no commit is recorded, so exhaustive deinit passes
        // without any assertion.
        gate.open()
        await task.finish()

        #expect(model.domainState == .idle)
        await model.dismount()
    }

    private func makeModel(clock: TestClock<Duration>) -> TestViewModel<ExpectState, ExpectAction> {
        TestViewModel(
            initialDomainState: ExpectState(),
            interactor: ExpectInteractor(clock: clock)
        )
    }
}
}

// MARK: - Projection reads (plan 07 §5 view-layer assertions)

@FeatureState
private struct ProjectionTestState: Equatable {
    @Domain var rawResults: [Int] = []
    var query: String = ""
    var subtitle: String {
        "\(rawResults.count) results"
    }
}

private enum ProjectionTestAction {
    case search(String)
}

private struct ProjectionTestInteractor: Interactor {
    var body: some Interactor<ProjectionTestState, ProjectionTestAction> {
        Interact { state, action, effects in
            switch action {
            case .search(let query):
                state.query = query
                effects.perform { effectState in
                    try effectState.modify { $0.rawResults = [1, 2, 3] }
                }
            }
        }
    }
}

extension TestingInfrastructureTests {
    @Suite
    @MainActor
    struct TestViewModelProjectionTests {
    @Test
    func projectionExposesViewVisibleMembersOverCommittedState() async {
        let model = TestViewModel(
            initialDomainState: ProjectionTestState(),
            interactor: ProjectionTestInteractor()
        )

        #expect(model.projection.subtitle == "0 results")

        _ = await model.send(.search("swift")) { $0.query = "swift" }
        await model.expect { $0.rawResults = [1, 2, 3] }

        // Derived members compute from the current committed state on every access.
        #expect(model.projection.query == "swift")
        #expect(model.projection.subtitle == "3 results")
    }
}
}
