import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@_IdentifiableIfPossible(T.self)` when `T: Identifiable`. Adds `Identifiable` to the
/// generated `ViewState`; `id` is the visible `id` member or the `ViewStateProjection` extension.
public struct IdentifiableIfPossibleMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty else { return [] }
        return [
            ("""
            \(declaration.attributes.availability)extension \(raw: type.trimmedDescription): Identifiable {}
            """ as DeclSyntax)
            .cast(ExtensionDeclSyntax.self)
        ]
    }
}

/// `@_EquatableIfPossible(T.self)` when `T: Equatable`. Adds `Equatable` to the generated
/// `ViewState`, comparing the projected states.
public struct EquatableIfPossibleMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty else { return [] }
        // `==` lives in a file-scope extension, so it takes the projection's own access
        // modifier (`@FeatureState` writes `fileprivate` for file-private states).
        let access =
            declaration.modifiers
            .first {
                [.keyword(.public), .keyword(.package), .keyword(.fileprivate)].contains($0.name.tokenKind)
            }
            .map { "\($0.name.text) " } ?? ""
        return [
            ("""
            \(declaration.attributes.availability)extension \(raw: type.trimmedDescription): Equatable {
            \(raw: access)static func == (lhs: Self, rhs: Self) -> Bool {
            lhs._state == rhs._state
            }
            }
            """ as DeclSyntax)
            .cast(ExtensionDeclSyntax.self)
        ]
    }
}

/// The unconstrained overload of the `_…IfPossible` macros: the state lacks the conformance.
public struct NoOpExtensionMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        []
    }
}
