import Foundation
import Lattice

@FeatureState
struct SuccessState: Equatable {
    var title = "Success"
    var summary = SummaryState()
    var session = SessionState()
}

@FeatureState
struct SummaryState: Equatable {
    var count = 0
}

@FeatureState
struct SessionState: Equatable {
    var name = "Live sync"
    var telemetry = TelemetryState()
}

@FeatureState
struct TelemetryState: Equatable {
    var status = "Connected"
    var subphase: SubphaseState = .idle
}

@FeatureState
struct ActiveState: Equatable {
    var tick = 0
    var note = ""
}
