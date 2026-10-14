import Observation

/// Records whether anything read in its closure changed, the way SwiftUI tracks a view body.
///
/// `init` runs `read` inside `withObservationTracking`; `didFire` turns true on the first change
/// notification, which Observation delivers synchronously from the mutation's `willSet`.
final class ObservationProbe: @unchecked Sendable {
    private(set) var didFire = false

    @MainActor
    init(_ read: @MainActor () -> Void) {
        withObservationTracking {
            read()
        } onChange: { [self] in
            didFire = true
        }
    }
}
