#if canImport(AppKit)
    import AppKit
    import Foundation
    import Lattice
    import SwiftUI
    import Testing

    @testable import ScopedCompositionExample

    /// Renders `ScopedCompositionView` in an `NSHostingView` and checks the render counts its
    /// views document: the root and `DashboardView` never advance past 1, `HeaderView`
    /// re-renders on a title change and `BadgeView` with it, and a leaf change re-renders only
    /// the leaf.
    @MainActor
    @Suite
    struct ScopedCompositionRenderTests {
        private let viewModel = ViewModel(
            initialState: ScopedCompositionState(),
            feature: Feature(interactor: ScopedCompositionInteractor())
        )
        private let counters = RenderCounters()
        private let host: NSView

        init() {
            let host = NSHostingView(
                rootView: ScopedCompositionView(viewModel: viewModel)
                    .environment(\.renderCounters, counters)
            )
            host.frame = NSRect(x: 0, y: 0, width: 480, height: 900)
            self.host = host
            render()
        }

        /// Body runs per view, keyed by view, so a failure shows every count at once.
        private var renders: [String: Int] {
            [
                "root": counters.root,
                "dashboard": counters.dashboard,
                "header": counters.header,
                "badge": counters.badge,
                "footer": counters.footer,
            ]
        }

        private func send(_ event: ScopedCompositionEvent) {
            viewModel.sendViewEvent(event)
            render()
        }

        /// Lays the hosting view out, which re-runs every invalidated `body`, then spins the main
        /// run loop briefly so that a late update would be counted too.
        private func render() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
        }

        @Test
        func initialRenderRunsEveryBodyOnce() {
            #expect(renders == ["root": 1, "dashboard": 1, "header": 1, "badge": 1, "footer": 1])
        }

        @Test
        func titleChangeReRendersHeaderAndTheBadgeItScopes() {
            send(.dashboard(.header(.titleChanged("Renamed"))))
            #expect(renders == ["root": 1, "dashboard": 1, "header": 2, "badge": 2, "footer": 1])
        }

        @Test
        func badgeLeafChangesReRenderOnlyTheBadge() {
            send(.dashboard(.header(.badge(.incremented))))
            #expect(renders == ["root": 1, "dashboard": 1, "header": 1, "badge": 2, "footer": 1])

            send(.dashboard(.header(.badge(.labelChanged("Typed")))))
            #expect(renders == ["root": 1, "dashboard": 1, "header": 1, "badge": 3, "footer": 1])
        }

        @Test
        func footerChangeReRendersOnlyTheFooter() {
            send(.setFooter("Updated"))
            #expect(renders == ["root": 1, "dashboard": 1, "header": 1, "badge": 1, "footer": 2])
        }

        @Test
        func rootAndDashboardNeverRenderPastOnce() {
            send(.dashboard(.header(.titleChanged("Renamed"))))
            send(.dashboard(.header(.badge(.incremented))))
            send(.dashboard(.header(.badge(.labelChanged("Typed")))))
            send(.setFooter("Updated"))
            #expect(counters.root == 1)
            #expect(counters.dashboard == 1)
        }
    }
#endif
