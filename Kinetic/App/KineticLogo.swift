import AppKit
import SwiftUI

/// Module 22：动态轨迹 K（规格 3、3.1、4）。
///
/// 一条略带弧度的竖向主轨迹，以及一条从右上划向中部、再向右下展开的连续弧形轨迹；端点为圆头。
/// 坐标为 100×100、y 向下。App 图标图层由 `Tools/AppIcon/make_icon_svg.py` 按同一几何生成。
enum KineticLogo {
    /// 竖向主轨迹：一段三次贝塞尔曲线（起点、控制点 1、控制点 2、终点）。
    static let stem: [CGPoint] = [
        CGPoint(x: 27, y: 12), CGPoint(x: 24, y: 40), CGPoint(x: 24, y: 62), CGPoint(x: 27, y: 88)
    ]
    /// 弧形轨迹：从右上到中部，再从中部到右下，两段相接的三次贝塞尔曲线。
    static let trajectory: [[CGPoint]] = [
        [CGPoint(x: 74, y: 12), CGPoint(x: 68, y: 34), CGPoint(x: 54, y: 50), CGPoint(x: 38, y: 54)],
        [CGPoint(x: 38, y: 54), CGPoint(x: 56, y: 58), CGPoint(x: 70, y: 70), CGPoint(x: 76, y: 88)]
    ]
    /// App 标志的线宽（100 单位中）。
    static let lineWidth: CGFloat = 11
    /// 菜单栏标志：小尺寸下略粗，提高识别度（规格 4）。
    static let menuBarLineWidth: CGFloat = 13
    /// 品牌主色 #58BFDA。
    static let accentColor = NSColor(srgbRed: 88.0 / 255.0, green: 191.0 / 255.0, blue: 218.0 / 255.0, alpha: 1)

    enum Part: CaseIterable {
        case stem
        case trajectory
    }

    private static func segments(of part: Part) -> [[CGPoint]] {
        part == .stem ? [stem] : trajectory
    }

    /// 把 100×100 坐标映射到 `rect`（保持比例、居中）。
    private static func mapper(for rect: CGRect) -> (CGPoint) -> CGPoint {
        let side = min(rect.width, rect.height)
        let scale = side / 100
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        return { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
    }

    /// SwiftUI 路径（y 向下）。
    static func path(_ part: Part, in rect: CGRect) -> Path {
        let map = mapper(for: rect)
        var path = Path()
        for (index, segment) in segments(of: part).enumerated() {
            if index == 0 { path.move(to: map(segment[0])) }
            path.addCurve(to: map(segment[3]), control1: map(segment[1]), control2: map(segment[2]))
        }
        return path
    }

    /// AppKit 路径，用于在翻转（y 向下）的上下文中绘制。
    static func bezierPath(_ part: Part, in rect: CGRect) -> NSBezierPath {
        let map = mapper(for: rect)
        let path = NSBezierPath()
        for (index, segment) in segments(of: part).enumerated() {
            if index == 0 { path.move(to: map(segment[0])) }
            path.curve(to: map(segment[3]), controlPoint1: map(segment[1]), controlPoint2: map(segment[2]))
        }
        return path
    }

    // MARK: - 菜单栏

    /// 菜单栏图标的尺寸（pt）。
    static let menuBarSize = NSSize(width: 18, height: 18)

    private static let templateMenuBarImage = makeMenuBarImage(accent: false)
    private static let accentMenuBarImage = makeMenuBarImage(accent: true)

    /// 菜单栏标志：没有背景。壁纸未启用、手动暂停或停止时是黑白模板图，由系统按菜单栏外观着色；
    /// 正常播放与智能暂停时变为品牌主色（规格 4）。
    static func menuBarImage(accent: Bool) -> NSImage {
        accent ? accentMenuBarImage : templateMenuBarImage
    }

    private static func makeMenuBarImage(accent: Bool) -> NSImage {
        let image = NSImage(size: menuBarSize, flipped: true) { rect in
            (accent ? accentColor : NSColor.black).setStroke()
            let width = menuBarLineWidth * min(rect.width, rect.height) / 100
            for part in Part.allCases {
                let path = bezierPath(part, in: rect)
                path.lineWidth = width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = !accent
        image.accessibilityDescription = "Kinetic"
        return image
    }
}

/// SwiftUI 中的动态轨迹 K 的一部分，可以用 `trim` 做描绘动画。
struct KineticLogoShape: Shape {
    let part: KineticLogo.Part

    func path(in rect: CGRect) -> Path {
        KineticLogo.path(part, in: rect)
    }
}

/// Module 22：完整字标「Kinetic」，用于启动动画。K 就是动态轨迹 K；「inetic」用与 K 相同的线宽、圆头圆角的单线字形绘制，
/// 保持同一套字形设计。坐标与 K 相同：100 单位高、y 向下；K 占 0…100，字母在其右侧。
enum KineticWordmark {
    /// 字标总宽（单位）。左右留白相等，使整个字标居中。
    static let unitWidth: CGFloat = 388.5
    /// 字母基线与 x 高（与 K 的底端对齐）。
    static let baseline: CGFloat = 88
    static let xHeight: CGFloat = 34
    /// i 的圆点中心高度。
    static let dotY: CGFloat = 15
    /// e、c 的字碗半径。
    private static let bowl = CGSize(width: 23, height: 27)
    private static var bowlCenterY: CGFloat { (baseline + xHeight) / 2 }
    /// e、c 开口端点的角度（弧度）。
    private static let apertureAngle: CGFloat = 0.75

    /// 「i n e t i c」各字母的横向位置：i、n、t 为竖笔中心线，e、c 为字碗左缘。
    /// 字母外缘之间约 12 单位；e 与 t、t 与 i 之间留白较多，收紧到约 9 单位。
    static let letterOrigins: [CGFloat] = [99, 124, 187, 264, 301, 324]

    /// 每个字母的路径（100 单位坐标）。
    static let letterPaths: [Path] = {
        let x = letterOrigins
        return [letterI(x[0]), letterN(x[1]), letterE(x[2]), letterT(x[3]), letterI(x[4]), letterC(x[5])]
    }()

    /// 把「inetic」映射到字标所在的 `rect`（`rect` 高度对应 100 单位，左缘对应 0）。
    static func lettersPath(in rect: CGRect) -> Path {
        let scale = rect.height / 100
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: rect.minX, ty: rect.minY)
        var path = Path()
        for letter in letterPaths { path.addPath(letter, transform: transform) }
        return path
    }

    private static func letterI(_ x: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x, y: xHeight))
        path.addLine(to: CGPoint(x: x, y: baseline))
        // 极短的线段加圆头，就是一个与笔画同宽的圆点。
        path.move(to: CGPoint(x: x, y: dotY))
        path.addLine(to: CGPoint(x: x, y: dotY + 0.01))
        return path
    }

