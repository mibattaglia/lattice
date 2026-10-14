import Observation
import Testing

@testable import ScopedCompositionExample
import Lattice

private final class ChangeProbe: @unchecked Sendable {
    var didChange = false
}

@MainActor
@Suite
struct ScopedCompositionExampleTests {
    private func makeViewModel() -> ScopedCompositionViewModel {
        ViewModel(
            initialState: ScopedCompositionState(),
            feature: Feature(interactor: ScopedCompositionInteractor())
        )
    }

    @Test
    func chainedScopeSendsThroughToRoot() {
        let viewModel = makeViewModel()
        let badge = viewModel.scope(state: \.dashboard, action: \.dashboard)
            .scope(state: \.header, action: \.header)
            .scope(state: \.badge, action: \.badge)

        badge.sendViewEvent(.incremented)
        #expect(viewModel.viewState.dashboard.header.badge.count == 1)
    }

    @Test
    func badgeLeafChangeDoesNotInvalidateHeaderTitleObserver() {
        let viewModel = makeViewModel()
        let header = viewModel.scope(state: \.dashboard, action: \.dashboard)
            .scope(state: \.header, action: \.header)
        let probe = ChangeProbe()
        withObservationTracking { _ = header.title } onChange: { probe.didChange = true }

        viewModel.sendViewEvent(.dashboard(.header(.badge(.incremented))))
        #expect(!probe.didChange)
        #expect(viewModel.viewState.dashboard.header.badge.count == 1)
    }

    @Test
    func readOnlyFooterScopeIsObservationLive() {
        let viewModel = makeViewModel()
        let footer = viewModel.scope(state: \.footer)
        let probe = ChangeProbe()
        withObservationTracking { _ = footer.status } onChange: { probe.didChange = true }

        viewModel.sendViewEvent(.setFooter("Updated"))
        #expect(probe.didChange)
        #expect(viewModel.viewState.footer.status == "Updated")
    }

    @Test
    func badgeBindingReadsAndSendsThroughChainedScopes() {
        let viewModel = makeViewModel()
        let badge = viewModel.scope(state: \.dashboard, action: \.dashboard)
            .scope(state: \.header, action: \.header)
            .scope(state: \.badge, action: \.badge)
        let binding = badge.binding(\.label, sending: \.labelChanged)

        #expect(binding.wrappedValue == "Badge")
        binding.wrappedValue = "Typed"
        #expect(viewModel.viewState.dashboard.header.badge.label == "Typed")
    }
}
