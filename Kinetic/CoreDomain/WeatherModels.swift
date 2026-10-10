import Foundation

enum WeatherMode: String, Codable, CaseIterable, Sendable { case off, system, manual }
enum WeatherAvailability: String, Codable, Sendable { case live, cached }
enum WeatherActivity: String, Sendable { case off, loading, ready, unavailable }
enum WeatherCondition: String, Sendable {
    case clear, cloudy, fog, drizzle, rain, snow, thunderstorm, unknown
    init(code: Int) {
        switch code {
        case 0, 1: self = .clear
        case 2, 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55, 56, 57: self = .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82: self = .rain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95, 96, 99: self = .thunderstorm
        default: self = .unknown
        }
    }
    var title: String { NSLocalizedString("weather.condition.\(rawValue)", comment: "") }
}

struct WeatherPlace: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var timeZone: String
    func validated() throws -> Self {
        guard !id.isEmpty, id.utf8.count <= 128,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
              latitude.isFinite, (-90...90).contains(latitude),
              longitude.isFinite, (-180...180).contains(longitude),
              timeZone.utf8.count <= 128, TimeZone(identifier: timeZone) != nil else { throw WeatherError.invalidPlace }
        return self
    }
    func matches(_ other: Self) -> Bool {
        id == other.id && abs(latitude - other.latitude) < 0.00001 && abs(longitude - other.longitude) < 0.00001
    }
}

struct WeatherConfiguration: Codable, Equatable, Sendable {
    var mode: WeatherMode = .off
    var manualPlace: WeatherPlace?
    func validated() throws -> Self {
        if let manualPlace { _ = try manualPlace.validated() }
        if mode == .manual && manualPlace == nil { throw WeatherError.invalidPlace }
        return self
    }
}

/// Actual provider values and their provenance. Unknown conditions stay unknown.
struct WeatherSnapshot: Codable, Equatable, Sendable {
    var place: WeatherPlace
    var weatherCode: Int
    var temperatureCelsius: Double
    var isDay: Bool
    var windSpeedMetresPerSecond: Double
    var windDirectionDegrees: Double
    var precipitationMillimetres: Double
    var observedAt: Date
    var fetchedAt: Date
    var availability: WeatherAvailability = .live
    var isStale = false
    var condition: WeatherCondition { .init(code: weatherCode) }
    static let freshAge: TimeInterval = 45 * 60
    static let responseAge: TimeInterval = 6 * 60 * 60

    func validated(now: Date) throws -> Self {
        _ = try place.validated()
        guard (0...999).contains(weatherCode), temperatureCelsius.isFinite, (-100...80).contains(temperatureCelsius),
              windSpeedMetresPerSecond.isFinite, (0...150).contains(windSpeedMetresPerSecond),
              windDirectionDegrees.isFinite, (0...360).contains(windDirectionDegrees),
              precipitationMillimetres.isFinite, (0...1_000).contains(precipitationMillimetres),
              observedAt.timeIntervalSince1970.isFinite, fetchedAt.timeIntervalSince1970.isFinite,
              observedAt.timeIntervalSince1970 >= 946_684_800, fetchedAt.timeIntervalSince1970 >= 946_684_800,
              observedAt <= now.addingTimeInterval(300), fetchedAt <= now.addingTimeInterval(300),
              observedAt <= fetchedAt.addingTimeInterval(300) else { throw WeatherError.invalidResponse }
        return self
    }
    func cached(at now: Date) -> Self {
        var value = self; value.availability = .cached
        value.isStale = now.timeIntervalSince(observedAt) > Self.freshAge
        return value
    }
    func permitsResponse(at now: Date) -> Bool {
        (try? validated(now: now)) != nil && condition != .unknown
            && now.timeIntervalSince(observedAt) <= Self.responseAge
    }
}

struct WeatherReading: Equatable, Sendable {
    var activity: WeatherActivity = .off
    var snapshot: WeatherSnapshot?
    var message: String?
}

enum WeatherError: LocalizedError {
    case invalidPlace, invalidResponse, settingsUnreadable, network, responseTooLarge, permissionRequired, permissionDenied, locationUnavailable
    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidPlace: key = "invalidPlace"
        case .invalidResponse: key = "invalidResponse"
        case .settingsUnreadable: key = "settingsUnreadable"
        case .network: key = "network"
        case .responseTooLarge: key = "responseTooLarge"
        case .permissionRequired: key = "permissionRequired"
        case .permissionDenied: key = "permissionDenied"
        case .locationUnavailable: key = "locationUnavailable"
        }
        return NSLocalizedString("weather.error.\(key)", comment: "")
    }
}
