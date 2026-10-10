import AppKit
import SwiftUI
import SystemConfiguration

private typealias Tokens = MainWindowDesignTokens

/// R4 第 11 节：Display Bubble 的一行（显示器名称、当前壁纸 / 播放状态、是否为受控显示器）。
struct FloatingBarDisplayRow: Identifiable, Equatable {
    let id: DisplayID
    let name: String
    let detail: String
    let isControlled: Bool

    init(id: DisplayID, name: String, detail: String, isControlled: Bool) {
        self.id = id
        self.name = name
        self.detail = detail
        self.isControlled = isControlled
    }

    init(item: DisplayTargetItem, state: WallpaperRuntimeState, isControlled: Bool) {
        id = item.id
        name = item.name
        let status = FloatingBarDisplayRow.statusText(state.playbackState)
        detail = item.wallpaperName.map { "\($0) · \(status)" } ?? status
        self.isControlled = isControlled
    }

    static func statusText(_ state: PlaybackState) -> String {
        NSLocalizedString("floatingBar.status.\(state.rawValue)", comment: "")
    }
}

/// 从 Floating Bar 的显示器图标上方弹出（系统 Popover：Liquid Glass、大圆角、指向图标的箭头）。
/// 只选择 Floating Bar 控制哪一台显示器，不更换壁纸、不改变显示器分配。
struct FloatingBarDisplayBubble: View {
    /// 系统设置中的电脑名称（例如「Wu 的 MacBook Pro」）；不做网络查询。
    static let computerName: String? = SCDynamicStoreCopyComputerName(nil, nil) as String?

    let hostName: String
    let status: String
    let rows: [FloatingBarDisplayRow]
    let onSelect: (DisplayID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hostName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, Tokens.Spacing.small)
            .padding(.bottom, Tokens.Spacing.small)
            .accessibilityElement(children: .combine)

            Divider().opacity(0.6)
                .padding(.bottom, Tokens.Spacing.micro)

            ForEach(rows) { row in
                FloatingBarDisplayRowButton(row: row) { onSelect(row.id) }
            }
        }
        .padding(Tokens.Spacing.compact)
        .frame(width: 270)
    }
}

private struct FloatingBarDisplayRowButton: View {
    let row: FloatingBarDisplayRow
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.small) {
                // 规格：勾号只用系统黑 / 白 / 灰，不用绿色。
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .opacity(row.isControlled ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(row.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Spacing.small)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(row.isControlled ? .isSelected : [])
        .accessibilityLabel(Text("\(row.name)，\(row.detail)"))
    }
}

/// R4 第 54 节：Floating Bar 背景不透明度 × 1.5（只调背景，不动图标）。
///
/// 背景是系统 Liquid Glass 的 clear 变体（macOS 26 前为 ultraThinMaterial），没有可直接设置的 alpha。
/// 按规格用一层系统窗口底色作等效调整：玻璃本身的等效不透明度 alphaOld 是估计值（无法从系统读取），
/// 叠加不透明度为 f 的底色后合成 1 − (1 − alphaOld)(1 − f) = alphaNew = min(1, alphaOld × 1.5)。
enum FloatingBarBackground {
    /// 修改前 clear 玻璃的等效背景不透明度（估计值，见 DECISIONS / QA 记录）。
    static let estimatedGlassOpacity: Double = 0.30
    static let multiplier: Double = 1.5

    static var targetOpacity: Double { min(1, estimatedGlassOpacity * multiplier) }

    /// 叠在玻璃上的底色不透明度：使合成后的背景不透明度等于 targetOpacity。只计算一次，不随显示累乘。
    static var fillOpacity: Double {
        guard estimatedGlassOpacity < 1 else { return 0 }
        return (targetOpacity - estimatedGlassOpacity) / (1 - estimatedGlassOpacity)
    }
}
