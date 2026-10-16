import CasePaths
import Foundation
import Lattice

// The feature the test model suites drive: one action per shape of commit a test shell has to
// handle. Declared at file scope, so the interactor and its effect literals are nonisolated, as
// `TestModel` requires.

@FeatureState
struct LoadState: Equatable, Sendable {
    var count = 0
    var isLoading = false
    var note = ""
    var values: [Int] = []
    /// The `remaining` of every `.chain` effect, in the order they ran.
    var chained: [Int] = []
}

@CasePathable
enum LoadAction: Equatable, Sendable {
    case increment
    /// Counts, and its effect sends `.loaded(41)` from its preamble: pending when `send` returns.
    case load
    case loaded(Int)
    /// Its effect sends `.loaded(41)` after a `Task.yield()`.
    case loadAfterYield
    /// Its effect sends `.loaded(41)` after sleeping for the duration.
    case loadAfterSleep(Duration)
    /// Its effect sends `.step(1)` and `.step(2)` from its preamble.
    case startSequence
    case step(Int)
    /// Notes, and its effect's preamble modifies `count`: committed inside `send`.
    case preamble
    /// Its effect modifies `count`, then `note`, after a `Task.yield()`.
    case fetch
    /// After a `Task.yield()`, its effect modifies, sends `.loaded(41)` and modifies again.
    case surround
    /// From its preamble, its effect modifies, sends `.loaded(1)` and modifies again.
    case interleave
    /// Its effect makes a modification that changes nothing, after a `Task.yield()`.
    case noop
    /// Its effect sleeps until it is cancelled.
    case hang
    /// Its effect sleeps until it is cancelled, then sends `.hang`, which starts another one.
    case hangThenHangAgainWhenCancelled
    /// After a `Task.yield()`, its effect appends `remaining` to `chained` and sends
    /// `.chain(remaining - 1)` while `remaining > 0`.
    case chain(Int)
    /// Starts loading; its effect waits on the gate, then counts, and clears `isLoading` in a
    /// `defer`, cancelled or not.
    case gated
    /// Its effect waits on the gate, ignoring cancellation: it stays in flight until the gate
    /// opens.
    case gatedIgnoringCancellation
    /// Its effect waits on the gate, then sends `.loaded(41)`.
    case gatedLoad
    /// Its effect waits on the gate, then sends `.loaded(41)` and cancels `waiter` in the same
    /// job: the waiting task is cancelled just as the commit it waits for lands.
    case gatedLoadCancellingWaiter
    /// After a `Task.yield()`, its effect modifies twice, then sends `.step(7)`.
    case modifyTwiceThenSend
}

/// A task the test hands an effect to cancel. Locked: the test sets it, and the effect cancels it on
/// the model's executor.
final class LockedTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }
}

@Interactor<LoadState, LoadAction>
struct LoadInteractor {
    var gate = Gate()
    var waiter = LockedTaskBox()
    /// Only for sleeps that end by cancellation: the tests never advance it.
    var clock = EffectClock()

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .increment:
                state.count += 1

            case .load:
                state.count += 1
                effects.perform { try effects.send(.loaded(41)) }

            case .loaded(let value):
                state.count += value

            case .loadAfterYield:
                effects.perform {
                    await Task.yield()
                    try effects.send(.loaded(41))
                }

            case .loadAfterSleep(let duration):
                effects.perform {
                    try await Task.sleep(for: duration)
                    try effects.send(.loaded(41))
                }

            case .startSequence:
                effects.perform {
                    try effects.send(.step(1))
                    try effects.send(.step(2))
                }

            case .step(let value):
                state.values.append(value)

            case .preamble:
                state.note = "go"
                effects.perform { try effects.modify { $0.count += 10 } }

            case .fetch:
                effects.perform {
                    await Task.yield()
                    try effects.modify { $0.count = 5 }
                    try effects.modify { $0.note = "x" }
                }

            case .surround:
                effects.perform {
                    await Task.yield()
                    try effects.modify { $0.isLoading = true }
                    try effects.send(.loaded(41))
                    try effects.modify { $0.note = "done" }
                }

            case .interleave:
                effects.perform {
                    try effects.modify { $0.note = "a" }
                    try effects.send(.loaded(1))
                    try effects.modify { $0.isLoading = true }
                }

            case .noop:
                effects.perform {
                    await Task.yield()
                    try effects.modify { $0.count = $0.count }
                }

            case .hang:
                effects.perform {
                    try await clock.sleep(for: .seconds(1_000))
                }

            case .hangThenHangAgainWhenCancelled:
                effects.perform {
                    do {
                        try await clock.sleep(for: .seconds(1_000))
                    } catch {
                        try effects.send(.hang)
                    }
                }

            case .chain(let remaining):
                effects.perform {
                    await Task.yield()
                    try effects.modify { $0.chained.append(remaining) }
                    if remaining > 0 {
                        try effects.send(.chain(remaining - 1))
                    }
                }

            case .gated:
                state.isLoading = true
                effects.perform {
                    defer { try? effects.modify { $0.isLoading = false } }
                    try await gate.pass()
                    try effects.modify { $0.count = 100 }
                }

            case .gatedIgnoringCancellation:
                effects.perform { await gate.wait() }

            case .gatedLoad:
                effects.perform {
                    try await gate.pass()
                    try effects.send(.loaded(41))
                }

            case .gatedLoadCancellingWaiter:
                effects.perform {
                    try await gate.pass()
                    try effects.send(.loaded(41))
                    waiter.cancel()
                }

            case .modifyTwiceThenSend:
                effects.perform {
                    await Task.yield()
                    try effects.modify { $0.count = 7 }
                    try effects.modify { $0.note = "seven" }
                    try effects.send(.step(7))
                }
            }
        }
    }
}

/// A test model over ``LoadInteractor``. It forwards the caller's location, so the reports the
/// model makes at its creation point at the test. Its default timeout is generous: the tests that
/// expect a wait to time out pass their own.
@available(iOS 26, macOS 26, watchOS 26, *)
func makeLoadModel(
    _ interactor: LoadInteractor = LoadInteractor(),
    exhaustivity: Exhaustivity = .on,
    timeout: Duration = .seconds(10),
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> TestModel<Feature<LoadAction, LoadState>> {
    await TestModel(
        initialState: LoadState(),
        feature: Feature(interactor: interactor),
        exhaustivity: exhaustivity,
        timeout: timeout,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}
