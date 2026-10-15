import Foundation

@testable import SearchExample

/// The weather service the tests inject: a plain class, not `Sendable`, which the test hands over to
/// the model. The test observes it only through what they share: the `searches` log and the gates.
final class StubWeatherService: WeatherService {
    private let searchResults: [String: WeatherSearchDomainModel]
    private let forecasts: [Double: ForecastDomainModel]
    private let searches: CallLog
    private let searchGate: Gate?
    private let forecastGate: Gate?

    /// - Parameters:
    ///   - forecasts: The forecast for each location, by latitude.
    ///   - searchGate: When set, every search waits until the test opens it.
    ///   - forecastGate: When set, every forecast request waits until the test opens it.
    init(
        searchResults: [String: WeatherSearchDomainModel] = [:],
        forecasts: [Double: ForecastDomainModel] = [:],
        searches: CallLog = CallLog(),
        searchGate: Gate? = nil,
        forecastGate: Gate? = nil
    ) {
        self.searchResults = searchResults
        self.forecasts = forecasts
        self.searches = searches
        self.searchGate = searchGate
        self.forecastGate = forecastGate
    }

    nonisolated(nonsending) func searchWeather(query: String) async throws -> WeatherSearchDomainModel {
        searches.append(query)
        await searchGate?.wait()
        return searchResults[query] ?? WeatherSearchDomainModel(results: [])
    }

    nonisolated(nonsending) func forecast(latitude: Double, longitude: Double) async throws -> ForecastDomainModel {
        await forecastGate?.wait()
        return forecasts[latitude]
            ?? ForecastDomainModel(
                daily: .init(temperatureMax: [], temperatureMin: [], time: []),
                dailyUnits: .init(temperatureMax: "", temperatureMin: "")
            )
    }
}

/// The queries the stub served, in order. Locked: the stub appends on the model's executor while the
/// test reads.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var entries: [String] { lock.withLock { storage } }

    func append(_ entry: String) {
        lock.withLock { storage.append(entry) }
    }
}

/// A suspension point the test opens. ``wait()`` ignores cancellation, so a request cancelled while
/// it waits still gets its answer once the test opens the gate: a stale answer arriving late.
///
/// Locked: the request waits on the model's executor while the test opens the gate. `wait()` is
/// `nonisolated(nonsending)`, so the request registers before the `send` that started it returns.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated(nonsending) func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumesNow = lock.withLock {
                guard !isOpen else { return true }
                waiters.append(continuation)
                return false
            }
            if resumesNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in waiting {
            waiter.resume()
        }
    }
}
