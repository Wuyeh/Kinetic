import AppKit
import SwiftUI

private typealias Tokens = MainWindowDesignTokens

// MARK: - Card Visual State

/// 卡片外观状态。只负责边框 / 光晕 / 选中 / 悬停操作 / Active 与 Unsupported 标记，
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
/// 由 `WallpaperPreviewCoordinator` 单独决定。两者都不调用 Desktop Runtime、
/// 不应用壁纸、不改变播放状态。
@MainActor
struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let isSelected: Bool
    let isActive: Bool
    let onSelect: () -> Void
    let onApply: () -> Void

    @State private var isHovered = false
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
            onSelect: onSelect,
            onApply: {
                // 先结束本卡片的预览会话，再走原有 Apply 流程；预览不会升级为桌面播放。
                previewCoordinator.stopAll()
                onApply()
            },
            livePreview: previewCoordinator.preview(for: wallpaper.id),
            onPreviewInterrupted: { previewCoordinator.previewInterrupted($0) }
        )
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                previewCoordinator.hoverBegan(wallpaper)
            } else {
                previewCoordinator.hoverEnded(wallpaper.id)
            }
        }
        .onDisappear {
            isHovered = false
            previewCoordinator.hoverEnded(wallpaper.id)
        }
    }
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
                .background { WallpaperCardGlow(isVisible: visualState.emphasis == .activeGlow) }

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

/// 卡片的预览区域：尺寸由区域自身决定（固定宽高比、圆角、裁切），
/// 内容只填充这个区域，不能改变卡片的宽度、高度或网格位置。
/// 静态缩略图始终在最下层；Live Preview 就绪后才在其上方淡入，失败或离开时直接露出缩略图。
@MainActor
struct WallpaperCardPreview: View {
    let wallpaper: Wallpaper
    var livePreview: WallpaperPreviewCoordinator.ActivePreview? = nil
    var onPreviewInterrupted: (LivePreviewSession) -> Void = { _ in }

    var body: some View {
        Color.clear
            .aspectRatio(Tokens.Grid.previewAspectRatio, contentMode: .fit)
            .overlay { StaticThumbnailView(wallpaper: wallpaper) }
            .overlay {
                if let livePreview {
                    LivePreviewLayer(
                        preview: livePreview,
                        cornerRadius: Tokens.Radius.preview,
                        onInterrupted: onPreviewInterrupted
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.preview, style: .continuous))
    }
}

/// 预览区域的静态内容：导入时生成的缩略图；没有缩略图时显示占位图形。
@MainActor
struct StaticThumbnailView: View {
    let wallpaper: Wallpaper

    var body: some View {
        if let url = wallpaper.thumbnailURL,
           let image = ThumbnailImageCache.shared.image(for: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(systemName: wallpaper.type == .video ? "play.rectangle" : "photo")
                    .font(.system(size: Tokens.Spacing.large, weight: .ultraLight))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 缩略图只从磁盘读取一次；悬停、选中等外观变化不会重复读取文件。
@MainActor
final class ThumbnailImageCache {
    static let shared = ThumbnailImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

// MARK: - Card Overlay

/// Selected 的轻量边框与 Active 的边框；不接收点击。
private struct WallpaperCardEmphasisLayer: View {
    let emphasis: WallpaperCardVisualState.Emphasis

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.preview, style: .continuous)
            .strokeBorder(Tokens.accent.opacity(strokeOpacity), lineWidth: lineWidth)
            .allowsHitTesting(false)
    }

    private var strokeOpacity: Double {
        switch emphasis {
        case .none: return 0
        case .selection: return 0.45
        case .activeGlow: return 0.75
        }
    }

    private var lineWidth: CGFloat { emphasis == .activeGlow ? 2 : 1 }
}

/// Active 的柔和光晕，位于预览区域后方，不影响布局。
private struct WallpaperCardGlow: View {
    let isVisible: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.preview, style: .continuous)
            .fill(Tokens.accent.opacity(isVisible ? 0.35 : 0))
            .shadow(color: Tokens.accent.opacity(isVisible ? 0.45 : 0), radius: Tokens.Spacing.compact)
            .allowsHitTesting(false)
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
            Button(action: onApply) {
                pill("shell.tile.apply", font: Tokens.Typography.metadata)
                    .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.small, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(Tokens.Spacing.small)
            .transition(.opacity)
        case .activeBadge:
            pill("shell.tile.active", font: Tokens.Typography.badge)
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

    private func pill(_ key: LocalizedStringKey, font: Font) -> some View {
        Text(key)
            .font(font)
            .padding(.horizontal, Tokens.Spacing.compact)
            .padding(.vertical, Tokens.Spacing.small)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.small, style: .continuous))
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
