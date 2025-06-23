import Foundation
import SwiftDiagnostics
import SwiftOperators
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros

// MARK: - Builder Configuration Collector

/// Internal structure that records the values passed to the builder inside the
/// trailing-closure that the `#subscribe` macro accepts.
private struct BuilderConfiguration {
    var viewEventReceiver: ExprSyntax?
    var viewStateReceiver: ExprSyntax?
    var interactor: ExprSyntax?
    var viewStateReducer: ExprSyntax?
}

/// A `SyntaxVisitor` that walks through the closure body, finding calls or
/// assignments that are performed on the builder instance and extracts their
/// arguments so we can later generate code from them.
private final class BuilderCallCollector: SyntaxVisitor {
    private let builderName: String
    private(set) var configuration = BuilderConfiguration()

    init(builderName: String) {
        self.builderName = builderName
        super.init(viewMode: .sourceAccurate)
    }

    // Visits every `FunctionCallExprSyntax` looking for invocations on the
    // builder instance (e.g. `builder.interactor(someInteractor)`).
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
            isCall(onBuilder: memberAccess.base)
        else {
            return .visitChildren
        }

        let methodName = memberAccess.declName.baseName.text
        let firstArgument = node.arguments.first?.expression

        switch methodName {
        case "viewEventReceiver":
            configuration.viewEventReceiver = firstArgument
        case "viewStateReceiver":
            configuration.viewStateReceiver = firstArgument
        case "interactor":
            configuration.interactor = firstArgument
        case "viewStateReducer":
            configuration.viewStateReducer = firstArgument
        default:
            break
        }

        return .visitChildren
    }

    // Visits assignment expressions like `builder.viewEventReceiver = .main`.
    override func visit(_ node: AssignmentExprSyntax) -> SyntaxVisitorContinueKind {
        // We only care about assignments where the LHS is a member access on
        // the builder (e.g. `builder.viewEventReceiver = ...`).
        guard
            let memberAccess = node.parent?.as(InfixOperatorExprSyntax.self)?.leftOperand.as(
                MemberAccessExprSyntax.self),
            isCall(onBuilder: memberAccess.base)
        else {
            return .visitChildren
        }

        let propertyName = memberAccess.declName.baseName.text
        // The right-hand side value is the sibling `rightOperand` of the
        // `AssignmentExprSyntax`'s parent (`InfixOperatorExprSyntax`).
        if let infix = node.parent?.as(InfixOperatorExprSyntax.self) {
            let valueExpr = infix.rightOperand
            switch propertyName {
            case "viewEventReceiver":
                configuration.viewEventReceiver = valueExpr
            case "viewStateReceiver":
                configuration.viewStateReceiver = valueExpr
            default:
                break
            }
        }
        return .visitChildren
    }

    // Helper that climbs through nested calls to determine whether the provided
    // base expression eventually resolves to the declared `builder` variable.
    private func isCall(onBuilder base: ExprSyntax?) -> Bool {
        guard let base else { return false }

        if let declRef = base.as(DeclReferenceExprSyntax.self) {
            return declRef.baseName.text == builderName
        }
        if let memberAccess = base.as(MemberAccessExprSyntax.self) {
            return isCall(onBuilder: memberAccess.base)
        }
        if let call = base.as(FunctionCallExprSyntax.self) {
            return isCall(onBuilder: call.calledExpression)
        }
        return false
    }
}

// MARK: - Diagnostic Messages

private enum SubscribeMacroDiagnostics {
    static func missingTrailingClosure(node: some SyntaxProtocol) -> Diagnostic {
        Diagnostic(
            node: node,
            message: MacroExpansionErrorMessage("#subscribe macro requires a trailing closure with a builder parameter")
        )
    }

    static func missingInteractor(node: some SyntaxProtocol) -> Diagnostic {
        Diagnostic(
            node: node,
            message: MacroExpansionErrorMessage("Builder configuration must include an interactor")
        )
    }

    static func missingBuilderParameter(node: some SyntaxProtocol) -> Diagnostic {
        Diagnostic(
            node: node,
            message: MacroExpansionErrorMessage("The trailing closure for #subscribe must declare a builder parameter")
        )
    }
}

// MARK: - SubscribeMacro

public enum SubscribeMacro {}

extension SubscribeMacro: ExpressionMacro {
    public static func expansion<Node: FreestandingMacroExpansionSyntax, Context: MacroExpansionContext>(
        of node: Node,
        in context: Context
    ) throws -> ExprSyntax {
        // We only support the trailing-closure syntax now. Emit a diagnostic if
        // the user passed positional arguments.
        guard node.trailingClosure != nil else {
            context.diagnose(SubscribeMacroDiagnostics.missingTrailingClosure(node: node))
            return ExprSyntax("()")
        }

        let closure = node.trailingClosure!

        // should look for inside the closure body. We look for the first
        // identifier token that appears in the signature.
        var extractedBuilderName: String?
        if let signature = closure.signature {
            for token in signature.tokens(viewMode: .sourceAccurate) {
                if case .identifier(let name) = token.tokenKind {
                    extractedBuilderName = name
                    break
                }
            }
        }

        guard let builderName = extractedBuilderName else {
            context.diagnose(SubscribeMacroDiagnostics.missingBuilderParameter(node: closure))
            return ExprSyntax("()")
        }

        // Walk the closure body collecting the builder configuration.
        let collector = BuilderCallCollector(builderName: builderName)
        collector.walk(Syntax(closure))
        var configuration = collector.configuration

        // If the interactor is missing we both diagnose and early return so the
        // macro expansion does not crash at runtime.
        guard let interactorExpr = configuration.interactor else {
            context.diagnose(SubscribeMacroDiagnostics.missingInteractor(node: Syntax(closure)))
            return ExprSyntax("()")
        }

        // Provide default values when none are specified.
        if configuration.viewStateReceiver == nil {
            configuration.viewStateReceiver = ExprSyntax(".main")
        }
        // `viewEventReceiver` is currently unused in the generated pipeline but
        // we still store it for future use if needed.

        // Compose the direct Combine pipeline expression.
        let receiveOnExpr = configuration.viewStateReceiver?.trimmedDescription ?? ".main"

        let pipeline: String
        if let reducerExpr = configuration.viewStateReducer?.trimmedDescription {
            pipeline = """
                viewEvents
                    .interact(with: \(interactorExpr.trimmedDescription))
                    .reduce(using: \(reducerExpr))
                    .receive(on: \(receiveOnExpr))
                    .assign(to: &$viewState)
                """
        } else {
            pipeline = """
                viewEvents
                    .interact(with: \(interactorExpr.trimmedDescription))
                    .receive(on: \(receiveOnExpr))
                    .assign(to: &$viewState)
                """
        }

        let expanded: ExprSyntax = ExprSyntax(stringLiteral: pipeline)

        return expanded
    }
}
