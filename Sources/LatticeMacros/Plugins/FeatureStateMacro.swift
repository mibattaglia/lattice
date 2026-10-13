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
    static let presentsMacroName = "Presents"
    static let presentationStatePropertyWrapperName = "PresentationState"

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

struct ObservationDiagnostic: DiagnosticMessage {
    enum ID: String {
        case invalidApplication = "invalid type"
        case missingInitializer = "missing initializer"
    }

    var message: String
    var diagnosticID: MessageID
    var severity: DiagnosticSeverity

    init(
        message: String,
        diagnosticID: SwiftDiagnostics.MessageID,
        severity: SwiftDiagnostics.DiagnosticSeverity = .error
    ) {
        self.message = message
        self.diagnosticID = diagnosticID
        self.severity = severity
    }

    init(
        message: String,
        domain: String,
        id: ID,
        severity: SwiftDiagnostics.DiagnosticSeverity = .error
    ) {
        self.message = message
        self.diagnosticID = MessageID(domain: domain, id: id.rawValue)
        self.severity = severity
    }
}

extension DiagnosticsError {
    init<S: SyntaxProtocol>(
        syntax: S,
        message: String,
        domain: String = "Observation",
        id: ObservationDiagnostic.ID,
        severity: SwiftDiagnostics.DiagnosticSeverity = .error
    ) {
        self.init(diagnostics: [
            Diagnostic(
                node: Syntax(syntax),
                message: ObservationDiagnostic(message: message, domain: domain, id: id, severity: severity)
            )
        ])
    }
}

extension DeclModifierListSyntax {
    func privatePrefixed(_ prefix: String) -> DeclModifierListSyntax {
        let modifier: DeclModifierSyntax = DeclModifierSyntax(name: "private", trailingTrivia: .space)
        return [modifier]
            + filter {
                switch $0.name.tokenKind {
                case .keyword(let keyword):
                    switch keyword {
                    case .fileprivate, .private, .internal, .public, .package:
                        return false
                    default:
                        return true
                    }
                default:
                    return true
                }
            }
    }

    init(keyword: Keyword) {
        self.init([DeclModifierSyntax(name: .keyword(keyword))])
    }
}

extension TokenSyntax {
    func privatePrefixed(_ prefix: String) -> TokenSyntax {
        switch tokenKind {
        case .identifier(let identifier):
            return TokenSyntax(
                .identifier(prefix + identifier),
                leadingTrivia: leadingTrivia,
                trailingTrivia: trailingTrivia,
                presence: presence
            )
        default:
            return self
        }
    }
}

extension PatternBindingListSyntax {
    func privatePrefixed(_ prefix: String) -> PatternBindingListSyntax {
        var bindings = self.map { $0 }
        for index in 0..<bindings.count {
            let binding = bindings[index]
            if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                bindings[index] = PatternBindingSyntax(
                    leadingTrivia: binding.leadingTrivia,
                    pattern: IdentifierPatternSyntax(
                        leadingTrivia: identifier.leadingTrivia,
                        identifier: identifier.identifier.privatePrefixed(prefix),
                        trailingTrivia: identifier.trailingTrivia
                    ),
                    typeAnnotation: binding.typeAnnotation,
                    initializer: binding.initializer,
                    accessorBlock: binding.accessorBlock,
                    trailingComma: binding.trailingComma,
                    trailingTrivia: binding.trailingTrivia
                )

            }
        }

        return PatternBindingListSyntax(bindings)
    }
}

extension VariableDeclSyntax {
    func privatePrefixed(_ prefix: String, addingAttribute attribute: AttributeSyntax)
        -> VariableDeclSyntax
    {
        let newAttributes = attributes + [.attribute(attribute)]
        return VariableDeclSyntax(
            leadingTrivia: leadingTrivia,
            attributes: newAttributes,
            modifiers: modifiers.privatePrefixed(prefix),
            bindingSpecifier: TokenSyntax(
                bindingSpecifier.tokenKind,
                leadingTrivia: .space,
                trailingTrivia: .space,
                presence: .present
            ),
            bindings: bindings.privatePrefixed(prefix),
            trailingTrivia: trailingTrivia
        )
    }

