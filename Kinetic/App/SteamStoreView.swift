import AppKit
import SwiftUI

private typealias Tokens = MainWindowDesignTokens

/// Kinetic 1.0 Module 14 — Steam Store Browser：主窗口「Steam」页面的内容（标题与排序 / 显示选项由 `ContentHeader` 提供）。
///
/// - 在线搜索只搜 Steam 创意工坊（规格 27：与侧栏的本地搜索完全分开），结果不写入本地资料库。
/// - 卡片与本地网格同一套正方形 Poster、同一个网格；单击选中，双击 = 加入本地资料库（规格 10、11：绝不应用）。
/// - 已在资料库的卡片双击只提示「已在本地资料库」；有更新时双击更新同一条记录。
/// - Module 15：下载完成动画由独立的视觉队列管理；成功 / 失败都不触碰 Runtime。
@MainActor
struct SteamStoreBrowserView: View {
    @ObservedObject var store: SteamStoreService
    @ObservedObject var steam: SteamAcquisitionService
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var downloads: SteamDownloadPresentation
    let options: ContentViewOptions
    @Binding var sortMode: SteamWorkshopSortMode
    /// R4：九组创意工坊筛选；列表、加载更多、搜索与刷新都使用同一完整条件。
    var filters = SteamFilterState()
    let availableWidth: CGFloat
    /// 主内容滚动区域的可见高度（R4 BUG-S1：底部触发点必须真正进入可见区域才请求下一页）。
    var viewportHeight: CGFloat = 0
    let showMessage: (String) -> Void
    var onDisplayDrag: ((SteamStoreItem, URL?, CardDisplayDragEvent) -> Void)? = nil
    /// R4 第 23 节：Steam 页面的多选（稳定的创意工坊编号）。由主窗口持有，与空白框选共用。
    @Binding var selection: StableCardSelection<String>
    /// R4 第 28 节：双击当前多选中的任意一张 = 批量下载全部已选项目。
    var onBatchDownload: (([SteamStoreItem]) -> Void)? = nil
    /// R4 第 24 节：辅助点按菜单（单项 / 批量），由主窗口提供（需要壁纸列表）。
    var onContextMenu: ((SteamStoreItem, NSView) -> NSMenu)? = nil
    /// 两指滑动回到停留过的页时，主窗口把筛选 / 类型换成那一页的条件。
    var onRestoreConditions: ((SteamStoreQuery) -> Void)? = nil

