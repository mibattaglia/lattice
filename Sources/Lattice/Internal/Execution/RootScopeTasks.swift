enum RootScopeTasks {
    static func makeTask(
        rootScopeID: SendScopeID,
        isQuiescent: @MainActor @escaping (SendScopeID) -> Bool,
        cancelScope: @MainActor @escaping (SendScopeID) -> Void
    ) -> Task<Void, Never> {
        Task {
            await withTaskCancellationHandler {
                while !(await isQuiescent(rootScopeID)) {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            } onCancel: {
                Task { @MainActor in
                    cancelScope(rootScopeID)
                }
            }
        }
    }
}