    var isValidForObservation: Bool {
        !isComputed && isInstance && !isImmutable && identifier != nil
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

extension SyntaxStringInterpolation {
    // It would be nice for SwiftSyntaxBuilder to provide this out-of-the-box.
    mutating func appendInterpolation<Node: SyntaxProtocol>(_ node: Node?) {
        if let node {
            appendInterpolation(node)
        }
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
        property.diagnose(
            attribute: "PresentationState",
            renamed: FeatureStateMacro.presentsMacroName,
            context: context
        )

        if property.hasMacroApplication(FeatureStateMacro.presentsMacroName)
            || knownSupportedPropertyWrappers.contains(where: property.hasMacroApplication)
        {
            return [
                AttributeSyntax(
                    attributeName: IdentifierTypeSyntax(
                        name: .identifier(FeatureStateMacro.ignoredMacroName)
                    )
                )
            ]
        }

        return [
            AttributeSyntax(
                attributeName: IdentifierTypeSyntax(
                    name: .identifier(FeatureStateMacro.trackedMacroName)
                )
            )
        ]
    }
}

extension VariableDeclSyntax {
    func diagnose<C: MacroExpansionContext>(
        attribute name: String,
        renamed rename: String,
        context: C
    ) {
        if let attribute = self.firstAttribute(for: name),
            let type = attribute.attributeName.as(IdentifierTypeSyntax.self)
        {
            context.diagnose(
                Diagnostic(
                    node: attribute,
                    message: MacroExpansionErrorMessage("'@\(name)' cannot be used in '@FeatureState'"),
                    fixIt: .replace(
                        message: MacroExpansionFixItMessage("Use '@\(rename)' instead"),
                        oldNode: attribute,
                        newNode: attribute.with(
                            \.attributeName,
                            TypeSyntax(
                                type.with(
                                    \.name,
                                    .identifier(rename, trailingTrivia: type.name.trailingTrivia)
                                )
                            )
                        )
                    )
                )
            )
        }
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

public struct ObservationStateTrackedMacro: AccessorMacro {
    public static func expansion<
        Context: MacroExpansionContext,
        Declaration: DeclSyntaxProtocol
    >(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: Declaration,
        in context: Context
    ) throws -> [AccessorDeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self),
            property.isValidForObservation,
            let identifier = property.identifier?.trimmed
        else {
            return []
        }

        if property.hasMacroApplication(FeatureStateMacro.ignoredMacroName)
            || property.hasMacroApplication(FeatureStateMacro.presentationStatePropertyWrapperName)
            || property.hasMacroApplication(FeatureStateMacro.presentsMacroName)
            || knownSupportedPropertyWrappers.contains(where: property.hasMacroApplication)
        {
            return []
        }

        let initAccessor: AccessorDeclSyntax =
            """
            @storageRestrictions(initializes: _\(identifier))
            init(initialValue) {
            _\(identifier) = initialValue
            }
            """

        let getAccessor: AccessorDeclSyntax =
            """
            get {
            \(raw: FeatureStateMacro.registrarVariableName).access(self, keyPath: \\.\(identifier))
            return _\(identifier)
            }
            """

        let setAccessor: AccessorDeclSyntax =
            """
            set {
            \(raw: FeatureStateMacro.registrarVariableName).mutate(self, keyPath: \\.\(identifier), &_\(identifier), newValue, _$isIdentityEqual, shouldNotifyObservers)
            }
            """
        let modifyAccessor: AccessorDeclSyntax = """
            _modify {
              let oldValue = _$observationRegistrar.willModify(self, keyPath: \\.\(identifier), &_\(identifier))
              defer {
                _$observationRegistrar.didModify(self, keyPath: \\.\(identifier), &_\(identifier), oldValue, _$isIdentityEqual)
              }
              yield &_\(identifier)
            }
            """

        return [initAccessor, getAccessor, setAccessor, modifyAccessor]
    }
}

extension ObservationStateTrackedMacro: PeerMacro {
    public static func expansion<
        Context: MacroExpansionContext,
        Declaration: DeclSyntaxProtocol
    >(
        of node: SwiftSyntax.AttributeSyntax,
        providingPeersOf declaration: Declaration,
        in context: Context
    ) throws -> [DeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self),
            property.isValidForObservation
        else {
            return []
        }

        if property.hasMacroApplication(FeatureStateMacro.ignoredMacroName)
            || property.hasMacroApplication(FeatureStateMacro.presentationStatePropertyWrapperName)
            || property.hasMacroApplication(FeatureStateMacro.presentsMacroName)
            || knownSupportedPropertyWrappers.contains(where: property.hasMacroApplication)
            || property.hasMacroApplication(FeatureStateMacro.trackedMacroName)
        {
            return []
        }

        let storage = DeclSyntax(
            property.privatePrefixed("_", addingAttribute: FeatureStateMacro.ignoredAttribute)
        )
        return [storage]
    }
}

public struct ObservationStateIgnoredMacro: AccessorMacro {
    public static func expansion<
        Context: MacroExpansionContext,
        Declaration: DeclSyntaxProtocol
    >(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: Declaration,
        in context: Context
    ) throws -> [AccessorDeclSyntax] {
        return []
    }
}

private let knownSupportedPropertyWrappers = [
    "Shared", "SharedReader", "Fetch", "FetchAll", "FetchOne",
]

// MARK: - ViewState projection

extension FeatureStateMacro {
    static let viewStateTypeName = "ViewState"
    static let viewStateTypesProtocolName = "_$ViewStateTypes"
    static let viewStateWitnessTypeName = "_$ViewStateWitness"
    static let viewStateStorageName = "_state"
    static let domainMacroName = "Domain"
    static let casePathableMacroName = "CasePathable"

    /// Names of the declarations `@FeatureState` adds to the state type.
    static let reservedTypeMemberNames: Set<String> = [
        viewStateTypeName, viewStateTypesProtocolName, viewStateWitnessTypeName,
    ]

    static func isGenericState(_ declaration: some DeclGroupSyntax) -> Bool {
        declaration.as(StructDeclSyntax.self)?.genericParameterClause != nil
            || declaration.as(EnumDeclSyntax.self)?.genericParameterClause != nil
    }

    static func genericStateDiagnostic(for declaration: some DeclGroupSyntax) -> Diagnostic? {
        let name: TokenSyntax
        let genericParameters: GenericParameterClauseSyntax
        if let structDecl = declaration.as(StructDeclSyntax.self),
            let clause = structDecl.genericParameterClause
        {
            name = structDecl.name
            genericParameters = clause
        } else if let enumDecl = declaration.as(EnumDeclSyntax.self),
            let clause = enumDecl.genericParameterClause
        {
            name = enumDecl.name
            genericParameters = clause
        } else {
            return nil
        }
        return Diagnostic(
            node: genericParameters,
            message: ViewStateDiagnostic.genericState(name.trimmed.text)
        )
    }

    /// Name tokens of state members that the generated declarations would redeclare.
    static func reservedViewStateNameTokens(in items: MemberBlockItemListSyntax) -> [TokenSyntax] {
        var tokens: [TokenSyntax] = []
        for item in items {
            let decl = item.decl
            if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                for clause in ifConfig.clauses {
                    if case .decls(let decls) = clause.elements {
                        tokens += reservedViewStateNameTokens(in: decls)
                    }
                }
            } else if let variable = decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
                        isReservedName(name, includingStorage: true)
                    {
                        tokens.append(name)
                    }
                }
            } else if let enumCase = decl.as(EnumCaseDeclSyntax.self) {
                for element in enumCase.elements where isReservedName(element.name, includingStorage: true) {
                    tokens.append(element.name)
                }
            } else if let named = decl.asProtocol((any NamedDeclSyntax).self),
                isReservedName(named.name, includingStorage: false)
            {
                tokens.append(named.name)
            }
        }
        return tokens
    }

    private static func isReservedName(_ name: TokenSyntax, includingStorage: Bool) -> Bool {
        reservedTypeMemberNames.contains(name.bareText)
            || (includingStorage && name.bareText == viewStateStorageName)
    }

    static func domainAttribute(in attributes: AttributeListSyntax) -> AttributeSyntax? {
        for element in attributes {
            guard case .attribute(let attribute) = element else { continue }
            let name = attribute.attributeName.trimmedDescription
            if name == domainMacroName || name == "\(moduleName).\(domainMacroName)" {
                return attribute
            }
        }
        return nil
    }

    /// Diagnoses `@Domain` applications that `@FeatureState` cannot honor.
    static func diagnoseDomainMisuse(
        in items: MemberBlockItemListSyntax,
        isIdentifiable: Bool,
        in context: some MacroExpansionContext
    ) {
        for item in items {
            let decl = item.decl
            if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                for clause in ifConfig.clauses {
                    if case .decls(let decls) = clause.elements {
                        diagnoseDomainMisuse(in: decls, isIdentifiable: isIdentifiable, in: context)
                    }
                }
                continue
            }
            guard let attributes = decl.asProtocol((any WithAttributesSyntax).self)?.attributes,
                let domain = domainAttribute(in: attributes)
            else {
                continue
            }
            if let variable = decl.as(VariableDeclSyntax.self), variable.isInstance {
                if isIdentifiable, variable.bindingNames.contains(where: { $0.bareText == "id" }) {
                    context.diagnose(
                        Diagnostic(node: domain, message: ViewStateDiagnostic.domainIdentifiableID)
                    )
                }
            } else {
                context.diagnose(Diagnostic(node: domain, message: ViewStateDiagnostic.domainNotProperty))
            }
        }
    }

    /// The `_$ViewStateTypes` protocol, `_$ViewStateWitness` struct and `ViewState` projection.
    static func viewStateDeclarations(
        of declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard let typeName = declaration.asProtocol((any NamedDeclSyntax).self)?.name.trimmed.text
        else {
            return []
        }
        let inheritedTypeNames = declaration.inheritedTypeNames
        let isIdentifiable = inheritedTypeNames.contains("Identifiable")

        diagnoseDomainMisuse(
            in: declaration.memberBlock.members, isIdentifiable: isIdentifiable, in: context
        )
        let reservedNames = reservedViewStateNameTokens(in: declaration.memberBlock.members)
        for name in reservedNames {
            context.diagnose(Diagnostic(node: name, message: ViewStateDiagnostic.reservedName(name.bareText)))
        }
        guard reservedNames.isEmpty else { return [] }

        var attributes: [String] = []
        if let availability = declaration.attributes.availability {
            attributes.append(availability.trimmedDescription)
        }
        attributes.append("@\(moduleName)._IdentifiableIfPossible(\(typeName).self)")
        attributes.append("@\(moduleName)._EquatableIfPossible(\(typeName).self)")

        var renderer = ViewStateRenderer(
            typeName: typeName,
            access: viewStateAccess(of: declaration, in: context),
            members: ViewStateMember.members(of: declaration.memberBlock.members),
            isIdentifiable: isIdentifiable,
            attributes: attributes,
            conformances: "\(moduleName).ViewStateProjection"
                + (inheritedTypeNames.contains("Sendable") ? ", Sendable" : "")
        )
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            return renderer.structDeclarations
        }
        // `@CasePathable` is propagated with the spelling the state uses; it is visible here,
        // so CasePaths is imported wherever the mirror is generated.
        if let casePathable = enumDecl.attributes.first(where: {
            guard case .attribute(let attribute) = $0 else { return false }
            let name = attribute.attributeName.trimmedDescription
            return name == casePathableMacroName || name == "CasePaths.\(casePathableMacroName)"
        }) {
            renderer.attributes.append(casePathable.trimmedDescription)
        }
        return renderer.enumDeclarations(
            isIndirect: enumDecl.modifiers.contains { $0.name.tokenKind == .keyword(.indirect) }
        )
    }

    /// The access modifier of the generated declarations, mirroring the state's: an explicit
    /// modifier, else `fileprivate` inside a file-private declaration (the file-scope `==` of
    /// `ViewState` must not be more visible than the state), else the default of an enclosing
    /// extension, else internal.
    static func viewStateAccess(
        of declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> String {
        if let access = declaration.modifiers.accessLevel {
            return access
        }
        let isInFilePrivateScope = context.lexicalContext.contains {
            $0.asProtocol((any WithModifiersSyntax).self)?.modifiers.accessLevel == "fileprivate "
        }
        if isInFilePrivateScope {
            return "fileprivate "
        }
        if let enclosingExtension = context.lexicalContext.first?.as(ExtensionDeclSyntax.self),
            let access = enclosingExtension.modifiers.accessLevel
        {
            return access
        }
        return ""
    }
}

