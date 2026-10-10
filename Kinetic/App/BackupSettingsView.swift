import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Module 50：设置 › 通用 › 备份与恢复。导出写到用户在系统面板里选的位置；恢复先检查、再确认，
/// 退出并重新打开 Kinetic 时才替换（替换前原来的数据另存到资料库的 RestoreSafety 文件夹）。
@MainActor
struct BackupSettingsSection: View {
    let storage: LibraryStorageLocation
    @State private var pending: KineticBackup?
    @State private var message: String?
    @State private var failure: String?

    private static var contentType: UTType { UTType(filenameExtension: KineticBackup.fileExtension) ?? .json }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("备份与恢复").font(.headline)
            Text("备份包含设置、资料库记录与喜爱、壁纸列表、显示器分配与参数、书签、方案、叠加层与组件布局、轮播和定时。不包含壁纸文件本身，也不包含密码、API Key 等钥匙串里的内容。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("导出备份…", action: export).kineticGlassButton()
                Button("从备份恢复…", action: restore).kineticGlassButton()
            }
            if let pending {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("已准备恢复 \(Self.dateText(pending.createdAt)) 的备份，退出并重新打开 Kinetic 后生效。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("取消恢复") { KineticBackupService.cancelPendingRestore(in: storage); refresh() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() { pending = KineticBackupService.pendingRestore(in: storage) }

    private func export() {
        failure = nil; message = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.nameFieldStringValue = "Kinetic 备份 " + Date().formatted(.iso8601.year().month().day()) + "." + KineticBackup.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let backup = try KineticBackupService.make(storage: storage, defaults: .standard, appVersion: version)
            try KineticBackupService.encode(backup).write(to: url, options: .atomic)
            message = "已导出到「\(url.lastPathComponent)」。"
        } catch { failure = "导出失败：" + error.localizedDescription }
    }

    private func restore() {
        failure = nil; message = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.contentType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try KineticBackupService.decode(Data(contentsOf: url))
            guard SetupPrompts.confirm(title: "从备份恢复？",
                message: "备份时间：\(Self.dateText(backup.createdAt))。将替换现在的设置、资料库记录、壁纸列表、显示器设置、书签、方案、叠加层、轮播和定时；壁纸文件不变。原来的数据会另存一份。退出并重新打开 Kinetic 后生效。",
                action: "恢复") else { return }
            try KineticBackupService.stageRestore(backup, in: storage)
            refresh()
            if SetupPrompts.confirm(title: "已准备恢复", message: "现在退出 Kinetic 吗？重新打开后即完成恢复。", action: "退出 Kinetic") {
                NSApp.terminate(nil)
            }
        } catch { failure = error.localizedDescription }
    }

    static func dateText(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}
