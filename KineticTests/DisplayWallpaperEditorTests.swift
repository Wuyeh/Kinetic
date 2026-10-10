import AppKit
import Combine
@testable import KineticSceneRuntime
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor private final class DisplayEditorHost: DesktopContentHost {
    var content: NSView?
    var promotions = 0
    func present(_ contentView: NSView) -> Bool { content = contentView; promotions += 1; return true }
    func stop() { content = nil }
}
@MainActor private final class DisplayEditorRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let configuration: StagedDisplayWallpaperConfiguration
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    var fail = false, disposed = false, paused = true, muted = true
    var delay: UInt64 = 0
    init(_ wallpaper: Wallpaper, _ configuration: StagedDisplayWallpaperConfiguration) {
        self.wallpaper = wallpaper; self.configuration = configuration
    }
    func prepare() async throws {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fail { throw DisplayEditingError.unreadable }
    }
    func play() { paused = false }; func pause() { paused = true }; func resume() { play() }
    func setMuted(_ muted: Bool) { self.muted = muted }; func dispose() { disposed = true }
}

@MainActor
final class DisplayWallpaperEditorTests: XCTestCase {
    private var root: URL!
    private var library: WallpaperLibrary!
    private var runtime: WallpaperRuntimeManager!
    private var editor: DisplayWallpaperEditor!
    private var video: VideoPlaybackStore!
    private var web: WebPlaybackStore!
    private var scene: ScenePropertyStore!
    private var settings: SettingsStore!
    private var created: [DisplayEditorRenderer] = []
    private var fail = false
    private var delay: UInt64 = 0
    private let a = DisplayID("display-A"), b = DisplayID("display-B")
    private var suite = ""
    override func setUp() {
        root = TestWorkspaceDirectory.make(".build/SidebarDisplayRevision/Fixtures")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = LibraryStorageLocation(rootURL: root)
        library = WallpaperLibrary(storage: storage); video = VideoPlaybackStore(storage: storage)
        web = WebPlaybackStore(storage: storage); scene = ScenePropertyStore(storage: storage)
        suite = "Kinetic.DisplayEditing.Tests." + UUID().uuidString
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        runtime = WallpaperRuntimeManager()
        editor = makeEditor()
        runtime.displayRendererFactory = { [weak self] wallpaper, display in try self!.editor.makeRenderer(wallpaper, on: display) }
        runtime.addDisplay(a, host: DisplayEditorHost()); runtime.addDisplay(b, host: DisplayEditorHost())
    }
    override func tearDown() {
        runtime.shutdown(); runtime.displayRendererFactory = nil
        editor = nil; runtime = nil; library = nil; video = nil; web = nil; scene = nil; settings = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        created = []; fail = false; delay = 0
    }
    private func makeEditor() -> DisplayWallpaperEditor {
        DisplayWallpaperEditor(storage: .init(rootURL: root), library: library, runtime: runtime,
            sceneStore: scene, videoStore: video, webStore: web, settings: settings) { [weak self] wallpaper, value in
                let renderer = DisplayEditorRenderer(wallpaper, value)
                renderer.fail = self?.fail ?? false; renderer.delay = self?.delay ?? 0
                self?.created.append(renderer); return renderer
            }
    }
    private func wallpaper(_ type: WallpaperType = .video, name: String = "本地壁纸") throws -> Wallpaper {
        let value = Wallpaper(name: name, type: type, source: .local, resourceURL: root.appendingPathComponent(UUID().uuidString + ".mp4"))
        try Data("source unchanged".utf8).write(to: value.resourceURL)
        try library.add(value); return value
    }
    private func settle() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while runtime.summary.displays.contains(where: { $0.runtime.preparingWallpaperID != nil }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayEditingError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testDraftSwitchingAndSelectionNeverTouchDesktopOrSavedDefaults() async throws {
        let first = try wallpaper(), second = try wallpaper(.web)
        runtime.apply(first, to: a); runtime.apply(first, to: b); try await settle()
        let old = created
        editor.edit(on: a) { $0.video.speed = 2 }
        editor.select(second, on: b)
        XCTAssertEqual(editor.draft(on: a).video.speed, 2)
        XCTAssertEqual(editor.draft(on: b).wallpaperID, second.id)
        XCTAssertTrue(editor.isDirty(on: a)); XCTAssertTrue(editor.isDirty(on: b))
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, first.id)
        XCTAssertEqual(runtime.activeWallpaper(on: b)?.id, first.id)
        XCTAssertEqual(created.count, old.count); XCTAssertTrue(old.allSatisfy { !$0.disposed })
        XCTAssertEqual(video.configuration(for: first.id), .init())
        XCTAssertFalse(FileManager.default.fileExists(atPath: editor.fileURL.path))
        let reopened = makeEditor()
        XCTAssertEqual(reopened.draft(on: a).video.speed, 1, "Unsaved draft is not restored across editor/app creation")
        XCTAssertEqual(reopened.draft(on: b).wallpaperID, first.id)
    }
    func testWallpaperAppliedElsewhereReplacesUnappliedDraftOnThatDisplayOnly() async throws {
        let first = try wallpaper(name: "A"), second = try wallpaper(name: "B"), third = try wallpaper(name: "C")
        runtime.apply(first, to: a); runtime.apply(first, to: b); try await settle()
        editor.select(second, on: a); editor.edit(on: b) { $0.video.speed = 2 }
        runtime.pause(.display(a))
        XCTAssertEqual(editor.draft(on: a).wallpaperID, second.id, "State changes of the same wallpaper keep the draft")
        runtime.apply(third, to: a); try await settle()
        XCTAssertEqual(editor.draft(on: a).wallpaperID, third.id, "Applied from Local / menu: the preview follows")
        XCTAssertFalse(editor.isDirty(on: a))
        XCTAssertEqual(editor.draft(on: b).wallpaperID, first.id); XCTAssertEqual(editor.draft(on: b).video.speed, 2)
        // The editor's own apply keeps its draft; stopping keeps the existing behaviour for a dirty draft.
        editor.select(second, on: a); await editor.apply(on: a)
        XCTAssertNil(editor.errors[a]); XCTAssertEqual(editor.draft(on: a).wallpaperID, second.id)
        // Re-applying the wallpaper already showing brings the preview back to it, discarding unapplied edits.
        editor.select(first, on: a); XCTAssertEqual(editor.draft(on: a).wallpaperID, first.id)
        runtime.apply(second, to: a); try await settle()
        XCTAssertEqual(editor.draft(on: a).wallpaperID, second.id); XCTAssertFalse(editor.isDirty(on: a))
        editor.edit(on: b) { $0.video.speed = 3 }
        runtime.apply(first, to: b); try await settle()
        XCTAssertEqual(editor.draft(on: b).video.speed, 1); XCTAssertFalse(editor.isDirty(on: b))
        XCTAssertEqual(runtime.activeWallpaper(on: b)?.id, first.id)
        editor.select(third, on: a); runtime.stop(.display(a)); try await settle()
        XCTAssertEqual(editor.draft(on: a).wallpaperID, third.id)
    }
    func testApplySameWallpaperOnlyToTargetKeepsOtherRendererPauseAudioAndSource() async throws {
        let wallpaper = try wallpaper()
        runtime.apply(wallpaper, to: a); runtime.apply(wallpaper, to: b); try await settle()
        let other = created.last!
        runtime.pause(.display(a)); runtime.setAudioEnabled(true, on: a)
        editor.edit(on: a) { $0.video.speed = 2; $0.video.effect = .sepia }
        await editor.apply(on: a)
        XCTAssertNil(editor.errors[a]); XCTAssertFalse(editor.isDirty(on: a))
        XCTAssertEqual(created.last?.configuration.video.speed, 2)
        XCTAssertTrue(created.last!.paused); XCTAssertFalse(created.last!.muted)
        XCTAssertFalse(other.disposed); XCTAssertEqual(editor.draft(on: b).video.speed, 1)
        XCTAssertEqual(runtime.state(of: a)?.playbackState, .manualPaused)
        XCTAssertEqual(runtime.state(of: b)?.playbackState, .playing)
        XCTAssertEqual(video.configuration(for: wallpaper.id), .init())
        XCTAssertEqual(try Data(contentsOf: wallpaper.resourceURL), Data("source unchanged".utf8))
        let reopened = makeEditor()
        XCTAssertEqual(reopened.draft(on: a).video.speed, 2)
        XCTAssertEqual(reopened.draft(on: b).video.speed, 1)
    }
    func testFailedApplyRetainsOldFrameDirtyDraftAndPreviouslyAppliedSettings() async throws {
        let wallpaper = try wallpaper()
        runtime.apply(wallpaper, to: a); try await settle(); let old = created.last!
        editor.edit(on: a) { $0.video.speed = 0.5 }; fail = true
        await editor.apply(on: a)
        XCTAssertNotNil(editor.errors[a]); XCTAssertTrue(editor.canApply(on: a))
        XCTAssertFalse(old.disposed); XCTAssertTrue(created.last!.disposed)
        XCTAssertEqual(editor.draft(on: a).video.speed, 0.5)
        XCTAssertEqual(makeEditor().draft(on: a).video.speed, 1)
        fail = false; await editor.apply(on: a)
        XCTAssertNil(editor.errors[a]); XCTAssertFalse(editor.isDirty(on: a)); XCTAssertTrue(old.disposed)
    }
    func testDisconnectNeverFallsBackAndRetainsStableDraft() async throws {
        let wallpaper = try wallpaper()
        editor.select(wallpaper, on: a); editor.edit(on: a) { $0.video.speed = 2 }
        runtime.removeDisplay(a)
        XCTAssertFalse(editor.canApply(on: a))
        await editor.apply(on: a)
        XCTAssertTrue(created.isEmpty); XCTAssertNil(runtime.activeWallpaper(on: b))
        runtime.addDisplay(a, host: DisplayEditorHost())
        XCTAssertEqual(editor.draft(on: a).video.speed, 2); XCTAssertTrue(editor.canApply(on: a))
    }
    func testEditsDuringPrepareAreKeptAndConcurrentDisplaysDoNotOverwriteEachOther() async throws {
        let wallpaper = try wallpaper()
        editor.select(wallpaper, on: a); editor.select(wallpaper, on: b)
        editor.edit(on: a) { $0.video.speed = 2 }; editor.edit(on: b) { $0.video.speed = 0.5 }
        delay = 100_000_000
        async let first: Void = editor.apply(on: a)
        async let second: Void = editor.apply(on: b)
        try await Task.sleep(nanoseconds: 30_000_000)
        editor.edit(on: a) { $0.video.speed = 1.5 }
        _ = await (first, second)
        XCTAssertNil(editor.errors[a]); XCTAssertNil(editor.errors[b])
        XCTAssertEqual(editor.applied[a]?.video.speed, 2)
        XCTAssertEqual(editor.draft(on: a).video.speed, 1.5); XCTAssertTrue(editor.isDirty(on: a))
        XCTAssertEqual(editor.applied[b]?.video.speed, 0.5); XCTAssertFalse(editor.isDirty(on: b))
        let restored = makeEditor()
        XCTAssertEqual(restored.draft(on: a).video.speed, 2); XCTAssertEqual(restored.draft(on: b).video.speed, 0.5)
    }
    func testGlobalSettingsSavePreservesOriginalAllMatchingMeaning() async throws {
        let wallpaper = try wallpaper()
        runtime.apply(wallpaper, to: a); runtime.apply(wallpaper, to: b); try await settle()
        editor.edit(on: a) { $0.video.speed = 2 }; await editor.apply(on: a)
        var global = VideoPlaybackOptions(); global.speed = 0.5
        try video.save(global, for: wallpaper, runtime: runtime); try await settle()
        XCTAssertEqual(editor.configuration(for: wallpaper, on: a).video.speed, 0.5)
        XCTAssertEqual(editor.configuration(for: wallpaper, on: b).video.speed, 0.5)
        XCTAssertEqual(Array(created.suffix(2)).map { $0.configuration.video.speed }, [0.5, 0.5])
    }
    func testUnrelatedGlobalSceneFitChangeDoesNotInvalidateVideoApplyOrDirtyItsDraft() async throws {
        let wallpaper = try wallpaper()
        _ = try self.wallpaper(.scene)
        runtime.apply(wallpaper, to: b); try await settle()
        editor.edit(on: b) { $0.video.speed = 2 }
        delay = 120_000_000
        async let applying: Void = editor.apply(on: b)
        try await Task.sleep(nanoseconds: 25_000_000)
        settings.set(\.sceneDisplayFit, to: .fit)
        await applying
        XCTAssertNil(editor.errors[b]); XCTAssertFalse(editor.isDirty(on: b))
        XCTAssertEqual(editor.draft(on: b).sceneFit, .automatic)
        XCTAssertEqual(makeEditor().draft(on: b).video.speed, 2)
    }
    /// 显示方式 › 自定义（2026-10-08）：范围随「应用」保存并送到桌面；全局场景显示方式改变时保留手动选定的范围。
    func testCustomDisplayFrameIsAppliedSavedAndSurvivesGlobalSceneFitChanges() async throws {
        let video = try wallpaper(), custom = try self.wallpaper(.scene, name: "自定义"), plain = try self.wallpaper(.scene, name: "填满")
        runtime.apply(video, to: a); try await settle()
        let frame = CustomDisplayFrame(zoom: 2, centerX: 0.3, centerY: 0.6)
        editor.edit(on: a) { $0.video.displayFit = .custom; $0.video.customFrame = frame }
        XCTAssertTrue(editor.canApply(on: a))
        await editor.apply(on: a)
        XCTAssertNil(editor.errors[a])
        XCTAssertEqual(created.last?.configuration.video.customFrame, frame)
        XCTAssertEqual(makeEditor().configuration(for: video, on: a).video.customFrame, frame, "saved per display and wallpaper")
        XCTAssertNil(editor.configuration(for: video, on: b).video.customFrame, "other displays keep their own")

        var record = StagedDisplayWallpaperConfiguration(wallpaperID: custom.id)
        record.sceneFit = .custom; record.sceneCustomFrame = frame
        var other = StagedDisplayWallpaperConfiguration(wallpaperID: plain.id); other.sceneFit = .fill
        let encode = { (value: StagedDisplayWallpaperConfiguration) in try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        try JSONSerialization.data(withJSONObject: ["version": 1, "displays": [b.rawValue: [
            custom.id.uuidString: try encode(record), plain.id.uuidString: try encode(other)]]]).write(to: editor.fileURL)
        editor = makeEditor()
        settings.set(\.sceneDisplayFit, to: .fit)
        XCTAssertEqual(editor.configuration(for: custom, on: b).sceneFit, .custom)
        XCTAssertEqual(editor.configuration(for: custom, on: b).sceneCustomFrame, frame)
        XCTAssertEqual(editor.configuration(for: plain, on: b).sceneFit, .fit, "other per-display choices follow the global setting as before")
        XCTAssertEqual(makeEditor().configuration(for: custom, on: b).sceneCustomFrame, frame)
    }
    func testWriteFailureAndInvalidDraftDoNotPrepareOrChangeDesktop() async throws {
        let wallpaper = try wallpaper(); editor.select(wallpaper, on: a)
        editor.edit(on: a) { $0.video.speed = .infinity }
        await editor.apply(on: a); XCTAssertNotNil(editor.errors[a]); XCTAssertTrue(created.isEmpty)
        editor.edit(on: a) { $0.video.speed = 2 }
        try FileManager.default.createDirectory(at: editor.fileURL, withIntermediateDirectories: false)
        await editor.apply(on: a); XCTAssertNotNil(editor.errors[a]); XCTAssertTrue(created.isEmpty)
        XCTAssertNil(runtime.activeWallpaper(on: a)); XCTAssertTrue(editor.isDirty(on: a))
    }
    func testSessionOnlyDisplayIsNotSavedAndMismatchedStoredIdentityIsRejected() async throws {
        let wallpaper = try wallpaper()
        let transient = DisplayID("session-display-7")
        runtime.addDisplay(transient, host: DisplayEditorHost())
        editor.select(wallpaper, on: transient)
        await editor.apply(on: transient)
        XCTAssertNil(editor.errors[transient])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: editor.fileURL)) as? [String: Any])
        XCTAssertEqual((saved["displays"] as? [String: Any])?.count, 0)
        let wrong = StagedDisplayWallpaperConfiguration(wallpaperID: UUID())
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wrong))
        try JSONSerialization.data(withJSONObject: ["version": 1, "displays": [a.rawValue: [wallpaper.id.uuidString: value]]])
            .write(to: editor.fileURL)
        let restored = makeEditor()
        XCTAssertNotNil(restored.loadError)
        XCTAssertFalse(restored.canApply(on: a))
    }
    func testNavigationIsConsumedWithoutAnyPlaybackOrControlledDisplayCommand() {
        let navigation = MainWindowNavigation(); navigation.request(display: b)
        XCTAssertEqual(navigation.requestedDisplay, b); XCTAssertNil(navigation.requestedSection)
        var received: [DisplayID] = []
        let observation = navigation.displayRequests.compactMap { $0 }.sink { id in received.append(id); navigation.consumeDisplay() }
        XCTAssertEqual(received, [b]); XCTAssertNil(navigation.requestedDisplay)
        navigation.request(display: a); XCTAssertEqual(received, [b, a])
        navigation.request(.steam); XCTAssertEqual(navigation.requestedSection, .steam)
        XCTAssertNil(navigation.requestedDisplay); observation.cancel()
        XCTAssertTrue(created.isEmpty); XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("displays"))
    }
    func testPreviewGeometryUsesActualDisplayRatioAndPickerUsesOnlyLocalRecords() throws {
        let builtIn = DisplayRuntimeState(displayID: a, displayName: "内建视网膜显示器", runtime: .init(),
                                        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scaleFactor: 2)
        XCTAssertEqual(DisplayControlLayout.aspectRatio(builtIn), 3024.0 / 1964.0, accuracy: 0.000001)
        let items = try [wallpaper(), wallpaper(.web), wallpaper(.scene)]
        let remote = Wallpaper(name: "remote", type: .web, source: .steam, resourceURL: URL(string: "https://example.invalid")!)
        XCTAssertEqual(DisplayControlPresentation.pickerWallpapers(items + [remote]).map(\.id), items.map(\.id))
        XCTAssertEqual(items.map { DisplayControlPresentation.typeName($0.type) }, ["视频", "Web", "Scene"])
        // The wallpaper in use is pinned above the list and not repeated in it.
        var split = DisplayControlPresentation.pinnedPicker(items + [remote], activeID: items[1].id)
        XCTAssertEqual(split.inUse?.id, items[1].id); XCTAssertEqual(split.others.map(\.id), [items[0].id, items[2].id])
        split = DisplayControlPresentation.pinnedPicker(items, activeID: remote.id)
        XCTAssertNil(split.inUse); XCTAssertEqual(split.others.map(\.id), items.map(\.id))
        XCTAssertNil(DisplayControlPresentation.pinnedPicker(items, activeID: nil).inUse)
    }

    func testNativeMainWindowAndCenteredListModalLayoutsInLightDarkAndNarrowWindows() async throws {
        let output = TestWorkspaceDirectory.make(".build/SidebarDisplayRevision/LayoutSnapshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lists = LocalOrganizationStore(storage: library.storage)
        _ = try lists.createList(name: "夜间"); _ = try lists.createList(name: "工作")
        let navigation = MainWindowNavigation()
        let importer = LocalImportService(library: library)
        // Keep all three native windows within this Mac's visible screen; AppKit
        // otherwise constrains a 1560-point test window to 1512 points on orderBack.
        for (width, height) in [(900.0, 600.0), (1120.0, 760.0), (1400.0, 900.0)] {
            for mode in [NSAppearance.Name.aqua, .darkAqua] {
                let view = LibraryShellView(library: library, runtime: runtime, importer: importer,
                    steam: nil, store: nil, steamApply: nil, navigation: navigation, displayEditor: editor, settings: settings)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height),
                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: mode)
                window.contentView = host; window.orderBack(nil)
                try await Task.sleep(nanoseconds: 150_000_000)
                navigation.request(display: a)
                try await Task.sleep(nanoseconds: 150_000_000)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.frame.width, width, accuracy: 1)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("display-\(Int(width))-\(mode.rawValue).png"))
                window.close()
            }
        }
        let modal = NSHostingView(rootView: NewWallpaperListModal(onCancel: {}, onCreate: { _, _, _ in false }))
        modal.frame = CGRect(x: 0, y: 0, width: 360, height: 320); modal.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(modal.bitmapImageRepForCachingDisplay(in: modal.bounds))
        modal.cacheDisplay(in: modal.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("list-modal.png"))
    }

    /// 2026-10-08: overlay button beside the display name, widgets drawn on the display preview.
    func testDisplayPageOverlayButtonAndWidgetsOnPreviewSnapshots() async throws {
        let output = TestWorkspaceDirectory.make(".build/OverlayMigration/Snapshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let storage = LibraryStorageLocation(rootURL: root)
        let descriptor = DisplayDescriptor(id: a, name: "内建视网膜显示器",
            desktop: .init(id: 1, frame: .init(x: -6000, y: -6000, width: 1512, height: 982), backingScaleFactor: 2), isPersistent: true)
        let registry = DisplayRegistry(discover: { [descriptor] }); registry.start(); defer { registry.stop() }
        let manager = OverlayManager(store: .init(storage: storage), registry: registry, readReduceMotion: { false },
                                     makeSurface: { OverlayWindowOwner(displayID: $0) })
        let repository = WidgetLayoutRepository(storage: storage), contents = WidgetContentRegistry()
        manager.register(.widgets) { _ in WidgetBoardOverlay(repository: repository, registry: contents) }; manager.start()
        defer { manager.shutdown() }
        let widgets = WidgetBoardEditorModel(manager: manager, registry: registry, repository: repository, contents: contents)
        widgets.add(.cpu, on: a); widgets.add(.memory, on: a); widgets.add(.weather, on: a)
        let large = try XCTUnwrap(widgets.draft(on: a).layout.widgets.last?.id)
        widgets.edit(large, on: a) { $0.size = .large }
        widgets.selectDisplay(a); widgets.isEnabled = true
        XCTAssertTrue(widgets.canApply(on: a))
        // Particles and the clock preview on the same thumbnail (user, 2026-10-08).
        let particles = ParticleEditorModel(manager: manager, registry: registry, readReduceMotion: { false })
        particles.selectDisplay(a); particles.isEnabled = true; particles.options.preset = .snow; particles.options.density = 0.8
        let clock = NixieClockEditorModel(manager: manager, registry: registry)
        clock.selectDisplay(a); clock.isEnabled = true
        let editors = DisplayOverlayEditors(particles: particles, clock: clock, widgets: widgets)
        XCTAssertTrue(editors.canApply(on: a)); XCTAssertFalse(editors.canApply(on: b))
        let menu = DisplayOverlayMenu(entries: ["particles.title", "widgets.title", "clock.title", "agentSessions.settings.title"].map { key in
            DisplayOverlayMenu.Entry(id: key, titleKey: key, detailKey: nil) { _ in }
        })
        let navigation = MainWindowNavigation(), importer = LocalImportService(library: library)
        for mode in [NSAppearance.Name.aqua, .darkAqua] {
            let view = LibraryShellView(library: library, runtime: runtime, importer: importer, steam: nil, store: nil, steamApply: nil,
                navigation: navigation, displayEditor: editor, settings: settings, overlayMenu: menu, overlays: editors)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: mode)
            window.contentView = host; window.orderBack(nil)
            try await Task.sleep(nanoseconds: 150_000_000)
            navigation.request(display: a)
            try await Task.sleep(nanoseconds: 400_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("display-widgets-\(mode.rawValue).png"))
            window.close()
        }
    }

    func testRealScenePreviewResourceCostAndRelease() async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resourceRecord = base.appendingPathComponent(".build/ScenePlaybackFreeze-3326873240/current-resource.json")
        guard let data = try? Data(contentsOf: resourceRecord),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = record["root"] as? String,
              FileManager.default.fileExists(atPath: path) else { throw XCTSkip("This machine-specific Scene was not supplied") }
        let assets = EngineAssetsStore.standardManagedInstallURL()
        guard FileManager.default.fileExists(atPath: assets.appendingPathComponent("assets").path) else {
            throw XCTSkip("User-owned engine assets are not installed")
        }
        let previousAssets = SceneRenderer.engineAssetsProvider
        SceneRenderer.engineAssetsProvider = { assets }
        defer { SceneRenderer.engineAssetsProvider = previousAssets }
        let wall = Wallpaper(name: "Scene preview QA", type: .scene, source: .steam, resourceURL: URL(fileURLWithPath: path))
        let preview = DisplayScenePreview()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 312),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = preview.surface; window.orderBack(nil)
        defer { preview.stop(); window.close() }
        let baseline = try XCTUnwrap(LivePreviewDiagnostics.memoryFootprint())
        preview.update(wall, values: [:], fit: .automatic, aspect: 1512 / 982)
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while preview.isPreparing && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNil(preview.error); XCTAssertNotNil(preview.renderer)
        let loaded = try XCTUnwrap(LivePreviewDiagnostics.memoryFootprint())
        let delta = loaded > baseline ? loaded - baseline : 0
        try await Task.sleep(nanoseconds: 300_000_000)
        let renderedDimensions: [Int]
        if let frame = await preview.renderer?.scene.capturePreviewFrame() { renderedDimensions = [frame.width, frame.height] }
        else { renderedDimensions = [] }
        XCTAssertEqual(renderedDimensions.count, 2)
        XCTAssertLessThanOrEqual(renderedDimensions.first ?? Int.max, Int(DisplayControlLayout.maximumPreviewWidth * window.backingScaleFactor))
        XCTAssertLessThanOrEqual(renderedDimensions.last ?? Int.max, Int(312 * window.backingScaleFactor))
        let beforeTime = try XCTUnwrap(preview.renderer).scene.sceneTime
        preview.update(wall, values: [:], fit: .fit, aspect: 1512 / 982)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(preview.renderer).scene.sceneTime, beforeTime)
        weak var retiringRenderer = preview.renderer
        weak var retiringRuntime = preview.renderer?.scene
        weak var retiringHost = preview.renderer?.scene.fullHostForTesting
        preview.stop(); window.close()
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 10
        var released = try XCTUnwrap(LivePreviewDiagnostics.memoryFootprint())
        while (retiringRenderer != nil || retiringRuntime != nil || retiringHost != nil) && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            released = try XCTUnwrap(LivePreviewDiagnostics.memoryFootprint())
        }
        XCTAssertNil(preview.renderer)
        XCTAssertNil(retiringRenderer); XCTAssertNil(retiringRuntime); XCTAssertNil(retiringHost)
        var report: [String: Any] = ["baseline": baseline, "loaded": loaded, "delta": delta,
                                   "released": released, "previewWidthPoints": 480, "fpsCeiling": 30,
                                   "rendererReleased": retiringRenderer == nil, "runtimeReleased": retiringRuntime == nil,
                                   "hostReleased": retiringHost == nil,
                                   "renderedDimensions": renderedDimensions, "pid": ProcessInfo.processInfo.processIdentifier]
        var repeatCycles: [[String: Any]] = []
        for _ in 0..<2 {
            window.orderBack(nil)
            preview.update(wall, values: [:], fit: .automatic, aspect: 1512 / 982)
            let deadline = ProcessInfo.processInfo.systemUptime + 25
            while preview.isPreparing && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertNil(preview.error); XCTAssertNotNil(preview.renderer)
            let loaded = LivePreviewDiagnostics.memoryFootprint()
            weak var renderer = preview.renderer
            weak var runtime = preview.renderer?.scene
            weak var host = preview.renderer?.scene.fullHostForTesting
            preview.stop(); window.close()
            let releaseDeadline = ProcessInfo.processInfo.systemUptime + 10
            while (renderer != nil || runtime != nil || host != nil) && ProcessInfo.processInfo.systemUptime < releaseDeadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertNil(renderer); XCTAssertNil(runtime); XCTAssertNil(host)
            repeatCycles.append(["loaded": loaded, "released": LivePreviewDiagnostics.memoryFootprint(),
                                 "rendererReleased": renderer == nil, "runtimeReleased": runtime == nil, "hostReleased": host == nil])
        }
        report["repeatCycles"] = repeatCycles
        // Cold-start Metal / allocator residency depends on earlier tests. Check
        // actual resolution, full object retirement and bounded warm cycles,
        // rather than treating all process-resident bytes as live Scene assets.
        if let firstReleased = repeatCycles.first?["released"] as? UInt64,
           let lastReleased = repeatCycles.last?["released"] as? UInt64 {
            XCTAssertLessThanOrEqual(lastReleased, firstReleased + 64 * 1_024 * 1_024)
        }
        let reportDirectory = TestWorkspaceDirectory.make(".build/SidebarDisplayRevision")
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportDirectory.appendingPathComponent("real-scene-preview-memory.json"))
        // Allow a read-only VM sample to distinguish retained scene objects from
        // process-wide Metal / allocator residency after the preview disappears.
    }
}
