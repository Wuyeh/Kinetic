import AppKit
import Combine
import XCTest
@testable import Kinetic

/// Module 60: the production drag, acquisition, registry, runtime and crossfade pipeline.
/// Only physical screens, renderer first-frame delivery and the SteamCMD process are substituted.
@MainActor
final class MultiDisplayUXQATests: XCTestCase {
    func testLocalClickApplyAcrossOneTwoAndFourDisplaysOnlyChangesChosenScreen() async throws {
        for count in [1, 2, 4] {
            let h = try WallpaperFlowQAHarness(count: count); defer { h.cleanup() }
            try await h.start()
            let candidate = try h.addWeb("Local click")
            let target = h.ids.last!
            if count == 1 {
                XCTAssertEqual(LocalCardApplyRoute.resolve(h.runtime.summary), .direct(target))
            } else {
                XCTAssertEqual(LocalCardApplyRoute.resolve(h.runtime.summary), .chooseDisplay)
                var picker = DisplayApplyPresentation(); picker.present(candidate.id)
                XCTAssertEqual(picker.takeSelection(target, availableIDs: h.runtime.displayIDs,
                    isInLibrary: { h.library.wallpaper(id: $0) != nil }), candidate.id)
            }
            h.runtime.apply(candidate, to: target)
            try await h.checkOnlyTargetChanged(to: candidate, on: target)
        }
    }

    func testLocalAndAlreadyDownloadedSteamDragsShareExplicitStableTarget() async throws {
        let h = try WallpaperFlowQAHarness(count: 3); defer { h.cleanup() }
        try await h.start()
        let local = try h.addWeb("Dragged local")
        let target = h.ids[1], frames = h.targetFrames, point = h.point(on: target)
        var drag = LocalWallpaperDragPresentation(); drag.begin(local.id)
        let destination = drag.takeDrop(from: local.id, at: point, displayFrames: frames,
            displayIDs: h.runtime.displayIDs, listFrames: [:], listIDs: [], isInLibrary: true, isPlayable: true)
        XCTAssertEqual(destination, .display(local.id, target))
        if case .display(let id, let screen) = destination, let wallpaper = h.library.wallpaper(id: id) {
            h.runtime.apply(wallpaper, to: screen)
        }
        try await h.checkOnlyTargetChanged(to: local, on: target)
        let downloaded = try await h.download("601")
        let processCount = h.fake.processes.count
        var remote = SteamDisplayDragPresentation(); let item = h.remote("601")
        remote.begin(item, posterURL: nil)
        let drop = try XCTUnwrap(remote.takeDrop(from: item.id, at: point, frames: frames,
                                                displays: h.runtime.displayIDs))
        h.coordinator.request(drop.0.acquisitionInfo, to: drop.1)
        try await waitForSteam { h.notices.last?.outcome == .appliedExisting }
        XCTAssertEqual(h.fake.processes.count, processCount, "A downloaded card must not start another download")
        XCTAssertEqual(h.runtime.activeWallpaper(on: target)?.id, downloaded.id)
        for id in h.ids where id != target { XCTAssertEqual(h.runtime.activeWallpaper(on: id)?.id, h.initial[id]?.id) }
    }

