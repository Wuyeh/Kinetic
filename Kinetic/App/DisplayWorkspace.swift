import SwiftUI

/// Display-page geometry only. None of these values change wallpaper settings.
/// The arrangement is fixed: nothing can be dragged or resized, every frame follows the window.
enum DisplayWorkspaceMetrics {
    /// The main window's own corner arc (16 pt on Kinetic's window), shared by all three modules.
    static let cornerRadius: CGFloat = 16
    static let gap: CGFloat = 24
    /// The console's share of the row while it is below its width cap.
    static let consoleWidthFraction: CGFloat = 0.27
    /// Narrower than this the console's controls crowd; it wins over the aspect cap in very short windows.
    static let minimumConsoleWidth: CGFloat = 240
    /// Width never exceeds this fraction of the console's height: a clearly upright panel.
    static let maximumConsoleAspect: CGFloat = 0.5
    // Apple material remains system-controlled. Only the neutral backing below it is set here.
    static let consoleBackingOpacity: Double = 0.5 // Half of the previous 1.0.
    static let selectorHeight: CGFloat = 52
    static let headerHeight = max(ContentHeaderMetrics.buttonSize, selectorHeight)
    static let dividerSpacing: CGFloat = 8
    static let dividerThickness: CGFloat = 1
    static let workspaceSpacing: CGFloat = 12
    /// Room kept above and below a height-limited thumbnail for its loading / error line.
    static let statusReserve: CGFloat = 28
    static let statusSpacing: CGFloat = 8
    static var workspaceTop: CGFloat { headerHeight + dividerSpacing + dividerThickness + workspaceSpacing }
}

/// Page frames, in the display page's own coordinate space.
struct DisplayWorkspaceFrames: Equatable {
    var title: CGRect
    var selector: CGRect
    var dividerY: CGFloat
    var preview: CGRect
    var console: CGRect
}

/// The wallpaper selector sits on the title row directly above the console (an upside-down "!").
/// The console fills the height below the header at the trailing edge. Its width grows with the
/// window at the same proportional rate as the thumbnail until it reaches its aspect cap; any further
/// width goes to the thumbnail, which always keeps the display's aspect ratio.
enum DisplayWorkspaceLayout {
    static func frames(in size: CGSize, aspect: CGFloat) -> DisplayWorkspaceFrames {
        typealias M = DisplayWorkspaceMetrics
        let width = clean(size.width)
        let top = M.workspaceTop
        let height = max(0, clean(size.height) - top)
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 1.6
        let gap = min(M.gap, width)
        let row = max(0, width - gap)
        let consoleWidth = min(row, max(M.minimumConsoleWidth,
                                        min(height * M.maximumConsoleAspect, row * M.consoleWidthFraction)))
        let column = max(0, row - consoleWidth)
        let previewWidth = min(column, max(0, height - 2 * M.statusReserve) * ratio)
        let previewHeight = previewWidth / ratio
        let consoleX = width - consoleWidth
        return .init(
            title: CGRect(x: 0, y: 0, width: max(0, consoleX - gap), height: M.headerHeight),
            selector: CGRect(x: consoleX, y: (M.headerHeight - M.selectorHeight) / 2,
                             width: consoleWidth, height: M.selectorHeight),
            dividerY: M.headerHeight + M.dividerSpacing,
            preview: CGRect(x: (column - previewWidth) / 2, y: top + (height - previewHeight) / 2,
                            width: previewWidth, height: previewHeight),
            console: CGRect(x: consoleX, y: top, width: consoleWidth, height: height))
    }

    private static func clean(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
}

/// Every part stays mounted while the window resizes; only frames change,
/// so the preview's native view is never recreated by layout.
struct DisplayWorkspace<Title: View, Selector: View, Preview: View, Console: View, Status: View>: View {
    let aspect: CGFloat
    @ViewBuilder var title: () -> Title
    @ViewBuilder var selector: () -> Selector
    @ViewBuilder var preview: (CGSize) -> Preview
    @ViewBuilder var console: () -> Console
    @ViewBuilder var status: () -> Status

    var body: some View {
        GeometryReader { geometry in
            let frames = DisplayWorkspaceLayout.frames(in: geometry.size, aspect: aspect)
            let shape = RoundedRectangle(cornerRadius: DisplayWorkspaceMetrics.cornerRadius, style: .continuous)
            ZStack(alignment: .topLeading) {
                title()
                    .frame(width: frames.title.width, height: frames.title.height, alignment: .leading)
                    .position(x: frames.title.midX, y: frames.title.midY)
                Divider().opacity(ContentHeaderMetrics.separatorOpacity)
                    .frame(width: geometry.size.width)
                    .position(x: geometry.size.width / 2, y: frames.dividerY + DisplayWorkspaceMetrics.dividerThickness / 2)
                selector()
                    .frame(width: frames.selector.width, height: frames.selector.height)
                    .position(x: frames.selector.midX, y: frames.selector.midY)
                preview(frames.preview.size)
                    .frame(width: frames.preview.width, height: frames.preview.height)
                    .clipShape(shape)
                    .position(x: frames.preview.midX, y: frames.preview.midY)
                status()
                    .frame(width: frames.preview.width, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: frames.preview.width, height: DisplayWorkspaceMetrics.statusReserve, alignment: .topLeading)
                    .position(x: frames.preview.midX,
                              y: frames.preview.maxY + DisplayWorkspaceMetrics.statusSpacing + DisplayWorkspaceMetrics.statusReserve / 2)
                console()
                    .frame(width: frames.console.width, height: frames.console.height)
                    .position(x: frames.console.midX, y: frames.console.midY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}
