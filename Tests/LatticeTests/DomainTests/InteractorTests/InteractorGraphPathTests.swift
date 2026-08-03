// Path derivation through the imperative-effect pathway.
// A recording leaf captures the `Effects` handle path at every structural position.

import CasePaths
import Foundation
import Testing

@testable import Lattice

// MARK: - Fixtures

private struct PathChildState: Equatable, Sendable {
    var value = 0
}

private struct PathRootState: Sendable {
    var counter = PathChildState()
    var other = PathChildState()
}

private enum PathChildAction: Sendable {
    case probe
}

@CasePathable
private enum PathRootAction: Sendable {
    case probe
    case counter(PathChildAction)
    case other(PathChildAction)
}

@CasePathable
private enum PathEnumState: Sendable {
    case loaded(PathChildState)
    case idle
}

@CasePathable
private enum PathEnumAction: Sendable {
    case loaded(PathChildAction)
}

/// Collects the `Effects` handle paths observed by recording leaves. `@unchecked Sendable`
/// is a formality: all touches happen on the MainActor.
private final class PathRecorder: @unchecked Sendable {
    private(set) var paths: [String: GraphPath] = [:]

    func record(_ label: String, _ path: GraphPath) {
        paths[label] = path
    }
}

/// A leaf that records the path of the handle it receives. Structurally an `Interact` leaf
/// behind a `body`, so it also exercises the default body-forwarding `interact` witness.
private struct RecordingLeaf<State: Sendable, Action: Sendable>: Interactor {
    let label: String
    let recorder: PathRecorder

    var body: some Interactor<State, Action> {
        Interact { (_: inout State, _: Action, effects: Effects<State, Action>) in
            self.recorder.record(self.label, effects.path)
        }
    }
}

private typealias RootLeaf = RecordingLeaf<PathRootState, PathRootAction>
private typealias ChildLeaf = RecordingLeaf<PathChildState, PathChildAction>

private func collect<I: Interactor>(
    @InteractorBuilder<PathRootState, PathRootAction> _ build: () -> I
) -> I where I.DomainState == PathRootState, I.Action == PathRootAction {
    build()
}

private func rootHandle() -> Effects<PathRootState, PathRootAction> {
    _detachedEffectsHandle(path: GraphPath())
}

// MARK: - Tests

@Suite
@MainActor
struct InteractorGraphPathTests {

    @Test
    func mergePairAppendsPositionalComponents() {
        let recorder = PathRecorder()
        let merged = Interactors.Merge(
            RootLeaf(label: "a", recorder: recorder),
            RootLeaf(label: "b", recorder: recorder)
        )

        var state = PathRootState()
        merged.interact(state: &state, action: .probe, effects: rootHandle())

        #expect(recorder.paths["a"] == GraphPath().appending(id: 0))
        #expect(recorder.paths["b"] == GraphPath().appending(id: 1))
    }

    @Test
    func nestedMergeFromThreeSiblingBuilderBlock() {
        let recorder = PathRecorder()
        // Three siblings nest as Merge(Merge(A, B), C) via buildPartialBlock.
        let tree = collect {
            RootLeaf(label: "a", recorder: recorder)
            RootLeaf(label: "b", recorder: recorder)
            RootLeaf(label: "c", recorder: recorder)
        }

        var state = PathRootState()
        tree.interact(state: &state, action: .probe, effects: rootHandle())

        #expect(recorder.paths["a"] == GraphPath().appending(id: 0).appending(id: 0))
        #expect(recorder.paths["b"] == GraphPath().appending(id: 0).appending(id: 1))
        #expect(recorder.paths["c"] == GraphPath().appending(id: 1))
    }

    @Test
    func mergeManyAppendsIndices() {
        let recorder = PathRecorder()
        let merged = Interactors.MergeMany(interactors: [
            RootLeaf(label: "a", recorder: recorder),
            RootLeaf(label: "b", recorder: recorder),
            RootLeaf(label: "c", recorder: recorder),
        ])

        var state = PathRootState()
        merged.interact(state: &state, action: .probe, effects: rootHandle())

        #expect(recorder.paths["a"] == GraphPath().appending(id: 0))
        #expect(recorder.paths["b"] == GraphPath().appending(id: 1))
        #expect(recorder.paths["c"] == GraphPath().appending(id: 2))
    }