    func testBothDragTypesRejectDisconnectedTargetWithoutFallingBackToMainScreen() async throws {
        let h = try WallpaperFlowQAHarness(count: 2); defer { h.cleanup() }
        try await h.start()
        let candidate = try h.addWeb("Not applied"), target = h.ids[1]
        let staleFrames = h.targetFrames, point = h.point(on: target)
        var local = LocalWallpaperDragPresentation(); local.begin(candidate.id)
        local.move(point, from: candidate.id, displayFrames: staleFrames, displayIDs: h.runtime.displayIDs,
                   listFrames: [:], listIDs: [])
        var remote = SteamDisplayDragPresentation(); let item = h.remote("602")
        remote.begin(item, posterURL: nil)
        remote.move(point, from: item.id, frames: staleFrames, displays: h.runtime.displayIDs)
        h.connect([h.ids[0]])
        XCTAssertNil(local.takeDrop(from: candidate.id, at: point, displayFrames: staleFrames,
            displayIDs: h.runtime.displayIDs, listFrames: [:], listIDs: [], isInLibrary: true, isPlayable: true))
        XCTAssertNil(remote.takeDrop(from: item.id, at: point, frames: staleFrames, displays: h.runtime.displayIDs))
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.ids[0])?.id, h.initial[h.ids[0]]?.id)
        XCTAssertTrue(h.fake.processes.isEmpty)
    }

    func testDisconnectDuringRealAcquisitionStillImportsButDoesNotApplyAfterReconnect() async throws {
        let h = try WallpaperFlowQAHarness(count: 3); defer { h.cleanup() }
        try await h.start()
        let target = h.ids[1], original = h.initial[target]!
        h.coordinator.request(h.remote("603").acquisitionInfo, to: target)
        try await h.waitForDownload("603")
        h.connect([h.ids[2], h.ids[0]])
        h.connect([h.ids[2], target, h.ids[0]], directIDOffset: 100)
        try await waitForSteam { h.runtime.activeWallpaper(on: target)?.id == original.id }
        try h.finishDownload("603")
        try await waitForSteam { h.library.wallpaper(workshopID: "603") != nil && !h.notices.isEmpty }
        XCTAssertEqual(h.notices.map(\.outcome), [.disconnected])
        XCTAssertNotNil(h.library.wallpaper(workshopID: "603"))
        for id in h.ids { XCTAssertEqual(h.runtime.activeWallpaper(on: id)?.id, h.initial[id]?.id) }
    }

    func testSteamDragAcrossFourDisplaysRetainsOldFramesUntilReadyThenCrossfadesOnlyTarget() async throws {
        let h = try WallpaperFlowQAHarness(count: 4); defer { h.cleanup() }
        try await h.start()
        let target = h.ids[2], item = h.remote("604")
        h.waitWorkshopIDs.insert(item.id)
        var drag = SteamDisplayDragPresentation(); drag.begin(item, posterURL: nil)
        let drop = try XCTUnwrap(drag.takeDrop(from: item.id, at: h.point(on: target),
            frames: h.targetFrames, displays: h.runtime.displayIDs))
        h.coordinator.request(drop.0.acquisitionInfo, to: drop.1)
        try await h.waitForDownload(item.id)
        // A registry reorder (or a changed transient CGDisplayID) cannot change the saved destination.
        h.connect(Array(h.ids.reversed()), directIDOffset: 200)
        try h.finishDownload(item.id)
        try await waitForSteam { h.renderers.last?.waiting == true }
        for id in h.ids {
            XCTAssertEqual(h.runtime.activeWallpaper(on: id)?.id, h.initial[id]?.id)
            XCTAssertEqual(h.hosts[id]?.stage.contents.count, 1)
        }
        XCTAssertTrue(h.notices.isEmpty)
        let downloaded = try XCTUnwrap(h.library.wallpaper(workshopID: item.id))
        h.renderers.last?.ready()
        try await h.checkOnlyTargetChanged(to: downloaded, on: target)
        XCTAssertEqual(h.notices.map(\.outcome), [.downloadedAndApplied])
        XCTAssertEqual(h.notices.first?.displayID, target)
    }

    func testReconnectKeepsManualPauseAndStoppedIntentWithoutDisturbingOtherDisplay() async throws {
        let h = try WallpaperFlowQAHarness(count: 3); defer { h.cleanup() }
        try await h.start()
        let paused = h.ids[1], stopped = h.ids[2]
        h.runtime.pause(.display(paused)); h.runtime.stop(.display(stopped))
        h.connect([h.ids[0]])
        h.connect([stopped, h.ids[0], paused], directIDOffset: 500)
        try await waitForSteam { h.runtime.activeWallpaper(on: paused)?.id == h.initial[paused]?.id }
        XCTAssertEqual(h.runtime.state(of: paused)?.playbackState, .manualPaused)
        XCTAssertNil(h.runtime.activeWallpaper(on: stopped))
        XCTAssertEqual(h.runtime.state(of: stopped)?.playbackState, .stopped)
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.ids[0])?.id, h.initial[h.ids[0]]?.id)
        XCTAssertEqual(h.hosts[h.ids[0]]?.completedTransitionCount, 0)
    }
}

