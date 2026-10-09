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
        let observers: AccessorDeclListSyntax
        if let block = binding.accessorBlock, case .accessors(let accessors) = block.accessors {
            observers = accessors
        } else {
            observers = []
        }
        func observer(_ keyword: Keyword, argument: String, defaultName: String) -> String {
            guard let accessor = observers.first(where: { $0.accessorSpecifier.tokenKind == .keyword(keyword) }),
                let body = accessor.body
            else { return "" }
            let parameter = accessor.parameters?.name.text ?? defaultName
            return "({ \(parameter) in \(body.statements.trimmedDescription) })(\(argument))"
        }
        let willSet = observer(.willSet, argument: "newValue", defaultName: "newValue")
        let didSet = observer(.didSet, argument: "oldValue", defaultName: "oldValue")
        let captureOldValue = didSet.isEmpty ? "" : "let oldValue = \(storage)._untrackedValue"
        let setter: AccessorDeclSyntax
        let modify: AccessorDeclSyntax
        if observers.isEmpty {
            setter = "set { \(raw: storage).value = newValue }"
            modify = "_modify { yield &\(raw: storage).value }"
        } else {
            // Swift accepts attached get/set accessors on an observed property,
            // but does not compose its original observers into those accessors.
            // A temporary wrapper preserves native _modify notifications while
            // willSet/didSet still see the property's old/new stored values.
            setter = """
                set {
                    \(raw: willSet)
                    \(raw: captureOldValue)
                    \(raw: storage).value = newValue
                    \(raw: didSet)
                }
                """
            let modifyWillSet = observer(.willSet, argument: "temporary._untrackedValue", defaultName: "newValue")
            modify = """
                _modify {
                    var temporary = \(raw: storage)
                    defer {
                        \(raw: modifyWillSet)
                        \(raw: captureOldValue)
                        \(raw: storage)._untrackedValue = temporary._untrackedValue
                        \(raw: didSet)
                    }
                    yield &temporary.value
                }
                """
        }
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
            setter,
            modify,
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
        let type = binding.typeAnnotation.map { ": Lattice._FeatureStateTracked<\($0.type.trimmedDescription)>" } ?? ""
        let initial = binding.initializer.map { " = Lattice._FeatureStateTracked(\($0.value.trimmedDescription))" } ?? ""
        return ["private var \(raw: storageName(identifier))\(raw: type)\(raw: initial)"]
    }
}
