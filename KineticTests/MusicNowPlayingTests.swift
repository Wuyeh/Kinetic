import AppKit
import Carbon
import SwiftUI
import ImageIO
import XCTest
@testable import Kinetic

actor TestMusicReader: MusicReading {
    var reads = 0, authorizations = 0, controls = 0
    var delay: UInt64 = 0
    var value = MusicSnapshot(availability: .live, track: .init(id: "test", title: "晨间练习", artist: "Kinetic 测试", album: "测试专辑", duration: 180), isPlaying: true, position: 20)
    func set(_ value: MusicSnapshot, delay: UInt64 = 0) { self.value = value; self.delay = delay }
    func read(_ source: MusicSource) async -> MusicSnapshot { reads += 1; let copy = value; if delay > 0 { try? await Task.sleep(nanoseconds: delay) }; return copy }
    func authorize(_ source: MusicSource) async -> MusicAvailability { authorizations += 1; return .live }
    func control(_ command: MusicControl, source: MusicSource) async -> Bool { controls += 1; return true }
}
actor TestLyricsClient: LyricsFetching {
    var calls = 0
    var delay: UInt64 = 0
    var fail = false
    func configure(delay: UInt64 = 0, fail: Bool = false) { self.delay = delay; self.fail = fail }
    func fetch(_ track: MusicTrack) async throws -> TrackLyrics {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fail { throw LyricsError.unavailable }
        return .init(plain: track.title + "\n测试第二行", lines: [.init(time: 0, text: track.title), .init(time: 30, text: "测试第二行")], instrumental: false)
    }
}
@MainActor final class TestMusicSchedule: SystemMetricsSchedule {
    var invalidated = false
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func invalidate() { invalidated = true }
    func fire() { if !invalidated { action() } }
}
@MainActor final class TestMusicScheduler: SystemMetricsScheduling {
    var schedules: [TestMusicSchedule] = [], intervals: [Double] = []
    func schedule(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> any SystemMetricsSchedule {
        let value = TestMusicSchedule(action); schedules.append(value); intervals.append(interval); return value
    }
}
@MainActor private final class MusicTestSurface: OverlaySurface {
    var views: [UUID: NSView] = [:]
    func present(_ view: NSView, for id: UUID, display: DesktopDisplay) throws { views[id] = view }
    func remove(_ id: UUID) { views[id] = nil }
    func realign(_ display: DesktopDisplay) {}
    func setOrder(_ ids: [UUID]) {}
    func close() { views.removeAll() }
}

@MainActor final class MusicNowPlayingTests: XCTestCase {
    private func settle() async { try? await Task.sleep(nanoseconds: 80_000_000) }
    func testConfigDefaultsRoundTripAndGeometryStayInsideDisplay() throws {
        var options = MusicOverlayOptions()
        XCTAssertEqual(options.lyrics, .off)
        options.source = .spotify; options.layout = .vinyl; options.lyrics = .synced
        let value = try options.applying(to: .init(kind: .music, displayID: .init("display-A")))
        XCTAssertEqual(try MusicOverlayOptions(configuration: value), options)
        for bad: [String: OverlayParameter] in [["scale": .number(.nan)], ["x": .number(2)], ["lyrics": .text("fake")], ["unexpected": .boolean(true)]] {
            var copy = value; copy.parameters = bad; XCTAssertThrowsError(try MusicOverlayOptions(configuration: copy))
        }
        for width in [1.0, 120, 1512, 6000] { for height in [1.0, 90, 982, 3300] {
            for isLyrics in [false, true] {
                let frame = try XCTUnwrap(options.frame(in: .init(width: width, height: height), isLyrics: isLyrics))
                XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width + 0.001); XCTAssertLessThanOrEqual(frame.maxY, height + 0.001)
            }
        } }
        XCTAssertNil(options.frame(in: .zero))
        XCTAssertEqual(options.moved(by: .init(width: 10000, height: 10000), in: .init(width: 1512, height: 982), isLyrics: true).lyricsPosition, .init(x: 1, y: 1))
    }
    func testTrackLimitsAndProgressPauseSeekAndStaleData() throws {
        let track = MusicTrack(id: "1", title: "Title", artist: "Artist", album: "Album", duration: 100)
        var snapshot = MusicSnapshot(availability: .live, track: track, isPlaying: true, position: 20, sampledAt: .init(timeIntervalSince1970: 0))
        XCTAssertEqual(snapshot.elapsed(at: .init(timeIntervalSince1970: 2)), 22)
        XCTAssertEqual(snapshot.elapsed(at: .init(timeIntervalSince1970: 500)), 32, "Stale metadata cannot advance forever")
        snapshot.isPlaying = false; XCTAssertEqual(snapshot.elapsed(at: .init(timeIntervalSince1970: 2)), 20)
        snapshot.position = 99; snapshot.isPlaying = true; XCTAssertEqual(snapshot.elapsed(at: .init(timeIntervalSince1970: 2)), 100)
        snapshot.position = 4; XCTAssertEqual(snapshot.elapsed(at: .init(timeIntervalSince1970: 2)), 6, "A player seek is authoritative")
        XCTAssertThrowsError(try MusicTrack(id: "", title: "Title", artist: "", album: "", duration: 1).validated())
        XCTAssertThrowsError(try MusicTrack(id: "1", title: "Title", artist: "", album: "", duration: .nan).validated())
        XCTAssertNil(LiveMusicReader.thumbnail(Data(repeating: 0, count: 5 * 1024 * 1024)))
    }
    func testServiceSharesPollingNeverPromptsAndDoesNotFetchLyricsByDefault() async {
        let reader = TestMusicReader(), lyrics = TestLyricsClient(), scheduler = TestMusicScheduler()
        let service = MusicService(reader: reader, repository: .init(client: lyrics), scheduler: scheduler)
        await settle(); let observed1 = await reader.reads; XCTAssertEqual(observed1, 0)
        let hidden = service.subscribe(source: .appleMusic, lyrics: false)
        await settle(); XCTAssertFalse(service.isSampling); XCTAssertTrue(scheduler.schedules.isEmpty)
        hidden.update(visible: true, source: .appleMusic, lyrics: false)
        let second = service.subscribe(source: .appleMusic, lyrics: false, visible: true)
        await settle(); XCTAssertEqual(scheduler.schedules.count, 1)
        let observed2 = await reader.reads; XCTAssertEqual(observed2, 1); let observed3 = await reader.authorizations; XCTAssertEqual(observed3, 0); let observed4 = await lyrics.calls; XCTAssertEqual(observed4, 0)
        for _ in 0..<100 { hidden.update(visible: true, source: .appleMusic, lyrics: false) }
        await settle(); let observed5 = await reader.reads; XCTAssertEqual(observed5, 1, "Geometry edits must not issue new player queries")
        scheduler.schedules[0].fire(); await settle(); let observed6 = await reader.reads; XCTAssertEqual(observed6, 2)
        hidden.cancel(); XCTAssertTrue(service.isSampling); second.cancel(); XCTAssertFalse(service.isSampling)
        XCTAssertTrue(scheduler.schedules[0].invalidated); service.shutdown()
    }
    func testLockAndLowPowerStopOrReduceWorkAndStaleCompletionIsIgnored() async {
        let reader = TestMusicReader(), scheduler = TestMusicScheduler()
        var value = await reader.value; value.position = 77; await reader.set(value, delay: 200_000_000)
        let service = MusicService(reader: reader, scheduler: scheduler)
        let lease = service.subscribe(source: .appleMusic, lyrics: false, visible: true)
        var conditions = SmartPauseConditions(); conditions.screenLocked = true; service.updateConditions(conditions)
        try? await Task.sleep(nanoseconds: 240_000_000)
        XCTAssertNil(service.snapshots[.appleMusic]); XCTAssertFalse(service.isSampling)
        conditions.screenLocked = false; conditions.lowPowerMode = true; service.updateConditions(conditions)
        XCTAssertEqual(scheduler.intervals.last, 10)
        try? await Task.sleep(nanoseconds: 240_000_000); XCTAssertEqual(service.snapshots[.appleMusic]?.position, 77)
        lease.cancel(); service.shutdown()
    }
    func testOverlayPausePreservesFrameAndRepeatedDisposalReleasesEverything() async throws {
        let service = MusicService(reader: TestMusicReader(), scheduler: TestMusicScheduler())
        var config = OverlayConfiguration(kind: .music, displayID: .init("display-A")); config.isEnabled = true
        let context = OverlayContext(frame: .init(x: 0, y: 0, width: 1512, height: 982), backingScaleFactor: 2, maximumFramesPerSecond: 1, allowsAnimation: true, isPaused: false)
        weak var released: MusicOverlay?
        for _ in 0..<40 {
            var overlay: MusicOverlay? = MusicOverlay(service: service); released = overlay
            try await overlay!.prepare(configuration: config, context: context)
            XCTAssertNil(overlay!.timer); overlay!.play(); await settle()
            XCTAssertNotNil(overlay!.timer); let position = overlay!.state.snapshot.position
            overlay!.pause(); XCTAssertNil(overlay!.timer); await settle(); XCTAssertEqual(overlay!.state.snapshot.position, position)
            overlay!.dispose(); overlay!.dispose(); XCTAssertEqual(service.subscriberCount, 0)
            overlay = nil; XCTAssertNil(released)
        }
        service.shutdown()
    }
    func testPlayerDictionariesUseTheirOwnSuiteAndPropertyCodes() {
        XCTAssertEqual(MusicSource.appleMusic.commandSuite, "hook")
        XCTAssertEqual(MusicSource.spotify.commandSuite, "spfy")
        XCTAssertEqual(LiveMusicReader.code(MusicSource.spotify.trackIDProperty), 0x49442020)
        XCTAssertEqual(MusicSource.spotify.artworkURLProperty, "aUrl")
        XCTAssertEqual(MusicSource.appleMusic.trackIDProperty, "pPIS")
    }
    func testMetadataEventsUseCoreScriptingSuiteRatherThanApplicationLifecycleClass() throws {
        for source in MusicSource.allCases {
            let object = NSAppleEventDescriptor(string: "test-object")
            let event = LiveMusicReader.event(source, object: object)
            XCTAssertEqual(event.attributeDescriptor(forKeyword: keyEventClassAttr)?.typeCodeValue, 0x636F7265, "Metadata must use core/getd")
            XCTAssertEqual(event.attributeDescriptor(forKeyword: keyEventIDAttr)?.typeCodeValue, 0x67657464)
            XCTAssertEqual(event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, "test-object")
            let command = LiveMusicReader.event(source, eventClass: LiveMusicReader.code(source.commandSuite), id: LiveMusicReader.code("PlPs"))
            XCTAssertEqual(command.attributeDescriptor(forKeyword: keyEventClassAttr)?.typeCodeValue, LiveMusicReader.code(source.commandSuite))
            XCTAssertEqual(command.attributeDescriptor(forKeyword: keyEventIDAttr)?.typeCodeValue, 0x506C5073)
        }
    }
    func testRealReaderNeverLaunchesPlayersForMetadata() async {
        let reader = LiveMusicReader()
        for source in MusicSource.allCases {
            let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
            let snapshot = await reader.read(source)
            if !wasRunning {
                XCTAssertEqual(snapshot.availability, .notRunning)
                XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty)
            }
            print("KMUSIC_SOURCE \(source.rawValue) status=\(snapshot.availability.rawValue) runningBefore=\(wasRunning)")
        }
    }
    func testAuthorizedAppleMusicTrackRemainsLiveAcrossSamples() async throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: MusicSource.appleMusic.bundleID).isEmpty else {
            throw XCTSkip("Apple Music is not running; this test never launches or authorizes it")
        }
        let reader = LiveMusicReader()
        let first = await reader.read(.appleMusic)
        if [.permissionRequired, .denied, .noTrack].contains(first.availability) {
            throw XCTSkip("A user-authorized Apple Music track is required")
        }
        XCTAssertEqual(first.availability, .live)
        let firstTrack = try XCTUnwrap(first.track)
        XCTAssertFalse(firstTrack.title.isEmpty)
        XCTAssertGreaterThan(firstTrack.duration, 0)
        try await Task.sleep(nanoseconds: 1_250_000_000)
        let second = await reader.read(.appleMusic)
        XCTAssertEqual(second.availability, .live)
        let secondTrack = try XCTUnwrap(second.track)
        XCTAssertGreaterThan(second.sampledAt, first.sampledAt)
        if first.isPlaying && second.isPlaying && firstTrack.id == secondTrack.id && second.position >= first.position {
            XCTAssertGreaterThan(second.position, first.position, "The actual player's progress must update, not just an estimated display clock")
        }
        print("KMUSIC_LIVE_TRACK metadata=true progressSamples=2 playing=\(second.isPlaying) artwork=\(secondTrack.artwork != nil)")
    }
    func testArtworkIsDecodedOnlyToABoundedThumbnail() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1440,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let thumbnail = try XCTUnwrap(LiveMusicReader.thumbnail(data))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 256); XCTAssertLessThanOrEqual(image.height, 256)
        XCTAssertLessThan(thumbnail.count, 512 * 1024)
    }
    func testEditorPreservesPerDisplayDraftsAndOnlyApplyWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OverlayStore(storage: .init(rootURL: root))
        func display(_ id: String) -> DisplayDescriptor { .init(id: .init(id), name: id, desktop: .init(id: 1, frame: .init(x: 0, y: 0, width: 1512, height: 982), backingScaleFactor: 2), isPersistent: true) }
        let a = display("A"), b = display("B"), registry = DisplayRegistry(discover: { [a, b] }); registry.start()
        let manager = OverlayManager(store: store, registry: registry, readReduceMotion: { false }, makeSurface: { _ in MusicTestSurface() })
        let service = MusicService(reader: TestMusicReader())
        manager.register(.music) { _ in MusicOverlay(service: service) }; manager.start()
        defer { manager.shutdown(); service.shutdown(); registry.stop() }
        let editor = MusicOverlayEditorModel(manager: manager, registry: registry, service: service)
        editor.selectDisplay(a.id); editor.isEnabled = true; editor.options.layout = .vinyl
        editor.selectDisplay(b.id); editor.isEnabled = true; editor.options.lyrics = .plain
        XCTAssertTrue(store.configurations.isEmpty); XCTAssertEqual(editor.draft(on: a.id).options.layout, .vinyl)
        let editors = DisplayOverlayEditors(particles: nil, clock: nil, widgets: nil, music: editor)
        XCTAssertTrue(editors.canApply(on: a.id)); editors.apply(on: a.id)
        XCTAssertNil(editor.error); XCTAssertEqual(store.configurations.count, 1); XCTAssertEqual(store.configurations[0].displayID, a.id)
        XCTAssertTrue(editor.isDirty(on: b.id)); XCTAssertFalse(editor.isDirty(on: a.id))
        editor.save(); XCTAssertEqual(store.configurations.count, 2)
        editor.selectDisplay(a.id); editor.isEnabled = false; editor.save()
        XCTAssertFalse(editor.saved(on: a.id).isEnabled); XCTAssertTrue(editor.saved(on: b.id).isEnabled)
    }
    func testThreeLayoutsAndLyricsRenderInBothAppearances() throws {
        let output = TestWorkspaceDirectory.make(".build/Modules43-44/Snapshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("KMUSIC_SNAPSHOTS \(output.path)")
        let track = MusicTrack(id: "fixture", title: "晨间练习 — 原创测试曲目", artist: "Kinetic 测试", album: "", duration: 180)
        let snapshot = MusicSnapshot(availability: .live, track: track, isPlaying: true, position: 45)
        for dark in [false, true] { for layout in MusicLayout.allCases {
            var options = MusicOverlayOptions(); options.layout = layout
            let host = NSHostingView(rootView: VStack(spacing: 20) {
                NowPlayingFace(options: options, snapshot: snapshot, artwork: nil, date: .now).frame(width: 340, height: layout == .vinyl ? 160 : 130)
                LyricsFace(mode: .synced, snapshot: .init(status: .ready, value: .init(plain: "", lines: [.init(time: 0, text: "清晨的光照进窗"), .init(time: 30, text: "下一帧继续流动"), .init(time: 60, text: "此处仅为原创测试文字")], instrumental: false)), seconds: 45).frame(width: 500, height: 160)
            }.padding(30).frame(width: 600, height: 460).background(dark ? Color(white: 0.1) : Color(white: 0.94)).environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = .init(x: 0, y: 0, width: 600, height: 460); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(layout.rawValue)-\(dark ? "dark" : "light").png"))
        } }
    }
}
