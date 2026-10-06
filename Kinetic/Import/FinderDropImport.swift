import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Kinetic 1.0 Module 8：从 Finder 把视频（或网页壁纸文件夹）拖入主窗口。
///
/// 规格第 8 节：Finder 拖动 → 主窗口反馈 → 松手 → 校验 → 复制到 Kinetic 管理目录 → 生成 Poster → 建立记录 → 加入「本地」→ 成功提示。
/// 只添加到本地资料库：不应用、不改变任何显示器的壁纸、不播放声音。任何页面（包括 Steam 在线商店）都可以拖入，导入后不切换页面。
/// 复制与校验全部交给 `LocalImportService`，与文件面板完全相同。
enum FinderDropEvaluation: Equatable {
    /// 其中可以导入的项目数量。
    case importable(count: Int)
    case unsupported

    /// 拖动中的快速判断，不复制、不解码：视频看扩展名，文件夹看根目录是否有 index.html。
    /// 暂时读不到文件夹内容时先按可导入处理，松手后由 LocalImportService 完整校验。
    @MainActor
    static func evaluate(_ urls: [URL]) -> FinderDropEvaluation {
        let count = urls.filter(isLikelyImportable).count
        return count > 0 ? .importable(count: count) : .unsupported
    }

    @MainActor
    static func isLikelyImportable(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
        guard isDirectory else { return VideoFormats.hasVideoExtension(url) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return true }
        return names.contains { LocalImportService.webEntryNames.contains($0.lowercased()) || $0 == "project.json" }
    }

    var titleKey: String {
        switch self {
        case .importable: return "drop.addToLocal"
        case .unsupported: return "drop.unsupported"
        }
    }

    var symbol: String {
        switch self {
        case .importable: return "plus.rectangle.on.rectangle"
        case .unsupported: return "nosign"
        }
    }

    var dropOperation: DropOperation {
        self == .unsupported ? .forbidden : .copy
    }
}

/// 导入结果的提示文字（文件面板、菜单栏与 Finder 拖入共用）。
struct LocalImportSummary: Equatable {
    /// 成功加入的记录，顺序与导入顺序一致（最后一个是最新的）。
    let addedIDs: [Wallpaper.ID]
    let failureMessages: [String]

    init(outcomes: [LocalImportOutcome]) {
        addedIDs = outcomes.compactMap { $0.wallpaper?.id }
        failureMessages = outcomes.compactMap { outcome in
            if case .failure(let error) = outcome.result { return error.localizedDescription }
            return nil
        }
    }

    var message: String? {
        let added = addedIDs.count, failed = failureMessages.count
        switch (added, failed) {
        case (0, 0):
            return nil
        case (1, 0):
            return NSLocalizedString("import.summary.addedOne", comment: "")
        case (_, 0):
            return String(format: NSLocalizedString("import.summary.addedMany", comment: ""), added)
        case (0, 1):
            return failureMessages[0]
        case (0, _):
            return String(format: NSLocalizedString("import.summary.failedMany", comment: ""), failed, failureMessages[0])
        default:
            return String(format: NSLocalizedString("import.summary.partial", comment: ""), added, failed, failureMessages[0])
        }
    }
}

/// 当前拖动的反馈状态。拖动事件都在主线程。
final class FinderDropState: ObservableObject {
    /// nil：没有拖动，或还在读取拖入的项目。
    @Published fileprivate(set) var feedback: FinderDropEvaluation?
    fileprivate var generation = 0

    fileprivate func reset() {
        generation += 1
        if feedback != nil { feedback = nil }
    }
}

/// 主窗口的 Finder 拖入目标（SwiftUI `onDrop`）。
struct FinderDropDelegate: DropDelegate {
    static let acceptedTypes: [UTType] = [.fileURL]

    let state: FinderDropState
    /// 松手后得到的本机文件；只用于导入。
    let onDrop: @MainActor ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        state.generation += 1
        let token = state.generation
        let state = state
        let providers = info.itemProviders(for: Self.acceptedTypes)
        Task { @MainActor in
            let urls = await Self.loadFileURLs(from: providers)
            guard token == state.generation else { return }
            let evaluation = FinderDropEvaluation.evaluate(urls)
            withAnimation(.easeOut(duration: 0.15)) { state.feedback = evaluation }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: state.feedback?.dropOperation ?? .copy)
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.15)) { state.reset() }
    }

    func performDrop(info: DropInfo) -> Bool {
        let evaluation = state.feedback
        withAnimation(.easeOut(duration: 0.15)) { state.reset() }
        // 已确认没有可导入的项目：拒绝放下（反馈里已经显示「不支持此文件格式」）。
        if evaluation == .unsupported { return false }
        let providers = info.itemProviders(for: Self.acceptedTypes)
        let onDrop = onDrop
        Task { @MainActor in
            let urls = await Self.loadFileURLs(from: providers)
            if !urls.isEmpty { onDrop(urls) }
        }
        return true
    }

    /// 读取拖入的本机文件地址（Finder 的文件引用地址转换为路径地址）；顺序与拖入顺序一致。
    static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadFileURL(from: provider) { urls.append(url) }
        }
        return urls
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else if let string = item as? String {
                    url = URL(string: string)
                }
                guard let url, url.isFileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (url as NSURL).filePathURL ?? url)
            }
        }
    }
}
