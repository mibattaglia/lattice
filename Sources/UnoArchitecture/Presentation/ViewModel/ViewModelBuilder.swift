import Combine
import CombineSchedulers
import Foundation

public final class ViewModelBuilder<DomainEvent, DomainState, ViewState>: @unchecked Sendable {
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

public struct ViewModelConfiguration<DomainEvent, DomainState, ViewState> {
    let viewEventsReceiver: AnySchedulerOf<DispatchQueue>
    let viewStateReceiver: AnySchedulerOf<DispatchQueue>
    let interactor: AnyInteractor<DomainState, DomainEvent>
    let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>?
}

public enum ViewModelBuilderError: Error {
    case missingInteractor
}