struct ViewStateDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    var severity: DiagnosticSeverity { .error }

    init(message: String, id: String) {
        self.message = message
        self.diagnosticID = MessageID(domain: "FeatureState", id: id)
    }

    static func genericState(_ typeName: String) -> Self {
        Self(
            message: """
                '@FeatureState' cannot be applied to generic type '\(typeName)': the generated \
                projection uses a nested protocol, which Swift does not allow inside generic types \
                (SE-0404). Make '\(typeName)' non-generic or wrap the generic data in a non-generic \
                state type.
                """,
            id: "genericState"
        )
    }

    static func reservedName(_ name: String) -> Self {
        Self(message: "'\(name)' is reserved by '@FeatureState'", id: "reservedName")
    }

    static let domainNotProperty = Self(
        message: "'@Domain' can only be applied to instance properties",
        id: "domainNotProperty"
    )

    static let domainIdentifiableID = Self(
        message: "'id' cannot be '@Domain' on an Identifiable state; its ViewState would not satisfy 'Identifiable'",
        id: "domainIdentifiableID"
    )
}

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

/// Renders the generated projection declarations for one `@FeatureState` type.
struct ViewStateRenderer {
    let typeName: String
    /// `public `, `package `, `fileprivate ` or empty.
    let access: String
    let members: [ViewStateMember]
    let isIdentifiable: Bool
    var attributes: [String]
    let conformances: String

