import Foundation
import Testing

@testable import Lattice

// The examples of the plan's §5.5 (`search`, `timer`) and §7 (`hydrates`): the search debounces on
// an `EffectClock` that the test advances, a tick stream drives the timer, and a stub or a gated
// client stands in for the network.

// MARK: - §5.5 search

@FeatureState
struct SearchExampleState: Equatable, Sendable {
    var query = ""
    var results: [String] = []
}

enum SearchExampleAction: Equatable, Sendable {
    case queryChanged(String)
}

@Interactor<SearchExampleState, SearchExampleAction>
struct SearchExampleInteractor<C: Clock<Duration>> {
    let clock: C

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .queryChanged(let query):
                state.query = query
                effects.perform {
                    try await clock.sleep(for: .milliseconds(300))  // the debounce: the next query cancels it
                    try effects.modify { $0.results = [query] }
                }
            }
        }
    }
}

// MARK: - §5.5 timer

@FeatureState
struct TimerExampleState: Equatable, Sendable {
    var ticks = 0
}

enum TimerExampleAction: Equatable, Sendable {
    case start
    case stop
}

/// One modification per tick of `ticks`; each processed tick is reported on `ticked`, so the test
/// knows when to assert. `.stop` cancels the timer through its key: auto-cancel is per action case,
/// and `.stop` is another case.
@Interactor<TimerExampleState, TimerExampleAction>
struct TimerExampleInteractor {
    @EffectID var timer
    let ticks: AsyncStream<Void>
    let ticked: AsyncStream<Int>.Continuation

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .start:
                effects.perform(id: timer) {
                    for await _ in ticks {
                        try effects.modify { $0.ticks += 1 }
                        ticked.yield(effects.state.ticks)
                    }
                }
            case .stop:
                effects.cancel(timer)
            }
        }
    }
}

// MARK: - §7 hydrates

@FeatureState
struct CounterExampleState: Equatable, Sendable {
    var count = 0
    var isRefreshing = false
    @Domain var lastUpdatedAt: Date?
}

enum CounterExampleAction: Equatable, Sendable {
    case task
    case cancelRefresh
}

struct CounterExampleAPIModel {
    let count: Int
    let updatedAt: Date
}

/// Not `Sendable`. Its method is `nonisolated(nonsending)`, as a module without
/// `NonisolatedNonsendingByDefault` must declare it for the effect to call it on the model.
protocol CounterExampleClient {
    nonisolated(nonsending) func fetch() async throws -> CounterExampleAPIModel
}

final class StubCounterExampleClient: CounterExampleClient {
    static let date = Date(timeIntervalSince1970: 1_000)
    let count: Int

    init(count: Int) {
        self.count = count
    }

    nonisolated(nonsending) func fetch() async throws -> CounterExampleAPIModel {
        await Task.yield()
        return CounterExampleAPIModel(count: count, updatedAt: Self.date)
    }
}

/// Fetches through a gate the test never opens: a cancellation-aware suspension, so a cancelled
/// refresh never writes a result.
final class GatedCounterExampleClient: CounterExampleClient {
    let gate = Gate()

    nonisolated(nonsending) func fetch() async throws -> CounterExampleAPIModel {
        try await gate.pass()
        return CounterExampleAPIModel(count: 9, updatedAt: StubCounterExampleClient.date)
    }
}

@Interactor<CounterExampleState, CounterExampleAction>
struct CounterExampleInteractor {
    @EffectID var refresh
    let counterClient: CounterExampleClient

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .task:
                state.isRefreshing = true
                effects.perform(id: refresh) {
                    defer { try? effects.modify { $0.isRefreshing = false } }  // also runs when cancelled
                    let model = try await counterClient.fetch()
                    try effects.modify {
                        $0.count = model.count
                        $0.lastUpdatedAt = model.updatedAt
                    }
                }
            case .cancelRefresh:
                effects.cancel(refresh)
            }
        }
    }
}

// MARK: - Tests

@Suite
struct TestModelExampleTests {
    /// The second query auto-cancels the first one's effect while it waits out the debounce: only
    /// "b" writes results.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func search() async {
        let clock = EffectClock()
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: SearchExampleState(),
                feature: Feature(interactor: SearchExampleInteractor(clock: clock))
            )
            await model.send(.queryChanged("a")) { $0.query = "a" }
            await model.send(.queryChanged("b")) { $0.query = "b" }  // auto-cancels "a" while it sleeps
            #expect(clock.sleeperCount == 1)  // "a"'s sleep left the clock inside that `send`
            await model.advance(clock, by: .milliseconds(300))
            await model.expect { $0.results = ["b"] }  // the effect wrote the results directly
            await model.finish()
        }

        #expect(issues == [])
    }

    /// Three ticks are three modifications and one `expect`; `.stop` cancels the timer.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func timer() async {
        let (ticks, tick) = AsyncStream.makeStream(of: Void.self)
        let (ticked, tickedContinuation) = AsyncStream.makeStream(of: Int.self)
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: TimerExampleState(),
                feature: Feature(interactor: TimerExampleInteractor(ticks: ticks, ticked: tickedContinuation))
            )
            await model.send(.start)
            var processedTicks = ticked.makeAsyncIterator()
            for _ in 1...3 {
                tick.yield()
                _ = await processedTicks.next()
            }
            await model.expect { $0.ticks = 3 }
            await model.send(.stop)
            await model.finish()
        }

        #expect(issues == [])
    }

    /// The refresh writes `count` and `lastUpdatedAt`, then its `defer` clears `isRefreshing`: one
    /// `expect` describes both modifications.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func hydrates() async {
        let issues = await reportedIssueDetails {
            let interactor = CounterExampleInteractor(counterClient: StubCounterExampleClient(count: 4))
            let model = await TestModel(initialState: CounterExampleState(), feature: Feature(interactor: interactor))
            await model.send(.task) { $0.isRefreshing = true }?.value
            await model.expect {
                $0.count = 4
                $0.lastUpdatedAt = StubCounterExampleClient.date
                $0.isRefreshing = false
            }
            await model.finish()
        }

        #expect(issues == [])
    }

    /// `.cancelRefresh` cancels the identified refresh from another case, at its cancellation-aware
    /// fetch; its `defer` still clears `isRefreshing`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func cancelRefresh() async {
        let issues = await reportedIssueDetails {
            let interactor = CounterExampleInteractor(counterClient: GatedCounterExampleClient())
            let model = await TestModel(initialState: CounterExampleState(), feature: Feature(interactor: interactor))
            let task = await model.send(.task) { $0.isRefreshing = true }
            await model.send(.cancelRefresh)
            await task?.value
            await model.expect { $0.isRefreshing = false }
            await model.finish()
        }

        #expect(issues == [])
    }
}
