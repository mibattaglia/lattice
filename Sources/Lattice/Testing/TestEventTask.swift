import Foundation

public struct TestEventTask: Sendable {
    private let cancelOperation: @Sendable () async -> Void
    private let finishOperation:
        @Sendable (
            Duration?,
            StaticString,
            StaticString,
            UInt,
            UInt
        ) async -> Void
    private let isCancelledOperation: @Sendable () -> Bool

    init(
        cancelOperation: @escaping @Sendable () async -> Void = {},
        finishOperation: @escaping @Sendable (
            Duration?,
            StaticString,
            StaticString,
            UInt,
            UInt
        ) async -> Void = { _, _, _, _, _ in },
        isCancelledOperation: @escaping @Sendable () -> Bool = { false }
    ) {
        self.cancelOperation = cancelOperation
        self.finishOperation = finishOperation
        self.isCancelledOperation = isCancelledOperation
    }

    public func cancel() async {
        await cancelOperation()
    }

    public func finish(
        timeout: Duration? = nil,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        await finishOperation(timeout, fileID, file, line, column)
    }

    public var isCancelled: Bool {
        isCancelledOperation()
    }
}