    var structDeclarations: [DeclSyntax] {
        let body =
            [
                "@_spi(Lattice) public let \(FeatureStateMacro.viewStateStorageName): \(typeName)",
                "\(access)init(_ state: \(typeName)) {",
                "self._state = state",
                "}",
            ] + forwardedProperties + domainStubs
        return [
            typesProtocol,
            witnessStruct,
            declaration(
                attributes + ["\(access)struct \(FeatureStateMacro.viewStateTypeName): \(conformances)"],
                body
            ),
        ]
    }

    func enumDeclarations(isIndirect: Bool) -> [DeclSyntax] {
        let cases = render { member in
            guard case .enumCase(let enumCase) = member else { return [] }
            let indirect = enumCase.isIndirect ? "indirect " : ""
            guard !enumCase.payloads.isEmpty else { return ["\(indirect)case \(enumCase.name.text)"] }
            let payloads = enumCase.payloads.indices.map { index in
                labeled(enumCase.payloads[index], "_$ViewStateWitness.\(enumCase.witnessName(index))")
            }
            return ["\(indirect)case \(enumCase.name.text)(\(payloads.joined(separator: ", ")))"]
        }
        let initCases = render { member in
            guard case .enumCase(let enumCase) = member else { return [] }
            return switchCase(enumCase, body: "self =") { index in "Lattice._$project(p\(index))" }
        }
        let stateCases = render { member in
            guard case .enumCase(let enumCase) = member else { return [] }
            return switchCase(enumCase, body: "return") { index in
                "Lattice._$unproject(p\(index), to: (\(enumCase.payloads[index].type.trimmedDescription)).self)"
            }
        }
        let body =
            cases
            + ["\(access)init(_ state: \(typeName)) {", "switch state {"] + initCases + ["}", "}"]
            + ["@_spi(Lattice) public var \(FeatureStateMacro.viewStateStorageName): \(typeName) {", "switch self {"]
            + stateCases + ["}", "}"]
            + forwardedProperties + domainStubs
        let indirect = isIndirect ? "indirect " : ""
        return [
            typesProtocol,
            witnessStruct,
            declaration(
                attributes + ["\(access)\(indirect)enum \(FeatureStateMacro.viewStateTypeName): \(conformances)"],
                body
            ),
        ]
    }

