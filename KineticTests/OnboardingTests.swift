import AppKit
import XCTest
@testable import Kinetic

/// Module 20：首次启动引导（Welcome、演示壁纸、第一次设置、结束提示）。
@MainActor
final class OnboardingTests: XCTestCase {
    private var suites: [String] = []
    private var roots: [URL] = []

    override func tearDown() async throws {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suites = []
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
    }

    // MARK: 测试环境

    @MainActor
    private final class RecordingRenderer: WallpaperRenderer {
        let wallpaper: Wallpaper
        let displayView = NSView()
        var onFailure: (@MainActor (Error) -> Void)?
        let failure: Error?
        init(wallpaper: Wallpaper, failure: Error?) {
            self.wallpaper = wallpaper
            self.failure = failure
        }
        func prepare() async throws { if let failure { throw failure } }
        func play() {}
        func pause() {}
        func resume() {}
        func setMuted(_ muted: Bool) {}
        func dispose() {}
    }

    @MainActor
    private final class StubDesktop: DesktopContentHost {
        func present(_ contentView: NSView) -> Bool { true }
        func stop() {}
    }

    private struct PrepareError: LocalizedError {
        var errorDescription: String? { "解码失败" }
    }

    private struct Environment {
        let library: WallpaperLibrary
        let importer: LocalImportService
        let runtime: WallpaperRuntimeManager
        let store: OnboardingStore
    }

