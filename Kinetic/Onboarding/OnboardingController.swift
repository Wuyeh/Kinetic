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

    /// Module 56：设置演示壁纸，之后是一页「了解 Kinetic」。
    enum Phase: Equatable {
        case demos
        case tour
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
    @Published private(set) var phase: Phase = .demos
    /// Module 56：连着多台显示器时，等用户在选择窗口里选一台的演示。
    @Published private(set) var demoAwaitingDisplay: OnboardingDemo?

    private let store: OnboardingStore
    private let library: WallpaperLibrary
    private let importer: LocalImportService
    private let runtime: WallpaperRuntimeManager
    /// 正在设置的显示器与壁纸；只认这台显示器上的结果。
    private var pending: (display: DisplayID, wallpaperID: Wallpaper.ID)?
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

        runtime.$summary
            .sink { [weak self] summary in self?.runtimeSummaryChanged(summary) }
            .store(in: &cancellables)
        runtime.$lastFailure
            .compactMap { $0 }
            .sink { [weak self] failure in self?.runtimeFailed(failure) }
            .store(in: &cancellables)
    }

    /// 正在某台显示器上显示时为「使用中」。只有一台显示器时它不能再点；多台时还可以设到别的显示器。
    func status(of demo: OnboardingDemo) -> DemoStatus {
        if applyingDemoID == demo.id { return .applying }
        if let id = importedWallpaperIDs[demo.id], !runtime.summary.displays(showing: id).isEmpty {
            return runtime.displayIDs.count > 1 ? .idle : .active
        }
        return .idle
    }

    /// 选择窗口里的显示器（与资料库的「选择应用显示器」相同）。
    var displayItems: [DisplayTargetItem] {
        runtime.summary.displays.enumerated().map { index, display in
            DisplayTargetItem(display: display, index: index,
                              wallpaper: display.runtime.activeWallpaperID.flatMap { library.wallpaper(id: $0) })
        }
    }

    /// 「设置为壁纸」：只有一台显示器时直接设置；多台时先请用户选显示器（Module 56）。同一时间只处理一个。
    func setAsWallpaper(_ demo: OnboardingDemo) async {
        guard applyingDemoID == nil, demoAwaitingDisplay == nil else { return }
        errorMessage = nil
        let displays = runtime.displayIDs
        if displays.count > 1 {
            demoAwaitingDisplay = demo
            return
        }
        guard let display = displays.first else {
            errorMessage = NSLocalizedString("onboarding.noDisplay", comment: "")
            return
        }
        guard status(of: demo) != .active else { return }
        await setAsWallpaper(demo, on: display)
    }

    func chooseDisplay(_ display: DisplayID) async {
        guard let demo = demoAwaitingDisplay else { return }
        demoAwaitingDisplay = nil
        guard runtime.displayIDs.contains(display) else { return }
        await setAsWallpaper(demo, on: display)
    }

    func cancelDisplayChoice() { demoAwaitingDisplay = nil }

    private func setAsWallpaper(_ demo: OnboardingDemo, on display: DisplayID) async {
        guard applyingDemoID == nil else { return }
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
        pending = (display, wallpaper.id)
        // 这台显示器已经在显示它：Runtime 不会再发状态变化，直接算成功。
        if runtime.summary.displays(showing: wallpaper.id).contains(display) {
            succeed()
            return
        }
        runtime.apply(wallpaper, to: display)
    }

    /// 设置好壁纸后的「继续」：进入「了解 Kinetic」。
    func continueToTour() {
        demoAwaitingDisplay = nil
        phase = .tour
    }

    /// 「开始使用」或「跳过」：之后启动不再显示引导。
    func finish() {
        store.markCompleted()
        demoAwaitingDisplay = nil
        isWelcomeVisible = false
    }

    /// 帮助 › 显示欢迎页：从演示页重新开始；已复制进资料库的演示不会重复导入。
    func showAgain() {
        guard !demos.isEmpty else { return }
        phase = .demos
        hasSetWallpaper = false
        errorMessage = nil
        demoAwaitingDisplay = nil
        isWelcomeVisible = true
    }

    private func runtimeSummaryChanged(_ summary: RuntimeSummary) {
        objectWillChange.send()
        guard let pending, summary.displays(showing: pending.wallpaperID).contains(pending.display) else { return }
        succeed()
    }

    private func runtimeFailed(_ failure: WallpaperRuntimeFailure) {
        guard let pending, failure.wallpaperID == pending.wallpaperID, failure.displayID == pending.display else { return }
        fail(failure.message)
    }

    private func succeed() {
        pending = nil
        applyingDemoID = nil
        hasSetWallpaper = true
    }

    private func fail(_ message: String) {
        pending = nil
        applyingDemoID = nil
        errorMessage = message
    }
}
