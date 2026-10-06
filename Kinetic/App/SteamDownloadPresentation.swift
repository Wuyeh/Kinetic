import AppKit
import Combine
import SwiftUI

/// Module 15：只管理下载完成的视觉队列，不下载、不入库、不调用 Runtime。
@MainActor
final class SteamDownloadPresentation: ObservableObject {
    struct Poster: Identifiable {
        let id: String
        let image: NSImage?
        let frame: CGRect
    }
    struct Flight: Identifiable {
        let poster: Poster
        let startedAt: Date
        let reduceMotion: Bool
        var id: String { poster.id }
    }

    @Published private(set) var activeIDs: Set<String> = []
    @Published private(set) var current: Flight?
    @Published private(set) var exitStartedAt: Date?
    private var posters: [String: Poster] = [:]
    private var queue: [Poster] = []
    private var driver: Task<Void, Never>?
    private var generation = 0
    private var hadSuccess = false
    private var reduced = false
    var durationScale: Double = 1

    var isVisible: Bool { !activeIDs.isEmpty || current != nil || exitStartedAt != nil || !queue.isEmpty }
    var pendingIDs: [String] { queue.map(\.id) }

    @discardableResult
    func begin(_ poster: Poster, reduceMotion: Bool) -> Bool {
        guard !activeIDs.contains(poster.id) else { return false }
        // 新下载在最终退场期间开始时，让 House 立即回到等待态。
        if exitStartedAt != nil { generation += 1; driver?.cancel(); driver = nil; exitStartedAt = nil }
        reduced = reduceMotion
        activeIDs.insert(poster.id)
        posters[poster.id] = poster
        return true
    }

    /// 下载期间窗口 / Grid 可以移动，完成动画使用卡片最近一次实际位置。
    func updateFrames(_ frames: [String: CGRect]) {
        for id in activeIDs {
            guard let frame = frames[id], !frame.isEmpty, let old = posters[id] else { continue }
            posters[id] = Poster(id: id, image: old.image, frame: frame)
        }
    }

    func finish(_ id: String, succeeded: Bool) {
        guard activeIDs.remove(id) != nil else { return }
        if let poster = posters.removeValue(forKey: id), succeeded {
            hadSuccess = true
            queue.append(poster)
        }
        advance()
    }

    private func advance() {
        guard driver == nil else { return }
        if !queue.isEmpty {
            let flight = Flight(poster: queue.removeFirst(), startedAt: Date(), reduceMotion: reduced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            current = flight
            let token = generation
            let duration = DownloadAnimationMetrics.flightAndImpact(reduced: flight.reduceMotion) * durationScale
            driver = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.current = nil
                self.driver = nil
                self.advance()
            }
        } else if activeIDs.isEmpty, hadSuccess {
            exitStartedAt = Date()
            let token = generation
            driver = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(DownloadAnimationMetrics.exit * self.durationScale * 1_000_000_000))
                guard !Task.isCancelled, self.generation == token else { return }
                self.exitStartedAt = nil
                self.hadSuccess = false
                self.driver = nil
            }
        }
    }

    static func snapshot(posterURL: URL?, type: WallpaperType, side: CGFloat) -> NSImage? {
        // ImageRenderer 无法绘制 NSViewRepresentable；Clone 复用同一份已解码首帧、模糊背景与几何规则。
        let artwork = posterURL.flatMap { PosterArtworkCache.shared.artwork(for: $0) }
        let renderer = ImageRenderer(content: DownloadPosterSnapshot(artwork: artwork, type: type, side: side))
        renderer.scale = 2
        return renderer.nsImage
    }
}

private struct DownloadPosterSnapshot: View {
    let artwork: PosterArtwork?
    let type: WallpaperType
    let side: CGFloat
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let artwork {
                if let backdrop = artwork.backdrop {
                    Image(decorative: backdrop, scale: 1).resizable().scaledToFill()
                        .frame(width: side, height: side).clipped()
                }
                Image(decorative: artwork.firstFrame, scale: 1).resizable().scaledToFit()
                    .frame(width: side, height: side)
            } else {
                Image(systemName: type == .video ? "play.rectangle" : "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(PosterShape())
    }
}

enum DownloadAnimationMetrics {
    static let coordinateSpace = "Kinetic.DownloadContent"
    static let flight = 0.86
    static let impact = 0.52
    static let exit = 0.4
    static let reducedFlight = 0.26
    static let reducedImpact = 0.16
    static let houseSide: CGFloat = 38
    static func flightAndImpact(reduced: Bool) -> Double {
        reduced ? reducedFlight + reducedImpact : flight + impact
    }