/// Test-only memory stores: no real settings, credentials, downloads or desktop windows.
final class WallpaperFlowQADefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? {
        key == "Kinetic.Steam.Username" ? "fixture-user" : values[key] as? String
    }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor
final class WallpaperFlowQAHarness {
    final class Screens { var values: [DisplayDescriptor] = [] }
    final class Desktop: DesktopContentHost {
        let window: NSWindow
        var content: NSView?
        init() {
            window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 640, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false; window.backgroundColor = .clear
            window.ignoresMouseEvents = true
        }
        func present(_ contentView: NSView) -> Bool {
            content = contentView; window.contentView = contentView; window.orderBack(nil)
            return true
        }
        func stop() { window.orderOut(nil); window.contentView = nil; content = nil }
    }
    final class Renderer: WallpaperRenderer {
        let wallpaper: Wallpaper
        let displayView = NSView()
        var onFailure: (@MainActor (Error) -> Void)?
        var delay = false, waiting = false, disposed = false
        var continuation: CheckedContinuation<Void, Error>?
        init(_ wallpaper: Wallpaper) { self.wallpaper = wallpaper }
        func prepare() async throws {
            if delay { try await withCheckedThrowingContinuation { waiting = true; continuation = $0 } }
        }
        func ready() { waiting = false; let pending = continuation; continuation = nil; pending?.resume() }
        func play() {}
        func pause() {}
        func resume() {}
        func setMuted(_ muted: Bool) {}
        func dispose() {
            disposed = true; waiting = false
            let pending = continuation; continuation = nil; pending?.resume(throwing: CancellationError())
        }
    }

    let root: URL, library: WallpaperLibrary, installation: SteamCMDInstallation
    let ids: [DisplayID]
    let defaults = WallpaperFlowQADefaults(), fake = FakeSteamCMD(), screens = Screens()
    var initial: [DisplayID: Wallpaper] = [:], hosts: [DisplayID: CrossfadeDesktopHost] = [:]
    var renderers: [Renderer] = [], notices: [SteamDisplayApplyCoordinator.Notice] = []
    var waitWorkshopIDs = Set<String>()
    var subscription: AnyCancellable?
    lazy var registry = DisplayRegistry(discover: { [unowned self] in self.screens.values },
        applicationNotifications: NotificationCenter(), workspaceNotifications: NotificationCenter())
    lazy var runtime = WallpaperRuntimeManager { [unowned self] wallpaper in
        let renderer = Renderer(wallpaper)
        renderer.delay = wallpaper.steamMetadata.map { self.waitWorkshopIDs.contains($0.workshopID) } ?? false
        self.renderers.append(renderer); return renderer
    }
    lazy var controller = MultiDisplayController(registry: registry, runtime: runtime, library: library,
        store: DisplayAssignmentStore(defaults: defaults, library: library.storage),
        legacy: WallpaperRestorationStore(defaults: defaults, library: library.storage),
        makeSurface: { [unowned self] id, _ in
            let host = CrossfadeDesktopHost(desktop: Desktop())
            self.hosts[id] = host; return .init(host: host, close: { host.stop() })
        })
    lazy var steam = SteamAcquisitionService(installation: installation, library: library,
        defaults: defaults, makeProcess: fake.factory)
    lazy var coordinator = SteamDisplayApplyCoordinator(runtime: runtime, library: library, steam: steam)

