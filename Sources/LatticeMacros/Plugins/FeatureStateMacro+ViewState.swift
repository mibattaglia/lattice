import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

extension FeatureStateMacro {
    static let viewStateTypeName = "ViewState"
    static let viewStateTypesProtocolName = "_$ViewStateTypes"
    static let viewStateWitnessTypeName = "_$ViewStateWitness"
    static let viewStateStorageName = "_state"
    static let domainMacroName = "Domain"
    static let casePathableMacroName = "CasePathable"

    /// Names of the declarations `@FeatureState` adds to the state type.
    static let reservedTypeMemberNames: Set<String> = [
        viewStateTypeName, viewStateTypesProtocolName, viewStateWitnessTypeName,
    ]

    static func isGenericState(_ declaration: some DeclGroupSyntax) -> Bool {
        declaration.as(StructDeclSyntax.self)?.genericParameterClause != nil
            || declaration.as(EnumDeclSyntax.self)?.genericParameterClause != nil
    }

    static func genericStateDiagnostic(for declaration: some DeclGroupSyntax) -> Diagnostic? {
        let name: TokenSyntax
        let genericParameters: GenericParameterClauseSyntax
        if let structDecl = declaration.as(StructDeclSyntax.self),
            let clause = structDecl.genericParameterClause
        {
            name = structDecl.name
            genericParameters = clause
        } else if let enumDecl = declaration.as(EnumDeclSyntax.self),
            let clause = enumDecl.genericParameterClause
        {
            name = enumDecl.name
            genericParameters = clause
        } else {
            return nil
        }
        return Diagnostic(
            node: genericParameters,
            message: ViewStateDiagnostic.genericState(name.trimmed.text)
        )
    }

