import Foundation
import UniformTypeIdentifiers

/// Kinetic 1.0 Module 8：可以作为视频壁纸的文件格式。导入、VideoRenderer 与悬停预览共用这一份清单。
///
/// 规格第 8、26 节：MP4 / MOV / M4V。三者都由 AVFoundation 解码，M4V 已经过 VideoRenderer 实测；
/// 每个文件导入前仍要逐个验证可播放（受版权保护的视频拒绝）。其他格式在经过 Runtime 验证之前一律不接受。
enum VideoFormats {
    static let fileExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 文件面板中可以选择的类型。
    static let contentTypes: [UTType] = {
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie]
        if let m4v = UTType(filenameExtension: "m4v"), !types.contains(m4v) { types.append(m4v) }
        return types
    }()

    /// 只看扩展名（不读取文件）。
    static func hasVideoExtension(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }
}
