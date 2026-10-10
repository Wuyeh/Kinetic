import AppKit
import KineticSceneRuntime
import SwiftUI

enum DisplayControlLayout {
    /// The preview renders at its on-screen size, rounded up to whole steps so a live window resize
    /// re-renders rarely. Rendering stays bounded: a larger presentation scales this width up.
    static let maximumPreviewWidth: CGFloat = 960
    static let previewWidthStep: CGFloat = 64
    static let pickerMaximumHeight: CGFloat = 330
    static let posterSide: CGFloat = 36
    /// Room for the console's vertical scroller inside its trailing padding.
    static let scrollerGutter: CGFloat = 16

    static func aspectRatio(_ display: DisplayRuntimeState?) -> CGFloat {
        guard let size = display?.frame?.size, size.width > 0, size.height > 0 else { return 16 / 10 }
        return size.width / size.height
    }
    static func renderSize(for size: CGSize, aspect: CGFloat) -> CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 16 / 10
        let shown = size.width.isFinite ? max(0, size.width) : 0
        let width = min(maximumPreviewWidth, max(previewWidthStep, (shown / previewWidthStep).rounded(.up) * previewWidthStep))
        return CGSize(width: width, height: width / ratio)
    }
}

@MainActor
enum DisplayControlPresentation {
    static func name(_ display: DisplayRuntimeState, index: Int) -> String {
        display.displayName.isEmpty
            ? String(format: NSLocalizedString("displayPicker.fallback", comment: ""), index + 1)
            : display.displayName
    }
    static func symbol(for display: DisplayID) -> String {
        guard let descriptor = DisplayRegistry.systemDisplays().first(where: { $0.id == display }) else { return "display" }
        return CGDisplayIsBuiltin(descriptor.desktop.id) != 0 ? "laptopcomputer" : "display"
    }
    static func typeName(_ type: WallpaperType) -> String {
        switch type { case .scene: return "Scene"; case .web: return "Web"; case .video: return "视频" }
    }
    static func pickerWallpapers(_ wallpapers: [Wallpaper]) -> [Wallpaper] {
        wallpapers.filter { $0.resourceURL.isFileURL && WallpaperCardVisualState.isPlayable($0) }
    }
    /// The display's current wallpaper, pinned above the scrolling list, and the rest of the list.
    static func pinnedPicker(_ wallpapers: [Wallpaper], activeID: Wallpaper.ID?) -> (inUse: Wallpaper?, others: [Wallpaper]) {
        let items = pickerWallpapers(wallpapers)
        let inUse = activeID.flatMap { id in items.first { $0.id == id } }
        return (inUse, items.filter { $0.id != inUse?.id })
    }
}

extension View {
    /// The console and the wallpaper selector: system glass over a half-strength window backing,
    /// with the window's corner arc.
    func displayWorkspacePanel(interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: DisplayWorkspaceMetrics.cornerRadius, style: .continuous)
        return kineticGlass(in: shape, interactive: interactive)
            .background(Color(nsColor: .windowBackgroundColor).opacity(DisplayWorkspaceMetrics.consoleBackingOpacity), in: shape)
    }

    @ViewBuilder
    func displayControlPrimaryButton(isEnabled: Bool) -> some View {
        if #available(macOS 26.0, *) {
            if isEnabled { buttonStyle(.glassProminent).tint(MainWindowDesignTokens.accent) }
            else { buttonStyle(.glass).tint(nil) }
        } else {
            if isEnabled { buttonStyle(.borderedProminent).tint(MainWindowDesignTokens.accent) }
            else { buttonStyle(.bordered).tint(nil) }
        }
    }
}

/// The former Settings › 叠加层 entries (moved 2026-10-08). Each entry opens the same window as before.
struct DisplayOverlayMenu {
    struct Entry: Identifiable {
        let id: String
        let titleKey: String
        let detailKey: String?
        let open: (DisplayID) -> Void
    }
    var entries: [Entry]
}

