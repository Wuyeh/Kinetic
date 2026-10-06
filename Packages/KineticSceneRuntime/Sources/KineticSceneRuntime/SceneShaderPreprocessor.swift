import Foundation

/// Scene-owned, bounded preprocessing. Includes stay within the asset resolver;
/// conditions are parsed integer expressions, never evaluated as executable code.
final class SceneShaderPreprocessor {
    private struct Branch { let parent: Bool; var matched: Bool; var active: Bool; var sawElse = false }
    private var definitions: [String: String] = [:]
    private var declared = 0
    private var inputBytes = 0
    private var outputBytes = 0
    private var paths = Set<String>()
    private let limit: Int
    let constants: SceneShaderConstants
    private let identifier = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    init(combos: [String: Int] = [:], constants: [String: SceneJSON] = [:], maximumBytes: Int = 256 * 1024) throws {
        limit = maximumBytes
        self.constants = try SceneShaderConstants(constants)
        guard combos.count <= 64 else { throw SceneRuntimeError.budgetExceeded("shader combo count") }
        for (name, value) in combos {
            guard Self.validName(name), value >= -1_000_000, value <= 1_000_000 else {
                throw SceneRuntimeError.malformed("shader combo name / integer")
            }
            definitions[name] = String(value)
        }
        declared = combos.count
    }

    func file(_ path: String, resolver: SceneAssetResolver, depth: Int = 0) throws -> String {
        guard depth < resolver.limits.maximumReferenceDepth else { throw SceneRuntimeError.budgetExceeded("shader include depth") }
        let path = try ScenePath.canonical(path)
        guard paths.insert(path).inserted else { throw SceneRuntimeError.malformed("cyclic shader include") }
        defer { paths.remove(path) }
        let data = try resolver.read(path, maximumBytes: limit)
        guard let source = String(data: data, encoding: .utf8) else { throw SceneRuntimeError.malformed("shader UTF-8") }
        return try process(source) { reference in
            let parent = (path as NSString).deletingLastPathComponent
            return try self.file(parent.isEmpty ? reference : parent + "/" + reference, resolver: resolver, depth: depth + 1)
        }
    }

