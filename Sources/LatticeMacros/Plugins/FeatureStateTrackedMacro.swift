import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Accessors use a per-property value wrapper, not the enclosing state's identity.
public struct FeatureStateTrackedMacro: AccessorMacro, PeerMacro {
    static func storageName(_ identifier: TokenSyntax) -> String {
        "_feature_" + identifier.text.replacingOccurrences(of: "`", with: "")
    }

    public static func expansion(
        of node: AttributeSyntax, providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self),
            let binding = property.bindings.first,
            let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier
        else { return [] }
        let storage = storageName(identifier)
        return [
            """
            @storageRestrictions(initializes: \(raw: storage))
            init(initialValue) {
                \(raw: storage) = Lattice._FeatureStateTracked(initialValue)
            }
            """,
            """
            get { \(raw: storage).value }
            """,
            "set { \(raw: storage).value = newValue }",
            "_modify { yield &\(raw: storage).value }",
        ]
    }

    public static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self),
            let binding = property.bindings.first,
            let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier
        else { return [] }
        var storage = property
        storage.attributes = []
        storage.modifiers = property.modifiers.privatePrefixed("_feature_")
        var storedBinding = binding
        storedBinding.pattern = PatternSyntax(IdentifierPatternSyntax(identifier: .identifier(storageName(identifier))))
        storedBinding.typeAnnotation = binding.typeAnnotation.map {
            $0.with(\.type, "Lattice._FeatureStateTracked<\($0.type.trimmed)>")
        }
        storedBinding.initializer = binding.initializer.map {
            $0.with(\.value, "Lattice._FeatureStateTracked(\($0.value.trimmed))")
        }
        // Like ObservationStateTracked, leave observers on the stored peer.
        // References to the public property still use its accessors; their Swift
        // bodies are not rewritten to emulate unannotated stored-property access.
        if var block = binding.accessorBlock, case .accessors(let accessors) = block.accessors {
            block.accessors = .accessors(AccessorDeclListSyntax(accessors.map { accessor in
                guard let body = accessor.body else { return accessor }
                let parameter = accessor.parameters?.name ?? .identifier(
                    accessor.accessorSpecifier.tokenKind == .keyword(.willSet) ? "newValue" : "oldValue"
                )
                return accessor.with(\.body, """
                    {
                        let \(parameter) = \(parameter)._untrackedValue
                        _ = \(parameter)
                        do \(body.trimmed)
                    }
                    """)
            }))
            storedBinding.accessorBlock = block
        }
        storage.bindings = [storedBinding]
        return [DeclSyntax(storage)]
    }
}
