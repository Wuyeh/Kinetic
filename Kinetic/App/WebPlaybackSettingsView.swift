import SwiftUI

@MainActor
struct WebPlaybackSettingsSection: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var store: WebPlaybackStore
    @ObservedObject var runtime: WallpaperRuntimeManager
    let allowsNetwork: Bool
    @StateObject private var preview = WebPlaybackPreview()
    @State private var wallpaperID: Wallpaper.ID?
    @State private var ownerID = UUID()
    private var pages: [Wallpaper] { library.wallpapers.filter { $0.type == .web } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("高级网页").font(.headline)
            if pages.isEmpty { Text("导入网页壁纸后，可以在这里调整脚本、样式和画面。").foregroundStyle(.secondary) }
            else {
                Picker("网页壁纸", selection: $wallpaperID) {
                    ForEach(pages) { Text($0.name).tag(Optional($0.id)) }
                }
                if let wallpaper = pages.first(where: { $0.id == wallpaperID }) {
                    WebPlaybackPreviewView(preview: preview).frame(maxWidth: 420)
                    WebPlaybackSettingsEditor(wallpaper: wallpaper, store: store, runtime: runtime,
                                              allowsNetwork: allowsNetwork, preview: preview, ownerID: ownerID)
                        .id(wallpaper.id)
                }
            }
        }
        .onAppear { selectInitial() }
        .onChange(of: pages.map(\.id)) { _ in selectInitial() }
        .onDisappear { preview.stop(ownerID: ownerID) }
    }
    private func selectInitial() {
        guard !pages.contains(where: { $0.id == wallpaperID }) else { return }
        wallpaperID = pages.first(where: { $0.id == runtime.activeWallpaper?.id })?.id ?? pages.first?.id
        if wallpaperID == nil { preview.stop(ownerID: ownerID) }
    }
}

@MainActor
struct WebPlaybackSettingsEditor: View {
    let wallpaper: Wallpaper
    @ObservedObject var store: WebPlaybackStore
    @ObservedObject var runtime: WallpaperRuntimeManager
    let allowsNetwork: Bool
    let preview: WebPlaybackPreview
    let ownerID: UUID
    @State private var draft = WebPlaybackOptions()
    @State private var error: String?
    @State private var status: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WebPlaybackControls(draft: $draft)
            HStack {
                Button {
                    do { try store.save(draft, for: wallpaper, runtime: runtime); error = nil; status = "已保存，正在使用此网页的屏幕会更新。" }
                    catch { self.error = error.localizedDescription; status = nil }
                } label: { Text("保存并应用").foregroundStyle(.primary) }
                    .kineticGlassButton().disabled(store.loadError != nil)
                Button { draft = .init(); error = nil; status = nil }
                    label: { Text("恢复默认").foregroundStyle(.primary) }.kineticGlassButton()
                Button { updatePreview(force: true) }
                    label: { Text("刷新预览").foregroundStyle(.primary) }.kineticGlassButton()
            }
            Button { store.refresh(wallpaper, runtime: runtime) }
                label: { Text("刷新屏幕上的网页").foregroundStyle(.primary) }.kineticGlassButton()
                .disabled(!runtime.displayIDs.contains { runtime.activeWallpaper(on: $0)?.id == wallpaper.id })
            Text("脚本开关和拦截规则改变时需要重新加载；缩放、位置、旋转与 CSS 保持当前页面。恢复默认也需要保存。刷新屏幕使用已保存设置。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = error ?? store.loadError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let failure = runtime.lastFailure, failure.wallpaperID == wallpaper.id {
                Text("网页更新失败，原画面已保留。\n" + failure.detail).foregroundStyle(.red).textSelection(.enabled)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { draft = store.configuration(for: wallpaper.id); updatePreview() }
        .onChange(of: draft) { _ in status = nil; updatePreview() }
        .onChange(of: allowsNetwork) { _ in updatePreview() }
    }
    private func updatePreview(force: Bool = false) {
        preview.update(wallpaper, options: draft, allowsNetwork: allowsNetwork, ownerID: ownerID, forceReload: force)
    }

}


/// Shared bindings; saving and preview ownership stay with the caller.
@MainActor
struct WebPlaybackControls: View {
    @Binding var draft: WebPlaybackOptions
    var allowsNumericEntry = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("允许 JavaScript", isOn: $draft.javaScriptEnabled)
            Toggle("鼠标移动交互", isOn: $draft.mouseInteractionEnabled)
                .disabled(!draft.javaScriptEnabled)
            Text("壁纸响应鼠标移动；桌面图标和其他窗口保持正常点击。关闭脚本后不发送鼠标交互。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("拦截常见跟踪服务", isOn: $draft.trackerBlockingEnabled)
            Text("拦截 Google Analytics、Tag Manager、DoubleClick 与 Hotjar。开启后可能影响依赖这些服务的网页。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            slider("缩放", value: $draft.scale, range: 0.25...3, suffix: "×")
            slider("水平位置", value: $draft.panX, range: -1...1)
            slider("垂直位置", value: $draft.panY, range: -1...1)
            slider("旋转", value: $draft.rotationDegrees, range: -180...180, suffix: "°")
            Toggle("按显示器实际像素布局", isOn: $draft.physicalPixelLayout)
            Text("Retina 屏幕使用实际像素作为网页布局单位，可能让文字和元素显得更小。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("自定义 CSS").font(.headline)
            TextEditor(text: $draft.customCSS).font(.system(size: 12, design: .monospaced))
                .frame(height: 120).border(Color.primary.opacity(0.1))
                .accessibilityLabel("自定义 CSS")
            Text("最多 64 KiB；样式只作用于 Kinetic，原网页文件不会改动。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title); Spacer()
                if allowsNumericEntry {
                    NumericParameterValue(title: title, value: value, range: range, suffix: suffix, isEditable: true)
                } else {
                    Text(value.wrappedValue.formatted(.number.precision(.fractionLength(0...2))) + suffix)
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}
