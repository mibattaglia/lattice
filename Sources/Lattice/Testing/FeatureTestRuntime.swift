import Foundation

struct ReceivedStep<State: Sendable, ViewState: Sendable, Action: Sendable>: Sendable {
    let action: Action
    let domainState: State
    let viewState: ViewState
    let originID: UUID
}

@MainActor
final class FeatureTestRuntime<State: Sendable, ViewState: Sendable, Action: Sendable> {
    private(set) var assertedDomainState: State
    private(set) var assertedViewState: ViewState

    private var runtimeDomainState: State
    private var runtimeViewState: ViewState
    private let interactor: AnyInteractor<State, Action>
    private let viewStateReducer: AnyViewStateReducer<State, ViewState>
    private let areStatesEqual: (_ lhs: State, _ rhs: State) -> Bool
    private lazy var runtime = EmissionRuntime<Action, ReceivedStep<State, ViewState, Action>> {
        [weak self] action, source in
        self?.handleAction(action, source: source)
            ?? EmissionRuntimeActionResult(emission: .none)
    }

    init(
        initialDomainState: State,
        initialViewState: @autoclosure () -> ViewState,
        interactor: AnyInteractor<State, Action>,
        viewStateReducer: AnyViewStateReducer<State, ViewState>,
        areStatesEqual: @escaping (_ lhs: State, _ rhs: State) -> Bool
    ) {
        self.runtimeDomainState = initialDomainState
        self.assertedDomainState = initialDomainState
        self.interactor = interactor
        self.viewStateReducer = viewStateReducer
        self.areStatesEqual = areStatesEqual

        var viewState = initialViewState()
        viewStateReducer.reduce(initialDomainState, into: &viewState)
        self.runtimeViewState = viewState
        self.assertedViewState = viewState
    }

    convenience init<F: FeatureProtocol>(
        initialDomainState: State,
        feature: F
    ) where F.Action == Action, F.DomainState == State, F.ViewState == ViewState {
        self.init(
            initialDomainState: initialDomainState,
            initialViewState: feature.makeInitialViewState(initialDomainState),
            interactor: feature.interactor,
            viewStateReducer: feature.viewStateReducer,
            areStatesEqual: feature.areStatesEqual
        )
    }

    var receivedSteps: [ReceivedStep<State, ViewState, Action>] {
        runtime.bufferedSteps
    }

    func send(_ action: Action) -> EmissionRuntimeSendResult {
        runtime.send(action)
    }

    @discardableResult
    func receiveNext() -> ReceivedStep<State, ViewState, Action>? {
        guard let step = runtime.popFirstBufferedStep() else { return nil }
        assertedDomainState = step.domainState
        assertedViewState = step.viewState
        return step
    }

    func receiveAll() -> [ReceivedStep<State, ViewState, Action>] {
        let steps = runtime.popAllBufferedSteps()
        if let last = steps.last {
            assertedDomainState = last.domainState
            assertedViewState = last.viewState
        }
        return steps
    }

    func waitForReceivedStepCount(
        _ count: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        await runtime.waitForBufferedStepCount(atLeast: count, timeout: timeout)
    }

    func waitForEffectsToDrain(originID: UUID) async {
        await runtime.waitForEffectsToDrain(originID: originID)
    }

    func hasInFlightEffects(originID: UUID) -> Bool {
        runtime.hasInFlightEffects(originID: originID)
    }

    func cancelEffects(originID: UUID) {
        runtime.cancelEffects(originID: originID)
    }

    private func handleAction(
        _ action: Action,
        source: EmissionRuntimeActionSource
    ) -> EmissionRuntimeActionResult<Action, ReceivedStep<State, ViewState, Action>> {
        let previousDomainState = runtimeDomainState
        let emission = interactor.interact(state: &runtimeDomainState, action: action)

        if !areStatesEqual(previousDomainState, runtimeDomainState) {
            viewStateReducer.reduce(runtimeDomainState, into: &runtimeViewState)
        }

        switch source {
        case .sent:
            assertedDomainState = runtimeDomainState
            assertedViewState = runtimeViewState
            return EmissionRuntimeActionResult(emission: emission)

        case .emitted(let originID):
            return EmissionRuntimeActionResult(
                emission: emission,
                bufferedStep: ReceivedStep(
                    action: action,
                    domainState: runtimeDomainState,
                    viewState: runtimeViewState,
                    originID: originID
                )
            )
        }
    }
}
