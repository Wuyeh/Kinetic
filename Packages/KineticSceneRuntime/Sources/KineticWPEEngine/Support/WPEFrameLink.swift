import AppKit
import QuartzCore

/// Kinetic adaptation for macOS 13: `NSScreen.displayLink(target:selector:)` / `CADisplayLink` exist only on
/// macOS 14+. `WPEFrameLink` keeps upstream's display-link contract (`isPaused`, preferred rate, `targetTimestamp`,
/// run-loop attachment) and uses the real display link when available, otherwise a run-loop timer.
final class WPEFrameLink: NSObject {
    private weak var target: WPEDisplayLinkTarget?
    private var displayLink: AnyObject?
    private var timer: Timer?
    private weak var runLoop: RunLoop?
    private var mode: RunLoop.Mode = .common
    private var invalidated = false
    private(set) var targetTimestamp: CFTimeInterval = CACurrentMediaTime()
    private var framesPerSecond: Float = 60

    var isPaused = true {
        didSet { applyState() }
    }

    init(screen: NSScreen, target: WPEDisplayLinkTarget) {
        self.target = target
        super.init()
        if #available(macOS 14.0, *) {
            let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.isPaused = true
            displayLink = link
        }
    }

    @available(macOS 14.0, *)
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        targetTimestamp = link.targetTimestamp
        // Release each frame's Objective-C temporaries (drawables, command buffers) at frame cadence.
        autoreleasepool { target?.step(self) }
    }

    func setPreferredFrameRate(minimum: Float, maximum: Float, preferred: Float) {
        framesPerSecond = max(1, preferred)
        if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: minimum, maximum: maximum, preferred: preferred)
        } else {
            applyState()
        }
    }

    func add(to runLoop: RunLoop, forMode mode: RunLoop.Mode) {
        self.runLoop = runLoop
        self.mode = mode
        if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
            link.add(to: runLoop, forMode: mode)
        } else {
            applyState()
        }
    }

    func invalidate() {
        invalidated = true
        timer?.invalidate()
        timer = nil
        if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink { link.invalidate() }
        displayLink = nil
    }

    private func applyState() {
        if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
            link.isPaused = isPaused
            return
        }
        timer?.invalidate()
        timer = nil
        guard !invalidated, !isPaused, let runLoop else { return }
        let interval = 1.0 / Double(framesPerSecond)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.targetTimestamp = CACurrentMediaTime() + interval
            // A timer never makes the render thread's run loop return, so drain per frame here.
            autoreleasepool { self.target?.step(self) }
        }
        timer.tolerance = interval * 0.1
        runLoop.add(timer, forMode: mode)
        self.timer = timer
    }
}

extension NSScreen {
    /// The selected display mode, rather than the panel's highest supported mode (upstream LiveWallpaperCore).
    var configuredFramesPerSecond: Int {
        let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let rate = displayID.flatMap { CGDisplayCopyDisplayMode($0) }?.refreshRate ?? 0
        return rate.isFinite && rate > 0 ? max(1, Int(rate.rounded())) : max(1, maximumFramesPerSecond)
    }
}

extension UserDefaults {
    /// Upstream reads its debug toggles from an app-scoped suite; Kinetic uses the standard defaults.
    static func appScoped() -> UserDefaults { .standard }
    static var appSuite: UserDefaults { .standard }
}
