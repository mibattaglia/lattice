import Testing

@testable import Lattice

@Suite
@MainActor
struct EffectsHandleTests {

    // Phase discipline is enforced by type — these are the compile-time negatives:
    //
    //     effects.modify { $0.n = 1 }        // ❌ 'Effects' has no member 'modify'
    //     effects.send(action)               // ❌ 'Effects' has no member 'send'
    //     _ = effects.state                  // ❌ 'Effects' has no member 'state'
    //     effectState.perform { _ in }       // ❌ 'EffectState' has no member 'perform'
    //
    // The runtime backstops for smuggled handles are covered below and in
    // `EffectsHandleBackstopExitTests`.

    @Test
    func performLaunchesWithSynchronousHeadStart() throws {
        let recorder = Recorder()
        let (core, _) = makeHandleCore(onCommit: { _, _ in recorder.record("commit") })

        try core.send(
            HandleAction { state, effects in
                recorder.record("interact")
                state.n = 1
                effects.perform { effectState in
                    // Synchronous prefix: runs in-domain before `send` returns, observing
                    // committed state; a mutation made before the first await is visible
                    // immediately after `send` returns.
                    MainActor.assertIsolated()
                    recorder.record("prefix n=\(effectState.state.n)")
                    try effectState.modify { $0.n = 2 }
                }
            })

        #expect(recorder.events == ["interact", "commit", "prefix n=1", "commit"])
        #expect(core.currentState.n == 2)
    }

    @Test
    func modifyFromEffectRunsFullFunnel() async throws {
        var commits: [(Int, Int)] = []
        let gate = Gate()
        let (core, _) = makeHandleCore(onCommit: { old, new in commits.append((old.n, new.n)) })

        let task = try core.send(
            HandleAction { _, effects in
                effects.perform { effectState in
                    await gate.wait()
                    try effectState.modify { $0.n = 7 }
                }
            })

        gate.open()
        await task?.value
        #expect(core.currentState.n == 7)
        // One commit for the update itself, one for the effect's `modify`.
        #expect(commits.map(\.1) == [0, 7])
    }

    @Test
    func sendFromEffectDispatchesFreshUpdate() async throws {
        let recorder = Recorder()
        let (core, _) = makeHandleCore()

        let followUp = HandleAction { state, _ in
            recorder.record("followUp")
            state.n = 42
        }
        let task = try core.send(
            HandleAction { _, effects in
                effects.perform { effectState in
                    await Task.yield()
                    try effectState.send(followUp)
                }
            })

        await task?.value
        #expect(recorder.events == ["followUp"])
        #expect(core.currentState.n == 42)
    }

    @Test
    func stateReflectsMutationsMadeAfterLaunch() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let (core, _) = makeHandleCore()

        let task = try core.send(
            HandleAction { _, effects in
                effects.perform { effectState in
                    recorder.record("before n=\(effectState.state.n)")
                    await gate.wait()
                    recorder.record("after n=\(effectState.state.n)")
                }
            })

