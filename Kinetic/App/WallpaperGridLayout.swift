import SwiftUI

/// 网格的纯布局计算：阶段由列数断点决定，阶段内宽度连续计算。
struct WallpaperGridMetrics {
    let columnCount: Int
    let cardWidth: CGFloat

    init(availableWidth: CGFloat) {
        let width = max(0, availableWidth)
        let minimum = MainWindowDesignTokens.Grid.minimumCardWidth
        let maximum = MainWindowDesignTokens.Grid.maximumCardWidth
        let gap = MainWindowDesignTokens.Grid.horizontalGap
        let breakpoint = MainWindowDesignTokens.Grid.threeToFourColumnBreakpoint

        let count: Int
        if width < breakpoint {
            // 正常最小窗口可以容纳 3 列；更窄的布局提案只作防溢出兜底。
            count = min(3, max(1, Int(floor((width + gap) / (minimum + gap)))))
        } else {
            // 当前阶段连续长到最大卡宽后才加一列，避免阶段内提前封顶。
            count = 4 + Int(floor((width - breakpoint) / (maximum + gap)))
        }

        columnCount = count
        let remainingWidth = width - CGFloat(count - 1) * gap
        cardWidth = min(width, min(maximum, max(minimum, remainingWidth / CGFloat(count))))
    }
}

/// 只在列数改变时动画；同列数下，卡片宽度直接跟随当前可用宽度。
struct ResponsiveWallpaperGrid<Content: View>: View {
    let availableWidth: CGFloat
    private let content: Content

    init(availableWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.availableWidth = availableWidth
        self.content = content()
    }

    var body: some View {
        let metrics = WallpaperGridMetrics(availableWidth: availableWidth)
        LazyVGrid(
            columns: Array(repeating: GridItem(
                .fixed(metrics.cardWidth),
                spacing: MainWindowDesignTokens.Grid.horizontalGap,
                alignment: .top
            ), count: metrics.columnCount),
            alignment: .leading,
            spacing: MainWindowDesignTokens.Grid.verticalGap
        ) {
            content
        }
        .frame(width: availableWidth, alignment: .leading)
        .animation(
            .easeInOut(duration: MainWindowDesignTokens.Grid.columnTransitionDuration),
            value: metrics.columnCount
        )
    }
}
