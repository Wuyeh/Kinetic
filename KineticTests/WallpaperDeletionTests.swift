import AppKit
import XCTest
@testable import Kinetic

/// 删除流程：本地 / Steam、正在使用 / 准备中 / 未使用、预览占用、文件边界、失败回滚与确认弹窗。
@MainActor
final class WallpaperDeletionTests: XCTestCase {
    // MARK: Fakes

    private final class Events {
        var entries: [String] = []
    }

    private final class Desktop: DesktopContentHost {
        let events: Events
        init(events: Events) { self.events = events }
        func present(_ contentView: NSView) -> Bool { events.entries.append("present"); return true }
        func stop() { events.entries.append("desktop.stop") }
    }

    private final class Renderer: WallpaperRenderer {
        let wallpaper: Wallpaper
        let displayView = NSView()
        var onFailure: (@MainActor (Error) -> Void)?
        let events: Events
        let finishesImmediately: Bool
        /// 释放时资料库记录与文件是否仍在：证明先释放 Renderer、后删除。
        var onDispose: (() -> Void)?
        private var continuation: CheckedContinuation<Void, Error>?
        private(set) var isDisposed = false

        init(wallpaper: Wallpaper, events: Events, finishesImmediately: Bool) {
            self.wallpaper = wallpaper
            self.events = events
            self.finishesImmediately = finishesImmediately
        }

        func prepare() async throws {
            if finishesImmediately { return }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func play() {}
        func pause() {}
        func resume() {}
        func setMuted(_ muted: Bool) {}

        func dispose() {
            guard !isDisposed else { return }
            isDisposed = true
            onDispose?()
            events.entries.append("dispose:\(wallpaper.name)")
            let pending = continuation
            continuation = nil
            pending?.resume(throwing: CancellationError())
        }
    }

    private final class PreviewSession: LivePreviewSession {
        let wallpaperID: Wallpaper.ID
        let contentView = NSView()
        var state: PreviewContentState = .playing
        var onStateChange: ((PreviewContentState) -> Void)?
        private(set) var invalidated = false
        init(wallpaperID: Wallpaper.ID) { self.wallpaperID = wallpaperID }
        func start() {}
        func invalidate() { invalidated = true }
    }

    // MARK: Fixture

    private var root: URL!
    private var storage: LibraryStorageLocation!
    private var library: WallpaperLibrary!
    private var events: Events!
    private var runtime: WallpaperRuntimeManager!
    private var renderers: [Renderer] = []
    private var preparesImmediately = true
    private var preview: WallpaperPreviewCoordinator!
    private var previewSessions: [PreviewSession] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticDelete-\(UUID().uuidString)", isDirectory: true)
        storage = LibraryStorageLocation(rootURL: root)
        try FileManager.default.createDirectory(at: storage.wallpapersDirectoryURL, withIntermediateDirectories: true)
        library = WallpaperLibrary(storage: storage)
        events = Events()
        renderers = []
        preparesImmediately = true
        runtime = WallpaperRuntimeManager(desktop: Desktop(events: events)) { [unowned self] wallpaper in
            let renderer = Renderer(wallpaper: wallpaper, events: self.events, finishesImmediately: self.preparesImmediately)
            self.renderers.append(renderer)
            return renderer
        }
        previewSessions = []
        preview = WallpaperPreviewCoordinator(delay: 0.01, observesSystem: false, isEligible: { _ in true }) { [unowned self] wallpaper in
            let session = PreviewSession(wallpaperID: wallpaper.id)
            self.previewSessions.append(session)
            return session
        }
    }

