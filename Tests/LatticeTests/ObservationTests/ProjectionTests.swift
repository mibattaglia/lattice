import CasePaths
import IdentifiedCollections
import Testing

@testable import Lattice

@Suite struct ProjectionTests {
    @Test func projectSelectsTheLeafChildOptionalOrCollectionOverload() {
        let player = PlayerState(id: 1, score: 3)
        #expect(type(of: _$project(1)) == Int.self)
        #expect(type(of: _$project("title")) == String.self)
        #expect(type(of: _$project(["tag"])) == [String].self)
        #expect(type(of: _$project(player)) == PlayerState.ViewState.self)
        #expect(type(of: _$project(Optional(player))) == PlayerState.ViewState?.self)
        #expect(type(of: _$project([player])) == ViewStateCollection<[PlayerState]>.self)
        #expect(
            type(of: _$project(IdentifiedArrayOf<PlayerState>(uniqueElements: [player])))
                == ViewStateCollection<IdentifiedArrayOf<PlayerState>>.self
        )
    }

    @Test func unprojectRestoresEachPayloadKind() {
        let player = PlayerState(id: 1, score: 3)
        #expect(_$unproject(1, to: Int.self) == 1)
        #expect(_$unproject(PlayerState.ViewState(player), to: PlayerState.self) == player)
        #expect(_$unproject(Optional(PlayerState.ViewState(player)), to: PlayerState?.self) == player)
        #expect(_$unproject(PlayerState.ViewState?.none, to: PlayerState?.self) == nil)
        #expect(_$unproject(ViewStateCollection([player]), to: [PlayerState].self) == [player])
    }

    @Test func structViewStateMembersAreTypedByTheirProjection() {
        #expect(ScoreboardState._$ViewStateWitness.title.self == String.self)
        #expect(ScoreboardState._$ViewStateWitness.leader.self == PlayerState.ViewState.self)
        #expect(ScoreboardState._$ViewStateWitness.challenger.self == PlayerState.ViewState?.self)
        #expect(ScoreboardState._$ViewStateWitness.roster.self == ViewStateCollection<[PlayerState]>.self)
        #expect(
            ScoreboardState._$ViewStateWitness.rankedRoster.self
                == ViewStateCollection<IdentifiedArrayOf<PlayerState>>.self
        )
        #expect(ScoreboardState._$ViewStateWitness.tags.self == [String].self)
        #expect(ScoreboardState._$ViewStateWitness.syncText.self == String.self)
        // An inferred-type `@Domain` member keeps its own type for the unavailable stub.
        #expect(PlayerState._$ViewStateWitness.handicap.self == Int.self)
    }

    @Test func structViewStateReadsThroughToTheState() {
        let state = ScoreboardState(
            leader: PlayerState(id: 1, score: 12),
            challenger: PlayerState(id: 2, score: 4),
            roster: [PlayerState(id: 3), PlayerState(id: 4)],
            rankedRoster: [PlayerState(id: 5, score: 9)],
            tags: ["final"]
        )
        let viewState = ScoreboardState.ViewState(state)

        #expect(viewState.title == "Scores")
        #expect(viewState.leader.score == 12)
        // Visible computed member reading a hidden `@Domain` member.
        #expect(viewState.leader.isLeading)
        #expect(viewState.challenger?.score == 4)
        #expect(viewState.roster.map(\.id) == [3, 4])
        #expect(viewState.rankedRoster[id: 5]?.score == 9)
        #expect(viewState.tags == ["final"])
        #expect(viewState.syncText == "Never synced")
        #expect(viewState._state == state)
    }

    @Test func enumViewStateRoundTripsEveryPayloadKind() {
        let player = PlayerState(id: 7, score: 2)
        let phases: [MatchPhase] = [
            .waiting,
            .playing(player),
            .finished(winner: "Ada", rounds: 3),
            .overtime(nil),
            .overtime(player),
            .shootout([player, PlayerState(id: 8)], "sudden death"),
        ]
        for phase in phases {
            #expect(MatchPhase.ViewState(phase)._state == phase)
        }
    }

    @Test func enumViewStateProjectsPayloads() throws {
        let player = PlayerState(id: 7, score: 2)

        let playing = try #require(MatchPhase.ViewState(.playing(player))[case: \.playing])
        #expect(type(of: playing) == PlayerState.ViewState.self)
        #expect(playing.score == 2)

        let finished = try #require(MatchPhase.ViewState(.finished(winner: "Ada", rounds: 3))[case: \.finished])
        #expect(finished.winner == "Ada")
        #expect(finished.rounds == 3)

        let overtime = try #require(MatchPhase.ViewState(.overtime(player))[case: \.overtime])
        #expect(type(of: overtime) == PlayerState.ViewState?.self)

        let shootout = try #require(MatchPhase.ViewState(.shootout([player], "sudden death"))[case: \.shootout])
        #expect(type(of: shootout.0) == ViewStateCollection<[PlayerState]>.self)
        #expect(shootout.1 == "sudden death")

        #expect(MatchPhase.ViewState(.waiting).isWaiting)
        #expect(!MatchPhase.ViewState(.playing(player)).isWaiting)
    }

    @Test func casePathableStateGivesTheMirrorCasePaths() {
        let player = PlayerState(id: 7, score: 2)
        let playing = MatchPhase.ViewState(.playing(player))

        #expect(playing.is(\.playing))
        #expect(!playing.is(\.waiting))
        switch playing {
        case \.playing: break
        default: Issue.record("Expected `~=` to match the active case")
        }

        let embedded = (\MatchPhase.ViewState.Cases.finished)((winner: "Ada", rounds: 3))
        #expect(embedded == MatchPhase.ViewState(.finished(winner: "Ada", rounds: 3)))
        #expect((\MatchPhase.ViewState.Cases.waiting)(()) == MatchPhase.ViewState(.waiting))

        var modified = playing
        modified.modify(\.playing) { $0 = PlayerState.ViewState(PlayerState(id: 7, score: 5)) }
        #expect(modified[case: \.playing]?.score == 5)

        #expect(MatchPhase.ViewState.allCasePaths[playing] == \MatchPhase.ViewState.Cases.playing)
        #expect(Array(MatchPhase.ViewState.allCasePaths).count == Array(MatchPhase.allCasePaths).count)
    }

    @Test func indirectEnumViewStateRoundTrips() {
        let bracket = BracketState.match(.seed(1), .match(.seed(2), .seed(3)))
        let viewState = BracketState.ViewState(bracket)
        #expect(viewState._state == bracket)

        guard case .match(.seed(let first), .match(.seed(let second), .seed(let third))) = viewState
        else {
            Issue.record("Expected the mirror to keep the bracket shape, got \(viewState)")
            return
        }
        #expect([first, second, third] == [1, 2, 3])
    }
}
