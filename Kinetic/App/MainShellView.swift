import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 产品主窗口。只使用资料库、导入服务和 Runtime 的公开接口。
@MainActor
struct MainShellView: View {
    let appDelegate: AppDelegate
    @State private var services: ShellServices?
    @State private var connectionFailed = false

    var body: some View {
        Group {
            if let services {
                LibraryShellView(
                    library: services.library,
                    runtime: services.runtime,
                    importer: services.importer
                )
            } else if connectionFailed {
                Text("shell.error.unavailable")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .task {
            // SwiftUI may create the scene before applicationDidFinishLaunching builds the services.
            for _ in 0..<40 {
                connectServices()
                if services != nil { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            connectionFailed = true
        }
    }

    private func connectServices() {
        guard let library = appDelegate.library,
              let runtime = appDelegate.runtimeManager,
              let importer = appDelegate.importService else { return }
        services = ShellServices(library: library, runtime: runtime, importer: importer)
    }
}

@MainActor
private struct ShellServices {
    let library: WallpaperLibrary
    let runtime: WallpaperRuntimeManager
    let importer: LocalImportService
}

private enum ShellSection: Hashable {
    case search, favorites, all, local, steam

    var title: String {
        let key: String
        switch self {
        case .search: key = "shell.search"
        case .favorites: key = "shell.favorites"
        case .all: key = "shell.all"
        case .local: key = "shell.local"
        case .steam: key = "shell.steam"
        }
        return NSLocalizedString(key, comment: "Main window section")
    }

    var sidebarTitle: String {
        self == .steam
            ? NSLocalizedString("shell.sidebar.steam", comment: "Short Steam sidebar label")
            : title
    }

    var symbol: String? {
        switch self {
        case .search: return "magnifyingglass"
        case .favorites: return "heart"
        case .all: return "square.grid.2x2"
        case .local: return "house"
        // Steam 使用正式图形资源时再绘制；不以相似 SF Symbol 冒充品牌标志。
        case .steam: return nil
        }
    }

    var filter: LibraryFilter {
        switch self {
        case .favorites: return .favorites
        case .local: return .local
        case .steam: return .steam
        case .search, .all: return .all
        }
    }
}

private typealias Tokens = MainWindowDesignTokens

/// 只决定卡片的 Active 外观，不改变 Runtime 的真实 Active 或播放状态。
struct WallpaperCardPresentation {
    private(set) var targetWallpaperID: Wallpaper.ID?

    func displayedActiveWallpaperID(in state: WallpaperRuntimeState) -> Wallpaper.ID? {
        targetWallpaperID ?? state.activeWallpaperID
    }

    mutating func beginApply(_ id: Wallpaper.ID) {
        targetWallpaperID = id
    }

    mutating func synchronize(with state: WallpaperRuntimeState) {
        // 准备成功、失败、停止或请求未被接纳后，重新以 Runtime 实际状态为准。
        // 较早候选的迟到回调由既有 Runtime 忽略，不会覆盖最新的 UI Target。
        if state.preparingWallpaperID != targetWallpaperID {
            targetWallpaperID = nil
        }
    }
}

@MainActor
private struct LibraryShellView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var runtime: WallpaperRuntimeManager
    let importer: LocalImportService

    @State private var section: ShellSection = .all
    @State private var selectedID: Wallpaper.ID?
    @State private var cardPresentation = WallpaperCardPresentation()
    @State private var query = ""
    @State private var importing = false
    @State private var message: String?
    @State private var stopHovered = false
    @FocusState private var searchFocused: Bool

    private var visibleWallpapers: [Wallpaper] {
        section == .search ? library.search(query) : library.wallpapers(in: section.filter)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: Tokens.Sidebar.minimumWidth,
                    ideal: Tokens.Sidebar.defaultWidth,
                    max: Tokens.Sidebar.maximumWidth
                )
        } detail: {
            mainArea
                .frame(minWidth: Tokens.Window.minimumWidth - Tokens.Sidebar.maximumWidth)
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: Tokens.Window.minimumWidth, minHeight: Tokens.Window.minimumHeight)
        .tint(Tokens.accent)
        .onChange(of: runtime.state) { _ in
            cardPresentation.synchronize(with: runtime.state)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionButton(.search)
            sectionButton(.favorites)

            Text("shell.sidebar.library")
                .font(Tokens.Typography.sidebarSection)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, Tokens.Sidebar.horizontalInset + Tokens.Sidebar.itemHorizontalInset)
                .padding(.top, Tokens.Sidebar.sectionTopInset)
                .padding(.bottom, Tokens.Spacing.small)

            sectionButton(.all)
            sectionButton(.local)
            sectionButton(.steam)

            Spacer(minLength: Tokens.Spacing.section)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Tokens.Sidebar.topInset)
        .background(.regularMaterial)
    }