    /// 正常窗口中处于固定工具条右端与窗口右缘之间；非常窄时移至工具条上方，避免遮挡控件。
    static func houseCenter(in size: CGSize) -> CGPoint {
        let toolbarWidth = min(MainWindowDesignTokens.FloatingToolbar.width, max(0, size.width - 32))
        let toolbarRight = (size.width + toolbarWidth) / 2
        let room = size.width - toolbarRight
        let centerX = min(size.width - houseSide / 2 - 16, (toolbarRight + size.width) / 2)
        let y = size.height - MainWindowDesignTokens.FloatingToolbar.bottomInset
            - MainWindowDesignTokens.FloatingToolbar.height / 2
        return CGPoint(x: max(houseSide / 2 + 16, centerX), y: room >= houseSide + 32 ? y : y - 64)
    }

    static func point(on curve: [CGPoint], at t: Double) -> CGPoint {
        let t = CGFloat(min(1, max(0, t))), s = 1 - t
        return CGPoint(x: s*s*s*curve[0].x + 3*s*s*t*curve[1].x + 3*s*t*t*curve[2].x + t*t*t*curve[3].x,
                       y: s*s*s*curve[0].y + 3*s*s*t*curve[1].y + 3*s*t*t*curve[2].y + t*t*t*curve[3].y)
    }

    /// 两个完整、逐渐衰减的周期；不是无限重复的弹簧。
    static func bounce(at progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return sin(t * 4 * .pi) * (1 - t) * 7
    }
}

struct SteamPosterFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 一层不接收鼠标的视觉 Clone 与共享 House；原卡片始终留在 Grid 中。
struct SteamDownloadOverlay: View {
    @ObservedObject var presentation: SteamDownloadPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if presentation.isVisible {
                TimelineView(.animation) { timeline in
                    let center = DownloadAnimationMetrics.houseCenter(in: proxy.size)
                    let flight = presentation.current
                    let elapsed = flight.map { timeline.date.timeIntervalSince($0.startedAt) } ?? 0
                    let reduced = reduceMotion || flight?.reduceMotion == true
                    let flightDuration = reduced ? DownloadAnimationMetrics.reducedFlight : DownloadAnimationMetrics.flight
                    let impactDuration = reduced ? DownloadAnimationMetrics.reducedImpact : DownloadAnimationMetrics.impact
                    let impact = max(0, min(1, (elapsed - flightDuration) / impactDuration))
                    let bounce = reduced ? sin(impact * .pi) * 1.5 : DownloadAnimationMetrics.bounce(at: impact)
                    let exit = presentation.exitStartedAt.map {
                        max(0, min(1, timeline.date.timeIntervalSince($0) / DownloadAnimationMetrics.exit))
                    } ?? 0
                    ZStack(alignment: .topLeading) {
                        Image(systemName: LocalLibraryIcon.symbolName)
                            .font(.system(size: DownloadAnimationMetrics.houseSide, weight: .light))
                            .foregroundStyle(LocalLibraryIcon.color)
                            .scaleEffect(x: 1 - bounce / 100, y: 1 + bounce / 35, anchor: .bottom)
                            .opacity(1 - min(1, exit * 3))
                            .position(x: center.x, y: center.y - bounce)
                            .accessibilityLabel(Text("steam.download.house"))

                        if let flight, elapsed < flightDuration {
                            DownloadPosterRibbon(poster: flight.poster, target: CGPoint(x: center.x, y: center.y - 19),
                                                 progress: elapsed / flightDuration, reduced: reduced)
                        }
                        if exit > 0 {
                            whiteSmoke(center: center, progress: exit, reduced: reduced)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }

    private func whiteSmoke(center: CGPoint, progress: Double, reduced: Bool) -> some View {
        Canvas { context, _ in
            let count = reduced ? 5 : 22
            for i in 0..<count {
                var mist = context
                let angle = Double(i) * 2.39996
                let distance = CGFloat(8 + progress * Double(20 + i % 7 * 4))
                let radius = CGFloat(6 + i % 4) * (1 + progress)
                let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                mist.opacity = sin(progress * .pi) * 0.55
                mist.addFilter(.blur(radius: 5))
                mist.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(.white))
            }
        }
    }
}

/// 将同一个 Poster 切成细条，每条沿同一曲线的不同时间点运动，形成弯曲及尾部拖曳。
/// 接近屋顶时上沿先进入，后续条带继续加速收窄；不是整张刚体 ScaleX/ScaleY。
struct DownloadPosterRibbon: View {
    let poster: SteamDownloadPresentation.Poster
    let target: CGPoint
    let progress: Double
    let reduced: Bool

    var body: some View {
        Canvas { context, size in
            guard let image = poster.image else { return }
            let side = poster.frame.isEmpty ? CGFloat(180) : max(1, poster.frame.width)
            let source = poster.frame.isEmpty ? CGPoint(x: size.width / 2, y: size.height / 2)
                : CGPoint(x: poster.frame.midX, y: poster.frame.midY)
            let t = max(0, min(1, progress))
            let resolved = context.resolve(Image(nsImage: image))
            if reduced {
                let scale = 1 - t * 0.8
                let center = CGPoint(x: source.x + (target.x - source.x) * 0.08 * t,
                                     y: source.y + (target.y - source.y) * 0.08 * t)
                context.opacity = 1 - t
                context.draw(resolved, in: CGRect(x: center.x - side * scale / 2, y: center.y - side * scale / 2,
                                                 width: side * scale, height: side * scale))
                return
            }
            let curve = [source, CGPoint(x: source.x + (target.x - source.x) * 0.2, y: source.y - 100),
                         CGPoint(x: target.x - 110, y: target.y - 140), target]
            let strips = 32
            let band = side / CGFloat(strips)
            let bend = min(1, t / 0.55)
            for i in 0..<strips {
                let u = Double(i) / Double(strips - 1)
                let travel = max(0, min(1, pow(t, 1.5) * 1.18 - u * 0.18 * bend))
                guard travel < 1 else { continue }
                var center = DownloadAnimationMetrics.point(on: curve, at: travel)
                center.y += (CGFloat(i) + 0.5 - CGFloat(strips) / 2) * band * (1 - bend)
                let next = DownloadAnimationMetrics.point(on: curve, at: min(1, travel + 0.002))
                let angle = (atan2(next.y - center.y + (CGFloat(i) + 0.5 - CGFloat(strips) / 2) * band * (1 - bend),
                                   next.x - center.x) + .pi / 2) * bend
                let widthScale = max(0.005, 1 - pow(travel, 3.2))
                let lengthScale = 1 + pow(travel, 2) * 1.8
                var strip = context
                strip.translateBy(x: center.x, y: center.y)
                strip.rotate(by: .radians(angle))
                strip.scaleBy(x: widthScale, y: lengthScale)
                strip.clip(to: Path(CGRect(x: -side / 2, y: -band / 2, width: side, height: band + 0.8)))
                strip.draw(resolved, in: CGRect(x: -side / 2, y: -CGFloat(i) * band - band / 2,
                                               width: side, height: side))
            }
        }
    }
}

/// 已知总字节数才绘制确定的进度；未知、排队或校验中使用不定进度，不伪造百分比。
struct SteamDownloadRing: View {
    let progress: Double?
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.22), lineWidth: 2)
            if let progress {
                Circle().trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(MainWindowDesignTokens.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView().controlSize(.mini).tint(MainWindowDesignTokens.accent)
            }
        }
        .frame(width: 24, height: 24)
        .padding(5)
        .kineticGlass(in: Circle())
        .accessibilityLabel(Text("steam.download.progress"))
        .accessibilityValue(progress.map { Text(verbatim: "\(Int($0 * 100))%") } ?? Text("steam.download.waiting"))
    }
}

