import Foundation
import Testing

@testable import Lattice

// What `.append` and `.observe` expressed is now one effect: steps done in order inside it, and a
// `for await` over a stream inside it.

@FeatureState
struct EffectSequenceState: Equatable, Sendable {
    var log: [String] = []
}

enum EffectSequenceAction: Equatable, Sendable {
    /// Its effect sends `.logged("first")`, `.logged("second")` and `.logged("third")`, one after
    /// another, each after a `Task.yield()`.
    case runSequence
    /// Its effect sends `.logged(value)` for every value of a two-value stream.
    case observeStream
    case logged(String)
}

@Interactor<EffectSequenceState, EffectSequenceAction>
struct EffectSequenceInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .runSequence:
                effects.perform {
                    for value in ["first", "second", "third"] {
                        await Task.yield()
                        try effects.send(.logged(value))
                    }
                }

            case .observeStream:
                effects.perform {
                    let values = AsyncStream<String> { continuation in
                        continuation.yield("stream-1")
                        continuation.yield("stream-2")
                        continuation.finish()
                    }
                    for await value in values {
                        try effects.send(.logged(value))
                    }
                }

            case .logged(let value):
                state.log.append(value)
            }
        }
    }
}

@Suite
struct TestModelEffectSequenceTests {
    /// The send's task covers the whole effect; the actions it sent wait, outside `state`, until a
    /// `receive` asserts each of them, in order.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func sendTaskCoversAnEffectsSequentialSendsWhichStayPendingUntilReceived() async {
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: EffectSequenceState(),
                feature: Feature(interactor: EffectSequenceInteractor())
            )
            await model.send(.runSequence)?.value
            #expect(await model.state.log == [])

            await model.receive(.logged("first")) { $0.log = ["first"] }
            await model.receive(.logged("second")) { $0.log = ["first", "second"] }
            await model.receive(.logged("third")) { $0.log = ["first", "second", "third"] }
            await model.finish()
        }

        #expect(issues == [])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func actionsAStreamEffectSendsStayPendingUntilReceived() async {
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: EffectSequenceState(),
                feature: Feature(interactor: EffectSequenceInteractor())
            )
            await model.send(.observeStream)?.value
            #expect(await model.state.log == [])

            await model.receive(.logged("stream-1")) { $0.log = ["stream-1"] }
            await model.receive(.logged("stream-2")) { $0.log = ["stream-1", "stream-2"] }
            await model.finish()
        }

        #expect(issues == [])
    }
}
