import Foundation
import UnoArchitecture

@Interactor<RootDomainState, RootEvent>
struct RootInteractor: Sendable {
    private let healthKitReader: HealthKitReader

    init(healthKitReader: HealthKitReader) {
        self.healthKitReader = healthKitReader
    }

    var body: some InteractorOf<Self> {
        Interact(initialValue: .checkingPermission) { state, event in
            switch event {
            case .onAppear:
                state = .checkingPermission
                return .perform { [healthKitReader] _, send in
                    let isAuthorized = await healthKitReader.checkAuthorization()
                    if isAuthorized {
                        await send(.authorized)
                    } else {
                        await send(.needsPermission)
                    }
                }

            case .requestPermission:
                state = .requestingPermission
                return .perform { [healthKitReader] _, send in
                    do {
                        let granted = try await healthKitReader.requestAuthorization()
                        await send(granted ? .authorized : .permissionDenied)
                    } catch {
                        await send(.permissionDenied)
                    }
                }

            case .permissionResult(let granted):
                state = granted ? .authorized : .permissionDenied
                return .state
            }
        }
    }
}
