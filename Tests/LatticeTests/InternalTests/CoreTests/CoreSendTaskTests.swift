import Testing

@testable import Lattice

extension CoreTests {
    @Suite
    @MainActor
    struct CoreSendTaskTests {

        @Test
        func sendWithNoEffectsReturnsNil() throws {
            let core = makeCore()
            let task = try core.send(SAction { state, _ in state.n = 1 })
            #expect(task == nil)
        }

        @Test
        func compositeTaskCompletesOnlyAfterEveryEffect() async throws {
            let recorder = Recorder()
            let gateA = Gate()
            let gateB = Gate()
            let core = makeCore()

            let composite = try #require(
                try core.send(
                    SAction { _, core in
                        core.launchEffect(path: GraphPath(), location: loc(1)) {
                            await gateA.wait()
                            recorder.record("A done")
                        }
                        core.launchEffect(path: GraphPath(), location: loc(2)) {
                            await gateB.wait()
                            recorder.record("B done")
                        }
                    }))

            var compositeDone = false
            let observer = Task { @MainActor in
                await composite.value
                compositeDone = true
            }

            gateA.open()
            for _ in 0..<20 { await Task.yield() }
            #expect(recorder.events == ["A done"])
            #expect(!compositeDone)

            gateB.open()
            await observer.value
            #expect(compositeDone)
            #expect(recorder.events == ["A done", "B done"])
        }

        @Test
        func compositeCoversDirectEffectsOnly() async throws {
            let recorder = Recorder()
            let gate = Gate()
            let core = makeCore()
            var reentrantTask: Task<Void, Never>??

            let secondAction = SAction { _, core in
                core.launchEffect(path: GraphPath(), location: loc(2)) {
                    await gate.wait()
                    recorder.record("second effect done")
                }
            }

            let composite = try #require(
                try core.send(
                    SAction { _, core in
                        core.launchEffect(path: GraphPath(), location: loc(1)) { [weak core] in
                            await Task.yield()
                            // Re-entrant send starts an independent unit with its own task.
                            reentrantTask = try? core?.send(secondAction)
                            recorder.record("first effect done")
                        }
                    }))

            // The original send's composite completes without awaiting the second effect.
            await composite.value
            #expect(recorder.events == ["first effect done"])
            #expect(core.hasTasks(at: TaskKey(path: GraphPath(), location: loc(2))))

            // The re-entrant send returned its own task covering the second effect.
            let second = try #require(reentrantTask ?? nil)
            gate.open()
            await second.value
            #expect(recorder.events == ["first effect done", "second effect done"])
        }

        @Test
        func cancellingCompositeCancelsInFlightEffects() async throws {
            let recorder = Recorder()
            let core = makeCore()

            let composite = try #require(
                try core.send(
                    SAction { _, core in
                        core.launchEffect(path: GraphPath(), location: loc(1)) {
                            do {
                                try await Task.sleep(for: .seconds(100))
                                recorder.record("finished")
                            } catch {
                                recorder.record("cancelled 1")
                            }
                        }
                        core.launchEffect(path: GraphPath(), location: loc(2)) {
                            do {
                                try await Task.sleep(for: .seconds(100))
                                recorder.record("finished")
                            } catch {
                                recorder.record("cancelled 2")
                            }
                        }
                    }))

            composite.cancel()
            // The composite completes once the effects wind down.
            await composite.value
            #expect(recorder.events.sorted() == ["cancelled 1", "cancelled 2"])
        }

        @Test
        func concurrentSendsReturnIndependentTasks() async throws {
            let recorder = Recorder()
            let gate = Gate()
            let core = makeCore()

            let first = try #require(
                try core.send(
                    SAction { _, core in
                        core.launchEffect(path: GraphPath(), location: loc(1)) {
                            do {
                                try await Task.sleep(for: .seconds(100))
                            } catch {
                                recorder.record("first cancelled")
                            }
                        }
                    }))
            let second = try #require(
                try core.send(
                    SAction { _, core in
                        core.launchEffect(path: GraphPath(), location: loc(2)) {
                            await gate.wait()
                            recorder.record("second done")
                        }
                    }))

            first.cancel()
            await first.value
            #expect(recorder.events == ["first cancelled"])
            // The second send's effect is unaffected by cancelling the first's task.
            #expect(core.hasTasks(at: TaskKey(path: GraphPath(), location: loc(2))))

            gate.open()
            await second.value
            #expect(recorder.events == ["first cancelled", "second done"])
        }
    }
}
