// Deliberate compile-fail fixtures for the type-driven diagnostics (plan 05 §12 phase A).
// Kept commented: uncomment a block to verify the diagnostic manually. Each block fails to
// compile with the annotated error.

// 1. Non-Equatable view-visible member: the unavailable `_diff` catch-all wins overload
//    resolution only when nothing else applies, and then fails compilation with the
//    actionable message.
//
//    struct NotEquatable { var closure: () -> Void = {} }
//    struct BadState {
//        var member: NotEquatable = NotEquatable()
//        struct _ViewMembers {
//            let member: NotEquatable
//            @available(*, unavailable) private init() { fatalError() }
//        }
//        @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
//            \_ViewMembers.member: \BadState.member
//        ]
//        @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = []
//        @MainActor static func _commit(
//            old: BadState, new: BadState,
//            registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
//        ) {
//            // 🛑 error: '_diff' is unavailable: view-visible members must be Equatable —
//            //    make the type Equatable, mark the member '@Domain', or make it 'private'
//            Lattice._diff(old.member, new.member,
//                registrar: registrar, key: key.appending(\_ViewMembers.member))
//        }
//    }
//    extension BadState: Lattice.FeatureStateProtocol {}

// 2. Compile-time @Domain / private fencing: domain members are absent from the generated
//    `_ViewMembers` namespace, so view access fails as an ordinary "no member" error.
//
//    @MainActor func fencing(projection: FeatureProjection<SearchState>) {
//        // 🛑 error: value of type 'SearchState._ViewMembers' has no member 'rawResults'
//        _ = projection.rawResults
//    }
