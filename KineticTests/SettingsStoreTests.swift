import Foundation
import XCTest
@testable import Kinetic

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testDefaultsPersistAcrossStoreRecreation() {
        let suite = "KineticTests.Settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults)
        XCTAssertEqual(first.state, SettingsState())
        first.set(\.appearance, to: .dark)
        first.set(\.wallpaperAudioEnabled, to: true)
        first.set(\.smartPauseEnabled, to: false)
        first.set(\.webNetworkAccessEnabled, to: false)
        first.set(\.launchAtLoginEnabled, to: true)

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.state.appearance, .dark)
        XCTAssertTrue(restored.state.wallpaperAudioEnabled)
        XCTAssertFalse(restored.state.smartPauseEnabled)
        XCTAssertFalse(restored.state.webNetworkAccessEnabled)
        XCTAssertTrue(restored.state.launchAtLoginEnabled)
    }

    func testCorruptSettingsFallBackToProductDefaults() {
        let suite = "KineticTests.Settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: SettingsStore.storageKey)

        XCTAssertEqual(SettingsStore(defaults: defaults).state, SettingsState())
    }

    /// 新增「低电量模式时暂停」「使用电池时暂停」之前保存的设置仍完整读取，新选项取默认值。
    func testSettingsSavedBeforePowerOptionsKeepTheirValues() throws {
        let suite = "KineticTests.Settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = #"{"appearance":"dark","launchAtLoginEnabled":true,"wallpaperAudioEnabled":true,"smartPauseEnabled":false,"webNetworkAccessEnabled":false}"#
        defaults.set(Data(legacy.utf8), forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.state.appearance, .dark)
        XCTAssertTrue(store.state.launchAtLoginEnabled)
        XCTAssertTrue(store.state.wallpaperAudioEnabled)
        XCTAssertFalse(store.state.smartPauseEnabled)
        XCTAssertFalse(store.state.webNetworkAccessEnabled)
        XCTAssertTrue(store.state.pauseInLowPowerMode)
        XCTAssertFalse(store.state.pauseOnBatteryPower)
        XCTAssertTrue(store.state.pauseWhenFullScreen)
        XCTAssertFalse(store.state.pauseWhenOccluded)
        XCTAssertEqual(store.state.smartPauseExcludedApps, [])

        store.set(\.pauseInLowPowerMode, to: false)
        store.set(\.pauseOnBatteryPower, to: true)
        let restored = SettingsStore(defaults: defaults)
        XCTAssertFalse(restored.state.pauseInLowPowerMode)
        XCTAssertTrue(restored.state.pauseOnBatteryPower)
        XCTAssertEqual(restored.state.appearance, .dark)
    }

    func testPerDisplayPolicyAndAppExceptionsPersistWithoutChangingExistingSettings() throws {
        let suite = "KineticTests.Settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.set(\.appearance, to: .dark)
        store.set(\.pauseWhenFullScreen, to: false)
        store.set(\.pauseWhenOccluded, to: true)
        store.set(\.smartPauseExcludedApps, to: ["com.apple.Safari", "com.apple.Preview"])

        let restored = SettingsStore(defaults: defaults)
        XCTAssertFalse(restored.state.pauseWhenFullScreen)
        XCTAssertTrue(restored.state.pauseWhenOccluded)
        XCTAssertEqual(restored.state.smartPauseExcludedApps, ["com.apple.Safari", "com.apple.Preview"])
        XCTAssertEqual(restored.state.appearance, .dark)
        XCTAssertEqual(restored.state.webNetworkAccessEnabled, SettingsState().webNetworkAccessEnabled)
        restored.set(\.smartPauseExcludedApps, to: ["com.apple.Preview"])
        XCTAssertEqual(SettingsStore(defaults: defaults).state.smartPauseExcludedApps, ["com.apple.Preview"])
    }
}
