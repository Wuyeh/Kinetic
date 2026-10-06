import Foundation

/// Module 20：随 App 打包的演示壁纸。原创、程序生成的无缝循环视频（生成脚本见 `Tools/DemoWallpapers/`），
/// 不依赖网络。网页演示要等 Web Renderer（Module 4，已暂缓）接入后再加。
struct OnboardingDemo: Identifiable, Equatable {
    let id: String
    let name: String
    let videoURL: URL
    let posterURL: URL?

    /// 引导页卡片用的临时模型：直接指向 App 包内的文件，只用于缩略图与悬停预览，不加入资料库。
    var previewWallpaper: Wallpaper {
        Wallpaper(id: Self.previewID(for: id), name: name, type: .video, source: .local,
                  resourceURL: videoURL, thumbnailURL: posterURL)
    }

    /// 同一演示每次得到相同的标识，悬停预览据此对应卡片。
    static func previewID(for id: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in Array("kinetic.demo.\(id)".utf8).enumerated() {
            bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
        }
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress) as UUID }
    }
}

enum OnboardingDemoCatalog {
    static let identifiers = ["aurora", "dawn", "drift"]
    static let subdirectory = "Demos"

    /// App 包中实际存在的演示；缺少视频的项目直接略过（例如不含视频的公开源码构建）。
    static func bundled(in bundle: Bundle = .main) -> [OnboardingDemo] {
        identifiers.compactMap { id in
            guard let video = bundle.url(forResource: id, withExtension: "mp4", subdirectory: subdirectory) else {
                return nil
            }
            return OnboardingDemo(
                id: id,
                name: NSLocalizedString("onboarding.demo.\(id)", comment: "Demo wallpaper name"),
                videoURL: video,
                posterURL: bundle.url(forResource: id, withExtension: "jpg", subdirectory: subdirectory)
            )
        }
    }
}
