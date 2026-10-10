import CoreGraphics
import Foundation

/// Module 42: the Nixie Clock overlay's own settings. Values belong to the overlay, never to a Wallpaper.
struct NixieClockOptions: Equatable, Sendable {
    var uses24Hour = true
    /// Off: a single-digit hour leaves the first tube unlit.
    var leadingZero = true
    var blinksSeparator = true
    var transparentBackground = true
    var opacity = 1.0
    var scale = 1.0
    /// Fractions of available travel; origin is top-left, like widget positions.
    var position = WidgetPosition(x: 0.5, y: 0.08)

    static let baseSize = CGSize(width: 300, height: 120)
    static let opacityRange = 0.2...1.0
    static let scaleRange = 0.5...3.0
    private static let keys: Set<String> = ["uses24Hour", "leadingZero", "blinksSeparator", "transparentBackground",
                                            "opacity", "scale", "x", "y"]

    init() {}
    init(configuration: OverlayConfiguration) throws {
        _ = try configuration.validated()
        guard configuration.kind == .clock, Set(configuration.parameters.keys).isSubset(of: Self.keys) else {
            throw OverlayError.invalidConfiguration
        }
        func flag(_ key: String, _ fallback: Bool) throws -> Bool {
            guard let value = configuration.parameters[key] else { return fallback }
            guard case .boolean(let flag) = value else { throw OverlayError.invalidConfiguration }
            return flag
        }
        func number(_ key: String, _ fallback: Double) throws -> Double {
            guard let value = configuration.parameters[key] else { return fallback }
            guard case .number(let number) = value else { throw OverlayError.invalidConfiguration }
            return number
        }
        uses24Hour = try flag("uses24Hour", uses24Hour); leadingZero = try flag("leadingZero", leadingZero)
        blinksSeparator = try flag("blinksSeparator", blinksSeparator)
        transparentBackground = try flag("transparentBackground", transparentBackground)
        opacity = try number("opacity", opacity); scale = try number("scale", scale)
        position = .init(x: try number("x", position.x), y: try number("y", position.y))
        self = try validated()
    }

    func validated() throws -> Self {
        guard opacity.isFinite, Self.opacityRange.contains(opacity), scale.isFinite, Self.scaleRange.contains(scale),
              position.x.isFinite, (0...1).contains(position.x), position.y.isFinite, (0...1).contains(position.y) else {
            throw OverlayError.invalidConfiguration
        }
        return self
    }

    func applying(to configuration: OverlayConfiguration) throws -> OverlayConfiguration {
        _ = try validated()
        guard configuration.kind == .clock else { throw OverlayError.invalidConfiguration }
        var result = configuration
        result.parameters = ["uses24Hour": .boolean(uses24Hour), "leadingZero": .boolean(leadingZero),
                             "blinksSeparator": .boolean(blinksSeparator), "transparentBackground": .boolean(transparentBackground),
                             "opacity": .number(opacity), "scale": .number(scale), "x": .number(position.x), "y": .number(position.y)]
        return try result.validated()
    }

    /// The clock's frame on a display (or a preview of it), always inside a 12 pt margin.
    func frame(in canvas: CGSize) -> CGRect? {
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return nil }
        let margin = min(12, min(canvas.width, canvas.height) / 4)
        let room = CGSize(width: canvas.width - margin * 2, height: canvas.height - margin * 2)
        let fitted = min(scale, room.width / Self.baseSize.width, room.height / Self.baseSize.height)
        let size = CGSize(width: Self.baseSize.width * max(0, fitted), height: Self.baseSize.height * max(0, fitted))
        return .init(x: margin + (room.width - size.width) * position.x, y: margin + (room.height - size.height) * position.y,
                     width: size.width, height: size.height)
    }
    func moved(by translation: CGSize, in canvas: CGSize) -> Self {
        guard translation.width.isFinite, translation.height.isFinite, let frame = frame(in: canvas) else { return self }
        let margin = min(12, min(canvas.width, canvas.height) / 4)
        let xTravel = canvas.width - margin * 2 - frame.width, yTravel = canvas.height - margin * 2 - frame.height
        var next = self
        next.position.x = xTravel > 0 ? max(0, min(1, position.x + translation.width / xTravel)) : position.x
        next.position.y = yTravel > 0 ? max(0, min(1, position.y + translation.height / yTravel)) : position.y
        return next
    }

    /// Four tubes, HH MM; nil leaves a tube unlit.
    static func digits(at date: Date, calendar: Calendar = .current, uses24Hour: Bool, leadingZero: Bool) -> [Int?] {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let raw = parts.hour ?? 0, minute = parts.minute ?? 0
        let hour = uses24Hour ? raw : (raw + 11) % 12 + 1
        return [hour < 10 && !leadingZero ? nil : hour / 10, hour % 10, minute / 10, minute % 10]
    }
    /// Blinking lights the separator on even seconds.
    static func separatorLit(at date: Date, calendar: Calendar = .current, blinking: Bool) -> Bool {
        !blinking || (calendar.component(.second, from: date) % 2 == 0)
    }
}
