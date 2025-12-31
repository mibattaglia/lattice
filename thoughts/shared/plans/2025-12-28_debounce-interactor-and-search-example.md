# Debounce Interactor and Search Example Implementation Plan

## Overview

Implement a reusable `Debounce` interactor primitive in the UnoArchitecture library and complete the Search example domain layer with debounced search queries and async API calls.

## Current State Analysis

**Library** (`Sources/UnoArchitecture/`):
- Has interactor primitives: `Interact`, `When`, `Merge`, `MergeMany`, `EmptyInteractor`, `Conditional`, `CollectInteractors`
- No debounce primitive exists
3
**Search Example** (`Examples/Search/Search/`):
- `SearchInteractor` is a stub (prints events, returns `.state`)
- Domain models and `WeatherService` are complete

### Key Discoveries:
- `When` interactor routes child actions to child interactors via case path extraction (`When.swift:167-188`)
- `Debounce` will be composed via `When`, so it only needs to debounce the entire action stream
- `.perform { }` emission handles async work (`Emission.swift:38-42`)
- Error handling: log to console, return previous state

## Desired End State

1. **Library**: A `Debounce<Child: Interactor>` interactor primitive that debounces all incoming actions by a configurable duration
2. **Search Example Domain**: Fully functional domain layer with:
   - 300ms debounced search queries
   - Async API calls for location search
   - Console logging on API errors

### Verification:
- All existing tests pass
- New `Debounce` interactor tests pass
- New `SearchInteractor` tests pass
- Search example compiles and runs

## What We're NOT Doing

- View layer updates (UI will automatically update when domain state changes)
- Location tapping / weather forecast loading (future work)
- Error UI states (errors log to console only)
- Cancellation of in-flight requests
- Caching of search results

## Implementation Approach

1. **Phase 1**: Create `Debounce` interactor primitive with tests
2. **Phase 2**: Update `SearchDomainState` with searching state
3. **Phase 3**: Implement `SearchInteractor` with tests

---

## Phase 1: Debounce Interactor Primitive

### Overview
Create a `Debounce` interactor that wraps a child interactor, debouncing incoming actions before forwarding them.

### Changes Required:

#### 1. Create Debounce Interactor
**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift` (new)

```swift
import Combine
import CombineSchedulers
import Foundation

extension Interactors {
    public struct Debounce<Child: Interactor>: Interactor {
        public typealias DomainState = Child.DomainState
        public typealias Action = Child.Action

        private let child: Child
        private let duration: DispatchQueue.SchedulerTimeType.Stride
        private let scheduler: AnySchedulerOf<DispatchQueue>

        public init(
            for duration: DispatchQueue.SchedulerTimeType.Stride,
            scheduler: AnySchedulerOf<DispatchQueue>,
            @InteractorBuilder<Child.DomainState, Child.Action> child: () -> Child
        ) {
            self.duration = duration
            self.scheduler = scheduler
            self.child = child()
        }

        public var body: some InteractorOf<Self> { self }