    /// Name tokens of state members that the generated declarations would redeclare.
    static func reservedViewStateNameTokens(in items: MemberBlockItemListSyntax) -> [TokenSyntax] {
        var tokens: [TokenSyntax] = []
        for item in items {
            let decl = item.decl
            if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                for clause in ifConfig.clauses {
                    if case .decls(let decls) = clause.elements {
                        tokens += reservedViewStateNameTokens(in: decls)
                    }
                }
            } else if let variable = decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
                        isReservedName(name, includingStorage: true)
                    {
                        tokens.append(name)
                    }
                }
            } else if let enumCase = decl.as(EnumCaseDeclSyntax.self) {
                for element in enumCase.elements where isReservedName(element.name, includingStorage: true) {
                    tokens.append(element.name)
                }
            } else if let named = decl.asProtocol((any NamedDeclSyntax).self),
                isReservedName(named.name, includingStorage: false)
            {
                tokens.append(named.name)
            }
        }
        return tokens
    }

    private static func isReservedName(_ name: TokenSyntax, includingStorage: Bool) -> Bool {
        reservedTypeMemberNames.contains(name.bareText)
            || (includingStorage && name.bareText == viewStateStorageName)
    }

    static func domainAttribute(in attributes: AttributeListSyntax) -> AttributeSyntax? {
        for element in attributes {
            guard case .attribute(let attribute) = element else { continue }
            let name = attribute.attributeName.trimmedDescription
            if name == domainMacroName || name == "\(moduleName).\(domainMacroName)" {
                return attribute
            }
        }
        return nil
    }

    /// Diagnoses `@Domain` applications that `@FeatureState` cannot honor.
    static func diagnoseDomainMisuse(
        in items: MemberBlockItemListSyntax,
        isIdentifiable: Bool,
        in context: some MacroExpansionContext
    ) {
        for item in items {
            let decl = item.decl
            if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                for clause in ifConfig.clauses {
                    if case .decls(let decls) = clause.elements {
                        diagnoseDomainMisuse(in: decls, isIdentifiable: isIdentifiable, in: context)
                    }
                }
                continue
            }
            guard let attributes = decl.asProtocol((any WithAttributesSyntax).self)?.attributes,
                let domain = domainAttribute(in: attributes)
            else {
                continue
            }
            if let variable = decl.as(VariableDeclSyntax.self), variable.isInstance {
                if isIdentifiable, variable.bindingNames.contains(where: { $0.bareText == "id" }) {
                    context.diagnose(
                        Diagnostic(node: domain, message: ViewStateDiagnostic.domainIdentifiableID)
                    )
                }
            } else {
                context.diagnose(Diagnostic(node: domain, message: ViewStateDiagnostic.domainNotProperty))
            }
        }
    }

    /// The `_$ViewStateTypes` protocol, `_$ViewStateWitness` struct and `ViewState` projection.
    static func viewStateDeclarations(
        of declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard let typeName = declaration.asProtocol((any NamedDeclSyntax).self)?.name.trimmed.text
        else {
            return []
        }
        let inheritedTypeNames = declaration.inheritedTypeNames
        let isIdentifiable = inheritedTypeNames.contains("Identifiable")

        diagnoseDomainMisuse(
            in: declaration.memberBlock.members, isIdentifiable: isIdentifiable, in: context
        )
        let reservedNames = reservedViewStateNameTokens(in: declaration.memberBlock.members)
        for name in reservedNames {
            context.diagnose(Diagnostic(node: name, message: ViewStateDiagnostic.reservedName(name.bareText)))
        }
        guard reservedNames.isEmpty else { return [] }

        var attributes: [String] = []
        if let availability = declaration.attributes.availability {
            attributes.append(availability.trimmedDescription)
        }
        attributes.append("@\(moduleName)._IdentifiableIfPossible(\(typeName).self)")
        attributes.append("@\(moduleName)._EquatableIfPossible(\(typeName).self)")

        var renderer = ViewStateRenderer(
            typeName: typeName,
            access: viewStateAccess(of: declaration, in: context),
            members: ViewStateMember.members(of: declaration.memberBlock.members),
            isIdentifiable: isIdentifiable,
            attributes: attributes,
            conformances: "\(moduleName).ViewStateProjection"
                + (inheritedTypeNames.contains("Sendable") ? ", Sendable" : "")
        )
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            return renderer.structDeclarations
        }
        // `@CasePathable` is propagated with the spelling the state uses; it is visible here,
        // so CasePaths is imported wherever the mirror is generated.
        if let casePathable = enumDecl.attributes.first(where: {
            guard case .attribute(let attribute) = $0 else { return false }
            let name = attribute.attributeName.trimmedDescription
            return name == casePathableMacroName || name == "CasePaths.\(casePathableMacroName)"
        }) {
            renderer.attributes.append(casePathable.trimmedDescription)
        }
        return renderer.enumDeclarations(
            isIndirect: enumDecl.modifiers.contains { $0.name.tokenKind == .keyword(.indirect) }
        )
    }

    /// The access modifier of the generated declarations, mirroring the state's: an explicit
    /// modifier, else `fileprivate` inside a file-private declaration (the file-scope `==` of
    /// `ViewState` must not be more visible than the state), else the default of an enclosing
    /// extension, else internal.
    static func viewStateAccess(
        of declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> String {
        if let access = declaration.modifiers.accessLevel {
            return access
        }
        let isInFilePrivateScope = context.lexicalContext.contains {
            $0.asProtocol((any WithModifiersSyntax).self)?.modifiers.accessLevel == "fileprivate "
        }
        if isInFilePrivateScope {
            return "fileprivate "
        }
        if let enclosingExtension = context.lexicalContext.first?.as(ExtensionDeclSyntax.self),
            let access = enclosingExtension.modifiers.accessLevel
        {
            return access
        }
        return ""
    }
}

struct ViewStateDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    var severity: DiagnosticSeverity { .error }

    init(message: String, id: String) {
        self.message = message
        self.diagnosticID = MessageID(domain: "FeatureState", id: id)
    }

    static func genericState(_ typeName: String) -> Self {
        Self(
            message: """
                '@FeatureState' cannot be applied to generic type '\(typeName)': the generated \
                projection uses a nested protocol, which Swift does not allow inside generic types \
                (SE-0404). Make '\(typeName)' non-generic or wrap the generic data in a non-generic \
                state type.
                """,
            id: "genericState"
        )
    }

    static func reservedName(_ name: String) -> Self {
        Self(message: "'\(name)' is reserved by '@FeatureState'", id: "reservedName")
    }

    static let domainNotProperty = Self(
        message: "'@Domain' can only be applied to instance properties",
        id: "domainNotProperty"
    )

    static let domainIdentifiableID = Self(
        message: "'id' cannot be '@Domain' on an Identifiable state; its ViewState would not satisfy 'Identifiable'",
        id: "domainIdentifiableID"
    )
}
