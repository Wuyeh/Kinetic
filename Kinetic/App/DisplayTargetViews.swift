import AppKit
import SwiftUI

private typealias Tokens = MainWindowDesignTokens

/// Module 17：显示器快照的纯 UI 投影。设备身份、几何和当前壁纸都来自同一个 Runtime 会话。
struct DisplayTargetItem: Identifiable, Equatable {
    let id: DisplayID
    let name: String
    let aspectRatio: CGFloat
    let wallpaperName: String?
    let thumbnailURL: URL?

    init(display: DisplayRuntimeState, index: Int, wallpaper: Wallpaper?) {
        id = display.displayID
        let name = display.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.isEmpty
            ? String(format: NSLocalizedString("displayPicker.fallback", comment: ""), index + 1)
            : name
        if let frame = display.frame, frame.size.width.isFinite, frame.size.height.isFinite,
           frame.size.width > 0, frame.size.height > 0 {
            aspectRatio = frame.size.width / frame.size.height
        } else {
            aspectRatio = Tokens.DisplayTarget.fallbackAspectRatio
        }
        // Prepare 期间仍展示旧 Active；停止后的 last ID 不是正在显示的壁纸。
        let active = wallpaper.flatMap { display.runtime.activeWallpaperID == $0.id ? $0 : nil }
        wallpaperName = active?.name
        thumbnailURL = active?.thumbnailURL
    }

    var previewSize: CGSize {
        let box = Tokens.DisplayTarget.previewBox
        let width = min(box.width, box.height * aspectRatio)
        return CGSize(width: width, height: width / aspectRatio)
    }
}

enum DisplayTargetHitTesting {
    /// 只有可见的部分才是目标，滚动裁切之外的 Preview 不能接收拖放。
    static func clippedFrames(_ frames: [DisplayID: CGRect], viewport: CGRect) -> [DisplayID: CGRect] {
        guard !viewport.isEmpty, !viewport.isNull else { return [:] }
        return frames.reduce(into: [:]) { result, pair in
            let visible = pair.value.intersection(viewport)
            if !visible.isNull, !visible.isEmpty { result[pair.key] = visible }
        }
    }

    /// 使用当前稳定 ID 顺序，最多返回一台仍连接的设备；绝不以数组下标或主屏兜底。
    static func target(at point: CGPoint?, frames: [DisplayID: CGRect], availableIDs: [DisplayID]) -> DisplayID? {
        guard let point else { return nil }
        return availableIDs.first { frames[$0]?.contains(point) == true }
    }
}

struct DisplayTargetFrameKey: PreferenceKey {
    static var defaultValue: [DisplayID: CGRect] = [:]
    static func reduce(value: inout [DisplayID: CGRect], nextValue: () -> [DisplayID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct DisplayTargetBoundsKey: PreferenceKey {
    static var defaultValue: [DisplayID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [DisplayID: Anchor<CGRect>], nextValue: () -> [DisplayID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 临时目标条。不持有 Renderer，不改变壁纸；同一个组件供本地与后续 Steam 拖放使用。
@MainActor
struct DisplayTargetStrip: View {
    let items: [DisplayTargetItem]
    let hoveredID: DisplayID?
    let availableWidth: CGFloat

    static func size(items: [DisplayTargetItem], availableWidth: CGFloat) -> CGSize {
        let inset = Tokens.DisplayTarget.inset
        let naturalWidth = items.reduce(0) { $0 + $1.previewSize.width }
            + CGFloat(max(0, items.count - 1)) * Tokens.DisplayTarget.gap + 2 * inset
        return CGSize(width: max(0, min(naturalWidth, Tokens.DisplayTarget.maximumWidth,
                                        availableWidth - 2 * Tokens.DisplayTarget.windowMargin)),
                      height: (items.map { $0.previewSize.height }.max() ?? 0) + 2 * inset)
    }

    var body: some View {
        let size = Self.size(items: items, availableWidth: availableWidth)
        ScrollView(.horizontal) {
            HStack(alignment: .center, spacing: Tokens.DisplayTarget.gap) {
                ForEach(items) { item in
                    DisplayTargetPreview(item: item, isHovered: hoveredID == item.id)
                        .anchorPreference(key: DisplayTargetBoundsKey.self, value: .bounds) { [item.id: $0] }
                }
            }
            .padding(Tokens.DisplayTarget.inset)
            .frame(minHeight: size.height)
        }
        .scrollIndicators(.hidden)
        .frame(width: size.width, height: size.height)
        .kineticGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.container, style: .continuous))
        // 同一帧内解出 Preview anchor 和 Scroll viewport，不经两份 @State 回传坐标。
        .overlayPreferenceValue(DisplayTargetBoundsKey.self) { anchors in
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let raw = anchors.mapValues { proxy[$0] }
                let visible = DisplayTargetHitTesting.clippedFrames(raw, viewport: CGRect(origin: .zero, size: proxy.size))
                Color.clear.preference(key: DisplayTargetFrameKey.self,
                                       value: visible.mapValues { $0.offsetBy(dx: origin.x, dy: origin.y) })
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("displayTarget.title"))
    }
}

@MainActor
private struct DisplayTargetPreview: View {
    let item: DisplayTargetItem
    let isHovered: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.medium, style: .continuous)
        Color(nsColor: .controlBackgroundColor)
        .overlay {
            if let url = item.thumbnailURL, let artwork = PosterArtworkCache.shared.artwork(for: url) {
                Image(decorative: artwork.firstFrame, scale: 1)
                    .resizable().scaledToFill()
            } else {
                Image(systemName: "display")
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: item.previewSize.width, height: item.previewSize.height)
        .overlay(alignment: .top) {
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Tokens.Spacing.small)
                .padding(.vertical, Tokens.Spacing.micro)
                .background(.regularMaterial, in: Capsule())
                .padding(Tokens.Spacing.micro)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isHovered ? Tokens.accent.opacity(0.9) : Color.primary.opacity(0.14),
                               lineWidth: isHovered ? 2 : 1)
                .shadow(color: Tokens.accent.opacity(isHovered ? 0.55 : 0), radius: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.name))
        .accessibilityValue(item.wallpaperName.map { Text(verbatim: $0) } ?? Text("displayTarget.systemWallpaper"))
        .accessibilityAddTraits(isHovered ? .isSelected : [])
        .help(item.name)
    }
}

/// Module 20：暂存用户这一次的单张 Apply 请求，Cancel / 选择都消耗请求，重复点按不会重复应用。
struct DisplayApplyPresentation: Equatable {
    private(set) var wallpaperID: Wallpaper.ID?
    var isPresented: Bool { wallpaperID != nil }

