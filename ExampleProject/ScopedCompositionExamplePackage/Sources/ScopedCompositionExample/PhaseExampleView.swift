import Foundation
import Lattice
import SwiftUI

typealias PhaseExampleViewModel = ViewModel<
    Feature<PhaseEvent, PhaseDomainState, PhaseViewState>
>

/// Root of the enum-case-scoping demo: a plain exhaustive `switch` over the coarse
/// `viewModel.viewState` read selects the outer case; `scope(state: \.success,
/// action: \.success)` projects the matched payload into a live `ScopedViewModel`, and the
/// children chain `scope` four levels deep (`Success > Session > Telemetry > Subphase >
/// Active`), including an inner sub-phase enum case-scoped below the root.
///
/// The render counters make the observation boundaries visible:
/// - Ticks or typing in the deep leaf (in-place payload mutation): only `ActiveView renders:`
///   advances; every intermediate and sibling counter stays put.
/// - Increment (sibling branch): only `SummaryView renders:` advances.
/// - Start/Stop (inner case change): only `TelemetryView renders:` (the inner switch) and its
///   rebuilt subtree advance; the root switch stays put.
/// - Load/Reset (outer case change): `PhaseExampleView renders:` advances — the intended
///   coarse channel.
/// - Ticks while `.loading` (or `.idle`): nothing advances. This is the `_$inert` fix made
///   visible; before it, a payloadless case minted a fresh id per access and the switch
///   re-rendered once per second while showing an unchanged spinner.
struct PhaseExampleView: View {
    let viewModel: PhaseExampleViewModel
    // ponytail: render counter is demo-only instrumentation, not a real pattern
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    """
                    Each level holds a ScopedViewModel chained from the case scope and shows \
                    its own render counter. Ticks and typing mutate the deep leaf in place — \
                    only ActiveView re-renders. Start/Stop flips the inner sub-phase — only \
                    the inner switch re-renders. Load/Reset flips the outer case — only then \
                    does the root re-render. Ticks while loading re-render nothing.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                switch viewModel.viewState {  // coarse read: re-renders on outer case change only
                case .loading:
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity)
                case .success:
                    SuccessView(model: viewModel.scope(state: \.success, action: \.success))
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
    let model: ScopedViewModel<SuccessViewState, SuccessAction>
    // ponytail: render counter is demo-only instrumentation, not a real pattern
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
    let model: ScopedViewModel<SummaryViewState, SummaryAction>
    // ponytail: render counter is demo-only instrumentation, not a real pattern
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
    let model: ScopedViewModel<SessionViewState, SessionAction>
    // ponytail: render counter is demo-only instrumentation, not a real pattern
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

/// Level 3: owns the inner sub-phase switch. Reading `model.subphase` registers the sub-phase
/// container's identity, so this view re-renders on inner case changes only — in-place leaf
/// mutations inside `.active` do not advance its counter.
struct TelemetryView: View {
    let model: ScopedViewModel<TelemetryViewState, TelemetryAction>
    // ponytail: render counter is demo-only instrumentation, not a real pattern
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.status)

            switch model.subphase {  // inner switch: re-renders on sub-phase case change only
            case .idle:
                Text("Idle")
                    .foregroundStyle(.secondary)
            case .active:
                ActiveView(
                    model: model.scope(state: \.subphase, action: \.subphase)
                        .scope(state: \.active, action: \.active)
                )
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

/// Level 4, the deep leaf: the tick stream mutates `tick` in place once per second and the
/// note field round-trips through a binding — only this counter advances on either.
struct ActiveView: View {
    let model: ScopedViewModel<ActiveViewState, ActiveAction>
    // ponytail: render counter is demo-only instrumentation, not a real pattern
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
