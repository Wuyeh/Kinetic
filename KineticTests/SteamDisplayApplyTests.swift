import AppKit
import Combine
import XCTest
@testable import Kinetic

@MainActor
final class SteamDisplayApplyTests: XCTestCase {
    func testDownloadKeepsBothWallpapersUntilReadyAndOnlyAppliesToExplicitTarget() async throws {
        let h = Harness(); await h.start(); defer { h.stop() }
        let candidate = h.wallpaper("download")
        h.waitIDs.insert(candidate.id)
        h.coordinator.request(.init(workshopID: "10"), to: h.b)
        await h.settle()
        XCTAssertEqual(h.calls, ["10"])
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, h.old.id)
        h.complete("10", .success(candidate))
        try await waitForSteam { h.renderers.last?.waiting == true }
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.a)?.id, h.old.id)
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, h.old.id)
        XCTAssertTrue(h.notices.isEmpty, "Never announce success before Ready")
        h.renderers.last?.ready(); await h.settle()
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, candidate.id)
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.a)?.id, h.old.id)
        XCTAssertEqual(h.notices.map(\.outcome), [.downloadedAndApplied])
        XCTAssertEqual(h.notices.first?.displayID, h.b)
    }

    func testExistingRecordDoesNotDownloadIncludingUpdateAvailableAndActiveNoOp() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.workshops["10"] = h.old
        h.coordinator.request(.init(workshopID: "10", timeUpdated: Date()), to: h.b)
        await h.settle()
        XCTAssertTrue(h.calls.isEmpty)
        XCTAssertEqual(h.notices.map(\.outcome), [.appliedExisting])
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, h.old.id)
    }

    func testDownloadFailureKeepsOldWallpapersAndReportsCorrectOutcome() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.coordinator.request(.init(workshopID: "10"), to: h.b); await h.settle()
        h.complete("10", .failure(.network)); await h.settle()
        XCTAssertEqual(h.notices.map(\.outcome), [.downloadFailed])
        XCTAssertTrue(h.notices.first?.message.contains(SteamAcquisitionError.network.localizedDescription) == true)
        XCTAssertFalse(h.notices.first?.message.contains("\n") == true,
                       "The one-line toast must include the actual failure reason")
        XCTAssertEqual(h.renderers.count, 2)
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, h.old.id)
    }

    func testPreparationFailureAndUnsupportedRetainLocalRecordAndOldWallpaper() async {
        for unsupported in [false, true] {
            let h = Harness(); await h.start(); defer { h.stop() }
            let candidate = h.wallpaper("broken", type: unsupported ? .scene : .web)
            h.failIDs.insert(candidate.id)
            h.coordinator.request(.init(workshopID: "10"), to: h.b); await h.settle()
            h.complete("10", .success(candidate)); await h.settle()
            XCTAssertNotNil(h.records[candidate.id])
            XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, h.old.id)
            XCTAssertEqual(h.runtime.activeWallpaper(on: h.a)?.id, h.old.id)
            XCTAssertEqual(h.notices.map(\.outcome), [.applyFailed])
        }
    }

    func testDisconnectedTargetStaysCancelledEvenIfItReconnectsBeforeDownloadFinishes() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.coordinator.request(.init(workshopID: "10"), to: h.b); await h.settle()
        h.runtime.removeDisplay(h.b)
        h.runtime.addDisplay(h.b, host: AppControlTestHost())
        let candidate = h.wallpaper("new")
        h.complete("10", .success(candidate)); await h.settle()
        XCTAssertNotNil(h.records[candidate.id])
        XCTAssertNil(h.runtime.activeWallpaper(on: h.b))
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.a)?.id, h.old.id)
        XCTAssertEqual(h.notices.map(\.outcome), [.disconnected])
    }

    func testDeviceReorderingDoesNotChangeExplicitTarget() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.coordinator.request(.init(workshopID: "10"), to: h.b); await h.settle()
        h.runtime.updateDisplayOrder([h.b, h.a])
        let candidate = h.wallpaper("new")
        h.complete("10", .success(candidate)); await h.settle()
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, candidate.id)
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.a)?.id, h.old.id)
    }

    func testNewerLocalApplyAndGlobalStopWinOverPendingDownload() async {
        for stop in [false, true] {
            let h = Harness(); await h.start(); defer { h.stop() }
            h.coordinator.request(.init(workshopID: "10"), to: h.b); await h.settle()
            let newer = h.wallpaper("chosen later")
            if stop { h.runtime.stop(.allDisplays) }
            else { h.runtime.apply(newer, to: h.b) }
            await h.settle()
            let downloaded = h.wallpaper("download")
            h.complete("10", .success(downloaded)); await h.settle()
            XCTAssertNotNil(h.records[downloaded.id])
            XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, stop ? nil : newer.id)
            XCTAssertEqual(h.notices.map(\.outcome), [.cancelled])
        }
    }

    func testDuplicateRequestIsIgnoredAndLatestDownloadForSameTargetWins() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.coordinator.request(.init(workshopID: "10"), to: h.b)
        h.coordinator.request(.init(workshopID: "10"), to: h.b)
        await h.settle(); XCTAssertEqual(h.calls, ["10"])
        h.coordinator.request(.init(workshopID: "20"), to: h.b); await h.settle()
        let first = h.wallpaper("old intent"), latest = h.wallpaper("latest intent")
        h.complete("10", .success(first)); await h.settle()
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, h.old.id)
        XCTAssertTrue(h.notices.isEmpty)
        h.complete("20", .success(latest)); await h.settle()
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, latest.id)
        XCTAssertEqual(h.notices.map(\.workshopID), ["20"])
    }

    func testPauseDuringDownloadIsInheritedAndDeletedRecordNeverApplies() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.coordinator.request(.init(workshopID: "10"), to: h.b); await h.settle()
        h.runtime.pause(.allDisplays)
        let downloaded = h.wallpaper("paused download")
        h.complete("10", .success(downloaded)); await h.settle()
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .manualPaused)
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, downloaded.id)
        h.coordinator.request(.init(workshopID: "20"), to: h.b); await h.settle()
        let deleted = h.wallpaper("removed before apply")
        h.complete("20", .success(deleted), save: false); await h.settle()
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, downloaded.id)
        XCTAssertEqual(h.notices.last?.outcome, .applyFailed)
    }

    func testRemoteDragRequiresValidFinalTargetAndConsumesOnce() {
        let item = SteamStoreItem(workshopID: "remote", title: "Remote", previewURL: nil, creatorSteamID: nil,
                                 timeCreated: nil, timeUpdated: nil, fileSize: nil, type: .web, tags: [])
        let display = DisplayID("stable"), frame = CGRect(x: 100, y: 20, width: 140, height: 90)
        var drag = SteamDisplayDragPresentation()
        drag.begin(item, posterURL: nil)
        drag.move(.init(x: 150, y: 60), from: item.id, frames: [display: frame], displays: [display])
        XCTAssertEqual(drag.hoveredDisplayID, display)
        XCTAssertNil(drag.takeDrop(from: item.id, at: .zero, frames: [display: frame], displays: [display]))
        drag.begin(item, posterURL: nil)
        XCTAssertEqual(drag.takeDrop(from: item.id, at: .init(x: 150, y: 60), frames: [display: frame], displays: [display])?.1, display)
        XCTAssertNil(drag.takeDrop(from: item.id, at: .init(x: 150, y: 60), frames: [display: frame], displays: [display]))
        drag.begin(item, posterURL: nil); drag.cancel()
        XCTAssertNil(drag.item)
        drag.begin(item, posterURL: nil)
        XCTAssertNil(drag.takeDrop(from: item.id, at: .init(x: 150, y: 60), frames: [display: frame], displays: []))
    }

    func testExistingOrdinaryDownloadIsJoinedWithoutSecondSteamProcess() async throws {
        let root = TestWorkspaceDirectory.make(".build/Module18-24/TestWorkspaces")
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = SteamCMDInstallation(rootURL: root.appendingPathComponent("SteamCMD"))
        try FileManager.default.createDirectory(at: installation.rootURL, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: installation.scriptURL)
        let folder = installation.contentURL(for: "10")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"web","file":"index.html"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data("<html>test</html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        let defaults = SignedInDefaults()
        let fake = FakeSteamCMD(); fake.configure = { $0.script = { _ in } }
        let library = WallpaperLibrary(storage: .init(rootURL: root.appendingPathComponent("Library")))
        let steam = SteamAcquisitionService(installation: installation, library: library, defaults: defaults, makeProcess: fake.factory)
        XCTAssertTrue(steam.isSignedIn)
        let runtime = WallpaperRuntimeManager { AppControlTestRenderer($0) }
        runtime.addDisplay(.main, host: AppControlTestHost())
        let coordinator = SteamDisplayApplyCoordinator(runtime: runtime, library: library, steam: steam)
        defer { coordinator.shutdown(); runtime.shutdown() }
        var notices: [SteamDisplayApplyCoordinator.Notice] = []
        let subscription = coordinator.notices.sink { notices.append($0) }
        defer { subscription.cancel() }
        let ordinary = Task { await steam.acquire(.init(workshopID: "10")) }
        try await waitForSteam { steam.tasks["10"]?.isActive == true && fake.processes.first?.started == true }
        coordinator.request(.init(workshopID: "10"), to: .main)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(fake.processes.count, 1)
        fake.processes[0].emit("Success. Downloaded item 10 to \"\(folder.path)\" (20 bytes)\n")
        _ = await ordinary.value
        try await waitForSteam { !notices.isEmpty }
        XCTAssertEqual(fake.processes.count, 1)
        XCTAssertEqual(library.wallpapers.count, 1)
        XCTAssertEqual(runtime.activeWallpaper?.id, library.wallpaper(workshopID: "10")?.id)
        XCTAssertEqual(notices.map(\.outcome), [.downloadedAndApplied])
    }

    private final class SignedInDefaults: UserDefaults {
        override func string(forKey defaultName: String) -> String? {
            defaultName == "Kinetic.Steam.Username" ? "fixture-user" : nil
        }
    }

    @MainActor
    private final class Harness {
        let a = DisplayID("A"), b = DisplayID("B")
        let old = Wallpaper(name: "Old", type: .video, source: .local, resourceURL: URL(fileURLWithPath: "/test/old.mp4"))
        var records: [Wallpaper.ID: Wallpaper] = [:]
        var workshops: [String: Wallpaper] = [:]
        var calls: [String] = []
        var notices: [SteamDisplayApplyCoordinator.Notice] = []
        var renderers: [AppControlTestRenderer] = []
        var waitIDs = Set<Wallpaper.ID>(), failIDs = Set<Wallpaper.ID>()
        var completions: [String: CheckedContinuation<Result<Wallpaper, SteamAcquisitionError>, Never>] = [:]
        var subscription: AnyCancellable?
        lazy var runtime = WallpaperRuntimeManager { [unowned self] wallpaper in
            let renderer = AppControlTestRenderer(wallpaper, waits: self.waitIDs.contains(wallpaper.id), fails: self.failIDs.contains(wallpaper.id))
            self.renderers.append(renderer); return renderer
        }
        lazy var coordinator = SteamDisplayApplyCoordinator(runtime: runtime, resolveWorkshop: { [unowned self] in self.workshops[$0] },
            resolveWallpaper: { [unowned self] in self.records[$0] }, acquire: { [unowned self] item in
                self.calls.append(item.workshopID)
                return await withCheckedContinuation { self.completions[item.workshopID] = $0 }
            })
        func start() async {
            records[old.id] = old
            runtime.addDisplay(a, host: AppControlTestHost()); runtime.addDisplay(b, host: AppControlTestHost())
            runtime.apply(old, to: a); runtime.apply(old, to: b); await settle()
            subscription = coordinator.notices.sink { [weak self] in self?.notices.append($0) }
        }
        func wallpaper(_ name: String, type: WallpaperType = .web) -> Wallpaper {
            Wallpaper(name: name, type: type, source: .steam, resourceURL: URL(fileURLWithPath: "/test/index.html"))
        }
        func complete(_ id: String, _ result: Result<Wallpaper, SteamAcquisitionError>, save: Bool = true) {
            if case .success(let wallpaper) = result, save { records[wallpaper.id] = wallpaper; workshops[id] = wallpaper }
            completions.removeValue(forKey: id)?.resume(returning: result)
        }
        func settle() async { for _ in 0..<60 { await Task.yield() } }
        func stop() {
            coordinator.shutdown(); runtime.shutdown(); subscription?.cancel()
            for completion in completions.values { completion.resume(returning: .failure(.network)) }
            completions.removeAll()
        }
    }
}

@MainActor
final class AppControlTestHost: DesktopContentHost {
    func present(_ view: NSView) -> Bool { true }
    func stop() {}
}

@MainActor
final class AppControlTestRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    let waits: Bool, fails: Bool
    private(set) var muted = true
    private var continuation: CheckedContinuation<Void, Error>?
    var waiting: Bool { continuation != nil }
    init(_ wallpaper: Wallpaper, waits: Bool = false, fails: Bool = false) {
        self.wallpaper = wallpaper; self.waits = waits; self.fails = fails
    }
    func prepare() async throws {
        if fails { throw NSError(domain: "Module18Tests", code: 1) }
        if waits { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    func ready() { continuation?.resume(); continuation = nil }
    func play() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) { self.muted = muted }
    func dispose() { continuation?.resume(throwing: CancellationError()); continuation = nil }
}
