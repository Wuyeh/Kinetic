import AppKit
import Combine
import SwiftUI

@MainActor
final class AppleAerialBrowserModel: ObservableObject {
    let catalog: AppleAerialCatalog
    let library: WallpaperLibrary
    let preview: VideoPlaybackPreview
    @Published private(set) var selectedID: String?
    @Published private(set) var isAdding = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var applyWallpaperID: Wallpaper.ID?
    private let importer: LocalImportService
    private let runtime: WallpaperRuntimeManager
    private let cancelSteamApplication: (DisplayID) -> Void
    private var previewAccess: AppleAerialAccess?
    private var isVisible = false
    private var visibilityGeneration = UUID()

    init(catalog: AppleAerialCatalog, library: WallpaperLibrary, importer: LocalImportService,
         runtime: WallpaperRuntimeManager, preview: VideoPlaybackPreview? = nil,
         cancelSteamApplication: @escaping (DisplayID) -> Void = { _ in }) {
        self.catalog = catalog; self.library = library; self.importer = importer; self.runtime = runtime
        self.preview = preview ?? VideoPlaybackPreview(); self.cancelSteamApplication = cancelSteamApplication
    }
    var selectedAsset: AppleAerialAsset? { catalog.assets.first { $0.id == selectedID } }
    func existingWallpaper(for asset: AppleAerialAsset) -> Wallpaper? { library.wallpapers.first(where: asset.matches) }
    func opened() { isVisible = true; visibilityGeneration = UUID() }
    func closed() {
        isVisible = false; visibilityGeneration = UUID(); applyWallpaperID = nil
        stopPreview(); catalog.cancelScan()
    }
    func stopPreview() { preview.stop(); previewAccess = nil }
    func select(_ id: String?) {
        guard selectedID != id || preview.renderer == nil || preview.error != nil else { return }
        selectedID = id; error = nil; notice = nil
        guard let asset = selectedAsset else { stopPreview(); return }
        do {
            previewAccess = try catalog.validatedAccess(for: asset)
            var options = VideoPlaybackOptions(); options.displayFit = .fit
            preview.update(asset.previewWallpaper, options: options)
        } catch { self.error = error.localizedDescription; stopPreview() }
    }
    /// Both actions explicitly copy to managed storage. The display is selected *after* copying,
    /// so a long copy can never apply a stale intent over newer desktop commands.
    @discardableResult
    func addSelected(thenChooseDisplay: Bool = false) async -> Wallpaper? {
        guard !isAdding, let asset = selectedAsset else { return nil }
        isAdding = true; error = nil; notice = nil
        let visibility = visibilityGeneration
        defer { isAdding = false }
        do {
            let wallpaper: Wallpaper
            if let existing = existingWallpaper(for: asset) {
                guard library.availability(of: existing.id) == .available,
                      FileManager.default.isReadableFile(atPath: existing.resourceURL.path) else { throw AppleAerialError.missingLibraryFile }
                wallpaper = existing
            } else {
                let access = try catalog.validatedAccess(for: asset)
                defer { withExtendedLifetime(access) {} }
                let result = await importer.importItem(at: asset.url, origin: .appleAerial)
                var imported = try result.result.get()
                // Keep the importer's original managed filename (Apple UUID) for stable identity,
                // while showing Apple's local title. No extra library field or format migration.
                imported.name = asset.name
                try library.update(imported)
                wallpaper = imported
            }
            notice = "已将“\(wallpaper.name)”加入本地资料库。"
            if thenChooseDisplay, isVisible, visibilityGeneration == visibility, selectedID == asset.id {
                applyWallpaperID = wallpaper.id
            }
            return wallpaper
        } catch { self.error = error.localizedDescription; return nil }
    }
    func apply(to display: DisplayID) {
        let id = applyWallpaperID; applyWallpaperID = nil
        guard let id, let wallpaper = library.wallpaper(id: id), runtime.hasDisplay(display) else {
            notice = "目标显示器已断开，壁纸已保留在本地资料库。"; return
        }
        stopPreview(); WallpaperPreviewCoordinator.shared.stopAll()
        cancelSteamApplication(display)
        runtime.apply(wallpaper, to: display)
        notice = nil // Runtime owns preparation, success and failure; never claim success before Ready.
    }
}

/// A dedicated browser, not a third Sidebar source. Closing releases previews only.
@MainActor
final class AppleAerialBrowserWindow: NSObject, NSWindowDelegate {
    let model: AppleAerialBrowserModel
    private let runtime: WallpaperRuntimeManager
    private(set) var window: NSWindow?
    init(model: AppleAerialBrowserModel, runtime: WallpaperRuntimeManager) {
        self.model = model; self.runtime = runtime
    }
    @discardableResult func show(activate: Bool = true) -> NSWindow {
        if let window { window.makeKeyAndOrderFront(nil); return window }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 860, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Apple 航拍"; window.isReleasedWhenClosed = false
        window.minSize = .init(width: 680, height: 480)
        window.identifier = NSUserInterfaceItemIdentifier("Kinetic.AppleAerials")
        window.contentView = NSHostingView(rootView: AppleAerialBrowserView(model: model, catalog: model.catalog,
            library: model.library, runtime: runtime).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.delegate = self; self.window = window; model.opened(); window.center()
        window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }
        return window
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        model.closed(); closing.delegate = nil; closing.contentView = nil; window = nil
    }
    func close() { window?.close(); model.closed() }
}

