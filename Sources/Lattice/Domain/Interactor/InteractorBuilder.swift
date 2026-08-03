import Foundation

/// A *result builder* that composes multiple ``Interactor`` values into a single
/// interactor.
///
/// The builder powers the `body` property of every ``Interactor`` implementation.  You can use
/// regular control-flow (`if`, `switch`, `for`), optional and array literals to declaratively
/// combine smaller interactors into more complex ones.
///
/// ```swift
/// struct Feature: Interactor {
///   var body: some Interactor<State, Action> {
///     LoggingInteractor()
///     CounterInteractor()
///     if isPremium {
///       AnalyticsInteractor()
///     }
///   }
/// }
/// ```
///
/// Composition is structural: sibling positions, `if/else` branches, and `When` lenses each
/// append a `GraphPath` component, giving every effect-launching leaf a stable structural
/// identity for task storage and cancellation.
@resultBuilder
public enum InteractorBuilder<State, Action> {
    /// Builds an interactor from an array literal `[...]` or a `for` loop.
    public static func buildArray(
        _ interactors: [some Interactor<State, Action>]
    ) -> some Interactor<State, Action> {
        Interactors.MergeMany(interactors: interactors)
    }

    /// Builds an empty block.
    public static func buildBlock() -> some Interactor<State, Action> {
        EmptyInteractor()
    }

    /// Pass-through overload for a single child.
    public static func buildBlock<I: Interactor<State, Action>>(_ interactor: I) -> I {
        interactor
    }

    /// Variadic overload for `I...` syntax.
    public static func buildBlock<I: Interactor<State, Action>>(_ interactors: I...)
        -> Interactors.MergeMany<I>
    {
        Interactors.MergeMany(interactors: interactors)
    }

    /// ``if/else`` first-branch.
    public static func buildEither<I0: Interactor<State, Action>, I1: Interactor<State, Action>>(
        first interactor: I0
    ) -> Interactors.Conditional<I0, I1> {
        .first(interactor)
    }

    /// ``if/else`` second-branch.
    public static func buildEither<I0: Interactor<State, Action>, I1: Interactor<State, Action>>(
        second interactor: I1
    ) -> Interactors.Conditional<I0, I1> {
        .second(interactor)
    }

    /// Accepts an expression that is already an ``Interactor``.
    public static func buildExpression<I: Interactor<State, Action>>(_ expression: I) -> I {
        expression
    }

    /// Accepts an expression typed as `any Interactor` and erases it.
    @_disfavoredOverload
    public static func buildExpression(
        _ expression: any Interactor<State, Action>
    ) -> AnyInteractor<State, Action> {
        expression.eraseToAnyInteractor()
    }

    public static func buildFinalResult<I: Interactor<State, Action>>(_ interactor: I) -> I {
        interactor
    }

    public static func buildLimitedAvailability(
        _ wrapped: some Interactor<State, Action>
    ) -> AnyInteractor<State, Action> {
        wrapped.eraseToAnyInteractor()
    }

    public static func buildOptional(_ wrapped: (any Interactor<State, Action>)?) -> AnyInteractor<
        State, Action
    > {
        wrapped?.eraseToAnyInteractor() ?? EmptyInteractor<State, Action>().eraseToAnyInteractor()
    }

    public static func buildPartialBlock<I: Interactor<State, Action>>(first: I) -> I {
        first
    }

    public static func buildPartialBlock<
        I0: Interactor<State, Action>, I1: Interactor<State, Action>
    >(
        accumulated: I0, next: I1
    ) -> Interactors.Merge<I0, I1> {
        Interactors.Merge(accumulated, next)
    }
}
