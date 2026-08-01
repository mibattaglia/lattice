import Clocks
import Testing

@testable import Lattice

@Suite
@MainActor
struct EffectCancellationTests {

    @Test
    func samePerformCallSiteReplacesAcrossDispatches() async throws {
        let recorder = Recorder()
        let (core, _) = makeHandleCore()

        let action = HandleAction { _, effects in
            effects.perform { _ in
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

        // The second dispatch reached the same `perform` line: the first task was replaced.
        await first?.value
        #expect(recorder.events == ["cancelled"])
        second?.cancel()
        await second?.value
    }

    @Test
    func distinctPerformCallSitesInOneUpdateBothComplete() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let (core, _) = makeHandleCore()

        let task = try core.send(
            HandleAction { _, effects in
                effects.perform { _ in
                    await gate.wait()
                    recorder.record("a")
                }
                effects.perform { _ in
                    await gate.wait()
                    recorder.record("b")
                }
            })

        gate.open()
        await task?.value
        #expect(recorder.events.sorted() == ["a", "b"])
    }

    @Test
    func distinctEffectIDsAtOneCallSiteDoNotReplaceEachOther() async throws {
        let recorder = Recorder()
        let (core, _) = makeHandleCore()
        let first = EffectID(name: "first")
        let second = EffectID(name: "second")

        func launch(_ id: EffectID) -> HandleAction {
            HandleAction { _, effects in
                effects.perform(id: id) { _ in
                    do {
                        try await Task.sleep(for: .seconds(100))
                    } catch {
                        recorder.record("cancelled \(id.name ?? "?")")
                    }
                }
            }
        }

        let taskA = try core.send(launch(first))
        let taskB = try core.send(launch(second))

        // Same call site, different ids: both in flight.
        #expect(first.isRunning)
        #expect(second.isRunning)
        #expect(recorder.events.isEmpty)

        // Same id re-reaching the same line replaces its predecessor.
        let taskC = try core.send(launch(first))
        await taskA?.value
        #expect(recorder.events == ["cancelled first"])
        #expect(first.isRunning)
        #expect(second.isRunning)

        taskB?.cancel()
        taskC?.cancel()
        await taskB?.value
        await taskC?.value
    }

    @Test
    func sameCallSiteWithNoIDReplacesAcrossDispatches() async throws {
        let recorder = Recorder()
        let (core, _) = makeHandleCore()

        let action = HandleAction { _, effects in
            effects.perform { _ in
                do {
                    try await Task.sleep(for: .seconds(100))
                } catch {
                    recorder.record("cancelled")
                }
            }
        }

        let first = try core.send(action)
        let second = try core.send(action)
        await first?.value
        #expect(recorder.events == ["cancelled"])
        second?.cancel()
        await second?.value
    }

    @Test
    func debounceByReplacementWithTestClock() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let (core, _) = makeHandleCore()

        func queryChanged(_ query: String) -> HandleAction {
            HandleAction { state, effects in
                state.text = query  // state mutation is immediate
                effects.perform { effectState in
                    // Previous keystroke's task is cancelled (same `perform` line).
                    try await clock.sleep(for: .milliseconds(300))
                    recorder.record("search \(effectState.state.text)")
                }
            }
        }

        _ = try core.send(queryChanged("s"))
        _ = try core.send(queryChanged("sw"))
        let last = try core.send(queryChanged("swi"))

        await clock.advance(by: .milliseconds(300))
        await last?.value

        // Exactly one search executed, for the final query.
        #expect(recorder.events == ["search swi"])
    }
}
