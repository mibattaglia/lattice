import Combine
import Foundation

/// A result builder for combining multiple interactors, pushing an action into each one, and then returning
/// an interleaved sequence of results.
@resultBuilder
public enum InteractorBuilder<State, Action> {
    public static func buildArray(
        _ reducers: [some Interactor<State, Action>]
    ) -> some Interactor<State, Action> {
        Interactors.MergeMany(interactors: reducers)
    }
    
    public static func buildBlock() -> some Interactor<State, Action> {
        EmptyInteractor()
    }
    
    public static func buildBlock<I: Interactor<State, Action>>(_ interactor: I) -> I {
        interactor
    }
    
    public static func buildBlock<I: Interactor<State, Action>>(_ interactors: I...) -> Interactors.MergeMany<I> {
        Interactors.MergeMany(interactors: interactors)
    }
    
    public static func buildEither<I0: Interactor<State, Action>, I1: Interactor<State, Action>>(
        first Interactor: I0
    ) -> Interactors.Conditional<I0, I1> {
        .first(Interactor)
    }
    
    public static func buildEither<I0: Interactor<State, Action>, I1: Interactor<State, Action>>(
        second Interactor: I1
    ) -> Interactors.Conditional<I0, I1> {
        .second(Interactor)
    }
    
    public static func buildExpression<I: Interactor<State, Action>>(_ expression: I) -> I {
        expression
    }
    
    @_disfavoredOverload
    public static func buildExpression(
        _ expression: any Interactor<State, Action>
    ) -> AnyInteractor<State, Action> {
        let erased: AnyInteractor<State, Action> = expression.eraseToAnyInteractor()
        return erased
    }
    
    public static func buildFinalResult<I: Interactor<State, Action>>(_ interactor: I) -> I {
        interactor
    }
    
    public static func buildLimitedAvailability(
        _ wrapped: some Interactor<State, Action>
    ) -> AnyInteractor<State, Action> {
        let erased: AnyInteractor<State, Action> = wrapped.eraseToAnyInteractor()
        return erased
    }

    public static func buildOptional(_ wrapped: (any Interactor<State, Action>)?) -> AnyInteractor<State, Action> {
        wrapped?.eraseToAnyInteractor() ?? EmptyInteractor<State, Action>().eraseToAnyInteractor()
    }
    
    public static func buildPartialBlock<I: Interactor<State, Action>>(first: I) -> I {
        first
    }
    
    public static func buildPartialBlock<I0: Interactor<State, Action>, I1: Interactor<State, Action>>(
        accumulated: I0, next: I1
    ) -> Interactors.Merge<I0, I1> {
        Interactors.Merge(accumulated, next)
    }
}
