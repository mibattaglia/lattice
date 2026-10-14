import Foundation
import Testing

@testable import Lattice

/// Declares `Identifiable` (and its `id`) outside the type body, as conformances in other files do.
@FeatureState
private struct ExtensionIdentifiedState: Equatable {
    var number = 1
}

extension ExtensionIdentifiedState: Identifiable {
    var id: Int { number }
}

/// Lists `Identifiable` but implements `id` in an extension, so `id` is not a forwarded member.
@FeatureState
private struct ListedIdentifiableState: Identifiable {
    var number = 3
}

extension ListedIdentifiableState {
    var id: String { "row-\(number)" }
}

/// Neither `Equatable` nor `Identifiable`.
@FeatureState
private struct PlainState {
    var value = 1
}

/// The common nested naming: a namespace with a nested `State`.
private enum Scoreboard {
    @FeatureState
    struct State: Equatable {
        var round = 1
        var leader = PlayerState(id: 1)
    }
}

private func identifierType<T: Identifiable>(of _: T) -> ObjectIdentifier { ObjectIdentifier(T.ID.self) }

@Suite struct ViewStateProjectionTests {
    @Test func identifiableStateWithVisibleIDProjectsIdentifiable() {
        let viewState = PlayerState.ViewState(PlayerState(id: 4))
        #expect(identifierType(of: viewState) == ObjectIdentifier(Int.self))
        #expect(viewState.id == 4)
    }

    @Test func identifiableStateWithExtensionIDProjectsIdentifiable() {
        let viewState = ExtensionIdentifiedState.ViewState(ExtensionIdentifiedState(number: 9))
        #expect(ExtensionIdentifiedState.ViewState.ID.self == Int.self)
        #expect(identifierType(of: viewState) == ObjectIdentifier(Int.self))
        #expect(viewState.id == 9)

        let listed = ListedIdentifiableState.ViewState(ListedIdentifiableState(number: 4))
        #expect(identifierType(of: listed) == ObjectIdentifier(String.self))
        #expect(listed.id == "row-4")
    }

    @Test func equatableStateProjectsEquatableComparingTheState() {
        let first = ScoreboardState(title: "A")
        #expect(ScoreboardState.ViewState(first) == ScoreboardState.ViewState(ScoreboardState(title: "A")))
        #expect(ScoreboardState.ViewState(first) != ScoreboardState.ViewState(ScoreboardState(title: "B")))
        #expect(MatchPhase.ViewState(.waiting) == MatchPhase.ViewState(.waiting))
        #expect(MatchPhase.ViewState(.waiting) != MatchPhase.ViewState(.playing(PlayerState(id: 1))))
    }

    @Test func stateWithoutConformancesProjectsNeither() {
        let viewState: Any = PlainState.ViewState(PlainState())
        #expect(!(viewState is any Equatable))
        #expect(!(viewState is any Identifiable))
    }

    @Test func sendableStateProjectsSendable() {
        let viewState: any Sendable = ScoreboardState.ViewState(ScoreboardState())
        #expect(viewState is ScoreboardState.ViewState)
    }

    @Test func nestedStateNamedStateProjects() {
        let viewState = Scoreboard.State.ViewState(Scoreboard.State(round: 2))
        #expect(viewState.round == 2)
        #expect(viewState.leader.id == 1)
        #expect(viewState._state == Scoreboard.State(round: 2))
    }
}
