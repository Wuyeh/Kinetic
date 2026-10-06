#if DEBUG
import Foundation

/// 仅 Debug（scheme `Kinetic-Module11`，参数 `--card-states-demo`）：
/// 使用独立的演示资料库检查卡片的 Normal / Hover / Selected / Active / Unsupported，不读写正式资料库。
@MainActor
enum CardStatesDemoLibrary {
    static let launchArgument = "--card-states-demo"

    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    static func storage() throws -> LibraryStorageLocation {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return LibraryStorageLocation(rootURL: support.appendingPathComponent("Kinetic-Acceptance/Module11", isDirectory: true))
    }

    /// 演示资料库为空时，用仓库测试素材填充：两段视频、一个网页文件夹，以及一条场景记录。
    static func seedIfNeeded(library: WallpaperLibrary, importer: LocalImportService) async {
        guard library.wallpapers.isEmpty else { return }
        let samples: [(name: String, ext: String?, title: String)] = [
            ("loop", "mp4", "card.demo.video.blue"),
            ("loop-warm", "mp4", "card.demo.video.warm"),
            ("web-sample", nil, "card.demo.web")
        ]
        for sample in samples {
            guard let url = Bundle.main.url(forResource: sample.name, withExtension: sample.ext, subdirectory: "Fixtures"),
                  var wallpaper = await importer.importItem(at: url).wallpaper else { continue }
            wallpaper.name = NSLocalizedString(sample.title, comment: "")
            try? library.update(wallpaper)
        }
        // 场景壁纸只作为 Unsupported 记录，借用网页示例的预览图。
        let scene = Wallpaper(
            name: NSLocalizedString("card.demo.scene", comment: ""),
            type: .scene,
            source: .steam,
            resourceURL: library.storage.wallpapersDirectoryURL.appendingPathComponent("scene-demo", isDirectory: true),
            thumbnailURL: library.wallpapers.first { $0.type == .web }?.thumbnailURL,
            steamMetadata: SteamMetadata(workshopID: "0", author: NSLocalizedString("card.demo.author", comment: ""))
        )
        try? library.add(scene)
    }

    /// Module 21 独立验收资料库：正常视频与损坏视频，真实经过产品错误提示和重试入口。
    static func seedRecoveryIfNeeded(library: WallpaperLibrary, importer: LocalImportService) async {
        guard library.wallpapers.isEmpty else { return }
        for name in ["loop", "loop-warm"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures") else { continue }
            _ = await importer.importItem(at: url)
        }
        guard let url = Bundle.main.url(forResource: "corrupt", withExtension: "mp4", subdirectory: "Fixtures") else { return }
        try? library.add(Wallpaper(name: "损坏视频（恢复验收）", type: .video, source: .local,
                                  resourceURL: url, thumbnailURL: library.wallpapers.first?.thumbnailURL))
    }
}
#endif
