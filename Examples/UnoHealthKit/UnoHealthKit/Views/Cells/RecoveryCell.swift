import SwiftUI

struct RecoveryCell: View {
    let recovery: RecoveryListItem

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.indigo)
                    .frame(width: 56, height: 56)

                Image(systemName: "bed.double.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recovery")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Spacer()

                    if let totalSleep = recovery.totalSleep {
                        Text(totalSleep)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.indigo)
                    }
                }

                if let stages = recovery.sleepStages {
                    sleepStagesView(stages)
                }

                HStack(spacing: 16) {
                    if let rhr = recovery.restingHeartRate {
                        vitalView(value: rhr, color: .red)
                    }

                    if let hrv = recovery.hrv {
                        vitalView(value: hrv, color: .green)
                    }

                    if let respRate = recovery.respiratoryRate {
                        vitalView(value: respRate, color: .cyan)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func sleepStagesView(_ stages: SleepStagesDisplay) -> some View {
        HStack(spacing: 8) {
            stageBar(label: "Awake", value: stages.awake, color: .orange)
            stageBar(label: "REM", value: stages.rem, color: .cyan)
            stageBar(label: "Core", value: stages.core, color: .blue)
            stageBar(label: "Deep", value: stages.deep, color: .indigo)
        }
    }

    private func stageBar(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(height: 20)

            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
    }

    private func vitalView(value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
    }
}
