import Combine
import CombineSchedulers
import Foundation

/// A builder that assembles the moving parts required to construct a ``ViewModel``.
///
/// Used internally by the ``@ViewModel`` macro.
public final class ViewModelBuilder<DomainEvent: Sendable, DomainState: Sendable, ViewState>: @unchecked Sendable {
    private var _viewEventsReceiver: AnySchedulerOf<DispatchQueue> = .main
    private var _viewStateReceiver: AnySchedulerOf<DispatchQueue> = .main
    private var _interactor: AnyInteractor<DomainState, DomainEvent>?
    private var _viewStateReducer: AnyViewStateReducer<DomainState, ViewState>?

    public init() {}

    @discardableResult
    public func viewEventReceiver(_ scheduler: AnySchedulerOf<DispatchQueue>) -> Self {
        self._viewEventsReceiver = scheduler
        return self
    }

    @discardableResult
    public func viewStateReceiver(_ scheduler: AnySchedulerOf<DispatchQueue>) -> Self {
        self._viewStateReceiver = scheduler
        return self
    }

    @discardableResult
    public func interactor(_ interactor: AnyInteractor<DomainState, DomainEvent>) -> Self {
        self._interactor = interactor
        return self
    }

    @discardableResult
    public func viewStateReducer(
        _ viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    ) -> Self {
        self._viewStateReducer = viewStateReducer
        return self
    }

    func build() throws -> ViewModelConfiguration<DomainEvent, DomainState, ViewState> {
        guard let _interactor else {
            throw ViewModelBuilderError.missingInteractor
        }

        return ViewModelConfiguration(
            viewEventsReceiver: _viewEventsReceiver,
            viewStateReceiver: _viewStateReceiver,
            interactor: _interactor,
            viewStateReducer: _viewStateReducer
        )
    }
}

/// The concrete configuration produced by ``ViewModelBuilder/build()``.
public struct ViewModelConfiguration<DomainEvent: Sendable, DomainState: Sendable, ViewState> {
    let viewEventsReceiver: AnySchedulerOf<DispatchQueue>
    let viewStateReceiver: AnySchedulerOf<DispatchQueue>
    let interactor: AnyInteractor<DomainState, DomainEvent>
    let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>?
}

public enum ViewModelBuilderError: Error {
    /// Thrown when `interactor(_:)` has not been called before `build()`.
    case missingInteractor
}
