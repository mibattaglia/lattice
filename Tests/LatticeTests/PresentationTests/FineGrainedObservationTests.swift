import CasePaths
import Foundation
import Observation
import Testing

@testable import Lattice

@FeatureState private struct Section: Equatable, Sendable {
    var title: String
    var subtitle: String
}

@FeatureState private struct DashState: Equatable, Sendable {
    var header = Section(title: "h", subtitle: "s")
    var count = 0
    @Domain var updatedAt = 0
    var updatedText: String { updatedAt == 0 ? "Never" : "Updated at \(updatedAt)" }
}

@CasePathable private enum SectionAction: Sendable {
    case setSubtitle(String)
}

@CasePathable private enum DashAction: Sendable {
    case bumpCount  // changes only `count`
    case setCount(Int)
    case setTitle(String)  // changes only `header.title`, in place
    case touch(Int)  // changes only the hidden `updatedAt`
    case header(SectionAction)  // mutates `header` through `Interactors.When`'s key path
}

@Interactor<Section, SectionAction>
private struct SectionInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .setSubtitle(let subtitle): state.subtitle = subtitle
            }
            return .none
        }
    }
}

@Interactor<DashState, DashAction>
private struct DashInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interactors.When(state: \.header, action: \.header) {
            SectionInteractor()
        }
        Interact { state, action in
            switch action {
            case .bumpCount: state.count += 1
            case .setCount(let count): state.count = count
            case .setTitle(let title): state.header.title = title
            case .touch(let time): state.updatedAt = time
            case .header: break
            }
            return .none
        }
    }
}

/// Not `Equatable`: per-member gating must not depend on state equality.
private struct Blob: Sendable {
    var value = 0
}

@FeatureState private struct UncomparableDashState: Sendable {
    var title = "t"
    var blob = Blob()
}

private enum UncomparableDashAction: Sendable {
    case setTitle(String)
    case replaceBlob
}

@Interactor<UncomparableDashState, UncomparableDashAction>
private struct UncomparableDashInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .setTitle(let title): state.title = title
            case .replaceBlob: state.blob = Blob()
            }
            return .none
        }
    }
}

@MainActor
@Suite struct FineGrainedObservationTests {
    private func makeViewModel() -> ViewModel<Feature<DashAction, DashState>> {
        ViewModel(initialState: DashState(), feature: Feature(interactor: DashInteractor()))
    }

    @Test func leafChangeFiresItsObserver() {
        let vm = makeViewModel()
        let count = ObservationProbe { _ = vm.count }

        vm.sendViewEvent(.bumpCount)
        #expect(count.didFire)
        #expect(vm.count == 1)
    }

    @Test func unrelatedLeafChangeDoesNotInvalidate() {
        let vm = makeViewModel()
        let title = ObservationProbe { _ = vm.header.title }

        vm.sendViewEvent(.bumpCount)  // changes count, not header.title
        #expect(!title.didFire)
    }

    @Test func equalValueAssignedDoesNotInvalidate() {
        let vm = makeViewModel()
        let count = ObservationProbe { _ = vm.count }
        let root = ObservationProbe { _ = vm.viewState }

        vm.sendViewEvent(.setCount(0))  // same value
        #expect(!count.didFire)
        #expect(!root.didFire)
    }

    @Test func perMemberGatingDoesNotRequireAnEquatableState() {
        let vm = ViewModel(
            initialState: UncomparableDashState(),
            feature: Feature(interactor: UncomparableDashInteractor())
        )
        let title = ObservationProbe { _ = vm.title }
        let blob = ObservationProbe { _ = vm.blob.value }

        vm.sendViewEvent(.setTitle("t"))  // equal Equatable leaf: gated
        #expect(!title.didFire)

        vm.sendViewEvent(.replaceBlob)  // a non-Equatable leaf always notifies
        #expect(blob.didFire)
    }

    @Test func inPlaceNestedLeafMutationFiresOnlyThatLeaf() {
        let vm = makeViewModel()
        let title = ObservationProbe { _ = vm.header.title }
        let subtitle = ObservationProbe { _ = vm.header.subtitle }
        let count = ObservationProbe { _ = vm.count }
        let root = ObservationProbe { _ = vm.viewState }

        vm.sendViewEvent(.setTitle("new"))  // only title changes, in place
        #expect(title.didFire)
        #expect(!subtitle.didFire)
        #expect(!count.didFire)
        #expect(!root.didFire)
        #expect(vm.viewState.header.title == "new")
    }

