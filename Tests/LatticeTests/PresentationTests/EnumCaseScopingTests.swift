// Case scoping rides the generated enum case accessors (`@FeatureState` emits
// `success: SuccessState?` into `_ViewMembers`).

import CasePaths
import Foundation
import Testing

@testable import Lattice

// MARK: - Fixtures

@FeatureState
private struct SuccessState: Equatable {
    var title: String = "t"
    var count: Int = 0
}

@FeatureState
@CasePathable
private enum PhaseState {
    case loading
    case success(SuccessState)
}

@CasePathable private enum SuccessAction {
    case titleChanged(String)
    case incremented
}

@CasePathable private enum PhaseAction {
    case load
    case reset
    case success(SuccessAction)
}

private struct SuccessInteractor: Interactor {
    var body: some Interactor<SuccessState, SuccessAction> {
        Interact { state, action in
            switch action {
            case .titleChanged(let t): state.title = t
            case .incremented: state.count += 1
            }
        }
    }
}

private struct PhaseInteractor: Interactor {
    var body: some Interactor<PhaseState, PhaseAction> {
        Interactors.When(state: \.success, action: \.success) {
            SuccessInteractor()
        }
        Interact { state, action in
            switch action {
            case .load: state = .success(SuccessState())
            case .reset: state = .loading
            case .success: break
            }
        }
    }
}

// MARK: - Tests

@MainActor
@Suite struct EnumCaseScopingTests {
    private func makeViewModel(loaded: Bool = true) -> ViewModel<PhaseState, PhaseAction> {
        ViewModel(
            initialState: loaded ? .success(SuccessState()) : .loading,
            interactor: PhaseInteractor()
        )
    }

    @Test func scopeIfActiveReturnsNilWhenCaseIsInactive() {
        let vm = makeViewModel(loaded: false)
        #expect(vm.scopeIfActive(state: \.success, action: \.success) == nil)
    }

    @Test func scopeIfActiveReadsThePayloadWhileActive() {
        let vm = makeViewModel()
        let scoped = vm.scopeIfActive(state: \.success, action: \.success)

        #expect(scoped?.title == "t")
        #expect(scoped?.count == 0)
    }

    @Test func scopedReadsAreLive() {
        let vm = makeViewModel()
        let scoped = vm.scopeIfActive(state: \.success, action: \.success)

        vm.sendViewEvent(.success(.incremented))
        #expect(scoped?.count == 1)
    }

    @Test func scopedSendsEmbedIntoTheParentAction() {
        let vm = makeViewModel()
        let scoped = vm.scope(state: \.success, action: \.success)

        scoped.sendViewEvent(.titleChanged("new"))
        #expect(scoped.title == "new")
        #expect(vm.success?.title == "new")
    }

    @Test func scopeHeldAcrossDeactivationServesTheCreationSnapshot() {
        let vm = makeViewModel()
        let scoped = vm.scope(state: \.success, action: \.success)

        vm.sendViewEvent(.success(.titleChanged("before")))
        #expect(scoped.title == "before")

        // Snapshot fallback covers at most one transitional render after the case departs.
        vm.sendViewEvent(.reset)
        #expect(scoped.title == "t")  // creation-time payload, not "before"
    }

    @Test func sendsAfterDeactivationAreDroppedByWhen() {
        let vm = makeViewModel()
        let scoped = vm.scope(state: \.success, action: \.success)

        vm.sendViewEvent(.reset)
        scoped.sendViewEvent(.incremented)  // `When` drops it: the case is inactive.

        vm.sendViewEvent(.load)
        #expect(vm.success?.count == 0)
    }

    @Test func nestedCaseScopeOnScopedViewModel() {
        // Parent struct holding the enum; scope into the struct member, then into the case.
        let vm = ViewModel(
            initialState: ShellState(),
            interactor: ShellInteractor()
        )

        let phase: ScopedViewModel<PhaseState, PhaseAction> = vm.scope(
            state: \.phase,
            action: \.phase
        )
        let success = phase.scopeIfActive(state: \.success, action: \.success)

        #expect(success != nil)
        success?.sendViewEvent(.incremented)
        #expect(success?.count == 1)
    }
}

// MARK: - Nested-shell fixture

@FeatureState
private struct ShellState {
    var phase: PhaseState = PhaseState.success(SuccessState())
}

@CasePathable private enum ShellAction {
    case phase(PhaseAction)
}

private struct ShellInteractor: Interactor {
    var body: some Interactor<ShellState, ShellAction> {
        Interactors.When(state: \.phase, action: \.phase) {
            PhaseInteractor()
        }
    }
}
