import Foundation

/// Module 48：把当前整套设置存成方案，或把方案应用到现在连接的显示器。
///
/// 只经过各模块原来的入口：壁纸与参数走显示器编辑器的应用（验证、保存、Apply 与 Crossfade），
/// 叠加层整台显示器一次写入 OverlayStore，组件布局重新写一份（布局文件没人引用时会被清理），
/// 轮播与定时交给各自的服务。没有连接的显示器跳过。
@MainActor
final class WallpaperSchemeCoordinator {
    let store: SetupStore
    private let runtime: WallpaperRuntimeManager
    private let library: WallpaperLibrary
    private let editor: DisplayWallpaperEditor
    private let playlist: WallpaperPlaylistPlayer
    private let scheduler: WallpaperScheduler
    private let overlays: OverlayStore?
    private let layouts: WidgetLayoutRepository?

    init(store: SetupStore, runtime: WallpaperRuntimeManager, library: WallpaperLibrary, editor: DisplayWallpaperEditor,
         playlist: WallpaperPlaylistPlayer, scheduler: WallpaperScheduler,
         overlays: OverlayStore?, layouts: WidgetLayoutRepository?) {
        self.store = store; self.runtime = runtime; self.library = library; self.editor = editor
        self.playlist = playlist; self.scheduler = scheduler; self.overlays = overlays; self.layouts = layouts
    }

    /// 现在的设置：每台已连接、有稳定 ID 的显示器。
    func capture(name: String) -> WallpaperScheme {
        var scheme = WallpaperScheme(name: name, isAudioEnabled: runtime.isAudioEnabled)
        for display in runtime.summary.displays where !display.id.rawValue.hasPrefix("session-display-") {
            let state = display.runtime
            let wallpaper = (state.activeWallpaperID ?? (state.playbackState == .stopped ? state.lastActiveWallpaperID : nil))
                .flatMap { library.wallpaper(id: $0) }
            var saved = SchemeDisplay()
            saved.configuration = wallpaper.map { editor.configuration(for: $0, on: display.id) }
            saved.isStopped = state.playbackState == .stopped
            saved.isManuallyPaused = runtime.manualPauseRequested(on: display.id)
            saved.isAudioEnabled = runtime.isAudioEnabled(on: display.id)
            saved.overlays = overlays?.configurations.filter { $0.displayID == display.id } ?? []
            for configuration in saved.overlays where configuration.kind == .widgets {
                if case .text(let value) = configuration.parameters["widgetLayout"], let id = UUID(uuidString: value),
                   let layout = try? layouts?.load(id) {
                    saved.widgetLayouts[configuration.id.uuidString] = layout
                }
            }
            saved.playlist = playlist.entries[display.id]?.configuration
            saved.schedule = scheduler.entries[display.id]?.schedule
            scheme.displays[display.id.rawValue] = saved
        }
        return scheme
    }

    @discardableResult
    func saveCurrent(name: String) throws -> UUID { try store.addScheme(capture(name: name)) }

    /// How many of the scheme's displays are connected now, and how many will be skipped.
    func reach(of scheme: WallpaperScheme) -> (connected: Int, skipped: Int) {
        let connected = scheme.displays.keys.filter { runtime.hasDisplay(DisplayID($0)) }.count
        return (connected, scheme.displays.count - connected)
    }

    /// 应用方案（调用方先确认）。返回没能完成的部分，空表示全部完成。
    @discardableResult
    func apply(_ scheme: WallpaperScheme) async -> [String] {
        var failures: [String] = []
        runtime.setAudioEnabled(scheme.isAudioEnabled)
        for key in scheme.displays.keys.sorted() {
            guard let saved = scheme.displays[key] else { continue }
            let display = DisplayID(key)
            guard runtime.hasDisplay(display) else { continue }
            do { try applyOverlays(saved, on: display) } catch { failures.append(error.localizedDescription) }
            if let configuration = saved.configuration {
                if let id = configuration.wallpaperID, library.wallpaper(id: id) != nil {
                    await editor.apply(configuration, on: display)
                    if let error = editor.errors[display] { failures.append(error) }
                } else {
                    failures.append("方案里的一张壁纸已不在资料库中，这块屏幕保留了当前壁纸。")
                }
            }
            if let list = saved.playlist {
                playlist.start(list, on: display, preferred: saved.configuration?.wallpaperID)
            } else {
                playlist.stop(on: display)
            }
            scheduler.setSchedule(saved.schedule, on: display)
            runtime.setAudioEnabled(saved.isAudioEnabled, on: display)
            if saved.isStopped { runtime.stop(.display(display)) }
            else if saved.isManuallyPaused { runtime.pause(.display(display)) }
            else if runtime.manualPauseRequested(on: display) { runtime.resume(.display(display)) }
        }
        return failures
    }

    private func applyOverlays(_ saved: SchemeDisplay, on display: DisplayID) throws {
        guard let overlays else { return }
        let references = WidgetLayoutRepository.references(in: overlays.configurations)
        var written = Set<UUID>()
        var next: [OverlayConfiguration] = []
        for original in saved.overlays {
            var configuration = original
            configuration.id = UUID()
            configuration.displayID = display
            if configuration.kind == .widgets {
                // A board without its saved layout cannot be shown; leave it out rather than store a broken reference.
                guard let layout = saved.widgetLayouts[original.id.uuidString], let layouts else { continue }
                let id = try layouts.write(layout, keeping: references.union(written))
                written.insert(id)
                configuration.parameters["widgetLayout"] = .text(id.uuidString)
            }
            next.append(configuration)
        }
        do { try overlays.replaceConfigurations(on: display, with: next) }
        catch {
            written.forEach { layouts?.discard($0) }
            throw error
        }
    }
}
