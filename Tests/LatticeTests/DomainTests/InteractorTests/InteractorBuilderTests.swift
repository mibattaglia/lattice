// The free functions are compile time tests, only to make sure type inference works; the suite at
// the end runs a built interactor through a test model.
import Foundation
import Testing

@testable import Lattice

private struct MyState: Sendable {}
private enum MyAction: Sendable { case myAction }

private struct TestInteractor: Interactor, Sendable {
    var body: some Interactor<MyAction, MyState> {
        EmptyInteractor()
    }
}

@available(iOS, introduced: 9999)
@available(macOS, introduced: 9999)
@available(tvOS, introduced: 9999)
@available(visionOS, introduced: 9999)
@available(watchOS, introduced: 9999)
private struct UnavailableInteractor: Interactor, Sendable {
    var body: some Interactor<MyAction, MyState> {
        EmptyInteractor()
    }
}

func limitedAvailability() {
    _ = Interactors.CollectInteractors {
        TestInteractor()
        if #available(iOS 9999, macOS 9999, tvOS 9999, visionOS 9999, watchOS 9999, *) {
            UnavailableInteractor()
        }

        if #available(iOS 8888, macOS 8888, tvOS 8888, visionOS 8888, watchOS 8888, *) {
            EmptyInteractor<MyAction, MyState>()
        }
    }
}

func controlFlow() {
    _ = Interactors.CollectInteractors {
        if Bool.random() {
            TestInteractor()
        }

        TestInteractor()

        for _ in 0...10 {
            EmptyInteractor<MyAction, MyState>()
        }
    }
}

func existentials() {
    _ = Interactors.CollectInteractors {
        TestInteractor()
        TestInteractor() as any InteractorOf<TestInteractor>
    }
}

@FeatureState
private struct BuilderState: Equatable {
    var handled: [String] = []
    var performed: [String] = []
}

private enum BuilderAction {
    case run
}

/// Records that it handled the action, and performs an effect that records it too.
private struct MarkerInteractor: Interactor {
    typealias State = BuilderState
    typealias Action = BuilderAction

    let name: String

    var body: some InteractorOf<Self> { self }

    func interact(state: inout BuilderState, action: BuilderAction, effects: Effects<BuilderState, BuilderAction>) {
        state.handled.append(name)
        effects.perform { try effects.modify { $0.performed.append(name) } }
    }
}

@Suite
struct InteractorBuilderTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(arguments: [true, false])
    func builtInteractorRunsTheChildrenItsControlFlowSelectsInOrder(includeOptional: Bool) async {
        let interactor = Interactors.CollectInteractors<BuilderState, BuilderAction, _> {
            MarkerInteractor(name: "first")
            if includeOptional {
                MarkerInteractor(name: "optional")
            }
            if !includeOptional {
                MarkerInteractor(name: "if")
            } else {
                MarkerInteractor(name: "else")
            }
            for index in 0..<2 {
                MarkerInteractor(name: "loop \(index)")
            }
            if #available(iOS 9999, macOS 9999, tvOS 9999, visionOS 9999, watchOS 9999, *) {
                MarkerInteractor(name: "unavailable")
            }
            MarkerInteractor(name: "existential") as any InteractorOf<MarkerInteractor>
        }
        let model = await TestModel(initialState: BuilderState(), feature: Feature(interactor: interactor))

        let selected = includeOptional ? ["optional", "else"] : ["if"]
        let children = ["first"] + selected + ["loop 0", "loop 1", "existential"]
        // Every child's effect started, in the same order, before `send` returned: their
        // modifications are folded into it.
        await model.send(.run) {
            $0.handled = children
            $0.performed = children
        }
        await model.finish()
    }
}