    init(count: Int) throws {
        ids = (0..<count).map { DisplayID("qa-stable-display-\($0)") }
        root = TestWorkspaceDirectory.make(".build/Module60-61/TestWorkspaces")
        library = WallpaperLibrary(storage: .init(rootURL: root.appendingPathComponent("Library")))
        installation = SteamCMDInstallation(rootURL: root.appendingPathComponent("SteamCMD"))
        try FileManager.default.createDirectory(at: installation.rootURL, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: installation.scriptURL)
        fake.configure = { $0.script = { _ in } }
    }
    func start() async throws {
        connect(ids); controller.start()
        subscription = coordinator.notices.sink { [weak self] in self?.notices.append($0) }
        for id in ids {
            let wallpaper = try addWeb("Original \(id.rawValue)"); initial[id] = wallpaper
            runtime.apply(wallpaper, to: id)
        }
        try await waitForSteam { self.ids.allSatisfy { self.runtime.activeWallpaper(on: $0)?.id == self.initial[$0]?.id } }
    }
    func connect(_ values: [DisplayID], directIDOffset: UInt32 = 0) {
        screens.values = values.map { id in
            let index = ids.firstIndex(of: id)!
            return DisplayDescriptor(id: id, name: "Test display \(index + 1)",
                desktop: .init(id: UInt32(index + 1) + directIDOffset,
                    frame: CGRect(x: index * 1000, y: 0, width: 1000, height: 700), backingScaleFactor: 2),
                isPersistent: true)
        }
        registry.refresh()
    }
    func addWeb(_ name: String) throws -> Wallpaper {
        let folder = root.appendingPathComponent("Sources").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = folder.appendingPathComponent("index.html")
        try Data("<html>\(name)</html>".utf8).write(to: entry)
        let wallpaper = Wallpaper(name: name, type: .web, source: .local, resourceURL: entry)
        try library.add(wallpaper); return wallpaper
    }
    func remote(_ id: String) -> SteamStoreItem {
        .init(workshopID: id, title: "Remote \(id)", previewURL: nil, creatorSteamID: nil,
              timeCreated: nil, timeUpdated: nil, fileSize: nil, type: .web, tags: ["Web", "Everyone"])
    }
    var targetFrames: [DisplayID: CGRect] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, CGRect(x: $0.offset * 160, y: 20, width: 140, height: 90)) })
    }
    func point(on id: DisplayID) -> CGPoint { let frame = targetFrames[id]!; return .init(x: frame.midX, y: frame.midY) }
    func waitForDownload(_ id: String) async throws {
        try await waitForSteam { self.steam.tasks[id]?.isActive == true && self.fake.processes.last?.started == true }
    }
    func finishDownload(_ id: String, valid: Bool = true) throws {
        let folder = installation.contentURL(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if valid {
            try Data(#"{"type":"web","file":"index.html"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
            try Data("<html>Downloaded \(id)</html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        }
        let process = try XCTUnwrap(fake.processes.last)
        process.emit("Success. Downloaded item \(id) to \"\(folder.path)\" (20 bytes)\n"); process.finish(0)
    }
    func download(_ id: String) async throws -> Wallpaper {
        let task = Task { await steam.acquire(remote(id).acquisitionInfo) }
        try await waitForDownload(id); try finishDownload(id)
        return try await task.value.get()
    }
    func checkOnlyTargetChanged(to wallpaper: Wallpaper, on target: DisplayID) async throws {
        try await waitForSteam { self.runtime.activeWallpaper(on: target)?.id == wallpaper.id }
        for id in ids where id != target {
            XCTAssertEqual(runtime.activeWallpaper(on: id)?.id, initial[id]?.id)
            XCTAssertEqual(hosts[id]?.completedTransitionCount, 0)
            XCTAssertFalse(hosts[id]?.isTransitioning ?? true)
        }
        let host = try XCTUnwrap(hosts[target])
        XCTAssertTrue(host.isTransitioning)
        XCTAssertEqual(host.stage.contents.count, 2, "The old frame stays installed until the crossfade ends")
        try await waitForSteam { !host.isTransitioning }
        XCTAssertEqual(host.stage.contents.count, 1)
        XCTAssertEqual(host.completedTransitionCount, 1)
    }
    func cleanup() {
        coordinator.shutdown(); subscription?.cancel(); controller.stopRecording()
        runtime.shutdown(); controller.closeSurfaces()
        try? FileManager.default.removeItem(at: root)
    }
}
