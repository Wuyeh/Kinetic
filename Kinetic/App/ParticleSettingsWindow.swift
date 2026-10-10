import AppKit
import SwiftUI

@MainActor
final class ParticleSettingsWindow: NSObject, NSWindowDelegate {
    let model: ParticleEditorModel
    private(set) var window: NSWindow?
    init(model: ParticleEditorModel) { self.model = model }
    @discardableResult func show(activate: Bool = true) -> NSWindow {
        if let window { window.makeKeyAndOrderFront(nil); return window }
        // The preview is on the display page (user, 2026-10-08); only the settings column remains.
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 340, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("particles.title", comment: "")
        window.identifier = .init("Kinetic.ParticleSettings"); window.isReleasedWhenClosed = false
        window.minSize = .init(width: 340, height: 440)
        OverlaySettingsWindowChrome.apply(to: window)
        window.contentView = NSHostingView(rootView: OverlaySettingsWindowContent(title: window.title) {
            ParticleSettingsView(model: model, manager: model.manager, registry: model.registry)
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
struct ParticleSettingsView: View {
    @ObservedObject var model: ParticleEditorModel
    @ObservedObject var manager: OverlayManager
    @ObservedObject var registry: DisplayRegistry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("particles.display", selection: Binding(get: { model.selectedDisplayID }, set: { model.selectDisplay($0) })) {
                    if model.selectedDisplayID == nil { Text("particles.noDisplay").tag(Optional<DisplayID>.none) }
                    ForEach(model.connectedDisplays) { Text($0.name).tag(Optional($0.id)) }
                    if let id = model.selectedDisplayID, !model.connectedDisplays.contains(where: { $0.id == id }) {
                        Text("particles.disconnected").tag(Optional(id))
                    }
                }
                Toggle("particles.enabled", isOn: $model.isEnabled)
                Picker("particles.preset", selection: $model.options.preset) {
                    ForEach(ParticlePreset.allCases) { Text($0.title).tag($0) }
                }
                slider("particles.density", value: $model.options.density, range: 0...1)
                slider("particles.intensity", value: $model.options.intensity, range: 0...1)
                slider("particles.wind", value: $model.options.wind, range: -1...1)
                Text("particles.wind.detail").font(.caption).foregroundStyle(.secondary)
                Toggle("particles.reduceMotion", isOn: $model.options.reduceMotion)
                Text("particles.reduceMotion.detail").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("particles.save") { model.save() }.kineticGlassButton().disabled(!model.canSave)
                    Button("particles.defaults") { model.restoreDefaults() }.kineticGlassButton()
                }
                if let state = model.state {
                    Text(LocalizedStringKey("particles.state.\(state.lifecycle.rawValue)")).font(.caption).foregroundStyle(.secondary)
                    if let failure = state.failure {
                        Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Button("particles.retry") { model.retry() }.kineticGlassButton()
                    }
                }
                if let message = model.error ?? manager.store.loadError { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                Text("particles.performance.detail").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(24)
        }
        .background { WindowGlassBackground(style: .sidebar).ignoresSafeArea() }
    }
    private func slider(_ key: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(key); Spacer(); Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range).accessibilityLabel(key)
        }
    }
}
