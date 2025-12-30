import CasePaths
import Foundation
import Testing

@testable import UnoArchitecture

// MARK: - Test Domain Models

struct ParentState: Equatable, Sendable {
    var counter: CounterInteractor.State
    var otherProperty: String
}

@CasePathable
enum ParentAction: Sendable {
    case counter(CounterInteractor.Action)
    case counterStateChanged(CounterInteractor.State)
    case otherAction
}

struct ParentStateWithTwo: Equatable, Sendable {
    var counter1: CounterInteractor.State
    var counter2: CounterInteractor.State
}

@CasePathable
enum ParentActionWithTwo: Sendable {
    case counter1(CounterInteractor.Action)
    case counter1StateChanged(CounterInteractor.State)
    case counter2(CounterInteractor.Action)
    case counter2StateChanged(CounterInteractor.State)
}

// MARK: - Tests

@Suite
@MainActor
struct WhenTests {

    @Test
    func whenKeyPathBasicFunctionality() async throws {
        let interactor = Interact<ParentState, ParentAction>(
            initialValue: ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")
        ) { state, action in
            switch action {
            case .counterStateChanged(let counterState):
                state.counter = counterState
                return .state
            case .counter, .otherAction:
                return .state
            }
        }
            .when(stateIs: \.counter, actionIs: \.counter, stateAction: \.counterStateChanged) {
                CounterInteractor()
            }

        let recorder = AsyncStreamRecorder<ParentState>()
        let (actionStream, actionCont) = AsyncStream<ParentAction>.makeStream()

        recorder.record(interactor.interact(actionStream))

        try await recorder.waitForEmissions(count: 1, timeout: .seconds(2))

        actionCont.yield(.counter(.increment))

        try await recorder.waitForEmissions(count: 2, timeout: .seconds(2))
        actionCont.finish()

        // Should receive: initial state (count: 0) + state after increment (count: 1)
        // Child actions are filtered out - only state change actions reach parent
        #expect(recorder.values.count == 2)

        // First state is initial parent state with child's initial state (count: 0)
        #expect(recorder.values[0].counter.count == 0)
        #expect(recorder.values[0].otherProperty == "test")

        // Second state reflects the increment via stateChanged
        #expect(recorder.values[1].counter.count == 1)
        #expect(recorder.values[1].otherProperty == "test")
    }

    @Test
    func whenFiltersNonChildActions() async throws {
        let interactor = Interact<ParentState, ParentAction>(
            initialValue: ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")
        ) { state, action in
            switch action {
            case .counterStateChanged(let counterState):
                state.counter = counterState
                return .state
            case .counter:
                return .state
            case .otherAction:
                state.otherProperty = "modified"
                return .state
            }
        }
            .when(stateIs: \.counter, actionIs: \.counter, stateAction: \.counterStateChanged) {
                CounterInteractor()
            }

        let recorder = AsyncStreamRecorder<ParentState>()
        let (actionStream, actionCont) = AsyncStream<ParentAction>.makeStream()

        recorder.record(interactor.interact(actionStream))

        try await recorder.waitForEmissions(count: 1, timeout: .seconds(2))

        actionCont.yield(.otherAction)

        try await recorder.waitForEmissions(count: 2, timeout: .seconds(2))
        actionCont.finish()

        // Should receive: initial state + state after otherAction
        #expect(recorder.values.count == 2)

        // First state is initial
        #expect(recorder.values[0].counter.count == 0)
        #expect(recorder.values[0].otherProperty == "test")

        // Second state has modified otherProperty
        #expect(recorder.values[1].otherProperty == "modified")
        #expect(recorder.values[1].counter.count == 0)  // Counter unchanged
    }

    @Test
    func whenMultipleChildActions() async throws {
        let interactor = Interact<ParentState, ParentAction>(
            initialValue: ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")
        ) { state, action in
            switch action {
            case .counterStateChanged(let counterState):
                state.counter = counterState
                return .state
            case .counter, .otherAction:
                return .state
            }
        }
            .when(stateIs: \.counter, actionIs: \.counter, stateAction: \.counterStateChanged) {
                CounterInteractor()
            }

        let recorder = AsyncStreamRecorder<ParentState>()
        let (actionStream, actionCont) = AsyncStream<ParentAction>.makeStream()

        recorder.record(interactor.interact(actionStream))

        try await recorder.waitForEmissions(count: 1, timeout: .seconds(2))

        actionCont.yield(.counter(.increment))  // count: 0 -> 1
        actionCont.yield(.counter(.increment))  // count: 1 -> 2
        actionCont.yield(.counter(.decrement))  // count: 2 -> 1

        try await recorder.waitForEmissions(count: 4, timeout: .seconds(2))  // initial + 3 state changes
        actionCont.finish()

        #expect(recorder.values.count == 4)

        // Child actions are filtered - only state changes reach parent
        let counterValues = recorder.values.map { $0.counter.count }
        #expect(counterValues == [0, 1, 2, 1])
    }

    @Test
    func whenChainingMultipleModifiers() async throws {
        let interactor = Interact<ParentStateWithTwo, ParentActionWithTwo>(
            initialValue: ParentStateWithTwo(
                counter1: CounterInteractor.State(count: 0),
                counter2: CounterInteractor.State(count: 10)
            )
        ) { state, action in
            switch action {
            case .counter1StateChanged(let counterState):
                state.counter1 = counterState
                return .state
            case .counter2StateChanged(let counterState):
                state.counter2 = counterState
                return .state
            case .counter1, .counter2:
                return .state
            }
        }
            .when(stateIs: \.counter1, actionIs: \.counter1, stateAction: \.counter1StateChanged) {
                CounterInteractor()
            }
            .when(stateIs: \.counter2, actionIs: \.counter2, stateAction: \.counter2StateChanged) {
                Interact<CounterInteractor.State, CounterInteractor.Action>(initialValue: CounterInteractor.State(count: 10)) { state, action in
                    switch action {
                    case .increment:
                        state.count += 1
                        return .state
                    case .decrement:
                        state.count -= 1
                        return .state
                    case .reset:
                        state.count = 10
                        return .state
                    }
                }
            }

        let recorder = AsyncStreamRecorder<ParentStateWithTwo>()
        let (actionStream, actionCont) = AsyncStream<ParentActionWithTwo>.makeStream()

        recorder.record(interactor.interact(actionStream))

        try await recorder.waitForEmissions(count: 1, timeout: .seconds(2))

        actionCont.yield(.counter1(.increment))  // counter1: 0 -> 1
        try await recorder.waitForEmissions(count: 2, timeout: .seconds(2))

        actionCont.yield(.counter2(.decrement))  // counter2: 10 -> 9
        try await recorder.waitForEmissions(count: 3, timeout: .seconds(2))

        actionCont.finish()

        #expect(recorder.values.count == 3)

        // Initial state
        #expect(recorder.values[0].counter1.count == 0)
        #expect(recorder.values[0].counter2.count == 10)

        // After counter1 state changed
        #expect(recorder.values[1].counter1.count == 1)
        #expect(recorder.values[1].counter2.count == 10)

        // After counter2 state changed
        #expect(recorder.values[2].counter1.count == 1)
        #expect(recorder.values[2].counter2.count == 9)
    }
}
