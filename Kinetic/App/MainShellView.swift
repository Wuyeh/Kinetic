import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// 产品主窗口。只使用资料库、导入服务和 Runtime 的公开接口。
@MainActor
struct MainShellView: View {
    let appDelegate: AppDelegate
    @State private var services: ShellServices?
    @State private var connectionFailed = false
    /// Module 22：每次启动主窗口第一次出现时播放启动动画。
    @State private var isPlayingLaunchAnimation = LaunchAnimationPolicy.consume()

    var body: some View {
        Group {
            if let services {
                if let onboarding = services.onboarding {
                    OnboardingGate(onboarding: onboarding) {
                        LibraryShellView(library: services.library, runtime: services.runtime, importer: services.importer,
                                         steam: services.steam, store: services.store, steamApply: services.steamApply,
                                         navigation: appDelegate.mainWindowNavigation)
                    }
                } else {
                    LibraryShellView(library: services.library, runtime: services.runtime, importer: services.importer,
                                     steam: services.steam, store: services.store, steamApply: services.steamApply,
                                     navigation: appDelegate.mainWindowNavigation)
                }
            } else if connectionFailed {
                Text("shell.error.unavailable")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .opacity(isPlayingLaunchAnimation ? 0 : 1)
        .overlay {
            if isPlayingLaunchAnimation {
                LaunchAnimationView {
                    // 字标淡出，同时主界面淡入。
                    withAnimation(.easeInOut(duration: LaunchAnimationView.Timing.fadeOut)) {
                        isPlayingLaunchAnimation = false
                    }
                }
                .transition(.opacity)
            }
        }
        // Module 22：整个窗口是 Liquid Glass，透出桌面上的动态壁纸（用户决定）。
        .background { WindowGlassBackground().ignoresSafeArea() }
        .background {
            MainWindowLaunchVisibility(appDelegate: appDelegate)
                .frame(width: 0, height: 0)
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
        services = ShellServices(library: library, runtime: runtime, importer: importer,
                                 onboarding: appDelegate.onboarding,
                                 steam: appDelegate.steamService, store: appDelegate.steamStore,
                                 steamApply: appDelegate.steamDisplayApply)
    }
}

/// Module 20：第一次启动先显示 Welcome，完成或跳过后淡入资料库。
private struct OnboardingGate<Library: View>: View {
    @ObservedObject var onboarding: OnboardingController
    @ViewBuilder let library: () -> Library

    var body: some View {
        ZStack {
            if onboarding.isWelcomeVisible {
                WelcomeView(onboarding: onboarding)
                    .transition(.opacity)
            } else {
                library()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: onboarding.isWelcomeVisible)
    }
}

/// Module 19：向 AppDelegate 登记主窗口及打开它的动作。登录启动时主窗口不显示，只在菜单栏运行；
/// 之后从菜单栏或 Dock 打开时正常显示。
private struct MainWindowLaunchVisibility: NSViewRepresentable {
    let appDelegate: AppDelegate

    func makeNSView(context: Context) -> WindowProbe {
        let openWindow = context.environment.openWindow
        appDelegate.registerMainWindowOpener { openWindow(id: "main") }
        return WindowProbe(appDelegate: appDelegate)
    }
    func updateNSView(_ nsView: WindowProbe, context: Context) {}

    final class WindowProbe: NSView {
        private weak var appDelegate: AppDelegate?

        init(appDelegate: AppDelegate) {
            self.appDelegate = appDelegate
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            appDelegate?.mainWindowDidAppear(window)
        }
    }
}

@MainActor
private struct ShellServices {
    let library: WallpaperLibrary
    let runtime: WallpaperRuntimeManager
    let importer: LocalImportService
    let onboarding: OnboardingController?
    /// 1.0 Module 9 / 14：Steam 下载核心与在线商店。
    let steam: SteamAcquisitionService?
    let store: SteamStoreService?
    let steamApply: SteamDisplayApplyCoordinator?
}

/// 主窗口的页面（侧栏各项）。1.0 Module 10（规格 2、4）：搜索、喜爱，资料库下只有「本地」与「Steam」，没有「全部」。
enum ShellSection: String, Hashable, CaseIterable {
    case search, favorites, local, steam

    var title: String {
        let key: String
        switch self {
        case .search: key = "shell.search"
        case .favorites: key = "shell.favorites"
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
        case .local: return LocalLibraryIcon.symbolName
        // Steam 使用正式图形资源时再绘制；不以相似 SF Symbol 冒充品牌标志。
        case .steam: return nil
        }
    }

    /// 1.0 Module 7：资料库只有「本地」（全部已保存的壁纸）与「喜爱」。
    /// 「Steam」是在线商店（Module 14），不是本地筛选，所以没有资料库查询。
    var filter: LibraryFilter? {
        switch self {
        case .favorites: return .favorites
        case .search, .local: return .local
        case .steam: return nil
        }
    }

    /// 读取保存的页面。v0.1 / Module 10 之前的「全部」与「本地」内容相同，读到时转为「本地」。
    init?(storedValue: String) {
        if storedValue == "all" {
            self = .local
        } else {
            self.init(rawValue: storedValue)
        }
    }
}

/// Module 22：主窗口打开时显示哪一页（用户要求）。第一次进入是资料库中的 Steam 页面；
/// 之后每次打开都回到上次退出时停留的页面。按资料库目录分别记录（Debug 验收资料库不影响正式资料库）。
struct MainWindowPageStore {
    static let storageKey = "Kinetic.MainWindowPage.v1"
    /// 第一次进入主界面时的页面。
    static let firstPage: ShellSection = .steam

    private let defaults: UserDefaults
    private let libraryKey: String

    init(defaults: UserDefaults = .standard, library: LibraryStorageLocation) {
        self.defaults = defaults
        libraryKey = library.rootURL.standardizedFileURL.path
    }

    /// 上次停留的页面；从未记录过（或记录无法识别）时是 Steam 页面。
    var initialPage: ShellSection {
        (defaults.dictionary(forKey: Self.storageKey)?[libraryKey] as? String)
            .flatMap(ShellSection.init(storedValue:)) ?? Self.firstPage
    }

    /// 每次切换页面时记录，退出时停留的页面就是最后一次记录的页面。
    func save(_ page: ShellSection) {
        var all = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        all[libraryKey] = page.rawValue
        defaults.set(all, forKey: Self.storageKey)
    }
}

private typealias Tokens = MainWindowDesignTokens

/// 内容区没有卡片时显示哪一种空状态。搜索且没有关键词时，按资料库本身是否为空处理。
/// 1.0 Module 7：Steam 页面是在线商店，Module 14 之前显示即将开放的说明，不显示本地资料库的内容。
enum LibraryEmptyState: Equatable {
    case library, search, favorites, steamStore

    static func resolve(isSearch: Bool, isFavorites: Bool, query: String, libraryIsEmpty: Bool,
                        isSteamStore: Bool = false) -> LibraryEmptyState {
        if isSteamStore { return .steamStore }
        if isFavorites { return .favorites }
        if isSearch {
            let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasQuery || !libraryIsEmpty ? .search : .library
        }
        return .library
    }

    var titleKey: String {
        switch self {
        case .library: return "shell.empty.library"
        case .search: return "shell.empty.search"
        case .favorites: return "shell.empty.favorites"
        case .steamStore: return "shell.empty.steamStore"
        }
    }

    var hintKey: String {
        switch self {
        case .library: return "shell.empty.hint"
        case .search: return "shell.empty.searchHint"
        case .favorites: return "shell.empty.favoritesHint"
        case .steamStore: return "shell.empty.steamStoreHint"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "photo.on.rectangle.angled"
        case .search: return "magnifyingglass"
        case .favorites: return "heart"
        case .steamStore: return "network"
        }
    }

    /// 只有资料库本身为空时才提供导入入口。
    var offersImport: Bool { self == .library }
}

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

/// Module 12：单显示器直接应用；多显示器必须让用户指定目标。
enum LocalCardApplyRoute: Equatable {
    case unavailable
    case direct(DisplayID)
    case chooseDisplay

    static func resolve(_ summary: RuntimeSummary) -> Self {
        switch summary.displays.count {
        case 0: return .unavailable
        case 1: return .direct(summary.displays[0].displayID)
        default: return .chooseDisplay
        }
    }
}

/// R2 UI-MS1：选择只存稳定的 Wallpaper ID，排序 / 网格换列不会改变选中的对象。
struct StableCardSelection<ID: Hashable>: Equatable {
    private(set) var ids: Set<ID> = []

    var singleID: ID? { ids.count == 1 ? ids.first : nil }
    var count: Int { ids.count }
    func contains(_ id: ID) -> Bool { ids.contains(id) }

    mutating func selectOnly(_ id: ID) { ids = [id] }
    mutating func toggle(_ id: ID) {
        if !ids.insert(id).inserted { ids.remove(id) }
    }
    mutating func replace(with newIDs: Set<ID>) { ids = newIDs }
    mutating func retain(_ validIDs: Set<ID>) { ids.formIntersection(validIDs) }
    mutating func remove(_ id: ID) { ids.remove(id) }
    mutating func clear() { ids.removeAll() }
}

enum CardMarqueeSelection {
    static func frame(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(start.x - end.x), height: abs(start.y - end.y))
    }

    static func intersectingIDs<ID: Hashable>(from start: CGPoint, to end: CGPoint,
                                                frames: [ID: CGRect]) -> Set<ID> {
        let area = frame(from: start, to: end)
        return Set(frames.filter { area.intersects($0.value) }.map(\.key))
    }
}

@MainActor
private struct LibraryShellView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var runtime: WallpaperRuntimeManager
    @StateObject private var organization: LocalOrganizationStore
    let importer: LocalImportService
    let steam: SteamAcquisitionService?
    let store: SteamStoreService?
    let steamApply: SteamDisplayApplyCoordinator?
    let navigation: MainWindowNavigation
    private let pageStore: MainWindowPageStore

    @State private var section: ShellSection
    @State private var selection = StableCardSelection<Wallpaper.ID>()
    @State private var cardFrames: [Wallpaper.ID: CGRect] = [:]
    @State private var marqueeExcludedFrames: [String: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var selectedListID: UUID?
    @State private var isCreatingList = false
    @State private var pendingListMembers: [Wallpaper.ID] = []
    @State private var listFrames: [UUID: CGRect] = [:]
    @StateObject private var sidebarDragCoordinates = WindowDragCoordinates()
    @State private var sidebarDragOrigin = CGPoint.zero
    @State private var isConfirmingDeletion = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var windowReference = LibraryWindowReference()
    @State private var cardPresentation = WallpaperCardPresentation()
    @State private var displayApply = DisplayApplyPresentation()
    @State private var localDrag = LocalWallpaperDragPresentation()
    @State private var steamDrag = SteamDisplayDragPresentation()
    @State private var targetFrames: [DisplayID: CGRect] = [:]
    @State private var query = ""
    /// Content Header：每个内容页面（本地、喜爱、Steam、每个壁纸列表）各自的排序与显示选项。
    @State private var contentOptions: [String: ContentViewOptions] = [:]
    /// 正在进行的导入次数（文件面板与 Finder 拖入可以同时进行）。
    @State private var activeImports = 0
    @StateObject private var dropState = FinderDropState()
    @StateObject private var downloadPresentation = SteamDownloadPresentation()
    @State private var message: String?
    @State private var messageID = UUID()
    @State private var hasDismissedLibraryIssue = false
    @FocusState private var searchFocused: Bool

    init(library: WallpaperLibrary, runtime: WallpaperRuntimeManager, importer: LocalImportService,
         steam: SteamAcquisitionService?, store: SteamStoreService?, steamApply: SteamDisplayApplyCoordinator?,
         navigation: MainWindowNavigation) {
        _library = ObservedObject(wrappedValue: library)
        _runtime = ObservedObject(wrappedValue: runtime)
        _organization = StateObject(wrappedValue: LocalOrganizationStore(storage: library.storage))
        self.importer = importer
        self.steam = steam
        self.store = store
        self.steamApply = steamApply
        self.navigation = navigation
        let pageStore = MainWindowPageStore(library: library.storage)
        self.pageStore = pageStore
        _section = State(initialValue: pageStore.initialPage)
    }

    private var importing: Bool { activeImports > 0 }

    /// 当前内容页面的选项键；搜索页面没有 Content Header，返回 nil。
    private var contentScopeKey: String? {
        if section == .search { return nil }
        if section == .local, let selectedListID { return "list-\(selectedListID.uuidString)" }
        return section.rawValue
    }

    private var currentContentOptions: ContentViewOptions {
        contentScopeKey.flatMap { contentOptions[$0] } ?? ContentViewOptions()
    }

    private var contentOptionsBinding: Binding<ContentViewOptions> {
        Binding(
            get: { currentContentOptions },
            set: { newValue in if let key = contentScopeKey { contentOptions[key] = newValue } }
        )
    }

    private var selectedList: WallpaperList? {
        guard section == .local, let selectedListID else { return nil }
        return organization.lists.first { $0.id == selectedListID }
    }

    private var visibleWallpapers: [Wallpaper] {
        if section == .search { return library.search(query) }
        let options = currentContentOptions
        if let list = selectedList {
            // 列表：「添加时间」是加入这个列表的时间。
            let members = Set(list.wallpaperIDs)
            return ContentQuery.apply(options, to: library.wallpapers.filter { members.contains($0.id) },
                                      dateAdded: { list.addedAt($0.id) })
        }
        switch section {
        case .local:
            // 本地：「添加时间」是加入资料库的时间；置顶组始终在前，排序只在组内进行。
            return ContentQuery.apply(options, to: library.wallpapers(in: .local), dateAdded: \.importedAt,
                                      isPinned: { organization.isPinned($0) })
        case .favorites:
            // 喜爱：「添加时间」是加入喜爱的时间。
            return ContentQuery.apply(options, to: library.wallpapers(in: .favorites), dateAdded: \.favoritedAt)
        case .steam:
            // Steam 在线商店（Module 14）由 SteamStoreService 按这些选项查询（添加时间 = 创意工坊发布时间）。
            return []
        case .search:
            return library.search(query)
        }
    }

    private var selectedWallpaper: Wallpaper? {
        guard let id = selection.singleID else { return nil }
        return visibleWallpapers.first { $0.id == id }
    }

    var body: some View {
        // 侧栏始终可见：只允许在 min…max 之间调整宽度，不提供也不允许任何折叠。
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .frame(minWidth: Tokens.Sidebar.minimumWidth)
                .navigationSplitViewColumnWidth(
                    min: Tokens.Sidebar.minimumWidth,
                    ideal: Tokens.Sidebar.defaultWidth,
                    max: Tokens.Sidebar.maximumWidth
                )
                .background { WindowDragCoordinateProbe(reference: sidebarDragCoordinates) }
                .background {
                    GeometryReader { proxy in Color.clear.preference(key: WindowDragOriginKey.self,
                                                                      value: proxy.frame(in: .global).origin) }
                    .allowsHitTesting(false)
                }
                .onPreferenceChange(WindowDragOriginKey.self) { if let origin = $0 { sidebarDragOrigin = origin } }
                .transformPreference(WallpaperListFrameKey.self) { frames in
                    frames = sidebarDragCoordinates.windowFrames(frames, globalOrigin: sidebarDragOrigin)
                }
                .onPreferenceChange(WallpaperListFrameKey.self) { listFrames = $0; refreshDisplayHover() }
        } detail: {
            mainArea
                .frame(minWidth: Tokens.Content.minimumWidth)
            .background {
                // 放在 detail 列：侧栏的任何状态变化都不会让守卫本身被移除。
                SidebarCollapseLock(detailMinimumWidth: Tokens.Content.minimumWidth)
                    .frame(width: 0, height: 0)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // 选择窗口是临时模态交互：背景控件不参与点击、键盘焦点或辅助功能导航。
        .disabled(displayApply.isPresented)
        .accessibilityHidden(displayApply.isPresented)
        .frame(minWidth: Tokens.Window.minimumWidth, minHeight: Tokens.Window.minimumHeight)
        .background {
            MainWindowMinimumSize(width: Tokens.Window.minimumWidth, height: Tokens.Window.minimumHeight)
                .frame(width: 0, height: 0)
        }
        .background {
            DeleteKeyHandler(
                isEnabled: selectedWallpaper != nil && !isConfirmingDeletion && !displayApply.isPresented
                    && localDrag.wallpaperID == nil && steamDrag.item == nil,
                windowReference: windowReference
            ) {
                if let wallpaper = selectedWallpaper { requestDelete(wallpaper) }
            }
            .frame(width: 0, height: 0)
        }
        // 1.0 Module 8：Finder 拖入。整个主窗口都是拖入目标，任何页面都可以；只加入本地资料库，不切换页面。
        .onDrop(of: FinderDropDelegate.acceptedTypes, delegate: FinderDropDelegate(state: dropState, onDrop: importDropped))
        .tint(Tokens.accent)
        .onChange(of: runtime.state) { _ in
            cardPresentation.synchronize(with: runtime.state)
        }
        .overlay(alignment: .top) {
            if let id = localDrag.wallpaperID, let wallpaper = library.wallpaper(id: id) {
                LocalWallpaperDragOverlay(wallpaper: wallpaper, location: localDrag.location,
                                          items: displayTargets, hoveredID: localDrag.hoveredDisplayID)
                .transition(.opacity)
                .zIndex(90)
            } else if let item = steamDrag.item {
                WallpaperDisplayDragOverlay(location: steamDrag.location, items: displayTargets,
                                            hoveredID: steamDrag.hoveredDisplayID) {
                    PosterView(posterURL: steamDrag.posterURL, placeholderType: item.type ?? .web)
                }
                .transition(.opacity)
                .zIndex(90)
            }
        }
        .onPreferenceChange(DisplayTargetFrameKey.self) { frames in
            targetFrames = frames
            refreshDisplayHover()
        }
        .overlay {
            if displayApply.isPresented {
                GeometryReader { proxy in
                    DisplayApplyDialog(items: displayTargets, availableSize: proxy.size,
                                       onSelect: selectApplyDisplay, onCancel: { displayApply.cancel() })
                }
                .zIndex(100)
            }
        }
        .onChange(of: runtime.summary.displays.map(\.displayID)) { ids in
            // 设备断开 / 排列改变后等待目标条本次布局的新坐标，不能命中上一帧的位置。
            targetFrames = [:]
            refreshDisplayHover()
            if ids.isEmpty { displayApply.cancel(); cancelDisplayDrag() }
        }
        .onChange(of: library.wallpapers.map(\.id)) { ids in
            if let id = displayApply.wallpaperID, !ids.contains(id) { displayApply.cancel() }
            if let id = localDrag.wallpaperID, !ids.contains(id) { cancelDisplayDrag() }
        }
        .onExitCommand { displayApply.cancel(); cancelDisplayDrag() }
        .onReceive(steamApply?.notices.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) {
            showMessage($0.message)
        }
        .onReceive(navigation.requests.compactMap { $0 }) { page in
            selectedListID = nil
            section = page
            navigation.consume()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelDisplayDrag()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === windowReference.window { cancelDisplayDrag() }
        }
        .onDisappear { cancelDisplayDrag() }
        .sheet(isPresented: $isCreatingList) {
            NewWallpaperListSheet { name, description, cover in
                do {
                    _ = try organization.createList(name: name, description: description,
                                                    coverSourceURL: cover, wallpaperIDs: pendingListMembers)
                    pendingListMembers = []
                    return true
                } catch {
                    showMessage(error.localizedDescription)
                    return false
                }
            }
        }
        .onChange(of: section) { page in
            pageStore.save(page)
            cancelDisplayDrag()
            selection.clear()
            if page != .local { selectedListID = nil }
        }
        // 选择只保留当前页面可见的壁纸（按稳定 ID）：排序不改变选择；类型筛选、搜索关键词、切换列表、
        // 在喜爱页面取消喜爱、删除或移出列表时，看不到的壁纸从选择中移除，批量菜单的数量随之正确。
        .onChange(of: visibleWallpapers.map(\.id)) { ids in
            selection.retain(Set(ids))
            if let id = localDrag.wallpaperID, !ids.contains(id) { cancelDisplayDrag() }
        }
        .onChange(of: columnVisibility) { visibility in
            if visibility != .all { columnVisibility = .all }
        }
        .task(id: messageID) {
            guard message != nil else { return }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            withAnimation(.easeOut(duration: 0.15)) { message = nil }
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

            sectionButton(.local)
            sectionButton(.steam)

            Text("lists.sidebar.title")
                .font(Tokens.Typography.sidebarSection)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Sidebar.horizontalInset + Tokens.Sidebar.itemHorizontalInset)
                .padding(.top, Tokens.Sidebar.sectionTopInset)
                .padding(.bottom, Tokens.Spacing.small)
                .contextMenu {
                    Button("lists.create.menu") { beginCreateList() }
                }

            ScrollView {
                LazyVStack(spacing: Tokens.Spacing.micro / 2) {
                    ForEach(organization.lists) { list in
                        listSidebarRow(list)
                    }
                }
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: Tokens.Spacing.section)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Tokens.Sidebar.topInset)
        // 侧栏背景交给系统：macOS 26 起是悬浮的 Liquid Glass 侧栏。
    }

    private func sectionButton(_ item: ShellSection) -> some View {
        Button {
            section = item
            selectedListID = nil
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

    private func listSidebarRow(_ list: WallpaperList) -> some View {
        Button {
            section = .local
            selectedListID = list.id
            selection.clear()
        } label: {
            HStack(spacing: Tokens.Sidebar.iconTextGap) {
                listCover(list)
                    .frame(width: Tokens.Sidebar.iconSlotWidth, height: Tokens.Sidebar.iconSlotWidth)
                Text(list.name)
                    .font(selectedListID == list.id ? Tokens.Typography.sidebarSelectedItem : Tokens.Typography.sidebarItem)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Sidebar.itemHorizontalInset)
            .frame(height: Tokens.Sidebar.rowHeight)
            .background {
                if selectedListID == list.id || localDrag.hoveredListID == list.id {
                    RoundedRectangle(cornerRadius: Tokens.Radius.medium, style: .continuous)
                        .fill(Tokens.accent.opacity(localDrag.hoveredListID == list.id ? 0.18 : 0.09))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Tokens.Sidebar.horizontalInset)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: WallpaperListFrameKey.self,
                                       value: [list.id: proxy.frame(in: .global)])
            }
        }
        .contextMenu {
            Button("lists.rename") { renameList(list) }
            Button("lists.duplicate") { performListAction { try organization.duplicateList(list.id) } }
            Divider()
            Button("lists.delete", role: .destructive) { confirmListDeletion(list) }
        }
    }

    @ViewBuilder
    private func listCover(_ list: WallpaperList) -> some View {
        Group {
            if let url = list.coverImageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "square.stack")
                    .font(.system(size: 15))
                    .foregroundStyle(Tokens.accent)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.small, style: .continuous))
    }

    private var mainArea: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { contentGeometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if section == .search {
                            // 搜索页面不使用 Content Header，保持原有的专用设计。
                            Text(section.title)
                                .font(Tokens.Typography.pageTitle)
                                .padding(.bottom, Tokens.Content.titleBottomGap)
                        } else {
                            ContentHeader(title: selectedList?.name ?? section.title, options: contentOptionsBinding)
                                .padding(.bottom, Tokens.Content.titleBottomGap)
                                .background { marqueeExclusionFrame("contentHeader") }
                        }

                        if section == .search {
                            TextField("shell.search.placeholder", text: $query)
                                .textFieldStyle(.roundedBorder)
                                .focused($searchFocused)
                                // 进入搜索页时输入框出现后再获取焦点；切换前设置焦点可能落空。
                                .onAppear { DispatchQueue.main.async { searchFocused = true } }
                                .frame(maxWidth: Tokens.Grid.maximumCardWidth * 2)
                                .padding(.bottom, Tokens.Spacing.section)
                                .background { marqueeExclusionFrame("search") }
                        }

                        if section == .steam, let store, let steam {
                            // 1.0 Module 14：Steam 在线商店（在线搜索、卡片、双击加入本地资料库）。
                            SteamStoreBrowserView(
                                store: store,
                                steam: steam,
                                library: library,
                                downloads: downloadPresentation,
                                options: currentContentOptions,
                                availableWidth: max(0, contentGeometry.size.width - 2 * Tokens.Content.horizontalInset),
                                showMessage: { showMessage($0) },
                                onDisplayDrag: handleSteamDisplayDrag
                            )
                        } else if visibleWallpapers.isEmpty {
                            emptyState
                        } else {
                            ResponsiveWallpaperGrid(
                                availableWidth: max(0, contentGeometry.size.width - 2 * Tokens.Content.horizontalInset)
                            ) {
                                ForEach(visibleWallpapers) { wallpaper in
                                    WallpaperCard(
                                        wallpaper: wallpaper,
                                        isSelected: selection.contains(wallpaper.id),
                                        isActive: cardIsActive(wallpaper.id),
                                        onSelect: {
                                            if NSEvent.modifierFlags.contains(.command) {
                                                selection.toggle(wallpaper.id)
                                            } else {
                                                selection.selectOnly(wallpaper.id)
                                            }
                                        },
                                        onApply: { requestApply(wallpaper) },
                                        onContextMenu: { view in contextMenu(for: wallpaper, in: view) },
                                        onDisplayDrag: { handleDisplayDrag($0, wallpaper: wallpaper) }
                                    )
                                    .background {
                                        GeometryReader { proxy in
                                            Color.clear.preference(
                                                key: WallpaperCardFrameKey.self,
                                                value: [wallpaper.id: proxy.frame(in: .global)]
                                            )
                                        }
                                    }
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
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            guard isBlankSelectionOrigin(value.startLocation),
                                  hypot(value.translation.width, value.translation.height) >= 5 else { return }
                            marqueeStart = value.startLocation
                            marqueeCurrent = value.location
                            selection.replace(with: CardMarqueeSelection.intersectingIDs(
                                from: value.startLocation, to: value.location, frames: cardFrames
                            ))
                        }
                        .onEnded { value in
                            if isBlankSelectionOrigin(value.startLocation),
                               hypot(value.translation.width, value.translation.height) < 5 {
                                selection.clear()
                            }
                            marqueeStart = nil
                            marqueeCurrent = nil
                        }
                )
                .overlay {
                    if let start = marqueeStart, let current = marqueeCurrent {
                        GeometryReader { proxy in
                            let area = CardMarqueeSelection.frame(from: start, to: current)
                            let origin = proxy.frame(in: .global).origin
                            Rectangle()
                                .fill(Tokens.accent.opacity(0.08))
                                .overlay { Rectangle().strokeBorder(Tokens.accent.opacity(0.8), lineWidth: 1) }
                                .frame(width: area.width, height: area.height)
                                .position(x: area.midX - origin.x, y: area.midY - origin.y)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(WallpaperCardFrameKey.self) { cardFrames = $0 }
            }

            if let failure = runtime.lastFailure {
                RecoveryNotice(
                    message: failure.message,
                    detail: failure.detail,
                    actionTitle: "recovery.retry",
                    action: retryAction(for: failure),
                    dismiss: runtime.dismissFailure
                )
                .padding(.horizontal, Tokens.Spacing.standard)
                .padding(.bottom, Tokens.FloatingToolbar.bottomInset + Tokens.FloatingToolbar.height + Tokens.Spacing.compact)
            } else if let issue = library.loadIssue, !hasDismissedLibraryIssue {
                RecoveryNotice(
                    message: NSLocalizedString(issue.backupURL == nil ? "recovery.library.unreadable" : "recovery.library.backedUp", comment: ""),
                    detail: issue.reason,
                    actionTitle: "recovery.showBackup",
                    action: issue.backupURL.map { url in { NSWorkspace.shared.activateFileViewerSelecting([url]) } },
                    dismiss: { hasDismissedLibraryIssue = true }
                )
                .padding(.horizontal, Tokens.Spacing.standard)
                .padding(.bottom, Tokens.FloatingToolbar.bottomInset + Tokens.FloatingToolbar.height + Tokens.Spacing.compact)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                floatingToolbar
                    .padding(.bottom, Tokens.FloatingToolbar.bottomInset)
                    .background { marqueeExclusionFrame("floatingToolbar") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: DownloadAnimationMetrics.coordinateSpace)
        .overlay { SteamDownloadOverlay(presentation: downloadPresentation) }
        .onPreferenceChange(MarqueeExcludedFrameKey.self) { marqueeExcludedFrames = $0 }
        .overlay {
            // 用户要求：状态提示（导入成功 / 失败、正在导入等）放在主内容区最上方居中，
            // 位于窗口上沿与页面标题之间（隐藏标题栏留出的那一条）。
            GeometryReader { proxy in
                StatusToastLayer(message: message, isImporting: importing)
                    // 只限定可用宽度；提示本身按内容收缩，过长时截断。
                    .frame(width: max(0, min(proxy.size.width - 2 * Tokens.Spacing.section, 560)))
                    .position(x: proxy.size.width / 2,
                              y: StatusToastLayer.centerY(topBand: proxy.safeAreaInsets.top))
            }
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        }
        .overlay {
            // 1.0 Module 8：拖入反馈位于主内容区（侧栏右侧，从窗口上沿到下沿）的正中间。
            if let feedback = dropState.feedback {
                FinderDropFeedbackView(evaluation: feedback)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.opacity)
            }
        }
    }

    private var emptyKind: LibraryEmptyState {
        LibraryEmptyState.resolve(
            isSearch: section == .search,
            isFavorites: section == .favorites,
            query: query,
            libraryIsEmpty: library.wallpapers.isEmpty,
            isSteamStore: section == .steam
        )
    }

    private var emptyState: some View {
        VStack(spacing: Tokens.Spacing.compact) {
            Image(systemName: selectedListID == nil ? emptyKind.symbol : "square.stack")
                .font(.system(size: Tokens.Spacing.large, weight: .ultraLight))
                .foregroundStyle(Tokens.accent)
            Text(selectedListID == nil ? NSLocalizedString(emptyKind.titleKey, comment: "")
                                       : NSLocalizedString("lists.empty", comment: ""))
                .font(Tokens.Typography.emptyTitle)
            if selectedListID == nil {
                Text(NSLocalizedString(emptyKind.hintKey, comment: ""))
                    .font(Tokens.Typography.emptyDetail)
                    .foregroundStyle(.secondary)
            }
            if selectedListID == nil && emptyKind.offersImport {
                Button("shell.import.video") { Task { await importVideo() } }
                    .kineticGlassButton()
                    .disabled(importing)
                    .padding(.top, Tokens.Spacing.small)
                    .background { marqueeExclusionFrame("emptyImport") }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.Grid.maximumCardWidth, alignment: .center)
        .padding(Tokens.Spacing.section)
    }

    private var floatingToolbar: some View {
        ZStack {
            switch toolbarState.nowPlaying {
            case .wallpaper(let id, let display):
                if let wallpaper = library.wallpaper(id: id) ?? runtime.activeWallpaper(on: display) {
                    nowPlaying(wallpaper)
                        .frame(maxWidth: Tokens.FloatingToolbar.nowPlayingMaximumWidth)
                }
            case .multiple(let count):
                nowPlayingOnSeveralDisplays(count)
                    .frame(maxWidth: Tokens.FloatingToolbar.nowPlayingMaximumWidth)
            case nil:
                EmptyView()
            }

            HStack(spacing: 0) {
                toolbarLeftCluster
                Spacer(minLength: 0)
                toolbarRightCluster
            }
            .padding(.horizontal, Tokens.FloatingToolbar.horizontalInset)
        }
        .frame(width: Tokens.FloatingToolbar.width, height: Tokens.FloatingToolbar.height)
        // 规格：工具条本身是 Liquid Glass 容器，内部图标没有独立背景。
        // 用户调整：工具条比窗口更通透，使用 clear 变体。
        .kineticGlass(in: Capsule(), clear: true)
    }

    private var toolbarLeftCluster: some View {
        HStack(spacing: Tokens.FloatingToolbar.iconGap) {
            Menu {
                // 1.0 Module 23：「＋」导入到本地资料库；Steam 内容从 Steam 在线商店页面获取（规格 2），
                // 所以 Steam 项目打开 Steam 页面，而不是一个不可用的导入入口。
                ForEach(FloatingToolbarAddItem.allCases, id: \.self) { item in
                    Button(LocalizedStringKey(item.titleKey)) { performAddItem(item) }
                }
            } label: {
                Image(systemName: "plus")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Tokens.FloatingToolbar.addIconSize, height: Tokens.FloatingToolbar.addIconSize)
                    // 用户要求：交互按钮无色，与工具条其他按钮一致。
                    .foregroundStyle(.primary)
                    .frame(width: Tokens.Spacing.section, height: Tokens.FloatingToolbar.stopButtonSize)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("shell.toolbar.add")
            .disabled(importing)

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                .frame(width: 1, height: Tokens.FloatingToolbar.dividerHeight)

            Button(action: togglePlayback) {
                Image(systemName: toolbarState.showsPauseSymbol ? "pause.fill" : "play.fill")
                    .frame(width: Tokens.Spacing.section, height: Tokens.FloatingToolbar.stopButtonSize)
            }
            .disabled(!toolbarState.canTogglePlayback)
            .help(NSLocalizedString(toolbarState.playbackHelpKey, comment: "Toolbar playback help"))
            .accessibilityLabel(Text(NSLocalizedString(toolbarState.playbackHelpKey, comment: "")))
        }
        .font(.system(size: Tokens.FloatingToolbar.iconSize, weight: .medium))
        .buttonStyle(.plain)
    }

    private var toolbarRightCluster: some View {
        HStack(spacing: Tokens.FloatingToolbar.rightClusterGap) {
            Button { runtime.stop(.allDisplays) } label: {
                Image(systemName: "xmark")
                    .frame(
                        width: Tokens.FloatingToolbar.stopButtonSize,
                        height: Tokens.FloatingToolbar.stopButtonSize
                    )
            }
            .disabled(!toolbarState.canStop)
            .help("shell.toolbar.stop")
            .accessibilityLabel(Text(LocalizedStringKey("shell.toolbar.stop")))

            Button {
                runtime.setAudioEnabled(!runtime.isAudioEnabled)
            } label: {
                Image(systemName: runtime.isAudioEnabled ? "speaker.wave.2" : "speaker.slash")
                    .frame(width: Tokens.Spacing.section, height: Tokens.FloatingToolbar.stopButtonSize)
            }
            .help(runtime.isAudioEnabled ? "shell.toolbar.mute" : "shell.toolbar.unmute")
            .accessibilityLabel(Text(LocalizedStringKey(runtime.isAudioEnabled ? "shell.toolbar.mute" : "shell.toolbar.unmute")))

        }
        .font(.system(size: Tokens.FloatingToolbar.iconSize, weight: .medium))
        .buttonStyle(.plain)
    }

    /// 1.0 Module 23：工具条状态来自全部显示器的汇总（只有一台显示器时与 v0.1 相同）。
    private var toolbarState: FloatingToolbarState {
        FloatingToolbarState(summary: runtime.summary, isInLibrary: { library.wallpaper(id: $0) != nil })
    }

    /// 多台显示器显示不同的壁纸时，中间显示摘要，不假装只有一张「正在播放」。
    private func nowPlayingOnSeveralDisplays(_ count: Int) -> some View {
        HStack(spacing: Tokens.FloatingToolbar.thumbnailNameGap) {
            Image(systemName: "display.2")
                .foregroundStyle(.secondary)
                .frame(width: Tokens.FloatingToolbar.thumbnailSize, height: Tokens.FloatingToolbar.thumbnailSize)
            Text(String(format: NSLocalizedString("shell.toolbar.nowPlaying.multiple", comment: ""), count))
                .font(Tokens.Typography.nowPlayingName)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
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

    private func togglePlayback() {
        FloatingToolbarState.perform(toolbarState.playbackAction, on: runtime,
                                     isInLibrary: { library.wallpaper(id: $0) != nil })
    }

    private func performAddItem(_ item: FloatingToolbarAddItem) {
        switch item {
        case .importVideo: Task { await importVideo() }
        case .importWebFolder: Task { await importWebFolders() }
        case .openSteamWorkshop: section = .steam
        }
    }

    private func cardIsActive(_ id: Wallpaper.ID) -> Bool {
        if runtime.summary.displays.count == 1 {
            return cardPresentation.displayedActiveWallpaperID(in: runtime.state) == id
        }
        return !runtime.summary.displays(involving: id).isEmpty
    }

    private func isBlankSelectionOrigin(_ point: CGPoint) -> Bool {
        !cardFrames.values.contains { $0.contains(point) } &&
        !marqueeExcludedFrames.values.contains { $0.contains(point) }
    }

    private func marqueeExclusionFrame(_ key: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: MarqueeExcludedFrameKey.self,
                                   value: [key: proxy.frame(in: .global)])
        }
    }

    private func requestApply(_ wallpaper: Wallpaper) {
        switch LocalCardApplyRoute.resolve(runtime.summary) {
        case .unavailable: break
        case .direct(let display): apply(wallpaper, to: display)
        case .chooseDisplay: displayApply.present(wallpaper.id)
        }
    }

    private var displayTargets: [DisplayTargetItem] {
        runtime.summary.displays.enumerated().map { index, display in
            DisplayTargetItem(display: display, index: index,
                              wallpaper: runtime.activeWallpaper(on: display.displayID))
        }
    }

    private func selectApplyDisplay(_ displayID: DisplayID) {
        // 同步消费这一次请求；重排按稳定 ID、断开 / 删除则取消，不选择另一台设备。
        guard let id = displayApply.takeSelection(displayID, availableIDs: runtime.displayIDs,
                                                 isInLibrary: { library.wallpaper(id: $0) != nil }),
              let wallpaper = library.wallpaper(id: id) else { return }
        apply(wallpaper, to: displayID)
    }

    private func refreshDisplayHover() {
        localDrag.refresh(displayFrames: targetFrames, displayIDs: runtime.displayIDs,
                          listFrames: listFrames, listIDs: organization.lists.map(\.id))
        steamDrag.refresh(frames: targetFrames, displays: runtime.displayIDs)
    }

    private func cancelDisplayDrag() {
        localDrag.cancel()
        steamDrag.cancel()
        targetFrames = [:]
    }

    private func handleDisplayDrag(_ event: CardDisplayDragEvent, wallpaper: Wallpaper) {
        switch event {
        case .began:
            guard steamDrag.item == nil else { return }
            guard localDrag.begin(wallpaper.id) else { return }
            displayApply.cancel()
            targetFrames = [:]
        case .moved(let point):
            localDrag.move(point, from: wallpaper.id, displayFrames: targetFrames, displayIDs: runtime.displayIDs,
                           listFrames: listFrames, listIDs: organization.lists.map(\.id))
        case .ended(let point):
            guard localDrag.wallpaperID == wallpaper.id else { return }
            let current = library.wallpaper(id: wallpaper.id)
            let drop = localDrag.takeDrop(from: wallpaper.id, at: point,
                                          displayFrames: targetFrames, displayIDs: runtime.displayIDs,
                                          listFrames: listFrames, listIDs: organization.lists.map(\.id),
                                          isInLibrary: current != nil,
                                          isPlayable: current.map(WallpaperCardVisualState.isPlayable) ?? false)
            targetFrames = [:]
            switch drop {
            case .list(let id, let list): performListAction { try organization.add([id], to: list) }
            case .display(_, let target):
                if let current { apply(current, to: target) }
            case nil: break
            }
        case .cancelled:
            guard localDrag.wallpaperID == wallpaper.id else { return }
            cancelDisplayDrag()
        }
    }

    private func handleSteamDisplayDrag(_ item: SteamStoreItem, _ posterURL: URL?, _ event: CardDisplayDragEvent) {
        guard let steamApply else { return }
        switch event {
        case .began:
            guard localDrag.wallpaperID == nil, steamDrag.item == nil else { return }
            displayApply.cancel()
            targetFrames = [:]
            steamDrag.begin(item, posterURL: posterURL)
        case .moved(let point):
            steamDrag.move(point, from: item.id, frames: targetFrames, displays: runtime.displayIDs)
        case .ended(let point):
            guard steamDrag.item?.id == item.id else { return }
            let destination = steamDrag.takeDrop(from: item.id, at: point, frames: targetFrames, displays: runtime.displayIDs)
            targetFrames = [:]
            if let (item, display) = destination { steamApply.request(item.acquisitionInfo, to: display) }
        case .cancelled:
            guard steamDrag.item?.id == item.id else { return }
            steamDrag.cancel(from: item.id)
            targetFrames = [:]
        }
    }

    private func apply(_ wallpaper: Wallpaper, to display: DisplayID? = nil) {
        guard wallpaper.supportState == .supported,
              WallpaperRuntimeManager.isRendererAvailable(for: wallpaper.type) else { return }
        guard let display = display ?? (runtime.summary.displays.count == 1 ? runtime.summary.displays.first?.displayID : nil),
              runtime.hasDisplay(display) else { return }
        if runtime.summary.displays.count == 1 { cardPresentation.beginApply(wallpaper.id) }
        steamApply?.cancelApplication(on: display)
        runtime.apply(wallpaper, to: display)
        // Renderer 创建可能同步失败，此时 Runtime 不会发布新的 state。
        if runtime.summary.displays.count == 1 { cardPresentation.synchronize(with: runtime.state) }
    }

    private func retryAction(for failure: WallpaperRuntimeFailure) -> (() -> Void)? {
        guard let wallpaper = library.wallpaper(id: failure.wallpaperID),
              WallpaperCardVisualState.isPlayable(wallpaper) else { return nil }
        return {
            WallpaperPreviewCoordinator.shared.stopAll()
            // 重试回到出错的那台显示器。
            apply(wallpaper, to: failure.displayID)
        }
    }

    private func toggleFavorite(_ wallpaper: Wallpaper) {
        do {
            try library.setFavorite(!wallpaper.isFavorite, for: wallpaper.id)
        } catch {
            showMessage(error.localizedDescription)
        }
    }

    private func contextMenu(for wallpaper: Wallpaper, in view: NSView) -> NSMenu {
        if !selection.contains(wallpaper.id) { selection.selectOnly(wallpaper.id) }
        let selected = selection.ids.compactMap { library.wallpaper(id: $0) }
        let wallpapers = selected.count > 1 ? selected : [wallpaper]
        let isBatch = wallpapers.count > 1
        let menu = NSMenu()
        menu.autoenablesItems = false
        let allPinned = wallpapers.allSatisfy { organization.isPinned($0.id) }
        menu.addItem(WallpaperMenuActionItem(title: localized(allPinned ? "wallpaper.menu.unpin" : "wallpaper.menu.pin")) {
            performListAction { try organization.setPinned(!allPinned, for: Set(wallpapers.map(\.id))) }
        })
        let allFavorite = wallpapers.allSatisfy(\.isFavorite)
        menu.addItem(WallpaperMenuActionItem(title: localized(allFavorite ? "wallpaper.menu.unfavorite" : "wallpaper.menu.favorite")) {
            do {
                for item in wallpapers { try library.setFavorite(!allFavorite, for: item.id) }
            } catch { showMessage(error.localizedDescription) }
        })

        let listItem = NSMenuItem(title: localized("wallpaper.menu.addToList"), action: nil, keyEquivalent: "")
        let listMenu = NSMenu()
        listMenu.addItem(WallpaperMenuActionItem(title: localized("lists.create.menu")) {
            beginCreateList(members: wallpapers.map(\.id))
        })
        listMenu.addItem(.separator())
        listMenu.addItem(listSectionHeading("lists.recent"))
        let recentLists = organization.lists.sorted {
            $0.updatedAt == $1.updatedAt ? $0.name < $1.name : $0.updatedAt > $1.updatedAt
        }.prefix(3)
        for list in recentLists {
            listMenu.addItem(WallpaperMenuActionItem(title: list.name) {
                performListAction { try organization.add(wallpapers.map(\.id), to: list.id) }
            })
        }
        listMenu.addItem(.separator())
        listMenu.addItem(listSectionHeading("lists.all"))
        for list in organization.lists {
            listMenu.addItem(WallpaperMenuActionItem(title: list.name) {
                performListAction { try organization.add(wallpapers.map(\.id), to: list.id) }
            })
        }
        menu.setSubmenu(listMenu, for: listItem)
        menu.addItem(listItem)

        menu.addItem(WallpaperMenuActionItem(title: localized("wallpaper.menu.share")) {
            let resources = wallpapers.map(\.resourceURL).filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !resources.isEmpty else { showMessage(localized("inspector.resourceMissing")); return }
            DispatchQueue.main.async {
                NSSharingServicePicker(items: resources).show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            }
        })
        menu.addItem(.separator())
        menu.addItem(WallpaperMenuActionItem(title: localized("wallpaper.menu.reveal")) {
            let resources = wallpapers.map(\.resourceURL).filter { FileManager.default.fileExists(atPath: $0.path) }
            if resources.isEmpty { showMessage(localized("inspector.resourceMissing")) }
            else { NSWorkspace.shared.activateFileViewerSelecting(resources) }
        })
        menu.addItem(.separator())
        let deleteItem = WallpaperMenuActionItem(title: localized("wallpaper.menu.delete")) {
            if isBatch { requestDeleteMany(wallpapers) }
            else { requestDelete(wallpaper) }
        }
        deleteItem.attributedTitle = NSAttributedString(
            string: deleteItem.title,
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.addItem(deleteItem)
        return menu
    }

    private func listSectionHeading(_ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: localized(key), action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        item.isEnabled = false
        return item
    }

    private func localized(_ key: String) -> String { NSLocalizedString(key, comment: "") }
    private func counted(_ key: String, _ count: Int) -> String {
        String(format: localized(key), count)
    }

    private func beginCreateList(members: [Wallpaper.ID] = []) {
        pendingListMembers = members
        isCreatingList = true
    }

    private func performListAction(_ action: () throws -> Void) {
        do { try action() }
        catch { showMessage(error.localizedDescription) }
    }

    private func renameList(_ list: WallpaperList) {
        let alert = NSAlert()
        alert.messageText = localized("lists.rename")
        let field = NSTextField(string: list.name)
        field.frame = NSRect(x: 0, y: 0, width: 270, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: localized("lists.save"))
        alert.addButton(withTitle: localized("lists.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            performListAction { try organization.renameList(list.id, name: field.stringValue) }
        }
    }

    private func confirmListDeletion(_ list: WallpaperList) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: localized("lists.delete.confirm"), list.name)
        alert.informativeText = localized("lists.delete.explanation")
        alert.addButton(withTitle: localized("lists.cancel"))
        let delete = alert.addButton(withTitle: localized("lists.delete"))
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        performListAction { try organization.deleteList(list.id) }
        if selectedListID == list.id { selectedListID = nil }
    }

    private func requestDeleteMany(_ wallpapers: [Wallpaper]) {
        guard !isConfirmingDeletion else { return }
        isConfirmingDeletion = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = counted("wallpaper.menu.batch.delete.confirm", wallpapers.count)
        alert.informativeText = localized("wallpaper.menu.batch.delete.explanation")
        alert.addButton(withTitle: localized("delete.confirm.cancel"))
        let delete = alert.addButton(withTitle: localized("delete.confirm.delete"))
        delete.hasDestructiveAction = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            isConfirmingDeletion = false
            guard response == .alertSecondButtonReturn else { return }
            WallpaperPreviewCoordinator.shared.stopAll()
            for wallpaper in wallpapers { deleteWallpaper(wallpaper.id) }
        }
        if let window = windowReference.window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else { finish(alert.runModal()) }
    }

    /// 右键菜单与 Backspace 共用的删除入口：先确认，再走唯一的删除流程。
    private func requestDelete(_ wallpaper: Wallpaper) {
        guard !isConfirmingDeletion else { return }
        isConfirmingDeletion = true
        WallpaperPreviewCoordinator.shared.stopAll()
        WallpaperDeletionConfirmation.present(for: wallpaper, in: windowReference.window) { confirmed in
            isConfirmingDeletion = false
            if confirmed { deleteWallpaper(wallpaper.id) }
        }
    }

    private func deleteWallpaper(_ id: Wallpaper.ID) {
        do {
            try WallpaperDeletionService(
                library: library,
                runtime: runtime,
                previewCoordinator: WallpaperPreviewCoordinator.shared
            ).delete(id)
            selection.remove(id)
            try organization.removeMissingReferences(validIDs: Set(library.wallpapers.map(\.id)))
        } catch {
            showMessage(error.localizedDescription)
        }
    }

    private func showMessage(_ text: String) {
        messageID = UUID()
        withAnimation(.easeOut(duration: 0.15)) { message = text }
    }

    private func revealInFinder(_ wallpaper: Wallpaper) {
        guard FileManager.default.fileExists(atPath: wallpaper.resourceURL.path) else {
            message = NSLocalizedString("inspector.resourceMissing", comment: "")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([wallpaper.resourceURL])
    }

    private func importVideo() async {
        guard !importing else { return }
        let panel = LocalImportPanel.makePanel()
        guard panel.runModal() == .OK else { return }
        activeImports += 1
        defer { activeImports -= 1 }
        reportImport(await importer.importItems(at: panel.urls))
    }

    private func importWebFolders() async {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("shell.import.web", comment: "")
        panel.message = NSLocalizedString("shell.import.webMessage", comment: "")
        panel.prompt = NSLocalizedString("import.panel.prompt", comment: "")
        panel.allowedContentTypes = [.folder]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        activeImports += 1
        defer { activeImports -= 1 }
        reportImport(await importer.importItems(at: panel.urls))
    }

    /// 1.0 Module 8：Finder 拖入主窗口松手后。与文件面板走同一条导入路径；不应用、不改变任何显示器、不切换页面。
    private func importDropped(_ urls: [URL]) {
        Task {
            activeImports += 1
            defer { activeImports -= 1 }
            reportImport(await importer.importItems(at: urls))
        }
    }

    /// 规格 8：导入只加入「本地」，不强制切换页面；新壁纸在当前页面可见时选中最新的一张。
    private func reportImport(_ outcomes: [LocalImportOutcome]) {
        let summary = LocalImportSummary(outcomes: outcomes)
        if let newest = summary.addedIDs.last, visibleWallpapers.contains(where: { $0.id == newest }) {
            selection.selectOnly(newest)
        }
        if let text = summary.message { showMessage(text) }
    }
}

private struct NewWallpaperListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var coverURL: URL?
    let onCreate: (String, String?, URL?) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.standard) {
            Text("lists.create.title")
                .font(.system(size: 20, weight: .semibold))
            Button { chooseCover() } label: {
                Group {
                    if let coverURL, let image = NSImage(contentsOf: coverURL) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Tokens.accent)
                    }
                }
                .frame(width: 116, height: 116)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.container, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.container, style: .continuous)
                        .strokeBorder(Tokens.accent, lineWidth: 1.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.container, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            TextField("lists.name", text: $name)
            TextField("lists.description", text: $description)
            HStack {
                Button("lists.cancel") { dismiss() }
                Spacer()
                Button("lists.create") {
                    if onCreate(name, description.isEmpty ? nil : description, coverURL) {
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Spacing.section)
        .frame(width: 360)
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { coverURL = panel.url }
    }
}

private struct WallpaperListFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct MarqueeExcludedFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct WallpaperCardFrameKey: PreferenceKey {
    static var defaultValue: [Wallpaper.ID: CGRect] = [:]

    static func reduce(value: inout [Wallpaper.ID: CGRect], nextValue: () -> [Wallpaper.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 固定主窗口的实际 Resize 下限，避免原生分栏把侧栏压到不可用。
private struct MainWindowMinimumSize: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> MinimumSizeView { MinimumSizeView() }

    func updateNSView(_ nsView: MinimumSizeView, context: Context) {
        nsView.minimumSize = NSSize(width: width, height: height)
        nsView.applyMinimumSize()
    }

    final class MinimumSizeView: NSView {
        var minimumSize = NSSize.zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyMinimumSize()
        }

        func applyMinimumSize() {
            guard let window, minimumSize != .zero else { return }
            window.contentMinSize = minimumSize
        }
    }
}

/// 1.0 Module 8：Finder 拖入主窗口时的反馈。系统 Liquid Glass 小卡片，不做大面积虚线拖放区。
private struct FinderDropFeedbackView: View {
    let evaluation: FinderDropEvaluation

    var body: some View {
        VStack(spacing: Tokens.Spacing.small) {
            Image(systemName: evaluation.symbol)
                .font(.system(size: Tokens.Spacing.large, weight: .light))
                .foregroundStyle(evaluation == .unsupported ? Color.secondary : Tokens.accent)
            Text(NSLocalizedString(evaluation.titleKey, comment: ""))
                .font(Tokens.Typography.emptyTitle)
            if case .importable(let count) = evaluation, count > 1 {
                Text(String(format: NSLocalizedString("drop.itemCount", comment: ""), count))
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Tokens.Spacing.large)
        .padding(.vertical, Tokens.Spacing.section)
        .kineticGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.container * 1.6, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// 主内容区顶部的状态提示：导入结果、错误等短消息，以及正在导入。只显示，不接收点击。
private struct StatusToastLayer: View {
    let message: String?
    let isImporting: Bool

    /// 提示的中心放在窗口上沿与页面标题之间；没有这条空间时（例如全屏）贴近顶部。
    static func centerY(topBand: CGFloat) -> CGFloat {
        topBand >= 24 ? topBand / 2 : Tokens.Spacing.standard + 4
    }

    var body: some View {
        Group {
            if let message {
                if message == NSLocalizedString("steam.store.added", comment: "") || message == NSLocalizedString("steam.store.updated", comment: "") {
                    toastText(message)
                        .padding(.horizontal, Tokens.Spacing.compact + 2)
                        .padding(.vertical, 5)
                        .kineticGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    toastText(message).toastCapsule()
                }
            } else if isImporting {
                HStack(spacing: Tokens.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                    Text("import.progress")
                        .font(Tokens.Typography.metadata)
                }
                .toastCapsule()
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: message)
        .animation(.easeOut(duration: 0.15), value: isImporting)
    }

    private func toastText(_ message: String) -> some View {
        Text(message).font(Tokens.Typography.metadata).lineLimit(1).truncationMode(.middle)
    }
}

private extension View {
    func toastCapsule() -> some View {
        padding(.horizontal, Tokens.Spacing.compact + 2)
            .padding(.vertical, 5)
            .kineticGlass(in: Capsule())
    }
}
