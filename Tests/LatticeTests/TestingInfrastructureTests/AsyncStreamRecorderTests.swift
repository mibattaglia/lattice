import Testing

@testable import Lattice

@Suite
struct AsyncStreamRecorderTests {
    @Test
    @MainActor
    func recordsEmissions() async throws {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let recorder = AsyncStreamRecorder<Int>()

        recorder.record(stream)

        continuation.yield(1)
        continuation.yield(2)
        continuation.yield(3)

        try await recorder.waitForEmissions(count: 3)
        #expect(recorder.values == [1, 2, 3])

        continuation.finish()
    }
}
