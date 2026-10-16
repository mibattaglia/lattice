import CasePaths
import Foundation
import Testing

@testable import Lattice

// MARK: - Test Domain Models

@FeatureState
struct ParentState: Equatable, Sendable {
    var counter: CounterState
    var otherProperty: String
}

@CasePathable
enum ParentAction: Sendable, Equatable {
    case counter(CounterAction)
    case otherAction
}

@FeatureState
struct TwoCounterState: Equatable, Sendable {
    var counter1: CounterState
    var counter2: CounterState
}

@CasePathable
enum TwoCounterAction: Sendable {
    case counter1(CounterAction)
    case counter2(CounterAction)
}

@CasePathable
enum LoadingAction: Sendable {
    case startLoading
    case loaded(CounterAction)
}

/// A test model over `interactor` from `initialState`. It forwards the caller's location, so the
/// reports the model makes at its creation point at the test.
@available(iOS 26, macOS 26, watchOS 26, *)
private func makeModel<I: Interactor>(
    _ initialState: sending I.State,
    _ interactor: sending I,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> TestModel<Feature<I.Action, I.State>> where I.State: FeatureState & Equatable {
    await TestModel(
        initialState: initialState,
        feature: Feature(interactor: interactor),
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

// MARK: - KeyPath Tests

@Suite
struct WhenKeyPathTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func basicFunctionality() async {
        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }
        let model = await makeModel(ParentState(counter: CounterState(count: 0), otherProperty: "test"), interactor)

        let task = await model.send(.counter(.increment)) { $0.counter.count = 1 }  // `otherProperty` untouched

        // The child performed no effect
        #expect(task == nil)
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func ignoresNonChildActions() async {
        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }
        let model = await makeModel(ParentState(counter: CounterState(count: 0), otherProperty: "test"), interactor)

        let task = await model.send(.otherAction)  // changes nothing

        #expect(task == nil)
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func multipleActions() async {
        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }
        let model = await makeModel(ParentState(counter: CounterState(count: 0), otherProperty: "test"), interactor)

        await model.send(.counter(.increment)) { $0.counter.count = 1 }
        await model.send(.counter(.increment)) { $0.counter.count = 2 }
        await model.send(.counter(.decrement)) { $0.counter.count = 1 }
        await model.finish()
    }

    /// The child's send reaches the parent as `.counter(.decrement)`, the action the test model
    /// receives, and is routed back to the child. The child's effect never suspends, so the action is
    /// handled depth-first, before `send` returns: with no effect left in flight, `receive` passes
    /// only because the action is already pending.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func childEffectSendIsEmbeddedInTheParentAction() async {
        let childInteractor = Interact<CounterState, CounterAction> { state, action, effects in
            switch action {
            case .increment:
                state.count += 1
                effects.perform { try effects.send(.decrement) }
            case .decrement:
                state.count -= 1
            case .reset:
                state.count = 0
            }
        }
        let interactor = Interactors.When<ParentState, ParentAction, _>(state: \.counter, action: \.counter) {
            childInteractor
        }
        let model = await makeModel(ParentState(counter: CounterState(count: 0), otherProperty: "test"), interactor)

        await model.send(.counter(.increment)) { $0.counter.count = 1 }
        await model.receive(.counter(.decrement)) { $0.counter.count = 0 }
        await model.finish()
    }
}

// MARK: - Modifier Tests

@Suite
struct WhenModifierTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func modifierCombinesWithParent() async {
        let interactor = Interact<ParentState, ParentAction> { state, action in
            switch action {
            case .otherAction:
                state.otherProperty = "modified"
            case .counter:
                break
            }
        }
        .when(state: \.counter, action: \.counter) {
            CounterInteractor()
        }
        let model = await makeModel(ParentState(counter: CounterState(count: 0), otherProperty: "test"), interactor)

        await model.send(.counter(.increment)) { $0.counter.count = 1 }  // `otherProperty` untouched
        await model.send(.otherAction) { $0.otherProperty = "modified" }
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func multipleWhenModifiers() async {
        let interactor = Interact<TwoCounterState, TwoCounterAction> { _, _ in }
            .when(state: \.counter1, action: \.counter1) {
                CounterInteractor()
            }
            .when(state: \.counter2, action: \.counter2) {
                CounterInteractor()
            }
        let model = await makeModel(
            TwoCounterState(
                counter1: CounterState(count: 0),
                counter2: CounterState(count: 10)
            ),
            interactor
        )

        await model.send(.counter1(.increment)) { $0.counter1.count = 1 }  // `counter2` untouched
        await model.send(.counter2(.decrement)) { $0.counter2.count = 9 }  // `counter1` untouched
        await model.finish()
    }
}

// MARK: - CasePath Tests

@Suite
struct WhenCasePathTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func basicFunctionality() async {
        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }
        let model = await makeModel(LoadingState.loaded(CounterState(count: 0)), interactor)

        let task = await model.send(.loaded(.increment)) { $0 = .loaded(CounterState(count: 1)) }

        #expect(task == nil)
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func ignoresWhenStateDoesNotMatch() async {
        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }
        let model = await makeModel(LoadingState.idle, interactor)

        let task = await model.send(.loaded(.increment))  // stays `.idle`

        #expect(task == nil)
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func ignoresNonChildActions() async {
        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }
        let model = await makeModel(LoadingState.loaded(CounterState(count: 0)), interactor)

        let task = await model.send(.startLoading)  // the child's count stays 0

        #expect(task == nil)
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func casePathModifier() async {
        let interactor = Interact<LoadingState, LoadingAction> { state, action in
            switch action {
            case .startLoading:
                state = .loading
            case .loaded:
                break
            }
        }
        .when(state: \.loaded, action: \.loaded) {
            CounterInteractor()
        }
        let model = await makeModel(LoadingState.loaded(CounterState(count: 0)), interactor)

        await model.send(.loaded(.increment)) { $0 = .loaded(CounterState(count: 1)) }
        await model.send(.startLoading) { $0 = .loading }
        await model.finish()
    }
}
