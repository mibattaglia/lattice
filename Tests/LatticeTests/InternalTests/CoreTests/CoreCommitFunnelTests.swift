import Testing

@testable import Lattice

extension CoreTests {
    @Suite
    @MainActor
    struct CoreCommitFunnelTests {

        @Test
        func sendRunsInteractOnceAndCommitsOldNew() throws {
            var interactCount = 0
            var committed: [(old: Int, new: Int)] = []
            let core = makeCore(onCommit: { old, new in
                committed.append((old.n, new.n))
            })

            try core.send(
                SAction { state, _ in
                    interactCount += 1
                    state.n = 42
                })

            #expect(interactCount == 1)
            #expect(committed.count == 1)
            #expect(committed[0].old == 0)
            #expect(committed[0].new == 42)
        }

        @Test
        func onCommitFiresOnEveryCommitEvenWithoutMutation() throws {
            var commitCount = 0
            let core = makeCore(onCommit: { _, _ in commitCount += 1 })

            try core.send(SAction { _, _ in })
            try core.send(SAction { _, _ in })

            #expect(commitCount == 2)
        }

        @Test
        func modifyRunsTheFunnel() throws {
            var committed: [(old: Int, new: Int)] = []
            let core = makeCore(onCommit: { old, new in
                committed.append((old.n, new.n))
            })

            try core.modify { $0.n = 7 }

            #expect(core.currentState.n == 7)
            #expect(committed.count == 1)
            #expect(committed[0].old == 0)
            #expect(committed[0].new == 7)
            // No update phase: `modify` never enters `.updating`.
            #expect(core.updateContext == nil)
        }

        /// Pins the commit-origin contract the test host's recorder depends on (plan 07 §2):
        /// the update-phase commit fires synchronously inside `send` with `.send(action)`
        /// origin, **before** any effect's synchronous-prefix `modify` commit can interleave.
        @Test
        func sendCommitCarriesSendOriginAndPrecedesEffectCommits() throws {
            var origins: [String] = []
            let core = TestCore(initialState: S(), isolation: MainActor.shared)
            core.mount(
                interact: { [unowned core] state, action in
                    action.run(&state, core)
                },
                onCommit: { _, new, origin in
                    switch origin {
                    case .send: origins.append("send(\(new.n))")
                    case .modify: origins.append("modify(\(new.n))")
                    }
                }
            )

            try core.send(
                SAction { state, core in
                    state.n = 1
                    core.launchEffect(path: GraphPath(), location: loc(1)) { [weak core] in
                        // Synchronous prefix: commits before 'send' returns, after the
                        // update-phase commit.
                        try? core?.modify { $0.n = 2 }
                    }
                })

            #expect(origins == ["send(1)", "modify(2)"])
        }

        @Test
        func presenceFlipViaSendCancelsChildBucketOnly() async throws {
            let recorder = Recorder()
            let childPath = GraphPath().appending(\S.child)
            let siblingPath = GraphPath().appending(id: 1)
            let core = makeCore(initial: S(n: 0, child: CoreChild()))
            core.registerPresenceWatcher(path: childPath) { $0.child != nil }

            let task = try core.send(
                SAction { _, core in
                    core.launchEffect(path: childPath, location: loc(1)) {
                        do {
                            try await Task.sleep(for: .seconds(100))
                        } catch {
                            recorder.record("child cancelled")
                        }
                    }
                    core.launchEffect(path: siblingPath, location: loc(2)) {
                        do {
                            try await Task.sleep(for: .seconds(100))
                        } catch {
                            recorder.record("sibling cancelled")
                        }
                    }
                })

            try core.send(SAction { state, _ in state.child = nil })

            // The child effect winds down; the sibling is untouched.
            while !recorder.events.contains("child cancelled") {
                await Task.yield()
            }
            #expect(recorder.events == ["child cancelled"])
            #expect(core.hasTasks(at: TaskKey(path: siblingPath, location: loc(2))))
            task?.cancel()
            await task?.value
        }

        @Test
        func presenceFlipViaModifyCancelsIdentically() async throws {
            let recorder = Recorder()
            let childPath = GraphPath().appending(\S.child)
            let core = makeCore(initial: S(n: 0, child: CoreChild()))
            core.registerPresenceWatcher(path: childPath) { $0.child != nil }

            let task = try core.send(
                SAction { _, core in
                    core.launchEffect(path: childPath, location: loc(1)) {
                        do {
                            try await Task.sleep(for: .seconds(100))
                        } catch {
                            recorder.record("cancelled")
                        }
                    }
                })

            try core.modify { $0.child = nil }

            await task?.value
            #expect(recorder.events == ["cancelled"])
        }

        @Test
        func prefixCancellationSparesPositionalSiblings() async throws {
            let recorder = Recorder()
            let parent = GraphPath().appending(\S.child)
            let child = parent.appending(id: 0)
            let sibling = GraphPath().appending(id: 1)
            let core = makeCore()

            let task = try core.send(
                SAction { _, core in
                    core.launchEffect(path: child, location: loc(1)) {
                        do {
                            try await Task.sleep(for: .seconds(100))
                        } catch {
                            recorder.record("child cancelled")
                        }
                    }
                    core.launchEffect(path: sibling, location: loc(2)) {
                        do {
                            try await Task.sleep(for: .seconds(100))
                        } catch {
                            recorder.record("sibling cancelled")
                        }
                    }
                })

            core.cancelTasks(withPrefix: parent)

            while !recorder.events.contains("child cancelled") {
                await Task.yield()
            }
            #expect(recorder.events == ["child cancelled"])
            #expect(core.hasTasks(at: TaskKey(path: sibling, location: loc(2))))
            task?.cancel()
            await task?.value
        }
    }
}
