// Scopes expose the child's FeatureProjection; assertion targets are projected members.

import CasePaths
import Foundation
import Testing

@testable import Lattice

// MARK: - Fixtures

@FeatureState
private struct BadgeState: Equatable {
    var count: Int = 0
}

@FeatureState
private struct HeaderState: Equatable {
    var title: String = "h"
    var badge: BadgeState = BadgeState()
}

@FeatureState
private struct AppState {
    var header: HeaderState = HeaderState()
    var footer: String = "f"
}

@CasePathable private enum BadgeAction {
    case incremented
}

@CasePathable private enum HeaderAction {
    case titleChanged(String)
    case badge(BadgeAction)
    case refreshTapped
}

@CasePathable private enum AppAction {
    case header(HeaderAction)
    case setFooter(String)
}

private struct AppInteractor: Interactor {
    var body: some Interactor<AppState, AppAction> {
        Interact { state, action, effects in
            switch action {
            case .header(.titleChanged(let t)): state.header.title = t
            case .header(.badge(.incremented)): state.header.badge.count += 1
            case .header(.refreshTapped):
                // Async effect: exercises EventTask propagation through the scope.
                effects.perform { effectState in
                    try effectState.modify { $0.header.badge.count += 1 }
                }
            case .setFooter(let f): state.footer = f
            }
        }
    }
}

// MARK: - Non-Sendable child action fixture

private final class NonSendablePayload {
    let value: Int
    init(value: Int) { self.value = value }
}

private enum NonSendableChildAction {
    case set(NonSendablePayload)
}

@CasePathable private enum NonSendableParentAction {
    case child(NonSendableChildAction)
}

private struct NonSendableParentInteractor: Interactor {
    var body: some Interactor<AppState, NonSendableParentAction> {
        Interact { state, action in
            switch action {
            case .child(.set(let payload)):
                state.header.badge.count = payload.value
            }
        }
    }
}

// MARK: - Tests

@MainActor
@Suite struct ScopedViewModelTests {
    private func makeViewModel() -> ViewModel<AppState, AppAction> {
        ViewModel(initialState: AppState(), interactor: AppInteractor())
    }

    @Test func scopedReadReflectsParentState() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        #expect(header.title == "h")
        #expect(header.badge.count == 0)
    }

    @Test func scopedSendEmbedsIntoParentAction() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        header.sendViewEvent(.titleChanged("new"))
        #expect(vm.header.title == "new")
        #expect(header.title == "new")
    }

    @Test func scopedSendReturnsParentEventTaskForEffects() async {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)

        let task = header.sendViewEvent(.refreshTapped)
        #expect(task.hasEffects == true)

        await task.finish()
        #expect(header.badge.count == 1)
    }

    @Test func grandchildScopeComposesThroughTheParent() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let badge = header.scope(state: \.badge, action: \.badge)

        #expect(badge.count == 0)
        badge.sendViewEvent(.incremented)
        #expect(badge.count == 1)
        #expect(vm.header.badge.count == 1)
    }

    @Test func closureScopeNeedsNoCasePathableParent() {
        let vm = makeViewModel()
        let header: ScopedViewModel<HeaderState, HeaderAction> = vm.scope(
            state: \.header,
            action: { AppAction.header($0) }
        )
        header.sendViewEvent(.titleChanged("closure"))
        #expect(header.title == "closure")
    }

    @Test func readOnlyScopeExposesStateWithoutActions() {
        let vm = makeViewModel()
        let header: ScopedViewModel<HeaderState, Never> = vm.scope(state: \.header)
        #expect(header.title == "h")
    }

    @Test func bindingReadsProjectedMemberAndSendsOnWrite() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)

        let binding = header.binding(\.title, sending: \.titleChanged)
        #expect(binding.wrappedValue == "h")

        binding.wrappedValue = "bound"
        #expect(vm.header.title == "bound")
    }

    @Test func nonSendableChildActionScopeCompilesAndRuns() {
        let vm = ViewModel(initialState: AppState(), interactor: NonSendableParentInteractor())
        let child: ScopedViewModel<HeaderState, NonSendableChildAction> = vm.scope(
            state: \.header,
            action: \.child
        )

        child.sendViewEvent(.set(NonSendablePayload(value: 7)))
        #expect(child.badge.count == 7)
    }
}
