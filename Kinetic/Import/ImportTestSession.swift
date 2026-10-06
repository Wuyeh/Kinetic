#if DEBUG
import AppKit
import Combine

/// 仅 Kinetic-Module8 验收 scheme 启用的调试面板；不是产品 UI。
/// 使用独立验收目录；「从 Mac 导入…」调用正式的系统打开面板与导入服务。
@MainActor
final class ImportTestSession: NSObject {
    private let library: WallpaperLibrary
    private let importer: LocalImportService
    private let runtime: WallpaperRuntimeManager
    private var panel: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let list = NSTextField(wrappingLabelWithString: "")
    private let report = NSTextField(wrappingLabelWithString: "")
    private var subscriptions: Set<AnyCancellable> = []

    init(library: WallpaperLibrary, runtime: WallpaperRuntimeManager) {
        self.library = library
        self.importer = LocalImportService(library: library)
        self.runtime = runtime
    }

    static func acceptanceStorage() throws -> LibraryStorageLocation {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return LibraryStorageLocation(rootURL: support.appendingPathComponent("Kinetic-Acceptance/Module8", isDirectory: true))
    }

    func start() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("import.test.title", comment: "")
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        let buttons = NSStackView(views: [
            button("import.test.import", #selector(importFromMac)),
            button("import.test.applyNewest", #selector(applyNewest)),
            button("import.test.stop", #selector(stopWallpaper)),
            button("import.test.clear", #selector(clearAcceptance))
        ])
        status.font = .systemFont(ofSize: 12)
        report.font = .systemFont(ofSize: 12)
        list.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let stack = NSStackView(views: [status, buttons, report, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        report.stringValue = NSLocalizedString("import.test.noReport", comment: "")

        library.$wallpapers.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        runtime.$state.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        runtime.$lastFailure.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        refresh()
    }

    func stop() {
        subscriptions.removeAll()
        panel?.close()
        panel = nil
    }

    private func button(_ key: String, _ action: Selector) -> NSButton {
        NSButton(title: NSLocalizedString(key, comment: ""), target: self, action: action)
    }

    @objc private func importFromMac() {
        Task { @MainActor in
            let urls = await LocalImportPanel.chooseItems(attachedTo: panel)
            guard !urls.isEmpty else { return }
            report.stringValue = NSLocalizedString("import.test.importing", comment: "")
            let outcomes = await importer.importItems(at: urls)
            report.stringValue = outcomes.map(describe).joined(separator: "\n")
            refresh()
        }
    }

    private func describe(_ outcome: LocalImportOutcome) -> String {
        let unchanged = NSLocalizedString(outcome.sourceUnchanged ? "runtime.test.yes" : "runtime.test.no", comment: "")
        switch outcome.result {
        case .success(let wallpaper):
            let playable = WallpaperRuntimeManager.isRendererAvailable(for: wallpaper.type)
                ? "" : NSLocalizedString("import.test.notPlayable", comment: "")
            return String(format: NSLocalizedString("import.test.imported", comment: ""),
                          outcome.sourceURL.path, wallpaper.type.localizedName, playable, unchanged)
        case .failure(let error):
            return String(format: NSLocalizedString("import.test.failed", comment: ""),
                          outcome.sourceURL.path, error.localizedDescription, unchanged)
        }
    }

    @objc private func applyNewest() {
        guard let newest = library.wallpapers.first else { return }
        runtime.apply(newest)
    }

    @objc private func stopWallpaper() { runtime.stop() }

    /// 先停止壁纸（Renderer 不再持有文件），再移除验收资料库记录与验收目录中的已导入内容。
    @objc private func clearAcceptance() {
        runtime.stop()
        do {
            for wallpaper in library.wallpapers { try library.remove(id: wallpaper.id) }
            try? FileManager.default.removeItem(at: library.storage.wallpapersDirectoryURL)
        } catch {
            report.stringValue = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        let none = NSLocalizedString("runtime.test.none", comment: "")
        status.stringValue = String(
            format: NSLocalizedString("import.test.status", comment: ""),
            library.storage.wallpapersDirectoryURL.path,
            library.wallpapers.count,
            NSLocalizedString("runtime.state.\(runtime.state.playbackState.rawValue)", comment: ""),
            runtime.activeWallpaper?.name ?? none,
            runtime.lastFailure.map { "\($0.message)（\($0.detail)）" } ?? none
        )
        let root = library.storage.wallpapersDirectoryURL.path + "/"
        list.stringValue = library.wallpapers.isEmpty
            ? NSLocalizedString("library.test.empty", comment: "")
            : library.wallpapers.map { wallpaper in
                let playable = WallpaperRuntimeManager.isRendererAvailable(for: wallpaper.type)
                    ? "" : NSLocalizedString("import.test.notPlayable", comment: "")
                let path = wallpaper.resourceURL.path.replacingOccurrences(of: root, with: "")
                let preview = wallpaper.thumbnailURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
                    ? NSLocalizedString("import.test.hasPreview", comment: "") : NSLocalizedString("import.test.noPreview", comment: "")
                return "\(wallpaper.name) · \(wallpaper.type.localizedName)\(playable) · \(preview)\n    \(path)"
            }.joined(separator: "\n")
    }
}
#endif
