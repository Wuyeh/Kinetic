import AppKit
import XCTest
@testable import Kinetic

@MainActor
final class MultiDisplayCoreTests: XCTestCase {
    @MainActor private final class Screens { var values: [DisplayDescriptor] = [] }
    @MainActor private final class Host: DesktopContentHost {
        var content: NSView?
        var stops = 0
        var realigns = 0
        var resolved: DesktopDisplay?
        func present(_ view: NSView) -> Bool { content = view; return true }
        func stop() { content = nil; stops += 1 }
    }
    @MainActor private final class Renderer: WallpaperRenderer {
        let wallpaper: Wallpaper
        let displayView = NSView()
        var onFailure: (@MainActor (Error) -> Void)?
        var muted = true
        var disposed = false
        var playing = false
        var delay = false
        var continuation: CheckedContinuation<Void, Error>?
        init(_ wallpaper: Wallpaper) { self.wallpaper = wallpaper }
        func prepare() async throws {
            if delay { try await withCheckedThrowingContinuation { continuation = $0 } }
        }
        func play() { playing = true }
        func pause() { playing = false }
        func resume() { playing = true }
        func setMuted(_ muted: Bool) { self.muted = muted }
        func dispose() {
            disposed = true; playing = false
            let pending = continuation; continuation = nil
            pending?.resume(throwing: CancellationError())
        }
    }
    @MainActor private final class Harness {
        let screens = Screens()
        let appNotifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        let defaults: UserDefaults
        let suite = "Kinetic.MultiDisplayCoreTests.\(UUID().uuidString)"
        let root: URL
        let library: WallpaperLibrary
        let store: DisplayAssignmentStore
        let legacy: WallpaperRestorationStore
        var made: [Renderer] = []
        var hosts: [DisplayID: Host] = [:]
        var delayedIDs: Set<Wallpaper.ID> = []
        lazy var registry = DisplayRegistry(discover: { [weak self] in self?.screens.values ?? [] },
                                            applicationNotifications: appNotifications, workspaceNotifications: workspaceNotifications)
        lazy var runtime = WallpaperRuntimeManager { [unowned self] wallpaper in
            let renderer = Renderer(wallpaper); renderer.delay = self.delayedIDs.contains(wallpaper.id)
            self.made.append(renderer); return renderer
        }
        lazy var controller = newController()
        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            root = TestWorkspaceDirectory.make(".build/DisplayCoreTests")
            library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root))
            store = DisplayAssignmentStore(defaults: defaults, library: library.storage)
            legacy = WallpaperRestorationStore(defaults: defaults, library: library.storage)
        }
        func newController() -> MultiDisplayController {
            MultiDisplayController(registry: registry, runtime: runtime, library: library, store: store, legacy: legacy,
                                   makeSurface: { [unowned self] id, resolve in
                let host = Host(); self.hosts[id] = host
                return .init(host: host, realign: { host.realigns += 1; host.resolved = resolve() })
            })
        }
        func add(_ name: String, type: WallpaperType = .video) throws -> Wallpaper {
            let wallpaper = Wallpaper(name: name, type: type, source: .local, resourceURL: root.appendingPathComponent(name + ".mp4"))
            try library.add(wallpaper); return wallpaper
        }
        func connect(_ values: [DisplayDescriptor]) { screens.values = values; registry.refresh() }
        func cleanup() {
            controller.stopRecording(); runtime.shutdown(); controller.closeSurfaces()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
    private let a = DisplayID("display-test-A"), b = DisplayID("display-test-B"), c = DisplayID("display-test-C")
    private func display(_ id: DisplayID, direct: UInt32 = 1, width: CGFloat = 1000, scale: CGFloat = 2,
                         persistent: Bool = true) -> DisplayDescriptor {
        .init(id: id, name: "屏幕 " + id.rawValue, desktop: .init(id: direct, frame: CGRect(x: 0, y: 0, width: width, height: 600),
                                                              backingScaleFactor: scale), isPersistent: persistent)
    }
    private func settle() async { try? await Task.sleep(nanoseconds: 25_000_000) }

    func testDisconnectReleasesOnlyThatRendererAndReconnectUsesStableID() async throws {
        let h = try Harness(); defer { h.cleanup() }
        h.screens.values = [display(a), display(b, direct: 2)]; h.controller.start()
        let rain = try h.add("Rain"), sea = try h.add("Sea")
        h.runtime.apply(rain, to: a); h.runtime.apply(sea, to: b); await settle()
        let oldA = h.made[0], oldB = h.made[1], hostB = h.hosts[b]
        h.connect([display(b, direct: 2)])
        XCTAssertTrue(oldA.disposed); XCTAssertFalse(oldB.disposed)
        XCTAssertEqual(h.runtime.activeWallpaper(on: b)?.id, sea.id)
        XCTAssertTrue(h.hosts[b] === hostB)
        XCTAssertEqual(h.store.load().assignments[a.rawValue]?.wallpaperID, rain.id)
        h.connect([display(b, direct: 2), display(c, direct: 3)])
        await settle()
        XCTAssertNil(h.runtime.activeWallpaper(on: c)); XCTAssertEqual(h.made.count, 2, "陌生设备保持原生壁纸")
        h.connect([display(b, direct: 2), display(c, direct: 3), display(a, direct: 99)])
        await settle()
        XCTAssertEqual(h.runtime.activeWallpaper(on: a)?.id, rain.id, "连接号变化不影响稳定 ID")
        XCTAssertEqual(h.made.count, 3); XCTAssertFalse(oldB.disposed)
    }

    func testReconnectInheritsCurrentGlobalPauseSmartPauseAndAudio() async throws {
        let h = try Harness(); defer { h.cleanup() }
        h.screens.values = [display(a), display(b)]; h.controller.start()
        h.runtime.apply(try h.add("Rain"), to: a); await settle()
        h.connect([display(b)])
        h.runtime.pause(); h.runtime.setSmartPauseActive(true); h.runtime.setAudioEnabled(true)
        h.connect([display(a), display(b)]); await settle()
        XCTAssertEqual(h.runtime.state(of: a)?.playbackState, .manualPaused)
        XCTAssertFalse(h.made.last!.playing); XCTAssertFalse(h.made.last!.muted)
        h.runtime.resume()
        XCTAssertEqual(h.runtime.state(of: a)?.playbackState, .smartPaused)
        h.runtime.setSmartPauseActive(false)
        XCTAssertEqual(h.runtime.state(of: a)?.playbackState, .playing)
    }

    func testPerDisplayPauseDoesNotChangeDisconnectedOtherAssignment() async throws {
        let h = try Harness(); defer { h.cleanup() }
        h.screens.values = [display(a), display(b)]; h.controller.start()
        h.runtime.apply(try h.add("Rain"), to: a); h.runtime.apply(try h.add("Sea"), to: b); await settle()
        h.connect([display(b)]); h.runtime.pause(.display(b))
        h.connect([display(a), display(b)]); await settle()
        XCTAssertEqual(h.runtime.state(of: a)?.playbackState, .playing)
        XCTAssertEqual(h.runtime.state(of: b)?.playbackState, .manualPaused)
        h.connect([display(b)]); h.runtime.pause(); h.runtime.resume()
        h.connect([display(a), display(b)]); await settle()
        XCTAssertEqual(h.runtime.state(of: a)?.playbackState, .playing, "断开时的最新全局 Resume 被记住")
    }

    func testStoppedAssignmentReconnectsWithoutRendererAndCanReenable() async throws {
        let h = try Harness(); defer { h.cleanup() }
        h.screens.values = [display(a), display(b)]; h.controller.start()
        let rain = try h.add("Rain")
        h.runtime.apply(rain, to: a); await settle()
        h.connect([display(b)]); h.runtime.stop()
        h.connect([display(a), display(b)]); await settle()
        XCTAssertEqual(h.runtime.state(of: a)?.playbackState, .stopped)
        XCTAssertNil(h.runtime.activeWallpaper(on: a)); XCTAssertEqual(h.made.count, 1)
        XCTAssertEqual(h.runtime.lastActiveWallpaper(on: a)?.id, rain.id)
        h.runtime.reenable(.display(a)); await settle()
        XCTAssertEqual(h.runtime.state(of: a)?.playbackState, .playing)
        XCTAssertEqual(h.made.count, 2)
    }

    func testGeometryAndPrimaryOrderUpdateWithoutReloadingRenderer() async throws {
        let h = try Harness(); defer { h.cleanup() }
        h.screens.values = [display(a), display(b)]; h.controller.start()
        h.runtime.apply(try h.add("Rain"), to: a); await settle()
        let renderer = h.made[0], host = h.hosts[a]
        h.screens.values = [display(b), display(a, direct: 91, width: 1440, scale: 1)]
        h.appNotifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(h.runtime.displayIDs, [b, a])
        XCTAssertEqual(h.runtime.summary.displays[1].frame?.width, 1440)
        XCTAssertEqual(h.runtime.summary.displays[1].scaleFactor, 1)
        XCTAssertTrue(h.hosts[a] === host); XCTAssertEqual(h.made.count, 1); XCTAssertFalse(renderer.disposed)
        XCTAssertGreaterThan(host!.realigns, 0)
        XCTAssertEqual(host!.resolved?.id, 91, "Resolver 必须读取本次屏幕快照，不能滞后一帧")
        XCTAssertEqual(host!.resolved?.frame.width, 1440)
    }

    func testDisconnectDuringFirstPrepareCancelsAndRestoresOnlySameTarget() async throws {
        let h = try Harness(); defer { h.cleanup() }
        h.screens.values = [display(a), display(b)]; h.controller.start()
        let rain = try h.add("Rain"); h.delayedIDs.insert(rain.id)
        h.runtime.apply(rain, to: a); h.runtime.pause(.display(a)); await settle()
        XCTAssertNotNil(h.made[0].continuation)
        h.connect([display(b)]); await settle()
        XCTAssertTrue(h.made[0].disposed)
        XCTAssertNil(h.runtime.activeWallpaper(on: b))
        XCTAssertTrue(h.store.load().assignments[a.rawValue]!.isManuallyPaused)
        h.delayedIDs.remove(rain.id)
        h.connect([display(a), display(b)]); await settle()
        XCTAssertEqual(h.runtime.state(of: a)?.activeWallpaperID, rain.id)
        XCTAssertEqual(h.runtime.state(of: a)?.playbackState, .manualPaused)
    }

    func testDeletedAssignmentDoesNotRestoreAndSceneRestoresOnlyItsOwnTarget() async throws {
        let h = try Harness(); defer { h.cleanup() }
        let scene = try h.add("Scene", type: .scene)
        h.store.save(.init(assignments: [a.rawValue: .init(wallpaperID: UUID(), isStopped: false, isManuallyPaused: false),
                                       b.rawValue: .init(wallpaperID: scene.id, isStopped: false, isManuallyPaused: false)],
                           hasMigratedLegacy: true))
        // 首次访问 lazy controller 在保存后，它必须读取最新记录。
        h.screens.values = [display(a), display(b)]; h.controller.start(); await settle()
        XCTAssertNil(h.runtime.activeWallpaper(on: a), "已删除的记录不能恢复，也不能回退到其他屏")
        XCTAssertEqual(h.made.count, 1)
        XCTAssertEqual(h.made.first?.wallpaper.id, scene.id)
        XCTAssertEqual(h.runtime.activeWallpaper(on: b)?.id, scene.id,
                       "Scene Renderer 已接入；有效记录仍走原有逐屏恢复流程")
        XCTAssertEqual(h.store.load().assignments.count, 2)
    }

    func testLegacyMigrationBindsOnlyFirstPrimaryAndOnlyOnce() async throws {
        let h = try Harness(); defer { h.cleanup() }
        let rain = try h.add("Rain")
        h.legacy.save(.init(wallpaperID: rain.id, isStopped: false, isManuallyPaused: true))
        h.screens.values = [display(a), display(b)]; h.controller.start(); await settle()
        XCTAssertEqual(h.runtime.activeWallpaper(on: a)?.id, rain.id)
        XCTAssertEqual(h.runtime.state(of: a)?.playbackState, .manualPaused)
        XCTAssertNil(h.runtime.activeWallpaper(on: b))
        h.connect([display(c)]); await settle()
        XCTAssertNil(h.runtime.activeWallpaper(on: c))
        XCTAssertTrue(h.store.load().hasMigratedLegacy)
        XCTAssertEqual(Set(h.store.load().assignments.keys), [a.rawValue])
    }

    func testExitDoesNotSaveShutdownAsStopAndRecordsAreLibraryScoped() async throws {
        let h = try Harness(); defer { h.cleanup() }
        h.screens.values = [display(a), display(b)]; h.controller.start()
        let rain = try h.add("Rain"), sea = try h.add("Sea")
        h.runtime.apply(rain, to: a); h.runtime.apply(sea, to: b); await settle()
        h.runtime.pause(); h.runtime.stop(.display(b))
        h.controller.stopRecording(); h.runtime.shutdown()
        let record = h.store.load().assignments[a.rawValue]!
        XCTAssertFalse(record.isStopped); XCTAssertTrue(record.isManuallyPaused)
        let freshRuntime = WallpaperRuntimeManager { Renderer($0) }
        let freshRegistry = DisplayRegistry(discover: { [displayA = display(a), displayB = display(b)] in [displayA, displayB] })
        let freshController = MultiDisplayController(registry: freshRegistry, runtime: freshRuntime, library: h.library,
                                                     store: h.store, legacy: h.legacy, makeSurface: { _, _ in .init(host: Host()) })
        freshController.start(); await settle()
        XCTAssertEqual(freshRuntime.state(of: a)?.activeWallpaperID, rain.id)
        XCTAssertEqual(freshRuntime.state(of: a)?.playbackState, .manualPaused)
        XCTAssertEqual(freshRuntime.state(of: b)?.playbackState, .stopped)
        XCTAssertEqual(freshRuntime.lastActiveWallpaper(on: b)?.id, sea.id)
        freshController.stopRecording(); freshRuntime.shutdown(); freshController.closeSurfaces()
        let other = DisplayAssignmentStore(defaults: h.defaults,
                                            library: LibraryStorageLocation(rootURL: h.root.appendingPathComponent("Other")))
        XCTAssertTrue(other.load().assignments.isEmpty)
    }

    func testTemporaryIdentityAndInvalidScreensAreNeverPersisted() async throws {
        let h = try Harness(); defer { h.cleanup() }
        h.screens.values = [display(a, persistent: false), display(b, width: 0), display(a)]
        h.controller.start()
        XCTAssertEqual(h.runtime.displayIDs, [a])
        h.runtime.apply(try h.add("Rain"), to: a); await settle()
        XCTAssertTrue(h.store.load().assignments.isEmpty)
        h.connect([]); h.connect([display(a, persistent: false)]); await settle()
        XCTAssertNotNil(h.runtime.activeWallpaper(on: a), "本进程内仍可以恢复临时身份")
        XCTAssertTrue(h.store.load().assignments.isEmpty)
    }

    func testSystemDiscoveryHasUniqueStableIdentitiesAndUsableFrames() {
        let displays = DisplayRegistry.systemDisplays()
        XCTAssertEqual(Set(displays.map(\.id)).count, displays.count)
        for display in displays {
            XCTAssertFalse(display.name.isEmpty); XCTAssertTrue(display.desktop.hasUsableFrame)
            XCTAssertGreaterThan(display.desktop.backingScaleFactor, 0)
            if display.isPersistent { XCTAssertTrue(display.id.rawValue.hasPrefix("display-")) }
        }
        XCTAssertEqual(DisplayRegistry.systemDisplays(), displays)
    }
}

/// Per-test fixture folder. Unsigned command-line runs keep fixtures under the repository's `.build` for inspection;
/// the signed, sandboxed Xcode run cannot write the repository, so it falls back to the test host's temporary folder.
enum TestWorkspaceDirectory {
    static func make(_ relative: String, file: String = #filePath) -> URL {
        let repository = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
        let preferred = repository.appendingPathComponent(relative, isDirectory: true)
        let manager = FileManager.default
        if (try? manager.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil,
           manager.isWritableFile(atPath: preferred.path) {
            return preferred.appendingPathComponent(UUID().uuidString, isDirectory: true)
        }
        return manager.temporaryDirectory.appendingPathComponent(relative, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
