import AppKit
import SwiftUI

/// NavigationSplitView 的原生列有独立 SwiftUI global 原点。拖放统一使用 NSWindow content 的左上角。
@MainActor
final class WindowDragCoordinates: ObservableObject {
    weak var view: NSView?
    @Published private(set) var attachment = 0

    func didAttach() { attachment += 1 }

    func windowPoint(forLocalPoint point: CGPoint) -> CGPoint? {
        guard let view, let content = view.window?.contentView else { return nil }
        let converted = view.convert(point, to: content)
        return CGPoint(x: converted.x - content.bounds.minX,
                       y: content.isFlipped ? converted.y - content.bounds.minY : content.bounds.maxY - converted.y)
    }

    func localPoint(forWindowPoint point: CGPoint) -> CGPoint? {
        guard let view, let content = view.window?.contentView else { return nil }
        let native = CGPoint(x: point.x + content.bounds.minX,
                             y: content.isFlipped ? point.y + content.bounds.minY : content.bounds.maxY - point.y)
        return view.convert(native, from: content)
    }

    func windowFrames<ID: Hashable>(_ frames: [ID: CGRect], globalOrigin: CGPoint) -> [ID: CGRect] {
        frames.reduce(into: [:]) { result, pair in
            let local = pair.value.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y)
            if let origin = windowPoint(forLocalPoint: local.origin),
               let end = windowPoint(forLocalPoint: .init(x: local.maxX, y: local.maxY)) {
                result[pair.key] = CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
            }
        }
    }
}

struct WindowDragCoordinateProbe: NSViewRepresentable {
    let reference: WindowDragCoordinates
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(); view.reference = reference; reference.view = view; return view
    }
    func updateNSView(_ nsView: ProbeView, context: Context) { reference.view = nsView }

    final class ProbeView: NSView {
        weak var reference: WindowDragCoordinates?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in self?.reference?.didAttach() }
        }
    }
}

struct WindowDragOriginKey: PreferenceKey {
    static var defaultValue: CGPoint? = nil
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        if let next = nextValue() { value = next }
    }
}

/// Module 19：长按拖动的临时 UI 状态。只在有效松手时产出目的地；不拥有 Runtime 或资料库。
struct LocalWallpaperDragPresentation {
    enum Destination: Equatable {
        case display(Wallpaper.ID, DisplayID)
        case list(Wallpaper.ID, UUID)
    }

    private(set) var wallpaperID: Wallpaper.ID?
    private(set) var location: CGPoint?
    private(set) var hoveredDisplayID: DisplayID?
    private(set) var hoveredListID: UUID?

    @discardableResult
    mutating func begin(_ id: Wallpaper.ID) -> Bool {
        guard wallpaperID == nil else { return false }
        wallpaperID = id
        return true
    }

    mutating func move(_ point: CGPoint, from id: Wallpaper.ID,
                       displayFrames: [DisplayID: CGRect], displayIDs: [DisplayID],
                       listFrames: [UUID: CGRect], listIDs: [UUID]) {
        guard wallpaperID == id else { return }
        location = point
        refresh(displayFrames: displayFrames, displayIDs: displayIDs,
                listFrames: listFrames, listIDs: listIDs)
    }

    mutating func refresh(displayFrames: [DisplayID: CGRect], displayIDs: [DisplayID],
                          listFrames: [UUID: CGRect], listIDs: [UUID]) {
        hoveredListID = location.flatMap { point in listIDs.first { listFrames[$0]?.contains(point) == true } }
        hoveredDisplayID = hoveredListID == nil
            ? DisplayTargetHitTesting.target(at: location, frames: displayFrames, availableIDs: displayIDs) : nil
    }

    /// 松手以最新坐标与当前设备 / 列表重新命中，不能沿用上一次 Hover，也不能回退到主屏。
    mutating func takeDrop(from id: Wallpaper.ID, at point: CGPoint,
                           displayFrames: [DisplayID: CGRect], displayIDs: [DisplayID],
                           listFrames: [UUID: CGRect], listIDs: [UUID],
                           isInLibrary: Bool, isPlayable: Bool) -> Destination? {
        guard wallpaperID == id else { return nil }
        defer { cancel() }
        guard isInLibrary else { return nil }
        if let list = listIDs.first(where: { listFrames[$0]?.contains(point) == true }) {
            return .list(id, list)
        }
        guard isPlayable,
              let display = DisplayTargetHitTesting.target(at: point, frames: displayFrames, availableIDs: displayIDs)
        else { return nil }
        return .display(id, display)
    }