/// Round button right of the display name, styled like the content-options button; the list drops
/// down in the same popover rows as the Workshop filter.
struct DisplayOverlayMenuButton: View {
    let displayID: DisplayID
    let menu: DisplayOverlayMenu
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: ContentHeaderMetrics.iconSize, weight: .semibold))
                .foregroundStyle(isPresented || isHovered ? AnyShapeStyle(MainWindowDesignTokens.accent) : AnyShapeStyle(.primary))
                .frame(width: ContentHeaderMetrics.buttonSize, height: ContentHeaderMetrics.buttonSize)
                .contentShape(Circle())
                .kineticGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text("settings.overlays"))
        .accessibilityLabel(Text("settings.overlays"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(menu.entries) { entry in
                    ContentOptionRow(titleKey: entry.titleKey, isChecked: false) {
                        isPresented = false
                        entry.open(displayID)
                    }
                    .help(entry.detailKey.map { Text(LocalizedStringKey($0)) } ?? Text(""))
                }
            }
            .padding(MainWindowDesignTokens.Spacing.small)
            .frame(width: ContentHeaderMetrics.popoverWidth)
        }
    }
}

struct SidebarSettingsGear: View {
    @State private var hovered = false
    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                SettingsLink { icon }
            } else {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: { icon }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("设置")
        .accessibilityLabel("设置")
    }
    private var icon: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: MainWindowDesignTokens.Sidebar.iconSize + 2, weight: .regular))
            .foregroundStyle(hovered ? MainWindowDesignTokens.accent : Color.primary)
            .frame(width: 30, height: 30).contentShape(Rectangle())
    }
}

/// Cached artwork only: opening the selector never starts poster timers or wallpaper engines.
struct DisplayPickerPoster: View {
    let wallpaper: Wallpaper?
    var body: some View {
        Group {
            if let url = wallpaper?.thumbnailURL, let artwork = PosterArtworkCache.shared.artwork(for: url) {
                Image(decorative: artwork.firstFrame, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: wallpaper?.type == .video ? "film" : wallpaper?.type == .web ? "globe" : "photo")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.05))
            }
        }
        .frame(width: DisplayControlLayout.posterSide, height: DisplayControlLayout.posterSide)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
    }
}

@MainActor
struct DisplayControlPage: View {
    let displayID: DisplayID
    @ObservedObject var editor: DisplayWallpaperEditor
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var runtime: WallpaperRuntimeManager
    @ObservedObject var settings: SettingsStore
    var overlayMenu: DisplayOverlayMenu? = nil
    /// Particles, the clock and widgets are previewed and edited on this thumbnail until 应用 (user, 2026-10-08).
    var overlays: DisplayOverlayEditors? = nil
    /// Module 46：控制台的「壁纸列表轮播」；与参数、叠加层一起点「应用」。
    var playlist: WallpaperPlaylistPlayer? = nil
    var lists: LocalOrganizationStore? = nil
    /// Module 47：控制台的「定时切换」。
    var scheduler: WallpaperScheduler? = nil
    /// Module 48：壁纸选择浮窗里的书签。
    var setup: SetupStore? = nil
    @StateObject private var videoPreview = VideoPlaybackPreview()
    @StateObject private var webPreview = WebPlaybackPreview()
    @StateObject private var scenePreview = DisplayScenePreview()
    @State private var ownerID = UUID()
    @State private var isPicking = false
    @State private var schema: ScenePropertySchema?
    @State private var lastDisplay: DisplayRuntimeState?
    @State private var previewSourceURL: URL?
    @State private var previewVisible = false
    @State private var sceneResetRequest = UUID()
    private var display: DisplayRuntimeState? { runtime.summary.displays.first { $0.id == displayID } }
    private var draft: StagedDisplayWallpaperConfiguration { editor.draft(on: displayID) }
    private var wallpaper: Wallpaper? { draft.wallpaperID.flatMap { library.wallpaper(id: $0) } }
    private var title: String { (display ?? lastDisplay).map { DisplayControlPresentation.name($0, index: 0) } ?? "显示器" }

