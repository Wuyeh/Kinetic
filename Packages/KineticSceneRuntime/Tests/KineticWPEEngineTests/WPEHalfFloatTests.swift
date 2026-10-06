import XCTest
@testable import KineticWPEEngine

final class WPEHalfFloatTests: XCTestCase {
    func testSignedZeroSubnormalsAndNonfiniteValues() {
        XCTAssertEqual(WPEHalfFloat.decode(0x0000).bitPattern, 0)
        XCTAssertEqual(WPEHalfFloat.decode(0x8000).bitPattern, 0x80000000)
        XCTAssertEqual(WPEHalfFloat.decode(0x0001), Float(1) / 16777216)
        XCTAssertEqual(WPEHalfFloat.decode(0x03ff), Float(1023) / 16777216)
        XCTAssertEqual(WPEHalfFloat.decode(0x0400), Float(1) / 16384)
        XCTAssertEqual(WPEHalfFloat.decode(0x3c00), 1)
        XCTAssertEqual(WPEHalfFloat.decode(0xbc00), -1)
        XCTAssertEqual(WPEHalfFloat.decode(0x7bff), 65504)
        XCTAssertEqual(WPEHalfFloat.decode(0x7c00), .infinity)
        XCTAssertEqual(WPEHalfFloat.decode(0xfc00), -.infinity)
        XCTAssertTrue(WPEHalfFloat.decode(0x7e00).isNaN)
        XCTAssertTrue(WPEHalfFloat.decode(0xffff).isNaN)
    }

    #if arch(arm64)
    func testEveryHalfBitPatternMatchesNativeConversion() {
        for raw in UInt32(0)...UInt32(UInt16.max) {
            let bits = UInt16(raw)
            let expected = Float(Float16(bitPattern: bits))
            let actual = WPEHalfFloat.decode(bits)
            if expected.isNaN { XCTAssertTrue(actual.isNaN, "bits: \(bits)") }
            else { XCTAssertEqual(actual.bitPattern, expected.bitPattern, "bits: \(bits)") }
        }
    }
    #endif
}
