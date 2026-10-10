import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor
final class VideoPlaybackViewTests: XCTestCase {
    func testLightAndDarkNativeSettingsLayouts() async throws {
        let root = TestWorkspaceDirectory.make(".build/Module30/DraftPreview/ViewFixtures")
        let library = WallpaperLibrary(storage: .init(rootURL: root))
        let store = VideoPlaybackStore(storage: .init(rootURL: root))
        let runtime = WallpaperRuntimeManager()
        let video = Wallpaper(name: "自制视频布局验收", type: .video, source: .local,
                              resourceURL: try XCTUnwrap(Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures")))
        try library.add(video)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let preview = VideoPlaybackPreview(debounceNanoseconds: 0)
            let size = CGSize(width: 640, height: 1200)
            let window = NSWindow(contentRect: .init(origin: .init(x: -5000, y: -5000), size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: ScrollView {
                VideoPlaybackSettingsSection(library: library, store: store, runtime: runtime, preview: preview).padding(24)
            }.environment(\.locale, Locale(identifier: "zh-Hans"))
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = .init(origin: .zero, size: size); window.contentView = host
            window.orderFrontRegardless()
            let deadline = Date().addingTimeInterval(8)
            while preview.previewOptions == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertNotNil(preview.previewOptions)
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = root.appendingPathComponent("advanced-video-\(appearance.rawValue).png")
            try data.write(to: url); window.close()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertNil(preview.renderer, "Closing settings must release its own preview")
            XCTAssertGreaterThan(data.count, 10_000)
            XCTAssertTrue(store.options.isEmpty, "Rendering controls cannot save or Apply")
            XCTAssertTrue(runtime.displayIDs.isEmpty)
            print("MODULE30 UI snapshot: \(url.path)")
        }
    }
}
