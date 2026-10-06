import SwiftUI

private typealias Tokens = MainWindowDesignTokens

/// Kinetic 1.0 Content Header 修订：内容页面（本地、Steam、喜爱、壁纸列表）顶部共用的页眉。
/// 左侧是较小的淡色页面名称，右侧是圆形「内容选项」按钮；下方一条很淡的分隔线。搜索页面不使用。
struct ContentHeader: View {
    let title: String
    @Binding var options: ContentViewOptions

    var body: some View {
        VStack(spacing: Tokens.Spacing.small) {
            HStack(alignment: .center, spacing: Tokens.Spacing.compact) {
                Text(title)
                    .font(ContentHeaderMetrics.titleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                ContentOptionsButton(options: $options)
            }
            Divider()
                .opacity(ContentHeaderMetrics.separatorOpacity)
        }
    }
}

enum ContentHeaderMetrics {
    static let titleFont = Font.system(size: 15, weight: .semibold)
    static let buttonSize: CGFloat = 30
    static let iconSize: CGFloat = 13
    static let separatorOpacity = 0.45
    static let popoverWidth: CGFloat = 196
}

/// 圆形「内容选项」按钮：三条横线，轻量 Liquid Glass。悬停与展开时图标用 #58BFDA 轻微强调，不做彩色填充。
struct ContentOptionsButton: View {
    @Binding var options: ContentViewOptions
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: ContentHeaderMetrics.iconSize, weight: .semibold))
                .foregroundStyle(isPresented || isHovered ? AnyShapeStyle(Tokens.accent) : AnyShapeStyle(.primary))
                .frame(width: ContentHeaderMetrics.buttonSize, height: ContentHeaderMetrics.buttonSize)
                .contentShape(Circle())
                .kineticGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text("content.options"))
        .accessibilityLabel(Text("content.options"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ContentOptionsPopover(options: $options)
        }
    }
}

/// 锚定在按钮下方的小弹出框：「排序选项」「显示选项」两段，全部纵向排列。
/// macOS 的弹出框本身就是系统材质（macOS 26 起为 Liquid Glass）；勾号用系统前景色。
struct ContentOptionsPopover: View {
    @Binding var options: ContentViewOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("content.section.sort")
            ForEach(ContentSortMode.allCases, id: \.self) { mode in
                ContentOptionRow(titleKey: mode.titleKey, isChecked: options.sortMode == mode) {
                    options.sortMode = mode
                }
            }

            Divider()
                .opacity(ContentHeaderMetrics.separatorOpacity)
                .padding(.vertical, Tokens.Spacing.small)

            sectionTitle("content.section.display")
            ContentOptionRow(titleKey: "content.type.all", isChecked: options.showsAllTypes) {
                options.showAllTypes()
            }
            ForEach(ContentViewOptions.displayedTypes, id: \.self) { type in
                ContentOptionRow(titleKey: "content.type.\(type.rawValue)", isChecked: options.isChecked(type)) {
                    options.toggle(type)
                }
            }
        }
        .padding(Tokens.Spacing.small)
        .frame(width: ContentHeaderMetrics.popoverWidth)
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Tokens.Spacing.small)
            .padding(.top, Tokens.Spacing.micro)
            .padding(.bottom, Tokens.Spacing.micro + 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 一行选项：左侧勾号列 + 名称；悬停时浅灰色高亮，不使用彩色背景。
private struct ContentOptionRow: View {
    let titleKey: String
    let isChecked: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.small) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .opacity(isChecked ? 1 : 0)
                    .frame(width: 14)
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Spacing.small)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}
