import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// R4：把关键视图渲染成 PNG，供人工查看布局（.build/R4/snapshots，沙盒中退回临时目录）。只断言渲染成功与尺寸。
@MainActor
final class R4SnapshotTests: XCTestCase {
    /// 签名沙盒中只能写入 App 允许的共享目录（Kinetic Steam 的例外路径）；之后由开发者复制到 .build/R4/snapshots。
    static let folder: URL = {
        let repository = TestWorkspaceDirectory.make(".build/R4/snapshots").deletingLastPathComponent()
        if !repository.path.contains("/Library/Containers/") { return repository }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.kinetic.app/Data", with: "")
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Kinetic Steam/R4Snapshots", isDirectory: true)
    }()

    @discardableResult
    static func render<V: View>(_ view: V, size: CGSize, name: String, appearance: NSAppearance.Name = .aqua) throws -> URL {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -6000, y: -6000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("R4 snapshot: \(url.path)")
        return url
    }

    func testDownloadListRows() throws {
        let rows = [
            SteamDownloadRow(id: "1", title: "极光 001", posterURL: nil, type: .video, ratio: "16:9", phase: .downloading(progress: 0.62)),
            SteamDownloadRow(id: "2", title: "Cyber Street 很长很长的壁纸名称用于截断检查", posterURL: nil, type: .web, ratio: "21:9",
                             phase: .downloading(progress: 0.18)),
            SteamDownloadRow(id: "3", title: "雨夜", posterURL: nil, type: .scene, ratio: nil, phase: .queued),
        ]
        let size = CGSize(width: SteamDownloadsMenuAnchor.width, height: 3 * SteamDownloadsMenuAnchor.rowHeight + 38)
        try Self.render(SteamDownloadsListContent(rows: rows), size: size, name: "download-list")
        try Self.render(SteamDownloadsListContent(rows: rows), size: size, name: "download-list-dark", appearance: .darkAqua)
        try Self.render(HStack(spacing: 20) {
            SteamDownloadRing(progress: 0.35)
            SteamDownloadRing(progress: 0.8)
            SteamDownloadRing(progress: nil)
        }, size: CGSize(width: 200, height: 60), name: "download-ring")
    }

    func testDisplayBubble() throws {
        let rows = [FloatingBarDisplayRow(id: DisplayID("a"), name: "Wu 的 MacBook Pro", detail: "极光 · 正在播放", isControlled: true),
                    FloatingBarDisplayRow(id: DisplayID("b"), name: "Studio Display", detail: "雨夜 · 已暂停", isControlled: false),
                    FloatingBarDisplayRow(id: DisplayID("c"), name: "LG UltraFine", detail: "系统壁纸", isControlled: false)]
        try Self.render(FloatingBarDisplayBubble(hostName: "Wu 的 MacBook Pro", status: "正在播放", rows: rows, onSelect: { _ in }),
                        size: CGSize(width: 270, height: 210), name: "display-bubble")
    }
}
