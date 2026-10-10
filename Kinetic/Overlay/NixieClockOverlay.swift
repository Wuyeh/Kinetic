import AppKit
import SwiftUI

/// Module 42: the tubes. Drawn procedurally (no image assets): smoky glass, a faint unlit cathode
/// and a warm glowing lit digit, with two neon dots between hours and minutes.
struct NixieClockFace: View {
    let options: NixieClockOptions
    let digits: [Int?]
    let separatorLit: Bool
    static let glow = Color(red: 1.0, green: 0.42, blue: 0.08)
    static let core = Color(red: 1.0, green: 0.78, blue: 0.52)

    var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width / NixieClockOptions.baseSize.width,
                           geometry.size.height / NixieClockOptions.baseSize.height)
            HStack(spacing: 6 * unit) {
                tube(digits[safe: 0] ?? nil, unit: unit); tube(digits[safe: 1] ?? nil, unit: unit)
                separator(unit: unit)
                tube(digits[safe: 2] ?? nil, unit: unit); tube(digits[safe: 3] ?? nil, unit: unit)
            }
            .padding(12 * unit)
            .background {
                if !options.transparentBackground {
                    RoundedRectangle(cornerRadius: 18 * unit, style: .continuous).fill(Color.black.opacity(0.62))
                        .overlay(RoundedRectangle(cornerRadius: 18 * unit, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: max(0.5, unit)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .opacity(options.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("clock.title"))
        .accessibilityValue(Text(Self.spoken(digits)))
    }

    private func tube(_ digit: Int?, unit: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24 * unit, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.13), Color(white: 0.08).opacity(0.55), Color.white.opacity(0.06)],
                                      startPoint: .top, endPoint: .bottom))
            Text("8").font(.system(size: 74 * unit, weight: .ultraLight)).foregroundStyle(Self.glow.opacity(0.09))
            if let digit {
                Text(String(digit)).font(.system(size: 74 * unit, weight: .ultraLight)).foregroundStyle(Self.core)
                    .shadow(color: Self.glow, radius: 2 * unit)
                    .shadow(color: Self.glow.opacity(0.9), radius: 7 * unit)
                    .shadow(color: Self.glow.opacity(0.55), radius: 16 * unit)
            }
            // Glass highlight along the left side of the envelope.
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.16), .clear], startPoint: .leading, endPoint: .center))
                .padding(.trailing, 30 * unit).padding(.vertical, 8 * unit).blendMode(.screen)
            shape.stroke(Color.white.opacity(0.2), lineWidth: max(0.5, unit))
        }
        .frame(width: 60 * unit, height: 96 * unit)
    }

    private func separator(unit: CGFloat) -> some View {
        VStack(spacing: 22 * unit) {
            ForEach(0..<2, id: \.self) { _ in
                Circle().fill(separatorLit ? Self.core : Self.glow.opacity(0.14)).frame(width: 7 * unit, height: 7 * unit)
                    .shadow(color: separatorLit ? Self.glow : .clear, radius: 4 * unit)
                    .shadow(color: separatorLit ? Self.glow.opacity(0.6) : .clear, radius: 10 * unit)
            }
        }
        .frame(width: 18 * unit)
    }

    static func spoken(_ digits: [Int?]) -> String {
        let text = digits.map { $0.map(String.init) ?? "" }
        guard text.count == 4 else { return "" }
        return text[0] + text[1] + ":" + text[2] + text[3]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

@MainActor
final class NixieClockState: ObservableObject {
    @Published var options = NixieClockOptions()
    @Published var digits: [Int?] = [0, 0, 0, 0]
    @Published var separatorLit = true
}

/// The full-display transparent canvas; the face sits at the configured position.
struct NixieClockCanvas: View {
    @ObservedObject var state: NixieClockState
    var body: some View {
        GeometryReader { geometry in
            if let frame = state.options.frame(in: geometry.size) {
                NixieClockFace(options: state.options, digits: state.digits, separatorLit: state.separatorLit)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
    }
}

/// Native transparent overlay. One non-repeating timer, re-armed for the next second (blinking) or the next
/// minute (steady); no timer at all while paused, hidden or disposed.
@MainActor
final class NixieClockOverlay: DesktopOverlay {
    let state = NixieClockState()
    private let host: NSHostingView<NixieClockCanvas>
    var displayView: NSView { host }
    var onFailure: (@MainActor (Error) -> Void)?
    private(set) var context: OverlayContext?
    private(set) var isDisposed = false
    private(set) var isPlaying = false
    private(set) var tickCount = 0
    private(set) var timer: Timer?
    private let now: () -> Date
    private var calendar: Calendar
    private var observers: [NSObjectProtocol] = []

    init(now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.now = now; self.calendar = calendar
        host = NSHostingView(rootView: NixieClockCanvas(state: state))
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        let center = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(); self?.synchronizeTimer(rearm: true) }
            })
        }
    }

    var blinks: Bool { state.options.blinksSeparator && context?.allowsAnimation == true }

    func prepare(configuration: OverlayConfiguration, context: OverlayContext) async throws {
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        try update(configuration: configuration, context: context)
    }
    func update(configuration: OverlayConfiguration, context: OverlayContext) throws {
        guard !isDisposed else { throw CancellationError() }
        let options = try NixieClockOptions(configuration: configuration)
        guard context.frame.width.isFinite, context.frame.height.isFinite, context.frame.width > 0, context.frame.height > 0,
              context.backingScaleFactor.isFinite, context.backingScaleFactor > 0,
              (1...60).contains(context.maximumFramesPerSecond) else { throw OverlayError.invalidConfiguration }
        let cadenceChanged = options.blinksSeparator != state.options.blinksSeparator || context.allowsAnimation != self.context?.allowsAnimation
        if state.options != options { state.options = options }
        if host.frame.size != context.frame.size { host.frame.size = context.frame.size }
        self.context = context
        refresh()
        if context.isPaused { pause() } else { synchronizeTimer(rearm: cadenceChanged) }
    }
    func play() {
        guard !isDisposed, context?.isPaused == false else { return }
        isPlaying = true; refresh(); synchronizeTimer(rearm: true)
    }
    /// Keeps the current reading on screen; no further updates until play.
    func pause() { isPlaying = false; timer?.invalidate(); timer = nil }
    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true; pause(); context = nil; onFailure = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        host.removeFromSuperview()
    }

    func refresh() {
        let date = now()
        let digits = NixieClockOptions.digits(at: date, calendar: calendar, uses24Hour: state.options.uses24Hour,
                                              leadingZero: state.options.leadingZero)
        let lit = NixieClockOptions.separatorLit(at: date, calendar: calendar, blinking: blinks)
        if state.digits != digits { state.digits = digits }
        if state.separatorLit != lit { state.separatorLit = lit }
    }
    /// Seconds until the next second or minute boundary, with a small lead past it.
    func nextInterval(from date: Date) -> TimeInterval {
        let unit: Calendar.Component = blinks ? .second : .minute
        guard let start = calendar.dateInterval(of: unit, for: date) else { return blinks ? 1 : 60 }
        return max(0.05, start.end.timeIntervalSince(date) + 0.01)
    }

    private func synchronizeTimer(rearm: Bool) {
        guard isPlaying, !isDisposed, context?.isPaused == false else { timer?.invalidate(); timer = nil; return }
        guard rearm || timer == nil else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: nextInterval(from: now()), repeats: false) { [weak self] _ in
            // Registered only on the main run loop.
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.isDisposed else { return }
                self.tickCount += 1; self.refresh(); self.synchronizeTimer(rearm: true)
            }
        }
        timer.tolerance = blinks ? 0.05 : 0.5
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
