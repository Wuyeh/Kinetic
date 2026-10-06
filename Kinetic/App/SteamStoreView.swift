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
    let availableWidth: CGFloat
    let showMessage: (String) -> Void
    var onDisplayDrag: ((SteamStoreItem, URL?, CardDisplayDragEvent) -> Void)? = nil

    @State private var searchText = ""
    @State private var selectedID: String?
    @State private var posterFrames: [String: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let apiKeyPage = URL(string: "https://steamcommunity.com/dev/apikey")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.hasAPIKey {
                TextField("steam.store.search.placeholder", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: Tokens.Grid.maximumCardWidth * 2)
                    .onSubmit { store.update(searchText: searchText) }
                    .padding(.bottom, Tokens.Spacing.section)
            }
            content
        }
        .onAppear { store.update(searchText: searchText, typeFilter: options.typeFilter) }
        .onChange(of: options.typeFilter) { store.update(typeFilter: $0) }
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
                        isSelected: selectedID == item.workshopID,
                        posters: store.posters,
                        onSelect: { selectedID = item.workshopID },
                        onDownload: { url in download(item, posterURL: url) },
                        onDisplayDrag: { url, event in onDisplayDrag?(item, url, event) }
                    )
                }
            }
            if store.canLoadMore {
                // 滚动到底部时自动加载下一页。
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.Spacing.section)
                    .onAppear { store.loadMore() }
            }
        }
    }

    private func state(of item: SteamStoreItem) -> SteamStoreCardState {
        SteamStoreCardState.resolve(item: item, record: library.wallpaper(workshopID: item.workshopID),
                                    task: steam.tasks[item.workshopID])
    }

    /// 双击：加入本地资料库（或更新）；已在资料库只提示。绝不应用。
    private func download(_ item: SteamStoreItem, posterURL: URL?) {
        selectedID = item.workshopID
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
                .padding(.top, Tokens.Spacing.small)
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.Grid.maximumCardWidth, alignment: .center)
        .padding(Tokens.Spacing.section)
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
        .background { WindowDragCoordinateProbe(reference: dragCoordinates) }
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
        .accessibilityLabel(Text(item.title))
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
