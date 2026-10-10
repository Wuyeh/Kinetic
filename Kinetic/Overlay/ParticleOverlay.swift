import AppKit

/// Native transparent overlay; owns one bounded timer and its own simulation only.
@MainActor
final class ParticleOverlay: DesktopOverlay {
    let view: ParticleCanvasView
    var displayView: NSView { view }
    var onFailure: (@MainActor (Error) -> Void)?
    private(set) var context: OverlayContext?
    private(set) var isDisposed = false
    private(set) var isPlaying = false
    private(set) var tickCount = 0
    private(set) var timerFramesPerSecond: Int?
    private var timer: Timer?
    private var lastTick: TimeInterval?

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) { view = ParticleCanvasView(seed: seed) }

    func prepare(configuration: OverlayConfiguration, context: OverlayContext) async throws {
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        try update(configuration: configuration, context: context)
        try Task.checkCancellation()
        // Draw the static first appearance before OverlayManager attaches the surface.
        view.needsDisplay = true
    }
    func update(configuration: OverlayConfiguration, context: OverlayContext) throws {
        guard !isDisposed else { throw CancellationError() }
        let options = try ParticleOptions(configuration: configuration)
        guard context.frame.width.isFinite, context.frame.height.isFinite,
              context.frame.width > 0, context.frame.height > 0,
              context.backingScaleFactor.isFinite, context.backingScaleFactor > 0,
              (1...60).contains(context.maximumFramesPerSecond) else { throw OverlayError.invalidConfiguration }
        try view.configure(options)
        if self.context?.frame.size != context.frame.size { view.frame.size = context.frame.size }
        self.context = context
        if context.isPaused { isPlaying = false }
        synchronizeTimer()
    }
    func play() { guard !isDisposed else { return }; isPlaying = true; synchronizeTimer() }
    func pause() { isPlaying = false; stopTimer() }
    func dispose() {
        guard !isDisposed else { return }; isDisposed = true; pause(); context = nil
        onFailure = nil; view.clear(); view.removeFromSuperview()
    }
    private func synchronizeTimer() {
        guard isPlaying, let context, !context.isPaused, context.allowsAnimation,
              !view.simulation.options.reduceMotion, !view.simulation.particles.isEmpty else { stopTimer(); return }
        let fps = context.maximumFramesPerSecond
        guard timer == nil || timerFramesPerSecond != fps else { return }
        stopTimer(); timerFramesPerSecond = fps; lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / Double(fps), repeats: true) { [weak self] _ in
            // This Timer is registered only on the main run loop; avoid queued tasks per frame.
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1 / Double(fps)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func tick() {
        guard !isDisposed, isPlaying, timer != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = now - (lastTick ?? now); lastTick = now
        view.advance(by: delta); tickCount += 1
    }
    private func stopTimer() {
        timer?.invalidate(); timer = nil; timerFramesPerSecond = nil; lastTick = nil
    }
    deinit { timer?.invalidate() }
}

