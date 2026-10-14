import Foundation
import Lattice

@FeatureState
struct SuccessState: Equatable, Sendable {
    var title: String = "Success"
    var summary: SummaryState = SummaryState()
    var session: SessionState = SessionState()
}

@FeatureState
struct SummaryState: Equatable, Sendable {
    var count: Int = 0
}

@FeatureState
struct SessionState: Equatable, Sendable {
    var name: String = "Live sync"
    var telemetry: TelemetryState = TelemetryState()
}

@FeatureState
struct TelemetryState: Equatable, Sendable {
    var status: String = "Connected"
    var subphase: SubphaseState = .idle
}

@FeatureState
struct ActiveState: Equatable, Sendable {
    var tick: Int = 0
    var note: String = ""
}
