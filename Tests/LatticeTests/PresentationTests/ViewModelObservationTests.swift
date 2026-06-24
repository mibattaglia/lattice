import CasePaths
import Foundation
import Observation
import Testing

@testable import Lattice

@MainActor
@Suite
struct ViewModelObservationTests {
    @Test
    func directAssignmentReducerInvalidatesPhaseObservation() {
        let viewModel = makeViewModel(reducer: DirectAssignmentObservationTestReducer())
        let changeProbe = ObservationChangeProbe()

        withObservationTracking {
            _ = viewModel.viewState.phase
        } onChange: {
            changeProbe.markChanged()
        }

        viewModel.sendViewEvent(.increment)

        #expect(changeProbe.didChange)
        #expect(viewModel.viewState.phase.active?.value == "1")
    }

    // Fine-grained observation: an in-place payload mutation (case unchanged) does NOT fire the
    // coarse `\.phase` keyPath, so an observer that reads only the *whole* enum is not
    // invalidated. Real views read the payload leaf (see
    // `casePathMutationReducerInvalidatesNestedValueObservation`) and do re-render. This matches
    // the documented precision model: in-place mutations flow through the nested registrar, not
    // the parent keyPath.
    @Test
    func casePathMutationDoesNotInvalidateWholePhaseObservation() {
        let viewModel = makeViewModel(reducer: CasePathMutationObservationTestReducer())
        let changeProbe = ObservationChangeProbe()

        withObservationTracking {
            _ = viewModel.viewState.phase
        } onChange: {
            changeProbe.markChanged()
        }

        viewModel.sendViewEvent(.increment)

        #expect(!changeProbe.didChange)
        #expect(viewModel.viewState.phase.active?.value == "1")
    }

    @Test
    func casePathMutationReducerInvalidatesNestedValueObservation() {
        let viewModel = makeViewModel(reducer: CasePathMutationObservationTestReducer())
        let changeProbe = ObservationChangeProbe()

        withObservationTracking {
            _ = viewModel.viewState.phase.active?.value
        } onChange: {
            changeProbe.markChanged()
        }

        viewModel.sendViewEvent(.increment)

        #expect(changeProbe.didChange)
        #expect(viewModel.viewState.phase.active?.value == "1")
    }

    private func makeViewModel<R: ViewStateReducer & Sendable>(
        reducer: R
    ) -> ViewModel<Feature<ObservationTestAction, ObservationTestDomainState, ObservationTestViewState>>
    where R.DomainState == ObservationTestDomainState, R.ViewState == ObservationTestViewState {
        ViewModel(
            initialDomainState: .init(count: 0),
            feature: Feature(
                interactor: ObservationTestInteractor(),
                reducer: reducer
            )
        )
    }
}

private final class ObservationChangeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var hasChanged = false

    var didChange: Bool {
        lock.withLock { hasChanged }
    }

    func markChanged() {
        lock.withLock {
            hasChanged = true
        }
    }
}

private struct ObservationTestInteractor: Interactor, Sendable {
    typealias DomainState = ObservationTestDomainState
    typealias Action = ObservationTestAction

    var body: some InteractorOf<Self> { self }

    func interact(state: inout ObservationTestDomainState, action: ObservationTestAction) -> Emission<ObservationTestAction> {
        switch action {
        case .increment:
            state.count += 1
            return .none
        }
    }
}

private struct DirectAssignmentObservationTestReducer: ViewStateReducer, Sendable {
    typealias DomainState = ObservationTestDomainState
    typealias ViewState = ObservationTestViewState

    var body: some ViewStateReducerOf<Self> { self }

    func initialViewState(for domainState: ObservationTestDomainState) -> ObservationTestViewState {
        ObservationTestViewState.defaultValue
    }

    func reduce(_ domainState: ObservationTestDomainState, into viewState: inout ObservationTestViewState) {
        viewState.phase = .active(.init(value: "\(domainState.count)"))
    }
}

private struct CasePathMutationObservationTestReducer: ViewStateReducer, Sendable {
    typealias DomainState = ObservationTestDomainState
    typealias ViewState = ObservationTestViewState

    var body: some ViewStateReducerOf<Self> { self }

    func initialViewState(for domainState: ObservationTestDomainState) -> ObservationTestViewState {
        ObservationTestViewState.defaultValue
    }

    func reduce(_ domainState: ObservationTestDomainState, into viewState: inout ObservationTestViewState) {
        viewState.phase.modify(\.active) { payload in
            payload.value = "\(domainState.count)"
        }
    }
}

@ObservableState
private struct ObservationTestViewState: Equatable, Sendable, DefaultValueProvider {
    static let defaultValue = Self(phase: .active(.init(value: "0")))

    var phase: ObservationTestPhase
}

@ObservableState
@CasePathable
@dynamicMemberLookup
private enum ObservationTestPhase: Equatable, Sendable {
    case idle
    case active(ObservationTestPayload)
}

@ObservableState
private struct ObservationTestPayload: Equatable, Sendable {
    var value: String
}

private struct ObservationTestDomainState: Equatable, Sendable {
    var count = 0
}

@CasePathable
private enum ObservationTestAction: Sendable {
    case increment
}