    @Test
    func conditionalBranchesAppendDistinctBranchTags() {
        let recorder = PathRecorder()
        let first = Interactors.Conditional<RootLeaf, RootLeaf>.first(
            RootLeaf(label: "first", recorder: recorder)
        )
        let second = Interactors.Conditional<RootLeaf, RootLeaf>.second(
            RootLeaf(label: "second", recorder: recorder)
        )

        var state = PathRootState()
        first.interact(state: &state, action: .probe, effects: rootHandle())
        second.interact(state: &state, action: .probe, effects: rootHandle())

        #expect(recorder.paths["first"] == GraphPath().appending(id: ConditionalBranch.first))
        #expect(recorder.paths["second"] == GraphPath().appending(id: ConditionalBranch.second))
        #expect(recorder.paths["first"] != recorder.paths["second"])
    }

    @Test
    func buildEitherBranchesAtTheSamePositionAreDisjoint() {
        let recorder = PathRecorder()
        func tree(_ flag: Bool) -> some Interactor<PathRootState, PathRootAction> {
            collect {
                if flag {
                    RootLeaf(label: "then", recorder: recorder)
                } else {
                    RootLeaf(label: "else", recorder: recorder)
                }
            }
        }

        var state = PathRootState()
        tree(true).interact(state: &state, action: .probe, effects: rootHandle())
        tree(false).interact(state: &state, action: .probe, effects: rootHandle())

        let thenPath = try? #require(recorder.paths["then"])
        let elsePath = try? #require(recorder.paths["else"])
        #expect(thenPath != elsePath)
    }

    @Test
    func whenKeyPathAppendsTheStateKeyPath() {
        let recorder = PathRecorder()
        let when = Interactors.When<PathRootState, PathRootAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            ChildLeaf(label: "child", recorder: recorder)
        }

        var state = PathRootState()
        when.interact(state: &state, action: .counter(.probe), effects: rootHandle())

        #expect(recorder.paths["child"] == GraphPath().appending(\PathRootState.counter))
    }

    @Test
    func whenCasePathAppendsTheCaseKeyPath() {
        let recorder = PathRecorder()
        let when = Interactors.When<PathEnumState, PathEnumAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            ChildLeaf(label: "child", recorder: recorder)
        }

        var state = PathEnumState.loaded(PathChildState())
        when.interact(
            state: &state,
            action: .loaded(.probe),
            effects: _detachedEffectsHandle(path: GraphPath())
        )

        #expect(recorder.paths["child"] == GraphPath().appending(\PathEnumState.Cases.loaded))
    }

    @Test
    func twoWhensOverDifferentLensesProduceDistinctPaths() {
        let recorder = PathRecorder()
        let counterWhen = Interactors.When<PathRootState, PathRootAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            ChildLeaf(label: "counter", recorder: recorder)
        }
        let otherWhen = Interactors.When<PathRootState, PathRootAction, _>(
            state: \.other,
            action: \.other
        ) {
            ChildLeaf(label: "other", recorder: recorder)
        }

        var state = PathRootState()
        counterWhen.interact(state: &state, action: .counter(.probe), effects: rootHandle())
        otherWhen.interact(state: &state, action: .other(.probe), effects: rootHandle())

        #expect(recorder.paths["counter"] != recorder.paths["other"])
    }

    @Test
    func whenComponentPrecedesTheChildBodyComponents() {
        let recorder = PathRecorder()
        let when = Interactors.When<PathRootState, PathRootAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            ChildLeaf(label: "a", recorder: recorder)
            ChildLeaf(label: "b", recorder: recorder)
        }

        var state = PathRootState()
        when.interact(state: &state, action: .counter(.probe), effects: rootHandle())

        let base = GraphPath().appending(\PathRootState.counter)
        #expect(recorder.paths["a"] == base.appending(id: 0))
        #expect(recorder.paths["b"] == base.appending(id: 1))
    }

    @Test
    func erasureAndWrappersAreStructurallyTransparent() {
        let recorder = PathRecorder()

        // AnyInteractor.
        let erased = RootLeaf(label: "erased", recorder: recorder).eraseToAnyInteractor()
        var state = PathRootState()
        erased.interact(state: &state, action: .probe, effects: rootHandle())
        #expect(recorder.paths["erased"] == GraphPath())

        // CollectInteractors.
        let collected = Interactors.CollectInteractors<PathRootState, PathRootAction, _> {
            RootLeaf(label: "collected", recorder: recorder)
        }
        collected.interact(state: &state, action: .probe, effects: rootHandle())
        #expect(recorder.paths["collected"] == GraphPath())

        // buildOptional (`if` without `else`) wraps in AnyInteractor; path unchanged.
        let include = true
        let optional = collect {
            if include {
                RootLeaf(label: "optional", recorder: recorder)
            }
        }
        optional.interact(state: &state, action: .probe, effects: rootHandle())
        #expect(recorder.paths["optional"] == GraphPath())
    }
}
