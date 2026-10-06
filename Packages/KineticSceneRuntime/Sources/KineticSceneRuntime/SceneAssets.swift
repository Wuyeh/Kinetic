import Darwin
import Foundation

/// Reads only explicit directory roots. openat + O_NOFOLLOW checks every component at open time.
/// Holding the root descriptor also avoids a path replacement escaping the authorized root.
/// Roots are searched in order: the scene's own folder / package first, then additional roots such as the
/// user's Wallpaper Engine `assets` folder (shared shaders, materials, models). Scene-owned files win.
public final class SceneAssetResolver: @unchecked Sendable {
    private struct Root {
        let descriptor: Int32
        let package: ScenePackage?
    }
    private let roots: [Root]
    public let limits: SceneLimits

    public init(root: URL, additionalRoots: [URL] = [], limits: SceneLimits = .init(), includePackages: Bool = true) throws {
        try limits.validate()
        guard additionalRoots.count <= 8 else { throw SceneRuntimeError.budgetExceeded("asset roots") }
        self.limits = limits
        var opened: [Root] = []
        do {
            for url in [root] + additionalRoots {
                guard url.isFileURL else { throw SceneRuntimeError.invalidPath(url.absoluteString) }
                let descriptor = open(url.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw SceneRuntimeError.invalidPath(url.lastPathComponent) }
                // The directory itself is held open; never reopen using an absolute payload path.
                opened.append(Root(descriptor: descriptor, package: nil))
                if !includePackages { continue }
                let packageFD = openat(descriptor, "scene.pkg", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if packageFD >= 0 {
                    let package = try ScenePackage(handle: FileHandle(fileDescriptor: packageFD, closeOnDealloc: true), limits: limits)
                    opened[opened.count - 1] = Root(descriptor: descriptor, package: package)
                } else if errno != ENOENT { throw SceneRuntimeError.invalidPath("scene.pkg") }
            }
            roots = opened
        } catch {
            opened.forEach { close($0.descriptor) }
            throw error
        }
    }
    deinit { roots.forEach { close($0.descriptor) } }

    public func read(_ relativePath: String, maximumBytes: Int? = nil) throws -> Data {
        try read(relativePath, maximumBytes: maximumBytes, in: roots[...])
    }

    /// Reads only from the scene's own root. `project.json` and the scene entry never come from engine assets.
    public func readSceneOwned(_ relativePath: String, maximumBytes: Int? = nil) throws -> Data {
        try read(relativePath, maximumBytes: maximumBytes, in: roots.prefix(1))
    }

    /// Number of searched roots (the scene root plus additional roots).
    public var rootCount: Int { roots.count }

    private func read(_ relativePath: String, maximumBytes: Int?, in searched: ArraySlice<Root>) throws -> Data {
        let path = try ScenePath.canonical(relativePath)
        let limit = min(maximumBytes ?? limits.maximumAssetBytes, limits.maximumAssetBytes)
        guard limit >= 0 else { throw SceneRuntimeError.budgetExceeded("invalid read budget") }
        for root in searched {
            if let data = try readDirectory(path, rootFD: root.descriptor, limit: limit) { return data }
            if let data = try root.package?.read(path, maximumBytes: limit) { return data }
        }
        throw SceneRuntimeError.missingAsset(path)
    }

    private func readDirectory(_ path: String, rootFD: Int32, limit: Int) throws -> Data? {
        let components = path.split(separator: "/").map(String.init)
        var parent = rootFD
        defer { if parent != rootFD { close(parent) } }
        for component in components.dropLast() {
            let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else {
                if errno == ENOENT { return nil }
                throw SceneRuntimeError.invalidPath(path)
            }
            if parent != rootFD { close(parent) }
            parent = child
        }
        let fd = openat(parent, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw SceneRuntimeError.invalidPath(path)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw SceneRuntimeError.invalidPath(path)
        }
        guard info.st_size <= limit else { throw SceneRuntimeError.budgetExceeded(path) }
        // Bound the read even if another process grows the file after fstat.
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw SceneRuntimeError.budgetExceeded(path) }
        guard data.count == info.st_size else { throw SceneRuntimeError.malformed("asset changed during read: \(path)") }
        return data
    }
}

