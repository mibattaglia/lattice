import Lattice
import SwiftUI

struct TimerLeakView: View {
    private var viewModel: ViewModel<TimerLeakState, TimerLeakEvent>

    init(viewModel: ViewModel<TimerLeakState, TimerLeakEvent>) {
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Kept outside the TimelineView so it keeps updating.
                ResidentMemoryOverlay()

                Text(
                    """
                    Stress demo for diff-at-commit under continuous re-rendering: a
                    TimelineView re-renders \(TimerLeakConstants.rowCount) rows every frame
                    (reusing view identities), each row reading the projected
                    `displayedValue`. A ~50 Hz timer effect commits underneath; most commits
                    leave the visible output unchanged, so the per-member diff pokes the
                    rows' observers only once per 100 ticks. Resident memory should stay
                    flat — the host-owned registrar has no per-copy identity to leak.
                    """
                )
                .font(.footnote)
                .padding(.horizontal)

                // TimelineView drives continuous re-rendering via `context.date`. Each
                // re-render re-reads `displayedValue` through the projection; observation is
                // registrar-keyed per member, not per state copy, so re-registration is
                // stable across the timer's commits.
                TimelineView(.animation) { context in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(0..<TimerLeakConstants.rowCount, id: \.self) { _ in
                                RowView(value: viewModel.displayedValue, date: context.date)
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
            .navigationTitle("Timer")
            .task {
                viewModel.sendViewEvent(.start)
            }
        }
    }
}

/// One row per line; the `date` input changes every frame, so this body re-runs (and
/// re-reads the projected value) on every TimelineView tick.
private struct RowView: View {
    let value: String
    let date: Date

    var body: some View {
        HStack {
            Text(value)
            Spacer()
            Text(date, format: .dateTime.hour().minute().second())
        }
        .font(.system(.caption2, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
}
