import Testing

@testable import Lattice

private struct TestError: Error {}

extension CoreTests {
    @Suite
    @MainActor
    struct CoreEffectLaunchTests {

        @Test
        func deferredLaunchOrderingObservesCommittedState() throws {
            let recorder = Recorder()
            let core = makeCore(onCommit: { _, _ in recorder.record("commit") })

            try core.send(
                SAction { state, core in
                    recorder.record("interact")
                    state.n = 1
                    core.launchEffect(path: GraphPath(), location: loc(1)) {
                        // Synchronous prefix: runs after the funnel, observing committed state.
                        recorder.record("effectPrefix n=\(core.currentState.n)")
                    }
                })

            #expect(recorder.events == ["interact", "commit", "effectPrefix n=1"])
        }

        @Test
        func effectPrefixStartsSynchronouslyInDomain() throws {
            let recorder = Recorder()
            let core = makeCore()

            try core.send(
                SAction { _, core in
                    core.launchEffect(path: GraphPath(), location: loc(1)) {
                        MainActor.assertIsolated()
                        recorder.record("prefix")
                        await Task.yield()
                    }
                })

            // The prefix ran before `send` returned.
            #expect(recorder.events == ["prefix"])
        }

        @Test
        func repeatedSendsAtSameSlotReplaceInFlightBucket() async throws {
            let recorder = Recorder()
            let core = makeCore()
            let action = SAction { _, core in
                core.launchEffect(path: GraphPath(), location: loc(1)) {
                    do {
                        try await Task.sleep(for: .seconds(100))
                        recorder.record("finished")
                    } catch {
                        recorder.record("cancelled")
                    }
                }
            }

            let first = try core.send(action)
            let second = try core.send(action)

            // The first task was cancelled by the second send reaching the same slot.
            await first?.value
            #expect(recorder.events == ["cancelled"])
            // The replacement is tracked.
            #expect(core.hasTasks(at: TaskKey(path: GraphPath(), location: loc(1))))
            second?.cancel()
            await second?.value
        }

        @Test
        func twoPerformsAtSameSlotInOneUpdateTrackAlongside() async throws {
            let recorder = Recorder()
            let core = makeCore()

            let task = try core.send(
                SAction { _, core in
                    for index in 0..<2 {
                        core.launchEffect(path: GraphPath(), location: loc(1)) {
                            do {
                                try await Task.sleep(for: .seconds(100))
                            } catch {
                                recorder.record("cancelled \(index)")
                            }
                        }
                    }
                })

            // Both alive: the second launch in the same update tracks, not replaces.
            #expect(core.currentTasks(at: TaskKey(path: GraphPath(), location: loc(1))).count == 2)
            #expect(recorder.events.isEmpty)
            task?.cancel()
            await task?.value
            #expect(recorder.events.sorted() == ["cancelled 0", "cancelled 1"])
        }

        @Test
        func distinctCallSitesInOneUpdateCoexist() async throws {
            let core = makeCore()

            let task = try core.send(
                SAction { _, core in
                    core.launchEffect(path: GraphPath(), location: loc(1)) {
                        try await Task.sleep(for: .seconds(100))
                    }
                    core.launchEffect(path: GraphPath(), location: loc(2)) {
                        try await Task.sleep(for: .seconds(100))
                    }
                })

            #expect(core.hasTasks(at: TaskKey(path: GraphPath(), location: loc(1))))
            #expect(core.hasTasks(at: TaskKey(path: GraphPath(), location: loc(2))))
            task?.cancel()
            await task?.value
        }

        @Test
        func explicitIDAndCallSiteSlotsCoexist() async throws {
            let core = makeCore()

            let task = try core.send(
                SAction { _, core in
                    core.launchEffect(path: GraphPath(), location: .id("x")) {
                        try await Task.sleep(for: .seconds(100))
                    }
                    core.launchEffect(path: GraphPath(), location: loc(1)) {
                        try await Task.sleep(for: .seconds(100))
                    }
                })

            #expect(core.hasTasks(at: TaskKey(path: GraphPath(), location: .id("x"))))
            #expect(core.hasTasks(at: TaskKey(path: GraphPath(), location: loc(1))))
            task?.cancel()
            await task?.value
        }

        @Test
        func selfCancelRaceResolvesViaEarlyCancelledEntry() async throws {
            let recorder = Recorder()
            let childPath = GraphPath().appending(\S.child)
            let core = makeCore(initial: S(n: 0, child: CoreChild()))
            core.registerPresenceWatcher(path: childPath) { $0.child != nil }

            let task = try core.send(
                SAction { _, core in
                    core.launchEffect(path: childPath, location: loc(1)) { [weak core] in
                        // Synchronous prefix flips this effect's own presence watcher, cancelling
                        // its bucket before `attach` has run.
                        try? core?.modify { $0.child = nil }
                        // The cancel landed on the entry box before `attach`: the task handle
                        // itself is not yet cancelled during the synchronous prefix...
                        recorder.record("isCancelled=\(Task.isCancelled)")
                        do {
                            try await Task.sleep(for: .seconds(100))
                            recorder.record("finished")
                        } catch {
                            // ...but cooperative cancellation lands at the next await.
                            recorder.record("cancelled")
                        }
                    }
                })

            await task?.value
            #expect(recorder.events == ["isCancelled=false", "cancelled"])
        }

        @Test
        func synchronousCompletionCleansUpStorage() async throws {
            let recorder = Recorder()
            let core = makeCore()

            let task = try core.send(
                SAction { _, core in
                    core.launchEffect(path: GraphPath(), location: loc(1)) {
                        recorder.record("ran")
                    }
                })

            #expect(!core.hasTasks(at: TaskKey(path: GraphPath(), location: loc(1))))
            let composite = try #require(task)
            await composite.value
            #expect(recorder.events == ["ran"])
        }

        @Test
        func throwingEffectCompletesBookkeepingAndReportsIssue() async throws {
            let core = makeCore()

            var task: Task<Void, Never>??
            await withKnownIssue(isolation: #isolation) {
                task = try? core.send(
                    SAction { _, core in
                        core.launchEffect(path: GraphPath(), location: loc(1)) {
                            await Task.yield()
                            throw TestError()
                        }
                    })
                await task??.value
            }

            #expect(!core.hasTasks(at: TaskKey(path: GraphPath(), location: loc(1))))
            #expect(task! != nil)
        }
    }
}
