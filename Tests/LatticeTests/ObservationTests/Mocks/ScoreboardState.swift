import Foundation
import IdentifiedCollections
import Lattice

@FeatureState
struct PlayerState: Equatable, Identifiable, Sendable {
    let id: Int
    var score = 0
    @Domain var handicap = 10
    var isLeading: Bool { score > handicap }
}

@FeatureState
struct ScoreboardState: Equatable, Sendable {
    var title = "Scores"
    @Domain var lastSyncedAt: Date?
    var leader = PlayerState(id: 0)
    var challenger: PlayerState?
    var roster: [PlayerState] = []
    var rankedRoster: IdentifiedArrayOf<PlayerState> = []
    var tags: [String] = []
    var syncText: String { lastSyncedAt == nil ? "Never synced" : "Synced" }
}
