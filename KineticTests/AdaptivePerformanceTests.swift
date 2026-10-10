import AppKit
import XCTest
@testable import Kinetic

@MainActor
final class AdaptivePerformanceTests: XCTestCase {
    private var suite = ""
    override func tearDown() async throws { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    private func settings() -> SettingsStore {
        suite = "Kinetic.Adaptive.Tests." + UUID().uuidString
        return SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    func testReasonsFollowPowerAndThermalStateOnlyWhenEnabled() {
        var conditions = SmartPauseConditions()
        XCTAssertNil(AdaptiveFrameRateController.reason(enabled: true, conditions: conditions, thermal: .nominal))
        XCTAssertNil(AdaptiveFrameRateController.reason(enabled: true, conditions: conditions, thermal: .fair), "fair is normal")
        XCTAssertEqual(AdaptiveFrameRateController.reason(enabled: true, conditions: conditions, thermal: .serious), .thermal)
        conditions.onBatteryPower = true
        XCTAssertEqual(AdaptiveFrameRateController.reason(enabled: true, conditions: conditions, thermal: .nominal), .battery)
        conditions.lowPowerMode = true
        XCTAssertEqual(AdaptiveFrameRateController.reason(enabled: true, conditions: conditions, thermal: .serious), .lowPowerMode)
        XCTAssertNil(AdaptiveFrameRateController.reason(enabled: false, conditions: conditions, thermal: .critical))
        XCTAssertTrue(SettingsState().adaptiveFrameRateEnabled, "on by default")
    }

    func testControllerAppliesOnlyOnChangesAndRestoresOnShutdown() {
        let store = settings()
        var thermal = ProcessInfo.ThermalState.nominal
        var applied: [Bool] = []
        let controller = AdaptiveFrameRateController(settings: store, monitor: nil, thermalState: { thermal }) { applied.append($0) }
        XCTAssertNil(controller.reason); XCTAssertEqual(applied, [])
        thermal = .serious; controller.update(); controller.update()
        XCTAssertEqual(controller.reason, .thermal); XCTAssertEqual(applied, [true])
        store.set(\.adaptiveFrameRateEnabled, to: false)
        XCTAssertNil(controller.reason); XCTAssertEqual(applied, [true, false], "turning it off restores full rate")
        store.set(\.adaptiveFrameRateEnabled, to: true)
        XCTAssertEqual(applied, [true, false, true])
        controller.shutdown()
        XCTAssertEqual(applied, [true, false, true, false])
    }

    func testRenderersFollowTheGlobalThrottleAndNewOnesStartThrottled() {
        defer { AdaptiveFrameRateController.applyToRenderers(false) }
        AdaptiveFrameRateController.applyToRenderers(true)
        XCTAssertTrue(SceneRenderer.isAdaptiveFrameRateThrottled)
        XCTAssertEqual(WebRenderer.adaptiveFrameRateLimit, 30)
        AdaptiveFrameRateController.applyToRenderers(false)
        XCTAssertFalse(SceneRenderer.isAdaptiveFrameRateThrottled)
        XCTAssertNil(WebRenderer.adaptiveFrameRateLimit)
        XCTAssertTrue(WebRenderer.controlScript.contains("setFrameRate(value)"))
    }

    func testOwnProcessUsageIsReadAndSummarised() throws {
        let usage = try XCTUnwrap(ProcessUsage.current())
        XCTAssertGreaterThan(usage.memoryBytes, 1_000_000)
        XCTAssertGreaterThanOrEqual(usage.cpuPercent, 0)
        XCTAssertTrue(ProcessUsage(cpuPercent: 3.25, memoryBytes: 412 * 1_048_576).summary.hasPrefix("Kinetic 占用 CPU 3.2% · 内存 "))
        XCTAssertTrue(ProcessUsage(cpuPercent: 42.4, memoryBytes: 0).summary.contains("CPU 42%"))
    }

    func testTheStripSamplesOnlyWhileAMenuIsOpen() {
        var reads = 0
        let model = PerformanceStripModel { reads += 1; return ProcessUsage(cpuPercent: Double(reads), memoryBytes: 1) }
        defer { model.shutdown() }
        XCTAssertEqual(reads, 1); XCTAssertFalse(model.isSampling)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        XCTAssertTrue(model.isSampling); XCTAssertEqual(model.usage?.cpuPercent, 2)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertFalse(model.isSampling)
    }

    /// A real page: its requestAnimationFrame loop runs at the display rate, then at most 30 frames a second while limited.
    func testWebWallpaperAnimationFramesAreCappedWhileLimited() async throws {
        defer { WebRenderer.applyAdaptiveFrameRateLimit(nil) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptiveWeb-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
        <!doctype html><html><body><script>
        window.frames = 0; let last = -1;
        function tick(time) { if (time !== last) { window.frames++; last = time; } requestAnimationFrame(tick); }
        requestAnimationFrame(tick);
        </script></body></html>
        """.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let renderer = WebRenderer(wallpaper: Wallpaper(name: "帧率", type: .web, source: .local, resourceURL: folder))
        defer { renderer.dispose() }
        try await renderer.prepare()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 320, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        renderer.contentView.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(renderer.contentView)
        window.orderFrontRegardless()
        defer { window.close() }
        renderer.play()
        let web = try XCTUnwrap(renderer.contentView.webView)
        func framesPerSecond() async throws -> Double {
            try await Task.sleep(nanoseconds: 300_000_000)
            let start = try await web.evaluateJavaScript("window.frames") as? Int ?? 0
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let end = try await web.evaluateJavaScript("window.frames") as? Int ?? 0
            return Double(end - start)
        }
        let free = try await framesPerSecond()
        WebRenderer.applyAdaptiveFrameRateLimit(30)
        let limited = try await framesPerSecond()
        XCTAssertLessThanOrEqual(limited, 34, "free \(free), limited \(limited)")
        XCTAssertGreaterThan(limited, 10)
        XCTAssertGreaterThan(free, limited + 10, "the display runs faster than the cap")
        WebRenderer.applyAdaptiveFrameRateLimit(nil)
        let restored = try await framesPerSecond()
        XCTAssertGreaterThan(restored, limited + 10)
        print("Module 51 web frames per second: free \(free), limited \(limited), restored \(restored)")
    }
}
