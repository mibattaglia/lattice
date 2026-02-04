// Compile time tests here only to make sure type inference works.
// Inspired by tests in https://github.com/pointfreeco/swift-composable-architecture/blob/main/Tests/ComposableArchitectureTests/ReducerBuilderTests.swift
import Combine
import Foundation
import Testing

@testable import Lattice

private struct MyState: Sendable {}
private enum MyAction: Sendable { case myAction }

private struct TestInteractor: Interactor, Sendable {
    var body: some Interactor<MyAction, MyState> {
        EmptyInteractor()
    }
}

@available(iOS, introduced: 9999)
@available(macOS, introduced: 9999)
@available(tvOS, introduced: 9999)
@available(visionOS, introduced: 9999)
@available(watchOS, introduced: 9999)
private struct UnavailableInteractor: Interactor, Sendable {
    var body: some Interactor<MyAction, MyState> {
        EmptyInteractor()
    }
}

func limitedAvailability() {
    _ = Interactors.CollectInteractors {
        TestInteractor()
        if #available(iOS 9999, macOS 9999, tvOS 9999, visionOS 9999, watchOS 9999, *) {
            UnavailableInteractor()
        }

        if #available(iOS 8888, macOS 8888, tvOS 8888, visionOS 8888, watchOS 8888, *) {
            EmptyInteractor<MyAction, MyState>()
        }
    }
}

func controlFlow() {
    _ = Interactors.CollectInteractors {
        if Bool.random() {
            TestInteractor()
        }

        TestInteractor()

        for _ in 0...10 {
            EmptyInteractor<MyAction, MyState>()
        }
    }
}

func existentials() {
    _ = Interactors.CollectInteractors {
        TestInteractor()
        TestInteractor() as any InteractorOf<TestInteractor>
    }
}
