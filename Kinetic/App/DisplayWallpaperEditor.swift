import AppKit
import Combine
import KineticSceneRuntime

/// Existing parameter types, plus their editing target. Unsaved drafts are session-only.
struct StagedDisplayWallpaperConfiguration: Codable, Equatable, Sendable {
    var wallpaperID: Wallpaper.ID?
    var video = VideoPlaybackOptions()
    var web = WebPlaybackOptions()
    var sceneValues: [String: ScenePropertyValue] = [:]
    var sceneFit: SceneDisplayFitSetting = .automatic
    /// 场景显示方式为「自定义」时显示的部分（视频的在 `video.customFrame`）。
    var sceneCustomFrame: CustomDisplayFrame?
}

enum DisplayEditingError: LocalizedError {
    case unavailable, superseded, unreadable, timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: return "显示器已断开，未更改其他屏幕。"
        case .superseded: return "屏幕状态已改变，草稿已保留，请重试。"
        case .unreadable: return "无法读取或保存显示器参数；原设置文件保持不变。"
        case .timedOut: return "应用未完成，草稿已保留，请重试。"
        }
    }
}

/// Staging and persistence adapter. Does not own a desktop, session or apply state machine.
@MainActor
final class DisplayWallpaperEditor: ObservableObject {
    typealias RendererFactory = @MainActor (Wallpaper, StagedDisplayWallpaperConfiguration) throws -> WallpaperRenderer
    private struct Document: Codable {
        var version = 1
        var displays: [String: [String: StagedDisplayWallpaperConfiguration]] = [:]
    }
    static let maximumBytes = 4 * 1_024 * 1_024
    @Published private(set) var drafts: [DisplayID: StagedDisplayWallpaperConfiguration] = [:]
    @Published private(set) var applying = Set<DisplayID>()
    @Published private(set) var errors: [DisplayID: String] = [:]
    private(set) var loadError: String?
    private(set) var applied: [DisplayID: StagedDisplayWallpaperConfiguration] = [:]
    let fileURL: URL
    let sceneStore: ScenePropertyStore
    let videoStore: VideoPlaybackStore
    let webStore: WebPlaybackStore
    private let runtime: WallpaperRuntimeManager
    private let library: WallpaperLibrary
    private let settings: SettingsStore
    private let factory: RendererFactory?
    private var document = Document()
    private var inFlight: [DisplayID: StagedDisplayWallpaperConfiguration] = [:]
    private var inFlightRenderers: [DisplayID: WallpaperRenderer] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var previousScene: [String: ScenePropertyConfiguration] = [:]
    private var previousVideo: [String: VideoPlaybackOptions] = [:]
    private var previousWeb: [String: WebPlaybackOptions] = [:]
    private var globalFit: SceneDisplayFitSetting
    private var configurationRevisions: [Wallpaper.ID: Int] = [:]

    init(storage: LibraryStorageLocation, library: WallpaperLibrary, runtime: WallpaperRuntimeManager,
         sceneStore: ScenePropertyStore, videoStore: VideoPlaybackStore, webStore: WebPlaybackStore,
         settings: SettingsStore, rendererFactory: RendererFactory? = nil) {
        self.library = library; self.runtime = runtime; self.sceneStore = sceneStore
        self.videoStore = videoStore; self.webStore = webStore; self.settings = settings
        self.factory = rendererFactory; globalFit = settings.state.sceneDisplayFit
        fileURL = storage.rootURL.appendingPathComponent("display-wallpaper-settings.json")
        load()
        previousVideo = videoStore.options; previousWeb = webStore.options; previousScene = sceneStore.configurations
        runtime.$summary.sink { [weak self] in self?.synchronize($0) }.store(in: &subscriptions)
        runtime.applyRequests.sink { [weak self] in self?.followReapply(on: $0.display, wallpaperID: $0.wallpaperID) }
            .store(in: &subscriptions)
        // Explicit saves from the original Settings keep their global/all-matching meaning.
        videoStore.$options.dropFirst().sink { [weak self] next in
            guard let self else { return }
            let keys = Set(self.previousVideo.keys).union(next.keys).filter { self.previousVideo[$0] != next[$0] }
            self.previousVideo = next; self.resetOverrides(keys: keys, type: .video)
        }.store(in: &subscriptions)
        webStore.$options.dropFirst().sink { [weak self] next in
            guard let self else { return }
            let keys = Set(self.previousWeb.keys).union(next.keys).filter { self.previousWeb[$0] != next[$0] }
            self.previousWeb = next; self.resetOverrides(keys: keys, type: .web)
        }.store(in: &subscriptions)
        sceneStore.$configurations.dropFirst().sink { [weak self] next in
            guard let self else { return }
            let keys = Set(self.previousScene.keys).union(next.keys).filter { self.previousScene[$0]?.values != next[$0]?.values }
            self.previousScene = next; self.resetOverrides(keys: keys, type: .scene)
        }.store(in: &subscriptions)
        settings.$state.map(\.sceneDisplayFit).removeDuplicates().dropFirst().sink { [weak self] fit in
            guard let self else { return }
            self.globalFit = fit
            for wallpaper in self.library.wallpapers where wallpaper.type == .scene {
                self.configurationRevisions[wallpaper.id, default: 0] += 1
            }
            self.inFlight = self.inFlight.filter { pair in
                pair.value.wallpaperID.flatMap { self.library.wallpaper(id: $0) }?.type != .scene
            }
            for display in self.document.displays.keys {
                for key in self.document.displays[display]?.keys ?? Dictionary<String, StagedDisplayWallpaperConfiguration>().keys {
                    // 「自定义」是这块屏幕上手动选定的范围，全局设置改变时保留。
                    if let id = self.document.displays[display]?[key]?.wallpaperID,
                       self.document.displays[display]?[key]?.sceneFit != .custom,
                       self.library.wallpaper(id: id)?.type == .scene {
                        self.document.displays[display]?[key]?.sceneFit = fit
                    }
                }
            }
            try? self.persist(self.document)
            self.synchronize(self.runtime.summary)
        }.store(in: &subscriptions)
    }

