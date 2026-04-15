import Foundation
import SwiftDiagnostics
import SwiftOperators
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros

public enum ViewStateReducerMacro {}

extension ViewStateReducerMacro: ExtensionMacro {
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
                    ["ViewStateReducer"]
                        .moduleQualified.contains($0.type.trimmedDescription)
                })
        {
            return []
        }
        let conformance = "Lattice.ViewStateReducer"
        let `extension`: DeclSyntax =
            """
            \(declaration.attributes.availability)extension \(type.trimmed): \(raw: conformance) {}
            """
        return [`extension`.as(ExtensionDeclSyntax.self)].compactMap { $0 }
    }
}

extension ViewStateReducerMacro: MemberAttributeMacro {
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
                guard !attributeName.starts(with: "ViewStateReducerBuilder"),
                    !attributeName.starts(with: "Lattice.ViewStateReducerBuilder")
                else {
                    return []
                }
            }

            let builderArguments: TokenSyntax =
                .identifier("Lattice.ViewStateReducerBuilder<\(macroGenerics)>")
            return [
                AttributeSyntax(
                    attributeName: IdentifierTypeSyntax(name: builderArguments)
                )
            ]
        }
        return []
    }
}

extension ViewStateReducerMacro: MemberMacro {
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
                        @ViewStateReducer requires 2 generic arguments: \
                        one for the ViewStateReducer's domain state type and one for its view state type.
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
                        @ViewStateReducer requires exactly 2 generic arguments: \
                        one for the ViewStateReducer's domain state type and one for its view state type.
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

        let argumentsArray = generics
            .arguments
            .compactMap { $0.argument.as(IdentifierTypeSyntax.self) }
        let domainStateType = argumentsArray[0].name.text
        let viewStateType = argumentsArray[1].name.text
        var decls: [DeclSyntax] = []
        let hasInitialViewState = hasInitialViewStateMethod(in: memberBlock)
        let bodyUsesBuildViewState = bodyReferencesBuildViewState(in: memberBlock)
        let defaultValueProviderConformance = localDefaultValueProviderConformance(
            in: memberBlock,
            forTypeNamed: viewStateType
        )

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
                rawValue: "ViewState",
                typeName: viewStateType
            )
        ) {
            decls.append(
                """
                typealias ViewState = \(raw: viewStateType)
                """
            )
        }
        if !hasInitialViewState,
            bodyUsesBuildViewState
        {
            if defaultValueProviderConformance == false {
                context
                    .diagnose(
                        Diagnostic(
                            node: declaration,
                            message: MacroExpansionErrorMessage(
                                """
                                Missing `initialViewState(for:)` on this `@ViewStateReducer`. \
                                Add an explicit implementation or conform \(viewStateType) to DefaultValueProvider.
                                """
                            )
                        )
                    )
            } else {
                decls.append(
                    """
                    func initialViewState(for _: DomainState) -> ViewState {
                        .defaultValue
                    }
                    """
                )
            }
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
                            This is handled by the `@ViewStateReducer` macro.
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

    private static func hasInitialViewStateMethod(in memberBlock: MemberBlockSyntax) -> Bool {
        memberBlock.members.contains { member in
            guard let function = member.decl.as(FunctionDeclSyntax.self) else {
                return false
            }
            return function.name.text == "initialViewState"
        }
    }

    private static func bodyReferencesBuildViewState(in memberBlock: MemberBlockSyntax) -> Bool {
        memberBlock.members.contains { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                variable.bindings.count == 1,
                let binding = variable.bindings.first,
                let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
                identifier.text == "body"
            else {
                return false
            }

            let source = binding.description
            return source.contains("buildViewState") || source.contains("BuildViewState")
        }
    }

    private static func localDefaultValueProviderConformance(
        in memberBlock: MemberBlockSyntax,
        forTypeNamed typeName: String
    ) -> Bool? {
        for member in memberBlock.members {
            if let `struct` = member.decl.as(StructDeclSyntax.self),
                `struct`.name.text == typeName
            {
                return conformsToDefaultValueProvider(`struct`.inheritanceClause)
            }
            if let `enum` = member.decl.as(EnumDeclSyntax.self),
                `enum`.name.text == typeName
            {
                return conformsToDefaultValueProvider(`enum`.inheritanceClause)
            }
            if let `class` = member.decl.as(ClassDeclSyntax.self),
                `class`.name.text == typeName
            {
                return conformsToDefaultValueProvider(`class`.inheritanceClause)
            }
        }
        return nil
    }

    private static func conformsToDefaultValueProvider(_ inheritanceClause: InheritanceClauseSyntax?) -> Bool {
        guard let inheritanceClause else { return false }

        return inheritanceClause
            .inheritedTypes
            .contains { inheritedType in
                ["DefaultValueProvider"]
                    .moduleQualified
                    .contains(inheritedType.type.trimmedDescription)
            }
    }
}
