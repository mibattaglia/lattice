import Clocks
import Foundation
import Testing

@testable import Lattice

@Suite(.serialized)
@MainActor
struct TestViewModelTests {
    @Test
    func synchronousSendCommitsImmediateState() async {
        let feature = Feature(interactor: FeatureInteractor())
        let model = TestViewModel(
            initialDomainState: FeatureState(),
            feature: feature
        )

        await model.send(.incrementCount) {
            $0.count = 1
        }

        #expect(model.domainState == FeatureState(count: 1))
        model.assertViewState(FeatureState(count: 1))
        await model.finish()
    }

    @Test
    func asyncPerformBuffersReceivedActions() async {
        let now = Date(timeIntervalSince1970: 1_748_377_205)
        let feature = Feature(
            interactor: MyInteractor(dateFactory: { now }),
            reducer: MyViewStateReducer()
        )
        let model = TestViewModel(
            initialDomainState: .loading,
            feature: feature
        )

        await model.send(.load) {
            $0 = .success(.init(count: 0, timestamp: now.timeIntervalSince1970, isLoading: false))
        }

        await model.send(.fetchData) {
            $0.modify(\.success) { $0.isLoading = true }
        }

        model.assertViewState(
            .success(
                .init(count: 0, dateDisplayString: "8:20 PM", isLoading: true)
            )
        )

        await model.receive(.fetchDataCompleted(42)) {
            $0.modify(\.success) {
                $0.count = 42
                $0.isLoading = false
            }
        }

        model.assertViewState(
            .success(
                .init(count: 42, dateDisplayString: "8:20 PM", isLoading: false)
            )
        )
        await model.finish()
    }

    @Test
    func appendReceivesActionsInOrder() async {
        let feature = Feature(interactor: AppendInteractor())
        let model = TestViewModel(
            initialDomainState: AppendState(),
            feature: feature
        )

        await model.send(.appendTwoPerforms)

        await model.receive(.logged("first")) {
            $0.log = ["first"]
        }

        await model.receive(.logged("second")) {
            $0.log = ["first", "second"]
        }

        #expect(model.domainState.log == ["first", "second"])
        await model.finish()
    }

    @Test
    func observeTaskCanBeCancelledAfterReceivingBufferedValues() async {
        let stream = AsyncStream.makeStream(of: Int.self)
        let feature = Feature(interactor: ObserveInteractor(stream: stream.stream))
        let model = TestViewModel(
            initialDomainState: ObserveState(),
            feature: feature
        )

        let task = await model.send(.start)
        stream.continuation.yield(1)
        stream.continuation.yield(2)

        await model.receive(.value(1)) {
            $0.count = 1
        }

        await model.receive(.value(2)) {
            $0.count = 2
        }

        await task.cancel()
        #expect(task.isCancelled)
        stream.continuation.finish()
        await task.finish()
        await model.finish()
    }

    @Test
    func debounceDelaysReceivedEffectUntilClockAdvances() async {
        let clock = TestClock()
        let feature = Feature(
            interactor: Interactors.Debounce(for: .milliseconds(300), clock: clock) {
                DebouncedEffectInteractor(counter: DebouncedCounter())
            }
        )
        let model = TestViewModel(
            initialDomainState: DebouncedState(),
            feature: feature
        )

        await model.send(.trigger) {
            $0.triggerCount = 1
        }
        await model.send(.trigger) {
            $0.triggerCount = 2
        }
        let task = await model.send(.trigger) {
            $0.triggerCount = 3
        }

        #expect(model.domainState.triggerCount == 3)

        await clock.advance(by: .milliseconds(300))

        await model.receive(.effectCompleted(3)) {
            $0.effectResult = 3
        }

        await task.finish()
        await model.finish()
    }

    @Test
    func nonExhaustiveModeCanSkipBufferedActions() async {
        let feature = Feature(interactor: AppendInteractor())
        let model = TestViewModel(
            initialDomainState: AppendState(),
            feature: feature
        )
        model.exhaustivity = .off()

        await model.send(.appendTwoPerforms)

        await model.receive(.logged("first")) {
            $0.log = ["first"]
        }

        try? await Task.sleep(for: .milliseconds(30))

        await model.skipReceivedActions()
        #expect(model.domainState.log == ["first", "second"])
        await model.finish()
    }

    @Test
    func nonExhaustiveModeCanSkipInFlightEffects() async {
        let stream = AsyncStream.makeStream(of: Int.self)
        let feature = Feature(interactor: ObserveInteractor(stream: stream.stream))
        let model = TestViewModel(
            initialDomainState: ObserveState(),
            feature: feature
        )
        model.exhaustivity = .off()

        let task = await model.send(.start)
        await model.skipInFlightEffects()
        stream.continuation.finish()
        await task.finish()
        await model.finish()
    }
}

@ObservableState
private struct AppendState: Equatable {
    var log: [String] = []
}

@Interactor<AppendState, AppendAction>
private struct AppendInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .appendTwoPerforms:
                return .append(
                    .perform {
                        try? await Task.sleep(for: .milliseconds(10))
                        return .logged("first")
                    },
                    .perform {
                        try? await Task.sleep(for: .milliseconds(10))
                        return .logged("second")
                    }
                )

            case .logged(let value):
                state.log.append(value)
                return .none
            }
        }
    }
}

private enum AppendAction: Equatable {
    case appendTwoPerforms
    case logged(String)
}

@ObservableState
private struct ObserveState: Equatable {
    var count = 0
}

@Interactor<ObserveState, ObserveAction>
private struct ObserveInteractor {
    let stream: AsyncStream<Int>

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .start:
                return .observe { [stream] in
                    AsyncStream { continuation in
                        let task = Task {
                            for await value in stream {
                                continuation.yield(.value(value))
                            }
                            continuation.finish()
                        }
                        continuation.onTermination = { @Sendable _ in
                            task.cancel()
                        }
                    }
                }

            case .value(let value):
                state.count = value
                return .none
            }
        }
    }
}

private enum ObserveAction: Equatable, Sendable {
    case start
    case value(Int)
}

private actor DebouncedCounter {
    func increment() {}
}

@ObservableState
private struct DebouncedState: Equatable {
    var triggerCount = 0
    var effectResult = 0
}

private struct DebouncedEffectInteractor: Interactor, Sendable {
    typealias DomainState = DebouncedState

    enum Action: Equatable, Sendable {
        case trigger
        case effectCompleted(Int)
    }

    let counter: DebouncedCounter

    var body: some InteractorOf<Self> { self }

    func interact(state: inout DebouncedState, action: Action) -> Emission<Action> {
        switch action {
        case .trigger:
            state.triggerCount += 1
            let count = state.triggerCount
            return .perform { [counter] in
                await counter.increment()
                return .effectCompleted(count)
            }

        case .effectCompleted(let value):
            state.effectResult = value
            return .none
        }
    }
}
