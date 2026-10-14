//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

// The observation codegen is lifted from The Composable Architecture:
// https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitectureMacros/ObservableStateMacro.swift

import SwiftDiagnostics
import SwiftOperators
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

#if !canImport(SwiftSyntax600)
    import SwiftSyntaxMacroExpansion
#endif

public struct FeatureStateMacro {
    static let moduleName = "Lattice"

    static let conformanceName = "FeatureState"
    static var qualifiedConformanceName: String {
        return "\(moduleName).\(conformanceName)"
    }
    static let originalConformanceName = "Observable"
    static var qualifiedOriginalConformanceName: String {
        "Observation.\(originalConformanceName)"
    }

    static var observableConformanceType: TypeSyntax {
        "\(raw: qualifiedConformanceName)"
    }

    static let registrarTypeName = "ObservationStateRegistrar"
    static var qualifiedRegistrarTypeName: String {
        "\(moduleName).\(registrarTypeName)"
    }

    static let idName = "ObservableStateID"
    static var qualifiedIDName: String {
        "\(moduleName).\(idName)"
    }

    static let trackedMacroName = "ObservationStateTracked"
    static let ignoredMacroName = "ObservationStateIgnored"

    static let registrarVariableName = "_$observationRegistrar"

    static func registrarVariable(_ observableType: TokenSyntax) -> DeclSyntax {
        return
            """
            @\(raw: ignoredMacroName) var \(raw: registrarVariableName) = \(raw: qualifiedRegistrarTypeName)()
            """
    }

    static func idVariable() -> DeclSyntax {
        return
            """
            public var _$id: \(raw: qualifiedIDName) {
            \(raw: registrarVariableName).id
            }
            """
    }

    static func willModifyFunction() -> DeclSyntax {
        return
            """
            public mutating func _$willModify() {
            \(raw: registrarVariableName)._$willModify()
            }
            """
    }

    static func shouldNotifyObserversNonEquatableFunction(
        _ perceptibleType: TokenSyntax, context: some MacroExpansionContext
    ) -> DeclSyntax {
        let memberGeneric = context.makeUniqueName("Member")
        return
            """
             private nonisolated func shouldNotifyObservers<\(memberGeneric)>(_ lhs: \(memberGeneric), _ rhs: \(memberGeneric)) -> Bool { true }
            """
    }

    static func shouldNotifyObserversEquatableFunction(
        _ perceptibleType: TokenSyntax, context: some MacroExpansionContext
    ) -> DeclSyntax {
        let memberGeneric = context.makeUniqueName("Member")
        return
            """
            private nonisolated func shouldNotifyObservers<\(memberGeneric): Equatable>(_ lhs: \(memberGeneric), _ rhs: \(memberGeneric)) -> Bool { lhs != rhs }
            """
    }

    static func shouldNotifyObserversNonEquatableObjectFunction(
        _ perceptibleType: TokenSyntax, context: some MacroExpansionContext
    ) -> DeclSyntax {
        let memberGeneric = context.makeUniqueName("Member")
        return
            """
             private nonisolated func shouldNotifyObservers<\(memberGeneric): AnyObject>(_ lhs: \(memberGeneric), _ rhs: \(memberGeneric)) -> Bool { lhs !== rhs }
            """
    }

    static func shouldNotifyObserversEquatableObjectFunction(
        _ perceptibleType: TokenSyntax, context: some MacroExpansionContext
    ) -> DeclSyntax {
        let memberGeneric = context.makeUniqueName("Member")
        return
            """
            private nonisolated func shouldNotifyObservers<\(memberGeneric): Equatable & AnyObject>(_ lhs: \(memberGeneric), _ rhs: \(memberGeneric)) -> Bool { lhs != rhs }
            """
    }

    static var ignoredAttribute: AttributeSyntax {
        AttributeSyntax(
            leadingTrivia: .space,
            atSign: .atSignToken(),
            attributeName: IdentifierTypeSyntax(name: .identifier(ignoredMacroName)),
            trailingTrivia: .space
        )
    }
}

