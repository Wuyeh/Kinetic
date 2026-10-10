import Foundation

/// Host-facing property metadata. Reuses the engine's ordering, localization and condition parser.
public struct KineticScenePropertySchema: Sendable {
    public struct Property: Identifiable, Equatable, Sendable {
        public var id: String { key }
        public let key: String
        public let kind: String
        public let title: String
        public let defaultValue: WallpaperEngineProjectPropertyValue?
        public let minimum: Double?
        public let maximum: Double?
        public let step: Double?
        public let options: [Option]
    }
    public struct Option: Equatable, Sendable {
        public let title: String
        public let value: WallpaperEngineProjectPropertyValue
    }
    private let schema: WallpaperEngineProjectPropertySchema
    public let properties: [Property]
    public var defaultValues: [String: WallpaperEngineProjectPropertyValue] { schema.defaultValues }

    public init(data: Data) throws {
        schema = try WallpaperEngineProjectPropertySchema.parse(data: data,
            preferredLanguages: ["zh-Hans", "zh-CN", "en"], includeSchemeColor: true)
        properties = schema.properties.filter { !$0.isPromotionalLink }.map { property in
            Property(key: property.key, kind: property.type.rawValue,
                title: WPEPropertyLabelText.clean(property.displayText), defaultValue: property.defaultValue,
                minimum: property.minimum, maximum: property.maximum, step: property.step,
                options: property.options.map { Option(title: WPEPropertyLabelText.clean($0.displayLabel), value: $0.value) })
        }
    }

    public func isVisible(_ key: String, overrides: [String: WallpaperEngineProjectPropertyValue]) -> Bool {
        guard let property = schema.properties.first(where: { $0.key == key }) else { return false }
        return WallpaperEngineProjectPropertySchema.visiblePropertyConditionMatches(
            condition: property.condition, values: schema.effectiveValues(overrides: overrides))
    }

    /// Evaluate each condition once per editor update, preserving author order and label filtering.
    public func visibleProperties(overrides: [String: WallpaperEngineProjectPropertyValue]) -> [Property] {
        let visible = Set(schema.visibleProperties(values: schema.effectiveValues(overrides: overrides)).map(\.key))
        return properties.filter { visible.contains($0.key) }
    }
}