    func configuration(for wallpaper: Wallpaper, on display: DisplayID) -> StagedDisplayWallpaperConfiguration {
        if let pending = inFlight[display], pending.wallpaperID == wallpaper.id { return pending }
        if let saved = document.displays[display.rawValue]?[wallpaper.id.uuidString] { return saved }
        var value = StagedDisplayWallpaperConfiguration(wallpaperID: wallpaper.id)
        switch wallpaper.type {
        case .video: value.video = previousVideo[wallpaper.id.uuidString] ?? videoStore.configuration(for: wallpaper.id)
        case .web: value.web = previousWeb[wallpaper.id.uuidString] ?? webStore.configuration(for: wallpaper.id)
        case .scene:
            value.sceneValues = previousScene[wallpaper.id.uuidString]?.values ?? sceneStore.configuration(for: wallpaper.id).values
            value.sceneFit = globalFit
        }
        return value
    }

    func draft(on display: DisplayID) -> StagedDisplayWallpaperConfiguration {
        drafts[display] ?? applied[display] ?? .init()
    }
    func isDirty(on display: DisplayID) -> Bool { draft(on: display) != (applied[display] ?? .init()) }
    func canApply(on display: DisplayID) -> Bool {
        guard let id = draft(on: display).wallpaperID, let wallpaper = library.wallpaper(id: id),
              WallpaperCardVisualState.isPlayable(wallpaper), wallpaper.resourceURL.isFileURL else { return false }
        return runtime.hasDisplay(display) && !applying.contains(display) && loadError == nil
            && runtime.state(of: display)?.preparingWallpaperID == nil
            && isDirty(on: display)
    }
    func select(_ wallpaper: Wallpaper, on display: DisplayID) {
        guard WallpaperCardVisualState.isPlayable(wallpaper), wallpaper.resourceURL.isFileURL else { return }
        drafts[display] = configuration(for: wallpaper, on: display)
        errors[display] = nil
    }
    func edit(on display: DisplayID, _ change: (inout StagedDisplayWallpaperConfiguration) -> Void) {
        var value = draft(on: display); change(&value); drafts[display] = value; errors[display] = nil
    }
    /// Module 48: a bookmark's wallpaper and parameters become this display's draft (previewed, applied on 应用).
    @discardableResult
    func stage(_ configuration: StagedDisplayWallpaperConfiguration, on display: DisplayID) -> Bool {
        guard let id = configuration.wallpaperID, let wallpaper = library.wallpaper(id: id),
              WallpaperCardVisualState.isPlayable(wallpaper), wallpaper.resourceURL.isFileURL else { return false }
        drafts[display] = configuration
        errors[display] = nil
        return true
    }
    /// Module 47 / 48: a scheduled bookmark or a scheme sets these parameters and applies them through the usual path.
    func apply(_ configuration: StagedDisplayWallpaperConfiguration, on display: DisplayID) async {
        guard stage(configuration, on: display) else { return }
        await apply(on: display)
    }