    /// One associated type per visible property, per inferred-type `@Domain` property (its stub
    /// needs a type) and per enum payload.
    private var typesProtocol: DeclSyntax {
        let requirements = render { member in
            switch member {
            case .property(let name, let type, let isDomain):
                guard !isDomain || type == nil else { return [] }
                return ["associatedtype \(name.text)", "var _$\(name.bareText): \(name.text) { get }"]
            case .enumCase(let enumCase):
                return enumCase.payloads.indices.flatMap { index in
                    let witness = enumCase.witnessName(index)
                    return ["associatedtype \(witness)", "var _$\(witness): \(witness) { get }"]
                }
            case .ifConfig:
                return []
            }
        }
        return declaration(["\(access)protocol \(FeatureStateMacro.viewStateTypesProtocolName)"], requirements)
    }

    private var witnessStruct: DeclSyntax {
        let placeholder = "Lattice._$placeholder(\(typeName).self)"
        let witnesses = render { member in
            switch member {
            case .property(let name, let type, let isDomain):
                if isDomain {
                    // No `_$project`: the stub keeps the member's own type.
                    return type == nil ? ["\(access)let _$\(name.bareText) = \(placeholder).\(name.text)"] : []
                }
                return ["\(access)let _$\(name.bareText) = Lattice._$project(\(placeholder).\(name.text))"]
            case .enumCase(let enumCase):
                return enumCase.payloads.indices.map { index in
                    let payloadType = enumCase.payloads[index].type.trimmedDescription
                    return "\(access)let _$\(enumCase.witnessName(index)) = "
                        + "Lattice._$project(Lattice._$placeholder((\(payloadType)).self))"
                }
            case .ifConfig:
                return []
            }
        }
        return declaration(
            [
                "\(access)struct \(FeatureStateMacro.viewStateWitnessTypeName): "
                    + FeatureStateMacro.viewStateTypesProtocolName
            ],
            witnesses
        )
    }

