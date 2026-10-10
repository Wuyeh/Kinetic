import SwiftUI

enum NumericParameterEntry {
    static func value(from text: String, range: ClosedRange<Double>, step: Double? = nil,
                      locale: Locale = .current) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 64 else { return nil }
        // Accept both the system decimal separator and the conventional decimal dot.
        let normalized = locale.decimalSeparator == "," ? text.replacingOccurrences(of: ",", with: ".") : text
        guard let number = Double(normalized), number.isFinite,
              let scale = ScenePropertySliderScale(minimum: range.lowerBound, maximum: range.upperBound, step: step)
        else { return nil }
        return scale.editedValue(number)
    }
}

/// Manual entry edits the same staged binding as the slider; it never saves or applies.
struct NumericParameterValue: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var suffix = ""
    var precision = 2
    var isEditable = false
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .frame(width: 88).focused($focused)
                    .onSubmit { finish(commit: true) }
                    .onExitCommand { finish(commit: false) }
                    .onAppear { focused = true }
                    .onChange(of: focused) { if !$0 && editing { finish(commit: true) } }
            } else if isEditable {
                label.contentShape(Rectangle())
                    .onTapGesture(count: 2) { begin() }
                    .help("双击数字以手动输入；Return确认，Escape取消")
                    .accessibilityLabel(title + "，" + formatted)
                    .accessibilityAction(named: Text("手动输入")) { begin() }
            } else { label }
        }.monospacedDigit()
    }
    private var formatted: String { value.formatted(.number.precision(.fractionLength(0...precision))) + suffix }
    private var label: some View { Text(formatted).foregroundStyle(.secondary) }
    private func begin() {
        text = value.formatted(.number.grouping(.never).precision(.fractionLength(0...12)))
        editing = true
    }
    private func finish(commit: Bool) {
        guard editing else { return }
        if commit, let number = NumericParameterEntry.value(from: text, range: range, step: step) { value = number }
        editing = false; focused = false
    }
}