extension FeatureStateMacro: MemberMacro {
    #if canImport(SwiftSyntax601)
        public static func expansion(
            of node: AttributeSyntax,
            providingMembersOf declaration: some DeclGroupSyntax,
            conformingTo protocols: [TypeSyntax],
            in context: some MacroExpansionContext
        ) throws -> [DeclSyntax] {
            try _expansion(
                of: node,
                providingMembersOf: declaration,
                conformingTo: protocols,
                in: context
            )
        }
    #else
        public static func expansion<
            Declaration: DeclGroupSyntax,
            Context: MacroExpansionContext
        >(
            of node: AttributeSyntax,
            providingMembersOf declaration: Declaration,
            in context: Context
        ) throws -> [DeclSyntax] {
            try _expansion(of: node, providingMembersOf: declaration, conformingTo: [], in: context)
        }
    #endif

    private static func _expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if let diagnostic = genericStateDiagnostic(for: declaration) {
            context.diagnose(diagnostic)
            return []
        }

        guard !declaration.isEnum
        else {
            return try enumExpansion(of: node, providingMembersOf: declaration, in: context)
                + viewStateDeclarations(of: declaration, in: context)
        }

        guard let identified = declaration.asProtocol((any NamedDeclSyntax).self) else {
            return []
        }

        let observableType = identified.name.trimmed

        if declaration.isClass {
            // classes are not supported
            throw DiagnosticsError(
                syntax: node,
                message: "'@FeatureState' cannot be applied to class type '\(observableType.text)'",
                id: .invalidApplication
            )
        }
        if declaration.isActor {
            // actors cannot yet be supported for their isolation
            throw DiagnosticsError(
                syntax: node,
                message: "'@FeatureState' cannot be applied to actor type '\(observableType.text)'",
                id: .invalidApplication
            )
        }

        var declarations = [DeclSyntax]()

        declaration.addIfNeeded(
            FeatureStateMacro.registrarVariable(observableType),
            to: &declarations
        )
        declaration.addIfNeeded(FeatureStateMacro.idVariable(), to: &declarations)
        declaration.addIfNeeded(FeatureStateMacro.willModifyFunction(), to: &declarations)
        declaration.addIfNeeded(
            FeatureStateMacro.shouldNotifyObserversNonEquatableFunction(
                observableType, context: context), to: &declarations)
        declaration.addIfNeeded(
            FeatureStateMacro.shouldNotifyObserversEquatableFunction(observableType, context: context),
            to: &declarations)
        declaration.addIfNeeded(
            FeatureStateMacro.shouldNotifyObserversNonEquatableObjectFunction(
                observableType, context: context), to: &declarations)
        declaration.addIfNeeded(
            FeatureStateMacro.shouldNotifyObserversEquatableObjectFunction(
                observableType, context: context), to: &declarations)

        declarations += viewStateDeclarations(of: declaration, in: context)

        return declarations
    }
}

extension [FeatureStateCase] {
    init(members: MemberBlockItemListSyntax) {
        var tag = 0
        self.init(members: members, tag: &tag)
    }

    init(members: MemberBlockItemListSyntax, tag: inout Int) {
        self = members.flatMap { member -> [FeatureStateCase] in
            if let enumCaseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
                return enumCaseDecl.elements.map {
                    defer { tag += 1 }
                    return FeatureStateCase.element($0, tag: tag)
                }
            }
            if let ifConfigDecl = member.decl.as(IfConfigDeclSyntax.self) {
                let configs = ifConfigDecl.clauses.flatMap { decl -> [FeatureStateCase.IfConfig] in
                    guard let elements = decl.elements?.as(MemberBlockItemListSyntax.self)
                    else { return [] }
                    return [
                        FeatureStateCase.IfConfig(
                            poundKeyword: decl.poundKeyword,
                            condition: decl.condition,
                            cases: Array(members: elements, tag: &tag)
                        )
                    ]
                }
                return [.ifConfig(configs)]
            }
            return []
        }
    }
}

enum FeatureStateCase {
    case element(EnumCaseElementSyntax, tag: Int)
    indirect case ifConfig([IfConfig])

    struct IfConfig {
        let poundKeyword: TokenSyntax
        let condition: ExprSyntax?
        let cases: [FeatureStateCase]
    }

    var getCase: String {
        switch self {
        case .element(let element, let tag):
            if let parameters = element.parameterClause?.parameters, parameters.count == 1 {
                return """
                    case let .\(element.name.text)(state):
                    return ._$id(for: state)._$tag(\(tag))
                    """
            } else {
                return """
                    case .\(element.name.text):
                    return ObservableStateID._$inert._$tag(\(tag))
                    """
            }
        case .ifConfig(let configs):
            return
                configs
                .map {
                    """
                    \($0.poundKeyword.text) \($0.condition?.trimmedDescription ?? "")
                    \($0.cases.map(\.getCase).joined(separator: "\n"))
                    """
                }
                .joined(separator: "\n") + "#endif\n"
        }
    }

