import CasePaths
import Foundation
import SwiftUI

extension ViewModel {
    @MainActor
    public func binding<Value>(
        get: @escaping (_ state: ViewStateType) -> Value,
        send valueToAction: @escaping (_ value: Value) -> ViewEventType
    ) -> Binding<Value> {
        ObservedObject(wrappedValue: self)
            .projectedValue[get: IgnoreHashable(get), send: IgnoreHashable(valueToAction)]
    }

    private subscript<Value>(
        get state: IgnoreHashable<(ViewStateType) -> Value>,
        send event: IgnoreHashable<(Value) -> ViewEventType?>
    ) -> Value {
        get {
            state.wrappedValue(viewState)
        }
        set {
            if let eventToSend = event.wrappedValue(newValue) {
                sendViewEvent(eventToSend)
            }
        }
    }
}
