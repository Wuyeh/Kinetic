import XCTest
@testable import Kinetic

/// Module 62：版本号与随包附带的第三方许可。
@MainActor
final class ReleaseReadinessTests: XCTestCase {
    func testVersionIsOnePointZero() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.0.0")
        XCTAssertTrue(SettingsContentView.versionText.contains("1.0.0"), SettingsContentView.versionText)
    }

    /// 删除关于页的展示项仍需保留随分发附带的完整许可原文。
    func testUpdateLicenseRemainsBundledWithoutAboutListing() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Sparkle-LICENSE", withExtension: "txt",
                                              subdirectory: "Acknowledgements"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Andy Matuschak"))
        XCTAssertTrue(text.contains("Permission is hereby granted, free of charge"))
        XCTAssertTrue(text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }

    /// 关于页的展示与随包保存的许可独立；隐藏展示项不能丢失分发所需的原文。
    func testSceneLicenseRemainsBundledWithoutAboutListing() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "SceneEngine-LICENSE", withExtension: "txt",
                                              subdirectory: "Acknowledgements"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Copyright (c) 2026 Loomscreen contributors"))
        XCTAssertTrue(text.contains("Permission is hereby granted, free of charge"))
        XCTAssertTrue(text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }
}
