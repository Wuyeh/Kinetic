import AppKit
import XCTest
@testable import Kinetic

@MainActor private final class SizedHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}

/// Records the size its view had when preparation started, like a scene reading its viewport.
@MainActor private final class SizeRecordingRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let displayView: NSView
    var onFailure: (@MainActor (Error) -> Void)?
    private(set) var preparedSize: CGSize?
    init(_ wallpaper: Wallpaper, view: NSView) { self.wallpaper = wallpaper; displayView = view }
    func prepare() async throws { preparedSize = displayView.bounds.size }
    func play() {}; func pause() {}; func resume() {}
    func setMuted(_ muted: Bool) {}; func dispose() {}
}

@MainActor
final class DisplaySizedPreparationTests: XCTestCase {
    /// An iPad (Sidecar, 4:3) next to a 3:2 main display: the wallpaper is prepared at the iPad's shape, not the main screen's.
    func testAnUnsizedViewIsPreparedAtItsOwnDisplaysShape() async throws {
        var made: [SizeRecordingRenderer] = []
        var sized = false
        let runtime = WallpaperRuntimeManager(makeRenderer: { wallpaper in
            let view = NSView(frame: sized ? NSRect(x: 0, y: 0, width: 640, height: 360) : .zero)
            let renderer = SizeRecordingRenderer(wallpaper, view: view)
            made.append(renderer)
            return renderer
        })
        defer { runtime.shutdown() }
        let iPad = DisplayID("display-ipad"), main = DisplayID("display-main")
        runtime.addDisplay(iPad, host: SizedHost(), frame: CGRect(x: 1512, y: 0, width: 1324, height: 993), scaleFactor: 2)
        runtime.addDisplay(main, host: SizedHost(), frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scaleFactor: 2)
        let wallpaper = Wallpaper(name: "场景", type: .scene, source: .local, resourceURL: URL(fileURLWithPath: "/tmp/scene"))
        runtime.apply(wallpaper, to: iPad)
        runtime.apply(wallpaper, to: main)
        try await waitUntilPrepared(runtime)
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[0].preparedSize, CGSize(width: 1324, height: 993))
        XCTAssertEqual(made[1].preparedSize, CGSize(width: 1512, height: 982))

        // A renderer that already has its own size (video, web) keeps it.
        sized = true
        let other = Wallpaper(name: "视频", type: .video, source: .local, resourceURL: URL(fileURLWithPath: "/tmp/video.mp4"))
        runtime.apply(other, to: iPad)
        try await waitUntilPrepared(runtime)
        XCTAssertEqual(made.last?.preparedSize, CGSize(width: 640, height: 360))
    }

    private func waitUntilPrepared(_ runtime: WallpaperRuntimeManager) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            try await Task.sleep(nanoseconds: 10_000_000)
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("preparation did not finish") }
        } while runtime.summary.displays.contains(where: { $0.runtime.preparingWallpaperID != nil })
    }
}
