import Foundation
import Lattice

@FeatureState
struct SuccessState: Equatable, Sendable {
    var title = "Success"
    var summary = SummaryState()
    var session = SessionState()
}

@FeatureState
struct SummaryState: Equatable, Sendable {
    var count = 0
}

@FeatureState
struct SessionState: Equatable, Sendable {
    var name = "Live sync"
    var telemetry = TelemetryState()
}

@FeatureState
struct TelemetryState: Equatable, Sendable {
    var status = "Connected"
    var subphase: SubphaseState = .idle
}

@FeatureState
struct ActiveState: Equatable, Sendable {
    var tick = 0
    var note = ""
}
