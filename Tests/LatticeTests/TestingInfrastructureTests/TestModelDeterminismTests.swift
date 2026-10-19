import Foundation
import Testing

@testable import Lattice

@FeatureState
struct TickState: Equatable, Sendable {
    var count = 0
}

enum TickAction: Equatable, Sendable {
    case tick
}

/// Counts up, and its effect counts down after a `Task.yield()`, which ignores cancellation.
@Interactor<TickState, TickAction>
struct TickInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .tick:
                state.count += 1
                effects.perform {
                    await Task.yield()
                    try effects.modify { $0.count -= 1 }
                }
            }
        }
    }
}

/// Repeated runs of the shapes whose outcome must not depend on scheduling.
@Suite
struct TestModelDeterminismTests {
    /// `send`'s assertion sees the root transition only; the effect's modification after its yield
    /// is pending once the send's task is done, for `expect`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(arguments: 1...300)
    func yieldThenModifyCounterSettlesWithinTheSendTask(iteration: Int) async {
        let issues = await reportedIssueDetails {
            let model = await TestModel(initialState: TickState(), feature: Feature(interactor: TickInteractor()))
            await model.send(.tick) { $0.count = 1 }?.value
            await model.expect { $0.count = 0 }
            await model.finish()
        }

        #expect(issues == [])
    }

    /// Each re-sent `.tick` auto-cancels the previous tick's effect, but `Task.yield()` ignores
    /// cancellation, so every decrement is still committed: 100 increments and 100 decrements. `.off`,
    /// because whether a decrement lands before or after the next send is scheduling.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(arguments: 1...30)
    func reSentTicksStillCommitEveryDecrement(iteration: Int) async {
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: TickState(),
                feature: Feature(interactor: TickInteractor()),
                exhaustivity: .off(showSkippedAssertions: false)
            )
            for _ in 1...100 {
                await model.send(.tick) { $0.count += 1 }
            }
            await model.finish()
            #expect(await model.state.count == 0)
        }

        #expect(issues == [])
    }
}
