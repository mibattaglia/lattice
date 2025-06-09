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
        let conformance = "UnoArchitecture.Interactor"
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
            if macroGenerics.count > 2 {
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
                    !attributeName.starts(with: "UnoArchitecture.InteractorBuilder")
                else {
                    return []
                }
            }

            let builderArguments: TokenSyntax =
                if let macroGenerics {
                    .identifier("UnoArchitecture.InteractorBuilder<\(macroGenerics)>")
                } else if genericArgs.count == 1 {
                    .identifier(
                        "UnoArchitecture.InteractorBuilder<\(genericArgs.description).State, \(genericArgs.description).Action>"
                    )
                } else {
                    .identifier("UnoArchitecture.InteractorBuilder<\(genericArgs)>")
                }
            return [
                AttributeSyntax(
                    attributeName: IdentifierTypeSyntax(name: builderArguments)
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
        let memberBlock = declaration.memberBlock
        let existingTypeAliases = memberBlock
            .members
            .compactMap { member in
                let `typealias` = member.decl.as(TypeAliasDeclSyntax.self)
                if let `typealias` {
                    return `typealias`
                } else {
                    return nil
                }
            }

        let attributes = declaration.attributes
        guard let declAttr = attributes.first?.as(AttributeSyntax.self),
            let attrName = declAttr.attributeName.as(IdentifierTypeSyntax.self)
        else {
            // TODO: - Diagnostic?
            return []
        }

        if let generics = attrName.genericArgumentClause,
            generics.arguments.count == 2
        {
            let argumentsArray = generics
                .arguments
                .compactMap { $0.argument.as(IdentifierTypeSyntax.self) }
            let domainStateType = argumentsArray[0].name.text
            let eventType = argumentsArray[1].name.text
            var decls: [DeclSyntax] = []

            handleTypeAlias(
                existingTypeAliases,
                context: context,
                aliasType: .init(
                    rawValue: "DomainState",
                    typeName: domainStateType
                )
            ) {
                decls.append(
                    """
                    typealias DomainState = \(raw: domainStateType)
                    """
                )
            }

            handleTypeAlias(
                existingTypeAliases,
                context: context,
                aliasType: .init(
                    rawValue: "Action",
                    typeName: eventType
                )
            ) {
                decls.append(
                    """
                    typealias Action = \(raw: eventType)
                    """
                )
            }
            return decls
        } else {
            return []
        }
    }

    private static func handleTypeAlias<C: MacroExpansionContext>(
        _ aliases: [TypeAliasDeclSyntax],
        context: C,
        aliasType: TypeAliasType,
        addDecl: @escaping () -> Void
    ) {
        if let existing = aliases.first(where: { $0.name.text == aliasType.rawValue }) {
            context
                .diagnose(
                    Diagnostic(
                        node: existing,
                        message: MacroExpansionWarningMessage(
                            """
                            Consider removing explicit `typealias \(aliasType.rawValue) = \(aliasType.typeName)`. \
                            This is handled by the `@Interactor` macro.
                            """
                        )
                    )
                )
        } else {
            addDecl()
        }
    }
    private struct TypeAliasType {
        let rawValue: String
        let typeName: String
    }
}