@MainActor
final class ParticleCanvasView: NSView {
    private(set) var simulation: ParticleSimulation
    init(seed: UInt64) {
        simulation = .init(seed: seed)
        super.init(frame: .zero); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(_ options: ParticleOptions) throws { try simulation.configure(options); needsDisplay = true }
    func advance(by duration: TimeInterval) { simulation.advance(by: duration); needsDisplay = true }
    func clear() { var options = simulation.options; options.density = 0; try? simulation.configure(options); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, bounds.width > 0, bounds.height > 0 else { return }
        cg.clear(dirtyRect)
        cg.saveGState(); cg.clip(to: bounds); cg.setAllowsAntialiasing(true)
        defer { cg.restoreGState() }
        let options = simulation.options
        let scale = min(bounds.width, bounds.height) / 900
        let alpha = 0.15 + options.intensity * 0.65
        for p in simulation.particles {
            cg.saveGState()
            let x = p.x * bounds.width, y = p.y * bounds.height
            cg.translateBy(x: x, y: y); cg.rotate(by: p.angle)
            let r = max(0.7, (2 + p.variation * 5) * scale)
            let pulse = 0.55 + 0.45 * sin(simulation.elapsed * 1.4 + p.phase)
            let white = NSColor(calibratedWhite: 1, alpha: alpha).cgColor
            cg.setFillColor(white); cg.setStrokeColor(white)
            switch options.preset {
            case .snow:
                cg.fillEllipse(in: .init(x: -r, y: -r, width: 2*r, height: 2*r))
            case .rain:
                cg.rotate(by: -p.angle)
                cg.setLineWidth(max(0.6, scale)); cg.move(to: .zero)
                cg.addLine(to: .init(x: -options.wind * 8 * scale, y: 28 * scale)); cg.strokePath()
            case .bokeh:
                glow(cg, color: NSColor(calibratedRed: 0.75, green: 0.9, blue: 1, alpha: alpha * 0.4), radius: r * 6)
            case .fireflies:
                glow(cg, color: NSColor(calibratedRed: 0.8, green: 1, blue: 0.35, alpha: alpha * pulse), radius: r * 2)
                cg.fillEllipse(in: .init(x: -r * 0.4, y: -r * 0.4, width: r * 0.8, height: r * 0.8))
            case .dust:
                cg.setAlpha(0.55); cg.fillEllipse(in: .init(x: -r/2, y: -r/2, width: r, height: r))
            case .stars:
                cg.setAlpha(pulse); cg.setLineWidth(max(0.6, scale))
                cg.move(to: .init(x: -r*2, y: 0)); cg.addLine(to: .init(x: r*2, y: 0))
                cg.move(to: .init(x: 0, y: -r*2)); cg.addLine(to: .init(x: 0, y: r*2)); cg.strokePath()
            case .leaves, .sakura:
                let color = options.preset == .leaves
                    ? NSColor(calibratedRed: 0.8, green: 0.55 + p.variation * 0.2, blue: 0.18, alpha: alpha)
                    : NSColor(calibratedRed: 1, green: 0.65 + p.variation * 0.2, blue: 0.8, alpha: alpha)
                cg.setFillColor(color.cgColor)
                cg.move(to: .init(x: 0, y: r*2))
                cg.addCurve(to: .init(x: 0, y: -r*2), control1: .init(x: r*2, y: r), control2: .init(x: r*2, y: -r))
                cg.addCurve(to: .init(x: 0, y: r*2), control1: .init(x: -r*2, y: -r), control2: .init(x: -r, y: r))
                cg.fillPath()
            case .mist:
                cg.scaleBy(x: 2.8, y: 1)
                glow(cg, color: NSColor(calibratedWhite: 1, alpha: alpha * 0.09), radius: (70 + p.variation * 80) * scale)
            case .embers:
                glow(cg, color: NSColor(calibratedRed: 1, green: 0.3 + p.variation * 0.35, blue: 0.05, alpha: alpha * pulse), radius: r*2)
            case .bubbles:
                cg.setLineWidth(max(0.6, scale)); cg.setAlpha(0.55)
                cg.strokeEllipse(in: .init(x: -r*3, y: -r*3, width: r*6, height: r*6))
                cg.fillEllipse(in: .init(x: -r, y: r, width: r, height: r))
            case .meteors:
                cg.rotate(by: -p.angle)
                for step in 0..<12 {
                    let t = Double(step) / 12, size = r * (1 - t * 0.7)
                    cg.setAlpha((1 - t) * pulse)
                    cg.fillEllipse(in: .init(x: -t*80*scale-size/2, y: t*60*scale-size/2, width: size, height: size))
                }
            }
            cg.restoreGState()
        }
    }
    private func glow(_ cg: CGContext, color: NSColor, radius: CGFloat) {
        guard radius > 0, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) else { return }
        cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    }
}
