import Foundation
import Testing

@testable import Lattice

/// A reference the interactor and its effect share, that the state carries and that an action
/// carries: not `Sendable`.
final class NonSendableCounterBox {
    var value: Int

    init(value: Int = 0) {
        self.value = value
    }
}

/// Not `Sendable`: it carries a ``NonSendableCounterBox``. Equal by `count`.
@FeatureState
struct NonSendableBoxState: Equatable {
    var count = 0
    @Domain var box = NonSendableCounterBox()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.count == rhs.count
    }
}

/// Not `Sendable`: `.bump` carries a ``NonSendableCounterBox`` with the step to add.
enum NonSendableBoxAction {
    case bump(NonSendableCounterBox)
}

@Interactor<NonSendableBoxState, NonSendableBoxAction>
struct NonSendableBoxInteractor {
    /// A non-Sendable dependency, used from `interact` and from the effect.
    let counter: NonSendableCounterBox

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .bump(let step):
                counter.value += step.value
                state.count = counter.value
                effects.perform {
                    await Task.yield()
                    counter.value += step.value
                    try effects.modify { $0.count = counter.value }
                }
            }
        }
    }
}

/// Nothing in the feature layer has to be `Sendable` for `TestModel`: the state, the action and
/// the dependency here are not. Each action is a new value, so `send` can hand it to the model's
/// executor. Assertions go through the model's closures; reading `state` from this nonisolated test
/// would need a `Sendable` state.
@Suite
struct TestModelNonSendableTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func nonSendableStateActionAndDependencyRunUnderTheTestModel() async {
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: NonSendableBoxState(),
                feature: Feature(interactor: NonSendableBoxInteractor(counter: NonSendableCounterBox()))
            )
            await model.send(.bump(NonSendableCounterBox(value: 1))) { $0.count = 1 }?.value
            await model.expect { $0.count = 2 }
            await model.send(.bump(NonSendableCounterBox(value: 2))) { $0.count = 4 }?.value
            await model.expect { $0.count = 6 }
            await model.finish()
        }

        #expect(issues == [])
    }
}
