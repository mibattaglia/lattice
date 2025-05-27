import Combine
import Foundation

@dynamicMemberLookup
public struct DynamicState<State> {
    private let stream: CurrentValueSubject<State, Never>

    init(stream: CurrentValueSubject<State, Never>) {
        self.stream = stream
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<State, T>) -> T {
        stream.value[keyPath: keyPath]
    }
}
