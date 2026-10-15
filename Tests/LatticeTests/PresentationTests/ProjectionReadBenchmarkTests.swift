// A member read through the generated projection costs at most 1.2× the same read on the raw
// state. Compiled for release builds only, so `swift test` skips it; run it with
// `swift test -c release --filter ProjectionReadBenchmark`.
#if !DEBUG
    import Foundation
    import Testing

    @testable import Lattice

    @FeatureState
    private struct BenchmarkBadgeState: Equatable, Sendable {
        var count = 1
    }

    @FeatureState
    private struct BenchmarkState: Equatable, Sendable {
        var title = "Benchmark"
        var badge = BenchmarkBadgeState()
    }

    private enum BenchmarkAction: Sendable {
        case noop
    }

    @Interactor<BenchmarkState, BenchmarkAction>
    private struct BenchmarkInteractor: Sendable {
        var body: some InteractorOf<Self> {
            Interact { _, _ in }
        }
    }

    @MainActor
    @Suite struct ProjectionReadBenchmarkTests {
        @Test func projectionReadStaysWithinBudgetOfDirectRead() {
            let viewModel = ViewModel(
                initialState: BenchmarkState(),
                feature: Feature(interactor: BenchmarkInteractor())
            )
            let clock = ContinuousClock()
            let readsPerRound = 20_000
            let rounds = 30
            var bestProjected = Duration.seconds(60)
            var bestDirect = Duration.seconds(60)
            var sink = 0

            // The minimum over interleaved rounds filters out scheduling noise; alternating the
            // order removes any first-runner bias.
            for round in 0..<rounds {
                let measureProjected = {
                    let start = clock.now
                    for _ in 0..<readsPerRound { sink &+= viewModel.badge.count }
                    bestProjected = min(bestProjected, clock.now - start)
                }
                let measureDirect = {
                    let start = clock.now
                    for _ in 0..<readsPerRound { sink &+= viewModel.state.badge.count }
                    bestDirect = min(bestDirect, clock.now - start)
                }
                if round.isMultiple(of: 2) {
                    measureProjected()
                    measureDirect()
                } else {
                    measureDirect()
                    measureProjected()
                }
            }

            let ratio = bestProjected / bestDirect
            print(
                """
                [ProjectionReadBenchmark] best of \(rounds) × \(readsPerRound) reads: \
                projection \(bestProjected), direct \(bestDirect), ratio \(ratio)
                """
            )
            #expect(sink == 2 * rounds * readsPerRound)
            #expect(ratio <= 1.2, "projection read costs \(ratio)× a direct read")
        }
    }
#endif
