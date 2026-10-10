import AppKit
import KineticSceneRuntime
import XCTest
@testable import Kinetic

/// 显示方式 › 自定义（用户 2026-10-08）：光圈固定、只有壁纸移动，光圈内始终铺满；静置 5 秒光圈外渐隐。
@MainActor
final class DisplayCropEditorTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 640)

    private func assertCovers(_ rect: CGRect, _ aperture: CGRect, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        let tolerance: CGFloat = 1e-6
        XCTAssertLessThanOrEqual(rect.minX, aperture.minX + tolerance, message, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.minY, aperture.minY + tolerance, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxX, aperture.maxX - tolerance, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxY, aperture.maxY - tolerance, message, file: file, line: line)
    }

    func testDefaultIsCenteredAndJustCoversTheAperture() {
        for content: CGFloat in [21 / 9, 16 / 9, 1, 9 / 16] {
            let geometry = DisplayCropGeometry(bounds: bounds, displayAspect: 16 / 10, contentAspect: content)
            let aperture = geometry.aperture, rect = geometry.contentRect(for: CustomDisplayFrame())
            XCTAssertEqual(aperture.width / aperture.height, 16 / 10, accuracy: 1e-9)
            XCTAssertEqual(aperture.midX, bounds.midX, accuracy: 1e-9); XCTAssertEqual(aperture.midY, bounds.midY, accuracy: 1e-9)
            XCTAssertEqual(rect.width / rect.height, content, accuracy: 1e-9, "full-ratio wallpaper")
            XCTAssertEqual(rect.midX, aperture.midX, accuracy: 1e-9); XCTAssertEqual(rect.midY, aperture.midY, accuracy: 1e-9)
            XCTAssertTrue(abs(rect.width - aperture.width) < 1e-6 || abs(rect.height - aperture.height) < 1e-6, "just covers")
            assertCovers(rect, aperture)
            // The whole wallpaper fits in the window at the default size.
            XCTAssertTrue(bounds.insetBy(dx: DisplayCropGeometry.margin - 1e-6, dy: DisplayCropGeometry.margin - 1e-6).contains(rect),
                          "\(rect) in \(bounds)")
        }
    }

    func testPanningFollowsEveryDirectionOneToOneAndStopsAtTheEdges() {
        let geometry = DisplayCropGeometry(bounds: bounds, displayAspect: 16 / 10, contentAspect: 16 / 9)
        let zoomed = geometry.clamped(CustomDisplayFrame(zoom: 2))
        let start = geometry.contentRect(for: zoomed)
        for delta in [CGVector(dx: 37, dy: 0), CGVector(dx: 0, dy: -23), CGVector(dx: 31.5, dy: 17.25), CGVector(dx: -12, dy: 29)] {
            let moved = geometry.contentRect(for: geometry.panned(zoomed, by: delta))
            XCTAssertEqual(moved.minX - start.minX, delta.dx, accuracy: 1e-6, "x follows \(delta)")
            XCTAssertEqual(moved.minY - start.minY, delta.dy, accuracy: 1e-6, "y follows \(delta)")
            XCTAssertEqual(moved.size, start.size)
        }
        // A hula hoop around a body: however far it is pushed, the wallpaper's edge never enters the aperture.
        for delta in [CGVector(dx: 5000, dy: 0), CGVector(dx: -5000, dy: 0), CGVector(dx: 0, dy: 5000),
                      CGVector(dx: 0, dy: -5000), CGVector(dx: 4000, dy: -3000)] {
            var frame = zoomed
            for _ in 0..<3 { frame = geometry.panned(frame, by: delta) }
            assertCovers(geometry.contentRect(for: frame), geometry.aperture, "pushed \(delta)")
            XCTAssertTrue(frame.isValid)
        }
    }

    func testPinchZoomsAroundTheFingersWithinLimits() {
        let geometry = DisplayCropGeometry(bounds: bounds, displayAspect: 16 / 10, contentAspect: 16 / 9)
        let point = CGPoint(x: geometry.aperture.midX + 40, y: geometry.aperture.midY - 25)
        let before = geometry.contentRect(for: CustomDisplayFrame(zoom: 2))
        let frame = geometry.zoomed(CustomDisplayFrame(zoom: 2), by: 1.25, around: point)
        XCTAssertEqual(frame.zoom, 2.5, accuracy: 1e-9)
        let after = geometry.contentRect(for: frame)
        // The wallpaper point under the fingers stays under them.
        XCTAssertEqual((point.x - before.minX) / before.width, (point.x - after.minX) / after.width, accuracy: 1e-9)
        XCTAssertEqual((point.y - before.minY) / before.height, (point.y - after.minY) / after.height, accuracy: 1e-9)
        XCTAssertEqual(geometry.zoomed(CustomDisplayFrame(), by: 0.3, around: point).zoom, 1, "never smaller than the aperture")
        XCTAssertEqual(geometry.zoomed(CustomDisplayFrame(zoom: 4), by: 3, around: point).zoom, CustomDisplayFrame.maximumZoom)
        let corner = CGPoint(x: geometry.aperture.minX, y: geometry.aperture.minY)
        var shrinking = CustomDisplayFrame(zoom: 5, centerX: 0.1, centerY: 0.9)
        for _ in 0..<20 { shrinking = geometry.zoomed(shrinking, by: 0.8, around: corner) }
        assertCovers(geometry.contentRect(for: shrinking), geometry.aperture, "zooming out near an edge stays filled")
    }

    func testEditorRegionIsWhatTheDisplayShows() {
        // The window's aperture and the engines compute the same part of the wallpaper.
        let geometry = DisplayCropGeometry(bounds: bounds, displayAspect: 16 / 10, contentAspect: 21 / 9)
        let frame = geometry.panned(geometry.clamped(CustomDisplayFrame(zoom: 1.7)), by: CGVector(dx: 120, dy: -60))
        let rect = geometry.contentRect(for: frame), aperture = geometry.aperture
        let shown = frame.region(content: CGSize(width: 2100, height: 900), viewport: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(shown.minX, (aperture.minX - rect.minX) / rect.width, accuracy: 1e-6)
        XCTAssertEqual(shown.width, aperture.width / rect.width, accuracy: 1e-6)
        XCTAssertEqual(shown.minY, (rect.maxY - aperture.maxY) / rect.height, accuracy: 1e-6, "top-left origin")
        XCTAssertEqual(shown.height, aperture.height / rect.height, accuracy: 1e-6)
    }

    func testWindowFitsTheWholeWallpaperOnScreen() {
        let maximum = CGSize(width: 1300, height: 800)
        let cases: [(display: CGFloat, content: CGFloat)] = [(1.6, 21.0 / 9), (1.6, 9.0 / 16), (16.0 / 9, 32.0 / 9), (9.0 / 16, 16.0 / 9)]
        for (display, content) in cases {
            let size = DisplayCropGeometry.windowContentSize(displayAspect: display, contentAspect: content, maximum: maximum)
            XCTAssertLessThanOrEqual(size.width, maximum.width + 1); XCTAssertLessThanOrEqual(size.height, maximum.height + 1)
            let geometry = DisplayCropGeometry(bounds: CGRect(origin: .zero, size: size), displayAspect: display, contentAspect: content)
            let rect = geometry.contentRect(for: CustomDisplayFrame())
            let room = CGRect(origin: .zero, size: size).insetBy(dx: DisplayCropGeometry.margin, dy: DisplayCropGeometry.margin)
            XCTAssertTrue(room.insetBy(dx: -1, dy: -1).contains(rect), "whole wallpaper visible: \(display) / \(content)")
            XCTAssertLessThan(min(room.width - rect.width, room.height - rect.height), 1.5,
                              "and it uses the window: \(display) / \(content)")
        }
    }

    func testDragMovesOnlyTheWallpaperCommitsAndOutsideFadesAfterIdle() async throws {
        let view = DisplayCropEditorView(displayAspect: 16 / 10, contentAspect: 16 / 9, frame: CustomDisplayFrame(zoom: 2))
        view.frame = bounds; view.layoutSubtreeIfNeeded()
        var committed: [CustomDisplayFrame] = []
        view.onChange = { committed.append($0) }
        view.idleDelay = 0.15
        let aperture = view.geometry.aperture
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = view.geometry.contentRect(for: view.value)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 500, y: 300)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 530, y: 280)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 545, y: 291)))
        let moved = view.geometry.contentRect(for: view.value)
        XCTAssertEqual(moved.minX - start.minX, 45, accuracy: 1e-6); XCTAssertEqual(moved.minY - start.minY, -9, accuracy: 1e-6)
        XCTAssertEqual(view.geometry.aperture, aperture, "the aperture never moves")
        // Holding the button is still operating: no fade.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(view.isOutsideHidden)
        XCTAssertEqual(committed.last, view.value, "the draft follows within a frame")
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 545, y: 291)))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(view.isOutsideHidden, "idle: only the aperture remains")
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 500, y: 300)))
        XCTAssertFalse(view.isOutsideHidden, "operating again brings the outside back")
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 500, y: 300)))
    }

    /// Offscreen snapshots for the QA record (no computer use on this Mac): visible, then idle.
    func testEditorSnapshots() throws {
        let width = 2100, height = 900
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for row in 0..<9 {
            for column in 0..<21 {
                let hue = CGFloat(column) / 21
                context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.45 + CGFloat(row) * 0.05, alpha: 1).cgColor)
                context.fill(CGRect(x: column * 100, y: row * 100, width: 100, height: 100))
            }
        }
        let view = DisplayCropEditorView(displayAspect: 16 / 10, contentAspect: 21 / 9, frame: CustomDisplayFrame(zoom: 1.4, centerX: 0.62, centerY: 0.45))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = CGRect(origin: .zero, size: DisplayCropGeometry.windowContentSize(displayAspect: 16 / 10, contentAspect: 21 / 9,
                                                                                     maximum: CGSize(width: 1300, height: 820)))
        view.setImage(try XCTUnwrap(context.makeImage()))
        view.layoutSubtreeIfNeeded()
        let folder = TestWorkspaceDirectory.make(".build/CustomFit/Snapshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func snapshot(_ name: String) throws {
            let layer = try XCTUnwrap(view.layer)
            let image = try XCTUnwrap(CGContext(data: nil, width: Int(view.bounds.width), height: Int(view.bounds.height),
                bitsPerComponent: 8, bytesPerRow: Int(view.bounds.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            layer.render(in: image)
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(image.makeImage()))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        }
        try snapshot("crop-editor-visible")
        view.setOutsideHidden(true)
        try snapshot("crop-editor-idle")
        print("Crop editor snapshots: \(folder.path)")
    }

    func testVideoLayersShowTheChosenRegion() throws {
        let view = VideoContentView(frame: CGRect(x: 0, y: 0, width: 160, height: 100))
        let context = try XCTUnwrap(CGContext(data: nil, width: 192, height: 108, bitsPerComponent: 8, bytesPerRow: 192 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        view.setPoster(try XCTUnwrap(context.makeImage()))
        view.setDisplayFit(.fill)
        XCTAssertEqual(view.playerLayer.frame, view.bounds, "other display modes are unchanged")
        let frame = CustomDisplayFrame(zoom: 2, centerX: 0.25, centerY: 0.25)
        view.setDisplayFit(.custom, frame: frame)
        let region = frame.region(content: CGSize(width: 192, height: 108), viewport: CGSize(width: 160, height: 100))
        let layer = view.playerLayer.frame
        XCTAssertEqual(layer.width, 160 / region.width, accuracy: 1e-6); XCTAssertEqual(layer.height, 100 / region.height, accuracy: 1e-6)
        XCTAssertEqual(-layer.minX / layer.width, region.minX, accuracy: 1e-6)
        XCTAssertEqual((layer.maxY - 100) / layer.height, region.minY, accuracy: 1e-6, "the top of the region meets the top of the view")
        XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspectFill)
        view.setDisplayFit(.fit)
        XCTAssertEqual(view.playerLayer.frame, view.bounds)
    }

    func testCustomFrameIsValidatedAndOlderSettingsStillDecode() throws {
        var options = VideoPlaybackOptions()
        options.displayFit = .custom; options.customFrame = CustomDisplayFrame(zoom: 2, centerX: 0.3, centerY: 0.7)
        XCTAssertEqual(try JSONDecoder().decode(VideoPlaybackOptions.self, from: JSONEncoder().encode(options)), options)
        XCTAssertNoThrow(try options.validated())
        for bad in [CustomDisplayFrame(zoom: 0.5), CustomDisplayFrame(zoom: 9), CustomDisplayFrame(centerX: .nan), CustomDisplayFrame(centerY: 2)] {
            options.customFrame = bad
            XCTAssertThrowsError(try options.validated(), "\(bad)")
        }
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(VideoPlaybackOptions())) as? [String: Any])
        old["customFrame"] = nil
        XCTAssertEqual(try JSONDecoder().decode(VideoPlaybackOptions.self, from: JSONSerialization.data(withJSONObject: old)),
                       VideoPlaybackOptions(), "settings saved before 自定义 still load")
        var staged = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            StagedDisplayWallpaperConfiguration(wallpaperID: UUID()))) as? [String: Any])
        staged["sceneCustomFrame"] = nil
        XCTAssertNil(try JSONDecoder().decode(StagedDisplayWallpaperConfiguration.self,
                                              from: JSONSerialization.data(withJSONObject: staged)).sceneCustomFrame)
        XCTAssertEqual(SceneDisplayFit(SceneDisplayFitSetting.custom), .fill)
        XCTAssertNil(SceneDisplayCrop(.fill, frame: CustomDisplayFrame(zoom: 2)))
        XCTAssertEqual(SceneDisplayCrop(.custom, frame: nil), SceneDisplayCrop())
        XCTAssertEqual(SceneDisplayCrop(.custom, frame: CustomDisplayFrame(zoom: 3, centerX: 0.2, centerY: 0.8)),
                       SceneDisplayCrop(zoom: 3, centerX: 0.2, centerY: 0.8))
    }
}
