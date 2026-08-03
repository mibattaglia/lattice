import Testing

@testable import Lattice

extension CoreTests {
    @Suite
    @MainActor
    struct CoreDismountTests {

        @Test
        func dismountCancelsTasksAndPoisonsEntryPoints() async throws {
            let recorder = Recorder()
            let core = makeCore()

            let composite = try #require(
                try core.send(
                    SAction { _, core in
                        core.launchEffect(path: GraphPath(), location: loc(1)) {
                            do {
                                try await Task.sleep(for: .seconds(100))
                            } catch {
                                recorder.record("cancelled")
                            }
                        }
                    }))

            core.dismount()
            #expect(core.isDismounted)

            // Outstanding composite send tasks complete as effects wind down — no hang.
            await composite.value
            #expect(recorder.events == ["cancelled"])

            #expect(throws: CancellationError.self) {
                try core.send(SAction { _, _ in })
            }
            #expect(throws: CancellationError.self) {
                try core.modify { $0.n = 1 }
            }
        }

        @Test
        func dismountIsIdempotent() throws {
            let core = makeCore()
            core.dismount()
            core.dismount()
            #expect(core.isDismounted)
        }

        @Test
        func deinitCancelsSuspendedEffectsThroughDeadWeakReference() async throws {
            let recorder = Recorder()
            var core: TestCore? = makeCore()

            let composite = try #require(
                try core?.send(
                    SAction { _, core in
                        core.launchEffect(path: GraphPath(), location: loc(1)) {
                            do {
                                try await Task.sleep(for: .seconds(100))
                            } catch {
                                recorder.record("cancelled")
                            }
                        }
                    }))

            // Release the core while the effect is suspended: `deinit` cancels the storage; the
            // effect's completion callback no-ops through the dead weak reference (no crash).
            core = nil

            await composite.value
            #expect(recorder.events == ["cancelled"])
        }
    }
}
