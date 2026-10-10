import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

final class ScenePropertySliderTests: XCTestCase {
    func testFineAuthoredPrecisionDoesNotCreateNativeStops() throws {
        let scale = try XCTUnwrap(ScenePropertySliderScale(minimum: 0, maximum: 300, step: 0.001))
        XCTAssertNil(scale.nativeStep, "300,000 positions must not become SwiftUI layout nodes")
        XCTAssertEqual(scale.editedValue(45.7264), 45.726, accuracy: 0.000_000_001)
        XCTAssertEqual(scale.editedValue(45.7266), 45.727, accuracy: 0.000_000_001)
        XCTAssertEqual(scale.clamped(45.726123), 45.726123, "Reading an authored default must not round or write it")
    }

    func testQuantizationIsAnchoredToAuthoredMinimumAndBounded() throws {
        let scale = try XCTUnwrap(ScenePropertySliderScale(minimum: 0.1, maximum: 10, step: 0.001))
        XCTAssertEqual(scale.editedValue(0.6284), 0.628, accuracy: 0.000_000_001)
        XCTAssertEqual(scale.editedValue(-100), 0.1)
        XCTAssertEqual(scale.editedValue(100), 10)
        let offset = try XCTUnwrap(ScenePropertySliderScale(minimum: -0.25, maximum: 1, step: 0.1))
        XCTAssertEqual(offset.editedValue(0), 0.05, accuracy: 0.000_000_001)
        XCTAssertEqual(offset.editedValue(1), 1)
    }

    func testOrdinarySteppedControlsRetainTheirExistingPresentation() throws {
        let scale = try XCTUnwrap(ScenePropertySliderScale(minimum: 0, maximum: 1, step: 0.1))
        XCTAssertEqual(scale.nativeStep, 0.1)
        XCTAssertEqual(scale.editedValue(0.74), 0.7, accuracy: 0.000_000_001)
    }

    func testInvalidStepsRemainContinuousAndInvalidRangesAreRejected() throws {
        for step: Double? in [nil, 0, -1, .nan, .infinity] {
            let scale = try XCTUnwrap(ScenePropertySliderScale(minimum: -1, maximum: 1, step: step))
            XCTAssertNil(scale.nativeStep)
            XCTAssertEqual(scale.editedValue(0.123456), 0.123456)
            XCTAssertEqual(scale.editedValue(.nan), -1)
        }
        XCTAssertNil(ScenePropertySliderScale(minimum: 1, maximum: 1, step: 1))
        XCTAssertNil(ScenePropertySliderScale(minimum: .nan, maximum: 1, step: 1))
        XCTAssertNil(ScenePropertySliderScale(minimum: -Double.greatestFiniteMagnitude,
                                              maximum: Double.greatestFiniteMagnitude, step: 1))
        let tiny = try XCTUnwrap(ScenePropertySliderScale(minimum: 0, maximum: 300, step: .leastNonzeroMagnitude))
        XCTAssertNil(tiny.nativeStep)
        XCTAssertEqual(tiny.editedValue(150), 150)
    }

    /// The regression was hundreds of MB of AttributeGraph stops, even without loading a scene renderer.
    @MainActor func testManyFineSlidersRenderAndEditWithoutExpandingLayoutMemory() async throws {
        // A cold test process first pays one-time SwiftUI / AppKit / font setup (about 140 MB here when this
        // test runs alone). Pay it with the same 31 controls at an ordinary 10-stop precision, so the budget
        // below measures only what fine precision adds.
        try await warmUpSliderStack()
        let model = FineSlidersModel()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 570),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let before = LivePreviewDiagnostics.memoryFootprint()
        let started = ProcessInfo.processInfo.systemUptime
        let hosting = NSHostingView(rootView: FineSlidersView(model: model))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2,
                          "Constructing author property controls must leave the main thread responsive")
        for index in 0..<10 {
            model.values[index] = 45.726 + Double(index) * 0.001
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let after = LivePreviewDiagnostics.memoryFootprint()
        let growth = after > before ? after - before : 0
        XCTAssertLessThan(growth, 128 * 1_048_576,
                          "Fine precision must not allocate a UI element for each possible value")
        XCTAssertEqual(model.values[9], 45.735, accuracy: 0.000_000_001)
    }

    @MainActor private func warmUpSliderStack() async throws {
        let model = FineSlidersModel()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 570),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let coarse = try XCTUnwrap(ScenePropertySliderScale(minimum: 0, maximum: 1, step: 0.1))
        XCTAssertEqual(coarse.nativeStep, 0.1)
        let hosting = NSHostingView(rootView: FineSlidersView(model: model, scale: coarse))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        model.values[0] = 0.5
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor private final class FineSlidersModel: ObservableObject {
    @Published var values = Array(repeating: 45.726, count: 31)
}

@MainActor private struct FineSlidersView: View {
    @ObservedObject var model: FineSlidersModel
    var scale = ScenePropertySliderScale(minimum: 0, maximum: 300, step: 0.001)!
    var body: some View {
        ScrollView {
            VStack {
                ForEach(model.values.indices, id: \.self) { index in
                    ScenePropertySlider(title: "作者参数 \(index)", scale: scale,
                        value: Binding(get: { model.values[index] }, set: { model.values[index] = $0 }))
                }
            }.padding(24)
        }
    }
}