#if DEBUG
/// 不联网、不写资料库的实际窗口验收入口，复用生产动画队列与 Overlay。
@MainActor
final class SteamDownloadTestSession {
    private var window: NSWindow?
    func start() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Kinetic — 下载体验验收"
        window.contentView = NSHostingView(rootView: SteamDownloadTestPanel())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

private struct SteamDownloadTestPanel: View {
    @StateObject private var presentation = SteamDownloadPresentation()
    @State private var reduced = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Button("开始两个下载") {
                        for (index, id) in ["A", "B"].enumerated() {
                            let image = NSImage(size: NSSize(width: 180, height: 180), flipped: false) { rect in
                                (index == 0 ? NSColor.systemTeal : .systemOrange).setFill()
                                rect.fill()
                                NSColor.white.setFill()
                                NSRect(x: 55, y: 25, width: 25, height: 130).fill()
                                return true
                            }
                            presentation.begin(.init(id: id, image: image,
                                                     frame: CGRect(x: 30 + index * 210, y: 90, width: 180, height: 180)),
                                               reduceMotion: reduced)
                        }
                    }
                    Button("完成 B") { presentation.finish("B", succeeded: true) }
                    Button("完成 A") { presentation.finish("A", succeeded: true) }
                    Button("失败 A") { presentation.finish("A", succeeded: false) }
                    Toggle("减弱动态效果", isOn: $reduced)
                }
                HStack(spacing: 30) {
                    ForEach(["A", "B"], id: \.self) { id in
                        RoundedRectangle(cornerRadius: 14).fill(id == "A" ? Color.teal : .orange)
                            .frame(width: 180, height: 180)
                            .overlay(alignment: .bottomTrailing) {
                                if presentation.activeIDs.contains(id) { SteamDownloadRing(progress: id == "A" ? 0.38 : 0.72).padding(8) }
                            }
                    }
                }
                Text("完成事件按 B → A 排队；原卡片留在网格，失败不进入动画。")
            }
            .padding(30)
            VStack { Spacer(); Capsule().stroke(.secondary).frame(width: 650, height: 56).padding(.bottom, 28) }
                .frame(maxWidth: .infinity)
            SteamDownloadOverlay(presentation: presentation)
        }
    }
}
#endif
