import SwiftUI

struct WorkoutCell: View {
    let workout: WorkoutListItem

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(workout.detailViewState.header.accentColor)
                    .frame(width: 56, height: 56)

                Image(systemName: workout.workoutIcon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(workout.workoutType)
                        .font(.headline)
                        .foregroundStyle(.white)

                    Spacer()

                    Text(workout.duration)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                }

                Text(workout.startTime)
                    .font(.subheadline)
                    .foregroundStyle(.gray)

                HStack(spacing: 16) {
                    if let calories = workout.calories {
                        metricView(value: calories, color: .yellow)
                    }

                    if let distance = workout.distance {
                        metricView(value: distance, color: .cyan)
                    }

                    if let heartRate = workout.heartRate {
                        metricView(value: heartRate, color: .red)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func metricView(value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
    }
}
