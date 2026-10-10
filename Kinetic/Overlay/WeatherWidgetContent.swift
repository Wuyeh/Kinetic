import AppKit
import Combine
import SwiftUI

enum WeatherWidgetPresentation {
    static func make(reading: WeatherReading, at now: Date) -> WidgetDataPresentation {
        let text = WidgetDataFormat.text
        guard reading.activity != .off else {
            return .init(caption: text("weatherWidget.off"), value: "—", note: text("weatherWidget.setup"), isUnavailable: true)
        }
        guard let weather = reading.snapshot, (try? weather.validated(now: now)) != nil else {
            return .init(caption: text(reading.activity == .loading ? "weatherWidget.loading" : "weatherWidget.unavailable"),
                value: "—", note: reading.message ?? text("weatherWidget.setup"), isUnavailable: true)
        }
        let formatter = DateFormatter(); formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: weather.place.timeZone); formatter.dateStyle = .short; formatter.timeStyle = .short
        let time = formatter.string(from: weather.observedAt)
        formatter.dateStyle = .none
        let compactTime = formatter.string(from: weather.observedAt)
        let stale = weather.isStale || now.timeIntervalSince(weather.observedAt) > WeatherSnapshot.freshAge
        let status: String
        if stale { status = text("weatherWidget.stale") }
        else if reading.activity == .loading { status = text("weatherWidget.updating") }
        else { status = text(weather.availability == .cached ? "weatherWidget.cached" : "weatherWidget.live") }
        var note = status + " · " + compactTime + " · Open-Meteo"
        if let message = reading.message, !message.isEmpty { note += "\n" + message }
        return .init(caption: weather.place.name, value: WidgetDataFormat.number(weather.temperatureCelsius) + " °C",
            symbol: symbol(condition: weather.condition, isDay: weather.isDay),
            rows: [.init(key: "weatherWidget.condition", value: weather.condition.title + " · " + text(weather.isDay ? "weather.day" : "weather.night")),
                .init(key: "weatherWidget.wind", value: WidgetDataFormat.number(weather.windSpeedMetresPerSecond) + " m/s · " + WidgetDataFormat.number(weather.windDirectionDegrees, decimals: 0) + "°"),
                .init(key: "weatherWidget.precipitation", value: WidgetDataFormat.number(weather.precipitationMillimetres) + " mm"),
                .init(key: "weatherWidget.observed", value: time)], note: note)
    }
    static func symbol(condition: WeatherCondition, isDay: Bool) -> String {
        switch condition {
        case .clear: return isDay ? "sun.max" : "moon.stars"
        case .cloudy: return isDay ? "cloud.sun" : "cloud.moon"
        case .fog: return "cloud.fog"
        case .drizzle: return "cloud.drizzle"
        case .rain: return "cloud.rain"
        case .snow: return "cloud.snow"
        case .thunderstorm: return "cloud.bolt.rain"
        case .unknown: return "questionmark"
        }
    }
}

/// Read-only consumer of the existing weather service. Adding a tile never configures or refreshes it.
@MainActor
final class WeatherWidgetContent: WidgetContent {
    private let service: WeatherService
    private let now: () -> Date
    private let state: WidgetDataViewState
    private let host: NSHostingView<WidgetDataView>
    private var observation: AnyCancellable?
    private var context: OverlayContext?
    var displayView: NSView { host }
    var onFailure: (@MainActor () -> Void)?
    private(set) var reading: WeatherReading
    private(set) var isPlaying = false
    private(set) var isDisposed = false
    var presentation: WidgetDataPresentation { state.presentation }

    init(configuration: WidgetConfiguration, service: WeatherService, now: @escaping () -> Date = Date.init) throws {
        _ = try configuration.validated(); guard configuration.kind == .weather else { throw WidgetBoardError.invalidLayout }
        self.service = service; self.now = now; reading = service.reading
        state = WidgetDataViewState(configuration: configuration, presentation: WeatherWidgetPresentation.make(reading: reading, at: now()))
        host = NSHostingView(rootView: WidgetDataView(state: state)); host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
    }
    func update(configuration: WidgetConfiguration, context: OverlayContext) throws {
        guard !isDisposed, configuration.kind == .weather, context.frame.width.isFinite, context.frame.height.isFinite,
              context.frame.width > 0, context.frame.height > 0 else { throw WidgetBoardError.invalidLayout }
        _ = try configuration.validated(); self.context = context; state.update(configuration: configuration, context: context)
        if context.isPaused { pause() }
    }
    func play() {
        guard !isDisposed, !isPlaying, context?.isPaused == false else { return }; isPlaying = true
        observation = service.$reading.sink { [weak self] reading in
            guard let self, self.isPlaying else { return }
            self.reading = reading; self.state.presentation = WeatherWidgetPresentation.make(reading: reading, at: self.now())
        }
    }
    func pause() { isPlaying = false; observation = nil }
    func dispose() {
        guard !isDisposed else { return }; pause(); isDisposed = true; context = nil; onFailure = nil; host.removeFromSuperview()
    }
    deinit { observation?.cancel() }
}

extension WidgetContentRegistry {
    func registerWeatherWidget(service: WeatherService) {
        register(.weather) { configuration in try WeatherWidgetContent(configuration: configuration, service: service) }
    }
}
