// Type-checked by scripts/negative-compile-checks.sh, together with the other files in this
// directory, against the built Lattice module: once with no flag (must compile) and once per `-D`
// flag (must fail with the diagnostic the script lists). Not part of any SwiftPM target.

import CasePaths
import Foundation
import IdentifiedCollections
import Lattice

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

/// Stand-in for the scoped read API: member access through a child's projection.
@dynamicMemberLookup
struct ScopedRead<Child: FeatureState> {
    let child: Child

    subscript<Value>(dynamicMember keyPath: KeyPath<Child.ViewState, Value>) -> Value {
        Child.ViewState(child)[keyPath: keyPath]
    }
}

/// Stand-in for the binding API: key paths formed from the root projection.
@dynamicMemberLookup
struct BindingPaths<State: FeatureState> {
    subscript<Value>(dynamicMember keyPath: KeyPath<State.ViewState, Value>) -> KeyPath<State.ViewState, Value> {
        keyPath
    }
}

func readThroughProjections() {
    let viewState = CounterState.ViewState(CounterState())
    _ = viewState.title
    _ = viewState.lastUpdatedText
    _ = viewState.badge.isHot
    _ = viewState.detail?.count
    _ = viewState.rows[id: 1]?.count
    _ = ScopedRead(child: BadgeState(id: 1)).count
    _ = BindingPaths<CounterState>().title
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
    #if LEAK_BINDING
        _ = BindingPaths<CounterState>().lastUpdatedAt
    #endif
    #if LEAK_SCOPED
        _ = ScopedRead(child: BadgeState(id: 1)).secretThreshold
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

#if GENERIC_STATE
    @FeatureState
    struct GenericState<Value> {
        var value: Value
    }
#endif
