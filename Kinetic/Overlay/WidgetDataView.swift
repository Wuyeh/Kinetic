import AppKit
import SwiftUI

/// Presentation only; no timers, samplers, location or wallpaper commands.
struct WidgetDataRow: Equatable, Identifiable {
    let key: String
    let value: String
    /// A literal label (for example a project name) rather than a localization key.
    var isLiteralKey = false
    var id: String { key }
}

struct WidgetDataPresentation: Equatable {
    var caption: String
    var value: String
    var symbol: String? = nil
    var fraction: Double? = nil
    var rows: [WidgetDataRow] = []
    var note = ""
    var isUnavailable = false
}

enum WidgetDataFormat {
    static func text(_ key: String) -> String { NSLocalizedString(key, comment: "") }
    static func number(_ value: Double, decimals: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...decimals)))
    }
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var amount = Double(value), index = 0
        while amount >= 1_024 && index < units.count - 1 { amount /= 1_024; index += 1 }
        return number(amount, decimals: index == 0 ? 0 : 1) + " " + units[index]
    }
    static func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(UInt64.max) else { return text("widgetData.unavailable") }
        return bytes(UInt64(value.rounded(.down))) + "/s"
    }
    static func unavailable(_ reason: SystemMetricUnavailable, note: String = "") -> WidgetDataPresentation {
        .init(caption: text("widgetData.status." + reason.rawValue), value: text("widgetData.unavailable"),
              note: note, isUnavailable: true)
    }
}

@MainActor
final class WidgetDataViewState: ObservableObject {
    @Published var configuration: WidgetConfiguration
    @Published var drawingScale = 1.0
    @Published var presentation: WidgetDataPresentation
    init(configuration: WidgetConfiguration, presentation: WidgetDataPresentation) {
        self.configuration = configuration; self.presentation = presentation
    }
    func update(configuration: WidgetConfiguration, context: OverlayContext) {
        self.configuration = configuration
        drawingScale = context.frame.width / configuration.size.dimensions.width
    }
}

@MainActor
struct WidgetDataView: View {
    @ObservedObject var state: WidgetDataViewState
    private var data: WidgetDataPresentation { state.presentation }
    private var scale: Double { state.drawingScale }
    private var rowLimit: Int { state.configuration.size == .small ? 1 : state.configuration.size == .medium ? 2 : 10 }

    var body: some View {
        Group {
            if state.configuration.size == .medium && !data.isUnavailable {
                HStack(alignment: .top, spacing: 12 * scale) {
                    primary.frame(maxWidth: .infinity, alignment: .leading)
                    details.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 5 * scale) { primary; details }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
    private var primary: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text(data.caption).font(.system(size: 11 * scale)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6 * scale) {
                if let symbol = data.symbol {
                    Image(systemName: symbol).font(.system(size: 23 * scale, weight: .regular)).foregroundStyle(.secondary)
                }
                Text(data.value).font(.system(size: (data.isUnavailable ? 24 : 30) * scale, weight: .medium))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            }
            if let fraction = data.fraction {
                ProgressView(value: max(0, min(1, fraction))).progressViewStyle(.linear)
                    .tint(MainWindowDesignTokens.accent).scaleEffect(y: scale, anchor: .center)
                    .accessibilityLabel(Text(data.caption))
            }
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            ForEach(Array(data.rows.prefix(rowLimit))) { row in
                HStack(spacing: 4 * scale) {
                    Text(row.isLiteralKey ? row.key : WidgetDataFormat.text(row.key)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(row.value).monospacedDigit().lineLimit(1)
                }.font(.system(size: 11 * scale))
            }
            if !data.note.isEmpty {
                Text(data.note).font(.system(size: 10 * scale)).foregroundStyle(.secondary)
                    .lineLimit(state.configuration.size == .large ? 3 : 2)
            }
        }
    }
}
