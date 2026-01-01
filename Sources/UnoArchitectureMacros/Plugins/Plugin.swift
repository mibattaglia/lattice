import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct MacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        InteractorMacro.self,
        ViewStateReducerMacro.self,
        ViewModelMacro.self,
        SubscribeMacro.self,
    ]
}
