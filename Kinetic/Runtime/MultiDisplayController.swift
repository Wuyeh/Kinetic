import AppKit
import Combine

/// 把稳定显示器发现接到既有 per-display Runtime；不重写状态机、Renderer 或 Crossfade。
@MainActor
final class MultiDisplayController {
    struct Surface {
        let host: DesktopContentHost
        var desktop: DesktopWindowRuntime? = nil
        var realign: @MainActor () -> Void = {}
        var close: @MainActor () -> Void = {}
    }
    typealias SurfaceFactory = @MainActor (DisplayID, @escaping @MainActor () -> DesktopDisplay?) -> Surface

    let registry: DisplayRegistry
    private let runtime: WallpaperRuntimeManager
    private let library: WallpaperLibrary
    private let store: DisplayAssignmentStore
    private let legacy: WallpaperRestorationStore
    private let restoreOnLaunch: Bool
    private let makeSurface: SurfaceFactory
    private var surfaces: [DisplayID: Surface] = [:]
    private var resolvedDisplays: [DisplayID: DesktopDisplay] = [:]
    private var document: DisplayAssignmentDocument
    private var persistentIDs: Set<String>
    private var subscriptions = Set<AnyCancellable>()
    private var reconciling = false
    private var recording = false
    /// Module 57：上次意外退出前刚换上的壁纸，这台显示器以停止状态加入、不自动恢复（可以重新启用）。
    var restoreHold: ((DisplayID, Wallpaper.ID) -> Bool)?

    init(registry: DisplayRegistry, runtime: WallpaperRuntimeManager, library: WallpaperLibrary,
         store: DisplayAssignmentStore, legacy: WallpaperRestorationStore,
         restoreOnLaunch: Bool = true, makeSurface: @escaping SurfaceFactory = { MultiDisplayController.desktopSurface(id: $0, resolve: $1) }) {
        self.registry = registry
        self.runtime = runtime
        self.library = library
        self.store = store
        self.legacy = legacy
        self.restoreOnLaunch = restoreOnLaunch
        self.makeSurface = makeSurface
        document = restoreOnLaunch ? store.load() : DisplayAssignmentDocument(hasMigratedLegacy: true)
        persistentIDs = Set(document.assignments.keys)
    }

    func start() {
        guard !recording else { return }
        recording = true
        registry.$displays.sink { [weak self] in self?.reconcile($0) }.store(in: &subscriptions)
        runtime.$summary.sink { [weak self] summary in
            guard let self, self.recording, !self.reconciling else { return }
            for display in summary.displays { self.remember(display) }
            self.save()
        }.store(in: &subscriptions)
        runtime.$globalUserCommand.dropFirst().sink { [weak self] command in
            guard let self, let command, self.recording else { return }
            // 全局控制期间已断开的设备也继承当前用户意图；单台显示器命令不影响其他设备。
            for key in self.document.assignments.keys where !self.runtime.hasDisplay(DisplayID(key)) {
                guard var record = self.document.assignments[key] else { continue }
                switch command {
                case .pause: record.isManuallyPaused = true
                case .resume: record.isManuallyPaused = false
                case .stop: record.isStopped = true; record.isManuallyPaused = false
                case .reenable: record.isStopped = false; record.isManuallyPaused = false
                }
                self.document.assignments[key] = record
            }
            self.save()
        }.store(in: &subscriptions)
        registry.start()
    }

    /// 退出前先断开记录，避免 shutdown 被保存为用户主动 Stop。
    func stopRecording() {
        recording = false
        subscriptions.removeAll()
        registry.stop()
    }

    func closeSurfaces() {
        surfaces.values.forEach { $0.close() }
        surfaces.removeAll()
    }

    func surface(on id: DisplayID) -> Surface? { surfaces[id] }

