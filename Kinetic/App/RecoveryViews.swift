import AppKit
import SwiftUI

/// Module 57：上次意外退出后，主窗口底部的提示（一次一条）。
struct LaunchRecoveryNotice: View {
    @ObservedObject var recovery: LaunchRecovery

    var body: some View {
        if let item = recovery.held.first {
            RecoveryNotice(
                message: Self.message(item),
                detail: "Kinetic 上次在这张壁纸刚换上后不久意外退出。为避免一打开就再次出问题，这台显示器保持停止，直到你重新启用（这里、显示器页或菜单栏都可以）。",
                actionTitle: "recovery.reenable",
                action: { recovery.reenable(item) },
                dismiss: { recovery.dismiss(item) }
            )
        }
    }

    static func message(_ item: HeldWallpaper) -> String {
        let wallpaper = item.wallpaperName.isEmpty ? "上次的壁纸" : "「\(item.wallpaperName)」"
        let display = item.displayName.isEmpty ? "这台显示器" : "「\(item.displayName)」"
        return "上次 Kinetic 意外退出，\(wallpaper)这次没有在\(display)上自动恢复。"
    }
}

/// Module 57：设置 › 通用「最近的问题」。
struct RecentProblemsSection: View {
    @ObservedObject var log: ProblemLog
    let displayCount: () -> Int
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近的问题").font(.headline)
            if log.records.isEmpty {
                Text("最近没有问题。壁纸没能加载、Kinetic 意外退出或资料库读取失败时会记在这里。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(log.records) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(record.title).font(.body.weight(.semibold))
                                Text(Self.dateText(record.date)).foregroundStyle(.secondary)
                            }
                            Text(Self.subtitle(record)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Button(copied ? "已复制" : "复制诊断信息", action: copy).kineticGlassButton()
                if !log.records.isEmpty {
                    Button("清除记录", action: log.clear).kineticGlassButton()
                }
            }
            Text("诊断信息只包含 Kinetic 和 macOS 的版本、显示器数量和上面这些记录，文件路径会被去掉。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy() {
        let info = Bundle.main.infoDictionary ?? [:]
        let text = DiagnosticsReport.text(
            records: log.records,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            displayCount: displayCount())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    static func subtitle(_ record: ProblemRecord) -> String {
        var parts: [String] = []
        if let display = record.displayName, !display.isEmpty { parts.append("显示器：\(display)") }
        if let wallpaper = record.wallpaperName, !wallpaper.isEmpty { parts.append("壁纸：\(wallpaper)") }
        parts.append(DiagnosticsReport.scrubPaths(record.message))
        return parts.joined(separator: " · ")
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
