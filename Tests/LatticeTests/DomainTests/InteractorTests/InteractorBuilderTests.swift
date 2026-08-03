// Compile-shape tests to make sure builder type inference works, plus runtime routing
// assertions (plan 04 test suite 3) and the headline non-Sendable erasure test (suite 4).
// Inspired by tests in https://github.com/pointfreeco/swift-composable-architecture/blob/main/Tests/ComposableArchitectureTests/ReducerBuilderTests.swift
import Foundation
import Testing

@testable import Lattice

private struct MyState {}
private enum MyAction { case myAction }

private struct TestInteractor: Interactor {
    var body: some Interactor<MyState, MyAction> {
        EmptyInteractor()
    }
}

@available(iOS, introduced: 9999)
@available(macOS, introduced: 9999)
@available(tvOS, introduced: 9999)
@available(visionOS, introduced: 9999)
@available(watchOS, introduced: 9999)
private struct UnavailableInteractor: Interactor {
    var body: some Interactor<MyState, MyAction> {
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
            EmptyInteractor<MyState, MyAction>()
        }
    }
}

func existentials() {
    _ = Interactors.CollectInteractors {
        TestInteractor()
        TestInteractor() as any InteractorOf<TestInteractor>
    }
}

// MARK: - Runtime routing

/// A leaf that appends its tag to the shared log on every routed action.
private struct RecordingInteractor: Interactor {
    let tag: String
    let log: Log

    final class Log {
        var entries: [String] = []
    }

    var body: some Interactor<MyState, MyAction> {
        Interact { [tag, log] (_: inout MyState, _: MyAction) in
            log.entries.append(tag)
        }
    }
}

@Suite
@MainActor
struct InteractorBuilderRoutingTests {

    @Test
    func everyBuilderShapeForwardsToAllLiveChildren() {
        let log = RecordingInteractor.Log()
        let flag = true

        let root = Interactors.CollectInteractors<MyState, MyAction, _> {
            RecordingInteractor(tag: "a", log: log)
            RecordingInteractor(tag: "b", log: log)
            if flag {
                RecordingInteractor(tag: "if", log: log)
            }
            if flag {
                RecordingInteractor(tag: "either-first", log: log)
            } else {
                RecordingInteractor(tag: "either-second", log: log)
            }
            for tag in ["array-0", "array-1"] {
                RecordingInteractor(tag: tag, log: log)
            }
            RecordingInteractor(tag: "any", log: log) as any Interactor<MyState, MyAction>
        }

        var state = MyState()
        root.interact(
            state: &state,
            action: .myAction,
            effects: _detachedEffectsHandle(path: GraphPath())
        )

        #expect(log.entries == ["a", "b", "if", "either-first", "array-0", "array-1", "any"])
    }
}

// MARK: - Non-Sendable erasure (plan 04 suite 4, the headline)

/// A deliberately non-Sendable service: mutable reference state, no locks, no conformances.
private final class NonSendableService {
    var fetchCount = 0

    func fetch() -> Int {
        fetchCount += 1
        return fetchCount
    }
}

private struct NonSendableState {
    var service = NonSendableService()
    var value = 0
}

private enum NonSendableAction { case fetch }

/// An interactor holding a non-Sendable class reference. Composes, erases via
/// `eraseToAnyInteractor()`, and runs — with zero `@unchecked` or `nonisolated(unsafe)`
/// anywhere in this file.
private struct NonSendableInteractor: Interactor {
    let service: NonSendableService

    var body: some Interactor<NonSendableState, NonSendableAction> {
        Interact { [service] state, action in
            switch action {
            case .fetch:
                state.value = service.fetch()
            }
        }
    }
}

@Suite
@MainActor
struct NonSendableErasureTests {

    @Test
    func nonSendableInteractorComposesErasesAndRuns() {
        let service = NonSendableService()
        let erased: AnyInteractor<NonSendableState, NonSendableAction> =
            Interactors.CollectInteractors {
                NonSendableInteractor(service: service)
            }
            .eraseToAnyInteractor()

        var state = NonSendableState()
        erased.interact(
            state: &state,
            action: .fetch,
            effects: _detachedEffectsHandle(path: GraphPath())
        )
        #expect(state.value == 1)
        #expect(service.fetchCount == 1)
    }
}
