import Foundation

@propertyWrapper
struct IgnoreHashable<Value>: Hashable {
    private(set) var wrappedValue: Value

    init(_ wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}
