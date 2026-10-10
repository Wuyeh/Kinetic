import AppKit
import KineticSceneRuntime
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ScenePropertiesSection: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var store: ScenePropertyStore
    @ObservedObject var runtime: WallpaperRuntimeManager
    @State private var wallpaperID: Wallpaper.ID?

    private var scenes: [Wallpaper] { library.wallpapers.filter { $0.type == .scene } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("场景属性与预设").font(.headline)
            if scenes.isEmpty {
                Text("导入场景壁纸后，可以在这里调整作者提供的属性。").foregroundStyle(.secondary)
            } else {
                Picker("场景壁纸", selection: $wallpaperID) {
                    ForEach(scenes) { Text($0.name).tag(Optional($0.id)) }
                }
                if let wallpaper = scenes.first(where: { $0.id == wallpaperID }) {
                    ScenePropertiesEditor(wallpaper: wallpaper, store: store, runtime: runtime).id(wallpaper.id)
                }
            }
        }
        .onAppear { selectInitialWallpaper() }
        .onChange(of: scenes.map(\.id)) { _ in selectInitialWallpaper() }
    }
    private func selectInitialWallpaper() {
        guard !scenes.contains(where: { $0.id == wallpaperID }) else { return }
        wallpaperID = scenes.first(where: { $0.id == runtime.activeWallpaper?.id })?.id ?? scenes.first?.id
    }
}

/// A draft is separate from saved settings. Selecting a preset or dragging a slider does not restart playback.
@MainActor
struct ScenePropertiesEditor: View {
    let wallpaper: Wallpaper
    @ObservedObject var store: ScenePropertyStore
    @ObservedObject var runtime: WallpaperRuntimeManager
    var stagedValues: Binding<[String: ScenePropertyValue]>? = nil
    var onSchemaLoaded: (ScenePropertySchema) -> Void = { _ in }
    var allowsNumericEntry = false
    var showsRestoreButton = true
    var resetRequest: UUID? = nil
    @State private var schema: ScenePropertySchema?
    @State private var draft: [String: ScenePropertyValue] = [:]
    @State private var presetID: UUID?
    @State private var error: String?
    @State private var status: String?
    @State private var naming = false
    @State private var renaming = false
    @State private var presetName = ""