@MainActor
struct AppleAerialBrowserView: View {
    @ObservedObject var model: AppleAerialBrowserModel
    @ObservedObject var catalog: AppleAerialCatalog
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var runtime: WallpaperRuntimeManager
    @State private var search = ""
    @State private var panelError: String?
    private var assets: [AppleAerialAsset] { catalog.assets.filter { $0.matchesSearch(search) } }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Mac 已下载的航拍").font(.headline)
                    if catalog.isScanning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("选择文件夹…") { Task { await chooseFolder() } }.kineticGlassButton().disabled(model.isAdding)
                    Button("刷新") { Task { await catalog.refresh(); synchronizeSelection() } }.kineticGlassButton().disabled(catalog.isScanning)
                }
                TextField("搜索航拍", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索航拍")
                HStack(alignment: .top, spacing: 20) {
                    List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                        ForEach(assets) { asset in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(asset.name).lineLimit(1)
                                HStack {
                                    if let category = asset.category { Text(category) }
                                    Text(ByteCountFormatter.string(fromByteCount: asset.sizeInBytes, countStyle: .file))
                                    if model.existingWallpaper(for: asset) != nil { Text("已在资料库") }
                                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.vertical, 4).tag(asset.id)
                        }
                    }.frame(minWidth: 250, idealWidth: 300, maxWidth: 330)
                    ScrollView(.vertical) {
                      VStack(alignment: .leading, spacing: 12) {
                        if let asset = model.selectedAsset {
                            Text(asset.name).font(.headline).lineLimit(2)
                            AppleAerialPreviewView(preview: model.preview)
                            HStack {
                                Button("加入资料库") { Task { await model.addSelected() } }.kineticGlassButton()
                                    .disabled(model.isAdding || model.existingWallpaper(for: asset) != nil)
                                Button(model.existingWallpaper(for: asset) == nil ? "添加并应用…" : "应用…") {
                                    Task { await model.addSelected(thenChooseDisplay: true) }
                                }.kineticGlassButton().disabled(model.isAdding || runtime.displayIDs.isEmpty)
                            }
                            if model.isAdding { ProgressView("正在加入资料库…").controlSize(.small) }
                        } else {
                            Text(catalog.isScanning ? "正在读取本机航拍…" : (catalog.assets.isEmpty ? "没有可浏览的已下载航拍。" : "选择一段航拍预览。"))
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
                        }
                        Text("只浏览和预览不会复制文件或更改桌面。加入资料库会复制视频并占用本机空间；未下载的航拍请先在 macOS 系统设置中下载。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if catalog.metadataUnavailable, !catalog.assets.isEmpty {
                            Text("所选目录没有可用的名称信息，使用航拍标识显示。选择上层 Customer 或 aerials 文件夹通常可读取名称。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let message = panelError ?? model.error ?? catalog.error { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                        if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                        if let failure = runtime.lastFailure, let asset = model.selectedAsset,
                           let wallpaper = model.existingWallpaper(for: asset), failure.wallpaperID == wallpaper.id {
                            Text("未能应用，原桌面画面已保留：" + failure.detail).foregroundStyle(.red)
                        }
                        Spacer(minLength: 0)
                      }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !catalog.assets.isEmpty, assets.isEmpty { Text("没有匹配的航拍。").foregroundStyle(.secondary) }
            }.padding(20)
            .overlay {
                if model.applyWallpaperID != nil {
                    DisplayApplyDialog(items: runtime.summary.displays.enumerated().map {
                        DisplayTargetItem(display: $0.element, index: $0.offset,
                                          wallpaper: runtime.activeWallpaper(on: $0.element.displayID))
                    }, availableSize: geometry.size, onSelect: { model.apply(to: $0) },
                       onCancel: { model.applyWallpaperID = nil })
                }
            }
        }
        .background { WindowGlassBackground(style: .sidebar).ignoresSafeArea() }
        .task { await catalog.refresh(); synchronizeSelection() }
        .onChange(of: catalog.assets) { _ in synchronizeSelection() }
        .onChange(of: search) { _ in if !assets.contains(where: { $0.id == model.selectedID }) { model.select(nil) } }
        .onDisappear { model.closed() }
    }
    private func synchronizeSelection() {
        if !assets.contains(where: { $0.id == model.selectedID }) { model.select(assets.first?.id) }
        else { model.select(model.selectedID) }
    }
    private func chooseFolder() async {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false; panel.showsHiddenFiles = true
        panel.title = "选择 Apple 航拍文件夹"; panel.prompt = "选择"
        panel.message = "仅浏览此文件夹内已下载的视频，不会下载或修改 Apple 文件。"
        panel.directoryURL = catalog.access?.url
            ?? AppleAerialCatalog.standardFolders().first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true)
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        do { model.stopPreview(); try catalog.link(folder); panelError = nil; await catalog.refresh(); synchronizeSelection() }
        catch { panelError = error.localizedDescription }
    }
}

private struct AppleAerialPreviewView: View {
    @ObservedObject var preview: VideoPlaybackPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("预览").font(.headline)
                if preview.isPreparing { ProgressView().controlSize(.small) }
            }
            AppleAerialPreviewSurface(preview: preview)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("预览始终静音，不改变桌面壁纸。").font(.caption).foregroundStyle(.secondary)
            if let error = preview.error { Text("预览失败：" + error).font(.caption).foregroundStyle(.red) }
        }
    }
}
private struct AppleAerialPreviewSurface: NSViewRepresentable {
    let preview: VideoPlaybackPreview
    func makeNSView(context: Context) -> NSView { preview.surface }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
