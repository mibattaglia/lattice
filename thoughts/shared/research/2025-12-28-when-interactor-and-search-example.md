---
date: 2025-12-28T11:40:06-0500
researcher: Claude
git_commit: bb7fccee069aeef284321b252c7f10a9f66ed17d
branch: mbattag/add-examples
repository: swift-uno-architecture
topic: "When interactor definition and usage, Search example implementation"
tags: [research, codebase, interactor, when, search, debounce, composition]
status: complete
last_updated: 2025-12-28
last_updated_by: Claude
---

# Research: When Interactor and Search Example

**Date**: 2025-12-28T11:40:06-0500
**Researcher**: Claude
**Git Commit**: bb7fccee069aeef284321b252c7f10a9f66ed17d
**Branch**: mbattag/add-examples
**Repository**: swift-uno-architecture

## Research Question

How is `When.swift` defined and used in the codebase? Understand the Search example implementation to plan filling in the remaining interactor actions.

## Summary

The `When` interactor enables parent-child domain composition by:
1. Routing parent actions to child interactors via case path extraction
2. Propagating child state updates back as parent actions via case path embedding
3. Supporting both struct property (KeyPath) and enum case (CasePath) patterns

The Search example has stub implementations that need to be completed to:
- Debounce search queries by 300ms
- Make async API calls for location search
- Load weather forecasts when tapping rows

## Detailed Findings

### When Interactor Definition

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`

The `When` interactor is a composition primitive for embedding child interactors in parent domains:

```swift
extension Interactors {
    public struct When<ParentState, ParentAction, Child: Interactor>: Interactor {
        enum StatePath {
            case keyPath(WritableKeyPath<ParentState, Child.DomainState>)
            case casePath(AnyCasePath<ParentState, Child.DomainState>)
        }

        let toChildState: StatePath
        let toChildAction: AnyCasePath<ParentAction, Child.Action>
        let toStateAction: AnyCasePath<ParentAction, Child.DomainState>
        let child: Child
    }
}
```

**Two Initialization Patterns**:

1. **Struct Property Pattern** (lines 103-115) - Child state is a property of parent state:
   ```swift
   When(
       stateIs: \.counter,        // WritableKeyPath
       actionIs: \.counter,       // CaseKeyPath
       stateAction: \.counterStateChanged  // CaseKeyPath
   ) {
       CounterInteractor()
   }
   ```

2. **Enum Case Pattern** (lines 148-160) - Child state is an enum case of parent state:
   ```swift
   When(
       stateIs: \.loggedIn,       // CaseKeyPath
       actionAction: \.loggedIn,  // CaseKeyPath (note: `actionAction` not `actionIs`)
       stateAction: \.loggedInStateChanged
   ) {
       LoggedInInteractor()
   }
   ```

**Interaction Logic** (lines 167-188):
```swift
public func interact(
    _ upstream: AnyPublisher<ParentAction, Never>
) -> AnyPublisher<ParentAction, Never> {
    // 1. Filter parent actions to child actions
    let childActions = upstream.compactMap { action in
        self.toChildAction.extract(from: action)
    }

    // 2. Run child interactor and wrap state as parent actions
    let childStateActions = childActions
        .interact(with: self.child)
        .map { childState in
            self.toStateAction.embed(childState)
        }

    // 3. Merge original actions with child state changes
    return Publishers.Merge(upstream, childStateActions)
        .eraseToAnyPublisher()
}
```

### When Interactor Test Usage

**File**: `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+WhenTests.swift`

The tests demonstrate the usage pattern with a `CounterInteractor` embedded in a parent domain:

```swift
struct ParentState {
    var counter: CounterInteractor.State
    var otherProperty: String
}

