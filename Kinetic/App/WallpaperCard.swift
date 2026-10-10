import AppKit
import SwiftUI

private typealias Tokens = MainWindowDesignTokens

// MARK: - Card Visual State

/// Module 11：卡片外观状态。只负责边框 / 光晕 / 选中 / 悬停操作 / Active 与 Unsupported 标记，
/// 不描述预览区域显示什么内容，也不触发任何 Runtime 操作。
struct WallpaperCardVisualState: Equatable {
    var isActive: Bool
    var isSelected: Bool
    var isHovered: Bool
    var isPlayable: Bool

    /// 预览区域外圈的强调效果。
    enum Emphasis: Equatable {
        case none
        case selection
        case activeGlow
    }

    /// 预览区域右下角的附件。
    enum Accessory: Equatable {
        case none
        case applyButton
        case activeBadge
        case unsupportedBadge
    }

    /// Active > Selected > Normal。Active + Selected 只显示 Active 光晕，不叠加两层边框。
    /// 悬停不改变强调效果，只影响右下角附件。
    var emphasis: Emphasis {
        if isActive { return .activeGlow }
        if isSelected { return .selection }
        return .none
    }

    /// 「使用中」始终优先；悬停时可播放显示「应用」，不可播放只显示「暂不支持」。
    var accessory: Accessory {
        if isActive { return .activeBadge }
        guard isHovered else { return .none }
        return isPlayable ? .applyButton : .unsupportedBadge
    }

    /// 双击与「应用」按钮是否可以请求应用；Unsupported 内容永远不可应用。
    var canApply: Bool { isPlayable }

    /// 当前版本能否播放这张壁纸。卡片外观与预览区域都以此识别 Unsupported。
    @MainActor
    static func isPlayable(_ wallpaper: Wallpaper) -> Bool {
        wallpaper.supportState == .supported &&
            WallpaperRuntimeManager.isRendererAvailable(for: wallpaper.type)
    }
}

// MARK: - Card

/// 资料库中的一张壁纸卡片：Preview Area、名称、Metadata。
/// 悬停只是界面交互：卡片外观立即进入 Hover；是否以及何时在预览区域内播放 Live Preview
/// 由 `WallpaperPreviewCoordinator` 单独决定（Module 11.1）。两者都不调用 Desktop Runtime、
/// 不应用壁纸、不改变播放状态。
@MainActor
struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let isSelected: Bool
    let isActive: Bool
    let onSelect: () -> Void
    let onApply: () -> Void
    let onContextMenu: (NSView) -> NSMenu
    /// 长按后拖向窗口顶部的显示器目标；与单击、双击及「应用」按钮并存。
    var onDisplayDrag: ((CardDisplayDragEvent) -> Void)? = nil

    @State private var isHovered = false
    @State private var isDragging = false
    @GestureState private var holdRecognized = false
    @StateObject private var dragCoordinates = WindowDragCoordinates()
    @ObservedObject private var previewCoordinator = WallpaperPreviewCoordinator.shared

    var body: some View {
        WallpaperCardContent(
            wallpaper: wallpaper,
            visualState: WallpaperCardVisualState(
                isActive: isActive,
                isSelected: isSelected,
                isHovered: isHovered,
                isPlayable: WallpaperCardVisualState.isPlayable(wallpaper)
            ),
            onSelect: { if !isDragging { onSelect() } },
            onApply: {
                guard !isDragging else { return }
                // 先结束本卡片的预览会话，再走原有 Apply 流程；预览不会升级为桌面播放。
                previewCoordinator.stopAll()
                onApply()
            },
            livePreview: previewCoordinator.preview(for: wallpaper.id),
            onPreviewInterrupted: { previewCoordinator.previewInterrupted($0) }
        )
        .background { WindowDragCoordinateProbe(reference: dragCoordinates) }
        .overlay { WallpaperSecondaryClickSurface(menuProvider: onContextMenu) }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: Tokens.LocalDrag.holdDuration)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .updating($holdRecognized) { phase, recognized, _ in
                    if case .second(true, _?) = phase { recognized = true }
                }
                .onChanged { phase in
                    guard let onDisplayDrag else { return }
                    if case .second(true, let drag?) = phase {
                        if !isDragging {
                            isDragging = true
                            previewCoordinator.stopAll()
                            onDisplayDrag(.began)
                        }
                        if let point = dragCoordinates.windowPoint(forLocalPoint: drag.location) {
                            onDisplayDrag(.moved(point))
                        }
                    }
                }
                .onEnded { phase in
                    guard isDragging, let onDisplayDrag else { return }
                    isDragging = false
                    if case .second(true, let drag?) = phase,
                       let point = dragCoordinates.windowPoint(forLocalPoint: drag.location) {
                        onDisplayDrag(.ended(point))
                    } else {
                        onDisplayDrag(.cancelled)
                    }
                }
        )
        .onChange(of: holdRecognized) { recognized in
            // 手势被系统取消时 onEnded 不保证执行；不能留下目标条或旧 Hover。
            if !recognized, isDragging {
                isDragging = false
                onDisplayDrag?(.cancelled)
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering, !isDragging {
                previewCoordinator.hoverBegan(wallpaper)
            } else {
                previewCoordinator.hoverEnded(wallpaper.id)
            }
        }
        .onDisappear {
            if isDragging { isDragging = false; onDisplayDrag?(.cancelled) }
            isHovered = false
            previewCoordinator.hoverEnded(wallpaper.id)
        }
    }
}

