import CoreLocation
import SwiftUI
import XCTest
@testable import Kinetic

/// Module 55：权限状态的换算、只读刷新、系统设置入口和设置 › 权限页面。
@MainActor
final class PermissionCenterTests: XCTestCase {
    private final class FakeProbe: PermissionProbing {
        var locationStatus: CLAuthorizationStatus = .notDetermined
        var locationServicesEnabled = true
        var automation: [MusicSource: MusicAvailability] = [:]
        var screenCaptureGranted = false
        private(set) var automationReads: [MusicSource] = []
        func automationStatus(_ source: MusicSource) async -> MusicAvailability {
            automationReads.append(source)
            return automation[source] ?? .notRunning
        }
    }

    func testLocationStates() {
        XCTAssertEqual(PermissionState.location(.notDetermined, servicesEnabled: true), .notDetermined)
        XCTAssertEqual(PermissionState.location(.denied, servicesEnabled: true), .denied)
        XCTAssertEqual(PermissionState.location(.restricted, servicesEnabled: true), .restricted)
        XCTAssertEqual(PermissionState.location(.authorizedAlways, servicesEnabled: true), .granted)
        guard case .unavailable(let reason) = PermissionState.location(.authorizedAlways, servicesEnabled: false) else {
            return XCTFail("系统定位服务关闭时，应用自己的授权没有意义")
        }
        XCTAssertTrue(reason.contains("定位服务"))
    }

    func testAutomationStates() {
        XCTAssertEqual(PermissionState.automation(.live, player: "Spotify"), .granted)
        XCTAssertEqual(PermissionState.automation(.permissionRequired, player: "Spotify"), .notDetermined)
        XCTAssertEqual(PermissionState.automation(.denied, player: "Spotify"), .denied)
        guard case .unavailable(let reason) = PermissionState.automation(.notRunning, player: "Spotify") else {
            return XCTFail("播放器没运行时 macOS 不给出状态")
        }
        XCTAssertTrue(reason.contains("Spotify"))
        XCTAssertEqual(PermissionState.screenCapture(true), .granted)
        XCTAssertEqual(PermissionState.screenCapture(false), .notDetermined)
    }

    func testRefreshOnlyReadsStatus() async {
        let probe = FakeProbe()
        probe.locationStatus = .denied
        probe.automation = [.appleMusic: .live, .spotify: .permissionRequired]
        probe.screenCaptureGranted = true
        let center = PermissionCenter(probe: probe)
        await center.refresh()
        XCTAssertEqual(center.location, .denied)
        XCTAssertEqual(center.automation[.appleMusic], .granted)
        XCTAssertEqual(center.automation[.spotify], .notDetermined)
        XCTAssertEqual(center.screenCapture, .granted)
        XCTAssertEqual(Set(probe.automationReads), Set(MusicSource.allCases), "每个播放器只读状态，不请求")
        XCTAssertFalse(center.isRequesting)
    }

    func testSystemSettingsPanes() {
        XCTAssertEqual(PrivacyPane.locationServices.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        XCTAssertEqual(PrivacyPane.automation.url.query, "Privacy_Automation")
        XCTAssertEqual(PrivacyPane.screenCapture.url.query, "Privacy_ScreenCapture")
    }

    func testFileAccessText() {
        XCTAssertTrue(PermissionCenterView.engineAssetsText(nil).contains("还没有"))
        XCTAssertTrue(PermissionCenterView.engineAssetsText(.ready(.linked, name: "wallpaper_engine")).contains("wallpaper_engine"))
        XCTAssertTrue(PermissionCenterView.engineAssetsText(.ready(.downloaded, name: nil)).contains("下载"))
        XCTAssertTrue(PermissionCenterView.engineAssetsText(.unavailable(.linked, reason: "书签失效")).contains("书签失效"))
    }

    /// 设置 › 权限：定位已拒绝、Apple Music 已允许、Spotify 未运行、系统录音未询问；浅色 / 深色。
    func testPermissionCenterSnapshots() async throws {
        let probe = FakeProbe()
        probe.locationStatus = .denied
        probe.automation = [.appleMusic: .live, .spotify: .notRunning]
        let center = PermissionCenter(probe: probe)
        await center.refresh()
        let view = PermissionCenterView(center: center, engineAssets: nil, onOpenSteamSettings: {}).padding(28)
        let size = CGSize(width: 628, height: 860)
        try R4SnapshotTests.render(view, size: size, name: "module55-permissions")
        try R4SnapshotTests.render(view, size: size, name: "module55-permissions-dark", appearance: .darkAqua)
    }
}
