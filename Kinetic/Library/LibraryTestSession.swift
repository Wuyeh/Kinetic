#if DEBUG
import AppKit
import Combine

/// 仅 Kinetic-Module7 验收 scheme 启用的调试面板；不是产品 UI（Sidebar / Grid 属于 Module 10–14）。
/// 使用独立的验收资料库目录，不写入正式资料库。
@MainActor
final class LibraryTestSession: NSObject, NSSearchFieldDelegate {
    private let library: WallpaperLibrary
    private var panel: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let list = NSTextField(wrappingLabelWithString: "")
    private let searchField = NSSearchField()
    private let filterControl = NSSegmentedControl()
    private var subscriptions: Set<AnyCancellable> = []

    init(library: WallpaperLibrary) { self.library = library }

    /// 验收资料库位于正式资料库旁边的独立目录。
    static func acceptanceStorage() throws -> LibraryStorageLocation {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return LibraryStorageLocation(rootURL: support.appendingPathComponent("Kinetic-Acceptance/Module7", isDirectory: true))
    }

    func start() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("library.test.title", comment: "")
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false

        filterControl.segmentCount = LibraryFilter.allCases.count
        for (index, filter) in LibraryFilter.allCases.enumerated() {
            filterControl.setLabel(NSLocalizedString("library.filter.\(filter.rawValue)", comment: ""), forSegment: index)
        }
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(refresh)
        searchField.placeholderString = NSLocalizedString("library.test.search", comment: "")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(refresh)

        let buttons = NSStackView(views: [
            button("library.test.addLocal", #selector(addLocal)),
            button("library.test.addSteam", #selector(addSteam)),
            button("library.test.toggleFavorite", #selector(toggleFirstFavorite)),
            button("library.test.removeFirst", #selector(removeFirst)),
            button("library.test.clear", #selector(clearAll))
        ])
        status.font = .systemFont(ofSize: 12)
        list.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let stack = NSStackView(views: [status, buttons, filterControl, searchField, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        searchField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        panel.contentView = stack
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        library.$wallpapers.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        refresh()
    }

    func stop() {
        subscriptions.removeAll()
        panel?.close()
        panel = nil
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    private func button(_ key: String, _ action: Selector) -> NSButton {
        NSButton(title: NSLocalizedString(key, comment: ""), target: self, action: action)
    }

    private var sampleURL: URL {
        Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "/kinetic-acceptance/loop.mp4")
    }

    @objc private func addLocal() {
        let number = library.wallpapers.count + 1
        let name = String(format: NSLocalizedString("library.test.localName", comment: ""), number)
        perform { try self.library.add(Wallpaper(name: name, type: .video, source: .local, resourceURL: self.sampleURL)) }
    }

    @objc private func addSteam() {
        let number = library.wallpapers.count + 1
        let name = String(format: NSLocalizedString("library.test.steamName", comment: ""), number)
        let metadata = SteamMetadata(workshopID: "\(100_000 + number)",
                                     author: NSLocalizedString("library.test.author", comment: ""))
        perform {
            try self.library.add(Wallpaper(name: name, type: .web, source: .steam,
                                           resourceURL: self.sampleURL, steamMetadata: metadata))
        }
    }

    @objc private func toggleFirstFavorite() {
        guard let first = library.wallpapers.first else { return }
        perform { try self.library.setFavorite(!first.isFavorite, for: first.id) }
    }

    @objc private func removeFirst() {
        guard let first = library.wallpapers.first else { return }
        perform { try self.library.remove(id: first.id) }
    }

    @objc private func clearAll() {
        perform { for wallpaper in self.library.wallpapers { try self.library.remove(id: wallpaper.id) } }
    }

    private func perform(_ change: () throws -> Void) {
        do { try change() } catch { status.stringValue = error.localizedDescription }
        refresh()
    }

    @objc private func refresh() {
        let filter = LibraryFilter.allCases[max(0, filterControl.selectedSegment)]
        let results = library.search(searchField.stringValue, in: filter)
        let fileExists = FileManager.default.fileExists(atPath: library.storage.libraryFileURL.path)
        var lines = [String(format: NSLocalizedString("library.test.status", comment: ""),
                            library.storage.libraryFileURL.path,
                            NSLocalizedString(fileExists ? "runtime.test.yes" : "runtime.test.no", comment: ""),
                            library.wallpapers.count, results.count)]
        if let issue = library.loadIssue {
            lines.append(String(format: NSLocalizedString("library.test.loadIssue", comment: ""),
                                issue.reason, issue.backupURL?.lastPathComponent ?? "—"))
        }
        status.stringValue = lines.joined(separator: "\n")
        list.stringValue = results.isEmpty
            ? NSLocalizedString("library.test.empty", comment: "")
            : results.map { wallpaper in
                let heart = wallpaper.isFavorite ? "♥" : "♡"
                var line = "\(heart) \(wallpaper.name) · \(wallpaper.type.localizedName) · \(wallpaper.acquisitionOrigin.localizedName)"
                if let author = wallpaper.steamMetadata?.author { line += " · \(author)" }
                return line
            }.joined(separator: "\n")
    }
}
#endif
