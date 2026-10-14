// Type-checked by scripts/negative-compile-checks.sh, together with the other files in this
// directory, against the built Lattice module: once with no flag (must compile) and once per `-D`
// flag (must fail with the diagnostics the script lists). Not part of any SwiftPM target.

import CasePaths
import Foundation
import IdentifiedCollections
import Lattice
import SwiftUI

@FeatureState
struct BadgeState: Equatable, Identifiable, Sendable {
    let id: Int
    var count = 0
    @Domain var secretThreshold = 10
    var isHot: Bool { count > secretThreshold }
}

@FeatureState
struct CounterState: Equatable, Sendable {
    var title = "Counter"
    @Domain var lastUpdatedAt: Date?
    @Domain var nonce = 0
    var badge = BadgeState(id: 0)
    var detail: BadgeState?
    var rows: IdentifiedArrayOf<BadgeState> = []
    var lastUpdatedText: String { lastUpdatedAt == nil ? "Never" : "Updated" }
}

@FeatureState
struct LoadedState: Equatable, Sendable {
    var query = ""
    @Domain var etag: String?
}

// Action payload types match the member types, so a rejected member is reported as unavailable
// rather than as a type mismatch.

@CasePathable
enum BadgeAction: Sendable {
    case countChanged(Int)
    case secretThresholdChanged(Int)
}

@CasePathable
enum CounterAction: Sendable {
    case titleChanged(String)
    case lastUpdatedAtChanged(Date?)
    case badge(BadgeAction)
    case detail(BadgeAction)
    case row(BadgeState.ID, BadgeAction)
}

@CasePathable
enum LoadedAction: Sendable {
    case queryChanged(String)
}

@CasePathable
enum ScreenAction: Sendable {
    case queryChanged(String)
    case etagChanged(String?)
    case loaded(LoadedAction)
}

@Interactor<CounterState, CounterAction>
struct CounterInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { _, _ in .none }
    }
}

@Interactor<ScreenState, ScreenAction>
struct ScreenInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { _, _ in .none }
    }
}

func readThroughProjections() {
    let viewState = CounterState.ViewState(CounterState())
    _ = viewState.title
    _ = viewState.lastUpdatedText
    _ = viewState.badge.isHot
    _ = viewState.detail?.count
    _ = viewState.rows[id: 1]?.count
    let _: KeyPath<CounterState.ViewState, Int> = \CounterState.ViewState.badge.count
    _ = ScreenState.ViewState(.loaded(LoadedState()))[case: \.loaded]?.query

    #if LEAK_ROOT
        _ = viewState.lastUpdatedAt
    #endif
    #if LEAK_NESTED
        _ = viewState.badge.secretThreshold
    #endif
    #if LEAK_OPTIONAL
        _ = viewState.detail?.secretThreshold
    #endif
    #if LEAK_COLLECTION
        _ = viewState.rows[id: 1]?.secretThreshold
    #endif
    #if LEAK_KEYPATH
        let _: KeyPath<CounterState.ViewState, Int> = \CounterState.ViewState.nonce
    #endif
    #if LEAK_CASE
        _ = ScreenState.ViewState(.loaded(LoadedState()))[case: \.loaded]?.etag
    #endif
    #if LEAK_RAW_STATE
        func rawState<Projection: ViewStateProjection>(_ projection: Projection) -> Projection.State {
            projection._state
        }
        _ = viewState.rows._base
    #endif
}

@MainActor
func readThroughTheViewModel(
    _ counterModel: ViewModel<Feature<CounterAction, CounterState>>,
    _ screenModel: ViewModel<Feature<ScreenAction, ScreenState>>
) {
    @Bindable var viewModel = counterModel
    @Bindable var screenViewModel = screenModel

    _ = viewModel.title
    _ = viewModel.lastUpdatedText
    _ = viewModel.badge.isHot
    _ = viewModel.detail?.count
    _ = viewModel.rows[id: 1]?.count
    _ = viewModel.viewState.title
    _ = viewModel[dynamicMember: \.badge.count]
    let badge = viewModel.scope(state: \.badge, action: \.badge)
    _ = badge.count
    _ = badge.isHot
    _ = badge.binding(\.count, sending: \.countChanged)
    _ = viewModel.scope(state: \.detail, action: \.detail)?.count
    _ = viewModel.scope(state: \.rows, action: \.row).first?.count
    _ = $viewModel.title.sending(\.titleChanged)
    _ = $viewModel.badge.count.sending(\.badge.countChanged)
    _ = $screenViewModel.loaded.query.sending(\.queryChanged)
    _ = screenViewModel.scopeIfActive(state: \.loaded, action: \.loaded)?.query

    #if LEAK_ROOT
        _ = viewModel.lastUpdatedAt
    #endif
    #if LEAK_NESTED
        _ = viewModel.badge.secretThreshold
    #endif
    #if LEAK_OPTIONAL
        _ = viewModel.detail?.secretThreshold
    #endif
    #if LEAK_COLLECTION
        _ = viewModel.rows[id: 1]?.secretThreshold
    #endif
    #if LEAK_KEYPATH
        _ = viewModel[dynamicMember: \.nonce]
        _ = badge.binding(\.secretThreshold, sending: \.secretThresholdChanged)
    #endif
    #if LEAK_BINDING
        _ = $viewModel.lastUpdatedAt.sending(\.lastUpdatedAtChanged)
        _ = $viewModel.badge.secretThreshold.sending(\.badge.secretThresholdChanged)
    #endif
    #if LEAK_SCOPED
        _ = badge.secretThreshold
        _ = viewModel.scope(state: \.rows, action: \.row).first?.secretThreshold
    #endif
    #if LEAK_CASE
        _ = $screenViewModel.loaded.etag.sending(\.etagChanged)
        _ = screenViewModel.scopeIfActive(state: \.loaded, action: \.loaded)?.etag
        // Enum scoping goes through the `@CasePathable` mirror only; a raw-enum case path is rejected.
        _ = screenViewModel.scopeIfActive(state: \ScreenState.Cases.loaded, action: \.loaded)
    #endif
    #if LEAK_RAW_STATE
        _ = viewModel.state
    #endif
}

#if GENERIC_STATE
    @FeatureState
    struct GenericState<Value> {
        var value: Value
    }
#endif
