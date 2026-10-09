#if os(macOS)
    import AppKit
    import Lattice
    import QuartzCore
    import SwiftUI
    import Testing

    // These are actual SwiftUI/AppKit hosts of the public Lattice API. No
    // handwritten state host, identity-only EquatableView, or timing sleeps.
    @Suite(.serialized)
    @MainActor
    struct FeatureStateHostedTests {
        @Test
        func equatableSiblingMutationsSeparateListContentRowAndAppliedWork() async throws {
            let state = MutationState()
            let model = mutationModel(state)
            let probe = HostedMutationProbe()
            let mount = HostedMutationMount(HostedRows(model: model, probe: probe))
            defer { mount.close() }
            try mount.settle { probe.applied["ticket"] == "0" && probe.applied["row-1"] == "Milk" && probe.applied["row-2"] == "Bread" }
            let initialA = probe.bodies["row-1", default: 0]
            let initialList = probe.listBodies
            let initialContent = probe.contentCalls

            model.sendViewEvent(.row(1, .sibling))
            model.sendViewEvent(.ticket(1))
            try mount.settle { probe.applied["ticket"] == "1" }
            #expect(probe.bodies["row-1", default: 0] == initialA)
            #expect(probe.listBodies > initialList)
            #expect(probe.applied["row-1"] == "Milk")

            model.sendViewEvent(.row(2, .title("Zucchini")))
            model.sendViewEvent(.ticket(2))
            try mount.settle { probe.applied["ticket"] == "2" && probe.applied["row-2"] == "Zucchini" }
            #expect(probe.bodies["row-1", default: 0] == initialA)
            await model.sendViewEvent(.emitted(.row(2, .sibling))).finish()
            model.sendViewEvent(.ticket(3))
            try mount.settle { probe.applied["ticket"] == "3" }
            #expect(probe.bodies["row-1", default: 0] == initialA)

            model.sendViewEvent(.row(1, .title("Cream")))
            model.sendViewEvent(.ticket(4))
            try mount.settle { probe.applied["ticket"] == "4" && probe.applied["row-1"] == "Cream" }
            #expect(probe.bodies["row-1", default: 0] > initialA)
            #expect(state.rows.allSatisfy { $0.probe.count("rowEquality") == 0 })
            print("HOSTED granularity: list=\(probe.listBodies), content=\(probe.contentCalls) (initial \(initialContent)), row=\(probe.bodies), applied=\(probe.applied)")
        }

        @Test
        func coalescedRemovalRendersLastSelectedCommitRatherThanLastRenderedValue() throws {
            let model = mutationModel()
            let held = try #require(model.filteredRows.first { $0.id == 1 })
            let probe = HostedMutationProbe()
            let mount = HostedMutationMount(HostedRows(model: model, probe: probe, held: held))
            defer { mount.close() }
            try mount.settle { probe.applied["held"] == "Milk" && probe.applied["ticket"] == "0" }
            let before = probe.bodies["held", default: 0]
            var firstCommitBodies = -1
            var animationFinished = false
            withAnimation(.linear(duration: 0.05), completionCriteria: .removed) {
                model.sendViewEvent(.row(1, .title("Committed milk")))
                firstCommitBodies = probe.bodies["held", default: 0]
                model.sendViewEvent(.row(1, .remove))
                model.sendViewEvent(.ticket(1))
            } completion: { animationFinished = true }
            // Measure the checkpoint instead of assuming that two sends did not render.
            #expect(firstCommitBodies == before)
            try mount.settle {
                probe.applied["ticket"] == "1" && probe.applied["held"] == "Committed milk"
                    && probe.dismantled["row-1"] != nil && animationFinished
            }
            #expect(held.title == "Committed milk")
            #expect(model.filteredRows.allSatisfy { $0.id != 1 })
            print("HOSTED coalesced: before=\(before), firstCommit=\(firstCommitBodies), finalBodies=\(probe.bodies), dismantled=\(probe.dismantled), applied=\(probe.applied)")
        }

        @Test
        func omissionKeepsMilkThenTheSameHeldHandleRendersReconnection() throws {
            let model = mutationModel()
            let held = try #require(model.filteredRows.first { $0.id == 1 })
            let probe = HostedMutationProbe()
            let mount = HostedMutationMount(HostedRows(model: model, probe: probe, held: held))
            defer { mount.close() }
            try mount.settle { probe.applied["held"] == "Milk" && probe.applied["row-1"] == "Milk" }
            var animationFinished = false
            withAnimation(.linear(duration: 0.05), completionCriteria: .removed) {
                model.sendViewEvent(.excludeAfterRename(1, "Oat milk"))
                model.sendViewEvent(.ticket(1))
            } completion: { animationFinished = true }
            try mount.settle {
                probe.applied["ticket"] == "1" && probe.dismantled["row-1"] != nil && animationFinished
            }
            #expect(probe.applied["held"] == "Milk")
            #expect(held.title == "Milk")
            model.sendViewEvent(.row(1, .title("Hidden edit")))
            model.sendViewEvent(.ticket(2))
            try mount.settle { probe.applied["ticket"] == "2" }
            #expect(probe.applied["held"] == "Milk")
            model.sendViewEvent(.row(1, .eligible(true)))
            model.sendViewEvent(.ticket(3))
            try mount.settle {
                probe.applied["ticket"] == "3" && probe.applied["held"] == "Hidden edit" && probe.applied["row-1"] == "Hidden edit"
            }
            #expect(held.title == "Hidden edit")
            model.sendViewEvent(.row(1, .title("Reconnected channel")))
            model.sendViewEvent(.ticket(4))
            try mount.settle { probe.applied["held"] == "Reconnected channel" && probe.applied["ticket"] == "4" }
            print("HOSTED omission/reconnection: row=\(probe.bodies), applied=\(probe.applied), dismantled=\(probe.dismantled)")
        }

        @Test
        func emittedSelectedValueAndOrdinaryParentSurviveRemovalWithoutRenderReads() async throws {
            let model = mutationModel()
            let held = try #require(model.filteredRows.first { $0.id == 1 })
            let parent = try #require(model.scopeIfPresent(state: \.parent))
            // Materialize handles without mounting a view; neither gets a rendering read.
            await model.sendViewEvent(.emitted(.row(1, .title("Emitted milk")))).finish()
            await model.sendViewEvent(.emitted(.parent(.title("Emitted detail")))).finish()
            model.sendViewEvent(.row(1, .remove))
            model.sendViewEvent(.removeParentAfterEdit)
            let probe = HostedMutationProbe()
            let mount = HostedMutationMount(VStack {
                HostedTitleRow(row: held, key: "held", probe: probe)
                HostedRetainedParent(parent: parent, probe: probe)
            })
            defer { mount.close() }
            try mount.settle { probe.applied["held"] == "Emitted milk" && probe.applied["detail"] == "Emitted detail" }
            #expect(model.scopeIfPresent(state: \.parent) == nil)
            print("HOSTED no-reread emitted/ordinary: applied=\(probe.applied)")
        }

        @Test
        func changedConsumerCallbackRemainsFreshWithoutArtificialEquality() throws {
            let model = mutationModel()
            let probe = HostedMutationProbe()
            let mount = HostedMutationMount(HostedCallbackRows(model: model, probe: probe))
            defer { mount.close() }
            try mount.settle { probe.applied["ticket"] == "0" && probe.button != nil }
            let initial = probe.bodies["callback", default: 0]
            model.sendViewEvent(.ticket(1))
            try mount.settle { probe.applied["ticket"] == "1" }
            probe.button?.performClick(nil)
            try mount.settle { probe.applied["callback-title"] == "callback 1" }
            #expect(probe.callbacks == [1])
            #expect(probe.bodies["callback", default: 0] > initial)
            print("HOSTED callback freshness: callbacks=\(probe.callbacks), bodies=\(probe.bodies)")
        }
    }

    @MainActor
    private final class HostedMutationProbe {
        var listBodies = 0
        var contentCalls: [Int: Int] = [:]
        var bodies: [String: Int] = [:]
        var applied: [String: String] = [:]
        var dismantled: [String: String] = [:]
        var callbacks: [Int] = []
        weak var button: NSButton?
    }

    @MainActor
    private struct HostedRows: View {
        let model: MutationModel
        let probe: HostedMutationProbe
        var held: ScopedRowViewModel<MutationRow>?
        var body: some View {
            VStack {
                HostedList(model: model, probe: probe)
                HostedTicket(model: model, probe: probe)
                if let held { HostedTitleRow(row: held, key: "held", probe: probe) }
            }
        }
    }

    @MainActor
    private struct HostedList: View {
        let model: MutationModel
        let probe: HostedMutationProbe
        var body: some View {
            probe.listBodies += 1
            return VStack {
                ForEach(model.filteredRows) { row in
                    let _ = probe.contentCalls[row.id, default: 0] += 1
                    HostedTitleRow(row: row, key: "row-\(row.id)", probe: probe)
                        .transition(.opacity)
                }
            }
        }
    }

    @MainActor
    private struct HostedTitleRow: View {
        let row: ScopedRowViewModel<MutationRow>
        let key: String
        let probe: HostedMutationProbe
        var body: some View {
            probe.bodies[key, default: 0] += 1
            return HostedAppliedText(key: key, text: row.title, probe: probe).frame(height: 24)
        }
    }

    @MainActor
    private struct HostedRetainedParent: View {
        let parent: ScopedViewModel<MutationParent, Never>
        let probe: HostedMutationProbe
        var body: some View {
            HostedAppliedText(key: "detail", text: parent.scope(state: \.detail).title, probe: probe).frame(height: 24)
        }
    }

    @MainActor
    private struct HostedTicket: View {
        let model: MutationModel
        let probe: HostedMutationProbe
        var body: some View { HostedAppliedText(key: "ticket", text: "\(model.ticket)", probe: probe).frame(height: 24) }
    }

    @MainActor
    private struct HostedAppliedText: NSViewRepresentable {
        let key: String
        let text: String
        let probe: HostedMutationProbe
        func makeCoordinator() -> Coordinator { Coordinator(key: key, probe: probe) }
        func makeNSView(context: Context) -> NSTextField { NSTextField(labelWithString: text) }
        func updateNSView(_ view: NSTextField, context: Context) {
            view.stringValue = text
            probe.applied[key] = view.stringValue
        }
        static func dismantleNSView(_ view: NSTextField, coordinator: Coordinator) {
            coordinator.probe.dismantled[coordinator.key] = view.stringValue
        }
        final class Coordinator {
            let key: String
            let probe: HostedMutationProbe
            init(key: String, probe: HostedMutationProbe) { self.key = key; self.probe = probe }
        }
    }

    @MainActor
    private struct HostedCallbackRows: View {
        let model: MutationModel
        let probe: HostedMutationProbe
        var body: some View {
            let ticket = model.ticket
            return VStack {
                ForEach(model.filteredRows) { row in
                    if row.id == 1 {
                        HostedCallbackRow(row: row, probe: probe, onEvent: {
                            probe.callbacks.append(ticket)
                            model.sendViewEvent(.row(row.id, .title("callback \(ticket)")))
                        })
                    }
                }
                HostedTicket(model: model, probe: probe)
            }
        }
    }

    @MainActor
    private struct HostedCallbackRow: View {
        let row: ScopedRowViewModel<MutationRow>
        let probe: HostedMutationProbe
        let onEvent: () -> Void
        var body: some View {
            probe.bodies["callback", default: 0] += 1
            return HStack {
                HostedAppliedText(key: "callback-title", text: row.title, probe: probe)
                HostedAppliedButton(probe: probe, onEvent: onEvent)
            }.frame(height: 28)
        }
    }

    @MainActor
    private struct HostedAppliedButton: NSViewRepresentable {
        let probe: HostedMutationProbe
        let onEvent: () -> Void
        func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }
        func makeNSView(context: Context) -> NSButton {
            let button = NSButton(title: "Send", target: context.coordinator, action: #selector(Coordinator.send))
            probe.button = button
            return button
        }
        func updateNSView(_ view: NSButton, context: Context) { context.coordinator.onEvent = onEvent }
        final class Coordinator: NSObject {
            var onEvent: () -> Void
            init(onEvent: @escaping () -> Void) { self.onEvent = onEvent }
            @objc func send() { onEvent() }
        }
    }

    @MainActor
    private final class HostedMutationMount {
        private let view: NSHostingView<AnyView>
        private let window: NSWindow
        init<Content: View>(_ content: Content) {
            _ = NSApplication.shared
            view = NSHostingView(rootView: AnyView(content))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
        }

        func settle(_ ready: () -> Bool) throws {
            // Native applied-content/animation/dismantling barriers drive this
            // bounded AppKit event pump. It is not a delay used to infer success.
            let deadline = Date().addingTimeInterval(3)
            while !ready(), Date() < deadline { turn() }
            guard ready() else { throw HostedSettlementFailure() }
            // Observe a bounded quiet checkpoint after the native receipt.
            for _ in 0..<4 { turn() }
            #expect(ready())
        }

        private func turn() {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            CATransaction.flush()
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    private struct HostedSettlementFailure: Error {}
#endif
