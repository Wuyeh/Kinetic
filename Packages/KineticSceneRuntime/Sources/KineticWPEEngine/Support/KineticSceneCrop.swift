import CoreGraphics

/// Kinetic: a user-chosen part of the scene canvas shown on the view (显示器 › 显示方式 › 自定义).
/// `zoom` 1 is the canvas just covering the view; the centre is in canvas units (0…1, top-left origin).
/// The region always lies inside the canvas, so the view is always filled.
public struct KineticSceneCrop: Equatable, Sendable {
    public static let maximumZoom: Double = 5
    public var zoom: Double
    public var centerX: Double
    public var centerY: Double

    public init(zoom: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5) {
        self.zoom = zoom; self.centerX = centerX; self.centerY = centerY
    }

    /// The visible part of a `source`-shaped canvas on a `target`-shaped view, normalised (0…1, top-left origin).
    /// Degenerate sizes show the whole canvas.
    public func region(source: CGSize, target: CGSize) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard [source.width, source.height, target.width, target.height].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return whole
        }
        let sourceAspect = Double(source.width / source.height), targetAspect = Double(target.width / target.height)
        let scale = min(Self.maximumZoom, max(1, zoom.isFinite ? zoom : 1))
        var width = 1.0, height = 1.0
        if sourceAspect > targetAspect { width = targetAspect / sourceAspect } else { height = sourceAspect / targetAspect }
        width /= scale; height /= scale
        func origin(_ center: Double, _ extent: Double) -> Double {
            let value = center.isFinite ? center : 0.5
            return min(1 - extent / 2, max(extent / 2, value)) - extent / 2
        }
        return CGRect(x: origin(centerX, width), y: origin(centerY, height), width: width, height: height)
    }
}
