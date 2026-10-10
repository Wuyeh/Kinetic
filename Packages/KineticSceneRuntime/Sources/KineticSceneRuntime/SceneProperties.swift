import Foundation
import KineticWPEEngine

public typealias ScenePropertyValue = WallpaperEngineProjectPropertyValue
public typealias SceneProperty = KineticScenePropertySchema.Property

/// Scene-owned manifest only; no UI, network, mutable source files or extra filesystem permissions.
public struct ScenePropertySchema: Sendable {
    private let schema: KineticScenePropertySchema
    public var properties: [SceneProperty] { schema.properties }
    public var defaultValues: [String: ScenePropertyValue] { schema.defaultValues }
    public var hasEditableProperties: Bool { properties.contains { Self.editableKinds.contains($0.kind) } }
    private static let editableKinds: Set<String> = ["bool", "slider", "combo", "color", "textinput", "file", "directory"]
    public static let maximumProperties = 256

    public static func read(root: URL, limits: SceneLimits = .init()) throws -> Self {
        let assets = try SceneAssetResolver(root: root, limits: limits, includePackages: false)
        return try Self(data: assets.readSceneOwned("project.json", maximumBytes: limits.maximumJSONBytes), limits: limits)
    }
    public init(data: Data, limits: SceneLimits = .init()) throws {
        let project = try SceneJSON.parse(data, limits: limits)
        guard project["type"].string?.lowercased() == "scene" else { throw SceneRuntimeError.malformed("Scene properties manifest") }
        guard (project["general"]["properties"].object?.count ?? 0) <= Self.maximumProperties else {
            throw SceneRuntimeError.budgetExceeded("Scene properties")
        }
        schema = try KineticScenePropertySchema(data: data)
    }
    public func isVisible(_ key: String, overrides: [String: ScenePropertyValue]) -> Bool {
        schema.isVisible(key, overrides: overrides)
    }
    public func visibleProperties(overrides: [String: ScenePropertyValue]) -> [SceneProperty] {
        schema.visibleProperties(overrides: overrides)
    }
    /// Validate the entire transaction before it is saved or sent to a renderer.
    public func validated(_ overrides: [String: ScenePropertyValue]) throws -> [String: ScenePropertyValue] {
        guard overrides.count <= Self.maximumProperties else { throw SceneRuntimeError.budgetExceeded("Scene properties") }
        var result: [String: ScenePropertyValue] = [:]
        for (key, value) in overrides {
            guard let property = properties.first(where: { $0.key == key }), Self.editableKinds.contains(property.kind) else {
                throw SceneRuntimeError.malformed("未声明或不可编辑的场景属性：\(key)")
            }
            func invalid() -> SceneRuntimeError { .malformed("场景属性值无效：\(property.title)") }
            switch (property.kind, value) {
            case ("bool", .bool): break
            case ("slider", .number(let number)):
                guard number.isFinite, number >= (property.minimum ?? -Double.greatestFiniteMagnitude),
                      number <= (property.maximum ?? Double.greatestFiniteMagnitude) else { throw invalid() }
            case ("combo", _):
                guard let option = property.options.first(where: { $0.value.looselyMatches(value) }) else { throw invalid() }
                result[key] = option.value
                continue
            case ("color", .string(let text)):
                let parts = text.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
                guard parts.count == 3, text.split(whereSeparator: { $0.isWhitespace }).count == 3,
                      parts.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw invalid() }
            case ("textinput", .string(let text)), ("file", .string(let text)), ("directory", .string(let text)):
                guard text.utf8.count <= 4_096 else { throw SceneRuntimeError.budgetExceeded(key) }
                if property.kind != "textinput", !text.isEmpty { _ = try ScenePath.canonical(text) }
            default: throw invalid()
            }
            result[key] = value
        }
        guard try JSONEncoder().encode(result).count <= 64 * 1_024 else { throw SceneRuntimeError.budgetExceeded("Scene property values") }
        return result
    }
}
