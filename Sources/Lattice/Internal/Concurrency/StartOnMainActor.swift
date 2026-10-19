extension Task where Failure == Never {
    /// The standard library's `Task.startOnMainActor`, which runs `work` synchronously on the main
    /// actor until its first suspension. It is not public API; the `@_silgen_name` binds the
    /// runtime's symbol, as shown in
    /// https://forums.swift.org/t/async-await-is-it-possible-to-start-a-task-on-mainactor-synchronously/52862/23.
    /// Only `immediateIfAvailable` calls it, on the main actor, before OS 26.
    @_silgen_name("$sScTss5NeverORs_rlE16startOnMainActor8priority_ScTyxABGScPSg_xyYaYbScMYccntFZ")
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @discardableResult
    @MainActor
    static func startOnMainActor(
        priority: TaskPriority? = nil,
        @_inheritActorContext @_implicitSelfCapture _ work:
            consuming @Sendable @escaping @MainActor () async -> Success
    ) -> Task<Success, Never>
}