    private func environment(failingRenderer: Bool = false) throws -> Environment {
        let suite = "KineticTests.Onboarding.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticOnboarding-\(UUID().uuidString)")
        roots.append(root)
        let storage = LibraryStorageLocation(rootURL: root)
        let library = WallpaperLibrary(storage: storage)
        let runtime = WallpaperRuntimeManager(desktop: StubDesktop()) { wallpaper in
            RecordingRenderer(wallpaper: wallpaper, failure: failingRenderer ? PrepareError() : nil)
        }
        return Environment(library: library, importer: LocalImportService(library: library), runtime: runtime,
                           store: OnboardingStore(defaults: defaults, library: storage))
    }

    private func controller(_ env: Environment, demos: [OnboardingDemo]) -> OnboardingController {
        OnboardingController(store: env.store, library: env.library, importer: env.importer,
                             runtime: env.runtime, demos: demos)
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func fixtureDemos() throws -> [OnboardingDemo] {
        [
            OnboardingDemo(id: "blue", name: "蓝色演示", videoURL: try fixture("loop", "mp4"), posterURL: nil),
            OnboardingDemo(id: "warm", name: "暖色演示", videoURL: try fixture("loop-warm", "mp4"), posterURL: nil)
        ]
    }

    /// 异步测试中挂起等待，让 Runtime 在主线程上的准备任务得以执行（不能用 RunLoop 空转）。
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5, step: TimeInterval = 0.01) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
    }

    // MARK: 演示壁纸

    /// 规格：Demo 随 App Bundle 提供、不依赖网络；用户决定三个视频演示。
    func testThreeBundledDemosArePlayableVideosWithPosters() async throws {
        let demos = OnboardingDemoCatalog.bundled()
        XCTAssertEqual(demos.map(\.id), ["aurora", "dawn", "drift"])
        XCTAssertEqual(demos.map(\.name), ["极光", "晨霞", "浮光"])
        let bundle = Bundle.main.bundleURL.standardizedFileURL.path
        for demo in demos {
            XCTAssertTrue(demo.videoURL.standardizedFileURL.path.hasPrefix(bundle), "\(demo.id) 应在 App 包内")
            let poster = try XCTUnwrap(demo.posterURL, "\(demo.id) 缺少缩略图")
            XCTAssertNotNil(NSImage(contentsOf: poster))
            try await LocalImportService.validateVideo(at: demo.videoURL)
            XCTAssertTrue(LivePreviewEligibility.canLivePreview(demo.previewWallpaper), "\(demo.id) 应可悬停预览")
        }
        XCTAssertEqual(Set(demos.map { $0.previewWallpaper.id }).count, 3)
        XCTAssertEqual(demos[0].previewWallpaper.id, OnboardingDemo.previewID(for: "aurora"), "标识稳定")
    }

    // MARK: 何时显示

    func testWelcomeAppearsOnFirstLaunchWithEmptyLibrary() throws {
        let env = try environment()
        let onboarding = controller(env, demos: try fixtureDemos())
        XCTAssertTrue(onboarding.isWelcomeVisible)
        XCTAssertFalse(env.store.isCompleted)
    }

    /// 用户决定：资料库里已有壁纸的用户直接进入资料库，之后也不再出现引导。
    func testExistingLibraryGoesStraightToTheLibrary() throws {
        let env = try environment()
        try env.library.add(Wallpaper(name: "雨夜", type: .video, source: .local,
                                      resourceURL: env.library.storage.rootURL.appendingPathComponent("rain.mp4")))
        let onboarding = controller(env, demos: try fixtureDemos())
        XCTAssertFalse(onboarding.isWelcomeVisible)
        XCTAssertTrue(env.store.isCompleted)
    }

    func testSkipShowsTheLibraryAndIsRemembered() throws {
        let env = try environment()
        let onboarding = controller(env, demos: try fixtureDemos())
        onboarding.finish()
        XCTAssertFalse(onboarding.isWelcomeVisible)
        XCTAssertTrue(env.library.wallpapers.isEmpty, "跳过不添加任何壁纸，资料库显示空状态")
        XCTAssertFalse(controller(env, demos: try fixtureDemos()).isWelcomeVisible, "下次启动不再显示")
    }

    func testNoWelcomeWithoutBundledDemos() throws {
        let env = try environment()
        let onboarding = controller(env, demos: [])
        XCTAssertFalse(onboarding.isWelcomeVisible)
        XCTAssertFalse(env.store.isCompleted, "演示缺失时不当作已完成")
    }

    func testCompletionIsRecordedPerLibrary() throws {
        let suite = "KineticTests.Onboarding.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let product = OnboardingStore(defaults: defaults, library: LibraryStorageLocation(rootURL: URL(fileURLWithPath: "/tmp/a")))
        let acceptance = OnboardingStore(defaults: defaults, library: LibraryStorageLocation(rootURL: URL(fileURLWithPath: "/tmp/b")))
        acceptance.markCompleted()
        XCTAssertTrue(acceptance.isCompleted)
        XCTAssertFalse(product.isCompleted)
    }

    // MARK: 设置为壁纸

    /// 点「设置为壁纸」：演示被复制进资料库（使用中文名），立即成为桌面壁纸，然后出现「已设置壁纸」提示。
    func testSetAsWallpaperCopiesTheDemoAndAppliesIt() async throws {
        let env = try environment()
        let demos = try fixtureDemos()
        let onboarding = controller(env, demos: demos)
        let blue = demos[0], warm = demos[1]
        let sourceSize = try FileManager.default.attributesOfItem(atPath: blue.videoURL.path)[.size] as? Int

        await onboarding.setAsWallpaper(blue)
        await waitUntil { onboarding.hasSetWallpaper }
        XCTAssertTrue(onboarding.hasSetWallpaper)
        XCTAssertNil(onboarding.applyingDemoID)
        XCTAssertNil(onboarding.errorMessage)
        XCTAssertEqual(env.library.wallpapers.count, 1)
        let imported = try XCTUnwrap(env.library.wallpapers.first)
        XCTAssertEqual(imported.name, "蓝色演示")
        XCTAssertEqual(imported.type, .video)
        XCTAssertEqual(imported.source, .local)
        XCTAssertEqual(imported.acquisitionOrigin, .bundledDemo, "Bundled demos keep their origin in Local")
        XCTAssertTrue(imported.resourceURL.standardizedFileURL.path
            .hasPrefix(env.library.storage.wallpapersDirectoryURL.standardizedFileURL.path), "复制进 Library Storage")
        XCTAssertNotNil(imported.thumbnailURL)
        XCTAssertEqual(env.runtime.state.activeWallpaperID, imported.id)
        XCTAssertEqual(env.runtime.state.playbackState, .playing)
        XCTAssertEqual(onboarding.status(of: blue), .active)
        XCTAssertEqual(onboarding.status(of: warm), .idle)
        XCTAssertTrue(onboarding.isWelcomeVisible, "提示显示后由用户点「开始使用」进入资料库")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: blue.videoURL.path)[.size] as? Int, sourceSize,
                       "App 包内的演示没有被改动")

        // 换另一个演示：再复制一份并切换。
        await onboarding.setAsWallpaper(warm)
        await waitUntil { env.runtime.state.activeWallpaperID != imported.id }
        XCTAssertEqual(env.library.wallpapers.count, 2)
        XCTAssertEqual(onboarding.status(of: warm), .active)
        XCTAssertEqual(onboarding.status(of: blue), .idle)

        // 再点回第一个：直接应用已复制的那份，不重复导入。
        await onboarding.setAsWallpaper(blue)
        await waitUntil { env.runtime.state.activeWallpaperID == imported.id }
        XCTAssertEqual(env.library.wallpapers.count, 2)
        XCTAssertEqual(onboarding.status(of: blue), .active)

        onboarding.finish()
        XCTAssertFalse(onboarding.isWelcomeVisible)
        XCTAssertFalse(controller(env, demos: demos).isWelcomeVisible)
    }

    func testUnplayableDemoShowsAnInlineErrorAndChangesNothing() async throws {
        let env = try environment()
        let broken = OnboardingDemo(id: "broken", name: "坏视频", videoURL: try fixture("corrupt", "mp4"), posterURL: nil)
        let onboarding = controller(env, demos: [broken])

        await onboarding.setAsWallpaper(broken)
        XCTAssertEqual(onboarding.errorMessage, "无法设置“坏视频”。")
        XCTAssertNil(onboarding.applyingDemoID)
        XCTAssertFalse(onboarding.hasSetWallpaper)
        XCTAssertTrue(env.library.wallpapers.isEmpty)
        XCTAssertNil(env.runtime.state.activeWallpaperID)
        XCTAssertEqual(onboarding.status(of: broken), .idle, "可以再试一次")
    }

    func testRendererFailureIsReportedInline() async throws {
        let env = try environment(failingRenderer: true)
        let demos = try fixtureDemos()
        let onboarding = controller(env, demos: demos)

        await onboarding.setAsWallpaper(demos[0])
        await waitUntil { onboarding.errorMessage != nil }
        XCTAssertEqual(onboarding.errorMessage, "无法加载“蓝色演示”。")
        XCTAssertNil(onboarding.applyingDemoID)
        XCTAssertFalse(onboarding.hasSetWallpaper)
        XCTAssertNil(env.runtime.state.activeWallpaperID)
    }

    /// 同一时间只处理一个演示：准备期间再点其他演示不会叠加请求。
    func testOnlyOneDemoIsSetAtATime() async throws {
        let env = try environment()
        let demos = try fixtureDemos()
        let onboarding = controller(env, demos: demos)

        let first = Task { await onboarding.setAsWallpaper(demos[0]) }
        await waitUntil({ onboarding.applyingDemoID != nil || onboarding.hasSetWallpaper }, step: 0.001)
        XCTAssertEqual(onboarding.applyingDemoID, "blue")
        await onboarding.setAsWallpaper(demos[1])
        await first.value
        await waitUntil { onboarding.hasSetWallpaper }
        XCTAssertEqual(env.library.wallpapers.map(\.name), ["蓝色演示"])
    }
}
