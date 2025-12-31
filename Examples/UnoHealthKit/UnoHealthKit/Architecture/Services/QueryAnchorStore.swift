import Foundation
import HealthKit

actor QueryAnchorStore {
    private var workoutAnchor: HKQueryAnchor?

    func getWorkoutAnchor() -> HKQueryAnchor? {
        workoutAnchor
    }

    func setWorkoutAnchor(_ anchor: HKQueryAnchor) {
        workoutAnchor = anchor
    }

    func reset() {
        workoutAnchor = nil
    }
}
