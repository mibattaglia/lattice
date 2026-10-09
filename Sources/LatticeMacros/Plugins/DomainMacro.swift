import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Marker read by `@FeatureState`; no raw domain access is changed.
public struct DomainMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self), variable.isInstance,
            context.lexicalContext.first(where: { $0.asProtocol(DeclGroupSyntax.self) != nil })
                .map({ syntax in
                guard let state = syntax.asProtocol(DeclGroupSyntax.self) else { return false }
                return state.attributes.contains {
                    guard let attribute = $0.as(AttributeSyntax.self) else { return false }
                    return ["FeatureState", "Lattice.FeatureState"].contains(attribute.attributeName.trimmedDescription)
                }
            }) == true
        else {
            throw SwiftSyntaxMacros.MacroExpansionErrorMessage("'@Domain' requires an instance property in an '@FeatureState' declaration")
        }
        if variable.modifiers.contains(where: {
            $0.detail == nil && [.keyword(.private), .keyword(.fileprivate)].contains($0.name.tokenKind)
        }) {
            context.diagnose(Diagnostic(node: node, message: SwiftSyntaxMacros.MacroExpansionWarningMessage(
                "'@Domain' is redundant on a private member; private getters are already excluded"
            )))
        }
        return []
    }
}