        try core.send(HandleAction { state, _ in state.n = 5 })
        gate.open()
        await task?.value
        #expect(recorder.events == ["before n=0", "after n=5"])
    }

    @Test
    func performOutsideUpdatePhaseReportsIssueAndLaunchesNothing() throws {
        let (core, effects) = makeHandleCore()

        withKnownIssue {
            effects.perform { _ in }
        }

        #expect(!core.hasTasks(at: TaskKey(path: GraphPath(), location: anyCallSite)))
        _ = core
    }

    @Test
    func performOnDismountedCoreReportsIssueAndLaunchesNothing() throws {
        let (core, effects) = makeHandleCore()
        core.dismount()

        withKnownIssue {
            effects.perform { _ in }
        }
    }

    @Test
    func modifyAndSendAfterDismountThrowCancellationError() throws {
        let (core, effects) = makeHandleCore()
        let effectState = effects.effectState
        core.dismount()

        withKnownIssue {
            #expect(throws: CancellationError.self) {
                try effectState.modify { $0.n = 1 }
            }
        }
        withKnownIssue {
            #expect(throws: CancellationError.self) {
                try effectState.send(HandleAction { _, _ in })
            }
        }
    }

    @Test
    func dismountedReentryFromCancelledTaskIsSilent() async throws {
        let (core, effects) = makeHandleCore()
        let effectState = effects.effectState
        core.dismount()

        // Inside an already-cancelled task the throw stays, but no issue is reported —
        // the normal teardown race.
        let task = Task { @MainActor in
            while !Task.isCancelled {
                await Task.yield()
            }
            #expect(throws: CancellationError.self) {
                try effectState.modify { $0.n = 1 }
            }
        }
        task.cancel()
        await task.value
    }

    @Test
    func stateFallsBackToSnapshotOnceCoreIsGone() throws {
        var core: HandleCore?
        var effects: Effects<HandleState, HandleAction>?
        (core, effects) = makeHandleCore(initial: HandleState(n: 9))
        let effectState = effects!.effectState

        // Populate the handle's snapshot while the core is alive.
        #expect(effectState.state.n == 9)

        effects = nil
        core = nil
        withKnownIssue {
            #expect(effectState.state.n == 9)
        }
        _ = core
    }

    @Test
    func stateReadStaysLiveAfterDismount() throws {
        let (core, effects) = makeHandleCore(initial: HandleState(n: 3))
        let effectState = effects.effectState
        core.dismount()

        // Dismount cancels work but does not destroy state; the read is live and reported.
        withKnownIssue {
            #expect(effectState.state.n == 3)
        }
    }

    @Test
    func subscriptWriteRunsOneFunnelPassPerAssignment() async throws {
        var commitCount = 0
        let gate = Gate()
        let (core, _) = makeHandleCore(onCommit: { _, _ in commitCount += 1 })

        let task = try core.send(
            HandleAction { _, effects in
                effects.perform { effectState in
                    await gate.wait()
                    effectState.n = 1
                    effectState.text = "a"
                }
            })

        gate.open()
        await task?.value
        // One commit for the (unchanged-state) update, then one per subscript assignment.
        #expect(commitCount == 3)
        #expect(core.currentState.n == 1)
        #expect(core.currentState.text == "a")
    }

    @Test
    func subscriptMatchesSingleAssignmentModify() async throws {
        var subscriptCommits: [Int] = []
        let (core, _) = makeHandleCore(onCommit: { _, new in subscriptCommits.append(new.n) })
        let task = try core.send(
            HandleAction { _, effects in
                effects.perform { $0.n = 11 }
            })
        await task?.value

        var modifyCommits: [Int] = []
        let (core2, _) = makeHandleCore(onCommit: { _, new in modifyCommits.append(new.n) })
        let task2 = try core2.send(
            HandleAction { _, effects in
                effects.perform { effectState in
                    try effectState.modify { $0.n = 11 }
                }
            })
        await task2?.value

        #expect(subscriptCommits == modifyCommits)
        #expect(core.currentState.n == core2.currentState.n)
    }

    @Test
    func subscriptReadEqualsStateRead() async throws {
        let recorder = Recorder()
        let (core, _) = makeHandleCore(initial: HandleState(n: 4))

        let task = try core.send(
            HandleAction { _, effects in
                effects.perform { effectState in
                    recorder.record("subscript=\(effectState.n) state=\(effectState.state.n)")
                }
            })
        await task?.value
        #expect(recorder.events == ["subscript=4 state=4"])
    }

    @Test
    func subscriptWriteAfterDismountIsDroppedWithoutThrowing() throws {
        var commitCount = 0
        let (core, effects) = makeHandleCore(onCommit: { _, _ in commitCount += 1 })
        let effectState = effects.effectState
        core.dismount()

        // No throw — the subscript swallows the dismount `CancellationError`; the write is
        // dropped (the dismounted-handle issue report still fires, as for `modify`).
        withKnownIssue {
            effectState.n = 99
        }
        #expect(commitCount == 0)
        #expect(core.currentState.n == 0)
    }
}

/// A helper matching no real slot — used to assert nothing was launched.
private var anyCallSite: EffectLocation { .callSite(fileID: "none", line: 0, column: 0) }

// Exit tests for the smuggled-handle runtime backstops: an `EffectState` captured out of its
// effect and used during the update phase trips the named preconditions. Swift Testing
// exit tests are macOS-only in this package.
#if os(macOS)
    @Suite
    struct EffectsHandleBackstopExitTests {

        @Test
        func smuggledModifyDuringUpdatePhaseTraps() async {
            await #expect(processExitsWith: .failure) {
                await MainActor.run {
                    let (core, effects) = makeHandleCore()
                    let smuggled = effects.effectState
                    try? core.send(
                        HandleAction { _, _ in
                            try? smuggled.modify { $0.n = 1 }
                        })
                }
            }
        }

        @Test
        func smuggledSendDuringUpdatePhaseTraps() async {
            await #expect(processExitsWith: .failure) {
                await MainActor.run {
                    let (core, effects) = makeHandleCore()
                    let smuggled = effects.effectState
                    try? core.send(
                        HandleAction { _, _ in
                            try? smuggled.send(HandleAction { _, _ in })
                        })
                }
            }
        }

        @Test
        func smuggledStateReadDuringUpdatePhaseTraps() async {
            await #expect(processExitsWith: .failure) {
                await MainActor.run {
                    let (core, effects) = makeHandleCore()
                    let smuggled = effects.effectState
                    try? core.send(
                        HandleAction { _, _ in
                            _ = smuggled.state
                        })
                }
            }
        }

        @Test
        func smuggledSubscriptWriteDuringUpdatePhaseTraps() async {
            await #expect(processExitsWith: .failure) {
                await MainActor.run {
                    let (core, effects) = makeHandleCore()
                    let smuggled = effects.effectState
                    try? core.send(
                        HandleAction { _, _ in
                            smuggled.n = 1
                        })
                }
            }
        }
    }
#endif
