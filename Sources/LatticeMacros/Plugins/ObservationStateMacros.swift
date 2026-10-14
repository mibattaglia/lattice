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

extension SyntaxStringInterpolation {
    // It would be nice for SwiftSyntaxBuilder to provide this out-of-the-box.
    mutating func appendInterpolation<Node: SyntaxProtocol>(_ node: Node?) {
        if let node {
            appendInterpolation(node)
        }
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

        if property.hasMacroApplication(FeatureStateMacro.ignoredMacroName) {
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
