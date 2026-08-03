// https://forums.swift.org/t/async-await-is-it-possible-to-start-a-task-on-mainactor-synchronously/52862/23

extension Task where Failure == Never {
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
