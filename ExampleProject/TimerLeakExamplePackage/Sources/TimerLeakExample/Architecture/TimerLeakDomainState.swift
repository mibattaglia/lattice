struct TimerLeakDomainState: Equatable, Sendable {
    var tickCount: Int = 0
    var displayedValue: String = "value-0"
    var isRunning: Bool = false
}