    private static func letterN(_ x: CGFloat) -> Path {
        let width: CGFloat = 40
        let arch = CGSize(width: width / 2, height: 22)
        var path = Path()
        path.move(to: CGPoint(x: x, y: xHeight))
        path.addLine(to: CGPoint(x: x, y: baseline))
        path.move(to: CGPoint(x: x, y: xHeight + arch.height))
        addArc(to: &path, center: CGPoint(x: x + arch.width, y: xHeight + arch.height), radii: arch, from: .pi, to: 2 * .pi)
        path.addLine(to: CGPoint(x: x + width, y: baseline))
        return path
    }

    private static func letterE(_ x: CGFloat) -> Path {
        let center = CGPoint(x: x + bowl.width, y: bowlCenterY)
        var path = Path()
        path.move(to: CGPoint(x: x, y: center.y))
        path.addLine(to: CGPoint(x: center.x + bowl.width, y: center.y))
        addArc(to: &path, center: center, radii: bowl, from: 0, to: -2 * .pi + apertureAngle)
        return path
    }

    private static func letterT(_ x: CGFloat) -> Path {
        let hook: CGFloat = 14
        var path = Path()
        path.move(to: CGPoint(x: x, y: 18))
        path.addLine(to: CGPoint(x: x, y: baseline - hook))
        addArc(to: &path, center: CGPoint(x: x + hook, y: baseline - hook), radii: CGSize(width: hook, height: hook),
               from: .pi, to: .pi / 2)
        path.addLine(to: CGPoint(x: x + 17, y: baseline))
        path.move(to: CGPoint(x: x - 11, y: xHeight))
        path.addLine(to: CGPoint(x: x + 15, y: xHeight))
        return path
    }

    private static func letterC(_ x: CGFloat) -> Path {
        let center = CGPoint(x: x + bowl.width, y: bowlCenterY)
        var path = Path()
        path.move(to: ellipsePoint(center: center, radii: bowl, angle: -apertureAngle))
        addArc(to: &path, center: center, radii: bowl, from: -apertureAngle, to: -2 * .pi + apertureAngle)
        return path
    }

    private static func ellipsePoint(center: CGPoint, radii: CGSize, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radii.width * cos(angle), y: center.y + radii.height * sin(angle))
    }

    /// 椭圆弧（y 向下的参数角），拆成不超过 90° 的三次贝塞尔曲线；路径当前点须已在弧的起点。
    private static func addArc(to path: inout Path, center: CGPoint, radii: CGSize, from start: CGFloat, to end: CGFloat) {
        let count = max(1, Int((abs(end - start) / (.pi / 2) - 1e-6).rounded(.up)))
        let step = (end - start) / CGFloat(count)
        let handle = 4 / 3 * tan(step / 4)
        func tangent(_ angle: CGFloat) -> CGVector {
            CGVector(dx: -radii.width * sin(angle), dy: radii.height * cos(angle))
        }
        for index in 0..<count {
            let from = start + CGFloat(index) * step
            let to = from + step
            let p0 = ellipsePoint(center: center, radii: radii, angle: from)
            let p3 = ellipsePoint(center: center, radii: radii, angle: to)
            let t0 = tangent(from)
            let t3 = tangent(to)
            path.addCurve(to: p3,
                          control1: CGPoint(x: p0.x + handle * t0.dx, y: p0.y + handle * t0.dy),
                          control2: CGPoint(x: p3.x - handle * t3.dx, y: p3.y - handle * t3.dy))
        }
    }
}

/// SwiftUI 中字标的「inetic」部分。
struct KineticWordmarkLettersShape: Shape {
    func path(in rect: CGRect) -> Path {
        KineticWordmark.lettersPath(in: rect)
    }
}