    private func sectionButton(_ item: ShellSection) -> some View {
        Button {
            section = item
            if item == .search { searchFocused = true }
        } label: {
            HStack(spacing: Tokens.Sidebar.iconTextGap) {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: Tokens.Sidebar.iconSize, weight: .regular))
                        .foregroundStyle(Tokens.accent)
                        .frame(width: Tokens.Sidebar.iconSlotWidth)
                } else {
                    Color.clear.frame(width: Tokens.Sidebar.iconSlotWidth, height: Tokens.Sidebar.iconSize)
                }
                Text(item.sidebarTitle)
                    .font(section == item ? Tokens.Typography.sidebarSelectedItem : Tokens.Typography.sidebarItem)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Sidebar.itemHorizontalInset)
            .frame(height: Tokens.Sidebar.rowHeight)
            .background {
                if section == item {
                    RoundedRectangle(cornerRadius: Tokens.Radius.medium, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Tokens.Sidebar.horizontalInset)
        .padding(.vertical, Tokens.Spacing.micro / 2)
    }

    private var mainArea: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { contentGeometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(section.title)
                            .font(Tokens.Typography.pageTitle)
                            .padding(.bottom, Tokens.Content.titleBottomGap)

                        if section == .search {
                            TextField("shell.search.placeholder", text: $query)
                                .textFieldStyle(.roundedBorder)
                                .focused($searchFocused)
                                .frame(maxWidth: Tokens.Grid.maximumCardWidth * 2)
                                .padding(.bottom, Tokens.Spacing.section)
                        }

                        if visibleWallpapers.isEmpty {
                            emptyState
                        } else {
                            ResponsiveWallpaperGrid(
                                availableWidth: max(0, contentGeometry.size.width - 2 * Tokens.Content.horizontalInset)
                            ) {
                                ForEach(visibleWallpapers) { wallpaper in
                                    WallpaperCard(
                                        wallpaper: wallpaper,
                                        isSelected: selectedID == wallpaper.id,
                                        isActive: cardPresentation.displayedActiveWallpaperID(in: runtime.state) == wallpaper.id,
                                        onSelect: { selectedID = wallpaper.id },
                                        onApply: { apply(wallpaper) }
                                    )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Content.horizontalInset)
                    .padding(.top, Tokens.Content.topInset)
                    .padding(.bottom, Tokens.Content.bottomInset)
                }
                .scrollIndicators(.hidden)
            }

            if let message {
                Text(message)
                    .font(Tokens.Typography.metadata)
                    .padding(.horizontal, Tokens.Spacing.standard)
                    .padding(.vertical, Tokens.Spacing.small)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.medium, style: .continuous))
                    .padding(.bottom, Tokens.FloatingToolbar.bottomInset + Tokens.FloatingToolbar.height + Tokens.Spacing.compact)
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                floatingToolbar
                    .padding(.bottom, Tokens.FloatingToolbar.bottomInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: Tokens.Spacing.compact) {
            Image(systemName: section == .favorites ? "heart" : "photo.on.rectangle.angled")
                .font(.system(size: Tokens.Spacing.large, weight: .ultraLight))
                .foregroundStyle(Tokens.accent)
            Text(NSLocalizedString(emptyTitleKey, comment: ""))
                .font(Tokens.Typography.emptyTitle)
            Text(NSLocalizedString(section == .search ? "shell.empty.searchHint" : "shell.empty.hint", comment: ""))
                .font(Tokens.Typography.emptyDetail)
                .foregroundStyle(.secondary)
            if section != .search && section != .favorites {
                Button("shell.import.video") { Task { await importVideo() } }
                    .buttonStyle(.bordered)
                    .disabled(importing)
                    .padding(.top, Tokens.Spacing.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.Grid.maximumCardWidth, alignment: .center)
        .padding(Tokens.Spacing.section)
    }

    private var emptyTitleKey: String {
        switch section {
        case .search: return "shell.empty.search"
        case .favorites: return "shell.empty.favorites"
        case .all, .local, .steam: return "shell.empty.library"
        }
    }

    private var floatingToolbar: some View {
        ZStack {
            if let wallpaper = nowPlayingWallpaper {
                nowPlaying(wallpaper)
                    .frame(maxWidth: Tokens.FloatingToolbar.nowPlayingMaximumWidth)
            }

            HStack(spacing: 0) {
                toolbarLeftCluster
                Spacer(minLength: 0)
                toolbarRightCluster
            }
            .padding(.horizontal, Tokens.FloatingToolbar.horizontalInset)
        }
        .frame(width: Tokens.FloatingToolbar.width, height: Tokens.FloatingToolbar.height)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.06), radius: Tokens.Spacing.small, y: Tokens.Spacing.micro)
    }

    private var toolbarLeftCluster: some View {
        HStack(spacing: Tokens.FloatingToolbar.iconGap) {
            Button { Task { await importVideo() } } label: {
                Image(systemName: "plus")
                    .frame(width: Tokens.Spacing.section, height: Tokens.FloatingToolbar.stopButtonSize)
            }
            .help("shell.toolbar.add")
            .disabled(importing)

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                .frame(width: 1, height: Tokens.FloatingToolbar.dividerHeight)

            Button(action: togglePlayback) {
                Image(systemName: runtime.state.playbackState == .playing ? "pause.fill" : "play.fill")
                    .frame(width: Tokens.Spacing.section, height: Tokens.FloatingToolbar.stopButtonSize)
            }
            .disabled(!canTogglePlayback)
            .help(playbackTooltip)
        }
        .font(.system(size: Tokens.FloatingToolbar.iconSize, weight: .medium))
        .buttonStyle(.plain)
    }

    private var toolbarRightCluster: some View {
        HStack(spacing: Tokens.FloatingToolbar.rightClusterGap) {
            Button { runtime.stop() } label: {
                Image(systemName: "xmark")
                    .frame(
                        width: Tokens.FloatingToolbar.stopButtonSize,
                        height: Tokens.FloatingToolbar.stopButtonSize
                    )
                    .background(
                        Color.primary.opacity(stopHovered ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.small, style: .continuous)
                    )
            }
            .disabled(!canStopPlayback)
            .help("shell.toolbar.stop")
            .onHover { stopHovered = $0 }

            Image(systemName: "speaker.slash")
                .foregroundStyle(.secondary)
                .frame(width: Tokens.Spacing.section, height: Tokens.FloatingToolbar.stopButtonSize)
                .help("shell.toolbar.unmute")

            Image(systemName: "info.circle")
                .foregroundStyle(selectedID == nil ? .secondary : .primary)
                .frame(width: Tokens.Spacing.section, height: Tokens.FloatingToolbar.stopButtonSize)
                .help("shell.toolbar.info")
        }
        .font(.system(size: Tokens.FloatingToolbar.iconSize, weight: .medium))
        .buttonStyle(.plain)
    }

    private var nowPlayingWallpaper: Wallpaper? {
        guard runtime.state.playbackState != .stopped else { return nil }
        return runtime.activeWallpaper
    }

    private func nowPlaying(_ wallpaper: Wallpaper) -> some View {
        HStack(spacing: Tokens.FloatingToolbar.thumbnailNameGap) {
            nowPlayingThumbnail(wallpaper)
            Text(wallpaper.name)
                .font(Tokens.Typography.nowPlayingName)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func nowPlayingThumbnail(_ wallpaper: Wallpaper) -> some View {
        Group {
            if let url = wallpaper.thumbnailURL,
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(
            width: Tokens.FloatingToolbar.thumbnailSize,
            height: Tokens.FloatingToolbar.thumbnailSize
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.small, style: .continuous))
    }

    private var playbackTooltip: String {
        let key: String
        switch runtime.state.playbackState {
        case .playing: key = "shell.toolbar.pause"
        case .stopped: key = "shell.toolbar.reenable"
        case .manualPaused, .smartPaused: key = "shell.toolbar.resume"
        default: key = "shell.toolbar.play"
        }
        return NSLocalizedString(key, comment: "Toolbar playback help")
    }

    private var canStopPlayback: Bool {
        runtime.state.playbackState != .stopped &&
        (runtime.state.activeWallpaperID != nil || runtime.state.preparingWallpaperID != nil)
    }

    private var canTogglePlayback: Bool {
        switch runtime.state.playbackState {
        case .playing, .manualPaused, .stopped: return true
        default: return false
        }
    }

    private func togglePlayback() {
        switch runtime.state.playbackState {
        case .playing: runtime.pause()
        case .manualPaused: runtime.resume()
        case .stopped: runtime.reenable()
        default: break
        }
    }

    private func apply(_ wallpaper: Wallpaper) {
        guard wallpaper.supportState == .supported,
              WallpaperRuntimeManager.isRendererAvailable(for: wallpaper.type) else { return }
        cardPresentation.beginApply(wallpaper.id)
        runtime.apply(wallpaper)
        // Renderer 创建可能同步失败，此时 Runtime 不会发布新的 state。
        cardPresentation.synchronize(with: runtime.state)
    }

    private func importVideo() async {
        guard !importing else { return }
        // 这里只提供视频入口；导入服务负责复制和验证。
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("shell.import.video", comment: "")
        panel.message = NSLocalizedString("shell.import.message", comment: "")
        panel.prompt = NSLocalizedString("import.panel.prompt", comment: "")
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importing = true
        defer { importing = false }
        let outcomes = await importer.importItems(at: panel.urls)
        if let newest = outcomes.compactMap(\.wallpaper).last {
            selectedID = newest.id
            section = .all
        }
        let failed = outcomes.compactMap { outcome -> String? in
            if case .failure(let error) = outcome.result { return error.localizedDescription }
            return nil
        }
        withAnimation {
            if let firstError = failed.first {
                message = firstError
            } else if !outcomes.isEmpty {
                message = NSLocalizedString("shell.import.success", comment: "")
            }
        }
        if let shownMessage = message {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if message == shownMessage { withAnimation { message = nil } }
            }
        }
    }
}
