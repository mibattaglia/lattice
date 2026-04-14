enum RootScopeTasks {
    @MainActor
    static func makeTask(
        rootScopeID: SendScopeID,
        isQuiescent: @MainActor @escaping (SendScopeID) -> Bool,
        cancelScope: @MainActor @escaping (SendScopeID) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await withTaskCancellationHandler {
                while !isQuiescent(rootScopeID) {
                    await Task.yield()
                }
            } onCancel: {
                MainActor.assumeIsolated {
                    cancelScope(rootScopeID)
                }
            }
        }
    }
}
