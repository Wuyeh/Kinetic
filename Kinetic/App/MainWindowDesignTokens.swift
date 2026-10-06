import SwiftUI

/// Module 10.1/10.2：主窗口的视觉尺寸。后续纯 UI 视图共用这些值。
enum MainWindowDesignTokens {
    enum Spacing {
        static let micro: CGFloat = 4
        static let small: CGFloat = 8
        static let compact: CGFloat = 12
        static let standard: CGFloat = 16
        static let section: CGFloat = 24
        static let large: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 10
        static let container: CGFloat = 15
    }

    enum Window {
        static let minimumWidth: CGFloat = 900
        static let minimumHeight: CGFloat = 600
        static let defaultWidth: CGFloat = 1180
        static let defaultHeight: CGFloat = 760
    }

    enum Sidebar {
        /// 硬性下限：拖到这里就停止，不会折叠。
        static let minimumWidth: CGFloat = 185
        /// 原来可拖到的最大宽度，视觉比例最好，作为默认宽度。
        static let defaultWidth: CGFloat = 225
        static let maximumWidth: CGFloat = 275
        static let topInset: CGFloat = 70
        static let rowHeight: CGFloat = 38
        static let horizontalInset: CGFloat = 12
        static let itemHorizontalInset: CGFloat = 16
        static let iconSize: CGFloat = 17
        static let iconSlotWidth: CGFloat = 20
        static let iconTextGap: CGFloat = 11
        static let sectionTopInset: CGFloat = 28
    }

    enum Content {
        static let horizontalInset: CGFloat = 30
        static let topInset: CGFloat = 0
        /// 内容区下限，保证固定宽度工具条两侧仍有留白。
        static let minimumWidth: CGFloat = 675
        static let bottomInset: CGFloat = 112
        static let titleBottomGap: CGFloat = 24
    }

    enum Grid {
        /// 网格以外按卡片宽度排版的参考尺寸（搜索框、空状态、欢迎页），保持原值。
        static let minimumCardWidth: CGFloat = 180
        static let idealCardWidth: CGFloat = 220
        static let maximumCardWidth: CGFloat = 250
        /// 用户要求（2026-09-25）：网格中的 Poster 缩小——最小窗口至少 4 列（原来 3 列），
        /// 全屏最多 6 列（原来 5 列）。正方形与模糊延展不变。
        static let minimumPosterWidth: CGFloat = 135
        static let maximumPosterWidth: CGFloat = 210
        static let horizontalGap: CGFloat = 22
        static let verticalGap: CGFloat = 28
        /// 网格内宽（已扣除左右内容留白）：4 × 210 + 3 × 22。
        static let fourToFiveColumnBreakpoint: CGFloat = 906
        static let columnTransitionDuration: TimeInterval = 0.18
        /// 1.0 Module 11：Poster 统一为 1:1 正方形（`PosterGeometry.aspectRatio`）。
        static let previewAspectRatio: CGFloat = PosterGeometry.aspectRatio
        static let previewTitleGap: CGFloat = 9
        static let titleMetadataGap: CGFloat = 3
    }

    enum Typography {
        static let pageTitle = Font.system(size: 27, weight: .semibold)
        static let wallpaperTitle = Font.system(size: 15, weight: .medium)
        static let metadata = Font.system(size: 12, weight: .regular)
        static let sidebarItem = Font.system(size: 14, weight: .medium)
        static let sidebarSelectedItem = Font.system(size: 14, weight: .semibold)
        static let sidebarSection = Font.system(size: 12, weight: .semibold)
        static let emptyTitle = Font.system(size: 17, weight: .medium)
        static let emptyDetail = Font.system(size: 13, weight: .regular)
        static let badge = Font.system(size: 11, weight: .medium)
        static let nowPlayingName = Font.system(size: 14, weight: .medium)
    }

    enum FloatingToolbar {
        static let width: CGFloat = 650
        static let height: CGFloat = 56
        static let horizontalInset: CGFloat = 22
        static let iconGap: CGFloat = 14
        static let iconSize: CGFloat = 17
        static let addIconSize: CGFloat = 14.5
        static let bottomInset: CGFloat = 28
        static let dividerHeight: CGFloat = 26
        static let stopButtonSize: CGFloat = 32
        static let thumbnailSize: CGFloat = 34
        static let nowPlayingMaximumWidth: CGFloat = 247
        static let thumbnailNameGap: CGFloat = 9
        static let rightClusterGap: CGFloat = 14
    }

    enum DisplayTarget {
        static let previewBox = CGSize(width: 156, height: 104)
        static let fallbackAspectRatio: CGFloat = 16.0 / 10.0
        static let inset: CGFloat = 12
        static let gap: CGFloat = 12
        static let maximumWidth: CGFloat = 640
        static let windowMargin: CGFloat = 24
        static let topInset: CGFloat = 12
    }

    enum DisplayPicker {
        static let contentWidth: CGFloat = 324
        static let rowHeight: CGFloat = 40
        static let maximumListHeight: CGFloat = 240
    }

    enum LocalDrag {
        static let holdDuration: Double = 0.30
        static let posterSide: CGFloat = 104
        static let pointerOffset: CGFloat = 12
    }

    static let accent = Color(red: 88.0 / 255.0, green: 191.0 / 255.0, blue: 218.0 / 255.0)
}

/// 1.0 Module 10（规格 4）：「本地」使用用户确定的小房子图标：#58BFDA、细线、无背景。
/// 侧栏「本地」与之后 Steam 下载完成时的「进入本地资料库」目标（House Target，Module 15）共用这一个图形。
enum LocalLibraryIcon {
    static let symbolName = "house"
    static let color = MainWindowDesignTokens.accent
}
