import Foundation

/// Records all emissions from an AsyncSequence for test assertions.
///
/// `AsyncStreamRecorder` captures values emitted from async streams, enabling
/// assertions about the sequence of emissions in tests.
///
/// ## Usage
///
/// ```swift
/// @Test
/// func testEmissions() async throws {
///     let recorder = AsyncStreamRecorder<Int>()
///     let stream = AsyncStream { continuation in
///         continuation.yield(1)
///         continuation.yield(2)
///         continuation.finish()
///     }
///
///     await recorder.record(stream)
///     try await recorder.waitForEmissions(count: 2)
///
///     #expect(recorder.values == [1, 2])
/// }
/// ```
///
/// ## Waiting for Emissions
///
/// Use `waitForEmissions(count:timeout:)` to wait for a specific number of values:
///
/// ```swift
/// try await recorder.waitForEmissions(count: 3, timeout: .seconds(5))
/// ```
///
/// - Note: Typically used internally by ``InteractorTestHarness``.
@MainActor
public final class AsyncStreamRecorder<Element: Sendable> {
    /// All recorded values in order of emission.
    public private(set) var values: [Element] = []
    private var task: Task<Void, Never>?
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isFinished = false

    /// Creates a new recorder.
    public init() {}

    /// Starts recording emissions from an async sequence.
    ///
    /// - Parameter sequence: The async sequence to record.
    public func record<S: AsyncSequence & Sendable>(_ sequence: S) where S.Element == Element {
        task = Task { [weak self] in
            do {
                for try await element in sequence {
                    guard let self else { return }
                    await MainActor.run {
                        self.append(element)
                    }
                }
                await MainActor.run { [weak self] in
                    self?.markFinished()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.markFinished()
                }
            }
        }
    }

    private func append(_ element: Element) {
        values.append(element)
        checkWaiters()
    }

    private func markFinished() {
        isFinished = true
        checkWaiters()
    }

    /// Waits until at least `count` emissions have been recorded.
    ///
    /// - Parameters:
    ///   - count: The minimum number of emissions to wait for.
    ///   - timeout: Maximum time to wait before throwing an error.
    /// - Throws: `TimeoutError` if the timeout expires before enough emissions arrive.
    public func waitForEmissions(count: Int, timeout: Duration = .seconds(5)) async throws {
        if values.count >= count || isFinished { return }

        let currentCount = values.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { [weak self] continuation in
                    Task { @MainActor [weak self] in
                        self?.addWaiter(count: count, continuation: continuation)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError(expectedCount: count, actualCount: currentCount)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func addWaiter(count: Int, continuation: CheckedContinuation<Void, Never>) {
        if values.count >= count || isFinished {
            continuation.resume()
        } else {
            waiters.append((count: count, continuation: continuation))
        }
    }

    /// Waits for the next emission after the current count.
    ///
    /// - Parameter timeout: Maximum time to wait.
    /// - Throws: `TimeoutError` if the timeout expires.
    public func waitForNextEmission(timeout: Duration = .seconds(5)) async throws {
        try await waitForEmissions(count: values.count + 1, timeout: timeout)
    }

    /// Cancels the recording task and resumes any waiters.
    public func cancel() {
        task?.cancel()
        task = nil
        for waiter in waiters { waiter.continuation.resume() }
        waiters.removeAll()
    }

    /// Cancels the recording from a non-isolated context.
    public nonisolated func cancelAsync() {
        Task { @MainActor in
            self.cancel()
        }
    }

    private func checkWaiters() {
        waiters.removeAll { waiter in
            if values.count >= waiter.count || isFinished {
                waiter.continuation.resume()
                return true
            }
            return false
        }
    }

    /// The most recent recorded value, or `nil` if no values have been recorded.
    public var lastValue: Element? { values.last }

    /// Error thrown when waiting for emissions times out.
    public struct TimeoutError: Error, CustomStringConvertible {
        public let expectedCount: Int
        public let actualCount: Int
        public var description: String {
            "Timed out waiting for \(expectedCount) emissions, only received \(actualCount)"
        }
    }
}
