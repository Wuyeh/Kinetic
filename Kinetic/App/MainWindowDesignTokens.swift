import SwiftUI

/// 主窗口的视觉尺寸。纯 UI 视图共用这些值。
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
        static let preview: CGFloat = 12
        static let container: CGFloat = 15
    }

    enum Window {
        static let minimumWidth: CGFloat = 900
        static let minimumHeight: CGFloat = 600
        static let defaultWidth: CGFloat = 1180
        static let defaultHeight: CGFloat = 760
    }

    enum Sidebar {
        static let minimumWidth: CGFloat = 175
        static let defaultWidth: CGFloat = 195
        static let maximumWidth: CGFloat = 225
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
        static let topInset: CGFloat = 26
        static let bottomInset: CGFloat = 112
        static let titleBottomGap: CGFloat = 24
    }

    enum Grid {
        static let minimumCardWidth: CGFloat = 180
        static let idealCardWidth: CGFloat = 220
        static let maximumCardWidth: CGFloat = 250
        static let horizontalGap: CGFloat = 22
        static let verticalGap: CGFloat = 28
        /// 网格内宽（已扣除左右内容留白）：3 × 250 + 2 × 22。
        static let threeToFourColumnBreakpoint: CGFloat = 794
        static let columnTransitionDuration: TimeInterval = 0.18
        static let previewAspectRatio: CGFloat = 1.6
        static let previewTitleGap: CGFloat = 9
        static let titleMetadataGap: CGFloat = 3
    }

    enum Typography {
        static let pageTitle = Font.system(size: 23, weight: .semibold)
        static let wallpaperTitle = Font.system(size: 15, weight: .medium)
        static let metadata = Font.system(size: 12, weight: .regular)
        static let sidebarItem = Font.system(size: 14, weight: .medium)
        static let sidebarSelectedItem = Font.system(size: 14, weight: .semibold)
        static let sidebarSection = Font.system(size: 12, weight: .semibold)
        static let inspectorLabel = Font.system(size: 12, weight: .medium)
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
        static let bottomInset: CGFloat = 28
        static let dividerHeight: CGFloat = 26
        static let stopButtonSize: CGFloat = 32
        static let thumbnailSize: CGFloat = 34
        static let nowPlayingMaximumWidth: CGFloat = 247
        static let thumbnailNameGap: CGFloat = 9
        static let rightClusterGap: CGFloat = 14
    }

    static let accent = Color(red: 88.0 / 255.0, green: 191.0 / 255.0, blue: 218.0 / 255.0)
}
