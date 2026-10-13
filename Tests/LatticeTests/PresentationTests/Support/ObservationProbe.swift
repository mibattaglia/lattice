import Foundation
import Observation

/// Records whether anything read in its closure changed, the way SwiftUI tracks a view body.
///
/// `init` runs `read` inside `withObservationTracking`; `didFire` turns true on the first change
/// notification, which Observation delivers synchronously from the mutation's `willSet`.
final class ObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false

    @MainActor
    init(_ read: @MainActor () -> Void) {
        withObservationTracking {
            read()
        } onChange: { [self] in
            markFired()
        }
    }

    var didFire: Bool { lock.withLock { hasFired } }

    private func markFired() {
        lock.withLock { hasFired = true }
    }
}