    private var forwardedProperties: [String] {
        render { member in
            guard case .property(let name, _, isDomain: false) = member else { return [] }
            return [
                "\(access)var \(name.text): _$ViewStateWitness.\(name.text) {",
                "Lattice._$project(_state.\(name.text))",
                "}",
            ]
        }
    }

    private var domainStubs: [String] {
        render { member in
            guard case .property(let name, let type, isDomain: true) = member,
                // An `id` stub would shadow the `Identifiable` witness; that case is diagnosed.
                !(isIdentifiable && name.bareText == "id")
            else {
                return []
            }
            return [
                "@available(*, unavailable, message: \"'\(name.bareText)' is @Domain state and is not visible to views\")",
                "\(access)var \(name.text): \(type?.trimmedDescription ?? "_$ViewStateWitness.\(name.text)") {",
                "fatalError()",
                "}",
            ]
        }
    }

    /// `header` lines (attributes, then the declaration line) followed by a braced `body`.
    private func declaration(_ header: [String], _ body: [String]) -> DeclSyntax {
        let opening = header.joined(separator: "\n") + " {"
        return "\(raw: ([opening] + body + ["}"]).joined(separator: "\n"))"
    }

    private func labeled(_ payload: ViewStateCase.Payload, _ value: String) -> String {
        payload.label.map { "\($0.text): \(value)" } ?? value
    }

    private func switchCase(
        _ enumCase: ViewStateCase,
        body: String,
        payload: (Int) -> String
    ) -> [String] {
        let name = enumCase.name.text
        guard !enumCase.payloads.isEmpty else { return ["case .\(name):", "\(body) .\(name)"] }
        let bindings = enumCase.payloads.indices.map { "p\($0)" }.joined(separator: ", ")
        let arguments = enumCase.payloads.indices.map { labeled(enumCase.payloads[$0], payload($0)) }
        return [
            "case let .\(name)(\(bindings)):",
            "\(body) .\(name)(\(arguments.joined(separator: ", ")))",
        ]
    }

    /// Renders `members` in order, mirroring `#if` blocks. A block that renders no lines in
    /// every clause is dropped.
    private func render(_ line: (ViewStateMember) -> [String]) -> [String] {
        Self.render(members, line)
    }

    private static func render(
        _ members: [ViewStateMember],
        _ line: (ViewStateMember) -> [String]
    ) -> [String] {
        var lines: [String] = []
        for member in members {
            guard case .ifConfig(let clauses) = member else {
                lines += line(member)
                continue
            }
            let rendered = clauses.map { (header: $0.header, lines: render($0.members, line)) }
            guard rendered.contains(where: { !$0.lines.isEmpty }) else { continue }
            for clause in rendered {
                lines.append(clause.header)
                lines += clause.lines
            }
            lines.append("#endif")
        }
        return lines
    }
}

