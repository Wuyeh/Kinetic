import Foundation

// From upstream LiveWallpaperCore/Schema/GlobalSettings.swift (MIT).
public struct StringDictionaryKey: CodingKey, Sendable {
    public let stringValue: String
    public var intValue: Int? { nil }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer {
    /// One unreadable value drops that entry, not the whole map. `nil` when the key is absent
    /// or not an object — distinct from "present but empty".
    public func decodeLossyStringDictionary<Value: Decodable>(
        forKey key: Key
    ) -> [String: Value]? {
        guard contains(key) else { return nil }
        guard let nested = try? nestedContainer(keyedBy: StringDictionaryKey.self, forKey: key) else {
            return nil
        }
        var result: [String: Value] = [:]
        for nestedKey in nested.allKeys {
            guard let value = try? nested.decode(Value.self, forKey: nestedKey) else { continue }
            result[nestedKey.stringValue] = value
        }
        return result
    }
}
