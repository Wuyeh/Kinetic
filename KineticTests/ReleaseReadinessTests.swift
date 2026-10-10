import SwiftUI
import XCTest
@testable import Kinetic

/// Module 62：版本号、随包附带的第三方许可与设置 › 关于的致谢。
@MainActor
final class ReleaseReadinessTests: XCTestCase {
    func testVersionIsOnePointZero() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.0.0")
        XCTAssertTrue(SettingsContentView.versionText.contains("1.0.0"), SettingsContentView.versionText)
    }

    /// MIT 许可要求分发时附上版权与许可声明：每一项都要能在 App 包里读到完整原文。
    func testEveryAcknowledgementShipsItsLicenseText() throws {
        XCTAssertEqual(Acknowledgement.all.map(\.id), ["sparkle", "scene-engine"])
        for item in Acknowledgement.all {
            let text = try XCTUnwrap(item.licenseText, "\(item.name) 的许可原文不在 App 包里")
            XCTAssertTrue(text.contains("Permission is hereby granted, free of charge"), item.name)
            XCTAssertTrue(text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""), item.name)
        }
        XCTAssertTrue(try XCTUnwrap(Acknowledgement.all.first?.licenseText).contains("Andy Matuschak"))
        XCTAssertTrue(try XCTUnwrap(Acknowledgement.all.last?.licenseText).contains("Loomscreen contributors"))
    }

    func testAcknowledgementsSnapshots() throws {
        let view = AcknowledgementsSection().padding(28)
        let size = CGSize(width: 628, height: 200)
        try R4SnapshotTests.render(view, size: size, name: "module62-acknowledgements")
        try R4SnapshotTests.render(view, size: size, name: "module62-acknowledgements-dark", appearance: .darkAqua)
    }
}
