import Foundation
import Lattice
import SwiftUI

typealias FineGrainedViewModel = ViewModel<FineGrainedState, FineGrainedEvent>

struct FineGrainedView: View {
    let viewModel: FineGrainedViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(
                """
                Each subview shows its own render counter. With per-member diff-at-commit
                observation, a button only re-renders the subview that reads the member it
                changed — the other counters stay put.
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
            Text(viewModel.title)  // reads only `title`
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
            Text("Count: \(viewModel.count)")  // reads only `count`
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
            // `phaseLabel` is derived view output over a @Domain member: this view
            // re-renders only when the derived string actually changes.
            if let label = viewModel.phaseLabel {
                Text("Phase: \(label)")
                    .font(.title2)
            } else {
                Text("Phase: idle")
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