    func makeRenderer(_ wallpaper: Wallpaper, on display: DisplayID) throws -> WallpaperRenderer {
        let value = configuration(for: wallpaper, on: display)
        let renderer: WallpaperRenderer
        if let factory { renderer = try factory(wallpaper, value) }
        else { renderer = try standardRenderer(wallpaper, configuration: value) }
        if inFlight[display]?.wallpaperID == wallpaper.id { inFlightRenderers[display] = renderer }
        return renderer
    }

    private func standardRenderer(_ wallpaper: Wallpaper, configuration value: StagedDisplayWallpaperConfiguration) throws -> WallpaperRenderer {
        switch wallpaper.type {
        case .video: return VideoRenderer(wallpaper: wallpaper, options: value.video)
        case .web: return WebRenderer(wallpaper: wallpaper, allowsNetwork: settings.state.webNetworkAccessEnabled, options: value.web)
        case .scene:
            let renderer = SceneRenderer(wallpaper: wallpaper, engineAssets: SceneRenderer.engineAssetsProvider?(),
                                         dependencyFolders: SceneRenderer.dependencyFolders(for: wallpaper), propertyValues: value.sceneValues)
            renderer.applyDisplay(value.sceneFit, frame: value.sceneCustomFrame)
            return renderer
        }
    }

