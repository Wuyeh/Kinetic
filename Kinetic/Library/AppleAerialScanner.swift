import Foundation

struct AppleAerialScan: Sendable {
    var assets: [AppleAerialAsset]
    var metadataUnavailable: Bool = false
}

enum AppleAerialError: LocalizedError {
    case inaccessible, scanBudget, settingsUnreadable, assetUnavailable, missingLibraryFile
    var errorDescription: String? {
        switch self {
        case .inaccessible: return "无法读取航拍文件夹，请通过系统面板重新选择。"
        case .scanBudget: return "文件夹内容过多，请直接选择航拍视频所在的文件夹。"
        case .settingsUnreadable: return "航拍文件夹设置无法读取，原设置文件已保留。"
        case .assetUnavailable: return "此航拍文件已不可用，请刷新或重新选择文件夹。"
        case .missingLibraryFile: return "资料库中的航拍视频已丢失，请先移除该记录，再重新添加。"
        }
    }
}

/// Reads local files only. Apple cache layout / metadata are optional, not a private API contract.
enum AppleAerialScanner {
    static let maximumEntries = 10_000
    static let maximumMetadataBytes = 4 * 1_024 * 1_024
    static let maximumDepth = 4

    static func contains(_ url: URL, in root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base + "/")
    }
    static func validVideo(_ url: URL, in root: URL) -> Bool {
        guard contains(url, in: root), ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()),
              let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) > 0 else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
    static func scan(_ root: URL) throws -> AppleAerialScan {
        let fm = FileManager.default
        guard root.isFileURL,
              let info = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              info.isDirectory == true, info.isSymbolicLink != true else { throw AppleAerialError.inaccessible }
        // stat alone doesn't establish sandbox access.
        _ = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let metadata = loadMetadata(root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        var enumerationError: Error?
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw AppleAerialError.inaccessible }
        var count = 0, found: [String: AppleAerialAsset] = [:]
        for case let url as URL in entries {
            try Task.checkCancellation()
            count += 1; guard count <= maximumEntries else { throw AppleAerialError.scanBudget }
            let properties = try url.resourceValues(forKeys: Set(keys))
            if properties.isSymbolicLink == true || entries.level > maximumDepth {
                entries.skipDescendants(); continue
            }
            guard validVideo(url, in: root), let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let id = uuid.uuidString, details = metadata.values[id]
            let asset = AppleAerialAsset(id: uuid, url: url, name: details?.name ?? "Apple 航拍 \(id.prefix(8))",
                category: details?.category, sizeInBytes: Int64(properties.fileSize ?? 0))
            // Multiple encodings of one Apple ID represent one item; stable path order, no duplicates.
            if let old = found[id], old.url.path < asset.url.path { continue }
            found[id] = asset
        }
        if let enumerationError { throw enumerationError }
        return AppleAerialScan(assets: found.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }, metadataUnavailable: metadata.unavailable)
    }

    private struct Metadata { var name: String; var category: String? }
    private static func localData(_ relative: String, root: URL, limit: Int) -> Data? {
        let url = root.appendingPathComponent(relative)
        guard contains(url, in: root), let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= limit,
              let data = try? Data(contentsOf: url), data.count <= limit else { return nil }
        return data
    }
    private static func loadMetadata(_ root: URL) -> (values: [String: Metadata], unavailable: Bool) {
        let candidates = ["entries.json", "manifest/entries.json", "Customer/entries.json", "aerials/manifest/entries.json"]
        var data: Data?, prefix = ""
        for path in candidates {
            if let contents = localData(path, root: root, limit: maximumMetadataBytes) {
                data = contents; prefix = (path as NSString).deletingLastPathComponent; break
            }
        }
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = (object["assets"] ?? object["entries"]) as? [[String: Any]], records.count <= maximumEntries else {
            return ([:], true)
        }
        var strings: [String: String] = [:]
        for language in ["zh_CN", "zh-Hans", "zh_Hans", "zh"] {
            let path = (prefix.isEmpty ? "" : prefix + "/") + "TVIdleScreenStrings.bundle/\(language).lproj/Localizable.nocache.strings"
            if let data = localData(path, root: root, limit: maximumMetadataBytes),
               let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
                strings = values; break
            }
        }
        func title(_ record: [String: Any]) -> String? {
            let key = record["localizedNameKey"] as? String
            let value = key.flatMap { strings[$0] } ?? (record["accessibilityLabel"] ?? record["name"] ?? record["displayName"]) as? String
            guard let value, !value.isEmpty, value.count <= 512 else { return nil }
            return value
        }
        var categories: [String: String] = [:]
        for record in object["categories"] as? [[String: Any]] ?? [] {
            if let id = record["id"] as? String, let name = title(record) { categories[id] = name }
        }
        var result: [String: Metadata] = [:]
        for record in records {
            guard let raw = (record["id"] ?? record["uuid"]) as? String, let uuid = UUID(uuidString: raw), let name = title(record) else { continue }
            let category = (record["categories"] as? [String])?.compactMap { categories[$0] }.first
            result[uuid.uuidString] = Metadata(name: name, category: category)
        }
        return (result, false)
    }
}
