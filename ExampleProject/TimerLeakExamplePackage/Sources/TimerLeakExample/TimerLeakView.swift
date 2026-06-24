import Lattice
import SwiftUI

struct TimerLeakView: View {
    private var viewModel: ViewModel<Feature<TimerLeakEvent, TimerLeakDomainState, TimerLeakViewState>>

    init(viewModel: ViewModel<Feature<TimerLeakEvent, TimerLeakDomainState, TimerLeakViewState>>) {
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Kept outside the TimelineView so it keeps updating.
                ResidentMemoryOverlay()

                Text(
                    """
                    Throwaway demo for the @ObservableState registrar leak,
                    mirroring HybrdLiveWorkout's metric grid: a TimelineView
                    re-renders the rows continuously on a date schedule (reusing
                    view identities), reading each row's nested @ObservableState
                    leaf every frame. A ~50 Hz timer rebuilds the child (\
                    \(TimerLeakConstants.rowCount) rows) wholesale underneath; the
                    rebuild is content-equal, so each previously-tracked registrar
                    is silently swapped out and never cancelled. Watch resident
                    memory climb steadily.
                    """
                )
                .font(.footnote)
                .padding(.horizontal)

                // TimelineView drives continuous re-rendering via `context.date`,
                // exactly like LiveWorkoutBottomSheetView's metric timeline. Each
                // re-render re-reads the current rows from the view model and
                // re-observes their registrars; the reducer's wholesale child
                // rebuild orphans the previous ones.
                TimelineView(.animation) { context in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(viewModel.viewState.child.rows) { row in
                                RowView(row: row, date: context.date)
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
            .navigationTitle("Timer Leak")
            .task {
                viewModel.sendViewEvent(.start)
            }
        }
    }
}

/// One observing subview per nested row, modeled on `LiveWorkoutMetricValueText`.
/// Reading `row.value` registers an observation on the row's registrar; the
/// `date` input changes every frame, so this body re-runs (and re-observes the
/// current registrar) on every TimelineView tick.
private struct RowView: View {
    let row: TimerRowViewState
    let date: Date

    var body: some View {
        HStack {
            Text(row.value)
            Spacer()
            Text(date, format: .dateTime.hour().minute().second())
        }
        .font(.system(.caption2, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
}
