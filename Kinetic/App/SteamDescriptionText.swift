import Foundation
import SwiftUI

/// R4 第 51 节：Steam 作者描述的 BBCode → 可显示的富文本。
///
/// 只做最小必要、安全的渲染：保留作者原文、段落、换行、列表、粗体 / 斜体 / 下划线 / 删除线、标题与 http(s) 链接；
/// 不加载远程图片（[img] 显示为指向原图的「图片」链接），不执行任何内容，其他未知标签只去掉标签保留文字。
enum SteamDescriptionText {
    private struct Style {
        var bold = 0
        var italic = 0
        var underline = 0
        var strike = 0
        var heading: Int?
        var code = 0
        var quote = 0
        var link: URL?
    }

    private struct ListFrame {
        var ordered: Bool
        var counter = 0
    }

    static func attributed(_ source: String, baseSize: CGFloat = 13) -> AttributedString {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var output = AttributedString()
        var style = Style()
        var lists: [ListFrame] = []
        var noparse = false
        var pendingLinkStart: Int?
        var imageURL: String?
        var index = text.startIndex

        func append(_ string: String) {
            guard !string.isEmpty else { return }
            if imageURL != nil { imageURL! += string; return }
            var run = AttributedString(string)
            var font = Font.system(size: headingSize(style.heading, base: baseSize),
                                   weight: style.bold > 0 || style.heading != nil ? .semibold : .regular)
            if style.code > 0 { font = .system(size: baseSize - 1, design: .monospaced) }
            if style.italic > 0 { font = font.italic() }
            run.font = font
            if style.underline > 0 { run.underlineStyle = .single }
            if style.strike > 0 { run.strikethroughStyle = .single }
            if style.quote > 0 { run.foregroundColor = .secondary }
            if let link = style.link { run.link = link; run.underlineStyle = .single }
            output += run
        }

        func endsWithNewline() -> Bool {
            output.characters.last.map { $0 == "\n" } ?? true
        }

        func newlineIfNeeded() {
            if !endsWithNewline() { output += AttributedString("\n") }
        }

        while index < text.endIndex {
            guard text[index] == "[", let close = text[index...].firstIndex(of: "]") else {
                let next = text[text.index(after: index)...].firstIndex(of: "[") ?? text.endIndex
                append(String(text[index..<next]))
                index = next
                continue
            }
            let inner = String(text[text.index(after: index)..<close])
            let isClosing = inner.hasPrefix("/")
            let body = isClosing ? String(inner.dropFirst()) : inner
            let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
            let name = (parts.first ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) : nil
            let afterTag = text.index(after: close)

            if noparse {
                if isClosing, name == "noparse" { noparse = false } else { append("[" + inner + "]") }
                index = afterTag
                continue
            }
            guard isKnown(name) else {
                // 不是 BBCode 标签（例如正文里的方括号）：原样保留。
                append("[" + inner + "]")
                index = afterTag
                continue
            }
            switch (name, isClosing) {
            case ("b", false): style.bold += 1
            case ("b", true): style.bold = max(0, style.bold - 1)
            case ("i", false): style.italic += 1
            case ("i", true): style.italic = max(0, style.italic - 1)
            case ("u", false): style.underline += 1
            case ("u", true): style.underline = max(0, style.underline - 1)
            case ("s", false), ("strike", false): style.strike += 1
            case ("s", true), ("strike", true): style.strike = max(0, style.strike - 1)
            case ("h1", false), ("h2", false), ("h3", false):
                newlineIfNeeded()
                style.heading = Int(name.dropFirst()) ?? 1
            case ("h1", true), ("h2", true), ("h3", true):
                style.heading = nil
                newlineIfNeeded()
            case ("code", false): newlineIfNeeded(); style.code += 1
            case ("code", true): style.code = max(0, style.code - 1); newlineIfNeeded()
            case ("quote", false): newlineIfNeeded(); style.quote += 1
            case ("quote", true): style.quote = max(0, style.quote - 1); newlineIfNeeded()
            case ("noparse", false): noparse = true
            case ("url", false):
                if let argument, let url = safeURL(argument) {
                    style.link = url
                } else {
                    pendingLinkStart = output.characters.count
                }
            case ("url", true):
                if let start = pendingLinkStart {
                    let lower = output.characters.index(output.startIndex, offsetBy: start)
                    let raw = String(output[lower...].characters)
                    if let url = safeURL(raw) { output[lower...].link = url }
                    pendingLinkStart = nil
                }
                style.link = nil
            case ("img", false): imageURL = ""
            case ("img", true):
                if let raw = imageURL {
                    imageURL = nil
                    let previous = style.link
                    style.link = safeURL(raw.trimmingCharacters(in: .whitespaces))
                    append(NSLocalizedString("details.description.image", comment: ""))
                    style.link = previous
                }
            case ("list", false): newlineIfNeeded(); lists.append(ListFrame(ordered: argument == "1"))
            case ("olist", false): newlineIfNeeded(); lists.append(ListFrame(ordered: true))
            case ("list", true), ("olist", true): _ = lists.popLast(); newlineIfNeeded()
            case ("*", _):
                newlineIfNeeded()
                let depth = max(1, lists.count)
                var marker = "•"
                if !lists.isEmpty, lists[lists.count - 1].ordered {
                    lists[lists.count - 1].counter += 1
                    marker = "\(lists[lists.count - 1].counter)."
                }
                append(String(repeating: "    ", count: depth - 1) + marker + " ")
            case ("hr", _):
                newlineIfNeeded()
                append("────────────")
                output += AttributedString("\n")
            case ("tr", true), ("table", true): newlineIfNeeded()
            case ("td", true), ("th", true): append("    ")
            default:
                break // spoiler / table / tr / td 等：只去掉标签，保留文字
            }
            index = afterTag
            // 块级标签自己已经换行：紧跟在后面的一个原文换行不再重复成空行。
            if Self.blockTags.contains(isClosing ? "/" + name : name), index < text.endIndex, text[index] == "\n" {
                index = text.index(after: index)
            }
        }
        return trimmed(output)
    }

    private static let knownTags: Set<String> = ["b", "i", "u", "s", "strike", "h1", "h2", "h3", "code", "quote", "noparse",
                                                 "url", "img", "list", "olist", "*", "hr", "spoiler", "table", "tr", "td",
                                                 "th", "previewyoutube", "p"]

    private static let blockTags: Set<String> = ["/h1", "/h2", "/h3", "list", "/list", "olist", "/olist", "quote", "/quote",
                                                 "code", "/code", "hr", "/table", "/tr"]

    private static func isKnown(_ name: String) -> Bool { knownTags.contains(name) }

    private static func headingSize(_ level: Int?, base: CGFloat) -> CGFloat {
        switch level {
        case 1?: return base + 4
        case 2?: return base + 2
        case 3?: return base + 1
        default: return base
        }
    }

    /// 只允许 http / https 链接。
    static func safeURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    private static func trimmed(_ text: AttributedString) -> AttributedString {
        var result = text
        while let first = result.characters.first, first.isWhitespace || first.isNewline {
            result.removeSubrange(result.startIndex..<result.index(afterCharacter: result.startIndex))
        }
        while let last = result.characters.last, last.isWhitespace || last.isNewline {
            result.removeSubrange(result.index(beforeCharacter: result.endIndex)..<result.endIndex)
        }
        return result
    }
}