    func apply(on display: DisplayID, schema: ScenePropertySchema? = nil) async {
        guard canApply(on: display), let id = draft(on: display).wallpaperID,
              let wallpaper = library.wallpaper(id: id) else { return }
        let originalDraft = draft(on: display)
        var value = originalDraft
        let previousRecord = document.displays[display.rawValue]?[id.uuidString]
        let revision = configurationRevisions[id, default: 0]
        var didWrite = false
        applying.insert(display); errors[display] = nil
        defer {
            applying.remove(display); inFlight[display] = nil; inFlightRenderers[display] = nil
            synchronize(runtime.summary)
        }
        do {
            switch wallpaper.type {
            case .video: value.video = try value.video.validated()
            case .web: value.web = try value.web.validated()
            case .scene:
                let schema = try schema ?? ScenePropertySchema.read(root: wallpaper.resourceURL)
                value.sceneValues = try schema.validated(value.sceneValues)
            }
            var next = document
            next.displays[display.rawValue, default: [:]][id.uuidString] = value
            _ = try encoded(next) // Validate the entire record before touching a desktop.
            try persist(next)
            document = next
            didWrite = true
            inFlight[display] = value
            // Existing configure capability keeps the video clock / web document when possible.
            var update: (@MainActor () async throws -> Bool)?
            var configuredRenderer: WallpaperRenderer?
            if runtime.activeWallpaper(on: display)?.id == id {
                _ = runtime.configureActive(wallpaper, on: display) { renderer, _ in
                    if let video = renderer as? VideoRenderer, wallpaper.type == .video {
                        update = { try await video.updateOptions(value.video); return true }
                    } else if let web = renderer as? WebRenderer, wallpaper.type == .web,
                              !value.web.requiresReload(comparedTo: web.options) {
                        update = { try await web.updateOptions(value.web); return true }
                    } else if let scene = renderer as? SceneRenderer, wallpaper.type == .scene {
                        update = {
                            let accepted = try await scene.scene.updatePropertyValues(value.sceneValues)
                            if accepted { scene.applyDisplay(value.sceneFit, frame: value.sceneCustomFrame) }
                            return accepted
                        }
                    } else { return false }
                    configuredRenderer = renderer
                    return true
                }
            }
            let updated = try await update?() ?? false
            if updated, let configuredRenderer {
                guard runtime.configureActive(wallpaper, on: display, configure: { renderer, _ in renderer === configuredRenderer }) else {
                    throw DisplayEditingError.superseded
                }
            } else {
                if runtime.activeWallpaper(on: display)?.id == id { runtime.reloadActive(wallpaper, on: display) }
                else { runtime.apply(wallpaper, to: display) }
                let deadline = ProcessInfo.processInfo.systemUptime + 30
                while runtime.state(of: display)?.preparingWallpaperID != nil {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayEditingError.timedOut }
                    try await Task.sleep(nanoseconds: 16_000_000)
                }
                guard runtime.hasDisplay(display) else { throw DisplayEditingError.unavailable }
                if let failure = runtime.lastFailure, failure.displayID == display, failure.wallpaperID == id {
                    throw DisplayApplyFailure(failure.detail)
                }
                guard runtime.activeWallpaper(on: display)?.id == id else { throw DisplayEditingError.superseded }
                if let expected = inFlightRenderers[display] {
                    guard runtime.configureActive(wallpaper, on: display, configure: { renderer, _ in renderer === expected }) else {
                        throw DisplayEditingError.superseded
                    }
                }
            }
            guard runtime.hasDisplay(display) else { throw DisplayEditingError.unavailable }
            guard revision == configurationRevisions[id, default: 0] else { throw DisplayEditingError.superseded }
            applied[display] = value
            // Keep edits made during preparation instead of erasing a newer draft.
            if drafts[display] == originalDraft { drafts[display] = value }
        } catch {
            if didWrite, document.displays[display.rawValue]?[id.uuidString] == value {
                var rollback = document
                rollback.displays[display.rawValue]?[id.uuidString] = previousRecord
                do { try persist(rollback); document = rollback }
                catch { loadError = DisplayEditingError.unreadable.localizedDescription }
            }
            errors[display] = error.localizedDescription
        }
    }

    private func synchronize(_ summary: RuntimeSummary) {
        for display in summary.displays {
            let next = display.runtime.activeWallpaperID.flatMap { library.wallpaper(id: $0) }
                .map { configuration(for: $0, on: display.id) } ?? .init()
            let clean = drafts[display.id] == nil || drafts[display.id] == applied[display.id]
            // A different wallpaper applied anywhere else replaces an unapplied draft (user decision 2026-10-08).
            let replaced = next.wallpaperID != nil && next.wallpaperID != applied[display.id]?.wallpaperID
            if !applying.contains(display.id) {
                applied[display.id] = next
                if clean || replaced { drafts[display.id] = next }
            }
        }
    }
    /// Re-applying the wallpaper already showing (from 本地, the menu bar …) also brings the preview back to it
    /// (user decision 2026-10-08). A different wallpaper is followed by `synchronize` once it is showing.
    private func followReapply(on display: DisplayID, wallpaperID: Wallpaper.ID) {
        guard !applying.contains(display), let current = applied[display], current.wallpaperID == wallpaperID,
              drafts[display] != current else { return }
        drafts[display] = current
    }
    private func resetOverrides(keys: Set<String>, type: WallpaperType) {
        guard !keys.isEmpty else { return }
        for key in keys {
            if let id = UUID(uuidString: key) { configurationRevisions[id, default: 0] += 1 }
        }
        inFlight = inFlight.filter { !keys.contains($0.value.wallpaperID?.uuidString ?? "") }
        for display in document.displays.keys {
            for key in keys { document.displays[display]?[key] = nil }
        }
        try? persist(document)
        synchronize(runtime.summary)
    }
    private func encoded(_ document: Document) throws -> Data {
        guard document.version == 1, document.displays.count <= 256,
              document.displays.values.reduce(0, { $0 + $1.count }) <= 10_000 else { throw DisplayEditingError.unreadable }
        for (display, records) in document.displays {
            guard !display.isEmpty, display.utf8.count <= 256 else { throw DisplayEditingError.unreadable }
            for (key, value) in records {
                guard let id = UUID(uuidString: key), value.wallpaperID == id,
                      value.sceneValues.count <= ScenePropertySchema.maximumProperties,
                      value.sceneCustomFrame?.isValid ?? true else { throw DisplayEditingError.unreadable }
                _ = try value.video.validated(); _ = try value.web.validated()
            }
        }
        var persisted = document
        // DisplayRegistry already marks this fallback as session-only. Keep its
        // draft usable in memory without pretending it is a stable saved identity.
        persisted.displays = persisted.displays.filter { !$0.key.hasPrefix("session-display-") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(persisted)
        guard data.count <= Self.maximumBytes else { throw DisplayEditingError.unreadable }
        return data
    }
    private func persist(_ document: Document) throws {
        guard loadError == nil else { throw DisplayEditingError.unreadable }
        let data = try encoded(document)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let info = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= Self.maximumBytes else { throw DisplayEditingError.unreadable }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let value = try JSONDecoder().decode(Document.self, from: data)
            guard value.version == 1 else { throw DisplayEditingError.unreadable }
            _ = try encoded(value)
            for records in value.displays.values {
                for configuration in records.values {
                    _ = try configuration.video.validated(); _ = try configuration.web.validated()
                }
            }
            document = value
        } catch { loadError = DisplayEditingError.unreadable.localizedDescription }
    }
}

private struct DisplayApplyFailure: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}
