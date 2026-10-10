import AppKit
import Combine
import SwiftUI
import XCTest
@testable import KineticSceneRuntime
@testable import Kinetic

final class DisplayWorkspaceRevisionTests: XCTestCase {
    private typealias M = DisplayWorkspaceMetrics
    private func check(_ f: DisplayWorkspaceFrames, size: CGSize, aspect: CGFloat,
                       file: StaticString = #filePath, line: UInt = #line) {
        for frame in [f.title, f.selector, f.preview, f.console] {
            XCTAssertTrue(frame.width.isFinite && frame.height.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, -0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.001, file: file, line: line)
        }
        XCTAssertFalse(f.preview.intersects(f.console), file: file, line: line)
        if f.preview.width > 0 {
            XCTAssertEqual(f.preview.width / f.preview.height, aspect, accuracy: 0.0001, file: file, line: line)
        }
        // Console: trailing edge, from below the header to the bottom, always upright.
        XCTAssertEqual(f.console.maxX, size.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(f.console.minY, M.workspaceTop, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(f.console.maxY, size.height, accuracy: 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(f.console.width, max(M.minimumConsoleWidth, f.console.height * M.maximumConsoleAspect) + 0.001,
                                 file: file, line: line)
        // Selector: on the title row's center line, exactly above the console (an upside-down "!").
        XCTAssertEqual(f.selector.minX, f.console.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(f.selector.width, f.console.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(f.selector.midY, f.title.midY, accuracy: 0.001, file: file, line: line)
        XCTAssertLessThan(f.selector.maxY, f.dividerY, file: file, line: line)
        XCTAssertLessThan(f.dividerY, f.console.minY, file: file, line: line)
        XCTAssertEqual(f.preview.midY, (f.console.minY + f.console.maxY) / 2, accuracy: 0.001, file: file, line: line)
    }
    func testDefaultWindowPlacesThumbnailAtTitleEdgeAndConsoleAtTrailingEdge() {
        let size = CGSize(width: 940, height: 608), aspect: CGFloat = 1512 / 982
        let f = DisplayWorkspaceLayout.frames(in: size, aspect: aspect)
        check(f, size: size, aspect: aspect)
        XCTAssertEqual(f.preview.minX, 0, accuracy: 0.001, "Thumbnail starts at the title's leading edge")
        XCTAssertEqual(f.console.minX - f.preview.maxX, M.gap, accuracy: 0.001)
        XCTAssertGreaterThan(f.preview.width, 646, "Larger than the 646 pt thumbnail in the reference screenshot")
        XCTAssertEqual(f.console.width, (size.width - M.gap) * M.consoleWidthFraction, accuracy: 0.001)
    }
    func testHorizontalGrowthScalesBothTogetherUntilConsoleCapThenOnlyThumbnail() {
        // A wide display, so the thumbnail is still width-limited after the console stops.
        let height: CGFloat = 1000, aspect: CGFloat = 2.4
        let cap = (height - M.workspaceTop) * M.maximumConsoleAspect
        var reachedCap = false, previous: DisplayWorkspaceFrames?
        for width in stride(from: CGFloat(940), through: 2400, by: 20) {
            let size = CGSize(width: width, height: height)
            let f = DisplayWorkspaceLayout.frames(in: size, aspect: aspect)
            check(f, size: size, aspect: aspect)
            if let previous {
                XCTAssertGreaterThanOrEqual(f.preview.width, previous.preview.width - 0.001, "Thumbnail never shrinks as the window widens")
                XCTAssertGreaterThanOrEqual(f.console.width, previous.console.width - 0.001)
            }
            if f.console.width < cap - 0.001 {
                XCTAssertFalse(reachedCap)
                // Same proportional rate: both are fixed shares of the row.
                XCTAssertEqual(f.console.width / (width - M.gap), M.consoleWidthFraction, accuracy: 0.0001)
                XCTAssertEqual(f.preview.width / (width - M.gap), 1 - M.consoleWidthFraction, accuracy: 0.0001)
            } else {
                reachedCap = true
                XCTAssertEqual(f.console.width, cap, accuracy: 0.001, "Console stops at its width cap")
            }
            previous = f
        }
        XCTAssertTrue(reachedCap)
        XCTAssertGreaterThan(previous!.preview.width, 1500, "Past the cap only the thumbnail keeps growing")
    }
    func testVerticalGrowthKeepsThumbnailAndOnlyLengthensConsole() {
        let width: CGFloat = 1000, aspect: CGFloat = 1.6
        let first = DisplayWorkspaceLayout.frames(in: .init(width: width, height: 680), aspect: aspect)
        for height in stride(from: CGFloat(680), through: 6000, by: 160) {
            let size = CGSize(width: width, height: height)
            let f = DisplayWorkspaceLayout.frames(in: size, aspect: aspect)
            check(f, size: size, aspect: aspect)
            XCTAssertEqual(f.preview.size, first.preview.size)
            XCTAssertEqual(f.console.width, first.console.width, accuracy: 0.001)
            XCTAssertEqual(f.console.height, height - M.workspaceTop, accuracy: 0.001, "No upper limit on console height")
        }
    }
    func testAllWindowSizesKeepModulesInsideThePage() {
        for w in stride(from: 300, through: 2600, by: 70) {
            for h in stride(from: 200, through: 1600, by: 60) {
                for aspect in [CGFloat(0.6), 1.6, 1512.0 / 982.0, 2.4] {
                    let size = CGSize(width: w, height: h)
                    let f = DisplayWorkspaceLayout.frames(in: size, aspect: aspect)
                    check(f, size: size, aspect: aspect)
                    if f.console.width < CGFloat(w) - M.gap - 0.001 {
                        XCTAssertGreaterThanOrEqual(f.console.width, M.minimumConsoleWidth - 0.001)
                    }
                    if f.preview.width > 0 {
                        XCTAssertGreaterThanOrEqual(f.preview.minY - f.console.minY, M.statusReserve - 0.001, "Room for the status line")
                    }
                }
            }
        }
    }
    func testPreviewRendersNearItsShownSizeWithABoundedWidth() {
        let aspect: CGFloat = 1512 / 982
        for shown in stride(from: CGFloat(1), through: 2400, by: 7) {
            let render = DisplayControlLayout.renderSize(for: .init(width: shown, height: shown / aspect), aspect: aspect)
            XCTAssertEqual(render.width / render.height, aspect, accuracy: 0.0001)
            XCTAssertEqual(render.width.truncatingRemainder(dividingBy: DisplayControlLayout.previewWidthStep), 0)
            XCTAssertLessThanOrEqual(render.width, DisplayControlLayout.maximumPreviewWidth)
            if shown <= DisplayControlLayout.maximumPreviewWidth {
                XCTAssertGreaterThanOrEqual(render.width, shown, "Never upscaled below the cap")
                XCTAssertLessThan(render.width - shown, DisplayControlLayout.previewWidthStep)
            } else {
                XCTAssertEqual(render.width, DisplayControlLayout.maximumPreviewWidth)
            }
        }
        XCTAssertEqual(DisplayControlLayout.renderSize(for: .zero, aspect: .nan).width, DisplayControlLayout.previewWidthStep)
    }
    func testManualNumericInputKeepsPrecisionBoundsLocaleAndRejectsInvalidValues() {
        XCTAssertEqual(NumericParameterEntry.value(from: "45.7264", range: 0...300, step: 0.001), 45.726)
        XCTAssertEqual(NumericParameterEntry.value(from: "1,15", range: 0.25...2, locale: Locale(identifier: "de_DE")), 1.15)
        XCTAssertEqual(NumericParameterEntry.value(from: "500", range: 0...300), 300)
        XCTAssertEqual(NumericParameterEntry.value(from: "-500", range: 0...300), 0)
        for text in ["", "abc", "nan", "inf", "1e999", String(repeating: "1", count: 65)] {
            XCTAssertNil(NumericParameterEntry.value(from: text, range: 0...300))
        }
    }
    @MainActor func testNativeViewsRemainMountedWhileTheWindowResizes() async throws {
        let preview = WorkspaceProbeRecorder(), console = WorkspaceProbeRecorder(), selector = WorkspaceProbeRecorder()
        let window = NSWindow(contentRect: .init(x: 80, y: 100, width: 865, height: 540),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: WorkspaceHarness(preview: preview, console: console, selector: selector))
        window.contentView = host; window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 120_000_000)
        let previewView = try XCTUnwrap(preview.views.first), consoleView = try XCTUnwrap(console.views.first)
        let selectorView = try XCTUnwrap(selector.views.first)
        for (width, height) in [(675, 540), (900, 700), (1250, 540), (1600, 1000), (865, 540)] {
            window.setContentSize(.init(width: width, height: height)); host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertEqual(preview.views.count, 1); XCTAssertEqual(console.views.count, 1); XCTAssertEqual(selector.views.count, 1)
            XCTAssertTrue(preview.views.first === previewView); XCTAssertTrue(console.views.first === consoleView)
            XCTAssertTrue(selector.views.first === selectorView)
            let expected = DisplayWorkspaceLayout.frames(in: host.bounds.size, aspect: 1.6)
            XCTAssertEqual(consoleView.frame.width, expected.console.width, accuracy: 1)
            XCTAssertEqual(consoleView.frame.height, expected.console.height, accuracy: 1)
            XCTAssertEqual(previewView.frame.width, expected.preview.width, accuracy: 1)
            XCTAssertEqual(selectorView.frame.width, expected.selector.width, accuracy: 1)
        }
    }
    @MainActor func testScenePreviewEditsKeepPlayingHostAndUnsupportedEditRestartsWithoutBlank() async throws {
        let root = TestWorkspaceDirectory.make(".build/DisplayWorkspaceRevision/PreviewFixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ object: Any) throws {
            let target = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: target)
        }
        try write("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
            "shown": ["type": "bool", "value": true], "unused": ["type": "slider", "value": 1, "min": 0, "max": 2]]]])
        try write("models/layer.json", ["material": "materials/base.json"])
        try write("materials/base.json", ["passes": [["shader": "solidcolor", "blending": "disabled",
            "constantshadervalues": ["g_Color": [1, 0, 0, 1]]]]])
        let script = "'use strict'; export function update(value) { return value; }"
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 10, "solid": true, "visible": ["user": "shown", "value": true]],
                        ["id": 1, "parent": 10, "image": "models/layer.json", "size": "64 64 0",
                         "origin": ["value": "32 32 0", "script": script]]]])
        let wallpaper = Wallpaper(name: "Continuity fixture", type: .scene, source: .local, resourceURL: root)
        let preview = DisplayScenePreview()
        let window = NSWindow(contentRect: .init(x: 80, y: 100, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = preview.surface; window.orderBack(nil)
        defer { preview.stop(); window.contentView = nil; window.close() }
        preview.update(wallpaper, values: [:], fit: .automatic, aspect: 1.6)
        try await waitForPreview(preview)
        let renderer = try XCTUnwrap(preview.renderer), host = try XCTUnwrap(renderer.scene.fullHostForTesting)
        let time = renderer.scene.sceneTime
        for i in 0..<10 {
            preview.update(wallpaper, values: ["shown": .bool(i.isMultiple(of: 2))], fit: .automatic, aspect: 1.6)
            try await Task.sleep(nanoseconds: 100_000_000)
            preview.update(wallpaper, values: ["shown": .bool(!i.isMultiple(of: 2))], fit: .automatic, aspect: 1.6)
            try await waitForPreview(preview)
            XCTAssertNil(preview.error); XCTAssertTrue(preview.renderer === renderer)
            XCTAssertTrue(renderer.scene.fullHostForTesting === host); XCTAssertTrue(renderer.scene.isPlaying)
            XCTAssertGreaterThanOrEqual(renderer.scene.sceneTime, time)
        }
        // The running host cannot take this edit: the wallpaper restarts with it, no error line,
        // and the last frame stays on screen while the replacement loads.
        preview.update(wallpaper, values: ["unused": .number(2)], fit: .automatic, aspect: 1.6)
        var sawBlank = false
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while preview.isPreparing && ProcessInfo.processInfo.systemUptime < deadline {
            let covered = preview.renderer.map { $0.scene.isPrepared && $0.displayView.superview === preview.surface } ?? false
            if !covered && preview.surface.layer?.contents == nil && preview.renderer !== renderer { sawBlank = true }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(preview.isPreparing); XCTAssertFalse(sawBlank, "The preview never goes blank while restarting")
        XCTAssertNil(preview.error)
        let restarted = try XCTUnwrap(preview.renderer)
        XCTAssertFalse(restarted === renderer); XCTAssertNil(renderer.scene.fullHostForTesting)
        XCTAssertTrue(restarted.scene.isPlaying)
        XCTAssertEqual(preview.surface.subviews.count, 1); XCTAssertTrue(preview.surface.subviews.first === restarted.displayView)
        // A continuous edit on the restarted host still keeps it.
        let restartedHost = try XCTUnwrap(restarted.scene.fullHostForTesting)
        preview.update(wallpaper, values: ["unused": .number(2), "shown": .bool(false)], fit: .automatic, aspect: 1.6)
        try await waitForPreview(preview)
        XCTAssertNil(preview.error); XCTAssertTrue(preview.renderer === restarted)
        XCTAssertTrue(restarted.scene.fullHostForTesting === restartedHost); XCTAssertTrue(restarted.scene.isPlaying)
    }

    @MainActor func testActualAuthoredParametersUseSamePreviewHostForAllThreeSuppliedScenes() async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: base.appendingPathComponent(".build/DisplayWorkspaceRevision/authored-binding-audit.json"))
        let samples = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let assets = EngineAssetsStore.standardManagedInstallURL()
        let previousAssets = SceneRenderer.engineAssetsProvider; SceneRenderer.engineAssetsProvider = { assets }
        defer { SceneRenderer.engineAssetsProvider = previousAssets }
        var report: [[String: Any]] = []
        for sample in samples {
            let id = try XCTUnwrap(sample["workshopID"] as? String), path = try XCTUnwrap(sample["root"] as? String)
            let root = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("Supplied Scene package is no longer present: " + id) }
            let wallpaper = Wallpaper(name: "Read-only actual " + id, type: .scene, source: .steam, resourceURL: root)
            let preview = DisplayScenePreview()
            let window = NSWindow(contentRect: .init(x: 80, y: 100, width: 480, height: 312),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = preview.surface; window.orderBack(nil)
            defer { preview.stop(); window.contentView = nil; window.close() }
            preview.update(wallpaper, values: [:], fit: .automatic, aspect: 1.6)
            try await waitForPreview(preview, timeout: 30)
            let renderer = try XCTUnwrap(preview.renderer), host = try XCTUnwrap(renderer.scene.fullHostForTesting)
            let startTime = renderer.scene.sceneTime
            let changes: [[String: ScenePropertyValue]]
            switch id {
            case "3326873240": changes = [["newproperty33": .number(100)], ["x2": .number(0.6), "y3": .number(0.6)], ["day1": .bool(false)], [:]]
            case "3379996991": changes = [["clocksize": .number(0.5)], ["x": .number(0.1), "y": .number(0.1)], ["enabled": .bool(false)], [:]]
            default: changes = [["newproperty": .number(0.3)], [:]]
            }
            var patchReports: [[String: Any]] = []
            for change in changes {
                preview.update(wallpaper, values: change, fit: .automatic, aspect: 1.6)
                try await waitForPreview(preview)
                patchReports.append(["keys": change.keys.sorted(), "error": preview.error as Any? ?? NSNull(),
                    "sameHost": preview.renderer === renderer && renderer.scene.fullHostForTesting === host,
                    "sceneTime": renderer.scene.sceneTime])
                XCTAssertNil(preview.error, "Scene " + id + " keys " + change.keys.sorted().joined(separator: ",") + ": " + (preview.error ?? ""))
                XCTAssertTrue(preview.renderer === renderer); XCTAssertTrue(renderer.scene.fullHostForTesting === host)
                XCTAssertTrue(renderer.scene.isPlaying); XCTAssertGreaterThanOrEqual(renderer.scene.sceneTime, startTime)
            }
            report.append(["workshopID": id, "patches": patchReports, "sameHost": preview.renderer === renderer,
                           "startTime": startTime, "endTime": renderer.scene.sceneTime, "error": preview.error as Any? ?? NSNull()])
            preview.stop(); window.contentView = nil; window.close()
            await renderer.scene.disposeAwaitingResources()
        }
        let reportDirectory = TestWorkspaceDirectory.make(".build/DisplayWorkspaceRevision")
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportDirectory.appendingPathComponent("actual-scene-continuity.json"))
    }
    @MainActor private func waitForPreview(_ preview: DisplayScenePreview, timeout: TimeInterval = 5) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while preview.isPreparing && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(preview.isPreparing, "Preview did not complete in time")
    }

}
@MainActor private final class WorkspaceProbeRecorder { var views: [NSView] = [] }
private struct WorkspaceNativeProbe: NSViewRepresentable {
    let recorder: WorkspaceProbeRecorder
    func makeNSView(context: Context) -> NSView { let view = NSView(); recorder.views.append(view); return view }
    func updateNSView(_ view: NSView, context: Context) {}
}
private struct WorkspaceHarness: View {
    let preview: WorkspaceProbeRecorder
    let console: WorkspaceProbeRecorder
    let selector: WorkspaceProbeRecorder
    var body: some View {
        DisplayWorkspace(aspect: 1.6) { Text("显示器") } selector: { WorkspaceNativeProbe(recorder: selector) }
            preview: { _ in WorkspaceNativeProbe(recorder: preview) }
            console: { WorkspaceNativeProbe(recorder: console) } status: { EmptyView() }
    }
}
