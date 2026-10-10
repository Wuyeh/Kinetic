import AppKit
import SwiftUI

private typealias Tokens = MainWindowDesignTokens

/// Kinetic 1.0 Content Header 修订：内容页面（本地、Steam、喜爱、壁纸列表）顶部共用的页眉。
/// 左侧是较小的淡色页面名称，右侧是圆形「内容选项」按钮；下方一条很淡的分隔线。搜索页面不使用。
struct ContentHeader: View {
    let title: String
    @Binding var options: ContentViewOptions
    /// R4 第 44–49 节：只有 Steam 在线页面传入，扩展同一个弹出框的「显示选项」。
    var steamFilters: Binding<SteamFilterState>? = nil
    var steamExpandedGroups: Binding<Set<SteamTagGroup>>? = nil
    var steamSortMode: Binding<SteamWorkshopSortMode> = .constant(.recentlyPublished)
    /// 内容区可用高度（弹出框高度不超过它的约 70%）。
    var availableHeight: CGFloat = 0
    /// Module 46：壁纸列表页面多一项「列表顺序」。
    var showsListOrder = false

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
                ContentOptionsButton(options: $options, steamFilters: steamFilters,
                                     steamExpandedGroups: steamExpandedGroups, steamSortMode: steamSortMode,
                                     availableHeight: availableHeight, showsListOrder: showsListOrder)
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
    var steamFilters: Binding<SteamFilterState>? = nil
    var steamExpandedGroups: Binding<Set<SteamTagGroup>>? = nil
    var steamSortMode: Binding<SteamWorkshopSortMode> = .constant(.recentlyPublished)
    var availableHeight: CGFloat = 0
    var showsListOrder = false
    @State private var isPresented = false
    @State private var isHovered = false
    @State private var measuredWorkshopHeight: CGFloat?

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
        .background {
            if steamFilters != nil {
                WorkshopFilterAnchor { measuredWorkshopHeight = $0 }
            }
        }
        .help(Text("content.options"))
        .accessibilityLabel(Text("content.options"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ContentOptionsPopover(options: $options, steamFilters: steamFilters,
                                  steamExpandedGroups: steamExpandedGroups, steamSortMode: steamSortMode,
                                  availableHeight: availableHeight, measuredWorkshopHeight: measuredWorkshopHeight,
                                  showsListOrder: showsListOrder)
        }
    }
}

/// 锚定在按钮下方的小弹出框：「排序选项」「显示选项」两段，全部纵向排列。
/// macOS 的弹出框本身就是系统材质（macOS 26 起为 Liquid Glass）；勾号用系统前景色。
struct ContentOptionsPopover: View {
    @Binding var options: ContentViewOptions
    var steamFilters: Binding<SteamFilterState>? = nil
    var steamExpandedGroups: Binding<Set<SteamTagGroup>>? = nil
    var steamSortMode: Binding<SteamWorkshopSortMode> = .constant(.recentlyPublished)
    var availableHeight: CGFloat = 0
    var measuredWorkshopHeight: CGFloat? = nil
    var showsListOrder = false
    @State private var fixedContentHeight = SteamFilterPopoverMetrics.fixedHeight - 2 * Tokens.Spacing.small

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
            sectionTitle("content.section.sort")
            if steamFilters != nil {
                ForEach(SteamWorkshopSortMode.allCases, id: \.self) { mode in
                    ContentOptionRow(titleKey: mode.titleKey, isChecked: steamSortMode.wrappedValue == mode) {
                        steamSortMode.wrappedValue = mode
                    }
                }
            } else {
                ForEach(ContentSortMode.available(inSteamStore: false, inList: showsListOrder), id: \.self) { mode in
                    ContentOptionRow(titleKey: mode.titleKey, isChecked: options.sortMode == mode) {
                        options.sortMode = mode
                    }
                }
            }

            Divider()
                .opacity(ContentHeaderMetrics.separatorOpacity)
                .padding(.vertical, Tokens.Spacing.small)

            sectionTitle("content.section.display")
            }
            .background {
                if steamFilters != nil {
                    GeometryReader { proxy in Color.clear.preference(key: WorkshopFilterHeadingHeight.self, value: proxy.size.height) }
                }
            }
            if let steamFilters, let steamExpandedGroups {
                // R4：Steam 页的九组筛选放进一个有高度上限的滚动区域；宽度不变。
                BoundedScrollView(maxHeight: max(1, SteamFilterPopoverMetrics.totalHeightLimit(availableHeight: availableHeight, measuredHeight: measuredWorkshopHeight) - fixedContentHeight - 2 * Tokens.Spacing.small), fillsHeight: true) {
                    SteamFilterGroupsView(filters: steamFilters, expanded: steamExpandedGroups)
                }
            } else {
                ContentOptionRow(titleKey: "content.type.all", isChecked: options.showsAllTypes) {
                    options.showAllTypes()
                }
                ForEach(ContentViewOptions.displayedTypes, id: \.self) { type in
                    ContentOptionRow(titleKey: "content.type.\(type.rawValue)", isChecked: options.isChecked(type)) {
                        options.toggle(type)
                    }
                }
            }
        }
        .padding(Tokens.Spacing.small)
        .frame(width: ContentHeaderMetrics.popoverWidth)
        .onPreferenceChange(WorkshopFilterHeadingHeight.self) { if $0 > 0 { fixedContentHeight = $0 } }
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

