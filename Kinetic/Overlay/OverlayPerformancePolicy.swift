import Foundation

/// Observed system conditions only. Manual pause is separate persisted intent.
struct OverlayPerformancePolicy: Equatable, Sendable {
    var isSuspended = false
    var reduceMotion = false
    var lowPowerMode = false

    func context(for configuration: OverlayConfiguration, display: DesktopDisplay) -> OverlayContext {
        OverlayContext(frame: display.frame, backingScaleFactor: display.backingScaleFactor,
            maximumFramesPerSecond: min(configuration.maximumFramesPerSecond, lowPowerMode ? 15 : 60),
            allowsAnimation: !reduceMotion,
            isPaused: isSuspended || configuration.isManuallyPaused)
    }
}

struct OverlayContext: Equatable, Sendable {
    var frame: CGRect
    var backingScaleFactor: CGFloat
    var maximumFramesPerSecond: Int
    var allowsAnimation: Bool
    var isPaused: Bool
}
