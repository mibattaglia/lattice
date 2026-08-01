import Foundation
import Lattice
import SwiftUI

typealias PhaseExampleViewModel = ViewModel<PhaseState, PhaseEvent>

/// Root of the enum-case-scoping demo: the root branches on the active case via
/// `scopeIfActive(state: \.success, action: \.success)`, which projects the matched payload
/// into a live `ScopedViewModel`, and the children chain `scope` four levels deep
/// (`Success > Session > Telemetry > Subphase > Active`), including an inner sub-phase enum
/// case-scoped below the root.
///
/// The render counters make the observation boundaries visible:
/// - Ticks or typing in the deep leaf (payload member change): only `ActiveView renders:`
///   advances; every intermediate and sibling counter stays put.
/// - Increment (sibling branch): only `SummaryView renders:` advances.
/// - Start/Stop (inner case change): only `TelemetryView renders:` (the inner branch) and its
///   rebuilt subtree advance; the root stays put.
/// - Load/Reset (outer case change): `PhaseExampleView renders:` advances — the intended
///   coarse channel.
/// - Ticks while `.loading` (or `.idle`): nothing advances — a tick that mutates nothing is
///   a no-change commit, and the diff fires no observers.
struct PhaseExampleView: View {
    let viewModel: PhaseExampleViewModel
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    """
                    Each level holds a ScopedViewModel chained from the case scope and shows \
                    its own render counter. Ticks and typing mutate the deep leaf — only \
                    ActiveView re-renders. Start/Stop flips the inner sub-phase — only the \
                    inner branch re-renders. Load/Reset flips the outer case — only then \
                    does the root re-render. Ticks while loading re-render nothing.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                // Case projection: re-renders on outer case change only.
                if let success = viewModel.scopeIfActive(state: \.success, action: \.success) {
                    SuccessView(model: success)
                } else {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity)
                }

                VStack(spacing: 12) {
                    Button("Load") { viewModel.sendViewEvent(.loadTapped) }
                    Button("Reset") { viewModel.sendViewEvent(.resetTapped) }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Text("PhaseExampleView renders: \(renders.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .task { await viewModel.sendViewEvent(.startTicking).finish() }
    }
}

/// Level 1 below the outer case: reads only `title`, then hands each branch its own scope.
/// `SummaryView` is the sibling branch that must stay put while the deep leaf ticks.
struct SuccessView: View {
    let model: ScopedViewModel<SuccessState, SuccessAction>
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: model.binding(\.title, sending: \.titleChanged))
                .textFieldStyle(.roundedBorder)
            SummaryView(model: model.scope(state: \.summary, action: \.summary))
            SessionView(model: model.scope(state: \.session, action: \.session))
            Text("SuccessView renders: \(renders.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Sibling branch: its counter advances on Increment and stays put on leaf ticks, typing,
/// and inner case changes.
struct SummaryView: View {
    let model: ScopedViewModel<SummaryState, SummaryAction>
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading, spacing: 8) {
            Button("Increment") { model.sendViewEvent(.incremented) }
                .buttonStyle(.bordered)
            Text("Count: \(model.count)")
            Text("SummaryView renders: \(renders.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Level 2: reads only `name`; a thin pass-through that scopes deeper.
struct SessionView: View {
    let model: ScopedViewModel<SessionState, SessionAction>
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.name)
                .font(.headline)
            TelemetryView(model: model.scope(state: \.telemetry, action: \.telemetry))
            Text("SessionView renders: \(renders.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Level 3: owns the inner sub-phase branch. `scopeIfActive` through the sub-phase enum's
/// case accessor re-renders this view on inner case changes only — leaf member mutations
/// inside `.active` do not advance its counter.
struct TelemetryView: View {
    let model: ScopedViewModel<TelemetryState, TelemetryAction>
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        let subphase = model.scope(state: \.subphase, action: \.subphase)
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.status)

            if let active = subphase.scopeIfActive(state: \.active, action: \.active) {
                ActiveView(model: active)
            } else {
                Text("Idle")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Start") { model.sendViewEvent(.startTapped) }
                Button("Stop") { model.sendViewEvent(.stopTapped) }
            }
            .buttonStyle(.bordered)

            Text("TelemetryView renders: \(renders.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Level 4, the deep leaf: the tick stream mutates `tick` once per second and the note field
/// round-trips through a binding — only this counter advances on either.
struct ActiveView: View {
    let model: ScopedViewModel<ActiveState, ActiveAction>
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading, spacing: 8) {
            Text("Tick: \(model.tick)")
                .font(.title3)
            TextField("Note", text: model.binding(\.note, sending: \.noteChanged))
                .textFieldStyle(.roundedBorder)
            Text("ActiveView renders: \(renders.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}
