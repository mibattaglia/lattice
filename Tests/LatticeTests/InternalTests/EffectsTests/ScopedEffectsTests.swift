import CasePaths
import Testing

@testable import Lattice

// The navigation-dismissed-mid-request contract: exact drop semantics for scoped effects.
// Serialized: `_EffectsDiagnostics.onDroppedReentry` is a single global hook, so the tests
// that install a `DropHookRecorder` must not overlap.
@Suite(.serialized)
@MainActor
struct ScopedEffectsTests {

    @Test
    func parentLeavingCaseCancelsChildBucketViaFunnel() async throws {
        let recorder = Recorder()
        let core = makeScopedCore(initial: ScopedParentState(destination: .detail(ScopedChildState())))
        let childEffects = _makeEffectsHandles(core: core, lens: scopedChildLens, path: scopedChildPath)

        let task = try core.send(
            .run { _ in
                childEffects.perform { _ in
                    do {
                        try await Task.sleep(for: .seconds(100))
                    } catch {
                        recorder.record("cancelled")
                    }
                }
            })

        // Parent leaves the child's case: transition detection cancels the child's bucket.
        try core.send(.run { $0.destination = nil })
        await task?.value
        #expect(recorder.events == ["cancelled"])
    }

    #if DEBUG
        @Test
        func stragglerModifyAfterCaseDepartureIsDroppedSilently() async throws {
            let hook = DropHookRecorder()
            var commitCount = 0
            let gate = Gate()
            let core = makeScopedCore(
                initial: ScopedParentState(destination: .detail(ScopedChildState())),
                onCommit: { _, _ in commitCount += 1 }
            )
            let childEffects = _makeEffectsHandles(
                core: core, lens: scopedChildLens, path: scopedChildPath)

            let task = try core.send(
                .run { _ in
                    childEffects.perform { effectState in
                        await gate.wait()
                        // Straggler: the case departed while we were suspended.
                        try effectState.modify { $0.value = 99 }
                    }
                })

            try core.send(.run { $0.destination = .other })
            let commitsBeforeStraggler = commitCount
            gate.open()
            await task?.value

            // State unchanged, no commit funnel run, no throw; hook fired with the child path.
            if case .other? = core.currentState.destination {
            } else {
                Issue.record("expected '.other' destination")
            }
            #expect(commitCount == commitsBeforeStraggler)
            #expect(hook.drops.count == 1)
            #expect(hook.drops.first?.kind == .modify)
            #expect(hook.drops.first?.path == scopedChildPath)
        }

        @Test
        func stragglerSendAfterCaseDepartureIsDroppedSilently() async throws {
            let hook = DropHookRecorder()
            let recorder = Recorder()
            let gate = Gate()
            let core = makeScopedCore(
                initial: ScopedParentState(destination: .detail(ScopedChildState())),
                onChildAction: { recorder.record("child \($0)") }
            )
            let childEffects = _makeEffectsHandles(
                core: core, lens: scopedChildLens, path: scopedChildPath)

            let task = try core.send(
                .run { _ in
                    childEffects.perform { effectState in
                        await gate.wait()
                        let reentry = try effectState.send(.ping)
                        #expect(reentry == nil)
                    }
                })

            try core.send(.run { $0.destination = nil })
            gate.open()
            await task?.value

            // No parent action observed; hook fired with `.send`.
            #expect(recorder.events.isEmpty)
            #expect(hook.drops.count == 1)
            #expect(hook.drops.first?.kind == .send)
            #expect(hook.drops.first?.path == scopedChildPath)
        }

        @Test
        func subscriptWriteAfterCaseDepartureIsDroppedSilently() async throws {
            let hook = DropHookRecorder()
            var commitCount = 0
            let gate = Gate()
            let core = makeScopedCore(
                initial: ScopedParentState(destination: .detail(ScopedChildState())),
                onCommit: { _, _ in commitCount += 1 }
            )
            let childEffects = _makeEffectsHandles(
                core: core, lens: scopedChildLens, path: scopedChildPath)

            let task = try core.send(
                .run { _ in
                    childEffects.perform { effectState in
                        await gate.wait()
                        effectState.value = 99  // no throw, no funnel run
                    }
                })

            try core.send(.run { $0.destination = nil })
            let commitsBeforeStraggler = commitCount
            gate.open()
            await task?.value

            #expect(commitCount == commitsBeforeStraggler)
            #expect(hook.drops.first?.kind == .modify)
        }
    #endif