    @Test func nestedLeafMutationThroughWhenKeyPathFiresOnlyThatLeaf() {
        let vm = makeViewModel()
        let title = ObservationProbe { _ = vm.header.title }
        let subtitle = ObservationProbe { _ = vm.header.subtitle }
        let count = ObservationProbe { _ = vm.count }
        let root = ObservationProbe { _ = vm.viewState }

        vm.sendViewEvent(.header(.setSubtitle("sub")))
        #expect(subtitle.didFire)
        #expect(!title.didFire)
        #expect(!count.didFire)
        #expect(!root.didFire)
        #expect(vm.header.subtitle == "sub")
    }

    // Reading the child value registers only the path to it; its members' changes reach member
    // readers.

    @Test func coarseChildReadDoesNotInvalidateOnInPlaceLeafMutation() {
        let vm = makeViewModel()
        let header = ObservationProbe { _ = vm.header }

        vm.sendViewEvent(.setTitle("new"))
        #expect(!header.didFire)
        #expect(vm.header.title == "new")
    }

    // A visible computed member that reads a hidden `@Domain` member stays fine-grained.

    @Test func visibleComputedMemberInvalidatesWhenItsDomainDependencyChanges() {
        let vm = makeViewModel()
        let updatedText = ObservationProbe { _ = vm.updatedText }
        let count = ObservationProbe { _ = vm.count }

        vm.sendViewEvent(.touch(5))
        #expect(updatedText.didFire)
        #expect(!count.didFire)
        #expect(vm.updatedText == "Updated at 5")
    }
}

// When the whole state is an enum with a plain payload (`RootPhaseState.content(String)`):

private enum RootPhaseAction: Sendable {
    case load(String)  // .loading -> .content (case change), or new content
    case refresh  // reassigns the current value
}

@Interactor<RootPhaseState, RootPhaseAction>
private struct RootPhaseInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .load(let text): state = .content(text)
            case .refresh:
                let current = state
                state = current
            }
            return .none
        }
    }
}

@MainActor
@Suite struct EnumRootObservationTests {
    private func makeViewModel(
        _ initialState: RootPhaseState = .loading,
        areStatesEqual: ((RootPhaseState, RootPhaseState) -> Bool)? = { $0 == $1 }
    ) -> ViewModel<Feature<RootPhaseAction, RootPhaseState>> {
        ViewModel(
            initialState: initialState,
            feature: Feature(interactor: RootPhaseInteractor(), areStatesEqual: areStatesEqual)
        )
    }

    // A view that `switch`es over the enum registers only the root; a case change must
    // re-render it. This is the regression that deleting the coarse fire would break.
    @Test func caseChangeInvalidatesWholeStateObserver() {
        let vm = makeViewModel()
        let root = ObservationProbe { _ = vm.viewState }

        vm.sendViewEvent(.load("hi"))  // .loading -> .content : root _$id changes
        #expect(root.didFire)
        #expect(vm.viewState == .content("hi"))
    }

    // A plain payload has no registrar, so a content change can only reach views as a root fire.
    @Test func plainPayloadContentChangeFiresRoot() {
        let vm = makeViewModel(.content("a"))
        let root = ObservationProbe { _ = vm.viewState }

        vm.sendViewEvent(.load("b"))
        #expect(root.didFire)
        #expect(vm.viewState == .content("b"))
    }

    // A plain payload mints a fresh `_$id` per access, so every commit in the case looks like a
    // replacement; the state equality swallows the content-equal ones.
    @Test func plainPayloadEqualContentCommitIsSwallowedByStateEquality() {
        let vm = makeViewModel(.content("a"))
        let root = ObservationProbe { _ = vm.viewState }

        vm.sendViewEvent(.refresh)
        vm.sendViewEvent(.load("a"))
        #expect(!root.didFire)
    }

    @Test func plainPayloadEqualContentCommitFiresRootWithoutStateEquality() {
        let vm = makeViewModel(.content("a"), areStatesEqual: nil)
        let root = ObservationProbe { _ = vm.viewState }

        vm.sendViewEvent(.refresh)
        #expect(root.didFire)
    }
}