    func process(_ source: String, include: ((String) throws -> String)? = nil) throws -> String {
        guard source.utf8.count <= limit - inputBytes else { throw SceneRuntimeError.budgetExceeded("shader source") }
        inputBytes += source.utf8.count
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Authored COMBO defaults are data. Material values already in the table override them.
        for line in normalized.components(separatedBy: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let prefix = ["// [COMBO]", "//[COMBO]"].first(where: { line.hasPrefix($0) }) else { continue }
            var budgets = SceneLimits(); budgets.maximumJSONDepth = 8; budgets.maximumJSONNodes = 128
            let value = try SceneJSON.parse(Data(line.dropFirst(prefix.count).utf8), limits: budgets)
            guard let name = value["combo"].string, Self.validName(name) else { throw SceneRuntimeError.malformed("shader combo declaration") }
            let number: Int
            if value["default"] == .null { number = 0 }
            else if let raw = value["default"].number, raw.rounded() == raw, abs(raw) <= 1_000_000 { number = Int(raw) }
            else if let raw = value["default"].string, let parsed = Int(raw), parsed >= -1_000_000, parsed <= 1_000_000 { number = parsed }
            else { throw SceneRuntimeError.malformed("shader combo default") }
            if definitions[name] == nil { try define(name, value: String(number)) }
        }
        let uncommented = normalized.replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: "", options: .regularExpression)
        var branches: [Branch] = [], output: [String] = []
        for rawLine in uncommented.components(separatedBy: "\n") {
            let comment = rawLine.range(of: "//")
            let line = comment.map { String(rawLine[..<$0.lowerBound]) } ?? rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let active = branches.last?.active ?? true
            guard trimmed.hasPrefix("#") else {
                if active {
                    let expanded = try constants.declaration(expand(line), annotation: comment.map { String(rawLine[$0.upperBound...]) })
                    try admit(expanded); output.append(expanded)
                }
                continue
            }
            let directive = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            let split = directive.firstIndex(where: { $0.isWhitespace }) ?? directive.endIndex
            let name = String(directive[..<split]), argument = directive[split...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "if", "ifdef", "ifndef":
                guard branches.count < 16 else { throw SceneRuntimeError.budgetExceeded("shader conditional depth") }
                let selected: Bool
                if name == "if" { selected = active ? try condition(argument) : false }
                else {
                    guard Self.validName(argument) else { throw SceneRuntimeError.malformed("shader conditional name") }
                    selected = name == "ifdef" ? definitions[argument] != nil : definitions[argument] == nil
                }
                branches.append(.init(parent: active, matched: selected, active: active && selected))
            case "elif":
                guard var branch = branches.popLast(), !branch.sawElse else { throw SceneRuntimeError.malformed("unmatched shader elif") }
                let selected = branch.parent && !branch.matched ? try condition(argument) : false
                branch.active = branch.parent && !branch.matched && selected; branch.matched = branch.matched || selected
                branches.append(branch)
            case "else":
                guard argument.isEmpty, var branch = branches.popLast(), !branch.sawElse else { throw SceneRuntimeError.malformed("unmatched shader else") }
                branch.active = branch.parent && !branch.matched; branch.matched = true; branch.sawElse = true
                branches.append(branch)
            case "endif":
                guard argument.isEmpty, branches.popLast() != nil else { throw SceneRuntimeError.malformed("unmatched shader endif") }
            default:
                guard active else { continue }
                switch name {
                case "define":
                    let split = argument.firstIndex(where: { $0.isWhitespace }) ?? argument.endIndex
                    let key = String(argument[..<split]), value = argument[split...].trimmingCharacters(in: .whitespaces)
                    try define(key, value: value)
                case "undef":
                    guard Self.validName(argument) else { throw SceneRuntimeError.malformed("shader undef name") }
                    definitions.removeValue(forKey: argument)
                case "include":
                    guard let include, argument.first == "\"", argument.last == "\"", argument.filter({ $0 == "\"" }).count == 2 else {
                        throw SceneRuntimeError.unsupported("shader include syntax")
                    }
                    // Child output is already admitted exactly once; inactive includes are never read.
                    output.append(try include(String(argument.dropFirst().dropLast())))
                case "version": break
                default: throw SceneRuntimeError.unsupported("shader directive: \(name)")
                }
            }
        }
        guard branches.isEmpty else { throw SceneRuntimeError.malformed("unterminated shader conditional") }
        return output.joined(separator: "\n")
    }

    private static func validName(_ name: String) -> Bool {
        name.utf8.count <= 128 && name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }
    private func define(_ name: String, value: String) throws {
        guard Self.validName(name), !value.contains("#"), !value.contains("\\") else { throw SceneRuntimeError.unsupported("shader macro declaration / concatenation") }
        if let existing = definitions[name] {
            guard existing == value else { throw SceneRuntimeError.unsupported("shader macro redefinition") }
            return
        }
        guard declared < 64 else { throw SceneRuntimeError.budgetExceeded("shader macro count") }
        declared += 1; definitions[name] = value
    }
    private func admit(_ line: String) throws {
        guard line.utf8.count + 1 <= limit - outputBytes else { throw SceneRuntimeError.budgetExceeded("shader macro expansion") }
        outputBytes += line.utf8.count + 1
    }
    private func substitute(_ text: String, name: String, value: String) throws -> String {
        let regex = try NSRegularExpression(pattern: "\\b" + name + "\\b")
        let range = NSRange(text.startIndex..., in: text)
        let count = regex.numberOfMatches(in: text, range: range)
        guard text.utf8.count + count * (value.utf8.count - name.utf8.count) <= limit else {
            throw SceneRuntimeError.budgetExceeded("shader macro expansion")
        }
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: value))
    }
    private func expand(_ source: String) throws -> String {
        var visiting = Set<String>()
        func resolve(_ text: String, depth: Int) throws -> String {
            guard depth < 16 else { throw SceneRuntimeError.budgetExceeded("shader macro dependency depth") }
            var result = text
            let names = Set(identifier.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }).filter { definitions[$0] != nil }
            for name in names.sorted() {
                guard visiting.insert(name).inserted else { throw SceneRuntimeError.malformed("cyclic shader macros") }
                let value = try resolve(definitions[name]!, depth: depth + 1)
                visiting.remove(name)
                result = try substitute(result, name: name, value: value)
            }
            return result
        }
        return try resolve(source, depth: 0)
    }
    private func condition(_ source: String) throws -> Bool {
        let defined = try NSRegularExpression(pattern: #"\bdefined\s*(?:\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)|([A-Za-z_][A-Za-z0-9_]*))"#)
        var expression = source
        for match in defined.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            let nameRange = Range(match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1), in: source)!
            let range = Range(match.range, in: expression)!
            expression.replaceSubrange(range, with: definitions[String(source[nameRange])] == nil ? "0" : "1")
        }
        expression = try expand(expression)
        var parser = try SceneShaderCondition(expression)
        return try parser.evaluate() != 0
    }
}