    var willModifyCase: String {
        switch self {
        case .element(let element, _):
            if let parameters = element.parameterClause?.parameters,
                parameters.count == 1,
                let parameter = parameters.first
            {
                return """
                    case var .\(element.name.text)(state):
                    \(FeatureStateMacro.moduleName)._$willModify(&state)
                    self = .\(element.name.text)(\(parameter.firstName.map { "\($0): " } ?? "")state)
                    """
            } else {
                return """
                    case .\(element.name.text):
                    break
                    """
            }
        case .ifConfig(let configs):
            return
                configs
                .map {
                    """
                    \($0.poundKeyword.text) \($0.condition?.trimmedDescription ?? "")
                    \($0.cases.map(\.willModifyCase).joined(separator: "\n"))
                    """
                }
                .joined(separator: "\n") + "#endif\n"
        }
    }
}

extension FeatureStateMacro {
    public static func enumExpansion<
        Declaration: DeclGroupSyntax,
        Context: MacroExpansionContext
    >(
        of node: AttributeSyntax,
        providingMembersOf declaration: Declaration,
        in context: Context
    ) throws -> [DeclSyntax] {
        let cases = [FeatureStateCase](members: declaration.memberBlock.members)
        var getCases: [String] = []
        var willModifyCases: [String] = []
        for enumCase in cases {
            getCases.append(enumCase.getCase)
            willModifyCases.append(enumCase.willModifyCase)
        }

        return [
            """
            public var _$id: \(raw: qualifiedIDName) {
            switch self {
            \(raw: getCases.joined(separator: "\n"))
            }
            }
            """,
            """
            public mutating func _$willModify() {
            switch self {
            \(raw: willModifyCases.joined(separator: "\n"))
            }
            }
            """,
        ]
    }
}

extension FeatureStateMacro: MemberAttributeMacro {
    public static func expansion<
        Declaration: DeclGroupSyntax,
        MemberDeclaration: DeclSyntaxProtocol,
        Context: MacroExpansionContext
    >(
        of node: AttributeSyntax,
        attachedTo declaration: Declaration,
        providingAttributesFor member: MemberDeclaration,
        in context: Context
    ) throws -> [AttributeSyntax] {
        // A generic state gets no members (the member role diagnoses it), so tracking accessors
        // would reference a registrar that does not exist.
        if isGenericState(declaration) {
            return []
        }

        guard let property = member.as(VariableDeclSyntax.self), property.isValidForObservation,
            property.identifier != nil
        else {
            return []
        }

        // dont apply to ignored properties or properties that are already flagged as tracked
        if property.hasMacroApplication(FeatureStateMacro.ignoredMacroName)
            || property.hasMacroApplication(FeatureStateMacro.trackedMacroName)
        {
            return []
        }

        property.diagnose(
            attribute: "ObservationIgnored",
            renamed: FeatureStateMacro.ignoredMacroName,
            context: context
        )
        property.diagnose(
            attribute: "ObservationTracked",
            renamed: FeatureStateMacro.trackedMacroName,
            context: context
        )

        return [
            AttributeSyntax(
                attributeName: IdentifierTypeSyntax(
                    name: .identifier(FeatureStateMacro.trackedMacroName)
                )
            )
        ]
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
        // This method can be called twice - first with an empty `protocols` when
        // no conformance is needed, and second with a `MissingTypeSyntax` instance.
        if protocols.isEmpty {
            return []
        }

        if let diagnostic = genericStateDiagnostic(for: declaration) {
            context.diagnose(diagnostic)
            return []
        }

        // A reserved-name collision suppresses the generated `ViewState` (the member role
        // diagnoses it), so only the observation conformance can be added.
        let conformances =
            reservedViewStateNameTokens(in: declaration.memberBlock.members).isEmpty
            ? "\(qualifiedConformanceName), Observation.Observable"
            : "Observation.Observable"

        return [
            ("""
            \(declaration.attributes.availability)extension \(raw: type.trimmedDescription): \
            \(raw: conformances) {}
            """ as DeclSyntax)
            .cast(ExtensionDeclSyntax.self)
        ]
    }
}