enum CardDisplayDragEvent {
    case began
    case moved(CGPoint)
    case ended(CGPoint)
    case cancelled
}

/// 辅助点按在鼠标原位弹出系统菜单；普通鼠标移动、单击、双击和按钮点击交给 SwiftUI 卡片。
/// R4：Steam 在线卡片也使用同一个菜单入口。
struct WallpaperSecondaryClickSurface: NSViewRepresentable {
    let menuProvider: (NSView) -> NSMenu

    func makeNSView(context: Context) -> SecondaryClickView { SecondaryClickView() }

    func updateNSView(_ nsView: SecondaryClickView, context: Context) {
        nsView.menuProvider = menuProvider
    }

    final class SecondaryClickView: NSView {
        var menuProvider: ((NSView) -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = menuProvider?(self) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

/// NSMenuItem 自己持有操作，避免右键菜单关闭前动作目标被释放。
final class WallpaperMenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func performAction() { handler() }
}

/// 无内部状态的卡片布局：外观完全由 visualState 决定，便于逐状态验证。
@MainActor
struct WallpaperCardContent: View {
    let wallpaper: Wallpaper
    let visualState: WallpaperCardVisualState
    let onSelect: () -> Void
    let onApply: () -> Void
    /// Preview Content State：只影响预览区域内部显示的内容，不影响卡片外观状态。
    var livePreview: WallpaperPreviewCoordinator.ActivePreview? = nil
    var onPreviewInterrupted: (LivePreviewSession) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 预览内容层在下，卡片 Overlay 在上；替换预览内容不会影响 Overlay。
            WallpaperCardPreview(wallpaper: wallpaper, livePreview: livePreview, onPreviewInterrupted: onPreviewInterrupted)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: applyIfAllowed)
                .onTapGesture(perform: onSelect)
                .overlay { WallpaperCardEmphasisLayer(emphasis: visualState.emphasis) }
                .overlay(alignment: .bottomTrailing) {
                    WallpaperCardAccessoryView(accessory: visualState.accessory, onApply: applyIfAllowed)
                }
                .background { WallpaperCardGlow(emphasis: visualState.emphasis) }

            // 预览与文字之间的间隙沿用卡片的单击 / 双击行为。
            Color.clear
                .frame(height: Tokens.Grid.previewTitleGap)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: applyIfAllowed)
                .onTapGesture(perform: onSelect)

            WallpaperCardCaption(wallpaper: wallpaper)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: applyIfAllowed)
                .onTapGesture(perform: onSelect)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: visualState)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(wallpaper.name)
        .accessibilityValue(accessibilityStateDescription)
        .accessibilityAddTraits(visualState.isSelected ? .isSelected : [])
    }

    private func applyIfAllowed() {
        if visualState.canApply { onApply() }
    }

    private var accessibilityStateDescription: String {
        var parts: [String] = []
        if visualState.isActive { parts.append(NSLocalizedString("shell.tile.active", comment: "")) }
        if visualState.isSelected { parts.append(NSLocalizedString("shell.tile.selected", comment: "")) }
        if !visualState.isPlayable { parts.append(NSLocalizedString("shell.tile.unsupported", comment: "")) }
        return parts.joined(separator: "，")
    }
}

// MARK: - Preview Area

/// 卡片的预览区域：1.0 Module 11 起是 1:1 连续圆角正方形 Poster（`PosterView`）。尺寸只由宽度决定，
/// 内容只填充这个区域，不能改变卡片的宽度、高度或网格位置。
/// Poster 始终在最下层；Live Preview 就绪后才在其上方淡入（保持原比例，四周露出 Poster 的模糊背景），
/// 失败或离开时直接露出 Poster。
@MainActor
struct WallpaperCardPreview: View {
    let wallpaper: Wallpaper
    var livePreview: WallpaperPreviewCoordinator.ActivePreview? = nil
    var onPreviewInterrupted: (LivePreviewSession) -> Void = { _ in }

