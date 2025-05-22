import Combine
import Foundation

/// A result builder for combining multiple interactors and running their events in sequence, one after the other,
/// and merging the results.
@resultBuilder
public enum InteractorBuilder<State: Equatable, Action> {
    public static func buildBlock<T: Interactor<State, Action>>(_ interactor: T) -> T {
        interactor
    }
    
    public static func buildBlock() -> some Interactor<State, Action> {
        EmptyInteractor()
    }
    
    public static func buildArray(_ components: [some Interactor<State, Action>]) -> some Interactor<State, Action> {
        _MergeMany(interactors: components)
    }
    
    public static func buildEither<I0: Interactor<State, Action>, I1: Interactor<State, Action>>(
        first interactor: I0
    ) -> _ConditionalInteractor<I0, I1> {
        .first(interactor)
    }
    
    public static func buildEither<I0: Interactor<State, Action>, I1: Interactor<State, Action>>(
        second interactor: I1
    ) -> _ConditionalInteractor<I0, I1> {
        .second(interactor)
    }
    
    public static func buildExpression<I: Interactor<State, Action>>(_ expression: I) -> I {
        expression
    }
    
    public static func buildFinalResult<I: Interactor<State, Action>>(_ interactor: I) -> I {
        interactor
    }
    
    public static func buildOptional<I: Interactor<State, Action>>(_ wrapped: I?) -> I? {
      wrapped
    }

    public static func buildPartialBlock<I: Interactor<State, Action>>(first: I) -> I {
      first
    }

    public static func buildPartialBlock<I0: Interactor<State, Action>, I1: Interactor<State, Action>>(
      accumulated: I0, next: I1
    ) -> _Merge<I0, I1> {
      _Merge(accumulated, next)
    }
    
    public struct _MergeMany<Element: Interactor>: Interactor {
        private let interactors: [Element]
        
        init(interactors: [Element]) {
            self.interactors = interactors
        }
        
        public var body: some Interactor<Element.State, Element.Action> { self }
        
        public func interact(
            _ upstream: AnyPublisher<Element.Action, Never>
        ) -> AnyPublisher<Element.State, Never> {
//            upstream
//                .flatMap { event in
//                    Publishers.MergeMany(interactors.map { $0.interact(Just(event).eraseToAnyPublisher()) })
//                }
//                .eraseToAnyPublisher()
            
            upstream
                .flatMap { event in
                    interactors
                        .publisher
                        .flatMap(maxPublishers: .max(1)) { interactor in
                            interactor.interact(Just(event).eraseToAnyPublisher())
                        }
                        .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        }
    }
    
    public struct _Merge<I0: Interactor, I1: Interactor<I0.State, I0.Action>>: Interactor {
        private let i0: I0
        private let i1: I1
        
        init(_ i0: I0, _ i1: I1) {
            self.i0 = i0
            self.i1 = i1
        }
        
        public var body: some Interactor<I0.State, I0.Action> { self }
        
        public func interact(_ upstream: AnyPublisher<I0.Action, Never>) -> AnyPublisher<I0.State, Never> {
            let shared = upstream
                .share()
                .eraseToAnyPublisher()
            
            return i0.interact(shared)
                .merge(with: i1.interact(shared))
                .eraseToAnyPublisher()
        }
    }
    
    public enum _ConditionalInteractor<First: Interactor, Second: Interactor<First.State, First.Action>>: Interactor {
        case first(First)
        case second(Second)
        
        public var body: some Interactor<First.State, First.Action> { self }
        
        public func interact(
            _ upstream: AnyPublisher<First.Action, Never>
        ) -> AnyPublisher<First.State, Never> {
            switch self {
            case .first(let first):
                return first.interact(upstream)
            case .second(let second):
                return second.interact(upstream)
            }
        }
    }
}

public struct EmptyInteractor<State: Equatable, Action>: Interactor {
    public typealias State = State
    public typealias Action = Action
    
    public var body: some InteractorOf<Self> { self }
    
    public func interact(
        _ upstream: AnyPublisher<Action, Never>
    ) -> AnyPublisher<State, Never> {
        Empty().eraseToAnyPublisher()
    }
}
