import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct FeatureStateMacro: MemberMacro, ExtensionMacro {
    private struct Member {
        let name: String
        let access: String
        let derived: Bool
        let identifiers: Set<String>
        let node: Syntax
    }

    private static func accessPrefix(_ modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers where modifier.detail == nil {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.package), .keyword(.internal),
                .keyword(.private), .keyword(.fileprivate): return "\(modifier.name.text) "
            default: continue
            }
        }
        return ""
    }

    private static func isDomain(_ variable: VariableDeclSyntax) -> Bool {
        variable.attributes.contains {
            guard let attribute = $0.as(AttributeSyntax.self) else { return false }
            return ["Domain", "Lattice.Domain"].contains(attribute.attributeName.trimmedDescription)
        }
    }

    private static func hasVisibleConditionalMembers(_ conditional: IfConfigDeclSyntax) -> Bool {
        for clause in conditional.clauses {
            guard case .decls(let members) = clause.elements else { continue }
            for item in members {
                if let variable = item.decl.as(VariableDeclSyntax.self), variable.isInstance {
                    let access = accessPrefix(variable.modifiers)
                    if access != "private ", access != "fileprivate ", !isDomain(variable) { return true }
                }
                if item.decl.is(EnumCaseDeclSyntax.self) { return true }
                if let nested = item.decl.as(IfConfigDeclSyntax.self), hasVisibleConditionalMembers(nested) { return true }
            }
        }
        return false
    }

    private static func collect(
        _ declaration: some DeclGroupSyntax, context: some MacroExpansionContext
    ) throws -> [Member] {
        var result: [Member] = []
        for member in declaration.memberBlock.members {
            if let conditional = member.decl.as(IfConfigDeclSyntax.self) {
                if hasVisibleConditionalMembers(conditional) {
                    throw SwiftSyntaxMacros.MacroExpansionErrorMessage(
                        "conditional member groups are unsupported by '@FeatureState'; move them to a separate type"
                    )
                }
            }
            guard let variable = member.decl.as(VariableDeclSyntax.self), variable.isInstance else { continue }
            let access = accessPrefix(variable.modifiers)
            guard access != "private ", access != "fileprivate ", !isDomain(variable) else { continue }
            guard !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.lazy) }) else {
                throw SwiftSyntaxMacros.MacroExpansionErrorMessage("view-visible lazy properties are unsupported; add '@Domain'")
            }
            guard variable.attributes.isEmpty else {
                throw SwiftSyntaxMacros.MacroExpansionErrorMessage(
                    "view-visible property attributes/wrappers and member-specific availability are unsupported; add '@Domain'"
                )
            }
            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self), binding.typeAnnotation != nil else {
                    throw SwiftSyntaxMacros.MacroExpansionErrorMessage(
                        "view-visible members need an explicit type annotation for the generated projection"
                    )
                }
                var derived = false
                if let block = binding.accessorBlock {
                    switch block.accessors {
                    case .getter: derived = true
                    case .accessors(let accessors):
                        let getters = accessors.filter { $0.accessorSpecifier.tokenKind == .keyword(.get) }
                        if !getters.isEmpty {
                            guard accessors.count == 1, let getter = getters.first,
                                getter.effectSpecifiers == nil,
                                getter.modifier?.name.tokenKind != .keyword(.mutating)
                            else {
                                throw SwiftSyntaxMacros.MacroExpansionErrorMessage(
                                    "view-visible computed properties must have a synchronous, nonmutating, get-only getter; add '@Domain'"
                                )
                            }
                            derived = true
                        } else if accessors.contains(where: {
                            ![TokenKind.keyword(.willSet), .keyword(.didSet)].contains($0.accessorSpecifier.tokenKind)
                        }) {
                            throw SwiftSyntaxMacros.MacroExpansionErrorMessage("unsupported view-visible accessor; add '@Domain'")
                        }
                    }
                }
                let tokens = binding.accessorBlock.map { Array($0.tokens(viewMode: .sourceAccurate)) } ?? []
                let identifiers = Set(tokens.indices.compactMap { index -> String? in
                    guard case .identifier(let name) = tokens[index].tokenKind else { return nil }
                    if index > 0, tokens[index - 1].tokenKind == .period {
                        guard index > 1, tokens[index - 2].text == "self" else { return nil }
                    }
                    return name
                })
                result.append(Member(name: identifier.identifier.trimmedDescription, access: access,
                    derived: derived, identifiers: identifiers, node: Syntax(binding)))
                if derived, let type = binding.typeAnnotation?.type,
                    type.is(ArrayTypeSyntax.self) || type.is(DictionaryTypeSyntax.self)
                        || ["Array", "Dictionary", "Set", "IdentifiedArrayOf"].contains(type.identifier ?? "") {
                    context.diagnose(Diagnostic(node: binding, message: SwiftSyntaxMacros.MacroExpansionWarningMessage(
                        "derived collections are cached and compared as one coarse output; use stored identified feature rows for granular updates"
                    )))
                }
            }
        }
        let computed = result.filter(\.derived)
        let names = Set(computed.map(\.name))
        let edges = Dictionary(uniqueKeysWithValues: computed.map { ($0.name, $0.identifiers.intersection(names)) })
        for member in computed {
            var pending = Array(edges[member.name] ?? [])
            var seen: Set<String> = []
            while let name = pending.popLast() {
                guard seen.insert(name).inserted else { continue }
                pending.append(contentsOf: edges[name] ?? [])
            }
            if seen.contains(member.name) {
                context.diagnose(Diagnostic(node: member.node, message: SwiftSyntaxMacros.MacroExpansionWarningMessage(
                    "cyclic derived properties may recurse at evaluation; break the cycle or add '@Domain'"
                )))
            }
        }
        return result
    }

    public static func expansion(
        of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.isStruct || declaration.isEnum else {
            throw SwiftSyntaxMacros.MacroExpansionErrorMessage("'@FeatureState' can only be attached to structs and enums")
        }
        let typeName: String
        let parameters: [String]
        if let state = declaration.as(StructDeclSyntax.self) {
            typeName = state.name.trimmedDescription
            parameters = state.genericParameterClause?.parameters.map { $0.name.text } ?? []
        } else {
            let state = declaration.cast(EnumDeclSyntax.self)
            typeName = state.name.trimmedDescription
            parameters = state.genericParameterClause?.parameters.map { $0.name.text } ?? []
        }
        let root = typeName + (parameters.isEmpty ? "" : "<\(parameters.joined(separator: ", "))>")
        let declaredAccess = accessPrefix(declaration.modifiers)
        let access = ["public ", "package "].contains(declaredAccess) ? declaredAccess : ""
        let reserved = ["_ViewMembers", "_viewMembers", "_commit"]
        for member in declaration.memberBlock.members {
            var names: [String] = []
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                names = variable.bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
            } else if let cases = member.decl.as(EnumCaseDeclSyntax.self) {
                names = cases.elements.map { $0.name.text }
            } else {
                let named: [String?] = [member.decl.as(FunctionDeclSyntax.self)?.name.text,
                    member.decl.as(StructDeclSyntax.self)?.name.text,
                    member.decl.as(EnumDeclSyntax.self)?.name.text,
                    member.decl.as(ClassDeclSyntax.self)?.name.text,
                    member.decl.as(ActorDeclSyntax.self)?.name.text,
                    member.decl.as(TypeAliasDeclSyntax.self)?.name.text]
                names = named.compactMap { $0 }
            }
            if names.contains(where: { reserved.contains($0) }) {
                throw SwiftSyntaxMacros.MacroExpansionErrorMessage("'@FeatureState' generated-name collision with _ViewMembers, _viewMembers, or _commit")
            }
        }
        var members = try collect(declaration, context: context)
        var generated: [DeclSyntax] = []
        var caseNames: [String] = []
        if let state = declaration.as(EnumDeclSyntax.self) {
            let existing = Set(state.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self)?.name.trimmedDescription }
                + state.definedVariables.compactMap { $0.identifier?.trimmedDescription })
            for item in state.memberBlock.members {
                guard let cases = item.decl.as(EnumCaseDeclSyntax.self) else { continue }
                guard cases.attributes.isEmpty else {
                    throw SwiftSyntaxMacros.MacroExpansionErrorMessage("member-specific enum case availability is unsupported by '@FeatureState'")
                }
                for element in cases.elements {
                    let name = element.name.trimmedDescription
                    caseNames.append(name)
                    let payloads = element.parameterClause?.parameters ?? []
                    guard payloads.count <= 1 else {
                        throw SwiftSyntaxMacros.MacroExpansionErrorMessage("enum cases with multiple associated values require one payload struct")
                    }
                    guard let payload = payloads.first else { continue }
                    guard !existing.contains(name) else {
                        throw SwiftSyntaxMacros.MacroExpansionErrorMessage("enum case '\(name)' collides with an existing member")
                    }
                    generated.append("""
                        \(raw: access)var \(raw: name): \(payload.type)? {
                            guard case .\(raw: name)(let value) = self else { return nil }
                            return value
                        }
                        """)
                    members.append(Member(name: name, access: access, derived: false, identifiers: [], node: Syntax(element)))
                }
            }
        }
        let fields = members.map {
            "\($0.access)let \($0.name) = Lattice.\($0.derived ? "_derivedProjectionMember" : "_projectionMember")(\\\(root).\($0.name))"
        }
        var commits = members.map {
            "Lattice._commitProjectionMember(_viewMembers.\($0.name), old: old, new: new, registrar: registrar, key: key.appending(\\_ViewMembers.\($0.name)))"
        }
        if !caseNames.isEmpty {
            let cases = caseNames.map { "case (.\($0), .\($0)): break" }.joined(separator: "\n")
            commits.insert("switch (old, new) {\n\(cases)\ndefault: Lattice._invalidateProjectionSubtree(registrar: registrar, key: key)\n}", at: 0)
        }
        generated.append(contentsOf: [
            """
            \(raw: access)struct _ViewMembers {
                \(raw: fields.joined(separator: "\n"))
            }
            """,
            """
            \(raw: access)static var _viewMembers: _ViewMembers { _ViewMembers() }
            """,
            """
            @MainActor
            \(raw: access)static func _commit(old: Self, new: Self, registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey) {
                \(raw: commits.joined(separator: "\n"))
            }
            """,
        ])
        return generated
    }

    public static func expansion(
        of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.isStruct || declaration.isEnum, !protocols.isEmpty else { return [] }
        let result: DeclSyntax = """
            \(declaration.attributes.availability)extension \(type.trimmed): Lattice.FeatureStateProtocol {}
            """
        return [result.cast(ExtensionDeclSyntax.self)]
    }
}
