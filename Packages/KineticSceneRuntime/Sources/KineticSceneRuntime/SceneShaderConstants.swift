import Foundation

/// Prepare-time data binding only. Authored values cannot inject shader source.
final class SceneShaderConstants {
    private let values: [String: SceneJSON]
    private var consumed = Set<String>()
    private(set) var literals: [String: String] = [:]

    init(_ values: [String: SceneJSON]) throws {
        guard values.count <= 64 else { throw SceneRuntimeError.budgetExceeded("material constant count") }
        guard values.keys.allSatisfy(Self.validName) else { throw SceneRuntimeError.malformed("material constant name") }
        self.values = values
    }

    func declaration(_ code: String, annotation: String?) throws -> String {
        let pattern = #"^\s*uniform\s+(float|int|bool|vec[234])\s+([A-Za-z_][A-Za-z0-9_]*)\s*;\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
              let typeRange = Range(match.range(at: 1), in: code), let nameRange = Range(match.range(at: 2), in: code) else { return code }
        let type = String(code[typeRange]), name = String(code[nameRange])
        guard name != "g_Time", name != "g_Color", !name.hasPrefix("g_Texture") else { return code }
        var metadata = SceneJSON.null
        if let annotation, annotation.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            var limits = SceneLimits(); limits.maximumJSONDepth = 8; limits.maximumJSONNodes = 128
            metadata = try SceneJSON.parse(Data(annotation.utf8), limits: limits)
            guard metadata.object != nil else { throw SceneRuntimeError.malformed("shader uniform annotation") }
        }
        let alias = metadata["material"].string
        if let alias, !Self.validName(alias) { throw SceneRuntimeError.malformed("shader material alias") }
        if let alias, values[alias] != nil, values[name] != nil, alias != name {
            throw SceneRuntimeError.malformed("ambiguous shader constant override: \(name)")
        }
        let key = alias.flatMap { values[$0] == nil ? nil : $0 } ?? (values[name] == nil ? nil : name)
        guard let value = key.flatMap({ values[$0] }) ?? (metadata["default"] == .null ? nil : metadata["default"]) else { return code }
        guard literals.count < 64, literals[name] == nil else { throw SceneRuntimeError.malformed("shader constant declaration count / duplicate") }
        literals[name] = try Self.literal(value, type: type)
        if let key { consumed.insert(key) }
        return ""
    }

    func validateConsumed() throws {
        guard consumed.count == values.count else { throw SceneRuntimeError.unsupported("unbound material constants: \(values.keys.filter { !consumed.contains($0) }.sorted().joined(separator: ", "))") }
    }

    func bind(_ source: String) throws -> String {
        var source = source
        for (name, literal) in literals.sorted(by: { $0.key < $1.key }) {
            let regex = try NSRegularExpression(pattern: "\\b" + name + "\\b")
            source = regex.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source),
                withTemplate: NSRegularExpression.escapedTemplate(for: "(" + literal + ")"))
            guard source.utf8.count <= 256 * 1024 else { throw SceneRuntimeError.budgetExceeded("shader constant expansion") }
        }
        return source
    }

    private static func validName(_ name: String) -> Bool {
        name.utf8.count <= 128 && name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    private static func literal(_ value: SceneJSON, type: String) throws -> String {
        if type == "bool" {
            if let flag = value.bool { return flag ? "true" : "false" }
            if let number = value.number, number == 0 || number == 1 { return number == 1 ? "true" : "false" }
            throw SceneRuntimeError.malformed("shader boolean constant")
        }
        let raw: [Double]
        if let number = value.number { raw = [number] }
        else if let text = value.string, text.utf8.count <= 256 {
            let components = text.split(whereSeparator: { $0.isWhitespace })
            guard !components.isEmpty, components.count <= 4, components.allSatisfy({ Double($0) != nil }) else {
                throw SceneRuntimeError.malformed("shader numeric constant")
            }
            raw = components.map { Double($0)! }
        } else if let array = value.array, !array.isEmpty, array.count <= 4, array.allSatisfy({ $0.number != nil }) {
            raw = array.map { $0.number! }
        } else { throw SceneRuntimeError.malformed("shader constant value") }
        guard raw.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { throw SceneRuntimeError.malformed("non-finite shader constant") }
        if type == "int" {
            guard raw.count == 1, raw[0].rounded() == raw[0], raw[0] >= Double(Int32.min), raw[0] <= Double(Int32.max) else {
                throw SceneRuntimeError.malformed("shader integer constant")
            }
            return "int(\(Int32(raw[0])))"
        }
        let count = type == "float" ? 1 : Int(type.suffix(1))!
        guard raw.count == count || (raw.count == 1 && value.number != nil) else { throw SceneRuntimeError.malformed("shader constant vector size") }
        let values = raw.map { String(Float($0)) }.joined(separator: ",")
        return (count == 1 ? "float" : "float\(count)") + "(" + values + ")"
    }
}
