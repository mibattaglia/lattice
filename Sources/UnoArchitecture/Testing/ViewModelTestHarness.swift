@preconcurrency import Combine
import Foundation

/// A test harness that simplifies ViewModel testing by recording viewState changes.
@MainActor
public final class ViewModelTestHarness<Action: Sendable, DomainState: Sendable, ViewState: Sendable> {

    public let viewModel: ViewModel<Action, DomainState, ViewState>

    public private(set) var states: [ViewState] = []
    private var cancellable: AnyCancellable?

    public init(
        interactor: AnyInteractor<DomainState, Action>,
        viewStateReducer: AnyViewStateReducer<DomainState, ViewState>,
        initialViewState: @autoclosure () -> ViewState
    ) {
        self.viewModel = ViewModel(
            initialValue: initialViewState(),
            interactor,
            viewStateReducer
        )
        self.setupObservation()
    }

    public convenience init(
        interactor: AnyInteractor<ViewState, Action>,
        initialState: @autoclosure () -> ViewState
    ) where DomainState == ViewState {
        let viewModel = ViewModel(initialState(), interactor)
        self.init(wrapping: viewModel)
    }

    private init(wrapping viewModel: ViewModel<Action, ViewState, ViewState>) where DomainState == ViewState {
        self.viewModel = viewModel
        self.setupObservation()
    }

    private func setupObservation() {
        self.cancellable = viewModel.$viewState
            .sink { [weak self] state in
                self?.states.append(state)
            }
    }

    public func send(_ action: Action) {
        viewModel.sendViewEvent(action)
    }

    public func send(_ actions: Action...) {
        for action in actions {
            viewModel.sendViewEvent(action)
        }
    }

    public var latestState: ViewState? {
        states.last
    }

    private var waitCancellable: AnyCancellable?

    /// Waits for states using Combine timeout.
    public func waitForStates(count: Int, timeout: Duration = .seconds(5)) async throws {
        if states.count >= count { return }

        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false

            self.waitCancellable = viewModel.$viewState
                .dropFirst(states.count)
                .prefix(count - states.count)
                .setFailureType(to: TimeoutError.self)
                .timeout(.seconds(timeoutSeconds), scheduler: DispatchQueue.main) { TimeoutError() }
                .sink(
                    receiveCompletion: { [weak self] result in
                        guard !completed else { return }
                        completed = true
                        self?.waitCancellable = nil
                        switch result {
                        case .finished:
                            continuation.resume()
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    },
                    receiveValue: { _ in }
                )
        }
    }

    public func assertStates(
        _ expected: [ViewState],
        timeout: Duration = .seconds(5)
    ) async throws where ViewState: Equatable {
        try await waitForStates(count: expected.count, timeout: timeout)

        guard states.prefix(expected.count) == expected[...] else {
            throw AssertionError(
                expected: expected,
                actual: Array(states.prefix(expected.count))
            )
        }
    }

    public struct AssertionError: Error, CustomStringConvertible {
        public let expected: [ViewState]
        public let actual: [ViewState]
        public var description: String {
            "States mismatch.\nExpected: \(expected)\nActual: \(actual)"
        }
    }

    public struct TimeoutError: Error, CustomStringConvertible {
        public var description: String { "Timed out waiting for states" }
    }

    deinit {
        cancellable?.cancel()
    }
}
