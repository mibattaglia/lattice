import Testing

@testable import Lattice

@Suite
@MainActor
struct RootScopeTasksTests {
    @MainActor
    final class Probe {
        var rootScopes: [SendScopeID: RootScopeState] = [:]
        var cancelledScopeIDs: [SendScopeID] = []

        func isQuiescent(_ rootScopeID: SendScopeID) -> Bool {
            rootScopes[rootScopeID]?.isQuiescent ?? true
        }

        func cancelScope(_ rootScopeID: SendScopeID) {
            cancelledScopeIDs.append(rootScopeID)
            rootScopes[rootScopeID] = .init()
        }
    }

    @MainActor
    final class FinishProbe {
        var didFinish = false
    }

    @Test
    func taskWaitsForScopeToBecomeQuiescent() async {
        let probe = Probe()
        let finishProbe = FinishProbe()
        let rootScopeID = SendScopeID()

        probe.rootScopes[rootScopeID] = .init(bufferedActionCount: 1)

        let task = RootScopeTasks.makeTask(
            rootScopeID: rootScopeID,
            isQuiescent: { probe.isQuiescent($0) },
            cancelScope: { probe.cancelScope($0) }
        )

        let observer = Task { @MainActor in
            await task.value
            finishProbe.didFinish = true
        }

        await Task.yield()
        #expect(finishProbe.didFinish == false)

        probe.rootScopes[rootScopeID] = .init()

        await observer.value
        #expect(finishProbe.didFinish)
        #expect(probe.cancelledScopeIDs.isEmpty)
    }

    @Test
    func cancellationInvokesScopeCancellation() async {
        let probe = Probe()
        let rootScopeID = SendScopeID()

        probe.rootScopes[rootScopeID] = .init(inFlightEffectIDs: [LegacyEffectID()])

        let task = RootScopeTasks.makeTask(
            rootScopeID: rootScopeID,
            isQuiescent: { probe.isQuiescent($0) },
            cancelScope: { probe.cancelScope($0) }
        )

        task.cancel()
        await task.value

        #expect(probe.cancelledScopeIDs == [rootScopeID])
        #expect(probe.rootScopes[rootScopeID]?.isQuiescent == true)
    }

    @Test
    func quiescentScopeCompletesImmediately() async {
        let probe = Probe()
        let rootScopeID = SendScopeID()

        let task = RootScopeTasks.makeTask(
            rootScopeID: rootScopeID,
            isQuiescent: { probe.isQuiescent($0) },
            cancelScope: { probe.cancelScope($0) }
        )

        await task.value

        #expect(probe.cancelledScopeIDs.isEmpty)
    }
}
