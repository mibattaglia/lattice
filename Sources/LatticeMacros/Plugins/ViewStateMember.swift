import SwiftSyntax

/// A member of a `@FeatureState` type that shapes its `ViewState`, in declaration order, with
/// `#if` blocks preserved.
indirect enum ViewStateMember {
    /// An instance property that is not `private`/`fileprivate`. `type` is the explicit
    /// annotation, if any.
    case property(name: TokenSyntax, type: TypeSyntax?, isDomain: Bool)
    case enumCase(ViewStateCase)
    case ifConfig([IfConfigClause])

    struct IfConfigClause {
        /// `#if CONDITION`, `#elseif CONDITION` or `#else`.
        let header: String
        let members: [ViewStateMember]
    }

    static func members(of items: MemberBlockItemListSyntax) -> [ViewStateMember] {
        var members: [ViewStateMember] = []
        for item in items {
            if let ifConfig = item.decl.as(IfConfigDeclSyntax.self) {
                members.append(
                    .ifConfig(
                        ifConfig.clauses.map { clause in
                            var nested: [ViewStateMember] = []
                            if case .decls(let decls) = clause.elements {
                                nested = Self.members(of: decls)
                            }
                            return IfConfigClause(
                                header: clause.poundKeyword.text
                                    + (clause.condition.map { " \($0.trimmedDescription)" } ?? ""),
                                members: nested
                            )
                        }
                    )
                )
            } else if let variable = item.decl.as(VariableDeclSyntax.self) {
                // `private(set)` and `fileprivate(set)` only restrict the setter.
                let isPrivate = variable.modifiers.contains {
                    ($0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate))
                        && $0.detail == nil
                }
                guard variable.isInstance, !isPrivate else { continue }
                let isDomain = FeatureStateMacro.domainAttribute(in: variable.attributes) != nil
                for binding in variable.bindings {
                    guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier
                    else { continue }
                    members.append(
                        .property(name: name.trimmed, type: binding.typeAnnotation?.type.trimmed, isDomain: isDomain)
                    )
                }
            } else if let caseDecl = item.decl.as(EnumCaseDeclSyntax.self) {
                let isIndirect = caseDecl.modifiers.contains { $0.name.tokenKind == .keyword(.indirect) }
                for element in caseDecl.elements {
                    members.append(
                        .enumCase(
                            ViewStateCase(
                                name: element.name.trimmed,
                                isIndirect: isIndirect,
                                payloads: (element.parameterClause?.parameters ?? []).map { parameter in
                                    ViewStateCase.Payload(
                                        label: parameter.firstName.flatMap {
                                            $0.tokenKind == .wildcard ? nil : $0.trimmed
                                        },
                                        type: parameter.type.trimmed
                                    )
                                }
                            )
                        )
                    )
                }
            }
        }
        return members
    }
}

struct ViewStateCase {
    struct Payload {
        let label: TokenSyntax?
        let type: TypeSyntax
    }

    let name: TokenSyntax
    let isIndirect: Bool
    let payloads: [Payload]

    /// The associated type naming the projected type of the payload at `index`.
    func witnessName(_ index: Int) -> String { "\(name.bareText)_\(index)" }
}