    mutating func present(_ wallpaperID: Wallpaper.ID) { self.wallpaperID = wallpaperID }
    mutating func cancel() { wallpaperID = nil }

    mutating func takeSelection(_ displayID: DisplayID, availableIDs: [DisplayID],
                                isInLibrary: (Wallpaper.ID) -> Bool) -> Wallpaper.ID? {
        defer { cancel() }
        guard let wallpaperID, availableIDs.contains(displayID), isInLibrary(wallpaperID) else { return nil }
        return wallpaperID
    }
}

/// 主窗口中央的选择窗口，按钮按稳定 ID 生成；列表过长时只滚动设备列表。
struct DisplayApplyDialog: View {
    let items: [DisplayTargetItem]
    let availableSize: CGSize
    let onSelect: (DisplayID) -> Void
    let onCancel: () -> Void
    @FocusState private var focusedID: DisplayID?

    var body: some View {
        let width = max(0, min(Tokens.DisplayPicker.contentWidth, availableSize.width - 96))
        let rowHeight = Tokens.DisplayPicker.rowHeight
        let listHeight = min(CGFloat(items.count) * (rowHeight + Tokens.Spacing.small) - Tokens.Spacing.small,
                             Tokens.DisplayPicker.maximumListHeight, max(rowHeight, availableSize.height - 200))
        ZStack {
            Color.black.opacity(0.22).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(spacing: Tokens.Spacing.standard) {
                Text("displayPicker.title").font(.system(size: 20, weight: .semibold))
                Text("displayPicker.detail")
                    .font(Tokens.Typography.metadata).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ScrollView(.vertical) {
                    KineticGlassContainer(spacing: Tokens.Spacing.small) {
                        VStack(spacing: Tokens.Spacing.small) {
                            ForEach(items) { item in
                                Button { onSelect(item.id) } label: {
                                    Text(item.name).lineLimit(1).truncationMode(.tail)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                }
                                .kineticGlassButton()
                                .frame(height: rowHeight)
                                .focused($focusedID, equals: item.id)
                                .help(item.name)
                                .accessibilityIdentifier("displayPicker.\(item.id.rawValue)")
                            }
                        }
                        .padding(.horizontal, Tokens.Spacing.micro)
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: max(0, listHeight))
                Button("displayPicker.cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction).kineticGlassButton()
            }
            .frame(width: width)
            .padding(Tokens.Spacing.section)
            .kineticGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .onAppear { focusedID = items.first?.id }
        .onChange(of: items.map(\.id)) { ids in
            if let focusedID, !ids.contains(focusedID) { self.focusedID = ids.first }
        }
        .onExitCommand(perform: onCancel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("displayPicker")
    }
}

#if DEBUG
/// 独立窗口复用生产组件，用注入设备检查 UI；不联网、不写资料库、不创建桌面窗口。
@MainActor
final class DisplayTargetTestSession {
    private var window: NSWindow?
    func start() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Kinetic — 显示器 UI 验收（模拟设备）"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 540)
        window.contentView = NSHostingView(rootView: DisplayTargetTestPanel())
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
    }
    func stop() { window?.close(); window = nil }
}

private struct DisplayTargetTestPanel: View {
    @State private var count = 2
    @State private var reversed = false
    @State private var stripVisible = true
    @State private var hoveredID: DisplayID?
    @State private var pointer: CGPoint?
    @State private var frames: [DisplayID: CGRect] = [:]
    @State private var picker = DisplayApplyPresentation()
    @State private var outcome = "尚未应用（不操作真实桌面）"
    private let wallpaperID = UUID()

    private var items: [DisplayTargetItem] {
        let names = ["Built-in Liquid Retina XDR Display", "Studio Display", "Portrait Display",
                     "LG UltraFine", "Wide Display", "Display Six", "Display Seven"]
        let preview = Bundle.main.url(forResource: "preview", withExtension: "png", subdirectory: "Fixtures/web-sample")
        let wallpaper = Wallpaper(id: wallpaperID, name: "网页示例", type: .web, source: .local,
                                  resourceURL: URL(fileURLWithPath: "/ui-acceptance/index.html"), thumbnailURL: preview)
        let result = (0..<count).map { index in
            DisplayTargetItem(display: .init(displayID: DisplayID("demo-\(index)"), displayName: names[index],
                                             runtime: .init(activeWallpaperID: index == 1 ? nil : wallpaperID),
                                             frame: .init(x: 0, y: 0, width: index == 2 ? 1080 : 1600,
                                                          height: index == 2 ? 1920 : 1000)),
                              index: index, wallpaper: index == 1 ? nil : wallpaper)
        }
        return reversed ? result.reversed() : result
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    ForEach([1, 2, 4, 7], id: \.self) { number in
                        Button("\(number) 台设备") { count = number; hoveredID = nil; frames = [:] }
                    }
                    Button("重排设备") { reversed.toggle(); frames = [:]; hoveredID = nil }
                    Button("断开最后设备") { count = max(0, count - 1); frames = [:]; hoveredID = nil }
                }
                HStack {
                    Button("显示 / 隐藏目标条") { stripVisible.toggle() }
                    Button("应用壁纸") {
                        switch LocalCardApplyRoute.resolve(.init(displays: items.map {
                            .init(displayID: $0.id, displayName: $0.name, runtime: .init())
                        })) {
                        case .direct(let id): outcome = "直接应用 → \(id.rawValue)"
                        case .chooseDisplay: picker.present(wallpaperID)
                        case .unavailable: outcome = "无显示器；未应用"
                        }
                    }
                    Button("测试悬停首台") { hover(items.first?.id) }
                    Button("测试悬停第二台") { hover(items.dropFirst().first?.id) }
                    Button("测试移出目标") { pointer = nil; updateHover() }
                }
                Text(outcome)
                Text("悬停目标条可验单一光晕；横向滚动查看全部设备。")
                    .foregroundStyle(.secondary)
                Text("可见目标：\(items.filter { frames[$0.id] != nil }.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("当前目标：\(hoveredID?.rawValue ?? "无")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(30).padding(.top, 150)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { WindowGlassBackground() }
            .overlay(alignment: .top) {
                if stripVisible, !items.isEmpty {
                    DisplayTargetStrip(items: items, hoveredID: hoveredID, availableWidth: proxy.size.width)
                        .padding(.top, Tokens.DisplayTarget.topInset)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .onContinuousHover(coordinateSpace: .global) { phase in
                            switch phase {
                            case .active(let point): pointer = point
                            case .ended: pointer = nil
                            }
                            updateHover()
                        }
                }
            }
            .onPreferenceChange(DisplayTargetFrameKey.self) { frames = $0; updateHover() }
            .overlay {
                if picker.isPresented {
                    DisplayApplyDialog(items: items, availableSize: proxy.size, onSelect: { id in
                        if picker.takeSelection(id, availableIDs: items.map(\.id), isInLibrary: { $0 == wallpaperID }) != nil {
                            outcome = "选择应用 → \(id.rawValue)"
                        }
                    }, onCancel: { picker.cancel(); outcome = "已取消；未应用" })
                }
            }
        }
    }

    private func updateHover() {
        hoveredID = DisplayTargetHitTesting.target(at: pointer, frames: frames, availableIDs: items.map(\.id))
    }

    private func hover(_ id: DisplayID?) {
        pointer = id.flatMap { frames[$0] }.map { CGPoint(x: $0.midX, y: $0.midY) }
        updateHover()
    }
}
#endif
