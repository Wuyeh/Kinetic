import Foundation

/// Per-runtime admission budgets. Limits are checked before allocating decoded or GPU storage.
public struct SceneLimits: Sendable {
    public var maximumPackageEntries = 65_536
    public var maximumPackageIndexBytes = 16 * 1_024 * 1_024
    public var maximumAssetBytes = 64 * 1_024 * 1_024
    public var maximumJSONBytes = 8 * 1_024 * 1_024
    public var maximumJSONDepth = 32
    public var maximumJSONNodes = 200_000
    public var maximumObjects = 2_048
    public var maximumTextureEdge = 8_192
    public var maximumTextureBytes = 128 * 1_024 * 1_024
    public var maximumResidentBytes = 256 * 1_024 * 1_024
    public var maximumReferenceDepth = 16
    public var maximumShaderBytes = 256 * 1_024
    public var maximumShaderPrograms = 32
    public var maximumParticlesPerEmitter = 4_096
    public var maximumSceneParticles = 16_384
    public var maximumPuppetVertices = 65_536
    public var maximumPuppetBones = 256
    public var maximumPuppetKeys = 200_000
    public var preparationTimeout: TimeInterval = 15
    public init() {}
    func validate() throws {
        let counts = [maximumPackageEntries, maximumPackageIndexBytes, maximumAssetBytes, maximumJSONBytes,
            maximumJSONDepth, maximumJSONNodes, maximumObjects, maximumTextureEdge, maximumTextureBytes,
            maximumResidentBytes, maximumReferenceDepth, maximumShaderBytes, maximumShaderPrograms,
            maximumParticlesPerEmitter, maximumSceneParticles, maximumPuppetVertices, maximumPuppetBones, maximumPuppetKeys]
        guard counts.allSatisfy({ $0 > 0 && $0 <= 1_073_741_824 }), maximumTextureEdge <= 16_384,
              maximumReferenceDepth <= 64, maximumJSONDepth <= 64,
              maximumParticlesPerEmitter <= 16_384, maximumSceneParticles <= 65_536,
              maximumPuppetVertices <= 262_144, maximumPuppetBones <= 512, maximumPuppetKeys <= 1_000_000,
              preparationTimeout.isFinite, preparationTimeout > 0, preparationTimeout <= 60 else {
            throw SceneRuntimeError.budgetExceeded("invalid runtime limits")
        }
    }
}

public enum SceneRuntimeError: Error, Equatable, Sendable, LocalizedError {
    case invalidPath(String)
    case missingAsset(String)
    case malformed(String)
    case budgetExceeded(String)
    case unsupported(String)
    case graphics(String)
    case disposed

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Scene 资源路径不安全：\(path)"
        case .missingAsset(let path): return "Scene 缺少资源：\(path)"
        case .malformed(let detail): return "Scene 文件无效：\(detail)"
        case .budgetExceeded(let detail): return "Scene 超出资源预算：\(detail)"
        case .unsupported(let feature): return "Scene 暂不支持：\(feature)"
        case .graphics(let detail): return "Scene 图形处理失败：\(detail)"
        case .disposed: return "Scene 渲染器已释放。"
        }
    }
}

enum ScenePath {
    static func canonical(_ raw: String) throws -> String {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
              !path.contains(":"), !path.contains("\0"), !path.contains("%"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SceneRuntimeError.invalidPath(raw)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 32,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SceneRuntimeError.invalidPath(raw)
        }
        return components.joined(separator: "/")
    }
}

struct SceneByteReader {
    let data: Data
    private(set) var offset = 0
    var remaining: Int { data.count - offset }
    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SceneRuntimeError.malformed("truncated binary payload") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func uint32() throws -> UInt32 {
        let bytes = try read(4)
        return bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }
    mutating func tag() throws -> String {
        let bytes = try read(9)
        guard bytes.last == 0, let tag = String(data: bytes.dropLast(), encoding: .ascii), tag.count == 8 else {
            throw SceneRuntimeError.malformed("invalid binary tag")
        }
        return tag
    }
}
