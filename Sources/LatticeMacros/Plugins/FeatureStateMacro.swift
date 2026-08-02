import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@FeatureState`: generates the view projection surface and the commit diff for a struct
/// or enum state type.
///
/// Generated members: the `_ViewMembers` key-path namespace over view-visible members, the
/// `_viewKeyPaths` map, the `_derivedMembers` set, the `_commit(old:new:registrar:key:)`
/// diff, and — for enums — one optional case accessor per single-payload case. Members
/// marked `@Domain` or `private` are excluded everywhere. Stored members diff through the
/// overload-ranked `Lattice._diff`; computed members become `registrar.commitDerived` calls.
public struct FeatureStateMacro {
    static let moduleName = "Lattice"

    // MARK: Member classification

    struct VisibleMember {
        let name: String
        /// The member's type as written (case accessors: the payload type + `?`).
        let type: String
        /// Computed members are derived view output; case accessors are not derived.
        let isComputed: Bool
        /// Enum case accessors read through committed state and diff in the case switch.
        let isCaseAccessor: Bool
        /// The getter body tokens, for the best-effort cycle scan (computed members only).
        let bodyIdentifiers: Set<String>
        /// The syntax node to attach member-targeted diagnostics to.
        let node: Syntax
    }

    struct EnumCaseInfo {
        let name: String
        /// The single payload's type, when the case has exactly one associated value.
        let payloadType: String?
        let hasPayload: Bool
    }

    private static func isPrivate(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { modifier in
            modifier.detail == nil
                && (modifier.name.tokenKind == .keyword(.private)
                    || modifier.name.tokenKind == .keyword(.fileprivate))
        }
    }

    private static func hasDomainAttribute(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard case .attribute(let attribute) = element else { return false }
            let name = attribute.attributeName.trimmedDescription
            return name == "Domain" || name == "\(moduleName).Domain"
        }
    }

    private static func accessPrefix(_ declaration: some DeclGroupSyntax) -> String {
        for modifier in declaration.modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.package):
                return "\(modifier.name.text) "
            default:
                continue
            }
        }
        return ""
    }

    /// Collects the view-visible variable members, emitting the syntactic diagnostics
    /// that concern individual members. Returns nil after an error-severity diagnostic.
    private static func collectVariableMembers(
        of declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> [VisibleMember]? {
        var members: [VisibleMember] = []
        var hadError = false

        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard variable.isInstance else { continue }
            guard !isPrivate(variable.modifiers) else { continue }
            guard !hasDomainAttribute(variable.attributes) else { continue }

            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)
                else { continue }
                let name = identifier.identifier.text

                var isComputed = false
                var bodyIdentifiers: Set<String> = []
                switch binding.accessorBlock?.accessors {
                case .getter(let body):
                    isComputed = true
                    bodyIdentifiers = identifierNames(in: Syntax(body))
                case .accessors(let accessors):
                    let kinds = accessors.map(\.accessorSpecifier.tokenKind)
                    if kinds.contains(.keyword(.set)) {
                        context.diagnose(
                            Diagnostic(
                                node: binding,
                                message: MacroExpansionErrorMessage(
                                    "view-visible computed properties are get-only; add '@Domain' for interactor-side settable helpers"
                                )
                            )
                        )
                        hadError = true
                        continue
                    }
                    if kinds.contains(.keyword(.get)) {
                        isComputed = true
                        for accessor in accessors where accessor.accessorSpecifier.tokenKind == .keyword(.get) {
                            bodyIdentifiers = identifierNames(in: Syntax(accessor))
                        }
                    }
                case nil:
                    break
                }

                guard let type = binding.typeAnnotation?.type else {
                    context.diagnose(
                        Diagnostic(
                            node: binding,
                            message: MacroExpansionErrorMessage(
                                "view-visible members need an explicit type annotation for the generated projection; add one, mark the member '@Domain', or make it 'private'"
                            )
                        )
                    )
                    hadError = true
                    continue
                }

                if isComputed, let warning = collectionReturnWarning(for: type) {
                    context.diagnose(Diagnostic(node: binding, message: warning))
                }

                members.append(
                    VisibleMember(
                        name: name,
                        type: type.trimmedDescription,
                        isComputed: isComputed,
                        isCaseAccessor: false,
                        bodyIdentifiers: bodyIdentifiers,
                        node: Syntax(binding)
                    )
                )
            }
        }

        return hadError ? nil : members
    }

    private static func identifierNames(in syntax: Syntax) -> Set<String> {
        var names: Set<String> = []
        for token in syntax.tokens(viewMode: .sourceAccurate) {
            if case .identifier(let name) = token.tokenKind {
                names.insert(name)
            }
        }
        return names
    }

    private static func collectionReturnWarning(
        for type: TypeSyntax
    ) -> MacroExpansionWarningMessage? {
        let isCollection: Bool
        if type.is(ArrayTypeSyntax.self) || type.is(DictionaryTypeSyntax.self) {
            isCollection = true
        } else if let identifier = type.as(IdentifierTypeSyntax.self) {
            isCollection = ["Array", "Set", "Dictionary", "IdentifiedArrayOf"]
                .contains(identifier.name.text)
        } else {
            isCollection = false
        }
        guard isCollection else { return nil }
        return MacroExpansionWarningMessage(
            """
            returns a collection: derived collections are rebuilt and compared as one leaf \
            value whenever observed at commit — model elements as '@FeatureState' values in \
            an 'IdentifiedArrayOf' stored member, return '[ID]'/section keys for structure, \
            or accept the O(n) compare
            """
        )
    }

    /// Best-effort cycle scan over visible computed members' getter bodies.
    private static func diagnoseDerivedCycles(
        among members: [VisibleMember],
        in context: some MacroExpansionContext
    ) {
        let computed = members.filter { $0.isComputed && !$0.isCaseAccessor }
        let names = Set(computed.map(\.name))
        let edges: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: computed.map { member in
                (member.name, member.bodyIdentifiers.intersection(names).subtracting([member.name]))
            }
        )
        func reachable(from start: String) -> Set<String> {
            var seen: Set<String> = []
            var stack = Array(edges[start] ?? [])
            while let next = stack.popLast() {
                guard seen.insert(next).inserted else { continue }
                stack.append(contentsOf: edges[next] ?? [])
            }
            return seen
        }
        for member in computed where reachable(from: member.name).contains(member.name) {
            context.diagnose(
                Diagnostic(
                    node: member.node,
                    message: MacroExpansionWarningMessage(
                        "cyclic derived properties will recurse at evaluation; break the cycle or mark one '@Domain'"
                    )
                )
            )
        }
    }

    /// Collects enum cases, emitting the multi-payload and accessor-collision errors.
    /// Returns nil after an error-severity diagnostic.
    private static func collectEnumCases(
        of declaration: EnumDeclSyntax,
        existingMemberNames: Set<String>,
        in context: some MacroExpansionContext
    ) -> [EnumCaseInfo]? {
        var cases: [EnumCaseInfo] = []
        var hadError = false

        for member in declaration.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                let name = element.name.text
                let parameters = element.parameterClause?.parameters ?? []
                switch parameters.count {
                case 0:
                    cases.append(EnumCaseInfo(name: name, payloadType: nil, hasPayload: false))
                case 1:
                    if existingMemberNames.contains(name) {
                        context.diagnose(
                            Diagnostic(
                                node: element,
                                message: MacroExpansionErrorMessage(
                                    "enum case '\(name)' collides with an existing member, blocking its case accessor; rename the case or the member"
                                )
                            )
                        )
                        hadError = true
                        continue
                    }
                    cases.append(
                        EnumCaseInfo(
                            name: name,
                            payloadType: parameters.first!.type.trimmedDescription,
                            hasPayload: true
                        )
                    )
                default:
                    context.diagnose(
                        Diagnostic(
                            node: element,
                            message: MacroExpansionErrorMessage(
                                "enum cases with multiple associated values are not projected; wrap the payload in a single struct (annotate it '@FeatureState' for granular observation)"
                            )
                        )
                    )
                    hadError = true
                }
            }
        }

        return hadError ? nil : cases
    }

    // MARK: Code generation

    private static func viewMembersStruct(
        access: String, entries: [(name: String, type: String)]
    ) -> DeclSyntax {
        let fields = entries
            .map { "    \(access)let \($0.name): \($0.type)" }
            .joined(separator: "\n")
        return """
            \(raw: access)struct _ViewMembers {
            \(raw: fields)\(raw: fields.isEmpty ? "" : "\n")    @available(*, unavailable) private init() { fatalError() }
            }
            """
    }

    private static func viewKeyPathsMap(
        access: String, typeName: String, entries: [(name: String, type: String)]
    ) -> DeclSyntax {
        guard !entries.isEmpty else {
            return """
                @MainActor \(raw: access)static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [:]
                """
        }
        let pairs = entries
            .map { "    \\_ViewMembers.\($0.name): \\\(typeName).\($0.name)," }
            .joined(separator: "\n")
        return """
            @MainActor \(raw: access)static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
            \(raw: pairs)
            ]
            """
    }

    private static func derivedMembersSet(access: String, names: [String]) -> DeclSyntax {
        guard !names.isEmpty else {
            return """
                @MainActor \(raw: access)static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = []
                """
        }
        let elements = names
            .map { "    \\_ViewMembers.\($0)," }
            .joined(separator: "\n")
        return """
            @MainActor \(raw: access)static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
            \(raw: elements)
            ]
            """
    }

    private static func commitFunction(
        access: String, typeName: String, body: [String]
    ) -> DeclSyntax {
        """
        @MainActor \(raw: access)static func _commit(
            old: \(raw: typeName), new: \(raw: typeName),
            registrar: \(raw: moduleName).FeatureStateRegistrar, key: \(raw: moduleName).ProjectionKey
        ) {
        \(raw: body.map { "    " + $0 }.joined(separator: "\n"))
        }
        """
    }

    private static func diffLine(member: String) -> String {
        """
        \(moduleName)._diff(
                old.\(member), new.\(member),
                registrar: registrar, key: key.appending(\\_ViewMembers.\(member)))
        """
    }

    private static func commitDerivedLine(member: String) -> String {
        """
        registrar.commitDerived(key.appending(\\_ViewMembers.\(member))) {
                new.\(member)
            }
        """
    }
}

extension FeatureStateMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let access = accessPrefix(declaration)

        if let structDecl = declaration.as(StructDeclSyntax.self) {
            return expandStruct(structDecl, access: access, in: context)
        }
        if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            return expandEnum(enumDecl, access: access, in: context)
        }

        context.diagnose(
            Diagnostic(
                node: node.attributeName,
                message: MacroExpansionErrorMessage(
                    "'@FeatureState' can only be attached to structs and enums"
                )
            )
        )
        return []
    }

    private static func expandStruct(
        _ declaration: StructDeclSyntax,
        access: String,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard let members = collectVariableMembers(of: declaration, in: context) else {
            return []
        }
        if members.isEmpty {
            context.diagnose(
                Diagnostic(
                    node: Syntax(declaration.name),
                    message: MacroExpansionWarningMessage(
                        "every member is '@Domain' or private, so the type has no view surface; remove '@FeatureState' or expose a member"
                    )
                )
            )
        }
        diagnoseDerivedCycles(among: members, in: context)

        let typeName = declaration.name.text
        var commitBody: [String] = []
        for member in members where !member.isComputed {
            commitBody.append(diffLine(member: member.name))
        }
        for member in members where member.isComputed {
            commitBody.append(commitDerivedLine(member: member.name))
        }

        return [
            viewMembersStruct(access: access, entries: members.map { ($0.name, $0.type) }),
            viewKeyPathsMap(
                access: access, typeName: typeName,
                entries: members.map { ($0.name, $0.type) }),
            derivedMembersSet(
                access: access,
                names: members.filter(\.isComputed).map(\.name)),
            commitFunction(access: access, typeName: typeName, body: commitBody),
        ]
    }

    private static func expandEnum(
        _ declaration: EnumDeclSyntax,
        access: String,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard let computedMembers = collectVariableMembers(of: declaration, in: context)
        else { return [] }

        var existingNames: Set<String> = []
        for member in declaration.memberBlock.members {
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                        existingNames.insert(identifier.identifier.text)
                    }
                }
            }
            if let function = member.decl.as(FunctionDeclSyntax.self) {
                existingNames.insert(function.name.text)
            }
        }

        guard
            let cases = collectEnumCases(
                of: declaration, existingMemberNames: existingNames, in: context)
        else { return [] }

        let payloadCases = cases.filter(\.hasPayload)
        if payloadCases.isEmpty && computedMembers.isEmpty {
            context.diagnose(
                Diagnostic(
                    node: Syntax(declaration.name),
                    message: MacroExpansionWarningMessage(
                        "every member is '@Domain' or private, so the type has no view surface; remove '@FeatureState' or expose a member"
                    )
                )
            )
        }
        diagnoseDerivedCycles(among: computedMembers, in: context)

        let typeName = declaration.name.text
        var declarations: [DeclSyntax] = []

        // Case accessors: optional views over each single-payload case.
        for enumCase in payloadCases {
            declarations.append(
                """
                \(raw: access)var \(raw: enumCase.name): \(raw: enumCase.payloadType!)? {
                    guard case .\(raw: enumCase.name)(let value) = self else { return nil }
                    return value
                }
                """
            )
        }

        var entries: [(name: String, type: String)] = payloadCases.map {
            ($0.name, "\($0.payloadType!)?")
        }
        entries.append(contentsOf: computedMembers.map { ($0.name, $0.type) })

        // The case-identity switch: same case recurses into the payload; a case flip is one
        // coarse fire over everything under this slot.
        var switchArms: [String] = []
        for enumCase in cases {
            if enumCase.hasPayload {
                switchArms.append(
                    """
                    case (.\(enumCase.name)(let oldValue), .\(enumCase.name)(let newValue)):
                            \(moduleName)._diff(
                                oldValue, newValue,
                                registrar: registrar, key: key.appending(\\_ViewMembers.\(enumCase.name)))
                    """
                )
            } else {
                switchArms.append(
                    """
                    case (.\(enumCase.name), .\(enumCase.name)):
                            break
                    """
                )
            }
        }
        var commitBody: [String] = [
            """
            switch (old, new) {
                \(switchArms.joined(separator: "\n    "))
                default:
                    registrar.invalidate(prefix: key)
                    return
                }
            """
        ]
        for member in computedMembers where member.isComputed {
            commitBody.append(commitDerivedLine(member: member.name))
        }

        declarations.append(
            contentsOf: [
                viewMembersStruct(access: access, entries: entries),
                viewKeyPathsMap(access: access, typeName: typeName, entries: entries),
                derivedMembersSet(
                    access: access,
                    names: computedMembers.filter(\.isComputed).map(\.name)),
                commitFunction(access: access, typeName: typeName, body: commitBody),
            ]
        )
        return declarations
    }
}

extension FeatureStateMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) || declaration.is(EnumDeclSyntax.self)
        else { return [] }
        if let inheritanceClause = declaration.inheritanceClause,
            inheritanceClause.inheritedTypes.contains(where: {
                ["FeatureStateProtocol"]
                    .moduleQualified.contains($0.type.trimmedDescription)
            })
        {
            return []
        }
        let `extension`: DeclSyntax =
            """
            \(declaration.attributes.availability)extension \(type.trimmed): \(raw: moduleName).FeatureStateProtocol {}
            """
        return [`extension`.as(ExtensionDeclSyntax.self)].compactMap { $0 }
    }
}
