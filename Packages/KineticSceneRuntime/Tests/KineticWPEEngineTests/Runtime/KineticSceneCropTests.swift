import CoreGraphics
import XCTest
@testable import KineticWPEEngine

/// 显示方式 › 自定义（2026-10-08）：用户选定的画布区域，在显示器上始终铺满。
final class KineticSceneCropTests: XCTestCase {
    private let canvas = CGSize(width: 1920, height: 1080)
    private let display = CGSize(width: 1600, height: 1000)

    private func assertRect(_ rect: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in [(rect.minX, expected.minX), (rect.minY, expected.minY), (rect.width, expected.width), (rect.height, expected.height)] {
            XCTAssertEqual(a, b, accuracy: 1e-9, "\(rect) vs \(expected)", file: file, line: line)
        }
    }

    func testDefaultRegionIsTheCenteredCoverCrop() {
        // 16:9 on 16:10: full height, the middle 0.9 of the width (cover).
        let width = (16.0 / 10.0) / (16.0 / 9.0)
        assertRect(KineticSceneCrop().region(source: canvas, target: display),
                   CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1))
        // A portrait canvas on a landscape display keeps the full width.
        let portrait = KineticSceneCrop().region(source: CGSize(width: 1000, height: 2000), target: display)
        XCTAssertEqual(portrait.width, 1, accuracy: 1e-9)
        XCTAssertEqual(portrait.height, (1000.0 / 2000.0) / 1.6, accuracy: 1e-9)
    }

    func testZoomAndCenterStayInsideTheCanvas() {
        let width = (16.0 / 10.0) / (16.0 / 9.0) / 2, height = 0.5
        assertRect(KineticSceneCrop(zoom: 2, centerX: 0.3, centerY: 0.6).region(source: canvas, target: display),
                   CGRect(x: 0.3 - width / 2, y: 0.6 - height / 2, width: width, height: height))
        // Past an edge the region stops at the edge: the display never shows anything outside the canvas.
        assertRect(KineticSceneCrop(zoom: 2, centerX: 0, centerY: 1).region(source: canvas, target: display),
                   CGRect(x: 0, y: 1 - height, width: width, height: height))
        assertRect(KineticSceneCrop(zoom: 1, centerX: 0.9, centerY: 0.1).region(source: canvas, target: display),
                   CGRect(x: 1 - width * 2, y: 0, width: width * 2, height: 1))
        // Zoom is limited to 1…maximum; unusable numbers fall back to the centred cover crop.
        XCTAssertEqual(KineticSceneCrop(zoom: 0.2).region(source: canvas, target: display),
                       KineticSceneCrop(zoom: 1).region(source: canvas, target: display))
        XCTAssertEqual(KineticSceneCrop(zoom: 50).region(source: canvas, target: display),
                       KineticSceneCrop(zoom: KineticSceneCrop.maximumZoom).region(source: canvas, target: display))
        XCTAssertEqual(KineticSceneCrop(zoom: .nan, centerX: .infinity, centerY: .nan).region(source: canvas, target: display),
                       KineticSceneCrop().region(source: canvas, target: display))
        XCTAssertEqual(KineticSceneCrop().region(source: .zero, target: display), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testPresentPassSamplesTheRegionAndThePointerFollowsIt() throws {
        let crop = KineticSceneCrop(zoom: 2, centerX: 0.25, centerY: 0.75)
        let uniforms = WPEPresentUniforms.make(fitMode: .custom(crop), sourceWidth: 1920, sourceHeight: 1080,
                                               targetWidth: 1600, targetHeight: 1000)
        let region = crop.region(source: canvas, target: display)
        XCTAssertEqual(uniforms.ndcScale, SIMD2<Float>(1, 1), "the region fills the display, no bars")
        XCTAssertEqual(Double(uniforms.uvScale.x), region.width, accuracy: 1e-6)
        XCTAssertEqual(Double(uniforms.uvScale.y), region.height, accuracy: 1e-6)
        XCTAssertEqual(Double(uniforms.uvOffset.x), region.minX, accuracy: 1e-6)
        XCTAssertEqual(Double(uniforms.uvOffset.y), region.minY, accuracy: 1e-6)
        // The display's centre is the region's centre in the scene; its corners are the region's corners.
        let centre = try XCTUnwrap(uniforms.scenePointer(fromDrawablePointer: SIMD2(0.5, 0.5)))
        XCTAssertEqual(centre.x, 0.25, accuracy: 1e-6); XCTAssertEqual(centre.y, 0.75, accuracy: 1e-6)
        let corner = try XCTUnwrap(uniforms.scenePointer(fromDrawablePointer: SIMD2(1, 1)))
        XCTAssertEqual(corner.x, region.maxX, accuracy: 1e-6); XCTAssertEqual(corner.y, region.maxY, accuracy: 1e-6)
    }

    func testRenderScaleFollowsTheZoomButNeverPassesTheCanvas() {
        let small = CGSize(width: 960, height: 600)
        let cover = WPEMetalUpscalePlan.displayFitScale(worldCanvas: canvas, drawableSize: small, fitMode: .cover)
        XCTAssertEqual(WPEMetalUpscalePlan.displayFitScale(worldCanvas: canvas, drawableSize: small, fitMode: .custom(.init())),
                       cover, accuracy: 1e-9)
        XCTAssertEqual(WPEMetalUpscalePlan.displayFitScale(worldCanvas: canvas, drawableSize: small,
                                                           fitMode: .custom(.init(zoom: 1.5))), min(1, cover * 1.5), accuracy: 1e-9)
        XCTAssertEqual(WPEMetalUpscalePlan.displayFitScale(worldCanvas: canvas, drawableSize: small,
                                                           fitMode: .custom(.init(zoom: 5))), 1)
        XCTAssertEqual(WPEMetalFXSpatialUpscaler.preScalerRejection(fitMode: .custom(.init()), sourceWidth: 800,
                       sourceHeight: 500, drawableWidth: 1600, drawableHeight: 1000), .fitMode,
                       "the scaler maps full rects only; a region is presented by the present pass")
    }
}