/// 一行选项：左侧勾号列 + 名称；悬停时浅灰色高亮，不使用彩色背景。显示器页的叠加层菜单也用它。
struct ContentOptionRow: View {
    let titleKey: String
    let isChecked: Bool
    var verbatimTitle: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    init(titleKey: String, isChecked: Bool, action: @escaping () -> Void) {
        self.titleKey = titleKey
        self.isChecked = isChecked
        self.action = action
    }

    /// R4：创意工坊标签行（中文显示名；过长时截断并提供完整 Tooltip）。
    init(title: String, isChecked: Bool, action: @escaping () -> Void) {
        self.titleKey = ""
        self.verbatimTitle = title
        self.isChecked = isChecked
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.small) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .opacity(isChecked ? 1 : 0)
                    .frame(width: 14)
                Group {
                    if let verbatimTitle { Text(verbatim: verbatimTitle).help(verbatimTitle) }
                    else { Text(LocalizedStringKey(titleKey)) }
                }
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
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

// MARK: - R4 Steam 筛选组

enum SteamFilterPopoverMetrics {
    static let targetHeight: CGFloat = 440 // Only for a detached preview without a host window.
    static let fixedHeight: CGFloat = 238
    static let minimumScrollHeight: CGFloat = 120
    static let arrowHeight: CGFloat = 12

    /// From the header button's lower edge to Floating Toolbar's lower edge.
    static func totalHeightLimit(availableHeight: CGFloat, measuredHeight: CGFloat? = nil) -> CGFloat {
        if let measuredHeight { return max(fixedHeight + 1, measuredHeight) }
        guard availableHeight > 0 else { return targetHeight }
        return max(fixedHeight + 1, availableHeight - ContentHeaderMetrics.buttonSize
                   - arrowHeight - MainWindowDesignTokens.FloatingToolbar.bottomInset)
    }
    static func scrollHeightLimit(availableHeight: CGFloat, measuredHeight: CGFloat? = nil) -> CGFloat {
        max(1, totalHeightLimit(availableHeight: availableHeight, measuredHeight: measuredHeight) - fixedHeight)
    }
}

/// Measures only this button in its own window; no screen capture or app control.
private struct WorkshopFilterAnchor: NSViewRepresentable {
    let measured: (CGFloat) -> Void
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.measured = measured; view.refresh() }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.detach() }
    final class AnchorView: NSView {
        var measured: ((CGFloat) -> Void)?
        private var observer: NSObjectProtocol?
        private var lastHeight: CGFloat?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); detach()
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
                    [weak self] _ in self?.refresh()
                }
            }
            refresh()
        }
        override func layout() { super.layout(); refresh() }
        func refresh() {
            guard let window, bounds.height > 0 else { return }
            let anchorBottom = convert(bounds, to: nil).minY
            let height = anchorBottom - window.contentLayoutRect.minY
                - MainWindowDesignTokens.FloatingToolbar.bottomInset - SteamFilterPopoverMetrics.arrowHeight
            guard height.isFinite, height > 0, lastHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }
            lastHeight = height
            DispatchQueue.main.async { [weak self] in self?.measured?(height) }
        }
        func detach() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
        deinit { detach() }
    }
}

/// 有高度上限的滚动区域：内容较少时自然缩短，超出上限时滚动（只在需要滚动时显示系统滚动指示）。
struct BoundedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    var fillsHeight = false
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: BoundedContentHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .scrollIndicators(contentHeight > maxHeight ? .automatic : .hidden)
        .frame(height: fillsHeight ? maxHeight : min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(BoundedContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct BoundedContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 九组筛选：紧凑的展开 / 收起标题行（系统 Chevron，无大块背景），展开后是与原菜单相同的文本行与勾号。
/// 展开 / 收起不改变条件、不刷新结果、不关闭弹出框；收起时以一行弱强调摘要提示已有条件。
struct SteamFilterGroupsView: View {
    @Binding var filters: SteamFilterState
    @Binding var expanded: Set<SteamTagGroup>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SteamTagGroup.allCases) { group in
                SteamFilterGroupHeader(group: group, isExpanded: expanded.contains(group),
                                       summary: filters.summary(for: group)) {
                    if !expanded.insert(group).inserted { expanded.remove(group) }
                }
                if expanded.contains(group) {
                    ContentOptionRow(titleKey: group == .type ? "content.type.all" : "steam.filter.all",
                                     isChecked: !filters.hasSelection(in: group)) {
                        filters.clear(group)
                    }
                    ForEach(group.tags) { tag in
                        ContentOptionRow(title: tag.label, isChecked: filters.isSelected(tag.value, in: group)) {
                            filters.select(tag.value, in: group)
                        }
                        .accessibilityLabel(Text(tag.label))
                    }
                }
            }
        }
    }
}

private struct SteamFilterGroupHeader: View {
    let group: SteamTagGroup
    let isExpanded: Bool
    let summary: String?
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Tokens.Spacing.small) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14)
                Text(group.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize()
                if let summary, !isExpanded {
                    Text(verbatim: summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.accent.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(summary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Spacing.small)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(summary.map { "\(group.title)，\($0)" } ?? group.title))
        .accessibilityValue(Text(isExpanded ? "steam.filter.expanded" : "steam.filter.collapsed"))
        .accessibilityAddTraits(.isHeader)
    }
}

private struct WorkshopFilterHeadingHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
