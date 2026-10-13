import Foundation
import Lattice
import SwiftUI

typealias ScopedCompositionViewModel = ViewModel<
    Feature<ScopedCompositionEvent, ScopedCompositionState>
>

/// How many times each view's `body` has run, as shown by the views' render counters.
///
/// SwiftUI re-creates a child view value every time its parent's `body` runs, so a counter
/// stored in the view value would start over at each re-creation. The counts live in this one
/// object instead, shared through the environment.
final class RenderCounters {
    var root = 0
    var dashboard = 0
    var header = 0
    var badge = 0
    var footer = 0
}

extension EnvironmentValues {
    @Entry var renderCounters = RenderCounters()
}

/// Root of the demo. Owns the `ViewModel`, creates scopes inline in `body`, and reads
/// nothing observable itself — the buttons only send. This is the read-light container
/// shape: its render counter (and `DashboardView`'s) should never advance past 1.
struct ScopedCompositionView: View {
    let viewModel: ScopedCompositionViewModel
    @Environment(\.renderCounters) private var renderCounters

    var body: some View {
        renderCounters.root += 1
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(
                    """
                    Each subview holds a ScopedViewModel created inline in body and shows
                    its own render counter. Leaf changes re-render only the leaf; when a
                    scope-creating view re-renders, its scoped children re-render with it
                    (the documented trade-off).
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                DashboardView(model: viewModel.scope(state: \.dashboard, action: \.dashboard))
                FooterView(model: viewModel.scope(state: \.footer))

                VStack(spacing: 12) {
                    Button("Rename header") {
                        viewModel.sendViewEvent(
                            .dashboard(
                                .header(.titleChanged("Dash \(UUID().uuidString.prefix(4))"))
                            )
                        )
                    }
                    Button("Update footer") {
                        viewModel.sendViewEvent(
                            .setFooter("Updated \(UUID().uuidString.prefix(4))")
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Text("Root renders: \(renderCounters.root)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

/// The degenerate container case: reads nothing observable, only creates the header scope.
/// Its counter should never advance past 1, even when the header re-renders.
struct DashboardView: View {
    let model: ScopedViewModel<DashboardState, DashboardAction>
    @Environment(\.renderCounters) private var renderCounters

    var body: some View {
        renderCounters.dashboard += 1
        return VStack(alignment: .leading, spacing: 12) {
            HeaderView(model: model.scope(state: \.header, action: \.header))
            Text("DashboardView renders: \(renderCounters.dashboard)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Reads only `title` from its slice; a badge-leaf change does not invalidate it. When it
/// does re-render (title change), `BadgeView` re-renders with it because a fresh badge scope
/// can never be proven unchanged — the documented trade-off, visible in the counters.
struct HeaderView: View {
    let model: ScopedViewModel<HeaderState, HeaderAction>
    @Environment(\.renderCounters) private var renderCounters

    var body: some View {
        renderCounters.header += 1
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.title)  // reads only header.title
                .font(.title2)
            BadgeView(model: model.scope(state: \.badge, action: \.badge))
            Text("HeaderView renders: \(renderCounters.header)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The leaf: a two-way binding into the slice plus a counter button.
struct BadgeView: View {
    let model: ScopedViewModel<BadgeState, BadgeAction>
    @Environment(\.renderCounters) private var renderCounters

    var body: some View {
        renderCounters.badge += 1
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Label", text: model.binding(\.label, sending: \.labelChanged))
                .textFieldStyle(.roundedBorder)
            Button("Increment") { model.sendViewEvent(.incremented) }
                .buttonStyle(.bordered)
            Text("Count: \(model.count)")
            Text("BadgeView renders: \(renderCounters.badge)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Reads `status` through a read-only scope (`ScopedViewModel<FooterState, Never>`): the
/// projection is observation-live even though it can send nothing.
struct FooterView: View {
    let model: ScopedViewModel<FooterState, Never>
    @Environment(\.renderCounters) private var renderCounters

    var body: some View {
        renderCounters.footer += 1
        return VStack(alignment: .leading) {
            Text(model.status)  // reads only footer.status
                .font(.title2)
            Text("FooterView renders: \(renderCounters.footer)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
