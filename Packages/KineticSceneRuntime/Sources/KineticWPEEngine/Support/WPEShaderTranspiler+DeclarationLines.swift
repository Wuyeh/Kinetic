import Foundation

extension WPEShaderTranspiler {
    /// GLSL allows declarations and main() on the same line. The ported
    /// declaration readers consume whole lines, so separate only leading
    /// declaration statements; never split for-loop bodies or comment text.
    static func separatingDeclarationLines(_ source: String) -> String {
        source.components(separatedBy: "\n").flatMap { raw -> [String] in
            var tail = raw, result: [String] = []
            let prefixes = ["uniform ", "varying ", "attribute ", "in ", "out ", "flat in ", "flat out ", "layout(", "layout ("]
            while prefixes.contains(where: tail.trimmingCharacters(in: .whitespaces).hasPrefix),
                  let end = tail.firstIndex(of: ";") {
                let declaration = String(tail[...end])
                // A semicolon inside a comment is not a declaration terminator.
                guard !declaration.contains("//"), !declaration.contains("/*") else { break }
                result.append(declaration)
                tail = String(tail[tail.index(after: end)...])
            }
            result.append(tail)
            return result
        }.joined(separator: "\n")
    }
}
