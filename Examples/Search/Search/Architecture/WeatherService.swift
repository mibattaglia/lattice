import Foundation

protocol WeatherService: Sendable {
    func searchWeather(query: String) async throws -> WeatherSearchDomainModel
    func forecast(latitude: Double, longitude: Double) async throws -> ForecastDomainModel
}

struct WeatherSearchDomainModel: Codable, Equatable {
    let results: [Result]

    struct Result: Codable, Equatable {
        let country: String
        let latitude: Double
        let longitude: Double
        let id: Int
        let name: String
    }
}

struct ForecastDomainModel: Codable, Equatable {
    let daily: Daily
    let dailyUnits: DailyUnits

    struct Daily: Codable, Equatable {
        let temperatureMax: [Double]
        let temperatureMin: [Double]
        let time: [Date]

        enum CodingKeys: String, CodingKey {
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
            case time = "time"
        }
    }

    struct DailyUnits: Codable, Equatable {
        let temperatureMax: String
        let temperatureMin: String

        enum CodingKeys: String, CodingKey {
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
        }
    }

    enum CodingKeys: String, CodingKey {
        case daily = "daily"
        case dailyUnits = "daily_units"
    }
}

struct RealWeatherService: WeatherService {
    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    func searchWeather(query: String) async throws -> WeatherSearchDomainModel {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: query)]

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try jsonDecoder.decode(WeatherSearchDomainModel.self, from: data)
    }

    func forecast(latitude: Double, longitude: Double) async throws -> ForecastDomainModel {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: "\(latitude)"),
            URLQueryItem(name: "longitude", value: "\(longitude)"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: TimeZone.autoupdatingCurrent.identifier),
        ]

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try jsonDecoder.decode(ForecastDomainModel.self, from: data)
    }
}
