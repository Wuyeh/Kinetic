import SwiftUI

/// Keep authored precision in the binding, without asking SwiftUI to build hundreds of thousands of stops.
struct ScenePropertySliderScale {
    static let maximumNativeIntervals: Double = 100
    let range: ClosedRange<Double>
    let step: Double?

    init?(minimum: Double, maximum: Double, step: Double?) {
        guard minimum.isFinite, maximum.isFinite, minimum < maximum,
              (maximum - minimum).isFinite else { return nil }
        range = minimum...maximum
        self.step = step.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    var nativeStep: Double? {
        guard let step, (range.upperBound - range.lowerBound) / step <= Self.maximumNativeIntervals else { return nil }
        return step
    }

    func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    func editedValue(_ value: Double) -> Double {
        let bounded = clamped(value)
        guard let step else { return bounded }
        let intervals = (bounded - range.lowerBound) / step
        guard intervals.isFinite else { return bounded }
        return clamped(range.lowerBound + intervals.rounded() * step)
    }
}

@MainActor
struct ScenePropertySlider: View {
    let title: String
    let scale: ScenePropertySliderScale
    @Binding var value: Double

    private var editingValue: Binding<Double> {
        Binding(get: { scale.clamped(value) }, set: { value = scale.editedValue($0) })
    }

    var body: some View {
        Group {
            if let step = scale.nativeStep {
                Slider(value: editingValue, in: scale.range, step: step)
            } else {
                Slider(value: editingValue, in: scale.range)
            }
        }.accessibilityLabel(title)
    }
}
