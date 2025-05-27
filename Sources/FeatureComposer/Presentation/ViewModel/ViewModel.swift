import Combine
import SwiftUI

public protocol ViewModel: ObservableObject {
    associatedtype ViewEventType
    associatedtype ViewStateType

    var viewState: ViewStateType { get }

    func sendViewEvent(_ event: ViewEventType)
}

public final class AnyViewModel<ViewEvent, ViewState>: ViewModel {
    public var viewState: ViewState {
        viewStateGetter()
    }
    private let viewStateGetter: () -> ViewState
    private let viewEventSender: (ViewEvent) -> Void
    private var cancellable: AnyCancellable?

    public init<VM: ViewModel>(_ base: VM) where VM.ViewEventType == ViewEvent, VM.ViewStateType == ViewState {
        self.viewEventSender = base.sendViewEvent(_:)
        self.viewStateGetter = { [weak base] in
            guard let base else {
                fatalError(
                    """
                    Underlying ViewModel with types '\(ViewEvent.self)', '\(ViewState.self)' has been deallocated.
                    """
                )
            }
            return base.viewState
        }
        self.cancellable = base
            .objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    public func sendViewEvent(_ event: ViewEvent) {
        viewEventSender(event)
    }
}

extension ViewModel {
    public func erased() -> AnyViewModel<ViewEventType, ViewStateType> {
        AnyViewModel(self)
    }
}
