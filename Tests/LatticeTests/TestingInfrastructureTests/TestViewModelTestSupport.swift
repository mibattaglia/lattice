import Testing

@MainActor
func expectTestFailure(
    containing expectedMessage: String,
    _ operation: @escaping @MainActor () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected TestFailure containing: \(expectedMessage)")
    } catch {
        #expect(String(describing: error).contains(expectedMessage))
    }
}