    @Test
    func optionalNilingBehavesIdentically() async throws {
        // The optional scope: `\.destination` nil'd (rather than flipped to another case).
        let recorder = Recorder()
        let gate = Gate()
        let core = makeScopedCore(initial: ScopedParentState(destination: .detail(ScopedChildState())))
        let childEffects = _makeEffectsHandles(core: core, lens: scopedChildLens, path: scopedChildPath)

        let task = try core.send(
            .run { _ in
                childEffects.perform { effectState in
                    do {
                        try await Task.sleep(for: .seconds(100))
                    } catch {
                        recorder.record("cancelled")
                    }
                    await gate.wait()
                    try effectState.modify { $0.value = 99 }
                }
            })

        try core.send(.run { $0.destination = nil })
        gate.open()
        await task?.value
        #expect(recorder.events == ["cancelled"])
        #expect(core.currentState.destination == nil)
    }

    @Test
    func keyPathScopedChildNeverDrops() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let core = makeScopedCore(
            onChildAction: { recorder.record("child \($0)") }
        )
        let directLens = ScopedLensRoot.identity.appending(
            state: \ScopedParentState.direct, action: scopedChildActionCase)
        let directPath = GraphPath().appending(\ScopedParentState.direct)
        let directEffects = _makeEffectsHandles(core: core, lens: directLens, path: directPath)

        let task = try core.send(
            .run { _ in
                directEffects.perform { effectState in
                    await gate.wait()
                    try effectState.modify { $0.value = 5 }
                    try effectState.send(.ping)
                }
            })

        try core.send(.run { $0.destination = nil })  // unrelated churn
        gate.open()
        await task?.value

        // Struct scope is always present: `modify` writes through, `send` embeds.
        #expect(core.currentState.direct.value == 5)
        #expect(recorder.events == ["child ping"])
    }

    @Test
    func nestedScopeDropDetectedAtDepartedLevelAndPrefixCancelled() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let core = makeScopedCore(initial: ScopedParentState(destination: .detail(ScopedChildState())))

        // A grandchild scope under the enum child: key-path lens onto the child's value.
        let valueCase = AnyCasePath<ScopedChildAction, ScopedChildAction>(
            embed: { $0 }, extract: { $0 })
        let grandLens = scopedChildLens.appending(
            state: \ScopedChildState.value, action: valueCase)
        let grandPath = scopedChildPath.appending(\ScopedChildState.value)
        let grandEffects = _makeEffectsHandles(core: core, lens: grandLens, path: grandPath)

        #if DEBUG
            let hook = DropHookRecorder()
        #endif
        let task = try core.send(
            .run { _ in
                grandEffects.perform { effectState in
                    do {
                        try await Task.sleep(for: .seconds(100))
                    } catch {
                        recorder.record("cancelled")
                    }
                    await gate.wait()
                    // Straggler: drops because the chain is broken at the departed child level.
                    try effectState.modify { $0 = 99 }
                }
            })

        // Departing the child's case cancels the grandchild's bucket by path prefix.
        try core.send(.run { $0.destination = .other })
        gate.open()
        await task?.value

        #expect(recorder.events == ["cancelled"])
        #if DEBUG
            #expect(hook.drops.first?.kind == .modify)
            #expect(hook.drops.first?.path == grandPath)
        #endif
    }

    @Test
    func caseReenteredAfterDepartureFreshTasksLaunchOldStragglerStillDropped() async throws {
        let recorder = Recorder()
        let gate = Gate()
        var commitCount = 0
        let core = makeScopedCore(
            initial: ScopedParentState(destination: .detail(ScopedChildState())),
            onCommit: { _, _ in commitCount += 1 }
        )
        let childEffects = _makeEffectsHandles(core: core, lens: scopedChildLens, path: scopedChildPath)

        let straggler = try core.send(
            .run { _ in
                childEffects.perform { effectState in
                    await gate.wait()
                    // Runs while the case is departed: dropped, its task already dead.
                    try effectState.modify { $0.value = 99 }
                    recorder.record("straggler done")
                }
            })

        try core.send(.run { $0.destination = nil })
        let commitsBeforeStraggler = commitCount
        gate.open()
        await straggler?.value
        #expect(recorder.events == ["straggler done"])
        #expect(commitCount == commitsBeforeStraggler)

        // Re-enter the case: new dispatches launch fresh tasks under the same path.
        try core.send(.run { $0.destination = .detail(ScopedChildState()) })
        let fresh = try core.send(
            .run { _ in
                childEffects.perform { effectState in
                    await Task.yield()
                    try effectState.modify { $0.value = 1 }
                }
            })
        await fresh?.value

        if case .detail(let child)? = core.currentState.destination {
            #expect(child.value == 1)
        } else {
            Issue.record("expected '.detail' destination")
        }
    }
}
