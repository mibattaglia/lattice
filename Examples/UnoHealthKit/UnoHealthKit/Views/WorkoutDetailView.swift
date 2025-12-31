import SwiftUI

struct WorkoutDetailView: View {
    let viewState: WorkoutDetailViewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                workoutDetailsSection
                if !viewState.events.isEmpty {
                    splitsSection
                }
            }
            .padding()
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(viewState.header.dateShort)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(viewState.header.accentColor)
                    .frame(width: 64, height: 64)

                Image(systemName: viewState.header.activityIcon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(viewState.header.activityName)
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text(viewState.header.timeRange)
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }

            Spacer()
        }
    }

    private var workoutDetailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workout Details")
                .font(.title2.bold())
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                let rows = viewState.statsGrid.chunked(into: 2)
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowStats in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(rowStats) { stat in
                            StatCell(stat: stat)
                            if stat.id != rowStats.last?.id {
                                Spacer()
                            }
                        }
                        if rowStats.count == 1 {
                            Spacer()
                        }
                    }
                    .padding(.vertical, 12)

                    if rowIndex < rows.count - 1 {
                        Divider()
                            .background(Color.gray.opacity(0.3))
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray6).opacity(0.15))
            )
        }
    }

    private var splitsSection: some View {
        let hasSpeed = viewState.events.contains { $0.averageSpeed != nil }
        let hasHeartRate = viewState.events.contains { $0.averageHeartRate != nil }
        let hasPower = viewState.events.contains { $0.averagePower != nil }
        let hasCadence = viewState.events.contains { $0.averageCadence != nil }

        return VStack(alignment: .leading, spacing: 16) {
            Text("Splits")
                .font(.title2.bold())
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                SplitHeaderRow(
                    hasSpeed: hasSpeed,
                    hasHeartRate: hasHeartRate,
                    hasPower: hasPower,
                    hasCadence: hasCadence
                )

                ForEach(viewState.events) { event in
                    SplitRow(
                        event: event,
                        hasSpeed: hasSpeed,
                        hasHeartRate: hasHeartRate,
                        hasPower: hasPower,
                        hasCadence: hasCadence
                    )
                    if event.id != viewState.events.last?.id {
                        Divider()
                            .background(Color.gray.opacity(0.3))
                    }
                }
            }
            .padding(.vertical)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray6).opacity(0.15))
            )
        }
    }
}

private struct StatCell: View {
    let stat: WorkoutStatCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.title)
                .font(.subheadline)
                .foregroundStyle(.gray)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(stat.value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(stat.color)
                Text(stat.unit.uppercased())
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(stat.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SplitHeaderRow: View {
    let hasSpeed: Bool
    let hasHeartRate: Bool
    let hasPower: Bool
    let hasCadence: Bool

    var body: some View {
        HStack {
            Text("")
                .frame(width: 30)
            Text("Time")
                .frame(maxWidth: .infinity, alignment: .leading)
            if hasSpeed {
                Text("Speed")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasHeartRate {
                Text("HR")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasPower {
                Text("Power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasCadence {
                Text("Cadence")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption)
        .foregroundStyle(.gray)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

private struct SplitRow: View {
    let event: WorkoutEventItem
    let hasSpeed: Bool
    let hasHeartRate: Bool
    let hasPower: Bool
    let hasCadence: Bool

    var body: some View {
        HStack {
            Text("\(event.index)")
                .font(.body)
                .foregroundStyle(.gray)
                .frame(width: 30, alignment: .leading)

            Text(event.duration)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasSpeed {
                Text(event.averageSpeed ?? "–")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.cyan)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasHeartRate {
                Text(event.averageHeartRate ?? "–")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasPower {
                Text(event.averagePower ?? "–")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasCadence {
                Text(event.averageCadence ?? "–")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.purple)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