    @State private var searchText = ""
    @State private var posterFrames: [String: CGRect] = [:]
    @State private var historyNavigations = 0
    @StateObject private var swipe = WorkshopSwipeNavigator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let apiKeyPage = URL(string: "https://steamcommunity.com/dev/apikey")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.hasAPIKey {
                TextField("steam.store.search.placeholder", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: Tokens.Grid.maximumCardWidth * 2)
                    .onSubmit {
                        store.update(searchText: searchText)
                        sortMode = store.query.effectiveSortMode
                    }
                    .background { MarqueeExclusionFrame(key: "steamSearch") }
                    .padding(.bottom, Tokens.Spacing.section)
            }
            content
            if store.hasAPIKey {
                WorkshopPagination(page: store.query.numberedPage ?? 1, pageSize: store.query.resultsPerPage,
                    goToPage: store.goToPage, changePageSize: store.setResultsPerPage)
                    .padding(.top, Tokens.Spacing.section)
                    .background { MarqueeExclusionFrame(key: "workshopPagination") }
            }
        }
        // 两指滑动：当前页跟着手指平移，滑出后换成停留过的页。
        .offset(x: swipe.offset)
        .opacity(swipe.isCovered ? 0 : 1)
        .background { WorkshopSwipeArea(navigator: swipe) }
        .onChange(of: swipe.request) { request in
            guard let request else { return }
            switch request.direction {
            case .back: store.goBack()
            case .forward: store.goForward()
            }
            searchText = store.query.searchText
            onRestoreConditions?(store.query)
            historyNavigations += 1
            swipe.didNavigate()
        }
        .background { WorkshopScrollReset(token: "\(store.query.numberedPage ?? 1):\(store.query.resultsPerPage):\(historyNavigations)") }
        .onAppear {
            swipe.canGo = { [store] in $0 == .back ? store.canGoBack : store.canGoForward }
            swipe.reduceMotion = reduceMotion
            searchText = store.query.searchText
            store.update(searchText: searchText, typeFilter: options.typeFilter, filters: filters, sortMode: sortMode, numberedPages: true)
        }
        // Module 59：离开 Steam 页面后卡片不在屏幕上，完成动画不再从旧位置起飞。
        .onDisappear { downloads.updateFrames([:]) }
        .onChange(of: reduceMotion) { swipe.reduceMotion = $0 }
        .onChange(of: options.typeFilter) { store.update(typeFilter: $0) }
        .onChange(of: sortMode) { store.update(sortMode: $0) }
        .onChange(of: store.query.effectiveSortMode) { sortMode = $0 }
        // 改变筛选：复用原有的重新查询与分页重置；旧请求的结果不会覆盖新条件。
        .onChange(of: filters) { store.update(filters: $0) }
        .onChange(of: searchText) { text in
            // 清空搜索框时回到最新发布的壁纸；输入时按回车再搜索，避免每个字都请求一次。
            if text.trimmingCharacters(in: .whitespaces).isEmpty, !store.query.trimmedSearch.isEmpty {
                store.update(searchText: "")
            }
        }
        .onPreferenceChange(SteamPosterFrameKey.self) {
            posterFrames = $0
            downloads.updateFrames($0)
        }
        // 第 36 节：刷新 / 搜索 / 筛选后，选择只保留仍在结果中的编号（不按位置）。
        .onChange(of: store.displayedItems(options: options).map(\.workshopID)) { ids in selection.retain(Set(ids)) }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .needsAPIKey:
            notice(symbol: "key", title: "steam.store.needsKey.title", detail: Text("steam.store.needsKey.detail")) {
                OpenSteamSettingsButton()
                Button("steam.store.getKey") { NSWorkspace.shared.open(Self.apiKeyPage) }.kineticGlassButton()
            }
        case .invalidKey:
            notice(symbol: "key", title: "steam.store.invalidKey.title", detail: Text("steam.store.invalidKey.detail")) {
                OpenSteamSettingsButton()
            }
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: Tokens.Grid.maximumCardWidth)
        case .failed(let reason):
            notice(symbol: "wifi.exclamationmark", title: "steam.store.failed.title", detail: Text(verbatim: reason)) {
                Button("steam.store.retry") { store.reload() }.kineticGlassButton()
            }
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        let items = store.displayedItems(options: options)
        if store.isShowingCachedResults {
            Text("steam.store.offline")
                .font(Tokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .padding(.bottom, Tokens.Spacing.compact)
        }
        if items.isEmpty {
            notice(symbol: "magnifyingglass", title: "steam.store.empty.title", detail: Text("steam.store.empty.detail")) {
                EmptyView()
            }
        } else {
            ResponsiveWallpaperGrid(availableWidth: availableWidth) {
                ForEach(items) { item in
                    SteamStoreCard(
                        item: item,
                        state: state(of: item),
                        isSelected: selection.contains(item.workshopID),
                        posters: store.posters,
                        onSelect: {
                            // 第 15 节：Command + 点按切换，不清除其他；普通点按只选当前。
                            if NSEvent.modifierFlags.contains(.command) { selection.toggle(item.workshopID) }
                            else { selection.selectOnly(item.workshopID) }
                        },
                        onDownload: { url in doubleClicked(item, posterURL: url, among: items) },
                        onDisplayDrag: { url, event in onDisplayDrag?(item, url, event) },
                        onContextMenu: onContextMenu.map { provider in { view in provider(item, view) } }
                    )
                }
            }

        }
    }

    /// 第 28 节：多选中的某一张被双击 → 批量下载当前全部已选项目（不应用、不打开显示器选择）；
    /// 双击未选中的卡片 → 原有单张双击逻辑，不会把旧选择偷偷批量下载。
    private func doubleClicked(_ item: SteamStoreItem, posterURL: URL?, among items: [SteamStoreItem]) {
        if SteamCardMenuPlan.doubleClickDownloadsSelection(selectionCount: selection.count,
                                                          clickedIsSelected: selection.contains(item.workshopID)),
           let onBatchDownload {
            onBatchDownload(items.filter { selection.contains($0.workshopID) })
            return
        }
        download(item, posterURL: posterURL)
    }

    private func state(of item: SteamStoreItem) -> SteamStoreCardState {
        SteamStoreCardState.resolve(item: item, record: library.wallpaper(workshopID: item.workshopID),
                                    task: steam.tasks[item.workshopID])
    }

    /// 双击：加入本地资料库（或更新）；已在资料库只提示。绝不应用。
    private func download(_ item: SteamStoreItem, posterURL: URL?) {
        selection.selectOnly(item.workshopID)
        let current = state(of: item)
        let isUpdate: Bool
        switch current {
        case .inLibrary:
            showMessage(NSLocalizedString("steam.store.inLibrary", comment: ""))
            return
        case .downloading:
            return
        case .updateAvailable:
            isUpdate = true
        case .remote, .failed:
            isUpdate = false
        }
        let frame = posterFrames[item.workshopID] ?? .zero
        let image = SteamDownloadPresentation.snapshot(posterURL: posterURL, type: item.type ?? .web,
                                                      side: max(135, frame.width))
        guard downloads.begin(.init(id: item.workshopID, image: image, frame: frame), reduceMotion: reduceMotion) else { return }
        downloads.register(.init(item: item, posterURL: posterURL))
        Task {
            switch await steam.acquire(item.acquisitionInfo, allowUpdate: isUpdate) {
            case .success:
                downloads.finish(item.workshopID, succeeded: true)
                showMessage(NSLocalizedString(isUpdate ? "steam.store.updated" : "steam.store.added", comment: ""))
            case .failure(.alreadyInLibrary):
                downloads.finish(item.workshopID, succeeded: false)
                showMessage(NSLocalizedString("steam.store.inLibrary", comment: ""))
            case .failure(.alreadyInProgress):
                downloads.finish(item.workshopID, succeeded: false)
                break
            case .failure(let error):
                downloads.finish(item.workshopID, succeeded: false)
                showMessage(error.localizedDescription)
            }
        }
    }

    private func notice<Actions: View>(symbol: String, title: LocalizedStringKey, detail: Text,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: Tokens.Spacing.compact) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Spacing.large, weight: .ultraLight))
                .foregroundStyle(Tokens.accent)
            Text(title)
                .font(Tokens.Typography.emptyTitle)
            detail
                .font(Tokens.Typography.emptyDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: Tokens.Spacing.compact) { actions() }
                .background { MarqueeExclusionFrame(key: "steamNoticeActions") }
                .padding(.top, Tokens.Spacing.small)
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.Grid.maximumCardWidth, alignment: .center)
        .padding(Tokens.Spacing.section)
    }

}

