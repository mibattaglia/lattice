////
////  DomainController.swift
////  swift-feature-composer
////
////  Created by Michael Battaglia on 2/1/25.
////
//
//import Foundation
//
//public final class DomainController<State, Action>: @unchecked Sendable {
//    private var bufferedActions: [Action] = []
//    private var isProcessing = false
//    private var state: State {
//        didSet {
//            stateStreamContinuation.yield(state)
//        }
//    }
//    
//    private let rootInteractor: any Interactor<State, Action>
//    private let stateStreamContinuation: AsyncStream<State>.Continuation
//    private let lock = NSRecursiveLock()
//    public let stateStream: AsyncStream<State>
//
//    public init(initialState: State, interactor: any Interactor<State, Action>) {
//        self.state = initialState
//        self.rootInteractor = interactor
//        
//        var continuation: AsyncStream<State>.Continuation!
//        self.stateStream = AsyncStream { continuation = $0 }
//        self.stateStreamContinuation = continuation
//        
//        // Emit initial state
//        self.stateStreamContinuation.yield(self.state)
//    }
//
//    public func send(_ action: Action) {
//        lock.lock()
//        bufferedActions.append(action)
//        lock.unlock()
//        processActionsIfNeeded()
//    }
//
//    private func processActionsIfNeeded() {
//        lock.lock()
//        defer { lock.unlock() }
//        guard !isProcessing else { return }
//        isProcessing = true
//        
//            while !bufferedActions.isEmpty {
//                let nextAction = bufferedActions.removeFirst()
//                applyAction(nextAction)
//            }
//            isProcessing = false
//    }
//
//    private func applyAction(_ action: Action) {
//        let result = rootInteractor.transform(state: &state, action: action)
//        handle(result)
//    }
//
//    private func handle(_ result: InteractionResult<State>) {
//        switch result.emission {
//        case .state:
//            break
//        case .stop:
//            stateStreamContinuation.finish()
//        case let .perform(runner):
//            Task {
//                await runner(state) { state in
//                    self.state = state
//                }
//            }
//        }
//    }
//}
