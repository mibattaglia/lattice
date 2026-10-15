import Foundation
import Testing

@testable import Lattice

/// A reference the interactor and its effect share, and that the state carries: not `Sendable`.
final class NonSendableCounterBox {
    var value = 0
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

enum NonSendableBoxAction: Equatable {
    case bump
}

@Interactor<NonSendableBoxState, NonSendableBoxAction>
struct NonSendableBoxInteractor {
    /// A non-Sendable dependency, used from `interact` and from the effect.
    let counter: NonSendableCounterBox

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .bump:
                counter.value += 1
                state.count = counter.value
                effects.perform {
                    await Task.yield()
                    counter.value += 1
                    try effects.modify { $0.count = counter.value }
                }
            }
        }
    }
}

/// Nothing in the feature layer has to be `Sendable` for `TestModel`: the state, the action and
/// the dependency here are not. Assertions go through the model's closures; reading `state` from
/// this nonisolated test would need a `Sendable` state.
@Suite
struct TestModelNonSendableTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func nonSendableStateAndDependencyRunUnderTheTestModel() async {
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: NonSendableBoxState(),
                feature: Feature(interactor: NonSendableBoxInteractor(counter: NonSendableCounterBox()))
            )
            await model.send(.bump) { $0.count = 1 }?.value
            await model.expect { $0.count = 2 }
            await model.send(.bump) { $0.count = 3 }?.value
            await model.expect { $0.count = 4 }
            await model.finish()
        }

        #expect(issues == [])
    }
}