@CasePathable
enum ParentAction {
    case counter(CounterInteractor.Action)
    case counterStateChanged(CounterInteractor.State)
    case otherAction
}
```

Key behaviors verified:
- Child actions are extracted and routed to child interactor
- Child state changes are embedded as parent actions
- Non-child actions pass through unchanged
- Initial state is emitted when interactor subscribes

### Search Example Current State

**Location**: `Examples/Search/Search/`

#### Domain State (`SearchDomainState.swift`)
```swift
@CasePathable
enum SearchDomainState {
    case none
    case loaded(Content)

    struct Content: Equatable {
        var model: WeatherSearchDomainModel
    }
}
```

#### Events (`SearchEvent.swift`)
```swift
enum SearchEvent: Equatable {
    case search(String)
    case locationTapped(id: String)
}
```

#### Interactor (`SearchInteractor.swift`) - STUB
```swift
@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor {
    private let weatherService: WeatherService

    var body: some InteractorOf<Self> {
        Interact(initialValue: .none) { accum, event in
            switch event {
            case let .locationTapped(id):
                print(id)     // STUB - needs implementation
                return .state
            case let .search(query):
                print(query)  // STUB - needs implementation
                return .state
            }
        }
    }
}
```

#### Weather Service Protocol
```swift
protocol WeatherService {
    func searchWeather(query: String) async throws -> WeatherSearchDomainModel
    func forecast(latitude: Double, longitude: Double) async throws -> ForecastDomainModel
}
```

#### View State (`SearchViewState.swift`)
```swift
enum SearchViewState: Equatable {
    case none
    case loaded(SearchListContent)
}

struct SearchListItem: Equatable, Identifiable {
    let id: String
    let name: String
    var isLoading: Bool = false
    var weather: Weather? = nil
}
```

#### View State Reducer (`SearchViewStateReducer.swift`) - STUB
```swift
@ViewStateReducer<SearchDomainState, SearchViewState>
struct SearchViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState in
            return .none  // STUB - needs implementation
        }
    }
}
```

### Emission Types Available

**File**: `Sources/UnoArchitecture/Domain/Emission.swift`

Three emission types for handling side effects:

1. **`.state`** - Immediate state emission
2. **`.perform { async work }`** - Async work returning new state
3. **`.observe { publisher }`** - Subscribe to publisher for state updates

The `.perform` emission is ideal for async API calls:
```swift
return .perform { [weatherService] in
    let result = try await weatherService.searchWeather(query: query)
    return SearchDomainState.loaded(Content(model: result))
}
```

## Architecture Documentation

### Child Interactor Composition with When

The `When` interactor enables modular feature composition:

1. **Parent defines action cases** for child actions and child state changes
2. **When routes** child actions to child interactor
3. **Child state** is embedded back as parent action
4. **Parent Interact** handles state change actions to update domain state

### Debouncing Pattern

Since there's no built-in debounce interactor, debouncing would be implemented using Combine's `.debounce()` operator in a child interactor that uses `.observe()` emission:

```swift
return .observe { state in
    searchSubject
        .debounce(for: .milliseconds(300), scheduler: scheduler)
        .flatMap { query -> AnyPublisher<ChildState, Never> in
            // perform search
        }
        .eraseToAnyPublisher()
}
```

## Code References

- `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift:45-189` - When implementation
- `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+WhenTests.swift:26-173` - When tests
- `Examples/Search/Search/Architecture/SearchInteractor.swift:5-25` - Search interactor stub
- `Examples/Search/Search/Architecture/SearchDomainState.swift:1-11` - Search domain state
- `Examples/Search/Search/Architecture/SearchEvent.swift:1-4` - Search events
- `Examples/Search/Search/Architecture/SearchViewStateReducer.swift:1-11` - View state reducer stub
- `Sources/UnoArchitecture/Domain/Emission.swift:13-55` - Emission types

## Decisions

1. **Debouncing should be a dedicated `Debounce` interactor primitive** defined in the library code (`Sources/UnoArchitecture/`), not embedded within feature-specific interactors. This keeps debouncing reusable and composable across features.

## Open Questions

1. How should error handling work for failed API requests?
2. Should the search interactor track loading state during API calls?
