import Foundation
import SwiftDiagnostics
import SwiftOperators
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros

public enum InteractorMacro {}

extension InteractorMacro: ExtensionMacro {
    public static func expansion<D: DeclGroupSyntax, T: TypeSyntaxProtocol, C: MacroExpansionContext>(
        of node: AttributeSyntax,
        attachedTo declaration: D,
        providingExtensionsOf type: T,
        conformingTo protocols: [TypeSyntax],
        in context: C
    ) throws -> [ExtensionDeclSyntax] {
        if let inheritanceClause = declaration.inheritanceClause,
            inheritanceClause
                .inheritedTypes
                .contains(where: {
                    ["Interactor"]
                        .moduleQualified.contains($0.type.trimmedDescription)
                })
        {
            return []
        }
        let conformance = "DomainArchitecture.Interactor"
        let `extension`: DeclSyntax =
            """
            \(declaration.attributes.availability)extension \(type.trimmed): \(raw: conformance) {}
            """
        return [`extension`.cast(ExtensionDeclSyntax.self)]
    }
}

extension InteractorMacro: MemberAttributeMacro {
    public static func expansion<D: DeclGroupSyntax, M: DeclSyntaxProtocol, C: MacroExpansionContext>(
        of node: AttributeSyntax,
        attachedTo declaration: D,
        providingAttributesFor member: M,
        in context: C
    ) throws -> [AttributeSyntax] {
        let macroGenerics = node.attributeName.as(IdentifierTypeSyntax.self)?.genericArgumentClause?.arguments
        if let macroGenerics {
            guard macroGenerics.count == 2 else {
                context
                    .diagnose(
                        Diagnostic(
                            node: node.attributeName,
                            message: MacroExpansionErrorMessage(
                                """
                                Only 2 generic arguments should be applied the @Interactor macro. \
                                One for the Interactor's state type and one for its action type. 
                                """
                            )
                        )
                    )
                return []
            }
        }
        if let body = member.as(VariableDeclSyntax.self),
            body.bindingSpecifier.text == "var",
            body.bindings.count == 1,
            let binding = body.bindings.first,
            let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
            identifier.text == "body",
            case .getter = binding.accessorBlock?.accessors,
            let genericArgs = binding.typeAnnotation?
                .type.as(SomeOrAnyTypeSyntax.self)?
                .constraint.as(IdentifierTypeSyntax.self)?
                .genericArgumentClause?
                .arguments
        {
            if macroGenerics != nil,
                genericArgs.count != 1,
                let argument = genericArgs.first?.argument.as(IdentifierTypeSyntax.self)?.name.text,
                argument != "Self"
            {
                let bodyGenericArgNames =
                    genericArgs
                    .compactMap { $0.argument.as(IdentifierTypeSyntax.self)?.name.text }
                var newTypeAnnotation = binding.typeAnnotation
                let interactorOr = SomeOrAnyTypeSyntax(
                    someOrAnySpecifier: .identifier("some"),
                    constraint: TypeSyntax(stringLiteral: " InteractorOf<Self>"),
                    trailingTrivia: Trivia(pieces: [TriviaPiece.spaces(1)])
                )
                newTypeAnnotation?.type = TypeSyntax(interactorOr)

                context.diagnose(
                    Diagnostic(
                        node: identifier,
                        message: MacroExpansionErrorMessage(
                            """
                            Generic parameters have already been applied to the attached \
                            macro and will take precedence over those specified in `body`
                            """
                        ),
                        fixIt: .replace(
                            message: MacroExpansionFixItMessage(
                                """
                                Replace 'some Interactor<\(bodyGenericArgNames.joined(separator: ", "))>' \
                                with 'some InteractorOf<Self>'
                                """
                            ),
                            oldNode: binding,
                            newNode:
                                binding
                                .with(\.typeAnnotation, newTypeAnnotation)
                        )
                    )
                )
                return []
            }
            for attribute in body.attributes {
                guard case let .attribute(attributeSyntax) = attribute,
                    let attributeName = attributeSyntax.attributeName.as(IdentifierTypeSyntax.self)?.name.text
                else {
                    continue
                }
                guard !attributeName.starts(with: "InteractorBuilder"),
                    !attributeName.starts(with: "DomainArchitecture.InteractorBuilder")
                else {
                    return []
                }
            }
            return [
                AttributeSyntax(
                    attributeName: IdentifierTypeSyntax(
                        name: .identifier("DomainArchitecture.InteractorBuilder<\(macroGenerics ?? genericArgs)>")
                    )
                )
            ]
        }
        return []
    }
}

extension InteractorMacro: MemberMacro {
    public static func expansion<D: DeclGroupSyntax, C: MacroExpansionContext>(
        of node: AttributeSyntax,
        providingMembersOf declaration: D,
        in context: C
    ) throws -> [DeclSyntax] {
        []
    }
}

extension [String] {
    var moduleQualified: Self {
        self.flatMap { [$0, "DomainArchitecture.\($0)"] }
    }
}

extension AttributeSyntax {
    var availability: AttributeSyntax? {
        if attributeName.identifier == "available" {
            return self
        } else {
            return nil
        }
    }
}

extension TypeSyntax {
    var identifier: String? {
        for token in tokens(viewMode: .all) {
            switch token.tokenKind {
            case .identifier(let identifier):
                return identifier
            default:
                break
            }
        }
        return nil
    }
}

extension AttributeListSyntax.Element {
    var availability: AttributeListSyntax.Element? {
        switch self {
        case .attribute(let attribute):
            if let availability = attribute.availability {
                return .attribute(availability)
            }
        case .ifConfigDecl(let ifConfig):
            if let availability = ifConfig.availability {
                return .ifConfigDecl(availability)
            }
        }
        return nil
    }
}

extension AttributeListSyntax {
    var availability: AttributeListSyntax? {
        var elements = [AttributeListSyntax.Element]()
        for element in self {
            if let availability = element.availability {
                elements.append(availability)
            }
        }
        if elements.isEmpty {
            return nil
        }
        return AttributeListSyntax(elements)
    }
}

extension IfConfigDeclSyntax {
    var availability: IfConfigDeclSyntax? {
        var elements = [IfConfigClauseListSyntax.Element]()
        for clause in clauses {
            if let availability = clause.availability {
                if elements.isEmpty {
                    elements.append(availability.clonedAsIf)
                } else {
                    elements.append(availability)
                }
            }
        }
        if elements.isEmpty {
            return nil
        } else {
            return with(\.clauses, IfConfigClauseListSyntax(elements))
        }
    }
}

extension IfConfigClauseSyntax {
    var availability: IfConfigClauseSyntax? {
        if let availability = elements?.availability {
            return with(\.elements, availability)
        } else {
            return nil
        }
    }

    var clonedAsIf: IfConfigClauseSyntax {
        detached.with(\.poundKeyword, .poundIfToken())
    }
}

extension IfConfigClauseSyntax.Elements {
    var availability: IfConfigClauseSyntax.Elements? {
        switch self {
        case .attributes(let attributes):
            if let availability = attributes.availability {
                return .attributes(availability)
            } else {
                return nil
            }
        default:
            return nil
        }
    }
}
