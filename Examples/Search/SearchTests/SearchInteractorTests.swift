import Combine
import CombineSchedulers
import Testing
import UnoArchitecture

@testable import Search

@Suite
final class SearchInteractorTests {
    private var cancellables: Set<AnyCancellable> = []

    @Test
    func searchQueryReturnsResults() async {
        let scheduler = DispatchQueue.test
        let mockService = MockWeatherService()
        let subject = PassthroughSubject<SearchEvent, Never>()

        let interactor = SearchInteractor(
            weatherService: mockService,
            scheduler: scheduler.eraseToAnyScheduler()
        )

        var events: [SearchEvent] = []

        await confirmation { confirmation in
            interactor.interact(subject.eraseToAnyPublisher())
                .sink { event in
                    events.append(event)
                    if events.contains(where: { event in
                        if case let .searchStateChanged(state) = event,
                           case .loaded = state {
                            return true
                        }
                        return false
                    }) {
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.search(.query("London")))

            await scheduler.advance(by: .milliseconds(300))
            await scheduler.advance()
        }

        #expect(events.contains(where: { event in
            if case let .searchStateChanged(state) = event,
               case let .loaded(content) = state {
                return content.model.results.first?.name == "London"
            }
            return false
        }))

        subject.send(completion: .finished)
    }

    @Test
    func emptyQueryReturnsNone() async {
        let scheduler = DispatchQueue.test
        let mockService = MockWeatherService()
        let subject = PassthroughSubject<SearchEvent, Never>()

        let interactor = SearchInteractor(
            weatherService: mockService,
            scheduler: scheduler.eraseToAnyScheduler()
        )

        var events: [SearchEvent] = []

        await confirmation { confirmation in
            interactor.interact(subject.eraseToAnyPublisher())
                .sink { event in
                    events.append(event)
                    if events.count >= 2 {
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.search(.query("")))

            await scheduler.advance(by: .milliseconds(300))
            await scheduler.advance()
        }

        #expect(events.contains(where: { event in
            if case let .searchStateChanged(state) = event {
                return state == .none
            }
            return false
        }))

        subject.send(completion: .finished)
    }

    @Test
    func searchIsDebounced() async {
        let scheduler = DispatchQueue.test
        let mockService = MockWeatherService()
        let subject = PassthroughSubject<SearchEvent, Never>()

        let interactor = SearchInteractor(
            weatherService: mockService,
            scheduler: scheduler.eraseToAnyScheduler()
        )

        var events: [SearchEvent] = []

        await confirmation { confirmation in
            interactor.interact(subject.eraseToAnyPublisher())
                .sink { event in
                    events.append(event)
                    if events.contains(where: { event in
                        if case let .searchStateChanged(state) = event,
                           case .loaded = state {
                            return true
                        }
                        return false
                    }) {
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.search(.query("L")))
            await scheduler.advance(by: .milliseconds(100))
            subject.send(.search(.query("Lo")))
            await scheduler.advance(by: .milliseconds(100))
            subject.send(.search(.query("Lon")))
            await scheduler.advance(by: .milliseconds(100))

            #expect(mockService.searchCallCount == 0)

            await scheduler.advance(by: .milliseconds(200))
            await scheduler.advance()
        }

        #expect(mockService.searchCallCount == 1)
        #expect(mockService.lastSearchQuery == "Lon")

        subject.send(completion: .finished)
    }

    @Test
    func searchErrorLogsAndReturnsNone() async {
        let scheduler = DispatchQueue.test
        let mockService = MockWeatherService()
        mockService.shouldFail = true
        let subject = PassthroughSubject<SearchEvent, Never>()

        let interactor = SearchInteractor(
            weatherService: mockService,
            scheduler: scheduler.eraseToAnyScheduler()
        )

        var events: [SearchEvent] = []

        await confirmation { confirmation in
            interactor.interact(subject.eraseToAnyPublisher())
                .sink { event in
                    events.append(event)
                    if events.count >= 3 {
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.search(.query("London")))

            await scheduler.advance(by: .milliseconds(300))
            await scheduler.advance()
        }

        #expect(events.contains(where: { event in
            if case let .searchStateChanged(state) = event {
                return state == .none
            }
            return false
        }))

        subject.send(completion: .finished)
    }
}

final class MockWeatherService: WeatherService {
    var searchCallCount = 0
    var lastSearchQuery: String?
    var shouldFail = false

    func searchWeather(query: String) async throws -> WeatherSearchDomainModel {
        searchCallCount += 1
        lastSearchQuery = query
        if shouldFail {
            throw NSError(domain: "MockError", code: 1)
        }
        return WeatherSearchDomainModel(
            results: [
                .init(country: "UK", latitude: 51.5, longitude: -0.1, id: 1, name: query)
            ]
        )
    }

    func forecast(latitude: Double, longitude: Double) async throws -> ForecastDomainModel {
        fatalError("Not implemented")
    }
}
