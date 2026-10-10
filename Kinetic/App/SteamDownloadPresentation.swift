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

    /// R4：House 弹出的下载列表需要的名称、Poster 与分辨率标签（由 Steam 页面登记，不是下载真相）。
    struct DownloadInfo: Equatable {
        let id: String
        let title: String
        let posterURL: URL?
        let type: WallpaperType?
        let tags: [String]

        init(id: String, title: String, posterURL: URL?, type: WallpaperType?, tags: [String]) {
            self.id = id
            self.title = title
            self.posterURL = posterURL
            self.type = type
            self.tags = tags
        }

        init(item: SteamStoreItem, posterURL: URL?) {
            self.init(id: item.workshopID, title: item.title, posterURL: posterURL, type: item.type, tags: item.tags)
        }
    }

    @Published private(set) var activeIDs: Set<String> = []
    @Published private(set) var current: Flight?
    @Published private(set) var exitStartedAt: Date?
    /// 登记顺序即列表顺序。
    @Published private(set) var infos: [String: DownloadInfo] = [:]
    private(set) var infoOrder: [String] = []
    private var posters: [String: Poster] = [:]
    private var latestFrames: [String: CGRect] = [:]
    private var queue: [Poster] = []
    private var driver: Task<Void, Never>?
    private var generation = 0
    private var hadSuccess = false
    private var reduced = false
    var durationScale: Double = 1

    var isVisible: Bool { !activeIDs.isEmpty || current != nil || exitStartedAt != nil || !queue.isEmpty }
    var pendingIDs: [String] { queue.map(\.id) }

    /// 登记一次下载的展示信息（双击下载、拖到显示器下载、批量下载都登记）。
    func register(_ info: DownloadInfo) {
        if infos[info.id] == nil { infoOrder.append(info.id) }
        infos[info.id] = info
    }

    /// House 列表的行：只列出仍在进行的任务（排队、下载、校验、入库），按登记顺序。
    func downloadRows(tasks: [String: SteamAcquisitionService.TaskPhase]) -> [SteamDownloadRow] {
        let active = tasks.filter { $0.value.isActive }
        let ordered = infoOrder.filter { active[$0] != nil } + active.keys.filter { infos[$0] == nil }.sorted()
        return ordered.compactMap { id in
            guard let phase = active[id] else { return nil }
            let info = infos[id]
            return SteamDownloadRow(id: id,
                                    title: info?.title ?? String(format: NSLocalizedString("steam.item.untitled", comment: ""), id),
                                    posterURL: info?.posterURL, type: info?.type,
                                    ratio: SteamResolutionTag.ratioLabel(tags: info?.tags ?? []), phase: phase)
        }
    }

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
    /// Module 59：卡片滚出可见范围（不再上报位置）后，旧位置可能已经是别的卡片，完成动画改从内容区中央起飞。
    func updateFrames(_ frames: [String: CGRect]) {
        latestFrames = frames
        for id in activeIDs {
            guard let old = posters[id] else { continue }
            let frame = frames[id].flatMap { $0.isEmpty ? nil : $0 } ?? .zero
            posters[id] = Poster(id: id, image: old.image, frame: frame)
        }
    }

    /// 测试与诊断：一张下载中的卡片现在记录的起飞位置。
    func posterFrame(_ id: String) -> CGRect? { posters[id]?.frame }

    /// R4 批量下载：用卡片最近一次的位置与 Poster 开始一个下载的视觉（Clone 只在开始时截取一次）。
    /// 卡片不在屏幕上时没有位置，完成动画从内容区中央飞向 House。
    @discardableResult
    func begin(item: SteamStoreItem, posterURL: URL?, reduceMotion: Bool) -> Bool {
        let frame = latestFrames[item.workshopID] ?? .zero
        let image = Self.snapshot(posterURL: posterURL, type: item.type ?? .web, side: max(135, frame.width))
        guard begin(Poster(id: item.workshopID, image: image, frame: frame), reduceMotion: reduceMotion) else { return false }
        register(DownloadInfo(item: item, posterURL: posterURL))
        return true
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

    /// 最终退场：House 在烟雾最浓之前消失（雾遮住 House，House 在雾中消失），之后雾散开。
    static func houseOpacity(exit progress: Double) -> Double { 1 - min(1, max(0, progress) * 3) }
    static func smokeOpacity(exit progress: Double) -> Double { sin(min(1, max(0, progress)) * .pi) * 0.55 }
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
    /// R4：点按 House 打开「正在下载」列表；没有下载服务时 House 只是动画目标。
    var steam: SteamAcquisitionService? = nil
    var posters: SteamPosterCache? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var menuAnchor = SteamDownloadsMenuAnchor()

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
                        // 动画层不接收鼠标；只有 House 本身是按钮（R4 用户要求）。
                        Group {
                            if let flight, elapsed < flightDuration {
                                DownloadPosterRibbon(poster: flight.poster, target: CGPoint(x: center.x, y: center.y - 19),
                                                     progress: elapsed / flightDuration, reduced: reduced)
                            }
                            if exit > 0 {
                                DownloadSmoke(center: center, progress: exit, reduced: reduced)
                            }
                        }
                        .allowsHitTesting(false)

                        house(bounce: bounce, exit: exit)
                            .position(x: center.x, y: center.y - bounce)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func house(bounce: Double, exit: Double) -> some View {
        let image = Image(systemName: LocalLibraryIcon.symbolName)
            .font(.system(size: DownloadAnimationMetrics.houseSide, weight: .light))
            .foregroundStyle(LocalLibraryIcon.color)
            .scaleEffect(x: 1 - bounce / 100, y: 1 + bounce / 35, anchor: .bottom)
            .opacity(DownloadAnimationMetrics.houseOpacity(exit: exit))
        if let steam, exit == 0 {
            Button {
                menuAnchor.present(steam: steam, presentation: presentation, posters: posters)
            } label: {
                image.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background { SteamDownloadsMenuAnchorView(anchor: menuAnchor) }
            .help(Text("steam.download.house.help"))
            .accessibilityLabel(Text("steam.download.house"))
            .accessibilityHint(Text("steam.download.house.help"))
        } else {
            image
                .allowsHitTesting(false)
                .accessibilityLabel(Text("steam.download.house"))
        }
    }
}

/// 退场时的「白色烟雾」：中性、低饱和的雾团。深色模式为白色；浅色模式用浅灰，否则在浅色窗口背景上看不见（Module 59）。
struct DownloadSmoke: View {
    let center: CGPoint
    let progress: Double
    let reduced: Bool
    @Environment(\.colorScheme) private var colorScheme

    static func mistColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(white: 0.58)
    }

    var body: some View {
        Canvas { context, _ in
            let count = reduced ? 5 : 22
            let color = Self.mistColor(colorScheme)
            for i in 0..<count {
                var mist = context
                let angle = Double(i) * 2.39996
                let distance = CGFloat(8 + progress * Double(20 + i % 7 * 4))
                let radius = CGFloat(6 + i % 4) * (1 + progress)
                let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                mist.opacity = DownloadAnimationMetrics.smokeOpacity(exit: progress)
                mist.addFilter(.blur(radius: 5))
                mist.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(color))
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
    /// R4（用户要求）：圆环加粗一点，原来 2 pt。
    static let lineWidth: CGFloat = 3.25
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.22), lineWidth: Self.lineWidth)
            if let progress {
                Circle().trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(MainWindowDesignTokens.accent, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
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

// MARK: - R4：House 弹出的「正在下载」列表

/// 列表中的一行（只读投影；下载真相仍是 `SteamAcquisitionService.tasks`）。
struct SteamDownloadRow: Identifiable, Equatable {
    let id: String
    let title: String
    let posterURL: URL?
    let type: WallpaperType?
    /// 例如「16:9」；没有分辨率标签时为 nil。
    let ratio: String?
    let phase: SteamAcquisitionService.TaskPhase

    /// 确定的进度（0…1）；排队或未知总大小时为 nil（不定进度）。
    var progress: Double? {
        switch phase {
        case .downloading(let progress): return progress
        case .verifying, .importing: return 1
        case .queued, .finished, .failed: return nil
        }
    }
}

/// 创意工坊的分辨率标签 → 画面比例文字。标签只是作者填写的筛选标签，不是实际像素。
enum SteamResolutionTag {
    private static let known: [(Int, Int)] = [(16, 9), (16, 10), (21, 9), (32, 9), (48, 9), (4, 3), (5, 4), (3, 2),
                                             (1, 1), (9, 16), (10, 16), (9, 21), (3, 4)]

    static func ratioLabel(tags: [String]) -> String? {
        for tag in tags {
            let lower = tag.lowercased()
            if let ratio = ratio(fromDimensionsIn: lower) { return ratio }
            if lower == "ultrawide standard definition" { return "21:9" }
            if lower == "dual standard definition" { return "32:9" }
            if lower == "triple standard definition" { return "48:9" }
            if lower == "portrait standard definition" { return "9:16" }
            if lower == "dynamic resolution" { return NSLocalizedString("steam.ratio.dynamic", comment: "") }
        }
        return nil
    }

    /// 「3840 x 2160」→ 16:9；接近常见比例（3% 以内）时用常见写法，否则约分。
    static func ratio(fromDimensionsIn text: String) -> String? {
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2, text.contains("x"), numbers[numbers.count - 2] > 0, numbers[numbers.count - 1] > 0 else { return nil }
        let width = numbers[numbers.count - 2], height = numbers[numbers.count - 1]
        let value = Double(width) / Double(height)
        if let match = known.min(by: { abs(Double($0.0) / Double($0.1) - value) < abs(Double($1.0) / Double($1.1) - value) }),
           abs(Double(match.0) / Double(match.1) - value) / value < 0.03 {
            return "\(match.0):\(match.1)"
        }
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        return "\(width / a):\(height / a)"
    }
}

/// 弹出位置：House 上方。用系统 NSMenu（与辅助点按菜单同一种小窗口），不是新的独立窗口。
@MainActor
final class SteamDownloadsMenuAnchor: ObservableObject {
    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 60
    static let maximumVisibleRows = 5
    weak var view: NSView?

    func present(steam: SteamAcquisitionService, presentation: SteamDownloadPresentation, posters: SteamPosterCache?) {
        guard let view else { return }
        let rows = max(1, min(Self.maximumVisibleRows, presentation.downloadRows(tasks: steam.tasks).count))
        let height = CGFloat(rows) * Self.rowHeight + 2 * MainWindowDesignTokens.Spacing.small + 22
        let host = NSHostingView(rootView: SteamDownloadsList(steam: steam, presentation: presentation, posters: posters)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .frame(width: Self.width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        let item = NSMenuItem()
        item.view = host
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item)
        // 菜单左上角放在 House 上方：菜单向上展开，底边贴近 House 顶部。
        let bounds = view.bounds
        let gap: CGFloat = 6
        let top = view.isFlipped ? bounds.minY - gap - menu.size.height : bounds.maxY + gap + menu.size.height
        let point = NSPoint(x: bounds.midX - menu.size.width / 2, y: top)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

struct SteamDownloadsMenuAnchorView: NSViewRepresentable {
    let anchor: SteamDownloadsMenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

/// 列表内容：左边小 Poster；右边上方名称与比例（灰色小字），下方胶囊进度条。随下载进度实时更新。
struct SteamDownloadsList: View {
    @ObservedObject var steam: SteamAcquisitionService
    @ObservedObject var presentation: SteamDownloadPresentation
    let posters: SteamPosterCache?

    var body: some View {
        SteamDownloadsListContent(rows: presentation.downloadRows(tasks: steam.tasks))
    }
}

/// 列表的纯展示部分（便于按行验证外观）。
struct SteamDownloadsListContent: View {
    let rows: [SteamDownloadRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("steam.download.list.title")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, MainWindowDesignTokens.Spacing.compact)
                .frame(height: 22, alignment: .center)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text("steam.download.list.empty")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: SteamDownloadsMenuAnchor.rowHeight)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in SteamDownloadRowView(row: row) }
                    }
                }
                .scrollIndicators(rows.count > SteamDownloadsMenuAnchor.maximumVisibleRows ? .automatic : .hidden)
            }
        }
        .padding(.vertical, MainWindowDesignTokens.Spacing.small)
    }
}

