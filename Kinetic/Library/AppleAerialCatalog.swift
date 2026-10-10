import Combine
import Foundation

/// Holds read-only access while a scan, preview or explicit import uses the folder.
final class AppleAerialAccess: @unchecked Sendable {
    let url: URL
    private let started: Bool
    init(_ url: URL) { self.url = url; started = url.startAccessingSecurityScopedResource() }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

@MainActor
final class AppleAerialCatalog: ObservableObject {
    private struct Document: Codable { var version = 1; var bookmark: Data }
    @Published private(set) var assets: [AppleAerialAsset] = []
    @Published private(set) var isScanning = false
    @Published private(set) var error: String?
    @Published private(set) var metadataUnavailable = false
    private(set) var access: AppleAerialAccess?
    private(set) var loadError: String?
    let fileURL: URL
    private var bookmark: Data?
    private let bookmarks: EngineAssetsBookmarks
    private let defaultFolders: [URL]
    private let scanner: @Sendable (URL) throws -> AppleAerialScan
    private var task: Task<AppleAerialScan, Error>?
    private var generation = UUID()

    init(storage: LibraryStorageLocation, bookmarks: EngineAssetsBookmarks = .securityScoped,
         defaultFolders: [URL] = AppleAerialCatalog.standardFolders(),
         scanner: @escaping @Sendable (URL) throws -> AppleAerialScan = { try AppleAerialScanner.scan($0) }) {
        self.bookmarks = bookmarks; self.defaultFolders = defaultFolders; self.scanner = scanner
        fileURL = storage.rootURL.appendingPathComponent("apple-aerials.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let info = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 1_024 * 1_024 else { throw AppleAerialError.settingsUnreadable }
                let data = try Data(contentsOf: fileURL)
                guard data.count <= 1_024 * 1_024 else { throw AppleAerialError.settingsUnreadable }
                let value = try JSONDecoder().decode(Document.self, from: data)
                guard value.version == 1 else { throw AppleAerialError.settingsUnreadable }
                bookmark = value.bookmark
            } catch { loadError = AppleAerialError.settingsUnreadable.localizedDescription; self.error = loadError }
        }
    }
    nonisolated static func standardFolders() -> [URL] {
        var result = [URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true),
                      URL(fileURLWithPath: "/Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)]
        if let home = NSHomeDirectoryForUser(NSUserName()) {
            result.insert(URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials"), at: 0)
        }
        return result
    }
    /// Only called with a folder chosen in the system panel. No remote resources or system writes.
    func link(_ folder: URL) throws {
        guard loadError == nil else { throw AppleAerialError.settingsUnreadable }
        let access = AppleAerialAccess(folder)
        let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw AppleAerialError.inaccessible }
        _ = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let data = try bookmarks.make(folder)
        let document = try JSONEncoder().encode(Document(bookmark: data))
        guard document.count <= 1_024 * 1_024 else { throw AppleAerialError.settingsUnreadable }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.write(to: fileURL, options: .atomic)
        cancelScan(); bookmark = data; self.access = access; assets = []; error = nil
    }
    func refresh() async {
        cancelScan(); let token = generation
        guard loadError == nil else { error = loadError; return }
        do {
            if access == nil {
                if let bookmark {
                    let resolved = try bookmarks.resolve(bookmark)
                    access = AppleAerialAccess(resolved.url)
                    // An old bookmark remains usable; refresh atomically when possible.
                    if resolved.isStale, let data = try? bookmarks.make(resolved.url),
                       let encoded = try? JSONEncoder().encode(Document(bookmark: data)), encoded.count <= 1_024 * 1_024,
                       (try? encoded.write(to: fileURL, options: .atomic)) != nil { self.bookmark = data }
                } else if let folder = defaultFolders.first(where: { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) != nil }) {
                    access = AppleAerialAccess(folder)
                }
            }
            guard let access else { throw AppleAerialError.inaccessible }
            isScanning = true; error = nil
            let scanner = scanner
            let work = Task.detached(priority: .userInitiated) {
                defer { withExtendedLifetime(access) {} }
                return try scanner(access.url)
            }
            task = work
            let result = try await work.value
            guard generation == token else { return }
            assets = result.assets; metadataUnavailable = result.metadataUnavailable
            isScanning = false; task = nil
        } catch {
            guard generation == token else { return }
            self.error = error.localizedDescription; isScanning = false; task = nil
            // A failed refresh keeps the last successful list; actions revalidate the file.
        }
    }
    func validatedAccess(for asset: AppleAerialAsset) throws -> AppleAerialAccess {
        guard let access, assets.contains(asset), AppleAerialScanner.validVideo(asset.url, in: access.url) else { throw AppleAerialError.assetUnavailable }
        return access
    }
    func cancelScan() { generation = UUID(); task?.cancel(); task = nil; isScanning = false }
    deinit { task?.cancel() }
}
