import AppKit
import SwiftUI

@MainActor final class MusicSettingsWindow: NSObject, NSWindowDelegate {
    let model: MusicOverlayEditorModel
    private(set) var window: NSWindow?
    init(model: MusicOverlayEditorModel) { self.model = model }
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        model.opened()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 370, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("music.title", comment: ""); window.identifier = .init("Kinetic.MusicSettings")
        window.isReleasedWhenClosed = false; window.minSize = .init(width: 370, height: 500)
        OverlaySettingsWindowChrome.apply(to: window)
        window.contentView = NSHostingView(rootView: OverlaySettingsWindowContent(title: window.title) {
            MusicSettingsView(model: model, service: model.service, registry: model.registry)
        }.environment(\.locale, Locale(identifier: "zh-Hans")))
        window.delegate = self; self.window = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil; window?.contentView = nil; window = nil
    }
}

@MainActor struct MusicSettingsView: View {
    @ObservedObject var model: MusicOverlayEditorModel
    @ObservedObject var service: MusicService
    @ObservedObject var registry: DisplayRegistry
    @State private var lease: MusicSubscription?
    @State private var authorizing = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("music.display", selection: Binding(get: { model.selectedDisplayID }, set: { model.selectDisplay($0) })) {
                    if model.selectedDisplayID == nil { Text("clock.noDisplay").tag(Optional<DisplayID>.none) }
                    ForEach(model.connectedDisplays) { Text($0.name).tag(Optional($0.id)) }
                    if let id = model.selectedDisplayID, !model.connectedDisplays.contains(where: { $0.id == id }) {
                        Text("clock.disconnected").tag(Optional(id))
                    }
                }
                Toggle("music.enabled", isOn: $model.isEnabled)
                Picker("music.source", selection: $model.options.source) {
                    ForEach(MusicSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("music.permission.detail").font(.caption).foregroundStyle(.secondary)
                Button("music.connect") {
                    let source = model.options.source; authorizing = true
                    Task {
                        _ = await service.authorize(source)
                        authorizing = false
                    }
                }.kineticGlassButton().disabled(authorizing)
                Text(service.snapshots[model.options.source]?.availability.message ?? MusicAvailability.inactive.message)
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    control(.previous, symbol: "backward.end.fill", key: "music.previous")
                    control(.playPause, symbol: service.snapshots[model.options.source]?.isPlaying == true ? "pause.fill" : "play.fill", key: "music.playPause")
                    control(.next, symbol: "forward.end.fill", key: "music.next")
                }.disabled(service.snapshots[model.options.source]?.availability != .live)
                Picker("music.layout", selection: $model.options.layout) {
                    ForEach(MusicLayout.allCases, id: \.self) { Text(LocalizedStringKey("music.layout." + $0.rawValue)).tag($0) }
                }
                slider("clock.size", value: $model.options.scale, range: 0.6...2)
                slider("clock.opacity", value: $model.options.opacity, range: 0.2...1)
                Text("music.drag").font(.caption).foregroundStyle(.secondary)
                Divider()
                Picker("lyrics.mode", selection: $model.options.lyrics) {
                    ForEach(LyricsMode.allCases, id: \.self) { Text(LocalizedStringKey("lyrics.mode." + $0.rawValue)).tag($0) }
                }
                Text("lyrics.privacy").font(.caption).foregroundStyle(.secondary)
                if model.options.lyrics != .off {
                    slider("lyrics.size", value: $model.options.lyricsScale, range: 0.6...2)
                    Text(LocalizedStringKey("lyrics.status." + (service.lyrics[model.options.source]?.status.rawValue ?? "off")))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("lyrics.retry") { service.retryLyrics(model.options.source) }.kineticGlassButton()
                    if let text = service.lyrics[model.options.source]?.value?.plain, !text.isEmpty {
                        ScrollView { Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 150)
                    }
                }
                HStack {
                    Button("clock.save") { model.save() }.kineticGlassButton().disabled(!model.canSave)
                    Button("clock.defaults") { model.defaults() }.kineticGlassButton()
                }
                if let failure = model.state?.failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                    Button("clock.retry") { model.retry() }.kineticGlassButton()
                }
                if let error = model.error ?? service.controlError ?? model.manager.store.loadError { Text(error).font(.caption).foregroundStyle(.red) }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }.padding(24)
        }
        .background { WindowGlassBackground(style: .sidebar).ignoresSafeArea() }
        .onAppear { lease = service.subscribe(source: model.options.source, lyrics: model.options.lyrics != .off, visible: true) }
        .onChange(of: model.options.source) { _ in updateLease() }
        .onChange(of: model.options.lyrics) { _ in updateLease() }
        .onDisappear { lease?.cancel(); lease = nil }
    }
    private func updateLease() { lease?.update(visible: true, source: model.options.source, lyrics: model.options.lyrics != .off) }
    private func control(_ action: MusicControl, symbol: String, key: String) -> some View {
        Button { let source = model.options.source; Task { await service.control(action, source: source) } } label: { Image(systemName: symbol) }
            .kineticGlassButton().help(Text(LocalizedStringKey(key))).accessibilityLabel(Text(LocalizedStringKey(key)))
    }
    private func slider(_ key: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(key); Spacer(); Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range).accessibilityLabel(key)
        }
    }
}
