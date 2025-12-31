import Foundation

/// Records all emissions from an AsyncSequence for test assertions.
@MainActor
public final class AsyncStreamRecorder<Element: Sendable> {
    public private(set) var values: [Element] = []
    private var task: Task<Void, Never>?
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isFinished = false

    public init() {}

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

    public func waitForNextEmission(timeout: Duration = .seconds(5)) async throws {
        try await waitForEmissions(count: values.count + 1, timeout: timeout)
    }

    public func cancel() {
        task?.cancel()
        task = nil
        for waiter in waiters { waiter.continuation.resume() }
        waiters.removeAll()
    }

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

    public var lastValue: Element? { values.last }

    public struct TimeoutError: Error, CustomStringConvertible {
        public let expectedCount: Int
        public let actualCount: Int
        public var description: String {
            "Timed out waiting for \(expectedCount) emissions, only received \(actualCount)"
        }
    }
}
