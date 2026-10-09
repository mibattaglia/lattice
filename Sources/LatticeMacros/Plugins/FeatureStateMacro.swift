import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct FeatureStateMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {
    private struct Member {
        let name: String
        let access: String
        let computed: Bool
        let storage: String?
        let payloadType: TypeSyntax?
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

    private static func hasConditionalStateMembers(_ conditional: IfConfigDeclSyntax) -> Bool {
        for clause in conditional.clauses {
            guard case .decls(let members) = clause.elements else { continue }
            for member in members {
                if let variable = member.decl.as(VariableDeclSyntax.self), variable.isInstance { return true }
                if member.decl.is(EnumCaseDeclSyntax.self) { return true }
                if let nested = member.decl.as(IfConfigDeclSyntax.self), hasConditionalStateMembers(nested) { return true }
            }
        }
        return false
    }

    private static func collect(_ declaration: some DeclGroupSyntax) throws -> [Member] {
        var result: [Member] = []
        for member in declaration.memberBlock.members {
            if let conditional = member.decl.as(IfConfigDeclSyntax.self), hasConditionalStateMembers(conditional) {
                throw MacroExpansionErrorMessage("conditional member groups are unsupported by '@FeatureState'; move them to a separate type")
            }
            guard let variable = member.decl.as(VariableDeclSyntax.self), variable.isInstance else { continue }
            let access = accessPrefix(variable.modifiers)
            let visible = access != "private " && access != "fileprivate " && !isDomain(variable)
            guard !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.lazy) }) else {
                throw MacroExpansionErrorMessage("lazy properties are unsupported by '@FeatureState', including hidden inputs")
            }
            guard variable.bindings.count == 1, let binding = variable.bindings.first,
                let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier
            else { throw MacroExpansionErrorMessage("'@FeatureState' requires one named property per declaration") }
            let computed = variable.isComputed
            if !computed || visible {
                guard variable.attributes.allSatisfy({ element in
                    guard let attribute = element.as(AttributeSyntax.self) else { return false }
                    return ["Domain", "Lattice.Domain"].contains(attribute.attributeName.trimmedDescription)
                }) else {
                    throw MacroExpansionErrorMessage("property attributes/wrappers and member-specific availability are unsupported by '@FeatureState', including hidden stored inputs")
                }
            }
            if let block = binding.accessorBlock, case .accessors(let accessors) = block.accessors {
                if computed {
                    guard !visible || (accessors.count == 1 && accessors.first?.effectSpecifiers == nil
                        && accessors.first?.modifier?.name.tokenKind != .keyword(.mutating))
                    else { throw MacroExpansionErrorMessage("view-visible computed properties must have a synchronous, nonmutating, get-only getter") }
                } else if accessors.contains(where: {
                    ![TokenKind.keyword(.willSet), .keyword(.didSet)].contains($0.accessorSpecifier.tokenKind)
                }) {
                    throw MacroExpansionErrorMessage("unsupported stored accessor in '@FeatureState', including hidden inputs")
                }
            }
            guard visible else { continue }
            guard binding.typeAnnotation != nil else {
                throw MacroExpansionErrorMessage("view-visible members need an explicit type annotation for generated member metadata")
            }
            result.append(Member(
                name: identifier.trimmedDescription, access: access, computed: computed,
                storage: !computed && !variable.isImmutable ? FeatureStateTrackedMacro.storageName(identifier) : nil,
                payloadType: nil
            ))
        }
        return result
    }

    public static func expansion(
        of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol, in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard declaration.isStruct, let variable = member.as(VariableDeclSyntax.self),
            variable.isValidForObservation, variable.bindings.count == 1,
            let identifier = variable.identifier,
            !identifier.text.hasPrefix("_feature_"), identifier.text != "_featureStateLocation"
        else { return [] }
        // Validation is owned by the member expansion so hidden properties are
        // diagnosed, not silently excluded from mutation instrumentation.
        guard (try? collect(declaration)) != nil else { return [] }
        return ["@Lattice._FeatureStateTrackedProperty"]
    }

    public static func expansion(
        of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.isStruct || declaration.isEnum else {
            throw MacroExpansionErrorMessage("'@FeatureState' can only be attached to structs and enums")
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
        let reserved = ["_ViewMembers", "_viewMembers", "_featureStateLocation", "_featureStateIdentity"]
        for member in declaration.memberBlock.members {
            let names: [String]
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                names = variable.bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
            } else {
                names = [member.decl.as(FunctionDeclSyntax.self)?.name.text,
                    member.decl.as(StructDeclSyntax.self)?.name.text,
                    member.decl.as(EnumDeclSyntax.self)?.name.text,
                    member.decl.as(TypeAliasDeclSyntax.self)?.name.text].compactMap { $0 }
            }
            if names.contains(where: { reserved.contains($0) || $0.hasPrefix("_feature_") }) {
                throw MacroExpansionErrorMessage("'@FeatureState' generated-name collision with member metadata or tracked storage")
            }
        }
        var members = try collect(declaration)
        var generated: [DeclSyntax] = []
        if let state = declaration.as(EnumDeclSyntax.self) {
            let existing = Set(members.map(\.name))
            var identityCases: [String] = []
            var tag = 0
            for item in state.memberBlock.members {
                guard let cases = item.decl.as(EnumCaseDeclSyntax.self) else { continue }
                guard cases.attributes.isEmpty else {
                    throw MacroExpansionErrorMessage("member-specific enum case availability is unsupported by '@FeatureState'")
                }
                for element in cases.elements {
                    let name = element.name.trimmedDescription
                    let payloads = element.parameterClause?.parameters ?? []
                    guard payloads.count <= 1 else {
                        throw MacroExpansionErrorMessage("enum cases with multiple associated values require one tracked payload struct")
                    }
                    defer { tag += 1 }
                    guard let payload = payloads.first else {
                        identityCases.append("case .\(name): return .case(\(tag), nil)")
                        continue
                    }
                    guard !existing.contains(name) else {
                        throw MacroExpansionErrorMessage("enum case '\(name)' collides with an existing member")
                    }
                    identityCases.append("case .\(name)(let value): return Lattice._featureStateCaseIdentity(\(tag), value)")
                    members.append(Member(
                        name: name, access: access, computed: false, storage: nil, payloadType: payload.type
                    ))
                }
            }
            generated.append("""
                \(raw: access)var _featureStateIdentity: Lattice._FeatureStateIdentity {
                    switch self { \(raw: identityCases.joined(separator: "\n")) }
                }
                """)
        } else {
            generated.append("private var _featureStateLocation = Lattice._FeatureStateLocation()")
            generated.append("\(raw: access)var _featureStateIdentity: Lattice._FeatureStateIdentity { _featureStateLocation.identity }")
        }
        let fields = members.map { member -> String in
            if let payloadType = member.payloadType {
                return """
                    \(member.access)let \(member.name) = Lattice._featureStateCaseMember { (state: \(root)) -> \(payloadType)? in
                        guard case .\(member.name)(let value) = state else { return nil }
                        return value
                    }
                    """
            }
            if member.computed {
                return "\(member.access)let \(member.name) = Lattice._featureStateComputedMember(\\\(root).\(member.name))"
            }
            let extraction = member.storage.map { "$0.\($0)._untrackedValue" } ?? "$0.\(member.name)"
            return "\(member.access)let \(member.name) = Lattice._featureStateMember(\\\(root).\(member.name), read: { \(extraction) })"
        }
        let identityMembers = members.contains { $0.name.replacingOccurrences(of: "`", with: "") == "id" }
            ? ": Lattice._FeatureStateIdentityMembers" : ""
        let validation = members.map { "Lattice._validateFeatureStateMember(\($0.name))" }
        generated.append(contentsOf: [
            """
            \(raw: access)struct _ViewMembers\(raw: identityMembers) {
                \(raw: fields.joined(separator: "\n").replacingOccurrences(of: "\n", with: "\n    "))
                nonisolated init() {
                    \(raw: validation.joined(separator: "\n"))
                }
            }
            """,
            "\(raw: access)static var _viewMembers: _ViewMembers { _ViewMembers() }",
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
