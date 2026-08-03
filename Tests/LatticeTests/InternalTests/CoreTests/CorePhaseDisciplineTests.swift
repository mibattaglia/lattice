// Exit tests exercising the core's loud phase-discipline preconditions directly, below the
// typed handles. Swift Testing exit tests require the 6.2 toolchain and are
// macOS-only in this package.

#if os(macOS)
    import Testing

    @testable import Lattice

    extension CoreTests {
        @Suite
        struct CorePhaseDisciplineTests {

        @Test
        func modifyDuringUpdatePhaseTraps() async {
            await #expect(processExitsWith: .failure) {
                await MainActor.run {
                    let core = makeCore()
                    try? core.send(
                        SAction { _, core in
                            try? core.modify { $0.n = 1 }
                        })
                }
            }
        }

        @Test
        func sendDuringUpdatePhaseTraps() async {
            await #expect(processExitsWith: .failure) {
                await MainActor.run {
                    let core = makeCore()
                    try? core.send(
                        SAction { _, core in
                            try? core.send(SAction { _, _ in })
                        })
                }
            }
        }

        @Test
        func reentrantModifyTraps() async {
            await #expect(processExitsWith: .failure) {
                await MainActor.run {
                    let core = makeCore()
                    try? core.modify { _ in
                        try? core.modify { $0.n = 1 }
                    }
                }
            }
        }

        @Test
        func currentStateReadDuringUpdatePhaseTraps() async {
            await #expect(processExitsWith: .failure) {
                await MainActor.run {
                    let core = makeCore()
                    try? core.send(
                        SAction { _, core in
                            _ = core.currentState
                        })
                }
            }
        }

        @Test
        func launchEffectOutsideUpdatePhaseTraps() async {
            await #expect(processExitsWith: .failure) {
                await MainActor.run {
                    let core = makeCore()
                    core.launchEffect(path: GraphPath(), location: loc(1)) {}
                }
            }
        }
        }
    }
#endif
