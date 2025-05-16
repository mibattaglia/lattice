import Combine
@testable import FeatureComposer
import FeatureComposerTestingSupport
import Foundation
import Testing

@Suite
final class CounterInteractorTests {
    let interactor = CounterInteractor()
    var cancellables: Set<AnyCancellable> = []
    
    @Test
    func increment() {
        let subject = PassthroughSubject<CounterInteractor.Action, Never>()
        let state = CounterInteractor.State(count: 0)
        let expected = [
            CounterInteractor.State(count: 0),
            CounterInteractor.State(count: 1),
            CounterInteractor.State(count: 2)
        ]
        
        interactor
            .interact(subject.eraseToAnyPublisher())
            .collect()
            .sink { actual in
//                #expect(actual == expected)
            }
            .store(in: &cancellables)
        
        subject.send(.increment)
        subject.send(.increment)
        subject.send(completion: .finished)
    }
    
//    @Test
//    func increment() async {
//        let state = CounterInteractor.State(count: 0)
//        let controller = DomainController(initialState: state, interactor: interactor)
//        
//        controller.send(.increment)
//        controller.send(.increment)
//        
//        let expected = [
//            CounterInteractor.State(count: 0),
//            CounterInteractor.State(count: 1),
//            CounterInteractor.State(count: 2)
//        ]
//        await streamConfirmation(stream: controller.stateStream, expectedResult: expected)
//    }
//
//    @Test
//    func decrement() async {
//        let state = CounterInteractor.State(count: 10)
//
//        let controller = DomainController(initialState: state, interactor: interactor)
//        controller.send(.decrement)
//        
//        let expected = [
//            CounterInteractor.State(count: 10),
//            CounterInteractor.State(count: 9)
//        ]
//        await streamConfirmation(stream: controller.stateStream, expectedResult: expected)
//    }
//    
//    @Test
//    func reset() async {
//        let state = CounterInteractor.State(count: 42)
//
//        let controller = DomainController(initialState: state, interactor: interactor)
//        controller.send(.reset)
//        
//        let expected = [
//            CounterInteractor.State(count: 42),
//            CounterInteractor.State(count: 0)
//        ]
//        await streamConfirmation(stream: controller.stateStream, expectedResult: expected)
//    }
}
