import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct MacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        InteractorMacro.self,
        ViewStateReducerMacro.self,
        FeatureStateMacro.self,
        DomainMacro.self,
        IdentifiableIfPossibleMacro.self,
        EquatableIfPossibleMacro.self,
        NoOpExtensionMacro.self,
        ObservationStateIgnoredMacro.self,
        ObservationStateTrackedMacro.self,
    ]
}
