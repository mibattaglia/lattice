import Foundation
import Testing

@testable import Lattice

@MainActor
@Suite(.serialized)
struct FeatureTestRuntimeTests {
    private let feature: Feature<MyEvent, MyDomainState, MyViewState>

    init() {
        let capturedNow = Date(timeIntervalSince1970: 1_748_377_205)
        self.feature = Feature(
            interactor: MyInteractor(dateFactory: { capturedNow }).eraseToAnyInteractorUnchecked(),
            reducer: MyViewStateReducer()
        )
    }

    @Test
    func emittedActionsAreBufferedUntilReceived() async {
        let runtime = FeatureTestRuntime(
            initialDomainState: .loading,
            feature: feature
        )

        _ = runtime.send(.load)
        let sendResult = runtime.send(.fetchData)

        #expect(runtime.assertedDomainState == .success(.init(count: 0, timestamp: 1_748_377_205, isLoading: true)))
        #expect(runtime.receivedSteps.isEmpty)

        let received = await runtime.waitForReceivedStepCount(1)
        #expect(received)
        #expect(runtime.receivedSteps.count == 1)
        #expect(runtime.assertedDomainState == .success(.init(count: 0, timestamp: 1_748_377_205, isLoading: true)))

        let step = runtime.receiveNext()
        #expect(step?.action == .fetchDataCompleted(42))
        #expect(runtime.assertedDomainState == .success(.init(count: 42, timestamp: 1_748_377_205, isLoading: false)))
        #expect(runtime.assertedViewState == .success(.init(count: 42, dateDisplayString: "8:20 PM", isLoading: false)))

        await runtime.waitForEffectsToDrain(originID: sendResult.originID)
    }

    @Test
    func transitiveReceivedActionsPreserveOriginID() async {
        let runtime = FeatureTestRuntime(
            initialDomainState: ChainedState(),
            feature: Feature(
                interactor: ChainedFeature(),
                reducer: ChainedViewStateReducer()
            )
        )

        let sendResult = runtime.send(ChainedAction.start)
        let received = await runtime.waitForReceivedStepCount(2)

        #expect(received)
        let steps = runtime.receiveAll()

        #expect(steps.count == 2)
        #expect(steps[0].action == .first)
        #expect(steps[1].action == .second)
        #expect(steps[0].originID == sendResult.originID)
        #expect(steps[1].originID == sendResult.originID)
        #expect(runtime.assertedDomainState.values == ["first", "second"])
    }
}

@Interactor<ChainedState, ChainedAction>
private struct ChainedFeature: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .start:
                return .perform { .first }

            case .first:
                state.values.append("first")
                return .perform { .second }

            case .second:
                state.values.append("second")
                return .none
            }
        }
    }
}

private struct ChainedState: Equatable, Sendable {
    var values: [String] = []
}

private enum ChainedAction: Equatable, Sendable {
    case start
    case first
    case second
}

@ObservableState
private struct ChainedViewState: Equatable, Sendable {
    var values: [String] = []
}

@ViewStateReducer<ChainedState, ChainedViewState>
private struct ChainedViewStateReducer: Sendable {
    func initialViewState(for domainState: ChainedState) -> ChainedViewState {
        .init(values: domainState.values)
    }

    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { (domainState: ChainedState, viewState: inout ChainedViewState) in
            viewState.values = domainState.values
        }
    }
}