/// Steam 卡片的全局范围（按创意工坊编号），供内容区判断手势起点与框选。
struct SteamCardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// R4 BUG-S1：什么时候请求下一页。触发点进入可见区域（含预取距离）、且状态为 idle 才请求；
/// 正在请求、失败（等待用户重试）或已到末尾都不请求。
enum SteamLoadMoreTrigger {
    /// 距离可见区域底部还有这么多点时就开始请求，滚动时不必等到真正碰底。
    static let prefetchDistance: CGFloat = 320

    static func shouldRequest(footerMinY: CGFloat?, viewportHeight: CGFloat,
                              state: SteamStoreService.LoadMoreState) -> Bool {
        guard state == .idle, let footerMinY, viewportHeight > 0 else { return false }
        return footerMinY <= viewportHeight + prefetchDistance
    }
}

struct SteamLoadMoreFooterKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

/// 网格下方：真实请求进行时显示系统加载指示；失败时显示原因与「重试」；其余时候只占位。
struct SteamLoadMoreFooter: View {
    let state: SteamStoreService.LoadMoreState
    let retry: () -> Void

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("steam.store.loadMore.loading"))
            case .failed(let reason):
                HStack(spacing: Tokens.Spacing.compact) {
                    Text(String(format: NSLocalizedString("steam.store.loadMore.failed", comment: ""), reason))
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("steam.store.retry", action: retry)
                        .kineticGlassButton()
                        .controlSize(.small)
                }
            case .idle, .exhausted:
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .padding(.vertical, Tokens.Spacing.section)
    }
}

