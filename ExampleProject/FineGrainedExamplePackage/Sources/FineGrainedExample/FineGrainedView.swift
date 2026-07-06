import Foundation
import Lattice
import SwiftUI

typealias FineGrainedViewModel = ViewModel<
    Feature<FineGrainedEvent, FineGrainedDomainState, FineGrainedViewState>
>

struct FineGrainedView: View {
    let viewModel: FineGrainedViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(
                """
                Each subview shows its own render counter. With fine-grained
                observation, a button only re-renders the subview that reads the
                slice it changed — the other counters stay put.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            HeaderView(viewModel: viewModel)
            FooterView(viewModel: viewModel)
            PhaseView(viewModel: viewModel)

            VStack(spacing: 12) {
                Button("Change title") {
                    viewModel.sendViewEvent(.setTitle(String(UUID().uuidString.prefix(8))))
                }
                Button("Bump count") {
                    viewModel.sendViewEvent(.bumpCount)
                }
                Button("Toggle phase") {
                    viewModel.sendViewEvent(.togglePhase)
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding()
    }
}

struct HeaderView: View {
    let viewModel: FineGrainedViewModel
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading) {
            Text(viewModel.header.title)  // reads only header.title
                .font(.title2)
            Text("HeaderView renders: \(renders.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct FooterView: View {
    let viewModel: FineGrainedViewModel
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading) {
            Text("Count: \(viewModel.footer.count)")  // reads only footer.count
                .font(.title2)
            Text("FooterView renders: \(renders.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PhaseView: View {
    let viewModel: FineGrainedViewModel
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading) {
            // Switching over the enum slice registers `\.phase`; only a case change
            // (idle <-> active) re-renders this switch.
            switch viewModel.phase {
            case .idle:
                Text("Phase: idle")
                    .font(.title2)
            case .active(let label):
                Text("Phase: \(label)")
                    .font(.title2)
            }
            Text("PhaseView renders: \(renders.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
