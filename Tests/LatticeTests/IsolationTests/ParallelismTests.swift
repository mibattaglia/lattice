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

/// Its effect blocks its model's executor for 1 ms, in its preamble, records when it blocked, then
/// counts the block.
@Interactor<BlockingEffectState, BlockingEffectAction>
struct BlockingEffectInteractor {
    let variant: ParallelismTimings.Variant

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .block:
                effects.perform {
                    let start = ContinuousClock.now
                    blockTheCurrentThreadForOneMillisecond()
                    parallelismTimings.recordBlock(variant, .init(start: start, end: .now))
                    try effects.modify { $0.blocks += 1 }
                }
            }
        }
    }
}

/// When every case of the parameterized tests ran, from its start to its end, and when the effect of
/// each case blocked. The case that completes the record of every variant compares the variants.
final class ParallelismTimings: @unchecked Sendable {
    enum Variant: CaseIterable {
        case testModel
        case actorModel
        case viewModel
    }

    struct Interval {
        let start: ContinuousClock.Instant
        let end: ContinuousClock.Instant
    }

    /// The complete record of one variant.
    struct Record {
        /// From the start of its first case to the end of its last.
        let wallTime: Duration
        /// Whether any two cases ran at the same time: `false` when the test runner ran the cases one
        /// at a time (`swift test --no-parallel`), which leaves nothing to compare.
        let casesOverlapped: Bool
        /// Whether any two effects blocked at the same time, which effects serialized on one executor
        /// cannot do.
        let blocksOverlapped: Bool
    }

    struct Comparison {
        let records: [Variant: Record]

        subscript(variant: Variant) -> Record {
            records[variant]!
        }
    }

    static let caseCount = 500

    private let lock = NSLock()
    private var cases: [Variant: [Interval]] = [:]
    private var blocks: [Variant: [Interval]] = [:]

    /// Records when the effect of a case blocked. The effect runs inside the case's `send`, so it
    /// records its block before the case records itself.
    func recordBlock(_ variant: Variant, _ interval: Interval) {
        lock.withLock {
            blocks[variant, default: []].append(interval)
        }
    }

    /// Records a case; returns the comparison when it completes the record of every variant, and
    /// starts over.
    func recordCase(_ variant: Variant, _ interval: Interval) -> Comparison? {
        lock.withLock {
            cases[variant, default: []].append(interval)
            guard Variant.allCases.allSatisfy({ cases[$0]?.count == Self.caseCount }) else { return nil }
            defer {
                cases = [:]
                blocks = [:]
            }
            var records: [Variant: Record] = [:]
            for variant in Variant.allCases {
                let variantCases = cases[variant] ?? []
                records[variant] = Record(
                    wallTime: Self.wallTime(of: variantCases),
                    casesOverlapped: Self.overlap(variantCases),
                    blocksOverlapped: Self.overlap(blocks[variant] ?? [])
                )
            }
            return Comparison(records: records)
        }
    }

    private static func wallTime(of intervals: [Interval]) -> Duration {
        let start = intervals.map(\.start).min()!
        let end = intervals.map(\.end).max()!
        return start.duration(to: end)
    }

    private static func overlap(_ intervals: [Interval]) -> Bool {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var latestEnd = sorted.first?.end else { return false }
        for interval in sorted.dropFirst() {
            if interval.start < latestEnd { return true }
            latestEnd = max(latestEnd, interval.end)
        }
        return false
    }
}

private let parallelismTimings = ParallelismTimings()

/// §8: features under `TestModel` and `ActorModel` run on their own executors, so 500 effects that
/// each block for 1 ms run in parallel on the cooperative pool; under `ViewModel` they all block the
/// main actor, one after another (at least 500 ms). Each parameterized test records its cases and
/// their blocks; the case that completes every record asserts that the cases of each actor shell
/// took less wall time, and that two of its effects blocked at the same time.
@Suite
struct ParallelismTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(arguments: 1...ParallelismTimings.caseCount)
    func testModelEffectsThatBlockRunInParallel(case index: Int) async {
        let start = ContinuousClock.now
        let model = await TestModel(
            initialState: BlockingEffectState(),
            feature: Feature(interactor: BlockingEffectInteractor(variant: .testModel))
        )
        await model.send(.block) { $0.blocks = 1 }  // the preamble's modification is folded in
        await model.finish()
        let end = ContinuousClock.now

        compareWhenEveryVariantRan(parallelismTimings.recordCase(.testModel, .init(start: start, end: end)))
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(arguments: 1...ParallelismTimings.caseCount)
    func actorModelEffectsThatBlockRunInParallel(case index: Int) async {
        let start = ContinuousClock.now
        let model = await ActorModel(
            initialState: BlockingEffectState(),
            feature: Feature(interactor: BlockingEffectInteractor(variant: .actorModel))
        )
        await model.send(.block)  // the preamble blocks the model's executor and commits inside `send`
        #expect(await model.state.blocks == 1)
        let end = ContinuousClock.now

        compareWhenEveryVariantRan(parallelismTimings.recordCase(.actorModel, .init(start: start, end: end)))
    }

    @MainActor
    @Test(arguments: 1...ParallelismTimings.caseCount)
    func viewModelEffectsThatBlockRunOneAfterAnotherOnTheMainActor(case index: Int) async {
        let start = ContinuousClock.now
        let viewModel = ViewModel(
            initialState: BlockingEffectState(),
            feature: Feature(interactor: BlockingEffectInteractor(variant: .viewModel))
        )
        viewModel.sendViewEvent(.block)  // the preamble blocks the main actor
        #expect(viewModel.blocks == 1)
        let end = ContinuousClock.now

        compareWhenEveryVariantRan(parallelismTimings.recordCase(.viewModel, .init(start: start, end: end)))
    }

    private func compareWhenEveryVariantRan(_ comparison: ParallelismTimings.Comparison?) {
        guard let comparison else { return }
        let viewModel = comparison[.viewModel]
        // At least 500 blocks of 1 ms, one after another on the main thread. Blocks serialized like
        // these never count as overlapping: the control for the overlap checks below.
        #expect(viewModel.wallTime >= .milliseconds(ParallelismTimings.caseCount))
        #expect(!viewModel.blocksOverlapped)
        // Parallelism needs a test runner that runs cases concurrently, and more than one core.
        guard ProcessInfo.processInfo.activeProcessorCount > 1 else { return }
        for variant in [ParallelismTimings.Variant.testModel, .actorModel] where comparison[variant].casesOverlapped {
            let record = comparison[variant]
            #expect(record.blocksOverlapped, "No two \(variant) effects blocked at the same time")
            #expect(
                record.wallTime < viewModel.wallTime,
                "The cases took \(record.wallTime) under \(variant) and \(viewModel.wallTime) under .viewModel"
            )
        }
    }
}