    mutating func cancel(from id: Wallpaper.ID? = nil) {
        guard id == nil || wallpaperID == id else { return }
        wallpaperID = nil
        location = nil
        hoveredDisplayID = nil
        hoveredListID = nil
    }
}

/// 拖动的 Poster 复用现有正方形 / 模糊延展。坐标与命中都用 NSWindow content 左上角。
/// 只作视觉反馈，绝不拦截目标条的滚动或拖动事件，也不创建 Live Preview / Renderer。
@MainActor
struct LocalWallpaperDragOverlay: View {
    let wallpaper: Wallpaper
    let location: CGPoint?
    let items: [DisplayTargetItem]
    let hoveredID: DisplayID?

    var body: some View {
        WallpaperDisplayDragOverlay(location: location, items: items, hoveredID: hoveredID,
                                    showsTargets: WallpaperCardVisualState.isPlayable(wallpaper)) {
            PosterView(wallpaper: wallpaper)
        }
    }
}

/// Local / Steam use the same measured overlay. Only the Poster source differs.
@MainActor
struct WallpaperDisplayDragOverlay<Poster: View>: View {
    let location: CGPoint?
    let items: [DisplayTargetItem]
    let hoveredID: DisplayID?
    var showsTargets = true
    @ViewBuilder let poster: () -> Poster
    @StateObject private var coordinates = WindowDragCoordinates()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if showsTargets, !items.isEmpty {
                    DisplayTargetStrip(items: items, hoveredID: hoveredID, availableWidth: proxy.size.width)
                        .padding(.top, MainWindowDesignTokens.DisplayTarget.topInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                if let windowPoint = location, let point = coordinates.localPoint(forWindowPoint: windowPoint),
                   CGRect(origin: .zero, size: proxy.size).contains(point) {
                    let side = MainWindowDesignTokens.LocalDrag.posterSide
                    let offset = MainWindowDesignTokens.LocalDrag.pointerOffset
                    poster()
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                        .position(x: min(point.x + offset + side / 2, proxy.size.width - side / 2),
                                  y: min(point.y + offset + side / 2, proxy.size.height - side / 2))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { WindowDragCoordinateProbe(reference: coordinates) }
            .transformPreference(DisplayTargetFrameKey.self) { frames in
                frames = coordinates.windowFrames(frames, globalOrigin: proxy.frame(in: .global).origin)
            }
        }
    }
}

#if DEBUG
/// 生产卡片 / 手势 / Overlay 的独立验收窗口，模拟设备只记录目的地，不改用户桌面或资料库。
@MainActor
final class LocalWallpaperDragTestSession {
    private var window: NSWindow?
    func start() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Kinetic — 本地拖放验收（模拟设备）"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 540)
        window.contentView = NSHostingView(rootView: LocalWallpaperDragTestPanel())
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
    }
    func stop() { window?.close(); window = nil }
}

@MainActor
private struct LocalWallpaperDragTestPanel: View {
    @State private var drag = LocalWallpaperDragPresentation()
    @State private var frames: [DisplayID: CGRect] = [:]
    @State private var count = 2
    @State private var reversed = false
    @State private var selected = false
    @State private var applications = 0
    @State private var outcome = "尚未应用（不操作真实桌面）"
    private let wallpaper: Wallpaper = {
        Wallpaper(name: "本地网页示例", type: .web, source: .local,
                  resourceURL: Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Fixtures/web-sample")
                      ?? URL(fileURLWithPath: "/drag-acceptance/index.html"),
                  thumbnailURL: Bundle.main.url(forResource: "preview", withExtension: "png", subdirectory: "Fixtures/web-sample"))
    }()

