import Foundation

/// A builder that assembles the moving parts required to construct a ``ViewModel``.
///
/// Used internally by the ``@ViewModel`` macro.
public final class ViewModelBuilder<DomainEvent: Sendable, DomainState: Sendable, ViewState>: @unchecked Sendable {
    private var _interactor: AnyInteractor<DomainState, DomainEvent>?
    private var _viewStateReducer: AnyViewStateReducer<DomainState, ViewState>?

    public init() {}

    @discardableResult
    public func interactor(_ interactor: AnyInteractor<DomainState, DomainEvent>) -> Self {
        self._interactor = interactor
        return self
    }

    @discardableResult
    public func viewStateReducer(_ viewStateReducer: AnyViewStateReducer<DomainState, ViewState>) -> Self {
        self._viewStateReducer = viewStateReducer
        return self
    }

    func build() throws -> ViewModelConfiguration<DomainEvent, DomainState, ViewState> {
        guard let _interactor else {
            throw ViewModelBuilderError.missingInteractor
        }
        return ViewModelConfiguration(interactor: _interactor, viewStateReducer: _viewStateReducer)
    }
}

/// The concrete configuration produced by ``ViewModelBuilder/build()``.
public struct ViewModelConfiguration<DomainEvent: Sendable, DomainState: Sendable, ViewState> {
    let interactor: AnyInteractor<DomainState, DomainEvent>
    let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>?
}

public enum ViewModelBuilderError: Error {
    /// Thrown when `interactor(_:)` has not been called before `build()`.
    case missingInteractor
}