    override func tearDown() async throws {
        runtime.shutdown()
        preview.stopAll()
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func service() -> WallpaperDeletionService {
        var service = WallpaperDeletionService(library: library, runtime: runtime, previewCoordinator: preview)
        service.fileRemovalDelay = 0
        return service
    }

    /// 与导入一致的受管目录：Wallpapers/<id>/<内容> + 预览图。
    private func addLocal(_ name: String, type: WallpaperType = .video) throws -> Wallpaper {
        let id = UUID()
        let folder = storage.wallpapersDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resource: URL
        if type == .web {
            resource = folder.appendingPathComponent("site", isDirectory: true)
            try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
            try Data("<html></html>".utf8).write(to: resource.appendingPathComponent("index.html"))
        } else {
            resource = folder.appendingPathComponent("\(name).mp4")
            try Data("video".utf8).write(to: resource)
        }
        let thumbnail = folder.appendingPathComponent("kinetic-preview.jpg")
        try Data("jpg".utf8).write(to: thumbnail)
        let wallpaper = Wallpaper(id: id, name: name, type: type, source: .local, resourceURL: resource, thumbnailURL: thumbnail)
        try library.add(wallpaper)
        return wallpaper
    }

    private func folder(of wallpaper: Wallpaper) -> URL {
        storage.wallpapersDirectoryURL.appendingPathComponent(wallpaper.id.uuidString, isDirectory: true)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func pendingFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: storage.wallpapersDirectoryURL.path)) ?? [])
            .filter { $0.hasPrefix(WallpaperDeletionService.pendingRemovalPrefix) }
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func applyAndWait(_ wallpaper: Wallpaper) async {
        runtime.apply(wallpaper)
        _ = await waitUntil { self.runtime.state.activeWallpaperID == wallpaper.id }
    }

    // MARK: Local

    func testInactiveLocalWallpaperRemovesRecordAndManagedFolderOnly() async throws {
        let target = try addLocal("雨夜")
        let other = try addLocal("海边")
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("KineticOriginal-\(UUID().uuidString).mp4")
        try Data("user original".utf8).write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }

        try service().delete(target.id)

        XCTAssertNil(library.wallpaper(id: target.id))
        XCTAssertNotNil(library.wallpaper(id: other.id))
        XCTAssertFalse(exists(folder(of: target)))
        XCTAssertTrue(exists(folder(of: other)))
        XCTAssertTrue(exists(original), "The user's original file is never touched")
        let cleaned = await waitUntil { self.pendingFolders().isEmpty }
        XCTAssertTrue(cleaned)
        XCTAssertTrue(events.entries.isEmpty, "Deleting an unused wallpaper does not touch the desktop")
        XCTAssertEqual(WallpaperLibrary(storage: storage).wallpapers.map(\.id), [other.id], "Removal is persisted")
    }

    func testLocalWebFolderIsRemovedToo() throws {
        let web = try addLocal("网页", type: .web)
        try service().delete(web.id)
        XCTAssertNil(library.wallpaper(id: web.id))
        XCTAssertFalse(exists(folder(of: web)))
    }

    // MARK: Active / preparing

    func testActiveWallpaperStopsAndReleasesBeforeRecordAndFilesAreRemoved() async throws {
        let active = try addLocal("正在使用")
        await applyAndWait(active)
        XCTAssertEqual(runtime.state.activeWallpaperID, active.id)
        let renderer = try XCTUnwrap(renderers.last)
        var recordExistedAtRelease = false
        var filesExistedAtRelease = false
        renderer.onDispose = { [unowned self] in
            recordExistedAtRelease = self.library.wallpaper(id: active.id) != nil
            filesExistedAtRelease = self.exists(active.resourceURL)
        }

        try service().delete(active.id)

        XCTAssertTrue(renderer.isDisposed)
        XCTAssertTrue(recordExistedAtRelease, "Renderer is released before the library record is removed")
        XCTAssertTrue(filesExistedAtRelease, "Renderer is released before its files are moved away")
        let stopIndex = try XCTUnwrap(events.entries.firstIndex(of: "desktop.stop"))
        let disposeIndex = try XCTUnwrap(events.entries.firstIndex(of: "dispose:正在使用"))
        XCTAssertLessThan(stopIndex, disposeIndex, "macOS wallpaper is restored before the renderer is released")
        XCTAssertNil(runtime.state.activeWallpaperID)
        XCTAssertNil(runtime.activeWallpaper)
        XCTAssertNil(library.wallpaper(id: active.id))
        XCTAssertFalse(exists(folder(of: active)))
    }

    func testPreparingWallpaperIsCancelledBeforeRemoval() async throws {
        let target = try addLocal("准备中")
        preparesImmediately = false
        runtime.apply(target)
        _ = await waitUntil { self.runtime.state.preparingWallpaperID == target.id }
        let renderer = try XCTUnwrap(renderers.last)

        try service().delete(target.id)

        XCTAssertTrue(renderer.isDisposed)
        XCTAssertNil(runtime.state.preparingWallpaperID)
        XCTAssertNil(runtime.preparingWallpaper)
        XCTAssertNil(library.wallpaper(id: target.id))
    }

    func testDeletingAnotherWallpaperKeepsTheDesktopPlaying() async throws {
        let active = try addLocal("桌面")
        let target = try addLocal("别的")
        await applyAndWait(active)
        let renderer = try XCTUnwrap(renderers.last)
        let before = events.entries

        try service().delete(target.id)

        XCTAssertEqual(runtime.state.activeWallpaperID, active.id)
        XCTAssertEqual(runtime.state.playbackState, .playing)
        XCTAssertFalse(renderer.isDisposed)
        XCTAssertEqual(events.entries, before)
    }

    func testDeletingTheLastStoppedWallpaperLeavesNothingToReenableFromTheLibrary() async throws {
        let wallpaper = try addLocal("已停止")
        await applyAndWait(wallpaper)
        runtime.stop()
        XCTAssertEqual(runtime.state.lastActiveWallpaperID, wallpaper.id)

        try service().delete(wallpaper.id)

        XCTAssertNil(library.wallpaper(id: runtime.state.lastActiveWallpaperID ?? UUID()),
                     "The toolbar only re-enables wallpapers that are still in the library")
    }

    // MARK: Preview

    func testHoverPreviewOfTheWallpaperIsReleasedFirst() async throws {
        let target = try addLocal("预览中")
        preview.hoverBegan(target)
        _ = await waitUntil { self.preview.activePreviewWallpaperID == target.id }
        let session = try XCTUnwrap(previewSessions.last)

        try service().delete(target.id)

        XCTAssertTrue(session.invalidated)
        XCTAssertNil(preview.activePreview)
        XCTAssertNil(library.wallpaper(id: target.id))
    }

    // MARK: Steam / boundaries

    func testSteamWallpaperOnlyLosesItsRecord() throws {
        let steamContent = root.appendingPathComponent("SteamLibrary/workshop/content/431960/123456", isDirectory: true)
        try FileManager.default.createDirectory(at: steamContent, withIntermediateDirectories: true)
        try Data("scene".utf8).write(to: steamContent.appendingPathComponent("scene.pkg"))
        let steam = Wallpaper(name: "星空", type: .scene, source: .steam, resourceURL: steamContent,
                              steamMetadata: SteamMetadata(workshopID: "123456", author: "作者"))
        try library.add(steam)

        try service().delete(steam.id)

        XCTAssertNil(library.wallpaper(id: steam.id))
        XCTAssertTrue(exists(steamContent.appendingPathComponent("scene.pkg")), "Steam managed content is never deleted")
    }

    func testRecordPointingOutsideItsManagedFolderNeverDeletesThoseFiles() throws {
        let outside = storage.wallpapersDirectoryURL.appendingPathComponent("shared.mp4")
        try Data("shared".utf8).write(to: outside)
        let odd = Wallpaper(name: "异常", type: .video, source: .local, resourceURL: outside)
        try library.add(odd)
        let traversal = Wallpaper(name: "越界", type: .video, source: .local,
                                  resourceURL: storage.wallpapersDirectoryURL
                                      .appendingPathComponent(UUID().uuidString)
                                      .appendingPathComponent("../shared.mp4"))
        try library.add(traversal)

        XCTAssertNil(service().managedFolder(for: odd))
        XCTAssertNil(service().managedFolder(for: traversal))
        try service().delete(odd.id)
        try service().delete(traversal.id)
        XCTAssertTrue(exists(outside))
        XCTAssertTrue(library.wallpapers.isEmpty)
    }

    func testMissingFilesStillRemoveTheRecord() throws {
        let wallpaper = try addLocal("缺失")
        try FileManager.default.removeItem(at: folder(of: wallpaper))
        try service().delete(wallpaper.id)
        XCTAssertNil(library.wallpaper(id: wallpaper.id))
    }

    func testUnknownWallpaperReportsNotFound() {
        XCTAssertThrowsError(try service().delete(UUID())) { error in
            XCTAssertEqual(error as? WallpaperDeletionError, .notFound)
        }
    }

    // MARK: Failure & cleanup

    func testLibraryWriteFailureRestoresTheFilesAndKeepsTheRecord() throws {
        let wallpaper = try addLocal("写入失败")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        XCTAssertThrowsError(try service().delete(wallpaper.id))

        XCTAssertNotNil(library.wallpaper(id: wallpaper.id))
        XCTAssertTrue(exists(wallpaper.resourceURL), "Files are moved back when the record cannot be removed")
        XCTAssertTrue(exists(wallpaper.thumbnailURL!))
        XCTAssertTrue(pendingFolders().isEmpty)
    }

    func testLeftoversFromAnInterruptedDeletionAreCleanedOnLaunch() throws {
        let keep = try addLocal("保留")
        let leftover = storage.wallpapersDirectoryURL
            .appendingPathComponent("\(WallpaperDeletionService.pendingRemovalPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: leftover.appendingPathComponent("clip.mp4"))

        WallpaperDeletionService.removeLeftovers(in: storage)

        XCTAssertFalse(exists(leftover))
        XCTAssertTrue(exists(folder(of: keep)))
    }

    // MARK: Confirmation

    func testConfirmationTextAndButtonsFollowTheSpec() {
        let wallpaper = Wallpaper(name: "雨夜", type: .video, source: .local, resourceURL: URL(fileURLWithPath: "/tmp/a.mp4"))
        let alert = WallpaperDeletionConfirmation.makeAlert(for: wallpaper)
        XCTAssertEqual(alert.messageText, "删除“雨夜”？")
        XCTAssertEqual(alert.informativeText, "此操作会将这张壁纸从 Kinetic 资料库中删除。")
        XCTAssertEqual(alert.buttons.map(\.title), ["取消", "删除"])
        let cancel = alert.buttons[0], delete = alert.buttons[1]
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}", "Esc cancels")
        XCTAssertEqual(delete.keyEquivalent, "", "Return never triggers the destructive action")
        XCTAssertFalse(alert.buttons.contains { $0.keyEquivalent == "\r" })
        XCTAssertTrue(delete.hasDestructiveAction)
        XCTAssertTrue(alert.window.initialFirstResponder === cancel)
        XCTAssertTrue(WallpaperDeletionConfirmation.isDeleteResponse(.alertSecondButtonReturn))
        XCTAssertFalse(WallpaperDeletionConfirmation.isDeleteResponse(.alertFirstButtonReturn))
        XCTAssertFalse(WallpaperDeletionConfirmation.isDeleteResponse(.abort))
    }

    func testBackspaceHandlerOnlyReactsToPlainDeleteKeys() {
        XCTAssertTrue(DeleteKeyHandlerView.isDeleteKey(51, modifiers: []), "Backspace")
        XCTAssertTrue(DeleteKeyHandlerView.isDeleteKey(117, modifiers: []), "Forward Delete")
        XCTAssertTrue(DeleteKeyHandlerView.isDeleteKey(51, modifiers: [.function, .numericPad]))
        XCTAssertFalse(DeleteKeyHandlerView.isDeleteKey(0, modifiers: []), "Other keys pass through")
        for modifier in [NSEvent.ModifierFlags.command, .option, .control, .shift] {
            XCTAssertFalse(DeleteKeyHandlerView.isDeleteKey(51, modifiers: modifier))
        }

        // 未启用、没有窗口时不拦截任何按键。
        let view = DeleteKeyHandlerView(frame: .zero)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "\u{7f}",
                                     charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        XCTAssertFalse(view.shouldHandle(event))
        view.isEnabled = true
        XCTAssertFalse(view.shouldHandle(event))
    }
}