extension TokenSyntax {
    /// The identifier without backticks.
    fileprivate var bareText: String { identifier?.name ?? text }
}

extension DeclModifierListSyntax {
    /// `public `, `package `, `fileprivate ` (for `private` and `fileprivate`) or an empty string
    /// for internal; `nil` when no access modifier is written. Generated members are never more
    /// visible than the state, and file-scope extensions of `ViewState` need `fileprivate` members.
    fileprivate var accessLevel: String? {
        for modifier in self where modifier.detail == nil {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open):
                return "public "
            case .keyword(.package):
                return "package "
            case .keyword(.fileprivate), .keyword(.private):
                return "fileprivate "
            case .keyword(.internal):
                return ""
            default:
                continue
            }
        }
        return nil
    }
}

extension VariableDeclSyntax {
    fileprivate var bindingNames: [TokenSyntax] {
        bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier }
    }
}

extension DeclGroupSyntax {
    /// Protocol names in the inheritance clause, looking through compositions, `@unchecked` and
    /// a `Swift.` qualifier.
    fileprivate var inheritedTypeNames: Set<String> {
        var names: Set<String> = []
        func collect(_ type: TypeSyntax) {
            if let attributed = type.as(AttributedTypeSyntax.self) {
                collect(attributed.baseType)
            } else if let composition = type.as(CompositionTypeSyntax.self) {
                composition.elements.forEach { collect($0.type) }
            } else {
                let name = type.trimmedDescription
                names.insert(name.hasPrefix("Swift.") ? String(name.dropFirst("Swift.".count)) : name)
            }
        }
        inheritanceClause?.inheritedTypes.forEach { collect($0.type) }
        return names
    }
}
