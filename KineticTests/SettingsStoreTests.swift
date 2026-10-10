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

    func testFreshStoreEnablesAndPersistsBothAgeRatingDefaults() throws {
        let suite = "KineticTests.AgeRatingDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.state.steamHideQuestionable)
        XCTAssertTrue(store.state.steamHideMature)
        XCTAssertTrue(defaults.bool(forKey: SettingsStore.steamAgeRatingDefaultsKey))
        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))
        XCTAssertEqual(try JSONDecoder().decode(SettingsState.self, from: data), store.state)
    }

    func testOldDisabledDefaultsAreEnabledWithoutChangingOtherSettings() throws {
        let suite = "KineticTests.LegacyAgeRatingDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = SettingsState()
        legacy.appearance = .dark
        legacy.launchAtLoginEnabled = true
        legacy.wallpaperAudioEnabled = true
        legacy.smartPauseEnabled = false
        legacy.webNetworkAccessEnabled = false
        legacy.sceneDisplayFit = .fit
        legacy.smartPauseExcludedApps = ["com.apple.Safari"]
        legacy.steamHideQuestionable = false
        legacy.steamHideMature = false
        defaults.set(try JSONEncoder().encode(legacy), forKey: SettingsStore.storageKey)

        var expected = legacy
        expected.steamHideQuestionable = true
        expected.steamHideMature = true
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.state, expected, "Only the two age-rating settings change")
        XCTAssertEqual(SettingsStore(defaults: defaults).state, expected)
        let saved = try XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))
        XCTAssertEqual(try JSONDecoder().decode(SettingsState.self, from: saved), expected)
    }

    func testManualDisableAfterMigrationSurvivesRestart() throws {
        let suite = "KineticTests.AgeRatingChoice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.set(\.steamHideQuestionable, to: false)
        let firstRestart = SettingsStore(defaults: defaults)
        XCTAssertFalse(firstRestart.state.steamHideQuestionable)
        XCTAssertTrue(firstRestart.state.steamHideMature)
        firstRestart.set(\.steamHideMature, to: false)
        let secondRestart = SettingsStore(defaults: defaults)
        XCTAssertEqual(secondRestart.state.steamHiddenAgeRatings, [])
        XCTAssertTrue(defaults.bool(forKey: SettingsStore.steamAgeRatingDefaultsKey))
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

    /// 28.4：场景壁纸显示方式默认「自动」（用户决定）；保存后恢复；旧版本设置没有这一项、或以后写入未知值时回到默认，其他设置不受影响。
    @MainActor
    func testSceneDisplayFitDefaultsPersistsAndToleratesUnknownValues() throws {
        let suite = "KineticSceneDisplayFit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SettingsState().sceneDisplayFit, .automatic)
        let store = SettingsStore(defaults: defaults)
        store.set(\.sceneDisplayFit, to: .fit)
        XCTAssertEqual(SettingsStore(defaults: defaults).state.sceneDisplayFit, .fit)
        let legacy = try JSONDecoder().decode(SettingsState.self, from: Data(#"{"appearance":"dark"}"#.utf8))
        XCTAssertEqual(legacy.sceneDisplayFit, .automatic); XCTAssertEqual(legacy.appearance, .dark)
        let future = try JSONDecoder().decode(SettingsState.self, from: Data(#"{"appearance":"dark","sceneDisplayFit":"zoom"}"#.utf8))
        XCTAssertEqual(future.sceneDisplayFit, .automatic); XCTAssertEqual(future.appearance, .dark)
    }
}
