import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

final class WallpaperGridLayoutTests: XCTestCase {
    func testEveryPointOfWidthChangeIsSharedContinuouslyWithinEachStage() {
        for (start, end, columns) in [(615.0, 793.0, 3), (794.0, 1065.0, 4)] {
            var previous = WallpaperGridMetrics(availableWidth: start)
            for width in stride(from: start + 0.5, through: end, by: 0.5) {
                let next = WallpaperGridMetrics(availableWidth: width)
                XCTAssertEqual(next.columnCount, columns)
                XCTAssertEqual(next.cardWidth - previous.cardWidth, 0.5 / Double(columns), accuracy: 0.000001)
                previous = next
            }
        }
    }

    func testExplicitBreakpointChangesColumnsExactlyOnceInEitherDirection() {
        let breakpoint = MainWindowDesignTokens.Grid.threeToFourColumnBreakpoint
        let widths = Array(stride(from: 615.0, through: 1065.0, by: 0.5))
        for sweep in [widths, Array(widths.reversed())] {
            var previous = WallpaperGridMetrics(availableWidth: sweep[0])
            var transitions = 0
            for width in sweep.dropFirst() {
                let next = WallpaperGridMetrics(availableWidth: width)
                XCTAssertEqual(next.columnCount, width < breakpoint ? 3 : 4)
                if next.columnCount != previous.columnCount { transitions += 1 }
                previous = next
            }
            XCTAssertEqual(transitions, 1)
        }
        XCTAssertEqual(WallpaperGridMetrics(availableWidth: breakpoint - 0.001).cardWidth, 250, accuracy: 0.001)
        XCTAssertEqual(WallpaperGridMetrics(availableWidth: breakpoint).cardWidth, 182)
    }

    func testCardBoundsAndNoHorizontalOverflowAcrossWindowResizeSweep() {
        for width in stride(from: 0.0, through: 2400.0, by: 0.5) {
            let metrics = WallpaperGridMetrics(availableWidth: width)
            XCTAssertGreaterThanOrEqual(metrics.cardWidth, min(width, 180))
            XCTAssertLessThanOrEqual(metrics.cardWidth, 250)
            let totalWidth = Double(metrics.columnCount) * metrics.cardWidth + Double(metrics.columnCount - 1) * 22
            XCTAssertLessThanOrEqual(totalWidth, width + 0.000001)
        }
    }

    @MainActor
    func testColumnChangeAnimatesThumbnailSizeThroughIntermediateWidths() async {
        var widths: [CGFloat] = []
        let host = NSHostingView(rootView: GridGeometryFixture { index, frame in
            if index == 0 { widths.append(frame.width) }
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 794, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)
        widths.removeAll()
        window.setContentSize(NSSize(width: 793, height: 600))
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        print("Grid transition measured widths: \(widths)")
        XCTAssertTrue(widths.contains { $0 > 191 && $0 < 249 }, "Column changes must animate thumbnail geometry")
    }

    @MainActor
    func testRenderedThumbnailsResizeProportionallyAndReflowOnlyAtColumnBoundary() async {
        var frames: [Int: CGRect] = [:]
        let host = NSHostingView(rootView: GridGeometryFixture { frames[$0] = $1 })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        let cases: [(CGFloat, Int, CGFloat)] = [
            (615, 3, 571.0 / 3), (650, 3, 202), (700, 3, 656.0 / 3),
            (740, 3, 232), (780, 3, 736.0 / 3), (793, 3, 749.0 / 3),
            (794, 4, 182), (820, 4, 188.5), (900, 4, 208.5),
            (940, 4, 218.5), (1000, 4, 233.5), (1065, 4, 249.75),
            (1066, 5, 195.6)
        ]
        for (width, columns, expectedCardWidth) in cases {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 250_000_000)
            host.layoutSubtreeIfNeeded()
            guard let first = frames[0] else {
                XCTFail("No rendered thumbnail geometry at width \(width)")
                return
            }
            print("Rendered grid: width=\(width), columns=\(columns), thumbnail=\(first.width)×\(first.height)")
            XCTAssertEqual(first.width, expectedCardWidth, accuracy: 0.5)
            XCTAssertEqual(first.width / first.height, 1.6, accuracy: 0.01)
            let firstRow = frames.values.filter { abs($0.minY - first.minY) < 0.5 }
            XCTAssertEqual(firstRow.count, columns, "Rendered column count at width \(width)")
            XCTAssertTrue(firstRow.allSatisfy { $0.maxX <= width + 0.5 })
        }
    }
}

private struct GridGeometryFixture: View {
    let report: (Int, CGRect) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                ResponsiveWallpaperGrid(availableWidth: geometry.size.width) {
                    ForEach(0..<12) { index in
                        Color.gray
                            .aspectRatio(MainWindowDesignTokens.Grid.previewAspectRatio, contentMode: .fit)
                            .overlay(GridGeometryProbe { report(index, $0) })
                    }
                }
            }
        }
    }
}

private struct GridGeometryProbe: NSViewRepresentable {
    let report: (CGRect) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView(report: report) }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.needsLayout = true }

    final class ProbeView: NSView {
        let report: (CGRect) -> Void

        init(report: @escaping (CGRect) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            report(convert(bounds, to: nil))
        }
    }
}