/// PKGV offsets are relative to the end of the index, not the start of the file.
/// This implementation follows the format researched in macos-wallpaperengine;
/// it owns no extraction directory and serializes seek/read on its file handle.
final class ScenePackage: @unchecked Sendable {
    struct Entry { let offset: UInt64; let count: Int }
    // Workshop packages PKGV0001…PKGV0024 share the same length/name/offset/size index; the complete engine
    // reads any PKGV. Accept `PKGV0001`…`PKGV0099` so a future Wallpaper Engine revision does not block every new
    // download; safety comes from the index, path, overlap, bounds and budget checks below, which every version
    // must pass. Implausible identifiers (PKGV0000, PKGV9999, non-digits) stay rejected.
    static let supportedVersions = 1...99
    static func isSupportedMagic(_ magic: String) -> Bool {
        guard magic.count == 8, magic.hasPrefix("PKGV") else { return false }
        let digits = magic.dropFirst(4)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let version = Int(digits) else { return false }
        return supportedVersions.contains(version)
    }
    private let handle: FileHandle
    private let entries: [String: Entry]
    private let lock = NSLock()
    init(handle: FileHandle, limits: SceneLimits) throws {
        self.handle = handle
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw SceneRuntimeError.malformed("PKGV is not a regular file")
        }
        let fileSize = UInt64(info.st_size)
        var indexBytes = 0
        func read(_ count: Int) throws -> Data {
            guard count >= 0, count <= limits.maximumPackageIndexBytes - indexBytes else {
                throw SceneRuntimeError.budgetExceeded("PKGV index")
            }
            let bytes = try handle.read(upToCount: count) ?? Data()
            guard bytes.count == count else { throw SceneRuntimeError.malformed("truncated PKGV index") }
            indexBytes += count
            return bytes
        }
        func uint32() throws -> UInt32 { var reader = SceneByteReader(data: try read(4)); return try reader.uint32() }
        let magicCount = Int(try uint32())
        guard (8...16).contains(magicCount), let magic = String(data: try read(magicCount), encoding: .ascii),
              Self.isSupportedMagic(magic) else {
            throw SceneRuntimeError.unsupported("PKGV version")
        }
        let count = Int(try uint32())
        guard count <= limits.maximumPackageEntries else { throw SceneRuntimeError.budgetExceeded("PKGV entry count") }
        var raw: [(String, UInt64, Int)] = []
        var names = Set<String>()
        for _ in 0..<count {
            let length = Int(try uint32())
            guard (1...1_024).contains(length), let name = String(data: try read(length), encoding: .utf8) else {
                throw SceneRuntimeError.malformed("invalid PKGV entry name")
            }
            let path = try ScenePath.canonical(name)
            guard names.insert(path.lowercased()).inserted else { throw SceneRuntimeError.malformed("duplicate PKGV entry: \(path)") }
            raw.append((path, UInt64(try uint32()), Int(try uint32())))
        }
        let start = UInt64(indexBytes)
        var parsed: [String: Entry] = [:]
        var ranges: [Range<UInt64>] = []
        for (path, offset, length) in raw {
            let absolute = start + offset
            guard absolute <= fileSize, UInt64(length) <= fileSize - absolute else {
                throw SceneRuntimeError.malformed("PKGV entry out of bounds: \(path)")
            }
            if length > 0 { ranges.append(absolute..<(absolute + UInt64(length))) }
            parsed[path.lowercased()] = Entry(offset: absolute, count: length)
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.upperBound > b.lowerBound {
            throw SceneRuntimeError.malformed("overlapping PKGV entries")
        }
        entries = parsed
    }
    func read(_ path: String, maximumBytes: Int) throws -> Data? {
        guard let entry = entries[path.lowercased()] else { return nil }
        guard entry.count <= maximumBytes else { throw SceneRuntimeError.budgetExceeded(path) }
        lock.lock(); defer { lock.unlock() }
        try handle.seek(toOffset: entry.offset)
        let data = try handle.read(upToCount: entry.count) ?? Data()
        guard data.count == entry.count else { throw SceneRuntimeError.malformed("truncated PKGV payload: \(path)") }
        return data
    }
}
