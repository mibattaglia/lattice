import Foundation
import SwiftDiagnostics
import SwiftOperators
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros

// MARK: - Shared Implementation

private enum SubscribeMacroImplementation {
    static func generateSubscribeExpression(
        schedulerArgument: ExprSyntax,
        interactorArgument: ExprSyntax,
        viewStateReducerArgument: ExprSyntax? = nil,
        context: some MacroExpansionContext
    ) -> ExprSyntax {

        if let viewStateReducerArgument = viewStateReducerArgument {
            // Full subscribe with reducer
            return ExprSyntax(
                """
                viewEvents
                    .interact(with: \(interactorArgument))
                    .reduce(using: \(viewStateReducerArgument))
                    .receive(on: \(schedulerArgument))
                    .assign(to: &$viewState)
                """
            )
        } else {
            // Simple subscribe without reducer
            return ExprSyntax(
                """
                viewEvents
                    .interact(with: \(interactorArgument))
                    .receive(on: \(schedulerArgument))
                    .assign(to: &$viewState)
                """
            )
        }
    }

    static func validateArguments(
        _ arguments: LabeledExprListSyntax,
        expectedCount: Int,
        context: some MacroExpansionContext,
        macroName: String
    ) -> Bool {
        guard arguments.count == expectedCount else {
            context.diagnose(
                Diagnostic(
                    node: arguments,
                    message: MacroExpansionErrorMessage(
                        "#\(macroName) macro expects exactly \(expectedCount) arguments"
                    )
                )
            )
            return false
        }
        return true
    }
}

// MARK: - SubscribeMacro (Full Version)

public enum SubscribeMacro {}

extension SubscribeMacro: ExpressionMacro {
    public static func expansion<Node: FreestandingMacroExpansionSyntax, Context: MacroExpansionContext>(
        of node: Node,
        in context: Context
    ) throws -> ExprSyntax {
        guard
            SubscribeMacroImplementation.validateArguments(
                node.arguments,
                expectedCount: 3,
                context: context,
                macroName: "subscribe"
            )
        else {
            return ExprSyntax("()")
        }

        let arguments = Array(node.arguments)
        let schedulerArgument = arguments[0].expression
        let interactorArgument = arguments[1].expression
        let viewStateReducerArgument = arguments[2].expression

        return SubscribeMacroImplementation.generateSubscribeExpression(
            schedulerArgument: schedulerArgument,
            interactorArgument: interactorArgument,
            viewStateReducerArgument: viewStateReducerArgument,
            context: context
        )
    }
}

// MARK: - SubscribeSimpleMacro (Simple Version)

public enum SubscribeSimpleMacro {}

extension SubscribeSimpleMacro: ExpressionMacro {
    public static func expansion<Node: FreestandingMacroExpansionSyntax, Context: MacroExpansionContext>(
        of node: Node,
        in context: Context
    ) throws -> ExprSyntax {
        guard
            SubscribeMacroImplementation.validateArguments(
                node.arguments,
                expectedCount: 2,
                context: context,
                macroName: "subscribeSimple"
            )
        else {
            return ExprSyntax("()")
        }

        let arguments = Array(node.arguments)
        let schedulerArgument = arguments[0].expression
        let interactorArgument = arguments[1].expression

        return SubscribeMacroImplementation.generateSubscribeExpression(
            schedulerArgument: schedulerArgument,
            interactorArgument: interactorArgument,
            viewStateReducerArgument: nil,
            context: context
        )
    }
}
