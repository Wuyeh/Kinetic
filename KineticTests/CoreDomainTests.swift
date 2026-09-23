import Foundation
import XCTest
@testable import Kinetic

final class CoreDomainTests: XCTestCase {
    func testWallpaperMetadataRoundTripsForEveryTypeAndSource() throws {
        // 仅构造 URL 值，不创建或读取媒体文件。
        let baseURL = URL(fileURLWithPath: "/kinetic-model-fixtures", isDirectory: true)

        for type in WallpaperType.allCases {
            for source in WallpaperSource.allCases {
                let wallpaper = Wallpaper(
                    name: "测试壁纸",
                    type: type,
                    source: source,
                    resourceURL: baseURL.appendingPathComponent("resource"),
                    thumbnailURL: baseURL.appendingPathComponent("preview.png"),
                    isFavorite: true,
                    steamMetadata: source == .steam
                        ? SteamMetadata(workshopID: "123456789", author: "测试作者", sizeInBytes: 1024)
                        : nil
                )

                let data = try JSONEncoder().encode(wallpaper)
                let restored = try JSONDecoder().decode(Wallpaper.self, from: data)

                XCTAssertEqual(restored, wallpaper)
                XCTAssertEqual(restored.id, wallpaper.id)
                XCTAssertEqual(restored.supportState, type == .scene ? .unsupported : .supported)
            }
        }
    }

    func testEditingMetadataPreservesWallpaperIdentity() {
        var wallpaper = Wallpaper(
            name: "原名称",
            type: .video,
            source: .local,
            resourceURL: URL(fileURLWithPath: "/kinetic-model-fixtures/resource")
        )
        let originalID = wallpaper.id

        wallpaper.name = "新名称"
        wallpaper.isFavorite = true

        XCTAssertEqual(wallpaper.id, originalID)
    }

    func testInitialStateMatchesProductDefaults() throws {
        let runtime = WallpaperRuntimeState()
        XCTAssertEqual(runtime.playbackState, .noWallpaper)
        XCTAssertNil(runtime.activeWallpaperID)
        XCTAssertNil(runtime.preparingWallpaperID)
        XCTAssertNil(runtime.lastActiveWallpaperID)

        let settings = SettingsState()
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.launchAtLoginEnabled)
        XCTAssertFalse(settings.wallpaperAudioEnabled)
        XCTAssertTrue(settings.smartPauseEnabled)
        XCTAssertTrue(settings.webNetworkAccessEnabled)

        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(SettingsState.self, from: data), settings)
    }

    func testPlaybackStatesHaveDistinctStableRepresentations() throws {
        let expected = Set([
            "noWallpaper", "preparing", "playing", "manualPaused",
            "smartPaused", "stopped", "failed"
        ])
        XCTAssertEqual(Set(PlaybackState.allCases.map(\.rawValue)), expected)

        for state in PlaybackState.allCases {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(PlaybackState.self, from: data), state)
        }
    }
}
