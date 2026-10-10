import AppKit
import XCTest
@testable import Kinetic

@MainActor private final class ProviderHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}

@MainActor private final class ProviderRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    init(_ wallpaper: Wallpaper) { self.wallpaper = wallpaper }
    func prepare() async throws {}
    func play() {}; func pause() {}; func resume() {}
    func setMuted(_ muted: Bool) {}; func dispose() {}
}

/// Stands in for NSWorkspace so the tests never change the real desktop picture.
@MainActor private final class FakePictures: SystemDesktopPictures {
    var current: [DisplayID: SystemDesktopPicture] = [:]
    var sets: [(DisplayID, SystemDesktopPicture)] = []
    func current(on display: DisplayID) -> SystemDesktopPicture? { current[display] }
    func set(_ picture: SystemDesktopPicture, on display: DisplayID) throws {
        sets.append((display, picture)); current[display] = picture
    }
}

@MainActor
final class SystemWallpaperProviderTests: XCTestCase {
    private var root: URL!
    private var library: WallpaperLibrary!
    private var runtime: WallpaperRuntimeManager!
    private var settings: SettingsStore!
    private var pictures: FakePictures!
    private var provider: SystemWallpaperProvider!
    private var captured: [(Wallpaper.ID, DisplayID)] = []
    private var suite = ""
    private let a = DisplayID("display-A"), b = DisplayID("display-B")
    private let originalA = SystemDesktopPicture(url: URL(fileURLWithPath: "/System/Library/Desktop Pictures/A.heic"), scaling: 3, allowClipping: true)
    private let originalB = SystemDesktopPicture(url: URL(fileURLWithPath: "/Users/me/Pictures/B.jpg"))

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SystemWallpaper-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = WallpaperLibrary(storage: .init(rootURL: root))
        runtime = WallpaperRuntimeManager(makeRenderer: { ProviderRenderer($0) })
        runtime.addDisplay(a, host: ProviderHost()); runtime.addDisplay(b, host: ProviderHost())
        suite = "Kinetic.SystemWallpaper.Tests." + UUID().uuidString
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        pictures = FakePictures()
        pictures.current = [a: originalA, b: originalB]
        provider = makeProvider()
    }

    override func tearDown() async throws {
        provider?.shutdown(); runtime?.shutdown()
        provider = nil; runtime = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeProvider() -> SystemWallpaperProvider {
        // A long settle delay keeps the automatic update out of the way; the tests call updateNow themselves.
        SystemWallpaperProvider(storage: .init(rootURL: root), settings: settings, runtime: runtime, library: library,
                                editor: nil, pictures: pictures, capture: { [unowned self] wallpaper, display in
                                    self.captured.append((wallpaper.id, display))
                                    return .init(image: Self.image())
                                }, settleDelay: 1_000)
    }

    private static func image() -> CGImage {
        let context = CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        return context.makeImage()!
    }

    private func wallpapers(_ count: Int) throws -> [Wallpaper] {
        try (0..<count).map { index in
            let value = Wallpaper(name: "壁纸\(index)", type: .video, source: .local,
                                  resourceURL: root.appendingPathComponent(UUID().uuidString + ".mp4"))
            try Data("video".utf8).write(to: value.resourceURL); try library.add(value); return value
        }
    }

    private func settle() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while runtime.summary.displays.contains(where: { $0.runtime.preparingWallpaperID != nil }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayEditingError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func providedFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: provider.folder.path))?.sorted() ?? []
    }

    func testOffByDefaultAndNothingChangesUntilTurnedOn() async throws {
        let items = try wallpapers(1)
        runtime.apply(items[0], to: a); try await settle()
        XCTAssertFalse(SettingsState().systemWallpaperSyncEnabled)
        await provider.updateNow()
        XCTAssertTrue(pictures.sets.isEmpty); XCTAssertTrue(captured.isEmpty)
    }

    func testTurningOnSetsEachDisplaysStillOnceAndKeepsTheOriginal() async throws {
        let items = try wallpapers(3)
        runtime.apply(items[0], to: a); runtime.apply(items[1], to: b); try await settle()
        settings.set(\.systemWallpaperSyncEnabled, to: true)
        await provider.updateNow()
        XCTAssertEqual(Set(pictures.sets.map(\.0)), [a, b])
        XCTAssertEqual(provider.savedOriginal(on: a), originalA)
        XCTAssertEqual(provider.savedOriginal(on: b), originalB)
        let setA = try XCTUnwrap(pictures.current[a])
        XCTAssertTrue(FileManager.default.fileExists(atPath: setA.url.path))
        XCTAssertNotNil(CGImageSourceCreateWithURL(setA.url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(setA.allowClipping, true)
        XCTAssertEqual(providedFiles().count, 2)

        await provider.updateNow()
        XCTAssertEqual(pictures.sets.count, 2, "the same wallpaper is not captured again")
        runtime.apply(items[2], to: a); try await settle()
        await provider.updateNow()
        XCTAssertEqual(pictures.sets.count, 3)
        XCTAssertEqual(pictures.sets.last?.0, a)
        XCTAssertEqual(provider.providedWallpaper(on: a), items[2].id)
        XCTAssertEqual(provider.savedOriginal(on: a), originalA, "the first original is kept, not Kinetic's own still")
        XCTAssertEqual(providedFiles().count, 2, "the previous still of that display is removed")
    }

    func testTurningOffPutsTheOriginalsBackNowOrWhenADisplayReconnects() async throws {
        let items = try wallpapers(2)
        runtime.apply(items[0], to: a); runtime.apply(items[1], to: b); try await settle()
        settings.set(\.systemWallpaperSyncEnabled, to: true)
        await provider.updateNow()
        runtime.removeDisplay(b)
        settings.set(\.systemWallpaperSyncEnabled, to: false)
        XCTAssertEqual(pictures.current[a], originalA)
        XCTAssertNil(provider.savedOriginal(on: a))
        XCTAssertNotNil(provider.savedOriginal(on: b), "b is not connected; its original waits")
        XCTAssertEqual(providedFiles().count, 1)

        runtime.addDisplay(b, host: ProviderHost())
        await provider.updateNow()
        XCTAssertEqual(pictures.current[b], originalB)
        XCTAssertNil(provider.savedOriginal(on: b))
        XCTAssertTrue(providedFiles().isEmpty)
    }

    func testStoppedDisplaysAndEarlierStillsAreHandledSafely() async throws {
        let items = try wallpapers(2)
        runtime.apply(items[0], to: a); runtime.apply(items[1], to: b); try await settle()
        runtime.stop(.display(b))
        // A still from an earlier run is already the system picture of a: it must not become the "original".
        try FileManager.default.createDirectory(at: provider.folder, withIntermediateDirectories: true)
        pictures.current[a] = SystemDesktopPicture(url: provider.folder.appendingPathComponent("old.png"))
        settings.set(\.systemWallpaperSyncEnabled, to: true)
        await provider.updateNow()
        XCTAssertEqual(pictures.sets.map(\.0), [a], "a stopped display is left alone")
        XCTAssertNil(provider.savedOriginal(on: a))
    }

    func testOriginalsAndProvidedStillsSurviveRelaunch() async throws {
        let items = try wallpapers(1)
        runtime.apply(items[0], to: a); try await settle()
        settings.set(\.systemWallpaperSyncEnabled, to: true)
        await provider.updateNow()
        provider.shutdown()
        provider = makeProvider()
        XCTAssertEqual(provider.savedOriginal(on: a), originalA)
        XCTAssertEqual(provider.providedWallpaper(on: a), items[0].id)
        await provider.updateNow()
        XCTAssertEqual(pictures.sets.count, 1, "already provided before the relaunch")
    }

    func testCustomCropAndPlacementMatchTheDisplaysFit() {
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(SystemWallpaperFraming.customCrop(imageSize: size, displayAspect: 16.0 / 9.0, frame: .init()),
                       CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(SystemWallpaperFraming.customCrop(imageSize: size, displayAspect: 16.0 / 9.0,
                                                         frame: .init(zoom: 2, centerX: 0.5, centerY: 0.5)),
                       CGRect(x: 480, y: 270, width: 960, height: 540))
        XCTAssertEqual(SystemWallpaperFraming.customCrop(imageSize: size, displayAspect: 1,
                                                         frame: .init(zoom: 1, centerX: 0, centerY: 0.5)),
                       CGRect(x: 0, y: 0, width: 1080, height: 1080), "a square display, clamped to the left edge")
        XCTAssertEqual(SystemWallpaperFraming.options(for: .fit).clips, false)
        XCTAssertEqual(SystemWallpaperFraming.options(for: .stretch).scaling, .scaleAxesIndependently)
        XCTAssertEqual(SystemWallpaperFraming.options(for: .fill).clips, true)
        let picture = SystemDesktopPicture(url: URL(fileURLWithPath: "/tmp/x.png"),
                                           options: [.imageScaling: NSNumber(value: NSImageScaling.scaleNone.rawValue),
                                                     .allowClipping: NSNumber(value: false), .fillColor: NSColor.red])
        XCTAssertEqual(picture.scaling, NSImageScaling.scaleNone.rawValue)
        XCTAssertEqual(picture.allowClipping, false)
        XCTAssertNotNil(picture.options[.fillColor] as? NSColor)
    }

    /// The real capture path for a playing video wallpaper: the file's frame at the player's time, placed as 填满.
    func testLiveCaptureTakesTheVideoFrameAtThePlayersTime() async throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures"))
        let video = Wallpaper(name: "循环", type: .video, source: .local, resourceURL: source)
        let live = WallpaperRuntimeManager(makeRenderer: { try WallpaperRuntimeManager.standardRenderer(for: $0) })
        defer { live.shutdown() }
        live.addDisplay(a, host: ProviderHost())
        live.apply(video, to: a)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while live.activeWallpaper(on: a)?.id != video.id {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("video did not become active") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let captured = await SystemWallpaperProvider.liveCapture(runtime: live, editor: nil)(video, a)
        let still = try XCTUnwrap(captured)
        XCTAssertGreaterThan(still.image.width, 0); XCTAssertGreaterThan(still.image.height, 0)
        XCTAssertTrue(still.clips); XCTAssertEqual(still.scaling, .scaleProportionallyUpOrDown)
        let nothing = await SystemWallpaperProvider.liveCapture(runtime: live, editor: nil)(video, b)
        XCTAssertNil(nothing, "no renderer on that display and no poster")
    }
}
