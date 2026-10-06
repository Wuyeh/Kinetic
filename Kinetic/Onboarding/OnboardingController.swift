import Combine
import Foundation

/// Module 20：引导是否已经完成。按资料库目录分别记录（Debug 验收资料库不影响正式资料库）。
struct OnboardingStore {
    static let storageKey = "Kinetic.Onboarding.v1"

    private let defaults: UserDefaults
    private let libraryKey: String

    init(defaults: UserDefaults = .standard, library: LibraryStorageLocation) {
        self.defaults = defaults
        libraryKey = library.rootURL.standardizedFileURL.path
    }

    var isCompleted: Bool {
        (defaults.dictionary(forKey: Self.storageKey)?[libraryKey] as? Bool) == true
    }

    func markCompleted() {
        var all = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        all[libraryKey] = true
        defaults.set(all, forKey: Self.storageKey)
    }
}

/// Module 20 — Onboarding。
/// 第一次启动且资料库为空时显示 Welcome（用户决定：已有壁纸的用户直接进入资料库）。
/// 「设置为壁纸」把演示**复制**进资料库（与本地导入相同），再通过 Runtime 公开的 `apply` 设置；
/// 完成后轻量提示已设置，并说明 Kinetic 会继续在菜单栏中运行。不修改 Runtime、资料库或导入规则。
@MainActor
final class OnboardingController: ObservableObject {
    enum DemoStatus: Equatable {
        case idle
        case applying
        case active
    }

    let demos: [OnboardingDemo]
    @Published private(set) var isWelcomeVisible: Bool
    /// 在引导中成功设置过壁纸：显示「已设置壁纸」提示。
    @Published private(set) var hasSetWallpaper = false
    @Published private(set) var applyingDemoID: String?
    /// 行内错误，例如：无法设置“极光”。
    @Published private(set) var errorMessage: String?
    /// 已复制进资料库的演示；再次点按时直接应用，不重复导入。
    @Published private(set) var importedWallpaperIDs: [String: Wallpaper.ID] = [:]

    private let store: OnboardingStore
    private let library: WallpaperLibrary
    private let importer: LocalImportService
    private let runtime: WallpaperRuntimeManager
    private var pendingWallpaperID: Wallpaper.ID?
    private var cancellables = Set<AnyCancellable>()

    init(store: OnboardingStore, library: WallpaperLibrary, importer: LocalImportService,
         runtime: WallpaperRuntimeManager, demos: [OnboardingDemo]) {
        self.store = store
        self.library = library
        self.importer = importer
        self.runtime = runtime
        self.demos = demos
        if !store.isCompleted, !library.wallpapers.isEmpty {
            // 资料库里已经有壁纸：不是新用户，不再显示引导。
            store.markCompleted()
        }
        isWelcomeVisible = !store.isCompleted && library.wallpapers.isEmpty && !demos.isEmpty

        runtime.$state
            .sink { [weak self] state in self?.runtimeStateChanged(state) }
            .store(in: &cancellables)
        runtime.$lastFailure
            .compactMap { $0 }
            .sink { [weak self] failure in self?.runtimeFailed(failure) }
            .store(in: &cancellables)
    }

    func status(of demo: OnboardingDemo) -> DemoStatus {
        if applyingDemoID == demo.id { return .applying }
        if let id = importedWallpaperIDs[demo.id], runtime.state.activeWallpaperID == id { return .active }
        return .idle
    }

    /// 「设置为壁纸」：第一次点按时复制进资料库，然后应用。同一时间只处理一个。
    func setAsWallpaper(_ demo: OnboardingDemo) async {
        guard applyingDemoID == nil, status(of: demo) != .active else { return }
        errorMessage = nil
        applyingDemoID = demo.id

        let wallpaper: Wallpaper
        if let id = importedWallpaperIDs[demo.id], let existing = library.wallpaper(id: id) {
            wallpaper = existing
        } else {
            // 1.0 Module 7：演示壁纸复制进本地资料库，来源记为 Kinetic 演示。
            guard var imported = await importer.importItem(at: demo.videoURL, origin: .bundledDemo).wallpaper else {
                fail(String(format: NSLocalizedString("onboarding.error", comment: ""), demo.name))
                return
            }
            // 资料库中使用演示的中文名，而不是包内文件名。
            imported.name = demo.name
            try? library.update(imported)
            importedWallpaperIDs[demo.id] = imported.id
            wallpaper = library.wallpaper(id: imported.id) ?? imported
        }
        pendingWallpaperID = wallpaper.id
        runtime.apply(wallpaper)
    }

    /// 「开始使用」或「跳过」：之后启动不再显示引导。
    func finish() {
        store.markCompleted()
        isWelcomeVisible = false
    }

    private func runtimeStateChanged(_ state: WallpaperRuntimeState) {
        objectWillChange.send()
        guard let pending = pendingWallpaperID, state.activeWallpaperID == pending else { return }
        pendingWallpaperID = nil
        applyingDemoID = nil
        hasSetWallpaper = true
    }

    private func runtimeFailed(_ failure: WallpaperRuntimeFailure) {
        guard failure.wallpaperID == pendingWallpaperID else { return }
        fail(failure.message)
    }

    private func fail(_ message: String) {
        pendingWallpaperID = nil
        applyingDemoID = nil
        errorMessage = message
    }
}
