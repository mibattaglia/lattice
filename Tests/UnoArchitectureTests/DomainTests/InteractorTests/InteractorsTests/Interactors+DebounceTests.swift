import Combine
import CombineSchedulers
import Foundation
import Testing

@testable import UnoArchitecture

@Suite
final class DebounceTests {
    private var cancellables: Set<AnyCancellable> = []

    @Test
    func debounceDelaysActions() async {
        let scheduler = DispatchQueue.test
        let subject = PassthroughSubject<CounterInteractor.Action, Never>()

        let debounced = Interactors.Debounce<CounterInteractor>(
            for: .milliseconds(300),
            scheduler: scheduler.eraseToAnyScheduler()
        ) {
            CounterInteractor()
        }

        var states: [CounterInteractor.DomainState] = []

        await confirmation { confirmation in
            debounced.interact(subject.eraseToAnyPublisher())
                .sink { state in
                    states.append(state)
                    if states.count == 2 {
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            // Initial state emitted immediately
            #expect(states == [.init(count: 0)])

            subject.send(.increment)

            // Action is debounced - state change not yet visible
            await scheduler.advance(by: .milliseconds(299))
            #expect(states == [.init(count: 0)])

            // After full debounce period, state change is emitted
            await scheduler.advance(by: .milliseconds(1))
        }

        #expect(states == [.init(count: 0), .init(count: 1)])

        subject.send(completion: .finished)
    }

    @Test
    func debounceCoalescesRapidActions() async {
        let scheduler = DispatchQueue.test
        let subject = PassthroughSubject<CounterInteractor.Action, Never>()

        let debounced = Interactors.Debounce<CounterInteractor>(
            for: .milliseconds(300),
            scheduler: scheduler.eraseToAnyScheduler()
        ) {
            CounterInteractor()
        }

        var states: [CounterInteractor.DomainState] = []

        await confirmation { confirmation in
            debounced.interact(subject.eraseToAnyPublisher())
                .sink { state in
                    states.append(state)
                    if states.count == 2 {
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            // Initial state emitted immediately
            #expect(states == [.init(count: 0)])

            // Send rapid actions - each resets the debounce timer
            subject.send(.increment)
            await scheduler.advance(by: .milliseconds(100))
            subject.send(.increment)
            await scheduler.advance(by: .milliseconds(100))
            subject.send(.increment)
            await scheduler.advance(by: .milliseconds(100))

            // Still only initial state - debounce timer keeps resetting
            #expect(states == [.init(count: 0)])

            // After 300ms from last action, only the last action is processed
            await scheduler.advance(by: .milliseconds(200))
        }

        // Only the last action (.increment) was processed since debounce coalesces
        #expect(states == [.init(count: 0), .init(count: 1)])

        subject.send(completion: .finished)
    }
}