    var body: some View {
        DisplayWorkspace(aspect: DisplayControlLayout.aspectRatio(display ?? lastDisplay)) {
            HStack(spacing: MainWindowDesignTokens.Spacing.compact) {
                Text(title).font(ContentHeaderMetrics.titleFont).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).accessibilityAddTraits(.isHeader)
                if let overlayMenu { DisplayOverlayMenuButton(displayID: displayID, menu: overlayMenu) }
                Spacer(minLength: 0)
            }
        } selector: { selector } preview: {
            preview(size: $0)
        } console: { console } status: { previewStatus }
        .background {
            DisplayPreviewVisibility { visible in
                previewVisible = visible
                if visible { updatePreview() } else { stopPreviews() }
            }.frame(width: 0, height: 0)
        }
        .onAppear { lastDisplay = display; updatePreview() }
        .onChange(of: draft) { value in updatePreview(); closeStaleCropEditor(value) }
        // The scene schema belongs to one wallpaper; the rotation can also change the draft's wallpaper.
        .onChange(of: draft.wallpaperID) { _ in schema = nil }
        .onChange(of: wallpaper?.resourceURL) { _ in updatePreview() }
        .onChange(of: display) { value in
            if let value { lastDisplay = value; updatePreview() }
            else { stopPreviews(); isPicking = false; DisplayCropEditorWindow.shared.close(on: displayID) }
        }
        .onChange(of: settings.state.webNetworkAccessEnabled) { _ in updatePreview() }
        .onDisappear { stopPreviews(); isPicking = false }
    }

    private func preview(size: CGSize) -> some View {
        let source = DisplayControlLayout.renderSize(for: size, aspect: DisplayControlLayout.aspectRatio(display ?? lastDisplay))
        let scale = max(size.width / source.width, size.height / source.height)
        return ZStack {
            Group {
                if let wallpaper, display != nil {
                    switch wallpaper.type {
                    case .video: DisplayPreviewSurface(surface: videoPreview.surface)
                    case .web: DisplayPreviewSurface(surface: webPreview.surface)
                    case .scene: DisplayPreviewSurface(surface: scenePreview.surface)
                    }
                } else { emptyPreview }
            }
            .frame(width: source.width, height: source.height)
            .scaleEffect(scale)
        }
        .frame(width: size.width, height: size.height)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .topLeading) {
            if let overlays {
                DisplayOverlayPreviews(editors: overlays, displayID: displayID, size: size, visible: previewVisible && display != nil)
            }
        }
        .clipped()
    }
    private var previewStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if display == nil { Text("显示器已断开").foregroundStyle(.secondary) }
            if videoPreview.isPreparing || webPreview.isPreparing || scenePreview.isPreparing {
                ProgressView().controlSize(.small)
            }
            if let error = videoPreview.error ?? webPreview.error ?? scenePreview.error {
                Text("预览失败：" + error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var emptyPreview: some View {
        VStack(spacing: 12) {
            Image(systemName: "display").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(display == nil ? "显示器已断开" : "未在播放").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Taken out of the console onto the title row; same picker, popover and selection as before.
    private var selector: some View {
        Button { isPicking.toggle() } label: {
            HStack(spacing: 10) {
                DisplayPickerPoster(wallpaper: wallpaper)
                Text(wallpaper?.name ?? "选择壁纸").lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: DisplayWorkspaceMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .displayWorkspacePanel(interactive: true)
        .accessibilityLabel("壁纸，当前选择：" + (wallpaper?.name ?? "未选择"))
        .popover(isPresented: $isPicking, arrowEdge: .top) {
            picker.frame(width: 290).padding(8)
                .kineticGlass(in: RoundedRectangle(cornerRadius: MainWindowDesignTokens.Radius.container, style: .continuous))
                .onExitCommand { isPicking = false }
        }
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let playlist, let lists {
                        DisplayPlaylistSection(displayID: displayID, player: playlist, lists: lists, editor: editor,
                                               library: library, runtime: runtime)
                            .padding(.trailing, DisplayControlLayout.scrollerGutter)
                        Divider().padding(.trailing, DisplayControlLayout.scrollerGutter)
                    }
                    if let scheduler, let lists, let setup {
                        DisplayScheduleSection(displayID: displayID, scheduler: scheduler, lists: lists, library: library,
                                               bookmarks: setup)
                            .padding(.trailing, DisplayControlLayout.scrollerGutter)
                        Divider().padding(.trailing, DisplayControlLayout.scrollerGutter)
                    }
                    if let wallpaper {
                        VStack(alignment: .leading, spacing: 14) {
                            switch wallpaper.type {
                            case .video: VideoPlaybackControls(draft: binding(\.video), compactLabels: true, allowsNumericEntry: true,
                                                               onCustomize: { openCropEditor(wallpaper) })
                            case .web:
                                WebPlaybackControls(draft: binding(\.web), allowsNumericEntry: true)
                                Button("刷新预览") { updatePreview(forceReload: true) }.kineticGlassButton()
                            case .scene:
                                SceneDisplayFitControl(selection: binding(\.sceneFit), compactLabels: true,
                                                       onCustomize: { openCropEditor(wallpaper) })
                                ScenePropertiesEditor(wallpaper: wallpaper, store: editor.sceneStore, runtime: runtime,
                                                      stagedValues: binding(\.sceneValues), onSchemaLoaded: { schema = $0 },
                                                      allowsNumericEntry: true, showsRestoreButton: false,
                                                      resetRequest: sceneResetRequest)
                                    .id(wallpaper.id)
                            }

                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, DisplayControlLayout.scrollerGutter)
                    } else {
                        Text("选择本地壁纸后可以调整预览。") .foregroundStyle(.secondary)
                            .padding(.trailing, DisplayControlLayout.scrollerGutter)
                    }
                }
            }
            // The vertical scroller runs in this gutter, to the right of the parameter values.
            .padding(.trailing, -DisplayControlLayout.scrollerGutter)
            if let error = editor.errors[displayID] ?? editor.loadError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let overlays { DisplayOverlayApplyError(editors: overlays, displayID: displayID) }
            HStack {
                Button("恢复默认预设") {
                    editor.edit(on: displayID) {
                        switch wallpaper?.type {
                        case .video: $0.video = .init()
                        case .web: $0.web = .init()
                        case .scene: $0.sceneValues = [:]
                        case nil: break
                        }
                    }
                    sceneResetRequest = UUID()
                }.kineticGlassButton().disabled(wallpaper == nil)
                Spacer(minLength: 0)
                if editor.applying.contains(displayID) { ProgressView().controlSize(.small) }
                if let overlays, let playlist, let scheduler {
                    ObservingObject(object: playlist) {
                        ObservingObject(object: scheduler) {
                            DisplayApplyButton(displayID: displayID, editor: editor, overlays: overlays, schema: schema,
                                               playlist: playlist, scheduler: scheduler, library: library)
                        }
                    }
                } else if let overlays {
                    DisplayApplyButton(displayID: displayID, editor: editor, overlays: overlays, schema: schema)
                } else {
                    Button("应用") { Task { await editor.apply(on: displayID, schema: schema) } }
                        .displayControlPrimaryButton(isEnabled: editor.canApply(on: displayID))
                        .disabled(!editor.canApply(on: displayID))
                }
            }
        }
        .padding(20)
        .displayWorkspacePanel()
    }
    /// The wallpaper this display is showing stays pinned above the scrolling list.
    private var picker: some View {
        let (inUse, others) = DisplayControlPresentation.pinnedPicker(library.wallpapers, activeID: display?.runtime.activeWallpaperID)
        return VStack(spacing: 4) {
            if let setup {
                DisplayBookmarkList(displayID: displayID, store: setup, library: library, editor: editor) {
                    schema = nil; isPicking = false
                }
            }
            if let inUse {
                pickerRow(inUse, inUse: true)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(others) { pickerRow($0, inUse: false) }
                }
            }
            .frame(height: min(DisplayControlLayout.pickerMaximumHeight, max(60, CGFloat(others.count) * 56)))
            if let setup {
                Divider()
                Button("将当前选择存为书签…") { saveBookmark(in: setup) }
                    .buttonStyle(.plain).foregroundStyle(MainWindowDesignTokens.accent)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .disabled(wallpaper == nil)
                    .help("保存选中的壁纸和这块屏幕上的参数（显示方式、播放与场景参数）。")
            }
        }
    }
    /// Module 48: the selected wallpaper and its parameters as they are now in the draft.
    private func saveBookmark(in setup: SetupStore) {
        let draft = draft
        isPicking = false
        DispatchQueue.main.async {
            guard let name = SetupPrompts.name(title: "存为书签", message: "保存选中的壁纸和这块屏幕上的参数。",
                                               initial: wallpaper?.name ?? "", confirm: "保存") else { return }
            SetupPrompts.report { try setup.addBookmark(name: name, configuration: draft) }
        }
    }
    private func pickerRow(_ item: Wallpaper, inUse: Bool) -> some View {
        Button {
            schema = nil; editor.select(item, on: displayID); isPicking = false
        } label: {
            HStack(spacing: 10) {
                DisplayPickerPoster(wallpaper: item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                    Text(DisplayControlPresentation.typeName(item.type)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if inUse { Text("正在使用").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize() }
                if item.id == draft.wallpaperID { Image(systemName: "checkmark").foregroundStyle(MainWindowDesignTokens.accent) }
            }.padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name + "，" + DisplayControlPresentation.typeName(item.type) + (inUse ? "，正在使用" : ""))
        .accessibilityAddTraits(item.id == draft.wallpaperID ? .isSelected : [])
    }
    /// 显示方式 › 自定义：在单独的窗口里拖动 / 捏合 / 双指滑动选择显示的部分，改动实时进入草稿与上面的预览，点「应用」才到桌面。
    private func openCropEditor(_ wallpaper: Wallpaper) {
        let draft = draft
        let current = wallpaper.type == .video ? draft.video.customFrame : draft.sceneCustomFrame
        DisplayCropEditorWindow.shared.open(
            displayID: displayID, wallpaper: wallpaper, displayName: title,
            displayAspect: DisplayControlLayout.aspectRatio(display ?? lastDisplay), frame: current ?? CustomDisplayFrame(),
            sceneValues: draft.sceneValues
        ) { [editor = editor, displayID = displayID] frame in
            editor.edit(on: displayID) { value in
                guard value.wallpaperID == wallpaper.id else { return }
                if wallpaper.type == .video { value.video.customFrame = frame } else { value.sceneCustomFrame = frame }
            }
        }
    }
    /// 草稿换了壁纸或不再是「自定义」时，关掉这块屏幕的范围窗口。
    private func closeStaleCropEditor(_ value: StagedDisplayWallpaperConfiguration) {
        let isCustom = wallpaper.map { $0.type == .video ? value.video.displayFit == .custom : value.sceneFit == .custom } ?? false
        DisplayCropEditorWindow.shared.closeIfStale(on: displayID, wallpaperID: isCustom ? value.wallpaperID : nil)
    }
    private func binding<Value>(_ keyPath: WritableKeyPath<StagedDisplayWallpaperConfiguration, Value>) -> Binding<Value> {
        Binding(get: { editor.draft(on: displayID)[keyPath: keyPath] },
                set: { value in editor.edit(on: displayID) { $0[keyPath: keyPath] = value } })
    }
    private func updatePreview(forceReload: Bool = false) {
        guard previewVisible, display != nil, let wallpaper else { stopPreviews(); return }
        if previewSourceURL != wallpaper.resourceURL {
            stopPreviews()
            previewSourceURL = wallpaper.resourceURL
        }
        let aspect = DisplayControlLayout.aspectRatio(display)
        switch wallpaper.type {
        case .video:
            webPreview.stop(ownerID: ownerID); scenePreview.stop()
            videoPreview.update(wallpaper, options: draft.video, ownerID: ownerID)
        case .web:
            videoPreview.stop(ownerID: ownerID); scenePreview.stop()
            webPreview.update(wallpaper, options: draft.web, allowsNetwork: settings.state.webNetworkAccessEnabled,
                              ownerID: ownerID, forceReload: forceReload)
        case .scene:
            videoPreview.stop(ownerID: ownerID); webPreview.stop(ownerID: ownerID)
            scenePreview.update(wallpaper, values: draft.sceneValues, fit: draft.sceneFit, frame: draft.sceneCustomFrame, aspect: aspect)
        }
    }
    private func stopPreviews() {
        videoPreview.stop(ownerID: ownerID); webPreview.stop(ownerID: ownerID); scenePreview.stop()
        previewSourceURL = nil
    }
}

/// 应用 applies the wallpaper draft and this display's overlay drafts (widgets, particles, clock) together,
/// and (Module 46) starts, changes or ends its wallpaper-list rotation.
private struct DisplayApplyButton: View {
    let displayID: DisplayID
    @ObservedObject var editor: DisplayWallpaperEditor
    @ObservedObject var overlays: DisplayOverlayEditors
    let schema: ScenePropertySchema?
    var playlist: WallpaperPlaylistPlayer? = nil
    var scheduler: WallpaperScheduler? = nil
    var library: WallpaperLibrary? = nil
    var body: some View {
        let wallpaper = editor.canApply(on: displayID), overlay = overlays.canApply(on: displayID)
        let rotation = playlist?.canApplyDraft(on: displayID) ?? false
        let schedule = scheduler?.canApplyDraft(on: displayID) ?? false
        Button("应用") {
            var schema = schema
            if rotation, let playlist {
                // The rotation decides which wallpaper the display shows; that goes through the usual apply below.
                let shown = editor.draft(on: displayID).wallpaperID
                if let start = playlist.applyDraft(on: displayID, showing: shown), start != shown,
                   let item = library?.wallpaper(id: start) {
                    editor.select(item, on: displayID)
                    schema = nil
                }
            }
            if overlay { overlays.apply(on: displayID) }
            if editor.canApply(on: displayID) { Task { await editor.apply(on: displayID, schema: schema) } }
            // Last: the slot covering now takes over at once (Module 47).
            if schedule { scheduler?.applyDraft(on: displayID) }
        }
        .displayControlPrimaryButton(isEnabled: wallpaper || overlay || rotation || schedule)
        .disabled(!(wallpaper || overlay || rotation || schedule))
    }
}

private struct DisplayOverlayApplyError: View {
    @ObservedObject var editors: DisplayOverlayEditors
    let displayID: DisplayID
    var body: some View {
        if let error = editors.error(on: displayID) {
            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

struct SceneDisplayFitControl: View {
    @Binding var selection: SceneDisplayFitSetting
    var compactLabels = false
    /// 显示器页：提供「自定义」并打开选择显示范围的窗口。全局设置为 nil，没有这个选项。
    var onCustomize: (() -> Void)? = nil
    @ViewBuilder
    var body: some View {
        if compactLabels {
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.scene.displayFit"); picker.labelsHidden()
                if selection == .custom, let onCustomize {
                    Button("settings.scene.displayFit.adjust", action: onCustomize).kineticGlassButton().padding(.top, 8)
                }
            }
        } else { picker }
    }
    private var picker: some View {
        Picker("settings.scene.displayFit", selection: choice) {
            Text("settings.scene.displayFit.automatic").tag(SceneDisplayFitSetting.automatic)
            Text("settings.scene.displayFit.fill").tag(SceneDisplayFitSetting.fill)
            Text("settings.scene.displayFit.fit").tag(SceneDisplayFitSetting.fit)
            if onCustomize != nil { Text("settings.scene.displayFit.custom").tag(SceneDisplayFitSetting.custom) }
        }
    }
    /// 选中「自定义」时打开选择显示范围的窗口。
    private var choice: Binding<SceneDisplayFitSetting> {
        Binding(get: { selection }, set: { value in
            let opened = value == .custom && selection != .custom
            selection = value
            if opened { onCustomize?() }
        })
    }
}

/// UI visibility only. The desktop session keeps its own independent lifecycle.
private struct DisplayPreviewVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ view: VisibilityView, context: Context) { view.changed = changed; view.refresh() }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.detach() }

    final class VisibilityView: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            if let window {
                for name in [NSWindow.didUpdateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in self?.refresh()
                    })
                }
                for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) {
                        [weak self] _ in self?.refresh()
                    })
                }
                observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                    object: window, queue: .main) { [weak self] _ in self?.publish(false) })
            }
            refresh()
        }
        func refresh() { publish(window?.isVisible == true && window?.isMiniaturized == false && !NSApp.isHidden) }
        private func publish(_ visible: Bool) {
            guard last != visible else { return }
            last = visible
            // A native notification can arrive during SwiftUI layout; publish after that transaction.
            DispatchQueue.main.async { [weak self] in guard let self, self.last == visible else { return }; self.changed?(visible) }
        }
        func detach() { observers.forEach(NotificationCenter.default.removeObserver); observers = []; publish(false) }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

struct DisplayPreviewSurface: NSViewRepresentable {
    let surface: NSView
    func makeNSView(context: Context) -> NSView { surface }
    func updateNSView(_ nsView: NSView, context: Context) { }
}
