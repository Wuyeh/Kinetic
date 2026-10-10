import SwiftUI

/// Module 62：随 Kinetic 分发的第三方代码与它们的许可（MIT 要求在分发时附上版权与许可声明）。
struct Acknowledgement: Identifiable, Equatable {
    let id: String
    let name: String
    let purpose: String
    let copyright: String
    let license: String
    /// App 包内 `Acknowledgements/` 里的许可原文。
    let fileName: String

    static let all: [Acknowledgement] = [
        Acknowledgement(id: "sparkle", name: "Sparkle", purpose: "检查、下载并安装 Kinetic 的更新",
                        copyright: "© 2006–2013 Andy Matuschak 等", license: "MIT 及随附第三方许可", fileName: "Sparkle-LICENSE.txt"),
        Acknowledgement(id: "scene-engine", name: "macos-wallpaperengine（Paradox07127）",
                        purpose: "场景壁纸引擎（Kinetic 移植并修改）",
                        copyright: "© 2026 Loomscreen contributors", license: "MIT 许可", fileName: "SceneEngine-LICENSE.txt"),
    ]

    var licenseURL: URL? {
        Bundle.main.url(forResource: (fileName as NSString).deletingPathExtension,
                        withExtension: (fileName as NSString).pathExtension, subdirectory: "Acknowledgements")
    }

    var licenseText: String? { licenseURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
}

/// 设置 › 关于「致谢与开源许可」。
struct AcknowledgementsSection: View {
    @State private var shown: Acknowledgement?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("致谢与开源许可").font(.headline)
            ForEach(Acknowledgement.all) { item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.body.weight(.semibold))
                        Text("\(item.purpose) · \(item.copyright) · \(item.license)")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("查看许可") { shown = item }
                        .kineticGlassButton()
                        .disabled(item.licenseURL == nil)
                }
            }
        }
        .sheet(item: $shown) { item in
            VStack(alignment: .leading, spacing: 12) {
                Text(item.name).font(.headline)
                ScrollView {
                    Text(item.licenseText ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("完成") { shown = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 560, height: 480)
        }
    }
}
