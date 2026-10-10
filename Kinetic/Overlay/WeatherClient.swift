import Foundation

protocol WeatherFetching: Sendable {
    func searchPlaces(_ query: String) async throws -> [WeatherPlace]
    func fetchWeather(for place: WeatherPlace, now: Date) async throws -> WeatherSnapshot
}

/// No cookies, credentials, disk cache or redirects. Request/response sizes are bounded.
final class WeatherClient: WeatherFetching, @unchecked Sendable {
    static let maximumResponseBytes = 512 * 1_024
    private let session: URLSession
    private let redirects = WeatherRedirectPolicy()
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 25
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }
    static func forecastURL(for place: WeatherPlace) throws -> URL {
        _ = try place.validated()
        return try url(host: "api.open-meteo.com", path: "/v1/forecast", query: [
            "latitude": String(place.latitude), "longitude": String(place.longitude),
            "current": "temperature_2m,is_day,weather_code,wind_speed_10m,wind_direction_10m,precipitation",
            "timeformat": "unixtime", "timezone": "GMT", "wind_speed_unit": "ms", "temperature_unit": "celsius", "precipitation_unit": "mm"
        ])
    }
    static func searchURL(_ query: String) throws -> URL {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...128).contains(query.count) else { throw WeatherError.invalidPlace }
        return try url(host: "geocoding-api.open-meteo.com", path: "/v1/search", query: ["name": query, "count": "10", "language": "zh", "format": "json"])
    }
    private static func url(host: String, path: String, query: [String: String]) throws -> URL {
        var components = URLComponents(); components.scheme = "https"; components.host = host; components.path = path
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw WeatherError.invalidPlace }; return url
    }
    private func read(_ url: URL) async throws -> Data {
        do {
            var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (stream, response) = try await session.bytes(for: request, delegate: redirects)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.url?.host == url.host, response.url?.scheme == "https" else { throw WeatherError.network }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw WeatherError.responseTooLarge }
            var data = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else { throw WeatherError.responseTooLarge }
                data.append(byte)
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as WeatherError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw WeatherError.network }
    }
    func searchPlaces(_ query: String) async throws -> [WeatherPlace] { try Self.decodePlaces(await read(Self.searchURL(query))) }
    func fetchWeather(for place: WeatherPlace, now: Date) async throws -> WeatherSnapshot {
        try Self.decodeSnapshot(await read(Self.forecastURL(for: place)), place: place, now: now)
    }
    static func decodePlaces(_ data: Data) throws -> [WeatherPlace] {
        struct Result: Decodable {
            var id: Int; var name: String; var latitude: Double; var longitude: Double
            var timezone: String; var country: String?; var admin1: String?
        }
        struct Envelope: Decodable { var results: [Result]? }
        guard data.count <= maximumResponseBytes else { throw WeatherError.responseTooLarge }
        do {
            let results = try JSONDecoder().decode(Envelope.self, from: data).results ?? []
            guard results.count <= 100 else { throw WeatherError.invalidResponse }
            var ids = Set<String>()
            return Array(results.compactMap { value -> WeatherPlace? in
                guard value.id > 0 else { return nil }
                let place = WeatherPlace(id: "open-meteo:\(value.id)", name: [value.name, value.admin1, value.country].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · "),
                    latitude: value.latitude, longitude: value.longitude, timeZone: value.timezone)
                guard (try? place.validated()) != nil, ids.insert(place.id).inserted else { return nil }; return place
            }.prefix(10))
        } catch let error as WeatherError { throw error } catch { throw WeatherError.invalidResponse }
    }
    static func decodeSnapshot(_ data: Data, place: WeatherPlace, now: Date) throws -> WeatherSnapshot {
        struct Current: Decodable { var time: Double; var temperature_2m: Double; var is_day: Int; var weather_code: Int; var wind_speed_10m: Double; var wind_direction_10m: Double; var precipitation: Double }
        struct Envelope: Decodable { var current: Current; var current_units: [String: String] }
        guard data.count <= maximumResponseBytes else { throw WeatherError.responseTooLarge }
        do {
            let decoded = try JSONDecoder().decode(Envelope.self, from: data), value = decoded.current, units = decoded.current_units
            guard units["time"] == "unixtime", units["temperature_2m"] == "°C", units["wind_speed_10m"] == "m/s",
                  units["precipitation"] == "mm", units["wind_direction_10m"] == "°", (0...1).contains(value.is_day),
                  now.timeIntervalSince1970 - value.time <= 12 * 3_600 else { throw WeatherError.invalidResponse }
            var snapshot = try WeatherSnapshot(place: place, weatherCode: value.weather_code, temperatureCelsius: value.temperature_2m,
                isDay: value.is_day == 1, windSpeedMetresPerSecond: value.wind_speed_10m,
                windDirectionDegrees: value.wind_direction_10m, precipitationMillimetres: value.precipitation,
                observedAt: Date(timeIntervalSince1970: value.time), fetchedAt: now).validated(now: now)
            snapshot.isStale = now.timeIntervalSince(snapshot.observedAt) > WeatherSnapshot.freshAge
            return snapshot
        } catch let error as WeatherError { throw error } catch { throw WeatherError.invalidResponse }
    }
    deinit { session.invalidateAndCancel() }
}

private final class WeatherRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