        public func interact(
            _ upstream: AnyPublisher<Action, Never>
        ) -> AnyPublisher<DomainState, Never> {
            upstream
                .debounce(for: duration, scheduler: scheduler)
                .interact(with: child)
                .eraseToAnyPublisher()
        }
    }
}
```

#### 2. Create Debounce Tests
**File**: `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+DebounceTests.swift` (new)

```swift
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

        let debounced = Interactors.Debounce(
            for: .milliseconds(300),
            scheduler: scheduler.eraseToAnyScheduler()
        ) {
            CounterInteractor()
        }

        var states: [CounterInteractor.DomainState] = []

        debounced.interact(subject.eraseToAnyPublisher())
            .sink { state in
                states.append(state)
            }
            .store(in: &cancellables)

        subject.send(.increment)
        #expect(states.isEmpty)

        await scheduler.advance(by: .milliseconds(299))
        #expect(states.isEmpty)

        await scheduler.advance(by: .milliseconds(1))
        #expect(states == [.init(count: 0), .init(count: 1)])

        subject.send(completion: .finished)
    }

    @Test
    func debounceCoalescesRapidActions() async {
        let scheduler = DispatchQueue.test
        let subject = PassthroughSubject<CounterInteractor.Action, Never>()

        let debounced = Interactors.Debounce(
            for: .milliseconds(300),
            scheduler: scheduler.eraseToAnyScheduler()
        ) {
            CounterInteractor()
        }

        var states: [CounterInteractor.DomainState] = []

        debounced.interact(subject.eraseToAnyPublisher())
            .sink { state in
                states.append(state)
            }
            .store(in: &cancellables)

        subject.send(.increment)
        await scheduler.advance(by: .milliseconds(100))
        subject.send(.increment)
        await scheduler.advance(by: .milliseconds(100))
        subject.send(.increment)
        await scheduler.advance(by: .milliseconds(100))

        #expect(states.isEmpty)

        await scheduler.advance(by: .milliseconds(200))
        #expect(states == [.init(count: 0), .init(count: 1)])

        subject.send(completion: .finished)
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `swift build`
- [x] All tests pass: `swift test`

---

## Phase 2: Update SearchDomainState

### Overview
Add searching state to the domain state for tracking when a search is in progress.

### Changes Required:

#### 1. Update Domain State
**File**: `Examples/Search/Search/Architecture/SearchDomainState.swift`

Replace entire file:

```swift
import CasePaths

@CasePathable
enum SearchDomainState: Equatable {
    case none
    case searching
    case loaded(Content)

    struct Content: Equatable {
        var model: WeatherSearchDomainModel
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `swift build`

---

## Phase 3: Implement SearchInteractor

### Overview
Implement the search interactor with:
- A child `SearchQueryInteractor` for debounced search queries
- Async API calls via `.perform` emission
- Unit tests with mocked weather service

### Changes Required:

#### 1. Update SearchEvent
**File**: `Examples/Search/Search/Architecture/SearchEvent.swift`

Replace entire file:

```swift
import CasePaths

@CasePathable
enum SearchEvent: Equatable {
    case search(SearchQueryEvent)
    case searchStateChanged(SearchDomainState)
}

@CasePathable
enum SearchQueryEvent: Equatable, Sendable {
    case query(String)
}
```

#### 2. Create SearchQueryInteractor
**File**: `Examples/Search/Search/Architecture/SearchQueryInteractor.swift` (new)

```swift
import Combine
import CombineSchedulers
import UnoArchitecture

@Interactor<SearchDomainState, SearchQueryEvent>
struct SearchQueryInteractor {
    private let weatherService: WeatherService

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
    }

    var body: some InteractorOf<Self> {
        Interact(initialValue: .none) { state, event in
            switch event {
            case let .query(query):
                guard !query.isEmpty else {
                    return .none
                }
                return .perform { [weatherService] in
                    do {
                        let result = try await weatherService.searchWeather(query: query)
                        return .loaded(.init(model: result))
                    } catch {
                        print("Search error: \(error)")
                        return .none
                    }
                }
            }
        }
    }
}
```

#### 3. Update SearchInteractor
**File**: `Examples/Search/Search/Architecture/SearchInteractor.swift`

Replace the `SearchInteractor` struct (keep domain models and service):

```swift
import Combine
import CombineSchedulers
import UnoArchitecture

@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor {
    private let weatherService: WeatherService
    private let scheduler: AnySchedulerOf<DispatchQueue>

    init(
        weatherService: WeatherService,
        scheduler: AnySchedulerOf<DispatchQueue> = .main
    ) {
        self.weatherService = weatherService
        self.scheduler = scheduler
    }

    var body: some InteractorOf<Self> {
        When(
            stateIs: \SearchDomainState.Cases.none,
            actionIs: \.search,
            stateAction: \.searchStateChanged
        ) {
            Interactors.Debounce(
                for: .milliseconds(300),
                scheduler: scheduler
            ) {
                SearchQueryInteractor(weatherService: weatherService)
            }
        }

        Interact(initialValue: .none) { accum, event in
            switch event {
            case .searchStateChanged:
                return .state
            case .search:
                return .state
            }
        }
    }
}
```

#### 4. Create SearchInteractor Tests
**File**: `Examples/Search/SearchTests/SearchInteractorTests.swift` (new)

```swift
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

        interactor.interact(subject.eraseToAnyPublisher())
            .sink { event in
                events.append(event)
            }
            .store(in: &cancellables)

        subject.send(.search(.query("London")))

        await scheduler.advance(by: .milliseconds(300))
        await scheduler.advance()

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

        interactor.interact(subject.eraseToAnyPublisher())
            .sink { event in
                events.append(event)
            }
            .store(in: &cancellables)

        subject.send(.search(.query("")))

        await scheduler.advance(by: .milliseconds(300))
        await scheduler.advance()

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

        interactor.interact(subject.eraseToAnyPublisher())
            .sink { event in
                events.append(event)
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

        interactor.interact(subject.eraseToAnyPublisher())
            .sink { event in
                events.append(event)
            }
            .store(in: &cancellables)

        subject.send(.search(.query("London")))

        await scheduler.advance(by: .milliseconds(300))
        await scheduler.advance()

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
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build`
- [ ] All tests pass: `swift test`

---

## Testing Strategy

### Unit Tests:
- `Debounce` interactor timing behavior
- `Debounce` action coalescing
- `SearchInteractor` returns results for valid query
- `SearchInteractor` returns none for empty query
- `SearchInteractor` debounces rapid queries
- `SearchInteractor` handles API errors gracefully

### Integration Tests:
- None (Search example uses real APIs)

## References

- Original research: `thoughts/shared/research/2025-12-28-when-interactor-and-search-example.md`
- `When` interactor: `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift:167-188`
- `Interact` with `.perform`: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interact.swift:66-70`
- Existing interactor tests: `Tests/UnoArchitectureTests/DomainTests/InteractorTests/`
