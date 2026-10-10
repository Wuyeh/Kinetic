import AppKit
import SwiftUI

@MainActor
final class NixieClockSettingsWindow: NSObject, NSWindowDelegate {
    let model: NixieClockEditorModel
    private(set) var window: NSWindow?
    init(model: NixieClockEditorModel) { self.model = model }
    @discardableResult func show(activate: Bool = true) -> NSWindow {
        if let window { window.makeKeyAndOrderFront(nil); return window }
        // The preview, and dragging the clock, are on the display page (user, 2026-10-08).
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 330, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("clock.title", comment: "")
        window.identifier = .init("Kinetic.NixieClockSettings"); window.isReleasedWhenClosed = false
        window.minSize = .init(width: 330, height: 440)
        OverlaySettingsWindowChrome.apply(to: window)
        window.contentView = NSHostingView(rootView: OverlaySettingsWindowContent(title: window.title) {
            NixieClockSettingsView(model: model, manager: model.manager, registry: model.registry)
        }.environment(\.locale, Locale(identifier: "zh-Hans")))
        window.delegate = self; self.window = window; model.opened(); window.center(); window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }
        return window
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        model.closed(); window?.delegate = nil; window?.contentView = nil; window = nil
    }
    func close() { window?.close(); model.closed() }
}

@MainActor
struct NixieClockSettingsView: View {
    @ObservedObject var model: NixieClockEditorModel
    @ObservedObject var manager: OverlayManager
    @ObservedObject var registry: DisplayRegistry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("clock.display", selection: Binding(get: { model.selectedDisplayID }, set: { model.selectDisplay($0) })) {
                    if model.selectedDisplayID == nil { Text("clock.noDisplay").tag(Optional<DisplayID>.none) }
                    ForEach(model.connectedDisplays) { Text($0.name).tag(Optional($0.id)) }
                    if let id = model.selectedDisplayID, !model.connectedDisplays.contains(where: { $0.id == id }) {
                        Text("clock.disconnected").tag(Optional(id))
                    }
                }
                Toggle("clock.enabled", isOn: $model.isEnabled)
                Divider()
                Picker("clock.hourFormat", selection: $model.options.uses24Hour) {
                    Text("clock.24h").tag(true); Text("clock.12h").tag(false)
                }.pickerStyle(.segmented)
                Toggle("clock.leadingZero", isOn: $model.options.leadingZero)
                Toggle("clock.blink", isOn: $model.options.blinksSeparator)
                Toggle("clock.transparent", isOn: $model.options.transparentBackground)
                slider("clock.opacity", value: $model.options.opacity, range: NixieClockOptions.opacityRange, percent: true)
                slider("clock.size", value: $model.options.scale, range: NixieClockOptions.scaleRange, percent: false)
                HStack {
                    Button("clock.save") { model.save() }.kineticGlassButton().disabled(!model.canSave)
                    Button("clock.defaults") { model.restoreDefaults() }.kineticGlassButton()
                }
                if let state = model.state {
                    Text(LocalizedStringKey("clock.state.\(state.lifecycle.rawValue)")).font(.caption).foregroundStyle(.secondary)
                    if let failure = state.failure {
                        Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Button("clock.retry") { model.retry() }.kineticGlassButton()
                    }
                }
                if let message = model.error ?? manager.store.loadError { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(24)
        }
        .background { WindowGlassBackground(style: .sidebar).ignoresSafeArea() }
    }

    private func slider(_ key: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, percent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(key); Spacer()
                Text(percent ? value.wrappedValue.formatted(.percent.precision(.fractionLength(0)))
                             : value.wrappedValue.formatted(.number.precision(.fractionLength(2))) + "×")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).accessibilityLabel(key)
        }
    }
}
