import Foundation

/// A type that can provide a default value for itself.
public protocol DefaultValueProvider {
    static var defaultValue: Self { get }
}
