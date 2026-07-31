import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Marker macro: expansion is empty. `@FeatureState` reads the attribute during its own
/// expansion to exclude the member from the view projection and the commit diff.
public struct DomainMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // §8 diagnostic: @Domain on a private member is redundant.
        if let variable = declaration.as(VariableDeclSyntax.self),
            variable.modifiers.contains(where: { modifier in
                modifier.detail == nil
                    && (modifier.name.tokenKind == .keyword(.private)
                        || modifier.name.tokenKind == .keyword(.fileprivate))
            })
        {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: MacroExpansionWarningMessage(
                        "'@Domain' is redundant on a private member; 'private' already excludes it from the view surface"
                    )
                )
            )
        }
        return []
    }
}