/// 打开设置窗口（SwiftUI Settings 场景）。macOS 14 起只能用 `SettingsLink`，与菜单栏的「设置…」相同。
private struct OpenSteamSettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Text("steam.store.openSettings") }
                .kineticGlassButton()
        } else {
            Button("steam.store.openSettings") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .kineticGlassButton()
        }
    }
}

/// 在线商店的一张卡片：与本地卡片同样的正方形 Poster、选中描边与光晕、标题与说明文字。
@MainActor
struct SteamStoreCard: View {
    let item: SteamStoreItem
    let state: SteamStoreCardState
    let isSelected: Bool
    let posters: SteamPosterCache
    let onSelect: () -> Void
    let onDownload: (URL?) -> Void
    var onDisplayDrag: ((URL?, CardDisplayDragEvent) -> Void)? = nil
    /// R4：辅助点按菜单（与本地卡片同一种 Cursor-Anchored 系统菜单）。
    var onContextMenu: ((NSView) -> NSMenu)? = nil

    @State private var posterURL: URL?
    @State private var isDragging = false
    @GestureState private var holdRecognized = false
    @StateObject private var dragCoordinates = WindowDragCoordinates()

    private var emphasis: WallpaperCardVisualState.Emphasis { isSelected ? .selection : .none }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterView(posterURL: posterURL, placeholderType: item.type ?? .web)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: download)
                .onTapGesture(perform: select)
                .overlay { WallpaperCardEmphasisLayer(emphasis: emphasis) }
                .overlay(alignment: .bottomTrailing) { SteamStoreCardBadge(state: state) }
                .background { WallpaperCardGlow(emphasis: emphasis) }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: SteamPosterFrameKey.self,
                                               value: [item.workshopID: proxy.frame(in: .named(DownloadAnimationMetrics.coordinateSpace))])
                    }
                }

            Color.clear
                .frame(height: Tokens.Grid.previewTitleGap)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: download)
                .onTapGesture(perform: select)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(Tokens.Typography.wallpaperTitle)
                    .lineLimit(1)
                    .padding(.bottom, Tokens.Grid.titleMetadataGap)
                Text(Self.metadataText(for: item))
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: download)
            .onTapGesture(perform: select)
        }
        .contentShape(Rectangle())
        .overlay { if let onContextMenu { WallpaperSecondaryClickSurface(menuProvider: onContextMenu) } }
        .background { WindowDragCoordinateProbe(reference: dragCoordinates) }
        .background {
            // R4 BUG-G1：整张卡片（Poster、徽标、标题）都是卡片起点，父级不能从这里开始框选。
            GeometryReader { proxy in
                Color.clear.preference(key: SteamCardFrameKey.self, value: [item.workshopID: proxy.frame(in: .global)])
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: Tokens.LocalDrag.holdDuration)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .updating($holdRecognized) { phase, recognized, _ in
                    if case .second(true, _?) = phase { recognized = true }
                }
                .onChanged { phase in
                    guard let onDisplayDrag, case .second(true, let drag?) = phase else { return }
                    if !isDragging { isDragging = true; onDisplayDrag(posterURL, .began) }
                    if let point = dragCoordinates.windowPoint(forLocalPoint: drag.location) {
                        onDisplayDrag(posterURL, .moved(point))
                    }
                }
                .onEnded { phase in
                    guard isDragging else { return }
                    isDragging = false
                    if case .second(true, let drag?) = phase,
                       let point = dragCoordinates.windowPoint(forLocalPoint: drag.location) {
                        onDisplayDrag?(posterURL, .ended(point))
                    } else { onDisplayDrag?(posterURL, .cancelled) }
                }
        )
        .onChange(of: holdRecognized) { recognized in
            if !recognized, isDragging { isDragging = false; onDisplayDrag?(posterURL, .cancelled) }
        }
        .onDisappear {
            if isDragging { isDragging = false; onDisplayDrag?(posterURL, .cancelled) }
        }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(isSelected ? String(format: NSLocalizedString("steam.card.selected", comment: ""), item.title) : item.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(failureReason ?? "")
        .accessibilityHint(Text(failureReason ?? ""))
        // 卡片出现时读取或下载 Poster；离开屏幕时 SwiftUI 取消这个任务（规格 27：离屏取消网络工作）。
        .task(id: item.previewURL) {
            if let cached = posters.cachedURL(for: item) {
                posterURL = cached
            } else {
                posterURL = await posters.load(item)
            }
        }
    }

    private var failureReason: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }

    private func select() { if !isDragging { onSelect() } }
    private func download() { if !isDragging { onDownload(posterURL) } }

    /// 例如「网页 · 作者名」。
    static func metadataText(for item: SteamStoreItem) -> String {
        let type = item.type?.localizedName ?? NSLocalizedString("steam.store.unknownType", comment: "")
        guard let author = item.authorName, !author.isEmpty else { return type }
        return "\(type) · \(author)"
    }
}

