import SwiftUI

private typealias Tokens = MainWindowDesignTokens

/// Module 20：第一次启动时的 Welcome：名称、标语、三个演示和「设置为壁纸」，设置成功后轻量提示并说明菜单栏。
/// Module 56：多台显示器时先选显示器；设置好之后「继续」到一页「了解 Kinetic」。
@MainActor
struct WelcomeView: View {
    @ObservedObject var onboarding: OnboardingController

    var body: some View {
        Group {
            switch onboarding.phase {
            case .demos: demos
            case .tour: WelcomeTourView(onFinish: onboarding.finish).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: onboarding.phase)
        .overlay {
            if onboarding.demoAwaitingDisplay != nil {
                GeometryReader { proxy in
                    DisplayApplyDialog(items: onboarding.displayItems, availableSize: proxy.size,
                                       onSelect: { id in Task { await onboarding.chooseDisplay(id) } },
                                       onCancel: onboarding.cancelDisplayChoice)
                }
            }
        }
    }

    private var demos: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Tokens.Spacing.large)

            VStack(spacing: Tokens.Spacing.small) {
                Text(verbatim: "Kinetic")
                    .font(.system(size: 44, weight: .bold))
                Text("onboarding.tagline")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("onboarding.prompt")
                .font(Tokens.Typography.emptyDetail)
                .foregroundStyle(.secondary)
                .padding(.top, Tokens.Spacing.standard)

            HStack(alignment: .top, spacing: Tokens.Grid.horizontalGap) {
                ForEach(onboarding.demos) { demo in
                    WelcomeDemoCard(
                        demo: demo,
                        status: onboarding.status(of: demo),
                        isBusy: onboarding.applyingDemoID != nil
                    ) {
                        Task { await onboarding.setAsWallpaper(demo) }
                    }
                }
            }
            .frame(maxWidth: 3 * Tokens.Grid.maximumCardWidth + 2 * Tokens.Grid.horizontalGap)
            .padding(.top, 36)

            Text(onboarding.errorMessage ?? " ")
                .font(Tokens.Typography.emptyDetail)
                .foregroundStyle(.red)
                .opacity(onboarding.errorMessage == nil ? 0 : 1)
                .padding(.top, Tokens.Spacing.standard)

            footer
                .frame(height: 96)
                .padding(.top, Tokens.Spacing.small)

            Spacer(minLength: Tokens.Spacing.large)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: Tokens.Window.minimumWidth, minHeight: Tokens.Window.minimumHeight)
        .tint(Tokens.accent)
        .animation(.easeInOut(duration: 0.2), value: onboarding.hasSetWallpaper)
        .onDisappear { WallpaperPreviewCoordinator.shared.stopAll() }
    }

    @ViewBuilder
    private var footer: some View {
        if onboarding.hasSetWallpaper {
            VStack(spacing: Tokens.Spacing.standard) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.small) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tokens.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("onboarding.done.title")
                            .font(.system(size: 15, weight: .semibold))
                        Text("onboarding.done.detail")
                            .font(Tokens.Typography.emptyDetail)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    onboarding.continueToTour()
                } label: {
                    Text("onboarding.continue").frame(minWidth: 96)
                }
                .kineticGlassButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .transition(.opacity)
        } else {
            // 用户要求：交互按钮无色。「跳过」是普通的次要文字按钮，不是彩色链接。
            Button("onboarding.skip") { onboarding.finish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(Tokens.Typography.emptyDetail)
                .disabled(onboarding.applyingDemoID != nil)
                .transition(.opacity)
        }
    }
}

/// 一个演示：与资料库卡片相同的预览区域（缩略图，悬停时播放预览），下方是名称与「设置为壁纸」。
@MainActor
private struct WelcomeDemoCard: View {
    let demo: OnboardingDemo
    let status: OnboardingController.DemoStatus
    let isBusy: Bool
    let onSet: () -> Void

    @ObservedObject private var previewCoordinator = WallpaperPreviewCoordinator.shared

    var body: some View {
        let wallpaper = demo.previewWallpaper
        VStack(spacing: Tokens.Spacing.compact) {
            WallpaperCardPreview(
                wallpaper: wallpaper,
                livePreview: previewCoordinator.preview(for: wallpaper.id),
                onPreviewInterrupted: { previewCoordinator.previewInterrupted($0) }
            )
            .overlay {
                PosterShape()
                    .strokeBorder(Tokens.accent.opacity(status == .active ? 0.75 : 0), lineWidth: 2)
            }
            .onHover { hovering in
                if hovering {
                    previewCoordinator.hoverBegan(wallpaper)
                } else {
                    previewCoordinator.hoverEnded(wallpaper.id)
                }
            }
            .onDisappear { previewCoordinator.hoverEnded(wallpaper.id) }

            Text(demo.name)
                .font(Tokens.Typography.wallpaperTitle)

            action
                .frame(height: 28)
        }
        .frame(maxWidth: Tokens.Grid.maximumCardWidth)
        .animation(.easeOut(duration: 0.15), value: status)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(demo.name)
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .idle:
            Button {
                previewCoordinator.stopAll()
                onSet()
            } label: {
                Text("onboarding.setWallpaper").frame(minWidth: 96)
            }
            .kineticGlassButton()
            .disabled(isBusy)
        case .applying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("onboarding.applying")
                    .font(Tokens.Typography.emptyDetail)
                    .foregroundStyle(.secondary)
            }
        case .active:
            Label("shell.tile.active", systemImage: "checkmark.circle.fill")
                .font(Tokens.Typography.emptyDetail)
                .foregroundStyle(Tokens.accent)
        }
    }
}

/// Module 56：设置好壁纸之后的一页说明——本地与 Steam 的区别、按显示器设置、菜单栏，以及权限按需询问。
@MainActor
struct WelcomeTourView: View {
    let onFinish: () -> Void

    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private let items = [
        Item(id: "library", symbol: "square.stack", title: "onboarding.tour.library.title", detail: "onboarding.tour.library.detail"),
        Item(id: "displays", symbol: "display.2", title: "onboarding.tour.displays.title", detail: "onboarding.tour.displays.detail"),
        Item(id: "menuBar", symbol: "menubar.rectangle", title: "onboarding.tour.menuBar.title", detail: "onboarding.tour.menuBar.detail"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Tokens.Spacing.large)
            Text("onboarding.tour.title")
                .font(.system(size: 30, weight: .bold))
            HStack(alignment: .top, spacing: Tokens.Grid.horizontalGap) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(Tokens.accent)
                            .frame(height: 32)
                            .accessibilityHidden(true)
                        Text(item.title).font(.system(size: 15, weight: .semibold))
                        Text(item.detail)
                            .font(Tokens.Typography.emptyDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Tokens.Spacing.standard)
                    .frame(maxWidth: Tokens.Grid.maximumCardWidth, minHeight: 190, alignment: .topLeading)
                    .kineticGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: 3 * Tokens.Grid.maximumCardWidth + 2 * Tokens.Grid.horizontalGap)
            .padding(.top, 36)
            Label("onboarding.tour.permissions", systemImage: "lock.shield")
                .font(Tokens.Typography.emptyDetail)
                .foregroundStyle(.secondary)
                .padding(.top, Tokens.Spacing.section)
            Button(action: onFinish) {
                Text("onboarding.start").frame(minWidth: 96)
            }
            .kineticGlassButton()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, Tokens.Spacing.section)
            Spacer(minLength: Tokens.Spacing.large)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: Tokens.Window.minimumWidth, minHeight: Tokens.Window.minimumHeight)
        .tint(Tokens.accent)
    }
}
