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
                                         navigation: appDelegate.mainWindowNavigation,
                                         displayEditor: appDelegate.displayWallpaperEditor,
                                         settings: appDelegate.settingsStore,
                                         overlayMenu: appDelegate.displayOverlayMenu,
                                         overlays: appDelegate.displayOverlayEditors,
                                         organization: appDelegate.localOrganization,
                                         playlist: appDelegate.playlistPlayer,
                                         scheduler: appDelegate.scheduler,
                                         setup: appDelegate.setupStore,
                                         launchRecovery: appDelegate.launchRecovery)
                    }
                } else {
                    LibraryShellView(library: services.library, runtime: services.runtime, importer: services.importer,
                                     steam: services.steam, store: services.store, steamApply: services.steamApply,
                                     navigation: appDelegate.mainWindowNavigation,
                                     displayEditor: appDelegate.displayWallpaperEditor,
                                     settings: appDelegate.settingsStore,
                                     overlayMenu: appDelegate.displayOverlayMenu,
                                     overlays: appDelegate.displayOverlayEditors,
                                     organization: appDelegate.localOrganization,
                                     playlist: appDelegate.playlistPlayer,
                                     scheduler: appDelegate.scheduler,
                                     setup: appDelegate.setupStore,
                                         launchRecovery: appDelegate.launchRecovery)
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
        // 用户指定 Workshop 使用设置页同款手柄图标；沿用侧栏原有图标样式。
        case .steam: return SettingsSection.steam.symbol
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

/// R4 BUG-G1：一次指针手势归谁。按下时由起点决定，并在这次手势结束前保持不变；
/// 拖动途中经过空白、卡片间隙或覆盖层都不会改判。
enum ContentPointerOwner: Equatable {
    /// 卡片（Poster、预览、徽标、标题等）：交给卡片自己的点按 / 长按拖到显示器，父级不能开始框选。
    case card
    /// 搜索框、页眉、按钮等交互控件：不开始框选。
    case control
    /// 内容区空白：普通点按清除选择，拖动是框选。
    case blank

    static func resolve(_ point: CGPoint, cardFrames: [CGRect], controlFrames: [CGRect]) -> Self {
        if cardFrames.contains(where: { $0.contains(point) }) { return .card }
        if controlFrames.contains(where: { $0.contains(point) }) { return .control }
        return .blank
    }
}

/// 记住当前手势的起点与归属。系统取消手势时 onEnded 不一定执行，所以起点变化即视为新的手势。
struct ContentPointerGesture: Equatable {
    /// 小于这个距离的移动视为点按（与原框选阈值相同）。
    static let clickTolerance: CGFloat = 5

    private(set) var start: CGPoint?
    private(set) var owner: ContentPointerOwner?

    mutating func owner(startingAt point: CGPoint, resolve: () -> ContentPointerOwner) -> ContentPointerOwner {
        if start != point || owner == nil {
            start = point
            owner = resolve()
        }
        return owner ?? .control
    }

    mutating func end() {
        start = nil
        owner = nil
    }

    /// 只有空白起点、移动超过点按阈值、且没有正在进行的显示器拖动时才框选。
    static func allowsMarquee(owner: ContentPointerOwner, translation: CGSize, displayDragActive: Bool) -> Bool {
        owner == .blank && !displayDragActive && hypot(translation.width, translation.height) >= clickTolerance
    }

    /// 只有空白起点的点按（没有拖动）才清除选择。
    static func isBlankClick(owner: ContentPointerOwner, translation: CGSize) -> Bool {
        owner == .blank && hypot(translation.width, translation.height) < clickTolerance
    }
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
struct LibraryShellView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var runtime: WallpaperRuntimeManager
    @StateObject private var organization: LocalOrganizationStore
    let importer: LocalImportService
    let steam: SteamAcquisitionService?
    let store: SteamStoreService?
    let steamApply: SteamDisplayApplyCoordinator?
    let navigation: MainWindowNavigation
    let displayEditor: DisplayWallpaperEditor?
    let settings: SettingsStore?
    let overlayMenu: DisplayOverlayMenu?
    let overlays: DisplayOverlayEditors?
    /// Module 46：按显示器轮播壁纸列表（显示器页「轮播」栏）。
    let playlist: WallpaperPlaylistPlayer?
    /// Module 47：按显示器定时切换（显示器页「定时切换」栏）。
    let scheduler: WallpaperScheduler?
    /// Module 48：书签（显示器页壁纸选择浮窗）。
    let setup: SetupStore?
    /// Module 57：上次意外退出后暂不恢复的壁纸。
    var launchRecovery: LaunchRecovery? = nil
    private let pageStore: MainWindowPageStore

    @State private var section: ShellSection
    @State private var selection = StableCardSelection<Wallpaper.ID>()
    @State private var cardFrames: [Wallpaper.ID: CGRect] = [:]
    /// Steam 在线卡片的整张卡片范围（全局坐标），与本地卡片一样属于卡片起点。
    @State private var steamCardFrames: [String: CGRect] = [:]
    @State private var pointerGesture = ContentPointerGesture()
    /// R4 第 10–13 节：Floating Bar 控制的显示器。
    @State private var displayControl = FloatingBarDisplayControl()
    /// R4 第 23 节：Steam 在线页面的多选（创意工坊编号）。
    @State private var steamSelection = StableCardSelection<String>()
    /// 从 Steam 批量菜单「新建壁纸列表…」进入：列表创建后把这些项目下载并加入新列表。
    @State private var pendingSteamBatch: [SteamStoreItem]?
    /// R4 第 44–49 节：Steam 页的九组筛选与展开状态（本次运行内存中；首次进入杂项与风格展开）。
    @State private var steamFilters = SteamFilterState()
    @State private var steamSortMode = SteamWorkshopSortMode.recentlyPublished
    @State private var steamExpandedGroups = Set(SteamTagGroup.allCases.filter(\.isExpandedByDefault))
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingDisplayBubble = false
    @State private var marqueeExcludedFrames: [String: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var selectedListID: UUID?
    @State private var selectedDisplayID: DisplayID?
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
         navigation: MainWindowNavigation, displayEditor: DisplayWallpaperEditor? = nil,
         settings: SettingsStore? = nil, overlayMenu: DisplayOverlayMenu? = nil, overlays: DisplayOverlayEditors? = nil,
         organization: LocalOrganizationStore? = nil, playlist: WallpaperPlaylistPlayer? = nil,
         scheduler: WallpaperScheduler? = nil, setup: SetupStore? = nil, launchRecovery: LaunchRecovery? = nil) {
        _library = ObservedObject(wrappedValue: library)
        _runtime = ObservedObject(wrappedValue: runtime)
        // Module 46：轮播在主窗口关闭后也要读列表，所以 App 只保留一份列表数据，两处不会互相覆盖。
        _organization = StateObject(wrappedValue: organization ?? LocalOrganizationStore(storage: library.storage))
        self.importer = importer
        self.steam = steam
        self.store = store
        self.steamApply = steamApply
        self.navigation = navigation
        self.displayEditor = displayEditor
        self.settings = settings
        self.overlayMenu = overlayMenu
        self.overlays = overlays
        self.playlist = playlist
        self.scheduler = scheduler
        self.setup = setup
        self.launchRecovery = launchRecovery
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
            // 「列表顺序」（Module 46）按列表自己的顺序，也就是轮播顺序；其他排序不变。
            let wallpapers = options.sortMode == .listOrder
                ? list.wallpaperIDs.compactMap { library.wallpaper(id: $0) }
                : library.wallpapers.filter { members.contains($0.id) }
            return ContentQuery.apply(options, to: wallpapers, dateAdded: { list.addedAt($0.id) })
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
        .disabled(displayApply.isPresented || isCreatingList)
        .accessibilityHidden(displayApply.isPresented || isCreatingList)
        .frame(minWidth: Tokens.Window.minimumWidth, minHeight: Tokens.Window.minimumHeight)
        .background {
            MainWindowMinimumSize(width: Tokens.Window.minimumWidth, height: Tokens.Window.minimumHeight)
                .frame(width: 0, height: 0)
        }
        .background {
            DeleteKeyHandler(
                isEnabled: selectedDisplayID == nil && selectedWallpaper != nil && !isConfirmingDeletion
                    && !displayApply.isPresented && !isCreatingList
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
            synchronizeControlledDisplay(ids)
        }
        .onAppear { synchronizeControlledDisplay(runtime.summary.displays.map(\.displayID)) }
        .onChange(of: library.wallpapers.map(\.id)) { ids in
            if let id = displayApply.wallpaperID, !ids.contains(id) { displayApply.cancel() }
            if let id = localDrag.wallpaperID, !ids.contains(id) { cancelDisplayDrag() }
        }
        .onExitCommand { displayApply.cancel(); cancelDisplayDrag() }
        .onReceive(steamApply?.notices.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) {
            showMessage($0.message)
        }
        .onReceive(navigation.requests.compactMap { $0 }) { page in
            selectedDisplayID = nil
            selectedListID = nil
            section = page
            navigation.consume()
        }
        .onReceive(navigation.displayRequests.compactMap { $0 }) { display in
            selectedListID = nil
            selectedDisplayID = display
            cancelDisplayDrag()
            navigation.consumeDisplay()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelDisplayDrag()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === windowReference.window { cancelDisplayDrag() }
        }
        .onDisappear { cancelDisplayDrag() }
        .overlay {
            if isCreatingList {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { cancelCreateList() }
                    NewWallpaperListModal(onCancel: cancelCreateList) { name, description, cover in
                do {
                    let listID = try organization.createList(name: name, description: description,
                                                             coverSourceURL: cover, wallpaperIDs: pendingListMembers)
                    pendingListMembers = []
                    if let items = pendingSteamBatch {
                        pendingSteamBatch = nil
                        runSteamBatch(items, action: .addToList(id: listID, name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    isCreatingList = false
                    return true
                } catch {
                    showMessage(error.localizedDescription)
                    return false
                }
                    }
                }
                .zIndex(110)
            }
        }
        .onChange(of: section) { page in
            pageStore.save(page)
            cancelDisplayDrag()
            selection.clear()
            // 第 35 节：切换页面清除该页的多选，避免跨数据域。
            steamSelection.clear()
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
            ScrollView {
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

                    Text("显示器")
                        .font(Tokens.Typography.sidebarSection)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Tokens.Sidebar.horizontalInset + Tokens.Sidebar.itemHorizontalInset)
                        .padding(.top, Tokens.Sidebar.sectionTopInset)
                        .padding(.bottom, Tokens.Spacing.small)
                    ForEach(Array(runtime.summary.displays.enumerated()), id: \.element.id) { index, display in
                        displaySidebarRow(display, index: index)
                    }

                    Text("lists.sidebar.title")
                        .font(Tokens.Typography.sidebarSection)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Tokens.Sidebar.horizontalInset + Tokens.Sidebar.itemHorizontalInset)
                        .padding(.top, Tokens.Sidebar.sectionTopInset)
                        .padding(.bottom, Tokens.Spacing.small)

                LazyVStack(spacing: Tokens.Spacing.micro / 2) {
                    ForEach(organization.lists) { list in
                        listSidebarRow(list)
                    }
                }
                }
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: Tokens.Spacing.section)
            SidebarSettingsGear()
                .padding(.leading, Tokens.Sidebar.horizontalInset + Tokens.Sidebar.itemHorizontalInset)
                .padding(.bottom, Tokens.Spacing.standard)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Tokens.Sidebar.topInset)
        .overlay {
            WallpaperSecondaryClickSurface { view in
                let menu = NSMenu()
                menu.autoenablesItems = false
                if let native = NSApp.currentEvent?.locationInWindow,
                   let content = view.window?.contentView,
                   let point = Optional(CGPoint(x: native.x - content.bounds.minX,
                        y: content.isFlipped ? native.y - content.bounds.minY : content.bounds.maxY - native.y)),
                   let list = organization.lists.first(where: { listFrames[$0.id]?.contains(point) == true }) {
                    let item = WallpaperMenuActionItem(title: localized("lists.delete")) { confirmListDeletion(list) }
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemRed])
                    menu.addItem(item)
                } else {
                    menu.addItem(WallpaperMenuActionItem(title: localized("lists.create.menu")) { beginCreateList() })
                }
                return menu
            }
        }
        // 侧栏背景交给系统：macOS 26 起是悬浮的 Liquid Glass 侧栏。
    }

    private func sectionButton(_ item: ShellSection) -> some View {
        Button {
            selectedDisplayID = nil
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
                    .font(section == item && selectedDisplayID == nil ? Tokens.Typography.sidebarSelectedItem : Tokens.Typography.sidebarItem)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Sidebar.itemHorizontalInset)
            .frame(height: Tokens.Sidebar.rowHeight)
            .background {
                if section == item && selectedDisplayID == nil {
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
            selectedDisplayID = nil
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
        .frame(width: Tokens.Sidebar.iconSlotWidth, height: Tokens.Sidebar.iconSlotWidth)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.small, style: .continuous))
    }

    private var mainArea: some View {
        Group {
            if let selectedDisplayID, let displayEditor, let settings {
                ZStack(alignment: .bottom) {
                    DisplayControlPage(displayID: selectedDisplayID, editor: displayEditor,
                                       library: library, runtime: runtime, settings: settings,
                                       overlayMenu: overlayMenu, overlays: overlays,
                                       playlist: playlist, lists: organization, scheduler: scheduler, setup: setup)
                        .padding(.horizontal, Tokens.Content.horizontalInset)
                        .padding(.top, Tokens.Content.topInset)
                        .padding(.bottom, Tokens.FloatingToolbar.height + Tokens.FloatingToolbar.bottomInset + Tokens.Spacing.standard)
                    floatingToolbar.padding(.bottom, Tokens.FloatingToolbar.bottomInset)
                }
                .id(selectedDisplayID)
            } else {
                libraryArea
            }
        }
    }

    private var libraryArea: some View {
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
                            ContentHeader(title: selectedList?.name ?? section.title, options: contentOptionsBinding,
                                          steamFilters: section == .steam ? $steamFilters : nil,
                                          steamExpandedGroups: section == .steam ? $steamExpandedGroups : nil,
                                          steamSortMode: $steamSortMode,
                                          availableHeight: contentGeometry.size.height,
                                          showsListOrder: selectedList != nil)
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
                                sortMode: $steamSortMode,
                                filters: steamFilters,
                                availableWidth: max(0, contentGeometry.size.width - 2 * Tokens.Content.horizontalInset),
                                viewportHeight: contentGeometry.size.height,
                                showMessage: { showMessage($0) },
                                onDisplayDrag: handleSteamDisplayDrag,
                                selection: $steamSelection,
                                onBatchDownload: { runSteamBatch($0, action: .download) },
                                onContextMenu: { item, _ in steamContextMenu(for: item) },
                                onRestoreConditions: { query in
                                    // 停留过的页的筛选与类型；与当前相同时不会再次请求。
                                    steamFilters = query.filters
                                    if let key = contentScopeKey {
                                        let options = contentOptions[key] ?? ContentViewOptions()
                                        contentOptions[key] = ContentViewOptions(sortMode: options.sortMode, typeFilter: query.typeFilter)
                                    }
                                }
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
                            // R4 BUG-G1：按下时锁定归属；卡片起点（包括等待长按的阶段）永远不框选，
                            // 显示器拖动进行中也不绘制选择框、不改变选择。
                            let owner = pointerGesture.owner(startingAt: value.startLocation) { pointerOwner(at: value.startLocation) }
                            guard ContentPointerGesture.allowsMarquee(owner: owner, translation: value.translation,
                                                                      displayDragActive: isDisplayDragActive) else {
                                if isDisplayDragActive { clearMarquee() }
                                return
                            }
                            marqueeStart = value.startLocation
                            marqueeCurrent = value.location
                            if section == .steam {
                                steamSelection.replace(with: CardMarqueeSelection.intersectingIDs(
                                    from: value.startLocation, to: value.location, frames: steamCardFrames
                                ))
                            } else {
                                selection.replace(with: CardMarqueeSelection.intersectingIDs(
                                    from: value.startLocation, to: value.location, frames: cardFrames
                                ))
                            }
                        }
                        .onEnded { value in
                            let owner = pointerGesture.owner(startingAt: value.startLocation) { pointerOwner(at: value.startLocation) }
                            if ContentPointerGesture.isBlankClick(owner: owner, translation: value.translation),
                               !isDisplayDragActive {
                                if section == .steam { steamSelection.clear() } else { selection.clear() }
                            }
                            pointerGesture.end()
                            clearMarquee()
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
                .onPreferenceChange(SteamCardFrameKey.self) { steamCardFrames = $0 }
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
            } else if let launchRecovery {
                LaunchRecoveryNotice(recovery: launchRecovery)
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
        .overlay { SteamDownloadOverlay(presentation: downloadPresentation, steam: steam, posters: store?.posters) }
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
        // R4 第 54 节：只提高背景不透明度（× 1.5）：在 clear 玻璃上叠一层系统窗口底色，图标不受影响。
        .background {
            Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(FloatingBarBackground.fillOpacity))
                .allowsHitTesting(false)
        }
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
            // R4：停止、声音与播放 / 暂停一样只作用于受控显示器（controlledDisplayID）。
            Button { if let id = controlledDisplayID { runtime.stop(.display(id)) } } label: {
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
                if let id = controlledDisplayID { runtime.setAudioEnabled(!controlledAudioEnabled, on: id) }
            } label: {
                Image(systemName: controlledAudioEnabled ? "speaker.wave.2" : "speaker.slash")
                    .frame(width: Tokens.Spacing.section, height: Tokens.FloatingToolbar.stopButtonSize)
            }
            .disabled(controlledDisplayID == nil)
            .help(controlledAudioEnabled ? "shell.toolbar.mute" : "shell.toolbar.unmute")
            .accessibilityLabel(Text(LocalizedStringKey(controlledAudioEnabled ? "shell.toolbar.mute" : "shell.toolbar.unmute")))

            // R4 第 9、50 节：详情 / Info 在声音之后、显示器图标之前；只看受控显示器真正已生效的壁纸。
            Button { if let wallpaper = controlledActiveWallpaper { openDetails(.local(wallpaper)) } } label: {
                Image(systemName: "info.circle")
                    .frame(width: Tokens.Spacing.section, height: Tokens.FloatingToolbar.stopButtonSize)
                    .contentShape(Rectangle())
            }
            .disabled(controlledActiveWallpaper == nil)
            .help(controlledActiveWallpaper == nil ? localized("floatingBar.info.empty") : localized("floatingBar.info"))
            .accessibilityLabel(Text("floatingBar.info"))

            displayControlButton
        }
        .font(.system(size: Tokens.FloatingToolbar.iconSize, weight: .medium))
        .buttonStyle(.plain)
    }

    /// 受控显示器当前真正已生效的壁纸（暂停也算；正在准备的候选与已停止的不算）。
    private var controlledActiveWallpaper: Wallpaper? {
        guard let display = controlledDisplay, display.runtime.playbackState != .stopped,
              let id = display.runtime.activeWallpaperID else { return nil }
        return library.wallpaper(id: id) ?? runtime.activeWallpaper(on: display.displayID)
    }

    /// 打开独立详情窗口；不 Apply、不切换显示器、不改变播放 / 音频 / 选择，也不开始下载。
    private func openDetails(_ subject: WallpaperDetailsSubject) {
        WallpaperDetailsWindows.shared.show(subject, store: store)
    }

    /// R4 第 10 节：最右侧的显示器图标：#58BFDA 细线，无背景；点按弹出 Display Bubble。
    private var displayControlButton: some View {
        Button { isShowingDisplayBubble.toggle() } label: {
            Image(systemName: "display")
                .font(.system(size: Tokens.FloatingToolbar.iconSize, weight: .light))
                .foregroundStyle(Tokens.accent)
                .frame(width: Tokens.Spacing.section, height: Tokens.FloatingToolbar.stopButtonSize)
                .contentShape(Rectangle())
        }
        .help(controlledDisplayName.map { String(format: localized("floatingBar.display.current"), $0) } ?? "")
        .accessibilityLabel(Text("floatingBar.display.button"))
        .accessibilityValue(Text(verbatim: controlledDisplayName ?? ""))
        .popover(isPresented: $isShowingDisplayBubble, arrowEdge: .top) {
            FloatingBarDisplayBubble(
                hostName: FloatingBarDisplayBubble.computerName ?? localized("floatingBar.display.thisMac"),
                status: controlledDisplay.map { FloatingBarDisplayRow.statusText($0.runtime.playbackState) } ?? "",
                rows: displayTargets.map { item in
                    FloatingBarDisplayRow(item: item,
                                          state: runtime.summary.state(of: item.id) ?? WallpaperRuntimeState(),
                                          isControlled: item.id == controlledDisplayID)
                },
                onSelect: { id in
                    // 只改变 Floating Bar 的控制对象：不更换壁纸、不 Crossfade、不修改分配。
                    displayControl.select(id, displayIDs: runtime.summary.displays.map(\.displayID))
                    isShowingDisplayBubble = false
                }
            )
            .environment(\.locale, Locale(identifier: "zh-Hans"))
        }
    }

    /// R4：Floating Bar 只看受控显示器的会话（只有一台显示器时与原来的汇总相同）。
    private var toolbarState: FloatingToolbarState {
        FloatingToolbarState(display: controlledDisplay, isInLibrary: { library.wallpaper(id: $0) != nil })
    }

    private var controlledDisplayID: DisplayID? { controlledDisplay?.displayID }

    private var controlledDisplay: DisplayRuntimeState? {
        runtime.summary.displays.first { $0.displayID == displayControl.controlledDisplayID }
    }

    private var controlledDisplayName: String? {
        displayTargets.first { $0.id == controlledDisplayID }?.name
    }

    private var controlledAudioEnabled: Bool {
        controlledDisplayID.map { runtime.isAudioEnabled(on: $0) } ?? runtime.isAudioEnabled
    }

    /// 受控显示器断开时改为控制主屏并轻量提示；不移动任何壁纸，原显示器重连后不抢回。
    private func synchronizeControlledDisplay(_ ids: [DisplayID]) {
        let hadControlled = displayControl.controlledDisplayID != nil
        guard let fallback = displayControl.synchronize(displayIDs: ids), hadControlled else { return }
        isShowingDisplayBubble = false
        if let name = displayTargets.first(where: { $0.id == fallback })?.name {
            showMessage(String(format: localized("floatingBar.display.switched"), name))
        }
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
        guard let display = controlledDisplayID else { return }
        FloatingToolbarState.perform(toolbarState.playbackAction, on: runtime, display: display,
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

    private func pointerOwner(at point: CGPoint) -> ContentPointerOwner {
        // 只使用当前页面的卡片：切换页面后另一页留下的范围不能把空白误判为卡片。
        let cards = section == .steam ? Array(steamCardFrames.values) : Array(cardFrames.values)
        return ContentPointerOwner.resolve(point, cardFrames: cards, controlFrames: Array(marqueeExcludedFrames.values))
    }

    private var isDisplayDragActive: Bool { localDrag.wallpaperID != nil || steamDrag.item != nil }

    private func clearMarquee() {
        marqueeStart = nil
        marqueeCurrent = nil
    }

    private func marqueeExclusionFrame(_ key: String) -> some View {
        MarqueeExclusionFrame(key: key)
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
        pointerGesture.end()
        clearMarquee()
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
            if let (item, display) = destination {
                downloadPresentation.register(.init(item: item, posterURL: steamDrag.posterURL ?? store?.posters.cachedURL(for: item)))
                steamApply.request(item.acquisitionInfo, to: display)
            }
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
        // R4 第 1、19、50 节：详情只在明确选择后打开，只看本次被辅助点按的这一张，不改变已保留的选择。
        // 按 9/25 的规定单选与多选菜单相同，不另设带数量或不同措辞的批量项。
        menu.addItem(WallpaperMenuActionItem(title: localized("wallpaper.menu.details")) {
            openDetails(.local(wallpaper))
        })
        menu.addItem(.separator())
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
        // Module 46：只在壁纸列表页面出现；只移出这个列表，壁纸本身不删除。
        if let list = selectedList {
            menu.addItem(WallpaperMenuActionItem(title: localized("lists.removeFromList")) {
                performListAction { try organization.remove(Set(wallpapers.map(\.id)), from: list.id) }
            })
        }

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

    /// R4 第 19、24 节：Steam 卡片的辅助点按菜单。已选卡片且多选 → 动作作用于全部所选；未选卡片 → 只选它。
    /// 按用户 9/25 的规定，单选与多选是同一个菜单，不显示数量；「查看详情…」只看被点按的这一张。
    private func steamContextMenu(for item: SteamStoreItem) -> NSMenu {
        if !steamSelection.contains(item.workshopID) { steamSelection.selectOnly(item.workshopID) }
        let selected = (store?.items ?? []).filter { steamSelection.contains($0.workshopID) }
        let items = selected.count > 1 ? selected : [item]
        let menu = NSMenu()
        menu.autoenablesItems = false
        let plan = SteamCardMenuPlan.entries(
            allTargetsLocal: items.allSatisfy { library.wallpaper(workshopID: $0.workshopID) != nil })
        for entry in plan {
            let title = SteamCardMenuPlan.title(entry)
            switch entry {
            case .details:
                menu.addItem(WallpaperMenuActionItem(title: title) { openDetails(.steam(item)) })
            case .separator:
                menu.addItem(.separator())
            case .download:
                menu.addItem(WallpaperMenuActionItem(title: title) { runSteamBatch(items, action: .download) })
            case .inLibrary:
                let inLibrary = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                inLibrary.isEnabled = false
                menu.addItem(inLibrary)
            case .addToList:
                let listItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menu.setSubmenu(steamListMenu(for: items), for: listItem)
                menu.addItem(listItem)
            case .favorite:
                menu.addItem(WallpaperMenuActionItem(title: title) { runSteamBatch(items, action: .favorite) })
            }
        }
        return menu
    }

    /// 「添加到壁纸列表」子菜单：新建壁纸列表…、最近使用、全部列表（与本地菜单相同的结构）。
    private func steamListMenu(for items: [SteamStoreItem]) -> NSMenu {
        let listMenu = NSMenu()
        listMenu.addItem(WallpaperMenuActionItem(title: localized("lists.create.menu")) {
            pendingSteamBatch = items
            beginCreateList()
        })
        guard !organization.lists.isEmpty else { return listMenu }
        let recent = organization.lists.sorted {
            $0.updatedAt == $1.updatedAt ? $0.name < $1.name : $0.updatedAt > $1.updatedAt
        }.prefix(3)
        listMenu.addItem(.separator())
        listMenu.addItem(listSectionHeading("lists.recent"))
        for list in recent {
            listMenu.addItem(WallpaperMenuActionItem(title: list.name) {
                runSteamBatch(items, action: .addToList(id: list.id, name: list.name))
            })
        }
        listMenu.addItem(.separator())
        listMenu.addItem(listSectionHeading("lists.all"))
        for list in organization.lists {
            listMenu.addItem(WallpaperMenuActionItem(title: list.name) {
                runSteamBatch(items, action: .addToList(id: list.id, name: list.name))
            })
        }
        return listMenu
    }

    /// 批量（或单项）Steam 动作：在线项目先下载入库，再加入列表 / 喜爱；绝不应用，完成后保留选择并显示真实结果。
    private func runSteamBatch(_ items: [SteamStoreItem], action: SteamBatchTransaction.Action) {
        guard let steam, !items.isEmpty else { return }
        let posters = store?.posters
        let transaction = SteamBatchTransaction(steam: steam, library: library, organization: organization,
                                                presentation: downloadPresentation,
                                                posterURL: { posters?.cachedURL(for: $0) },
                                                reduceMotion: reduceMotion)
        Task {
            let summary = await transaction.run(items, action: action)
            // 单项下载沿用原来的提示文字。
            if items.count == 1, action == .download, summary.downloaded == 1, summary.totalFailed == 0 {
                showMessage(localized("steam.store.added"))
            } else if items.count == 1, action == .download, summary.alreadyLocal == 1 {
                showMessage(localized("steam.store.inLibrary"))
            } else if !summary.message.isEmpty {
                showMessage(summary.message)
            }
        }
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

    private func cancelCreateList() {
        isCreatingList = false
        pendingListMembers = []
        pendingSteamBatch = nil
    }

    private func displaySidebarRow(_ display: DisplayRuntimeState, index: Int) -> some View {
        Button {
            selectedListID = nil
            selectedDisplayID = display.id
            cancelDisplayDrag()
        } label: {
            HStack(spacing: Tokens.Sidebar.iconTextGap) {
                Image(systemName: DisplayControlPresentation.symbol(for: display.id))
                    .font(.system(size: Tokens.Sidebar.iconSize, weight: .regular))
                    .foregroundStyle(Tokens.accent)
                    .frame(width: Tokens.Sidebar.iconSlotWidth)
                Text(DisplayControlPresentation.name(display, index: index))
                    .font(selectedDisplayID == display.id ? Tokens.Typography.sidebarSelectedItem : Tokens.Typography.sidebarItem)
                    .foregroundStyle(Color.primary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Sidebar.itemHorizontalInset)
            .frame(height: Tokens.Sidebar.rowHeight)
            .background {
                if selectedDisplayID == display.id {
                    RoundedRectangle(cornerRadius: Tokens.Radius.medium, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Tokens.Sidebar.horizontalInset)
        .padding(.vertical, Tokens.Spacing.micro / 2)
        .accessibilityAddTraits(selectedDisplayID == display.id ? .isSelected : [])
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
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertSecondButtonReturn else { return }
            performListAction { try organization.deleteList(list.id) }
            if selectedListID == list.id && !organization.lists.contains(where: { $0.id == list.id }) {
                selectedListID = nil
                selectedDisplayID = nil
                section = .local
            }
        }
        if let window = windowReference.window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else { finish(alert.runModal()) }
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

struct NewWallpaperListModal: View {
    @State private var name = ""
    @State private var description = ""
    @State private var coverURL: URL?
    @FocusState private var titleFocused: Bool
    let onCancel: () -> Void
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("选择壁纸列表海报")
            TextField("壁纸列表标题", text: $name).focused($titleFocused)
            TextField("lists.description", text: $description)
            HStack {
                Button("lists.cancel", action: onCancel).kineticGlassButton()
                Spacer()
                Button("lists.create") {
                    if onCreate(name, description.isEmpty ? nil : description, coverURL) {
                        onCancel()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                .displayControlPrimaryButton(isEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Tokens.Spacing.section)
        .frame(width: 360)
        .kineticGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.container, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { }
        .onExitCommand(perform: onCancel)
        .onAppear { titleFocused = true }
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

/// 内容区中不能开始框选的交互控件（全局坐标）。
struct MarqueeExcludedFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 放在控件的 background 中：报告它的全局范围，起点在这里的拖动不会开始框选。
struct MarqueeExclusionFrame: View {
    let key: String
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: MarqueeExcludedFrameKey.self, value: [key: proxy.frame(in: .global)])
        }
        .allowsHitTesting(false)
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
