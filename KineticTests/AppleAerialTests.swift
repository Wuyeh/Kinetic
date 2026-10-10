import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor private final class AerialHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}

@MainActor
final class AppleAerialTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func root() throws -> URL {
        let root = TestWorkspaceDirectory.make(".build/Module32/Fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root); return root
    }
    private var bookmarks: EngineAssetsBookmarks {
        .init(make: { try $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) },
              resolve: { data in
                  var stale = false
                  return (try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), stale)
              })
    }
    private func sample(in root: URL, id: UUID = UUID(), real: Bool = false) throws -> URL {
        let folder = root.appendingPathComponent("4KSDR240FPS")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(id.uuidString + ".mov")
        if real {
            let source = try XCTUnwrap(Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: url)
        } else { try Data("local video placeholder".utf8).write(to: url) }
        return url
    }
    private func catalog(_ folder: URL, storage: URL? = nil) throws -> AppleAerialCatalog {
        let catalog = AppleAerialCatalog(storage: .init(rootURL: try storage ?? root()), bookmarks: bookmarks, defaultFolders: [folder])
        return catalog
    }
    private func wait(_ test: () -> Bool, timeout: Double = 10) async throws {
        let limit = ProcessInfo.processInfo.systemUptime + timeout
        while !test() {
            guard ProcessInfo.processInfo.systemUptime < limit else { throw VideoRendererError.preparationTimedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testScanShowsOnlyDownloadedUUIDVideosAndUsesLocalChineseMetadata() throws {
        let root = try root(), id = UUID(), absent = UUID(), video = try sample(in: root, id: id)
        let json: [String: Any] = ["assets": [
            ["id": id.uuidString.lowercased(), "localizedNameKey": "flight", "accessibilityLabel": "Ocean", "categories": ["ocean"], "previewImage": "https://example.invalid/never-read.png"],
            ["id": absent.uuidString, "accessibilityLabel": "Not downloaded", "url-4K-SDR-240FPS": "https://example.invalid/never-download.mov"]],
            "categories": [["id": "ocean", "localizedNameKey": "category"]]]
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("entries.json"))
        let localization = root.appendingPathComponent("TVIdleScreenStrings.bundle/zh_CN.lproj")
        try FileManager.default.createDirectory(at: localization, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["flight": "太平洋航拍", "category": "水下"], format: .binary, options: 0)
            .write(to: localization.appendingPathComponent("Localizable.nocache.strings"))
        try Data("ordinary".utf8).write(to: root.appendingPathComponent("personal.mov"))
        try Data().write(to: root.appendingPathComponent(UUID().uuidString + ".mov"))
        let scan = try AppleAerialScanner.scan(root), asset = try XCTUnwrap(scan.assets.first)
        XCTAssertEqual(scan.assets.count, 1); XCTAssertEqual(asset.name, "太平洋航拍")
        XCTAssertEqual(asset.category, "水下"); XCTAssertEqual(asset.url, video); XCTAssertFalse(scan.metadataUnavailable)
        XCTAssertTrue(asset.matchesSearch("太平洋")); XCTAssertTrue(asset.matchesSearch(id.uuidString.lowercased()))
        XCTAssertFalse(asset.matchesSearch("absent")); XCTAssertEqual(asset.previewWallpaper.acquisitionOrigin, .appleAerial)
    }
    func testScanRejectsSymlinkEscapeAndDoesNotReadMetadataAboveSelectedFolder() throws {
        let root = try root(), outside = try self.root(), id = UUID(), original = try sample(in: outside, id: id)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(id.uuidString + ".mov"), withDestinationURL: original)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: outside)
        XCTAssertTrue(try AppleAerialScanner.scan(root).assets.isEmpty)
        let video = try sample(in: root)
        try Data("not valid metadata".utf8).write(to: root.appendingPathComponent("entries.json"))
        let selected = video.deletingLastPathComponent(), scan = try AppleAerialScanner.scan(selected)
        XCTAssertEqual(scan.assets.count, 1); XCTAssertTrue(scan.metadataUnavailable)
        XCTAssertTrue(scan.assets[0].name.hasPrefix("Apple 航拍"))
        XCTAssertFalse(AppleAerialScanner.contains(original, in: root))
        let symlink = outside.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
        XCTAssertThrowsError(try AppleAerialScanner.scan(symlink))
    }
    func testDuplicateEncodingsAndUnsupportedMetadataRemainSafe() throws {
        let root = try root(), id = UUID(), video = try sample(in: root, id: id)
        try Data("other encoding".utf8).write(to: root.appendingPathComponent(id.uuidString + ".mp4"))
        try Data(repeating: 0, count: AppleAerialScanner.maximumMetadataBytes + 1).write(to: root.appendingPathComponent("entries.json"))
        let first = try AppleAerialScanner.scan(root), second = try AppleAerialScanner.scan(root)
        XCTAssertEqual(first.assets.count, 1); XCTAssertEqual(first.assets, second.assets); XCTAssertTrue(first.metadataUnavailable)
        let ordinary = Wallpaper(name: "same name", type: .video, acquisitionOrigin: .localImport, resourceURL: video)
        XCTAssertFalse(first.assets[0].matches(ordinary), "Provenance is explicit, never guessed from UUID paths")
    }
    func testReadonlyBookmarkRoundTripAndCorruptSettingsPreservation() async throws {
        let folder = try root(), storage = try root(); _ = try sample(in: folder)
        let catalog = try catalog(folder, storage: storage)
        XCTAssertTrue(catalog.assets.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.fileURL.path))
        try catalog.link(folder); await catalog.refresh(); XCTAssertEqual(catalog.assets.count, 1)
        let restored = AppleAerialCatalog(storage: .init(rootURL: storage), bookmarks: bookmarks, defaultFolders: [])
        await restored.refresh(); XCTAssertEqual(restored.assets, catalog.assets)
        for data in [Data("bad".utf8), Data(#"{"version":2,"bookmark":"AA=="}"#.utf8)] {
            let brokenRoot = try root(), file = brokenRoot.appendingPathComponent("apple-aerials.json")
            try data.write(to: file)
            let broken = AppleAerialCatalog(storage: .init(rootURL: brokenRoot), bookmarks: bookmarks, defaultFolders: [])
            XCTAssertNotNil(broken.loadError); XCTAssertThrowsError(try broken.link(folder))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }
    func testCancelledOldScanCannotReplaceNewFolderAndFailedRefreshKeepsList() async throws {
        let old = try root(), new = try root(); _ = try sample(in: old); _ = try sample(in: new)
        let oldScan = try AppleAerialScanner.scan(old), newScan = try AppleAerialScanner.scan(new)
        let catalog = AppleAerialCatalog(storage: .init(rootURL: try root()), bookmarks: bookmarks, defaultFolders: [old], scanner: { url in
            if url == old { Thread.sleep(forTimeInterval: 0.2); return oldScan }
            return newScan
        })
        let first = Task { await catalog.refresh() }
        try await Task.sleep(nanoseconds: 30_000_000); try catalog.link(new); await catalog.refresh(); await first.value
        XCTAssertEqual(catalog.assets, newScan.assets); XCTAssertFalse(catalog.isScanning)
        try FileManager.default.removeItem(at: newScan.assets[0].url)
        XCTAssertThrowsError(try catalog.validatedAccess(for: newScan.assets[0]))
        let realCatalog = try self.catalog(old); await realCatalog.refresh()
        let before = realCatalog.assets; try FileManager.default.removeItem(at: old); await realCatalog.refresh()
        XCTAssertEqual(realCatalog.assets, before); XCTAssertNotNil(realCatalog.error)
    }
    func testImportCopiesWithExplicitOriginAndTitleAndDeduplicatesAcrossRestart() async throws {
        let folder = try root(), source = try sample(in: folder, real: true), original = try Data(contentsOf: source)
        let catalog = try catalog(folder); await catalog.refresh()
        let storage = try root(), library = WallpaperLibrary(storage: .init(rootURL: storage)), runtime = WallpaperRuntimeManager()
        defer { runtime.shutdown() }
        let model = AppleAerialBrowserModel(catalog: catalog, library: library, importer: LocalImportService(library: library), runtime: runtime)
        model.opened(); model.select(catalog.assets.first?.id)
        let result = await model.addSelected(), added = try XCTUnwrap(result)
        XCTAssertEqual(added.acquisitionOrigin, .appleAerial); XCTAssertEqual(added.type, .video)
        XCTAssertEqual(added.name, catalog.assets[0].name); XCTAssertEqual(library.wallpapers(in: .local).count, 1)
        XCTAssertNotEqual(added.resourceURL, source); XCTAssertEqual(try Data(contentsOf: added.resourceURL), original)
        XCTAssertEqual(try Data(contentsOf: source), original); XCTAssertTrue(runtime.displayIDs.isEmpty)
        let secondResult = await model.addSelected(), again = try XCTUnwrap(secondResult); XCTAssertEqual(again.id, added.id)
        let restored = WallpaperLibrary(storage: .init(rootURL: storage))
        let second = AppleAerialBrowserModel(catalog: catalog, library: restored, importer: LocalImportService(library: restored), runtime: runtime)
        second.select(catalog.assets[0].id); let thirdResult = await second.addSelected(), third = try XCTUnwrap(thirdResult)
        XCTAssertEqual(third.id, added.id); XCTAssertEqual(restored.wallpapers.count, 1)
        model.closed(); second.closed()
    }
    func testPreviewIsSilentAndClosingDoesNotChangeDesktopOrWriteLibrary() async throws {
        let folder = try root(); _ = try sample(in: folder, real: true)
        let catalog = try catalog(folder); await catalog.refresh()
        let storage = try root(), library = WallpaperLibrary(storage: .init(rootURL: storage))
        var created: [VideoRenderer] = []
        let runtime = WallpaperRuntimeManager { wallpaper in let r = VideoRenderer(wallpaper: wallpaper, options: .init()); created.append(r); return r }
        defer { runtime.shutdown() }
        let display = DisplayID("aerial-desktop"), host = AerialHost(), wallpaper = catalog.assets[0].previewWallpaper
        runtime.addDisplay(display, host: host); runtime.apply(wallpaper, to: display)
        try await wait { runtime.state(of: display)?.playbackState == .playing }
        let desktop = try XCTUnwrap(created.first), view = host.content
        let model = AppleAerialBrowserModel(catalog: catalog, library: library, importer: LocalImportService(library: library), runtime: runtime)
        model.opened(); model.select(catalog.assets[0].id)
        try await wait { model.preview.renderer != nil && !model.preview.isPreparing }
        let preview = try XCTUnwrap(model.preview.renderer as? VideoRenderer)
        XCTAssertTrue(preview.isMuted); XCTAssertFalse(preview === desktop)
        XCTAssertTrue(host.content === view); XCTAssertEqual(created.count, 1)
        XCTAssertTrue(library.wallpapers.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: library.storage.libraryFileURL.path))
        model.closed(); XCTAssertNil(model.preview.renderer)
        XCTAssertTrue(host.content === view); XCTAssertEqual(runtime.state(of: display)?.playbackState, .playing)
    }
    func testApplyWaitsForExplicitTargetAndFailureKeepsBothDesktops() async throws {
        let folder = try root(); _ = try sample(in: folder, real: true)
        let catalog = try catalog(folder); await catalog.refresh()
        let library = WallpaperLibrary(storage: .init(rootURL: try root()))
        var fail = false
        let runtime = WallpaperRuntimeManager { wallpaper in
            if fail { throw VideoRendererError.unplayable }
            return VideoRenderer(wallpaper: wallpaper, options: .init())
        }
        defer { runtime.shutdown() }
        let a = DisplayID("aerial-A"), b = DisplayID("aerial-B"), ha = AerialHost(), hb = AerialHost()
        runtime.addDisplay(a, host: ha); runtime.addDisplay(b, host: hb)
        let original = catalog.assets[0].previewWallpaper
        runtime.apply(original, to: a); runtime.apply(original, to: b)
        try await wait { runtime.state(of: a)?.playbackState == .playing && runtime.state(of: b)?.playbackState == .playing }
        runtime.pause(.display(b)); let oldA = ha.content, oldB = hb.content
        let model = AppleAerialBrowserModel(catalog: catalog, library: library, importer: LocalImportService(library: library), runtime: runtime)
        model.opened(); model.select(catalog.assets[0].id)
        let result = await model.addSelected(thenChooseDisplay: true), added = try XCTUnwrap(result)
        XCTAssertEqual(model.applyWallpaperID, added.id); XCTAssertTrue(ha.content === oldA); XCTAssertTrue(hb.content === oldB)
        fail = true; model.apply(to: a)
        XCTAssertTrue(ha.content === oldA); XCTAssertTrue(hb.content === oldB); XCTAssertNotNil(runtime.lastFailure)
        XCTAssertNil(model.applyWallpaperID); XCTAssertEqual(runtime.state(of: b)?.playbackState, .manualPaused)
        fail = false; _ = await model.addSelected(thenChooseDisplay: true); model.apply(to: a)
        try await wait { runtime.activeWallpaper(on: a)?.id == added.id }
        XCTAssertTrue(hb.content === oldB); XCTAssertEqual(runtime.state(of: b)?.playbackState, .manualPaused)
        model.closed(); XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, added.id)
    }
    func testInvalidVideoAndMissingTargetDoNotApplyOrCreateFakeRecords() async throws {
        let folder = try root(); _ = try sample(in: folder)
        let catalog = try catalog(folder); await catalog.refresh()
        let library = WallpaperLibrary(storage: .init(rootURL: try root())), runtime = WallpaperRuntimeManager()
        defer { runtime.shutdown() }
        let model = AppleAerialBrowserModel(catalog: catalog, library: library, importer: LocalImportService(library: library), runtime: runtime)
        model.opened(); model.select(catalog.assets[0].id)
        let result = await model.addSelected()
        XCTAssertNil(result); XCTAssertTrue(library.wallpapers.isEmpty); XCTAssertNotNil(model.error)
        model.applyWallpaperID = UUID(); model.apply(to: DisplayID("removed"))
        XCTAssertNil(model.applyWallpaperID); XCTAssertNotNil(model.notice); XCTAssertTrue(runtime.displayIDs.isEmpty)
        model.closed()
    }
    func testBrowserWindowReuseAndCloseDisposesPreview() async throws {
        let folder = try root(); _ = try sample(in: folder, real: true)
        let catalog = try catalog(folder); await catalog.refresh()
        let library = WallpaperLibrary(storage: .init(rootURL: try root())), runtime = WallpaperRuntimeManager()
        defer { runtime.shutdown() }
        let model = AppleAerialBrowserModel(catalog: catalog, library: library, importer: LocalImportService(library: library), runtime: runtime)
        let browser = AppleAerialBrowserWindow(model: model, runtime: runtime)
        let window = browser.show(activate: false)
        XCTAssertTrue(browser.show(activate: false) === window)
        try await wait { model.preview.renderer != nil && !model.preview.isPreparing }
        browser.close(); XCTAssertNil(browser.window); XCTAssertNil(model.preview.renderer)
        XCTAssertTrue(library.wallpapers.isEmpty); XCTAssertTrue(runtime.displayIDs.isEmpty)
        _ = browser.show(activate: false); browser.close()
        try await Task.sleep(nanoseconds: 120_000_000); XCTAssertNil(model.preview.renderer)
    }
    func testBrowserLayoutDefaultAndMinimumLightDarkAndNoSaveOnClose() async throws {
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        let folder = try root(); _ = try sample(in: folder, real: true)
        let catalog = try catalog(folder); await catalog.refresh()
        let library = WallpaperLibrary(storage: .init(rootURL: try root())), runtime = WallpaperRuntimeManager()
        defer { runtime.shutdown() }
        let snapshots = TestWorkspaceDirectory.make(".build/Module32/Snapshots").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [CGSize(width: 860, height: 590), CGSize(width: 680, height: 480)] {
                NSApp.appearance = NSAppearance(named: appearance)
                let model = AppleAerialBrowserModel(catalog: catalog, library: library, importer: LocalImportService(library: library), runtime: runtime)
                let browser = AppleAerialBrowserWindow(model: model, runtime: runtime)
                let window = browser.show(activate: false)
                window.setContentSize(size); window.setFrameOrigin(.init(x: -5000, y: -5000))
                try await wait { model.preview.renderer != nil && !model.preview.isPreparing }
                try await Task.sleep(nanoseconds: 80_000_000)
                let host = try XCTUnwrap(window.contentView); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: snapshots.appendingPathComponent("aerials-\(appearance.rawValue)-\(Int(size.width)).png"))
                XCTAssertGreaterThan(data.count, 10_000); browser.close(); XCTAssertNil(model.preview.renderer)
                XCTAssertTrue(library.wallpapers.isEmpty); XCTAssertTrue(runtime.displayIDs.isEmpty)
            }
        }
    }
}