    private func reconcile(_ displays: [DisplayDescriptor]) {
        guard recording, !reconciling else { return }
        reconciling = true
        defer { reconciling = false; save() }
        let connected = Set(displays.map(\.id))
        // @Published 在 willSet 时通知。Resolver 必须读取本次快照，不能回读 Registry 的上一帧。
        resolvedDisplays = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.desktop) })
        persistentIDs.formUnion(displays.filter(\.isPersistent).map { $0.id.rawValue })
        if !document.hasMigratedLegacy, let primary = displays.first {
            // v0.1 只有主屏记录；只迁移一次，不能在每次陌生屏接入时复制旧壁纸。
            if let record = legacy.load(), document.assignments[primary.id.rawValue] == nil {
                document.assignments[primary.id.rawValue] = record
            }
            document.hasMigratedLegacy = true
        }
        for id in runtime.displayIDs where !connected.contains(id) {
            if let snapshot = runtime.summary.displays.first(where: { $0.id == id }) { remember(snapshot, includePending: true) }
            runtime.removeDisplay(id)
            surfaces.removeValue(forKey: id)?.close()
        }
        for display in displays {
            if let surface = surfaces[display.id] {
                runtime.addDisplay(display.id, name: display.name, host: surface.host,
                                   frame: display.desktop.frame, scaleFactor: display.desktop.backingScaleFactor)
                surface.realign()
                continue
            }
            let id = display.id
            let surface = makeSurface(id, { [weak self] in self?.resolvedDisplays[id] })
            let record = document.assignments[display.id.rawValue]
            let wallpaper = record.flatMap { library.wallpaper(id: $0.wallpaperID) }.flatMap {
                $0.supportState == .supported && WallpaperRuntimeManager.isRendererAvailable(for: $0.type) ? $0 : nil
            }
            let held = wallpaper.map { restoreHold?(display.id, $0.id) == true } ?? false
            guard runtime.addDisplay(display.id, name: display.name, host: surface.host,
                                     frame: display.desktop.frame, scaleFactor: display.desktop.backingScaleFactor,
                                     stoppedWallpaper: record?.isStopped == true || held ? wallpaper : nil) else {
                surface.close(); continue
            }
            surfaces[display.id] = surface
            if let record, !record.isStopped, !held, let wallpaper {
                runtime.apply(wallpaper, to: display.id)
                if record.isManuallyPaused { runtime.pause(.display(display.id)) }
            }
        }
        runtime.updateDisplayOrder(displays.map(\.id))
    }

    private func remember(_ display: DisplayRuntimeState, includePending: Bool = false) {
        let state = display.runtime
        let stopped = state.playbackState == .stopped
        // 若首次 Prepare 时断开，记住用户明确选择的候选；已有 Active 时继续记住旧 Active。
        guard let id = state.activeWallpaperID ?? (stopped ? state.lastActiveWallpaperID : (includePending ? state.preparingWallpaperID : nil)) else { return }
        document.assignments[display.id.rawValue] = WallpaperRestorationRecord(
            wallpaperID: id, isStopped: stopped, isManuallyPaused: runtime.manualPauseRequested(on: display.id))
    }

    private func save() {
        guard restoreOnLaunch else { return }
        var saved = document
        saved.assignments = saved.assignments.filter { persistentIDs.contains($0.key) }
        if saved != store.load() { store.save(saved) }
    }

    static func desktopSurface(id: DisplayID, resolve: @escaping @MainActor () -> DesktopDisplay?) -> Surface {
        let surface = DisplayDesktopSurface(
            windowIdentifier: NSUserInterfaceItemIdentifier(AppDelegate.desktopWallpaperWindowIdentifier.rawValue + "." + id.rawValue),
            resolveDisplay: resolve)
        return Surface(host: surface.host, desktop: surface.desktop, realign: {
            // 仅重新对齐同一个舞台。显示器排列 / 分辨率变化不重新 Prepare Renderer。
            if !surface.host.stage.contents.isEmpty { surface.desktop.present(surface.host.stage) }
        }, close: { surface.desktop.stop() })
    }

    static func closeOrphanedSurfaces() {
        let prefix = AppDelegate.desktopWallpaperWindowIdentifier.rawValue + "."
        for window in NSApp.windows where window is DesktopWallpaperWindow {
            guard let id = window.identifier, id.rawValue.hasPrefix(prefix) else { continue }
            DesktopWindowRuntime.closeOrphanedWindows(in: [window], identifier: id)
        }
    }
}