private struct SteamDownloadRowView: View {
    let row: SteamDownloadRow

    var body: some View {
        HStack(spacing: MainWindowDesignTokens.Spacing.compact) {
            thumbnail
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: MainWindowDesignTokens.Spacing.small) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(row.ratio ?? NSLocalizedString("steam.ratio.unknown", comment: ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                SteamDownloadCapsuleBar(progress: row.progress)
            }
        }
        .padding(.horizontal, MainWindowDesignTokens.Spacing.compact)
        .frame(height: SteamDownloadsMenuAnchor.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.title))
        .accessibilityValue(row.progress.map { Text(verbatim: "\(Int($0 * 100))%") } ?? Text("steam.download.waiting"))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = row.posterURL, let artwork = PosterArtworkCache.shared.artwork(for: url) {
            Image(decorative: artwork.firstFrame, scale: 1).resizable().scaledToFill()
        } else {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(systemName: row.type == .video ? "play.rectangle" : "photo").foregroundStyle(.secondary)
            }
        }
    }
}

/// 胶囊形状的进度条：已知进度时 #58BFDA 填充；排队 / 未知总大小时一小段来回移动的不定进度，不伪造百分比。
struct SteamDownloadCapsuleBar: View {
    let progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                if let progress {
                    Capsule().fill(MainWindowDesignTokens.accent)
                        .frame(width: max(proxy.size.height, proxy.size.width * max(0, min(1, progress))))
                } else {
                    TimelineView(.animation(paused: reduceMotion)) { timeline in
                        let phase = reduceMotion ? 0.5 : (sin(timeline.date.timeIntervalSinceReferenceDate * 2.2) + 1) / 2
                        Capsule().fill(MainWindowDesignTokens.accent.opacity(0.75))
                            .frame(width: proxy.size.width * 0.28)
                            .offset(x: proxy.size.width * 0.72 * phase)
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
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
