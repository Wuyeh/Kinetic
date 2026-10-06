import Foundation
import CoreFoundation

public indirect enum SceneJSON: Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([SceneJSON]), object([String: SceneJSON])
    public subscript(_ key: String) -> SceneJSON { if case .object(let fields) = self { return fields[key] ?? .null }; return .null }
    public var object: [String: SceneJSON]? { if case .object(let value) = self { return value }; return nil }
    public var array: [SceneJSON]? { if case .array(let value) = self { return value }; return nil }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var seed: SceneJSON { if object?["value"] != nil { return self["value"] }; return self }

    public static func parse(_ data: Data, limits: SceneLimits = .init()) throws -> SceneJSON {
        try limits.validate()
        guard data.count <= limits.maximumJSONBytes else { throw SceneRuntimeError.budgetExceeded("JSON bytes") }
        var depth = 0, inString = false, escaped = false
        // Reject excessive nesting before JSONSerialization constructs the object graph.
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= limits.maximumJSONDepth else { throw SceneRuntimeError.budgetExceeded("JSON nesting") }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw SceneRuntimeError.malformed("invalid JSON") }
        var nodes = 0
        func convert(_ raw: Any) throws -> SceneJSON {
            nodes += 1
            guard nodes <= limits.maximumJSONNodes else { throw SceneRuntimeError.budgetExceeded("JSON node count") }
            if raw is NSNull { return .null }
            if let value = raw as? String { return .string(value) }
            if let value = raw as? NSNumber {
                if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
                guard value.doubleValue.isFinite else { throw SceneRuntimeError.malformed("non-finite JSON number") }
                return .number(value.doubleValue)
            }
            if let value = raw as? [Any] { return .array(try value.map(convert)) }
            if let value = raw as? [String: Any] { return .object(try value.mapValues(convert)) }
            throw SceneRuntimeError.malformed("invalid JSON value")
        }
        return try convert(raw)
    }
}
