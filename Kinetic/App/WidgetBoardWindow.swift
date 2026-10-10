import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WidgetBoardWindow: NSObject, NSWindowDelegate {
    let model: WidgetBoardEditorModel
    private(set) var window: NSWindow?
    init(model: WidgetBoardEditorModel) { self.model = model }
    @discardableResult func show(activate: Bool = true) -> NSWindow {
        if let window { window.makeKeyAndOrderFront(nil); return window }
        // The layout preview moved onto the display page (user, 2026-10-08), so only the settings column remains.
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 330, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("widgets.title", comment: ""); window.identifier = .init("Kinetic.WidgetBoard")
        window.isReleasedWhenClosed = false; window.minSize = .init(width: 330, height: 480)
        OverlaySettingsWindowChrome.apply(to: window)
        window.contentView = NSHostingView(rootView: OverlaySettingsWindowContent(title: window.title) {
            WidgetBoardEditorView(model: model,
                onImport: { [weak self] in self?.importLayout() }, onExport: { [weak self] in self?.exportLayout() })
        }.environment(\.locale, Locale(identifier: "zh-Hans")))
        window.delegate = self; self.window = window; model.opened(); window.center(); window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }; return window
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        model.closed(); window?.delegate = nil; window?.contentView = nil; window = nil
    }
    func close() { model.closed(); window?.close() }
    private func importLayout() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = NSLocalizedString("widgets.import.message", comment: "")
        panel.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self, let window, self.window === window, response == .OK, let file = panel.url else { return }
            let scoped = file.startAccessingSecurityScopedResource(); defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            do {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= WidgetBoardLayout.maximumBytes else { throw WidgetBoardError.invalidLayout }
                self.model.importLayout(try Data(contentsOf: file))
            } catch { self.model.reportFileError() }
        }
    }
    private func exportLayout() {
        guard let window else { return }
        do {
            let data = try model.exportLayout()
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Kinetic-Widget-Layout.json"
            panel.beginSheetModal(for: window) { [weak self, weak window] response in
                guard let self, let window, self.window === window, response == .OK, let file = panel.url else { return }
                let scoped = file.startAccessingSecurityScopedResource(); defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                do { try data.write(to: file, options: .atomic) } catch { self.model.reportFileError() }
            }
        } catch { model.reportFileError() }
    }
}

@MainActor
struct WidgetBoardEditorView: View {
    @ObservedObject var model: WidgetBoardEditorModel
    let onImport: () -> Void
    let onExport: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("widgets.display", selection: Binding(get: { model.selectedDisplayID }, set: { model.selectDisplay($0) })) {
                    if model.selectedDisplayID == nil { Text("particles.noDisplay").tag(Optional<DisplayID>.none) }
                    ForEach(model.connectedDisplays) { Text($0.name).tag(Optional($0.id)) }
                    if let id = model.selectedDisplayID, !model.connectedDisplays.contains(where: { $0.id == id }) {
                        Text("particles.disconnected").tag(Optional(id))
                    }
                }
                Toggle("widgets.enabled", isOn: Binding(get: { model.isEnabled }, set: { model.isEnabled = $0 }))
                Menu {
                    ForEach(WidgetKind.allCases) { kind in Button { model.add(kind) } label: { Label(kind.title, systemImage: kind.symbol) } }
                } label: { Label("widgets.add", systemImage: "plus").foregroundStyle(.primary) }
                    .kineticGlassButton().disabled(model.layout.widgets.count >= WidgetBoardLayout.maximumWidgets || !model.canSave
                                                   || !(model.selectedDisplayID.map(model.hasRoom(on:)) ?? false))
                if model.layout.widgets.isEmpty { Text("widgets.empty").font(.caption).foregroundStyle(.secondary) }
                else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.layout.widgets) { widget in
                            Button { model.selectWidget(widget.id) } label: {
                                HStack {
                                    Label(widget.title, systemImage: widget.kind.symbol).lineLimit(1)
                                    Spacer()
                                    if model.selectedWidgetID == widget.id { Image(systemName: "checkmark") }
                                }.foregroundStyle(.primary).padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if model.selectedWidget != nil { Divider(); widgetSettings }
                Divider()
                Button { model.save() } label: { Text("widgets.save").foregroundStyle(.primary) }
                    .kineticGlassButton().disabled(!model.canSave)
                HStack {
                    Button(action: onImport) { Text("widgets.import").foregroundStyle(.primary) }.kineticGlassButton()
                    Button(action: onExport) { Text("widgets.export").foregroundStyle(.primary) }.kineticGlassButton()
                }
                if let error = model.error ?? model.manager.store.loadError { Text(error).font(.caption).foregroundStyle(.red) }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if let state = model.state, let failure = state.failure {
                    Text(failure).font(.caption).foregroundStyle(.secondary)
                    Button { model.retry() } label: { Text("particles.retry").foregroundStyle(.primary) }.kineticGlassButton()
                }
                Text("widgets.sources.detail").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }.background { WindowGlassBackground(style: .sidebar).ignoresSafeArea() }
    }
    private var widgetSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("widgets.settings").font(.headline)
            TextField("widgets.customTitle", text: binding(\.customTitle, fallback: ""))
            Picker("widgets.size", selection: binding(\.size, fallback: .small)) {
                ForEach(WidgetSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            slider("widgets.opacity", value: binding(\.opacity, fallback: 1), range: 0.25...1)
            Toggle("widgets.showsTitle", isOn: binding(\.showsTitle, fallback: true))
            Button(role: .destructive) { model.removeSelected() } label: { Text("widgets.remove") }.kineticGlassButton()
        }
    }
    private func binding<T>(_ path: WritableKeyPath<WidgetConfiguration, T>, fallback: T) -> Binding<T> {
        Binding(get: { model.selectedWidget?[keyPath: path] ?? fallback }, set: { value in model.editSelected { $0[keyPath: path] = value } })
    }
    private func slider(_ key: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(key); Spacer(); Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range).accessibilityLabel(key)
        }
    }
}
