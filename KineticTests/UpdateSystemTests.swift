import CryptoKit
import SwiftUI
import XCTest
@testable import Kinetic

/// Module 54：更新地址 / 公钥的读取规则、Info.plist 里的 Sparkle 配置、设置项和关于页。
@MainActor
final class UpdateSystemTests: XCTestCase {
    func testFeedURLAcceptsReleaseAndLocalSourcesOnly() {
        XCTAssertEqual(UpdateConfiguration.feedURL("https://example.com/kinetic/appcast.xml")?.host, "example.com")
        XCTAssertNotNil(UpdateConfiguration.feedURL(" http://127.0.0.1:8765/appcast.xml "), "本机验收用的 http 源")
        XCTAssertNotNil(UpdateConfiguration.feedURL("file:///tmp/kinetic/appcast.xml"))
        XCTAssertNil(UpdateConfiguration.feedURL(nil))
        XCTAssertNil(UpdateConfiguration.feedURL(""), "没有配置地址的构建不检查更新")
        XCTAssertNil(UpdateConfiguration.feedURL("$(KINETIC_UPDATE_FEED_URL)"), "未展开的构建变量")
        XCTAssertNil(UpdateConfiguration.feedURL("ftp://example.com/appcast.xml"))
        XCTAssertNil(UpdateConfiguration.feedURL("https:///appcast.xml"))
    }

    func testPublicKeyMustBeA32ByteEd25519Key() {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(UpdateConfiguration.publicKey(key), key)
        XCTAssertNil(UpdateConfiguration.publicKey(nil))
        XCTAssertNil(UpdateConfiguration.publicKey("not base64"))
        XCTAssertNil(UpdateConfiguration.publicKey(Data(repeating: 1, count: 31).base64EncodedString()))
        let configured = UpdateConfiguration(info: [UpdateConfiguration.feedURLKey: "https://example.com/a.xml",
                                                    UpdateConfiguration.publicKeyKey: key])
        XCTAssertTrue(configured.isConfigured)
        XCTAssertFalse(UpdateConfiguration(info: [UpdateConfiguration.publicKeyKey: key]).isConfigured)
        XCTAssertFalse(UpdateConfiguration(info: [UpdateConfiguration.feedURLKey: "https://example.com/a.xml"]).isConfigured)
    }

    /// 发布签名的私钥文件是 base64 的 32 字节种子（Sparkle `--ed-key-file` 格式）；从种子还原的公钥与 App 里的公钥格式一致。
    func testSeedKeyFileFormatProducesTheBundledKeyShape() throws {
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        XCTAssertEqual(seed.count, 32)
        let restored = try Curve25519.Signing.PrivateKey(rawRepresentation: try XCTUnwrap(Data(base64Encoded: seed.base64EncodedString())))
        let signature = try restored.signature(for: Data("Kinetic".utf8))
        XCTAssertTrue(restored.publicKey.isValidSignature(signature, for: Data("Kinetic".utf8)))
        XCTAssertNotNil(UpdateConfiguration.publicKey(restored.publicKey.rawRepresentation.base64EncodedString()))
    }

    /// 构建出来的 Info.plist：Sparkle 在沙盒里装更新、每天检查、不自动安装；测试构建没有更新地址。
    func testBundledSparkleConfiguration() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertNotNil(UpdateConfiguration.publicKey(info["SUPublicEDKey"] as? String), "公钥必须是有效的 Ed25519 公钥")
        XCTAssertEqual(info["SUEnableInstallerLauncherService"] as? Bool, true)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true, "不让 Sparkle 再弹一次是否自动检查的询问")
        XCTAssertEqual((info["SUScheduledCheckInterval"] as? NSNumber)?.intValue, 86_400)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false, "下载安装都由用户确认")
        XCTAssertNotNil(info[UpdateConfiguration.feedURLKey], "地址键存在（构建设置可以写入）")
        XCTAssertFalse(UpdateConfiguration.bundled.isConfigured, "默认构建不带更新地址")
        XCTAssertNotNil(Bundle.main.privateFrameworksURL.flatMap { Bundle(url: $0.appendingPathComponent("Sparkle.framework")) },
                        "Sparkle.framework 嵌在 App 里")
    }

    func testAutomaticChecksSettingDefaultsOnAndReadsOldSettings() throws {
        XCTAssertTrue(SettingsState().automaticUpdateChecksEnabled)
        let old = try JSONDecoder().decode(SettingsState.self, from: Data(#"{"smartPauseEnabled": false}"#.utf8))
        XCTAssertTrue(old.automaticUpdateChecksEnabled, "旧版本保存的设置没有这个键时用默认值")
        XCTAssertFalse(old.smartPauseEnabled)
        var state = SettingsState()
        state.automaticUpdateChecksEnabled = false
        let decoded = try JSONDecoder().decode(SettingsState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(decoded.automaticUpdateChecksEnabled)
    }

    func testUnconfiguredBuildNeverStartsSparkle() {
        let suite = "Kinetic.Update.Test." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let updates = UpdateController(configuration: UpdateConfiguration(feedURL: nil, publicKey: nil),
                                       settings: SettingsStore(defaults: UserDefaults(suiteName: suite)!))
        updates.start()
        XCTAssertFalse(updates.isRunning)
        XCTAssertFalse(updates.canCheckForUpdates)
        updates.checkForUpdates()
        XCTAssertNil(updates.lastError)
    }

    func testOnlyRealFailuresAreReported() {
        XCTAssertNil(UpdateController.failureMessage(nil))
        XCTAssertNil(UpdateController.failureMessage(NSError(domain: "SUSparkleErrorDomain", code: 1001)), "已是最新版本")
        XCTAssertNil(UpdateController.failureMessage(NSError(domain: "SUSparkleErrorDomain", code: 4007)), "用户取消安装")
        XCTAssertEqual(UpdateController.failureMessage(NSError(domain: NSURLErrorDomain, code: -1009,
            userInfo: [NSLocalizedDescriptionKey: "似乎已断开与互联网的连接。"])), "似乎已断开与互联网的连接。")
    }

    /// 设置 › 关于（没有配置更新地址的构建），浅色 / 深色。
    func testAboutUpdateSectionSnapshots() throws {
        let suite = "Kinetic.Update.Snapshot." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let updates = UpdateController(configuration: UpdateConfiguration(feedURL: nil, publicKey: nil), settings: settings)
        let view = UpdateSettingsSection(updates: updates, settings: settings).padding(28)
        let size = CGSize(width: 628, height: 160)
        try R4SnapshotTests.render(view, size: size, name: "module54-update-unconfigured")
        try R4SnapshotTests.render(view, size: size, name: "module54-update-unconfigured-dark", appearance: .darkAqua)
        XCTAssertEqual(UpdateSettingsSection.lastCheckText(nil), "还没有检查过")
    }
}