/// Integer-only C-style condition expressions with token, nesting and arithmetic bounds.
private struct SceneShaderCondition {
    private let tokens: [String]
    private var index = 0
    private static let levels = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]
    init(_ source: String) throws {
        let regex = try NSRegularExpression(pattern: #"0[xX][0-9A-Fa-f]+|[0-9]+|[A-Za-z_][A-Za-z0-9_]*|\|\||&&|==|!=|<=|>=|<<|>>|[()!~+*/%<>&|^-]"#)
        var tokens: [String] = [], end = source.startIndex
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let range = Range(match.range, in: source)!
            guard source[end..<range.lowerBound].allSatisfy(\.isWhitespace), tokens.count < 128 else { throw SceneRuntimeError.unsupported("shader condition tokens / budget") }
            tokens.append(String(source[range])); end = range.upperBound
        }
        guard !tokens.isEmpty, source[end...].allSatisfy(\.isWhitespace) else { throw SceneRuntimeError.unsupported("shader condition syntax") }
        self.tokens = tokens
    }
    mutating func evaluate() throws -> Int64 {
        let value = try expression(level: 0, depth: 0, evaluate: true)
        guard index == tokens.count else { throw SceneRuntimeError.malformed("shader condition trailing tokens") }
        return value
    }
    private mutating func expression(level: Int, depth: Int, evaluate: Bool) throws -> Int64 {
        if level == Self.levels.count { return try unary(depth: depth, evaluate: evaluate) }
        var value = try expression(level: level + 1, depth: depth, evaluate: evaluate)
        while index < tokens.count, Self.levels[level].contains(tokens[index]) {
            let op = tokens[index]; index += 1
            let enabled = evaluate && !(op == "&&" && value == 0) && !(op == "||" && value != 0)
            let rhs = try expression(level: level + 1, depth: depth, evaluate: enabled)
            if evaluate { value = try Self.apply(op, value, rhs) }
        }
        return evaluate ? value : 0
    }
    private mutating func unary(depth: Int, evaluate: Bool) throws -> Int64 {
        guard depth < 16, index < tokens.count else { throw SceneRuntimeError.malformed("shader condition depth / operand") }
        let token = tokens[index]; index += 1
        if ["!", "~", "+", "-"].contains(token) {
            let value = try unary(depth: depth + 1, evaluate: evaluate)
            guard evaluate else { return 0 }
            switch token {
            case "!": return value == 0 ? 1 : 0
            case "~": return ~value
            case "+": return value
            default:
                let result = Int64(0).subtractingReportingOverflow(value)
                guard !result.overflow else { throw SceneRuntimeError.malformed("shader condition overflow") }
                return result.partialValue
            }
        }
        if token == "(" {
            let value = try expression(level: 0, depth: depth + 1, evaluate: evaluate)
            guard index < tokens.count, tokens[index] == ")" else { throw SceneRuntimeError.malformed("shader condition parentheses") }
            index += 1; return value
        }
        if token.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil { return 0 }
        let value: Int64?
        if token.lowercased().hasPrefix("0x") { value = Int64(token.dropFirst(2), radix: 16) }
        else if token.count > 1, token.first == "0" { value = Int64(token, radix: 8) }
        else { value = Int64(token) }
        guard let value else { throw SceneRuntimeError.malformed("shader condition integer") }
        return evaluate ? value : 0
    }
    private static func apply(_ op: String, _ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result: (partialValue: Int64, overflow: Bool)
        switch op {
        case "||": return lhs != 0 || rhs != 0 ? 1 : 0
        case "&&": return lhs != 0 && rhs != 0 ? 1 : 0
        case "|": return lhs | rhs
        case "^": return lhs ^ rhs
        case "&": return lhs & rhs
        case "==": return lhs == rhs ? 1 : 0
        case "!=": return lhs != rhs ? 1 : 0
        case "<": return lhs < rhs ? 1 : 0
        case ">": return lhs > rhs ? 1 : 0
        case "<=": return lhs <= rhs ? 1 : 0
        case ">=": return lhs >= rhs ? 1 : 0
        case "+": result = lhs.addingReportingOverflow(rhs)
        case "-": result = lhs.subtractingReportingOverflow(rhs)
        case "*": result = lhs.multipliedReportingOverflow(by: rhs)
        case "/", "%":
            guard rhs != 0, !(lhs == .min && rhs == -1) else { throw SceneRuntimeError.malformed("shader condition division") }
            return op == "/" ? lhs / rhs : lhs % rhs
        default:
            guard rhs >= 0, rhs < 63 else { throw SceneRuntimeError.malformed("shader condition shift") }
            if op == ">>" { return lhs >> rhs }
            result = lhs.multipliedReportingOverflow(by: Int64(1) << rhs)
        }
        guard !result.overflow else { throw SceneRuntimeError.malformed("shader condition overflow") }
        return result.partialValue
    }
}
