import Foundation
import Testing

@testable import Lattice

@FeatureState
struct BlockingEffectState: Equatable, Sendable {
    var blocks = 0
}

enum BlockingEffectAction: Equatable, Sendable {
    case block
}

/// Blocks the calling thread for 1 ms. Synchronous: `Thread.sleep` is unavailable from async code.
private func blockTheCurrentThreadForOneMillisecond() {
    Thread.sleep(forTimeInterval: 0.001)
}

/// Its effect blocks its model's executor for 1 ms, in its preamble, then counts the block.
@Interactor<BlockingEffectState, BlockingEffectAction>
struct BlockingEffectInteractor {
    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .block:
                effects.perform {
                    blockTheCurrentThreadForOneMillisecond()
                    try effects.modify { $0.blocks += 1 }
                }
            }
        }
    }
}

/// When every case of the two parameterized tests ran, from its start to its end. The case that
/// completes both records compares the wall times of the two variants.
final class ParallelismTimings: @unchecked Sendable {
    enum Variant {
        case testModel
        case viewModel
    }

    struct Interval {
        let start: ContinuousClock.Instant
        let end: ContinuousClock.Instant
    }

    struct Comparison {
        let testModelWallTime: Duration
        let viewModelWallTime: Duration
        /// Whether any two `TestModel` cases ran at the same time: `false` when the test runner ran
        /// the cases one at a time (`swift test --no-parallel`), which leaves nothing to compare.
        let testModelCasesOverlapped: Bool
    }

    static let caseCount = 500

    private let lock = NSLock()
    private var intervals: [Variant: [Interval]] = [:]

    /// Records a case; returns the comparison when it completes both records, and starts over.
    func record(_ variant: Variant, _ interval: Interval) -> Comparison? {
        lock.withLock {
            intervals[variant, default: []].append(interval)
            guard let testModelCases = intervals[.testModel], testModelCases.count == Self.caseCount,
                let viewModelCases = intervals[.viewModel], viewModelCases.count == Self.caseCount
            else { return nil }
            intervals = [:]
            return Comparison(
                testModelWallTime: Self.wallTime(of: testModelCases),
                viewModelWallTime: Self.wallTime(of: viewModelCases),
                testModelCasesOverlapped: Self.overlap(testModelCases)
            )
        }
    }

    private static func wallTime(of intervals: [Interval]) -> Duration {
        let start = intervals.map(\.start).min()!
        let end = intervals.map(\.end).max()!
        return start.duration(to: end)
    }

    private static func overlap(_ intervals: [Interval]) -> Bool {
        let sorted = intervals.sorted { $0.start < $1.start }
        var latestEnd = sorted[0].end
        for interval in sorted.dropFirst() {
            if interval.start < latestEnd { return true }
            latestEnd = max(latestEnd, interval.end)
        }
        return false
    }
}

private let parallelismTimings = ParallelismTimings()

/// §8: features under `TestModel` run on their own executors, so 500 effects that each block for
/// 1 ms run in parallel on the cooperative pool; under `ViewModel` they all block the main actor,
/// one after another (at least 500 ms). Each parameterized test records its cases; the case that
/// completes both records asserts that the `TestModel` cases took less wall time.
@Suite
struct ParallelismTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(arguments: 1...ParallelismTimings.caseCount)
    func testModelEffectsThatBlockRunInParallel(case index: Int) async {
        let start = ContinuousClock.now
        let model = await TestModel(
            initialState: BlockingEffectState(),
            feature: Feature(interactor: BlockingEffectInteractor())
        )
        await model.send(.block) { $0.blocks = 1 }  // the preamble's modification is folded in
        await model.finish()
        let end = ContinuousClock.now

        compareWhenBothVariantsRan(parallelismTimings.record(.testModel, .init(start: start, end: end)))
    }

    @MainActor
    @Test(arguments: 1...ParallelismTimings.caseCount)
    func viewModelEffectsThatBlockRunOneAfterAnotherOnTheMainActor(case index: Int) async {
        let start = ContinuousClock.now
        let viewModel = ViewModel(
            initialState: BlockingEffectState(),
            feature: Feature(interactor: BlockingEffectInteractor())
        )
        viewModel.sendViewEvent(.block)  // the preamble blocks the main actor
        #expect(viewModel.blocks == 1)
        let end = ContinuousClock.now

        compareWhenBothVariantsRan(parallelismTimings.record(.viewModel, .init(start: start, end: end)))
    }

    private func compareWhenBothVariantsRan(_ comparison: ParallelismTimings.Comparison?) {
        guard let comparison else { return }
        // At least 500 blocks of 1 ms, one after another on the main thread.
        #expect(comparison.viewModelWallTime >= .milliseconds(ParallelismTimings.caseCount))
        // Parallelism needs a test runner that runs cases concurrently, and more than one core.
        guard comparison.testModelCasesOverlapped, ProcessInfo.processInfo.activeProcessorCount > 1 else { return }
        #expect(
            comparison.testModelWallTime < comparison.viewModelWallTime,
            "TestModel cases took \(comparison.testModelWallTime), ViewModel cases \(comparison.viewModelWallTime)"
        )
    }
}
