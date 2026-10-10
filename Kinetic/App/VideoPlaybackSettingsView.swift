import SwiftUI

@MainActor
struct VideoPlaybackSettingsSection: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var store: VideoPlaybackStore
    @ObservedObject var runtime: WallpaperRuntimeManager
    @StateObject private var preview: VideoPlaybackPreview
    @State private var wallpaperID: Wallpaper.ID?
    @State private var previewOwnerID = UUID()
    let showsInlinePreview: Bool
    init(library: WallpaperLibrary, store: VideoPlaybackStore, runtime: WallpaperRuntimeManager,
         preview: VideoPlaybackPreview? = nil, showsInlinePreview: Bool = true) {
        self.library = library; self.store = store; self.runtime = runtime
        _preview = StateObject(wrappedValue: preview ?? VideoPlaybackPreview())
        self.showsInlinePreview = showsInlinePreview
    }
    private var videos: [Wallpaper] { library.wallpapers.filter { $0.type == .video } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("高级视频").font(.headline)
            if videos.isEmpty { Text("导入视频壁纸后，可以在这里调整播放与画面。").foregroundStyle(.secondary) }
            else {
                Picker("视频壁纸", selection: $wallpaperID) {
                    ForEach(videos) { Text($0.name).tag(Optional($0.id)) }
                }
                if let wallpaper = videos.first(where: { $0.id == wallpaperID }) {
                    if showsInlinePreview { VideoPlaybackPreviewView(preview: preview).frame(maxWidth: 420) }
                    VideoPlaybackSettingsEditor(wallpaper: wallpaper, store: store, runtime: runtime,
                        onDraftChange: { options in preview.update(wallpaper, options: options, ownerID: previewOwnerID) })
                        .id(wallpaper.id)
                }
            }
        }
        .onAppear { selectInitial() }
        .onChange(of: videos.map(\.id)) { _ in selectInitial() }
        .onDisappear { preview.stop(ownerID: previewOwnerID) }
    }
    private func selectInitial() {
        guard !videos.contains(where: { $0.id == wallpaperID }) else { return }
        wallpaperID = videos.first(where: { $0.id == runtime.activeWallpaper?.id })?.id ?? videos.first?.id
        if wallpaperID == nil { preview.stop(ownerID: previewOwnerID) }
    }
}

@MainActor
struct VideoPlaybackSettingsEditor: View {
    let wallpaper: Wallpaper
    @ObservedObject var store: VideoPlaybackStore
    @ObservedObject var runtime: WallpaperRuntimeManager
    var onDraftChange: (VideoPlaybackOptions) -> Void = { _ in }
    @State private var draft = VideoPlaybackOptions()
    @State private var error: String?
    @State private var status: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VideoPlaybackControls(draft: $draft)
            HStack {
                Button {
                    do { try store.save(draft, for: wallpaper, runtime: runtime); error = nil; status = "已保存。正在使用此视频的显示器会更新，暂停与静音状态保持。" }
                    catch { self.error = error.localizedDescription; status = nil }
                } label: { Text("保存并应用").foregroundStyle(.primary) }
                    .kineticGlassButton().disabled(store.loadError != nil)
                Button { draft = .init(); error = nil; status = nil }
                    label: { Text("恢复默认").foregroundStyle(.primary) }
                    .kineticGlassButton()
            }
            Text("参数先在效果预览中显示；点击“保存并应用”才更新屏幕。恢复默认也需要保存。素材文件不会被改动。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = error ?? store.loadError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let failure = runtime.lastFailure, failure.wallpaperID == wallpaper.id {
                Text("视频更新失败，原画面已保留。\n" + failure.detail).foregroundStyle(.red).textSelection(.enabled)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { draft = store.configuration(for: wallpaper.id); onDraftChange(draft) }
        .onChange(of: draft) { value in status = nil; onDraftChange(value) }
    }

}


/// Shared bindings; saving and preview ownership stay with the caller.
@MainActor
struct VideoPlaybackControls: View {
    @Binding var draft: VideoPlaybackOptions
    var compactLabels = false
    var allowsNumericEntry = false
    /// 显示器页：提供「自定义」并打开选择显示范围的窗口。其他地方为 nil，没有这个选项。
    var onCustomize: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("显示方式", selection: displayFit) {
                Text("填满（裁切边缘）").tag(VideoPlaybackOptions.DisplayFit.fill)
                Text("完整显示（保留比例）").tag(VideoPlaybackOptions.DisplayFit.fit)
                Text("拉伸至屏幕").tag(VideoPlaybackOptions.DisplayFit.stretch)
                if onCustomize != nil { Text("自定义").tag(VideoPlaybackOptions.DisplayFit.custom) }
            }
            if draft.displayFit == .custom, let onCustomize {
                Button("调整显示范围…", action: onCustomize).kineticGlassButton()
            }
            slider("播放速度", value: $draft.speed, range: 0.25...2, step: 0.25, suffix: "×")
            slider("音量", value: $draft.volume, range: 0...1, step: 0.05, suffix: "")
            Text("音量不会打开静音开关；声音仍由工具条、菜单栏与设置中的音频开关控制。")
                .font(.caption).foregroundStyle(.secondary)
            field("目标帧率", selection: $draft.frameRate) {
                Text("跟随源视频").tag(VideoPlaybackOptions.FrameRate.source)
                ForEach([VideoPlaybackOptions.FrameRate.fps24, .fps30, .fps60], id: \.self) { Text("\($0.rawValue) fps").tag($0) }
            }
            field("动态范围", selection: $draft.dynamicRange) {
                Text("自动（保留源颜色与 HDR）").tag(VideoPlaybackOptions.DynamicRange.automatic)
                Text("标准动态范围（SDR）").tag(VideoPlaybackOptions.DynamicRange.sdr)
            }
            Text("HDR 亮度由视频、显示器能力与 macOS 决定；不把 SDR 视频转换成 HDR。")
                .font(.caption).foregroundStyle(.secondary)
            slider("亮度", value: $draft.brightness, range: -0.5...0.5, step: 0.05, suffix: "")
            slider("对比度", value: $draft.contrast, range: 0.5...1.5, step: 0.05, suffix: "")
            slider("饱和度", value: $draft.saturation, range: 0...2, step: 0.1, suffix: "")
            field("视频效果", selection: $draft.effect) {
                Text("无").tag(VideoPlaybackOptions.Effect.none)
                Text("黑白").tag(VideoPlaybackOptions.Effect.grayscale)
                Text("暖褐色").tag(VideoPlaybackOptions.Effect.sepia)
            }
            field("预加载预算", selection: $draft.preloadBudgetMiB) {
                ForEach([64, 128, 256, 512], id: \.self) { Text("\($0) MiB").tag($0) }
            }
            Text("预算用于准备静态帧和检查处理画面的资源需求，不是应用总内存上限；系统解码缓存由 macOS 管理。不预读整段视频。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    /// 选中「自定义」时打开选择显示范围的窗口。
    private var displayFit: Binding<VideoPlaybackOptions.DisplayFit> {
        Binding(get: { draft.displayFit }, set: { value in
            let opened = value == .custom && draft.displayFit != .custom
            draft.displayFit = value
            if opened { onCustomize?() }
        })
    }
    @ViewBuilder
    private func field<Selection: Hashable, Options: View>(_ title: String, selection: Binding<Selection>,
                                                          @ViewBuilder options: () -> Options) -> some View {
        let picker = Picker(title, selection: selection, content: options)
        if compactLabels {
            VStack(alignment: .leading, spacing: 6) { Text(title); picker.labelsHidden() }
        } else { picker }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
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
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }
}