    private var items: [DisplayTargetItem] {
        let names = ["Built-in Liquid Retina XDR Display", "Studio Display", "Portrait Display",
                     "LG UltraFine", "Wide Display", "Display Six", "Display Seven"]
        let result = (0..<count).map { index in
            DisplayTargetItem(display: .init(displayID: DisplayID("drag-\(index)"), displayName: names[index],
                                             runtime: .init(activeWallpaperID: index == 0 ? wallpaper.id : nil),
                                             frame: .init(x: 0, y: 0, width: index == 2 ? 1080 : 1600,
                                                          height: index == 2 ? 1920 : 1000)),
                              index: index, wallpaper: index == 0 ? wallpaper : nil)
        }
        return reversed ? Array(result.reversed()) : result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("长按下方 Poster，再拖向顶部显示器；松在空白或按 Escape 取消。")
            HStack {
                Button("2 台设备") { count = 2; frames = [:]; refresh() }
                Button("7 台设备") { count = 7; frames = [:]; refresh() }
                Button("重排设备") { reversed.toggle(); frames = [:]; refresh() }
                Button("断开最后设备") { count = max(0, count - 1); frames = [:]; refresh() }
            }
            HStack {
                Button("开始拖动（测试）") { _ = drag.begin(wallpaper.id) }
                Button("悬停首台（测试）") { hover(items.first?.id) }
                Button("悬停第二台（测试）") { hover(items.dropFirst().first?.id) }
                Button("移出目标（测试）") { move(.init(x: -100, y: -100)) }
                Button("松手（测试）") { finish(drag.location ?? .init(x: -100, y: -100)) }
                Button("取消（测试）") { drag.cancel() }
            }
            Text("\(outcome)；应用次数：\(applications)")
            Text("当前目标：\(drag.hoveredDisplayID?.rawValue ?? "无")")
                .font(.caption).foregroundStyle(.secondary)
            WallpaperCard(wallpaper: wallpaper, isSelected: selected, isActive: false,
                          onSelect: { selected.toggle(); outcome = "单击选中；未应用" },
                          onApply: { applications += 1; outcome = "常规应用入口" },
                          onContextMenu: { _ in
                let menu = NSMenu(); menu.addItem(withTitle: "辅助点按菜单", action: nil, keyEquivalent: ""); return menu
            }, onDisplayDrag: { event in
                switch event {
                case .began: _ = drag.begin(wallpaper.id)
                case .moved(let point): move(point)
                case .ended(let point): finish(point)
                case .cancelled: drag.cancel(from: wallpaper.id)
                }
            })
            .frame(width: 180)
            Spacer()
        }
        .padding(30).padding(.top, 150)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { WindowGlassBackground() }
        .overlay {
            if drag.wallpaperID != nil {
                LocalWallpaperDragOverlay(wallpaper: wallpaper, location: drag.location,
                                          items: items, hoveredID: drag.hoveredDisplayID)
            }
        }
        .onPreferenceChange(DisplayTargetFrameKey.self) { frames = $0; refresh() }
        .onExitCommand { drag.cancel(); outcome = "Escape 取消；未应用" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in drag.cancel() }
        .onDisappear { drag.cancel() }
    }

    private func refresh() {
        drag.refresh(displayFrames: frames, displayIDs: items.map(\.id), listFrames: [:], listIDs: [])
    }
    private func move(_ point: CGPoint) {
        drag.move(point, from: wallpaper.id, displayFrames: frames, displayIDs: items.map(\.id), listFrames: [:], listIDs: [])
    }
    private func hover(_ id: DisplayID?) {
        if let frame = id.flatMap({ frames[$0] }) { move(.init(x: frame.midX, y: frame.midY)) }
    }
    private func finish(_ point: CGPoint) {
        let drop = drag.takeDrop(from: wallpaper.id, at: point, displayFrames: frames, displayIDs: items.map(\.id),
                                 listFrames: [:], listIDs: [], isInLibrary: true, isPlayable: true)
        if case .display(_, let id) = drop { applications += 1; outcome = "拖放目的地 → \(id.rawValue)" }
        else { outcome = "目标外松手；未应用" }
    }
}
#endif
