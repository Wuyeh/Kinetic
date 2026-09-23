import Foundation

/// Kinetic 自己管理的资料库目录。
/// App Sandbox 下位于容器的 Application Support/Kinetic；测试可注入独立目录。
struct LibraryStorageLocation: Equatable, Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    /// 资料库 metadata 文件。
    var libraryFileURL: URL { rootURL.appendingPathComponent("library.json", isDirectory: false) }

    /// 本地导入内容的管理目录。
    var wallpapersDirectoryURL: URL { rootURL.appendingPathComponent("Wallpapers", isDirectory: true) }

    static func standard(fileManager: FileManager = .default) throws -> LibraryStorageLocation {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
        return LibraryStorageLocation(rootURL: support.appendingPathComponent("Kinetic", isDirectory: true))
    }
}
