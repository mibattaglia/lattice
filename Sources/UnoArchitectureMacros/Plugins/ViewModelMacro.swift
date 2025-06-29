import Foundation
import SwiftDiagnostics
import SwiftOperators
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros

public enum ViewModelMacro {}

extension ViewModelMacro: ExtensionMacro {
    public static func expansion<D: DeclGroupSyntax, T: TypeSyntaxProtocol, C: MacroExpansionContext>(
        of node: AttributeSyntax,
        attachedTo declaration: D,
        providingExtensionsOf type: T,
        conformingTo protocols: [TypeSyntax],
        in context: C
    ) throws -> [ExtensionDeclSyntax] {
        // Check if the class already conforms to ViewModel
        if let inheritanceClause = declaration.inheritanceClause,
            inheritanceClause
                .inheritedTypes
                .contains(where: {
                    ["ViewModel"]
                        .moduleQualified.contains($0.type.trimmedDescription)
                })
        {
            return []
        }

        let conformance = "UnoArchitecture.ViewModel"
        let `extension`: DeclSyntax =
            """
            \(declaration.attributes.availability)extension \(type.trimmed): \(raw: conformance) {}
            """
        return [`extension`.as(ExtensionDeclSyntax.self)].compactMap { $0 }
    }
}

extension ViewModelMacro: MemberMacro {
    public static func expansion<D: DeclGroupSyntax, C: MacroExpansionContext>(
        of node: AttributeSyntax,
        providingMembersOf declaration: D,
        in context: C
    ) throws -> [DeclSyntax] {
        // Extract generic arguments from the macro
        guard let attrName = node.attributeName.as(IdentifierTypeSyntax.self),
            let generics = attrName.genericArgumentClause,
            generics.arguments.count == 2
        else {
            context.diagnose(
                Diagnostic(
                    node: node.attributeName,
                    message: MacroExpansionErrorMessage(
                        "@ViewModel macro requires exactly 2 generic arguments: ViewStateType and ViewEventType"
                    )
                )
            )
            return []
        }

        let argumentsArray = generics
            .arguments
            .compactMap { $0.argument.as(IdentifierTypeSyntax.self) }

        guard argumentsArray.count == 2 else {
            context.diagnose(
                Diagnostic(
                    node: node.attributeName,
                    message: MacroExpansionErrorMessage(
                        "Could not parse generic arguments for @ViewModel macro"
                    )
                )
            )
            return []
        }

        let viewStateType = argumentsArray[0].name.text
        let viewEventType = argumentsArray[1].name.text

        // Check for existing members to avoid conflicts
        let memberBlock = declaration.memberBlock
        let existingMembers = memberBlock.members.compactMap { member in
            if let varDecl = member.decl.as(VariableDeclSyntax.self),
                let binding = varDecl.bindings.first,
                let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
            {
                return pattern.identifier.text
            }
            if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
                return funcDecl.name.text
            }
            return nil
        }

        var declarations: [DeclSyntax] = []

        // Generate @Published viewState property if it doesn't exist
        if !existingMembers.contains("viewState") {
            declarations.append(
                """
                @Published private(set) var viewState: \(raw: viewStateType)
                """
            )
        }

        // Generate viewEvents subject if it doesn't exist
        if !existingMembers.contains("viewEvents") {
            declarations.append(
                """
                private let viewEvents = PassthroughSubject<\(raw: viewEventType), Never>()
                """
            )
        }

        // Generate sendViewEvent method if it doesn't exist
        if !existingMembers.contains("sendViewEvent") {
            declarations.append(
                """
                func sendViewEvent(_ event: \(raw: viewEventType)) {
                    viewEvents.send(event)
                }
                """
            )
        }

        return declarations
    }
}