/// 卡片右下角的状态（规格 9）。只读，不接收点击。
struct SteamStoreCardBadge: View {
    let state: SteamStoreCardState

    var body: some View {
        Group {
            switch state {
            case .remote:
                EmptyView()
            case .downloading(let progress):
                SteamDownloadRing(progress: progress)
                .padding(Tokens.Spacing.small)
            case .inLibrary:
                pill("steam.store.badge.inLibrary")
            case .updateAvailable:
                pill("steam.store.badge.update")
            case .failed:
                pill("steam.store.badge.failed")
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func pill(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(Tokens.Typography.badge)
            .padding(.horizontal, Tokens.Spacing.compact)
            .padding(.vertical, Tokens.Spacing.small - 2)
            .kineticGlass(in: Capsule())
            .padding(Tokens.Spacing.small)
    }
}


/// First/last plus the current page's two neighbours in either direction.
enum WorkshopPageEntry: Equatable, Identifiable {
    case page(Int), gap(after: Int)
    var id: String {
        switch self { case .page(let value): return "page-\(value)"; case .gap(let value): return "gap-\(value)" }
    }
    static func entries(current: Int) -> [Self] {
        let current = min(SteamStoreQuery.maximumPage, max(1, current))
        let pages = Set([1, SteamStoreQuery.maximumPage] + Array(max(1, current - 2)...min(SteamStoreQuery.maximumPage, current + 2))).sorted()
        var result: [Self] = []
        for page in pages {
            if case .page(let previous)? = result.last, page - previous > 1 { result.append(.gap(after: previous)) }
            result.append(.page(page))
        }
        return result
    }
}

struct WorkshopPagination: View {
    let page: Int
    let pageSize: Int
    let goToPage: (Int) -> Void
    let changePageSize: (Int) -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text("每页：").foregroundStyle(.secondary)
            Picker("每页数量", selection: Binding(get: { pageSize }, set: changePageSize)) {
                ForEach(SteamStoreQuery.pageSizeChoices, id: \.self) { Text(String($0)).tag($0) }
            }.labelsHidden().fixedSize()
            Button { goToPage(page - 1) } label: { Image(systemName: "arrow.left").frame(width: 18) }
                .kineticGlassButton().disabled(page <= 1).help("上一页").accessibilityLabel("上一页")
            ForEach(WorkshopPageEntry.entries(current: page)) { entry in
                switch entry {
                case .gap: Text("…").foregroundStyle(.secondary)
                case .page(let number):
                    Button { goToPage(number) } label: {
                        Text(String(number)).monospacedDigit().padding(.horizontal, 6).padding(.vertical, 4)
                            .background(number == page ? Color.primary.opacity(0.20) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(number == page)
                    .accessibilityLabel("第\(number)页").accessibilityAddTraits(number == page ? .isSelected : [])
                }
            }
            Button { goToPage(page + 1) } label: { Image(systemName: "arrow.right").frame(width: 18) }
                .kineticGlassButton().disabled(page >= SteamStoreQuery.maximumPage).help("下一页").accessibilityLabel("下一页")
        }.controlSize(.small).fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Scoped to Workshop navigation; the other library pages' scroll behaviour is unchanged.
private struct WorkshopScrollReset: NSViewRepresentable {
    let token: String
    func makeNSView(context: Context) -> ResetView { ResetView() }
    func updateNSView(_ view: ResetView, context: Context) {
        defer { view.token = token }
        guard let old = view.token, old != token else { return }
        DispatchQueue.main.async { [weak view] in
            guard let scroll = view?.enclosingScrollView, let document = scroll.documentView else { return }
            let y = document.isFlipped ? document.bounds.minY : max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    final class ResetView: NSView { var token: String? }
}
