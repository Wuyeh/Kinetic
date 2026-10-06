import SwiftUI

/// 错误以非模态提示展示；保留到用户重试或关闭，避免主窗口未打开时错过错误。
struct RecoveryNotice: View {
    let message: String
    let detail: String
    let actionTitle: LocalizedStringKey
    let action: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(MainWindowDesignTokens.Typography.metadata)
                .lineLimit(3)
                .help(detail)
                .accessibilityHint(detail)
            if let action {
                Button(actionTitle, action: action)
                    .kineticGlassButton()
                    .controlSize(.small)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("recovery.dismiss")
            .accessibilityLabel("recovery.dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .kineticGlass(in: Capsule())
        .accessibilityElement(children: .contain)
    }
}
