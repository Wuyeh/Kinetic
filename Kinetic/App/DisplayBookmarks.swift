import AppKit
import SwiftUI

/// Module 48：显示器页壁纸选择浮窗顶部的「书签」。选中一个书签，它的壁纸和参数进入这块屏幕的草稿
/// （缩略图预览），点「应用」才到桌面。辅助点按可以重命名或删除。
@MainActor
struct DisplayBookmarkList: View {
    let displayID: DisplayID
    @ObservedObject var store: SetupStore
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var editor: DisplayWallpaperEditor
    let onChoose: () -> Void

    var body: some View {
        if !store.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("书签").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 2)
                ScrollView {
                    LazyVStack(spacing: 4) { ForEach(store.bookmarks) { row($0) } }
                }
                .frame(height: min(DisplayControlLayout.pickerMaximumHeight / 2, CGFloat(store.bookmarks.count) * 56))
                Divider()
            }
        }
    }

    private func row(_ bookmark: WallpaperBookmark) -> some View {
        let wallpaper = bookmark.wallpaperID.flatMap { library.wallpaper(id: $0) }
        let usable = wallpaper.map { WallpaperCardVisualState.isPlayable($0) && $0.resourceURL.isFileURL } ?? false
        let chosen = usable && editor.draft(on: displayID) == bookmark.configuration
        return Button {
            if editor.stage(bookmark.configuration, on: displayID) { onChoose() }
        } label: {
            HStack(spacing: 10) {
                DisplayPickerPoster(wallpaper: wallpaper)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bookmark.name).foregroundStyle(usable ? .primary : .secondary).lineLimit(1).truncationMode(.tail)
                    Text(wallpaper?.name ?? "壁纸已不在资料库中").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if chosen { Image(systemName: "checkmark").foregroundStyle(MainWindowDesignTokens.accent) }
            }
            .padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .contextMenu {
            Button("重命名…") { rename(bookmark) }
            Button("删除书签", role: .destructive) { delete(bookmark) }
        }
        .accessibilityLabel("书签 " + bookmark.name + "，" + (wallpaper?.name ?? "壁纸已不在资料库中"))
    }

    private func rename(_ bookmark: WallpaperBookmark) {
        DispatchQueue.main.async {
            guard let name = SetupPrompts.name(title: "重命名书签", message: nil, initial: bookmark.name, confirm: "保存") else { return }
            SetupPrompts.report { try store.renameBookmark(bookmark.id, to: name) }
        }
    }

    private func delete(_ bookmark: WallpaperBookmark) {
        DispatchQueue.main.async {
            guard SetupPrompts.confirm(title: "删除书签“\(bookmark.name)”？", message: "只删除书签，壁纸与当前设置不变。",
                                       action: "删除", destructive: true) else { return }
            SetupPrompts.report { try store.deleteBookmark(bookmark.id) }
        }
    }
}

/// Small native dialogs shared by bookmarks and schemes.
@MainActor
enum SetupPrompts {
    /// A name field; nil when cancelled or left empty.
    static func name(title: String, message: String?, initial: String, confirm: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func confirm(title: String, message: String, action: String, destructive: Bool = false) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let button = alert.addButton(withTitle: action)
        if destructive { button.hasDestructiveAction = true }
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func report(_ action: () throws -> Void) {
        do { try action() } catch { inform(title: "未能完成", message: error.localizedDescription) }
    }

    static func inform(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

/// Module 48 / 规格 34：菜单栏「方案」。保存当前设置为方案、确认后应用、确认后删除。
@MainActor
struct MenuBarSchemeMenu: View {
    let coordinator: WallpaperSchemeCoordinator
    @ObservedObject var store: SetupStore

    var body: some View {
        Menu("方案") {
            Button("保存当前设置为方案…") { save() }
            if !store.schemes.isEmpty {
                Divider()
                ForEach(store.schemes) { scheme in Button(scheme.name) { apply(scheme) } }
                Divider()
                Menu("删除方案") {
                    ForEach(store.schemes) { scheme in Button(scheme.name) { delete(scheme) } }
                }
            }
        }
    }

    private func save() {
        DispatchQueue.main.async {
            let initial = "方案 " + Date().formatted(.dateTime.month().day().hour().minute())
            guard let name = SetupPrompts.name(title: "保存当前设置为方案",
                message: "保存每台显示器的壁纸与参数、暂停与声音、叠加层与组件布局、轮播和定时。",
                initial: initial, confirm: "保存") else { return }
            SetupPrompts.report { try coordinator.saveCurrent(name: name) }
        }
    }

    private func apply(_ scheme: WallpaperScheme) {
        DispatchQueue.main.async {
            let reach = coordinator.reach(of: scheme)
            var message = "将替换 \(reach.connected) 台显示器的壁纸与参数、暂停与声音、叠加层、轮播和定时。"
            if reach.skipped > 0 { message += "其中 \(reach.skipped) 台显示器现在没有连接，将跳过。" }
            guard reach.connected > 0 else {
                SetupPrompts.inform(title: "无法应用方案“\(scheme.name)”", message: "方案里的显示器现在都没有连接。")
                return
            }
            guard SetupPrompts.confirm(title: "应用方案“\(scheme.name)”？", message: message, action: "应用") else { return }
            Task {
                let failures = await coordinator.apply(scheme)
                if !failures.isEmpty {
                    SetupPrompts.inform(title: "方案“\(scheme.name)”部分未能应用", message: failures.joined(separator: "\n"))
                }
            }
        }
    }

    private func delete(_ scheme: WallpaperScheme) {
        DispatchQueue.main.async {
            guard SetupPrompts.confirm(title: "删除方案“\(scheme.name)”？", message: "只删除方案，当前设置与壁纸不变。",
                                       action: "删除", destructive: true) else { return }
            SetupPrompts.report { try coordinator.store.deleteScheme(scheme.id) }
        }
    }
}