    private var presets: [LocalScenePreset] { store.configuration(for: wallpaper.id).presets }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let schema {
                if !schema.hasEditableProperties {
                    Text("作者未提供可调整的场景属性。").foregroundStyle(.secondary)
                } else {
                    Picker("预设", selection: Binding(get: { presetID }, set: { id in
                        presetID = id
                        draft = presets.first(where: { $0.id == id })?.values ?? [:]
                        status = nil; error = nil
                    })) {
                        Text(presetID == nil && !draft.isEmpty ? "自定义设置" : "作者默认").tag(nil as UUID?)
                        ForEach(presets) { Text($0.name).tag(Optional($0.id)) }
                    }
                    actionRow {
                        Button("新建预设") { renaming = false; presetName = ""; naming = true }.kineticGlassButton()
                        Button("重命名") {
                            renaming = true; presetName = presets.first(where: { $0.id == presetID })?.name ?? ""; naming = true
                        }.kineticGlassButton().disabled(presetID == nil)
                        Button("删除预设", role: .destructive) {
                            perform {
                                if let presetID { try store.deletePreset(presetID, for: wallpaper) }
                                self.presetID = nil
                            }
                        }.kineticGlassButton().disabled(presetID == nil)
                    }
                    ForEach(schema.visibleProperties(overrides: draft)) { property in
                        ScenePropertyControl(property: property, value: Binding(
                            get: { draft[property.key] ?? property.defaultValue },
                            set: { value in draft[property.key] = value; status = nil }
                        ), allowsNumericEntry: allowsNumericEntry)
                    }
                    actionRow {
                        if stagedValues == nil {
                        Button("保存并应用") {
                            perform {
                                try store.save(values: draft, for: wallpaper, schema: schema, runtime: runtime)
                                status = "已保存。正在使用此场景的显示器会重新加载；其他显示器保持不变。"
                            }
                        }.kineticGlassButton().disabled(store.loadError != nil)
                        }
                        if showsRestoreButton {
                            Button("恢复作者默认") { draft = [:]; presetID = nil; status = nil; error = nil }.kineticGlassButton()
                        }
                        if stagedValues == nil { Spacer() }
                        Button("导入预设") { importPreset(schema) }.kineticGlassButton()
                        Button("导出预设") { exportPreset(schema) }.kineticGlassButton()
                    }
                    Text(stagedValues == nil ? "修改后点击“保存并应用”。预设只保存属性，不改动素材文件；恢复默认也需要保存。" : "修改只作用于左侧预览；点击控制台的“应用”才更新这台显示器。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if error == nil { ProgressView() }
            if let loadError = store.loadError { Text(loadError).foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let failure = runtime.lastFailure, failure.wallpaperID == wallpaper.id {
                Text("场景更新失败，原画面已保留。\n" + failure.detail).foregroundStyle(.red).textSelection(.enabled)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .task {
            do {
                let root = wallpaper.resourceURL
                let loaded = try await Task.detached(priority: .userInitiated) { try ScenePropertySchema.read(root: root) }.value
                guard !Task.isCancelled else { return }
                schema = loaded
                onSchemaLoaded(loaded)
                do { draft = try loaded.validated(stagedValues?.wrappedValue ?? store.configuration(for: wallpaper.id).values) }
                catch { self.error = "已保存的属性与当前素材不兼容，请恢复作者默认后保存。\n" + error.localizedDescription }
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: draft) { value in
            guard let stagedValues, stagedValues.wrappedValue != value else { return }
            stagedValues.wrappedValue = value
        }
        .onChange(of: resetRequest) { _ in
            draft = [:]; presetID = nil; status = nil; error = nil
        }
        .onChange(of: stagedValues?.wrappedValue) { value in
            if let value, value != draft { draft = value }
        }
        .sheet(isPresented: $naming) {
            VStack(alignment: .leading, spacing: 16) {
                Text(renaming ? "重命名预设" : "新建预设").font(.headline)
                TextField("预设名称", text: $presetName)
                HStack {
                    Spacer()
                    Button("取消") { naming = false }.kineticGlassButton()
                    Button("保存") {
                        perform {
                            guard let schema else { return }
                            if renaming, let presetID { try store.renamePreset(presetID, name: presetName, for: wallpaper) }
                            else { presetID = try store.createPreset(name: presetName, values: draft, for: wallpaper, schema: schema) }
                            naming = false
                        }
                    }.kineticGlassButton().keyboardShortcut(.defaultAction)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(24).frame(width: 340)
        }
    }

    /// Keep the Settings row unchanged; the narrower display console can wrap
    /// the same controls vertically without duplicating any parameter actions.
    @ViewBuilder
    private func actionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if stagedValues == nil { HStack(content: content) }
        else {
            ViewThatFits(in: .horizontal) {
                HStack(content: content).fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8, content: content)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription; status = nil }
    }
    private func importPreset(_ schema: ScenePropertySchema) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "选择 Kinetic 预设或属于此场景的 Wallpaper Engine 预设 project.json。"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            perform {
                presetID = try store.importPreset(data: ScenePropertyStore.read(url, maximumBytes: ScenePropertyStore.maximumPresetBytes),
                    for: wallpaper, schema: schema)
                draft = presets.first(where: { $0.id == presetID })?.values ?? [:]
                status = "预设已导入。点击“保存并应用”使其生效。"
            }
        }
    }
    private func exportPreset(_ schema: ScenePropertySchema) {
        perform {
            let name = presets.first(where: { $0.id == presetID })?.name ?? "当前设置"
            let data = try ScenePropertyStore.exportPreset(name: name, values: draft, for: wallpaper, schema: schema)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Kinetic-Scene-Preset.json"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                perform { try data.write(to: url, options: .atomic); status = "预设已导出。" }
            }
        }
    }
}

@MainActor
private struct ScenePropertyControl: View {
    let property: SceneProperty
    @Binding var value: ScenePropertyValue?
    var allowsNumericEntry = false
    private var title: String { property.title.isEmpty ? property.key : property.title }
    @ViewBuilder var body: some View {
        switch property.kind {
        case "bool":
            Toggle(title, isOn: Binding(get: { value?.boolValue ?? (value?.numberValue == 1) }, set: { value = .bool($0) }))
        case "slider":
            let lower = property.minimum ?? 0, upper = property.maximum ?? 100
            if let scale = ScenePropertySliderScale(minimum: lower, maximum: upper, step: property.step) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title); Spacer()
                        if allowsNumericEntry {
                            NumericParameterValue(title: title, value: Binding(
                                get: { value?.numberValue ?? lower }, set: { value = .number($0) }),
                                range: scale.range, step: scale.step, precision: 3, isEditable: true)
                        } else {
                            Text((value?.numberValue ?? lower).formatted(.number.precision(.fractionLength(0...3))))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    ScenePropertySlider(title: title, scale: scale, value: Binding(
                        get: { value?.numberValue ?? lower }, set: { value = .number($0) }
                    ))
                }
            } else { unsupported }
        case "combo":
            if let first = property.options.first {
                Picker(title, selection: Binding(get: { value ?? first.value }, set: { value = $0 })) {
                    ForEach(Array(property.options.enumerated()), id: \.offset) { _, option in Text(option.title).tag(option.value) }
                }
            } else { unsupported }
        case "color":
            ColorPicker(title, selection: Binding(get: {
                let parts = (value?.stringValue ?? "1 1 1").split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
                return parts.count == 3 ? Color(red: parts[0], green: parts[1], blue: parts[2]) : .white
            }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                value = .string("\(rgb.redComponent) \(rgb.greenComponent) \(rgb.blueComponent)")
            }), supportsOpacity: false)
        case "textinput", "file", "directory":
            VStack(alignment: .leading, spacing: 4) {
                TextField(title, text: Binding(get: { value?.stringValue ?? "" }, set: { value = .string($0) }))
                if property.kind != "textinput" {
                    Text("仅支持素材包内的相对路径。").font(.caption).foregroundStyle(.secondary)
                }
            }
        case "group": Text(title).font(.headline)
        case "text": Text(title).foregroundStyle(.secondary)
        default: unsupported
        }
    }
    private var unsupported: some View {
        HStack { Text(title); Spacer(); Text("暂不支持此控件").font(.caption).foregroundStyle(.secondary) }
    }
}
