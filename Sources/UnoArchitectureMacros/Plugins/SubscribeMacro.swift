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
        case "interactor":
            configuration.interactor = firstArgument
        case "viewStateReducer":
            configuration.viewStateReducer = firstArgument
        default:
            break
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
        let configuration = collector.configuration

        // If the interactor is missing we both diagnose and early return so the
        // macro expansion does not crash at runtime.
        guard let interactorExpr = configuration.interactor else {
            context.diagnose(SubscribeMacroDiagnostics.missingInteractor(node: Syntax(closure)))
            return ExprSyntax("()")
        }

        // Generate Task-based pipeline wrapped in immediately-invoked closure
        // (expression macros must produce expressions, not statements)
        // Values are captured in the Task's capture list to transfer Sendable ownership
        let pipeline: String
        if let reducerExpr = configuration.viewStateReducer?.trimmedDescription {
            // With ViewStateReducer: reduce domain state to view state
            pipeline = """
                ({
                    let interactor = \(interactorExpr.trimmedDescription)
                    let viewStateReducer = \(reducerExpr)
                    let (stream, continuation) = AsyncStream.makeStream(of: ViewEventType.self)
                    self.viewEventContinuation = continuation
                    self.subscriptionTask = Task { [interactor, viewStateReducer, stream] in
                        for await domainState in interactor.interact(stream) {
                            guard !Task.isCancelled else { break }
                            await MainActor.run { [weak self] in
                                self?.viewState = viewStateReducer.reduce(domainState)
                            }
                        }
                    }
                })()
                """
        } else {
            // Without ViewStateReducer: domain state IS view state
            pipeline = """
                ({
                    let interactor = \(interactorExpr.trimmedDescription)
                    let (stream, continuation) = AsyncStream.makeStream(of: ViewEventType.self)
                    self.viewEventContinuation = continuation
                    self.subscriptionTask = Task { [interactor, stream] in
                        for await domainState in interactor.interact(stream) {
                            guard !Task.isCancelled else { break }
                            await MainActor.run { [weak self] in
                                self?.viewState = domainState
                            }
                        }
                    }
                })()
                """
        }

        return ExprSyntax(stringLiteral: pipeline)
    }
}
