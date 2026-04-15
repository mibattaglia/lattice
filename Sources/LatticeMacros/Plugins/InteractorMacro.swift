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
        let conformance = "Lattice.Interactor"
        let `extension`: DeclSyntax =
            """
            \(declaration.attributes.availability)extension \(type.trimmed): \(raw: conformance) {}
            """
        return [`extension`.as(ExtensionDeclSyntax.self)].compactMap { $0 }
    }
}

extension InteractorMacro: MemberAttributeMacro {
    public static func expansion<D: DeclGroupSyntax, M: DeclSyntaxProtocol, C: MacroExpansionContext>(
        of node: AttributeSyntax,
        attachedTo declaration: D,
        providingAttributesFor member: M,
        in context: C
    ) throws -> [AttributeSyntax] {
        guard let macroGenerics = node.attributeName.as(IdentifierTypeSyntax.self)?.genericArgumentClause?.arguments
        else {
            return []
        }
        guard macroGenerics.count == 2 else {
            return []
        }
        if let body = member.as(VariableDeclSyntax.self),
            body.bindingSpecifier.text == "var",
            body.bindings.count == 1,
            let binding = body.bindings.first,
            let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
            identifier.text == "body",
            case .getter = binding.accessorBlock?.accessors
        {
            for attribute in body.attributes {
                guard case .attribute(let attributeSyntax) = attribute,
                    let attributeName = attributeSyntax.attributeName.as(IdentifierTypeSyntax.self)?.name.text
                else {
                    continue
                }
                guard !attributeName.starts(with: "InteractorBuilder"),
                    !attributeName.starts(with: "Lattice.InteractorBuilder")
                else {
                    return []
                }
            }

            let builderArguments: TokenSyntax =
                .identifier("Lattice.InteractorBuilder<\(macroGenerics)>")
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
        let attributes = declaration.attributes
        guard let declAttr = attributes.first?.as(AttributeSyntax.self),
            let attrName = declAttr.attributeName.as(IdentifierTypeSyntax.self)
        else {
            return []
        }

        guard let generics = attrName.genericArgumentClause else {
            context.diagnose(
                Diagnostic(
                    node: node.attributeName,
                    message: MacroExpansionErrorMessage(
                        """
                        @Interactor requires 2 generic arguments: \
                        one for the Interactor's state type and one for its action type.
                        """
                    )
                )
            )
            return []
        }

        guard generics.arguments.count == 2 else {
            context.diagnose(
                Diagnostic(
                    node: node.attributeName,
                    message: MacroExpansionErrorMessage(
                        """
                        @Interactor requires exactly 2 generic arguments: \
                        one for the Interactor's state type and one for its action type.
                        """
                    )
                )
            )
            return []
        }

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

        let argumentsArray = Array(generics.arguments)
        let domainStateType = argumentsArray[0].argument.trimmedDescription
        let eventType = argumentsArray[1].argument.trimmedDescription
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
