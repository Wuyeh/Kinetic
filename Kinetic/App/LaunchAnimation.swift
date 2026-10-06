import AppKit
import SwiftUI

/// Module 22：启动动画的播放规则。每次启动只播放一次；「减弱动态效果」开启时、测试宿主中不播放。
@MainActor
enum LaunchAnimationPolicy {
    private static var hasPlayed = false

    static func shouldPlay(alreadyPlayed: Bool, reduceMotion: Bool, isRunningTests: Bool) -> Bool {
        !alreadyPlayed && !reduceMotion && !isRunningTests
    }

    /// 主窗口第一次创建时调用；返回 true 表示这次播放，之后不再播放。
    static func consume() -> Bool {
        let play = shouldPlay(
            alreadyPlayed: hasPlayed,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        )
        hasPlayed = true
        return play
    }
}

/// Module 22：启动动画。主窗口出现时，动态轨迹 K 以品牌主色依次描绘（竖向主轨迹 → 弧形轨迹）；
/// 随后 K 缩小左移，右侧「inetic」由左向右渐显，拼成完整字标「Kinetic」（与 K 同一套单线字形）；
/// 完整显示后停留片刻，再淡出进入主界面（用户要求）。字标以整个窗口为准视觉居中。约 2.8 秒；单击可跳过。
@MainActor
struct LaunchAnimationView: View {
    /// 描绘阶段 K 的边长（pt）。
    static let logoSide: CGFloat = 112
    /// 字标完整展开后的高度（pt），也是此时 K 的边长。
    static let wordmarkHeight: CGFloat = 82
    /// 视觉居中：字标以整个窗口（含标题栏区域）为准居中；小写字母的重心偏下，整体再上移一点。
    static let opticalLift: CGFloat = wordmarkHeight * 0.05
    /// 各阶段时长（秒）。
    enum Timing {
        static let stemDraw = 0.4
        static let trajectoryDelay = 0.2
        static let trajectoryDraw = 0.55
        /// 从开始描绘弧形轨迹到 K 开始缩小左移。
        static let expandDelay = 0.7
        static let expand = 0.6
        /// 从 K 开始移动到字母开始显现（K 已接近到位）。
        static let lettersDelay = 0.35
        static let lettersReveal = 0.65
        /// 字标完整显示后的停留时间（用户要求：停几百毫秒再淡出）。
        static let hold = 0.5
        /// 淡出进入主界面。
        static let fadeOut = 0.4
    }

    let onFinished: () -> Void

    @State private var stemProgress: CGFloat = 0
    @State private var trajectoryProgress: CGFloat = 0
    @State private var isExpanded = false
    @State private var areLettersVisible = false
    @State private var hasFinished = false

    private static var unit: CGFloat { wordmarkHeight / 100 }
    private static var wordmarkWidth: CGFloat { KineticWordmark.unitWidth * unit }
    /// 字母的线宽与展开后的 K 相同。
    private static var letterStrokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: KineticLogo.lineWidth * unit, lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            letters
            logo
        }
        .frame(width: Self.wordmarkWidth, height: Self.wordmarkHeight)
        .offset(y: -Self.opticalLift)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityHidden(true)
        .task {
            withAnimation(.easeOut(duration: Timing.stemDraw)) { stemProgress = 1 }
            await pause(Timing.trajectoryDelay)
            withAnimation(.easeInOut(duration: Timing.trajectoryDraw)) { trajectoryProgress = 1 }
            await pause(Timing.expandDelay)
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: Timing.expand)) { isExpanded = true }
            withAnimation(.easeOut(duration: Timing.lettersReveal).delay(Timing.lettersDelay)) {
                areLettersVisible = true
            }
            await pause(Timing.lettersDelay + Timing.lettersReveal + Timing.hold)
            finish()
        }
    }

    /// K：先以 `logoSide` 居中描绘，展开时缩小到字标高度并移到字标左端。
    private var logo: some View {
        ZStack {
            logoPart(.stem, progress: stemProgress)
            logoPart(.trajectory, progress: trajectoryProgress)
        }
        .frame(width: Self.logoSide, height: Self.logoSide)
        .scaleEffect(isExpanded ? Self.wordmarkHeight / Self.logoSide : 1)
        .frame(width: Self.wordmarkHeight, height: Self.wordmarkHeight)
        .offset(x: isExpanded ? 0 : (Self.wordmarkWidth - Self.wordmarkHeight) / 2)
    }

    private func logoPart(_ part: KineticLogo.Part, progress: CGFloat) -> some View {
        KineticLogoShape(part: part)
            .trim(from: 0, to: progress)
            // 在 logoSide 尺寸下描绘；缩放到字标高度后，线宽与字母一致。
            .stroke(MainWindowDesignTokens.accent,
                    style: StrokeStyle(lineWidth: KineticLogo.lineWidth * Self.logoSide / 100,
                                       lineCap: .round, lineJoin: .round))
    }

    /// 「inetic」：与 K 相同的线宽、圆头。K 快到位时由左向右渐变显现，并与 K 同向轻轻左移到位，
    /// 不与移动中的 K 重叠。
    private var letters: some View {
        KineticWordmarkLettersShape()
            .stroke(MainWindowDesignTokens.accent, style: Self.letterStrokeStyle)
            .frame(width: Self.wordmarkWidth, height: Self.wordmarkHeight)
            .mask(alignment: .leading) {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.5),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.wordmarkWidth * 2)
                    .offset(x: areLettersVisible ? 0 : -Self.wordmarkWidth * 2)
            }
            .offset(x: areLettersVisible ? 0 : Self.wordmarkHeight * 0.2)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        onFinished()
    }
}