    var body: some View {
        Color.clear
            .aspectRatio(PosterGeometry.aspectRatio, contentMode: .fit)
            .overlay { PosterArtworkView(wallpaper: wallpaper) }
            .overlay {
                if let livePreview {
                    GeometryReader { proxy in
                        LivePreviewLayer(
                            preview: livePreview,
                            cornerRadius: PosterGeometry.cornerRadius(forSide: proxy.size.width),
                            onInterrupted: onPreviewInterrupted
                        )
                    }
                }
            }
            .clipShape(PosterShape())
    }
}

// MARK: - Card Overlay

/// Selected 的轻量边框与 Active 的边框；不接收点击。
struct WallpaperCardEmphasisLayer: View {
    let emphasis: WallpaperCardVisualState.Emphasis

    var body: some View {
        PosterShape()
            .strokeBorder(Tokens.accent.opacity(strokeOpacity), lineWidth: lineWidth)
            .allowsHitTesting(false)
    }

    private var strokeOpacity: Double {
        switch emphasis {
        case .none: return 0
        case .selection: return 0.8
        case .activeGlow: return 0.75
        }
    }

    private var lineWidth: CGFloat {
        switch emphasis {
        case .none: return 1
        case .selection: return 3.75
        case .activeGlow: return 2
        }
    }
}

/// 选中与运行中的柔和光晕，位于预览区域后方，不影响布局；运行态仍优先。
struct WallpaperCardGlow: View {
    let emphasis: WallpaperCardVisualState.Emphasis

    var body: some View {
        PosterShape()
            .fill(Tokens.accent.opacity(fillOpacity))
            .shadow(color: Tokens.accent.opacity(shadowOpacity), radius: Tokens.Spacing.compact)
            .allowsHitTesting(false)
    }

    private var fillOpacity: Double {
        switch emphasis {
        case .none: return 0
        case .selection: return 0.24
        case .activeGlow: return 0.35
        }
    }

    private var shadowOpacity: Double {
        switch emphasis {
        case .none: return 0
        case .selection: return 0.38
        case .activeGlow: return 0.45
        }
    }
}

/// 右下角附件：「应用」是独立按钮，不等待卡片的双击判定；只读徽标把点击交给卡片。
private struct WallpaperCardAccessoryView: View {
    let accessory: WallpaperCardVisualState.Accessory
    let onApply: () -> Void

    var body: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .applyButton:
            // 规格：「应用」是 Liquid Glass 按钮，尺寸适中。普通无色玻璃（用户要求，见 `kineticGlassButton`）。
            Button(action: onApply) {
                Text("shell.tile.apply")
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(.primary)
            }
            .kineticGlassButton()
            .controlSize(.small)
            .padding(Tokens.Spacing.small)
            .transition(.opacity)
        case .activeBadge:
            pill("shell.tile.active", font: Tokens.Typography.badge, tint: Tokens.accent.opacity(0.35))
                .padding(Tokens.Spacing.small)
                .allowsHitTesting(false)
        case .unsupportedBadge:
            pill("shell.tile.unsupported", font: Tokens.Typography.badge)
                .foregroundStyle(.secondary)
                .padding(Tokens.Spacing.small)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func pill(_ key: LocalizedStringKey, font: Font, tint: Color? = nil) -> some View {
        Text(key)
            .font(font)
            .padding(.horizontal, Tokens.Spacing.compact)
            .padding(.vertical, Tokens.Spacing.small - 2)
            .kineticGlass(in: Capsule(), tint: tint)
    }
}

// MARK: - Caption

/// 名称与「类型 · 来源」。
struct WallpaperCardCaption: View {
    let wallpaper: Wallpaper

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(wallpaper.name)
                .font(Tokens.Typography.wallpaperTitle)
                .lineLimit(1)
                .padding(.bottom, Tokens.Grid.titleMetadataGap)
            Text(Self.metadataText(for: wallpaper))
                .font(Tokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 例如「网页 · Steam」。卡片上的来源使用简短名称。
    static func metadataText(for wallpaper: Wallpaper) -> String {
        let source = NSLocalizedString("shell.tile.source.\(wallpaper.source.rawValue)", comment: "Short wallpaper source")
        return "\(wallpaper.type.localizedName) · \(source)"
    }
}
