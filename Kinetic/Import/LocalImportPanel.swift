import AppKit
import UniformTypeIdentifiers

/// Module 8：「从 Mac 导入…」使用的系统打开面板。
/// 只负责让用户选择项目；复制与入库由 LocalImportService 完成。
/// 界面入口（Floating Toolbar ＋、Menu Bar）属于 Module 15 / 16，届时直接调用这里。
@MainActor
enum LocalImportPanel {
    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("import.panel.title", comment: "")
        panel.message = NSLocalizedString("import.panel.message", comment: "")
        panel.prompt = NSLocalizedString("import.panel.prompt", comment: "")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = VideoFormats.contentTypes + [.folder]
        return panel
    }

    /// 返回用户选择的项目；取消时返回空数组。
    static func chooseItems(attachedTo window: NSWindow?) async -> [URL] {
        let panel = makePanel()
        guard let window else {
            return panel.runModal() == .OK ? panel.urls : []
        }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.urls : [])
            }
        }
    }
}
