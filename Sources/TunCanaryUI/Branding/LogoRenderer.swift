import AppKit
import CoreGraphics
import ImageIO
import TunCanaryCore

/// TunCanary 的矢量 logo：一只朝右的金丝雀侧影。全部用 Core Graphics 绘制，不依赖 asset catalog。
///
/// - 菜单栏：18 pt 高的模板图像（只有剪影，眼睛挖空），右下角挖出圆孔，彩色状态徽标由
///   `StatusItemController` 以子视图叠加在孔上；检查进行中时右上角多三个小圆点。
/// - 应用图标：深蓝圆角方块 + 黄色金丝雀，喙前两道弧线表示“鸣叫”的探针，`appIconPNG(pixelSize:)` 导出任意尺寸。
///
/// 坐标一律为 y 轴向上（Core Graphics 默认）。
public enum LogoRenderer {
    // MARK: - 几何

    /// 金丝雀的组成部分，坐标为单位方框内的归一化值（y 向上）。
    enum Canary {
        static let headCenter = CGPoint(x: 0.66, y: 0.70)
        static let headRadius: CGFloat = 0.17
        static let bodyCenter = CGPoint(x: 0.47, y: 0.46)
        static let bodyRadii = CGSize(width: 0.31, height: 0.23)
        /// 身体椭圆的倾角（弧度），尾部一端朝左下。
        static let bodyTilt: CGFloat = 0.45
        /// 尾羽：从身体左下方展开的扇形。
        static let tail: [CGPoint] = [CGPoint(x: 0.25, y: 0.44), CGPoint(x: 0.00, y: 0.24),
                                      CGPoint(x: 0.04, y: 0.12), CGPoint(x: 0.15, y: 0.06),
                                      CGPoint(x: 0.35, y: 0.29)]
        static let beak: [CGPoint] = [CGPoint(x: 0.80, y: 0.76), CGPoint(x: 0.97, y: 0.68), CGPoint(x: 0.80, y: 0.61)]
        static let eyeCenter = CGPoint(x: 0.71, y: 0.74)
        static let eyeRadius: CGFloat = 0.045
        /// 翅膀：身体上的一片弧形，应用图标中用深色填充。
        static let wing: [CGPoint] = [CGPoint(x: 0.30, y: 0.50), CGPoint(x: 0.47, y: 0.62),
                                      CGPoint(x: 0.64, y: 0.50), CGPoint(x: 0.44, y: 0.38)]
    }

    static func map(_ point: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    static func polygon(_ points: [CGPoint], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { map($0, rect) })
        path.closeSubpath()
        return path
    }

    /// 金丝雀剪影的各个部分（头、身体、尾、喙），分别填充即得完整剪影。
    public static func canaryParts(in rect: CGRect) -> [CGPath] {
        let head = map(Canary.headCenter, rect)
        let headRadius = Canary.headRadius * rect.width
        let headPath = CGPath(ellipseIn: CGRect(x: head.x - headRadius, y: head.y - headRadius,
                                                width: headRadius * 2, height: headRadius * 2), transform: nil)
        let body = map(Canary.bodyCenter, rect)
        let rx = Canary.bodyRadii.width * rect.width
        let ry = Canary.bodyRadii.height * rect.height
        var transform = CGAffineTransform(translationX: body.x, y: body.y).rotated(by: Canary.bodyTilt)
        let bodyPath = CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &transform)
        return [bodyPath, headPath, polygon(Canary.tail, in: rect), polygon(Canary.beak, in: rect)]
    }

    /// 眼睛所在的圆。
    public static func canaryEye(in rect: CGRect) -> CGRect {
        let center = map(Canary.eyeCenter, rect)
        let radius = Canary.eyeRadius * rect.width
        return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// 翅膀（平滑的闭合曲线）。
    static func canaryWing(in rect: CGRect) -> CGPath {
        let p = Canary.wing.map { map($0, rect) }
        let path = CGMutablePath()
        path.move(to: p[0])
        path.addQuadCurve(to: p[2], control: p[1])
        path.addQuadCurve(to: p[0], control: p[3])
        path.closeSubpath()
        return path
    }

    // MARK: - 菜单栏

    /// 菜单栏图像尺寸（点）。
    public static let menuBarImageSize = CGSize(width: 24, height: 18)
    /// 状态徽标圆心（点，y 向上，相对菜单栏图像左下角）。
    public static let menuBarBadgeCenter = CGPoint(x: 19.3, y: 4.9)
    /// 状态徽标半径（点）。
    public static let menuBarBadgeRadius: CGFloat = 4.6
    /// 徽标与剪影之间的留白。
    static let menuBarBadgeGap: CGFloat = 1.2
    /// 金丝雀所在区域。
    static let menuBarGlyphRect = CGRect(x: 0.5, y: 1.0, width: 16.0, height: 16.0)

    /// 菜单栏模板图像：系统按菜单栏深浅自动着色。
    /// - Parameter isChecking: 检查进行中时在右上角叠加三个小圆点（静态，不闪烁）。
    public static func menuBarTemplateImage(isChecking: Bool) -> NSImage {
        let image = NSImage(size: menuBarImageSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawMenuBarGlyph(in: ctx, origin: .zero, color: NSColor.black.cgColor, isChecking: isChecking)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppIdentity.displayName
        return image
    }

    /// 绘制菜单栏金丝雀（单色），挖出眼睛和徽标位置。在透明图层中绘制，不会擦掉底下已有的内容。
    public static func drawMenuBarGlyph(in ctx: CGContext, origin: CGPoint, color: CGColor, isChecking: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        ctx.setFillColor(color)
        for part in canaryParts(in: menuBarGlyphRect) {
            ctx.addPath(part)
            ctx.fillPath()
        }

        if isChecking {
            for center in menuBarCheckingDots {
                ctx.fillEllipse(in: CGRect(x: center.x - 1.05, y: center.y - 1.05, width: 2.1, height: 2.1))
            }
        }

        // 挖空眼睛和徽标位置，让彩色徽标与剪影之间留出一圈空隙。
        let hole = menuBarBadgeRadius + menuBarBadgeGap
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: canaryEye(in: menuBarGlyphRect))
        ctx.fillEllipse(in: CGRect(x: menuBarBadgeCenter.x - hole, y: menuBarBadgeCenter.y - hole,
                                   width: hole * 2, height: hole * 2))

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// “进行中”指示：右上角三个小圆点。
    static let menuBarCheckingDots: [CGPoint] = [
        CGPoint(x: 16.9, y: 15.2),
        CGPoint(x: 19.6, y: 15.2),
        CGPoint(x: 22.3, y: 15.2),
    ]

    // MARK: - 状态徽标

    /// 绘制状态徽标：彩色圆底 + 形状符号（✓ ! ✕ ?），形状与颜色同时区分状态。
    public static func drawBadge(in ctx: CGContext, center c: CGPoint, radius r: CGFloat, severity: Severity, dark: Bool) {
        ctx.saveGState()
        ctx.setFillColor(StatusPalette.badgeFill(severity, dark: dark).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))

        let glyph = StatusPalette.badgeGlyph(severity, dark: dark).cgColor
        ctx.setStrokeColor(glyph)
        ctx.setFillColor(glyph)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * r, y: c.y + y * r) }
        func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
            let rr = radius * r
            let center = p(x, y)
            ctx.fillEllipse(in: CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2))
        }

        switch severity {
        case .ok:
            ctx.setLineWidth(r * 0.27)
            ctx.move(to: p(-0.42, 0.00))
            ctx.addLine(to: p(-0.12, -0.30))
            ctx.addLine(to: p(0.42, 0.30))
            ctx.strokePath()
        case .warning:
            ctx.setLineWidth(r * 0.28)
            ctx.move(to: p(0, 0.50))
            ctx.addLine(to: p(0, -0.06))
            ctx.strokePath()
            dot(0, -0.46, 0.16)
        case .critical:
            ctx.setLineWidth(r * 0.27)
            ctx.move(to: p(-0.31, 0.31))
            ctx.addLine(to: p(0.31, -0.31))
            ctx.move(to: p(-0.31, -0.31))
            ctx.addLine(to: p(0.31, 0.31))
            ctx.strokePath()
        case .unknown:
            ctx.setLineWidth(r * 0.24)
            ctx.move(to: p(-0.32, 0.22))
            ctx.addCurve(to: p(0, 0.54), control1: p(-0.32, 0.42), control2: p(-0.18, 0.54))
            ctx.addCurve(to: p(0.32, 0.24), control1: p(0.19, 0.54), control2: p(0.32, 0.42))
            ctx.addCurve(to: p(0, -0.08), control1: p(0.32, 0.04), control2: p(0, 0.06))
            ctx.addLine(to: p(0, -0.14))
            ctx.strokePath()
            dot(0, -0.46, 0.15)
        }
        ctx.restoreGState()
    }

    /// 状态徽标图像（随绘制时的深浅外观取色），供 SwiftUI 与 AppKit 使用。
    public static func badgeImage(severity: Severity, diameter: CGFloat) -> NSImage {
        let image = NSImage(size: CGSize(width: diameter, height: diameter), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let dark = NSAppearance.currentDrawing().isDarkAppearance
            drawBadge(in: ctx, center: CGPoint(x: rect.midX, y: rect.midY), radius: diameter / 2,
                      severity: severity, dark: dark)
            return true
        }
        image.accessibilityDescription = severity.displayName
        return image
    }

    // MARK: - 菜单栏预览（离屏渲染与测试用）

    /// 模拟菜单栏上的最终效果：菜单栏底色 + 按深浅着色的剪影 + 彩色徽标。
    /// - Parameters:
    ///   - severity: 徽标状态；首次启动、尚无结果时传 `.unknown`。
    ///   - scale: 像素倍数，例如 2 为 Retina。
    public static func menuBarSample(severity: Severity, isChecking: Bool, dark: Bool, scale: CGFloat) -> CGImage? {
        let padding = CGSize(width: 8, height: 3)
        let size = CGSize(width: menuBarImageSize.width + padding.width * 2,
                          height: menuBarImageSize.height + padding.height * 2)
        return rasterize(size: size, scale: scale) { ctx in
            let background = dark ? StatusPalette.rgb(0x2A2A2C) : StatusPalette.rgb(0xF0F0F2)
            ctx.setFillColor(background.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            let ink = dark ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.85)
            let origin = CGPoint(x: padding.width, y: padding.height)
            drawMenuBarGlyph(in: ctx, origin: origin, color: ink.cgColor, isChecking: isChecking)
            drawBadge(in: ctx,
                      center: CGPoint(x: origin.x + menuBarBadgeCenter.x, y: origin.y + menuBarBadgeCenter.y),
                      radius: menuBarBadgeRadius, severity: severity, dark: dark)
        }
    }

    // MARK: - 应用图标

    /// 彩色应用图标 PNG。构建脚本用它导出 16–1024 各尺寸，再用 iconutil 生成 `.icns`。
    /// 失败时返回空 Data（正常情况下不会发生）。
    public static func appIconPNG(pixelSize: Int) -> Data {
        guard let image = appIconCGImage(pixelSize: pixelSize) else { return Data() }
        return pngData(image)
    }

    /// 彩色应用图标位图。
    public static func appIconCGImage(pixelSize: Int) -> CGImage? {
        guard pixelSize > 0 else { return nil }
        let side = CGFloat(pixelSize)
        return rasterize(size: CGSize(width: side, height: side), scale: 1) { ctx in
            drawAppIcon(in: ctx, size: side)
        }
    }

    /// 彩色应用图标（矢量，按显示尺寸重绘），供弹窗等界面使用。
    public static func appIconImage(pointSize: CGFloat) -> NSImage {
        NSImage(size: CGSize(width: pointSize, height: pointSize), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawAppIcon(in: ctx, size: rect.width)
            return true
        }
    }

    /// 绘制应用图标。按 macOS 图标网格：1024 画布中主体为 824 的圆角方块，四周留出阴影空间。
    public static func drawAppIcon(in ctx: CGContext, size s: CGFloat) {
        let inset = s * 100 / 1024
        let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let w = body.width
        let corner = w * 0.225
        let bodyPath = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor { StatusPalette.rgb(hex, alpha: alpha).cgColor }

        // 投影
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.028, color: color(0x000000, 0.35))
        ctx.addPath(bodyPath)
        ctx.setFillColor(color(0x0C1B34))
        ctx.fillPath()
        ctx.restoreGState()

        // 底色：深蓝渐变 + 中部暖色辉光
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: space, colors: [color(0x1D4273), color(0x0A1630)] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY),
                                   end: CGPoint(x: body.midX, y: body.minY), options: [])
        }
        if let glow = CGGradient(colorsSpace: space, colors: [color(0xFFC83D, 0.22), color(0xFFC83D, 0)] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX, y: body.midY), startRadius: 0,
                                   endCenter: CGPoint(x: body.midX, y: body.midY), endRadius: w * 0.55, options: [])
        }
        ctx.restoreGState()

        let bird = CGRect(x: body.minX + w * 0.10, y: body.minY + w * 0.14, width: w * 0.66, height: w * 0.66)

        // 喙前两道弧线：鸣叫的探针
        let beakTip = map(Canary.beak[1], bird)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(w * 0.030, 1))
        ctx.setShadow(offset: .zero, blur: max(w * 0.03, 1), color: color(0x3BF0B8, 0.7))
        ctx.setStrokeColor(color(0x6BF5C8))
        for (index, radius) in [w * 0.075, w * 0.135].enumerated() {
            ctx.setStrokeColor(color(0x6BF5C8, index == 0 ? 1 : 0.7))
            ctx.addArc(center: beakTip, radius: radius, startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
            ctx.strokePath()
        }
        ctx.restoreGState()

        // 身体：黄色渐变，带柔和投影
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.012), blur: w * 0.03, color: color(0x000000, 0.35))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color(0xFFFFFF))
        for part in canaryParts(in: bird).dropLast() {
            ctx.addPath(part)
            ctx.fillPath()
        }
        // 只在已填充的剪影内叠加渐变（各部分的并集）。
        ctx.setBlendMode(.sourceIn)
        if let yellow = CGGradient(colorsSpace: space, colors: [color(0xFFE36E), color(0xF6B41E)] as CFArray,
                                   locations: [0, 1]) {
            ctx.drawLinearGradient(yellow, start: CGPoint(x: bird.midX, y: bird.maxY),
                                   end: CGPoint(x: bird.midX, y: bird.minY), options: [])
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // 翅膀、喙与眼睛
        ctx.saveGState()
        ctx.addPath(canaryWing(in: bird))
        ctx.setFillColor(color(0xE39A12, 0.9))
        ctx.fillPath()
        if let beak = canaryParts(in: bird).last {
            ctx.addPath(beak)
            ctx.setFillColor(color(0xFF8A3D))
            ctx.fillPath()
        }
        ctx.setFillColor(color(0x0C1B34))
        ctx.fillEllipse(in: canaryEye(in: bird))
        ctx.restoreGState()

        // 边缘高光
        if s >= 64 {
            ctx.saveGState()
            ctx.addPath(bodyPath)
            ctx.clip()
            ctx.addPath(bodyPath)
            ctx.setStrokeColor(color(0xFFFFFF, 0.14))
            ctx.setLineWidth(max(1, s / 256))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - 位图工具

    /// 在 sRGB 位图上下文中绘制（y 向上），返回位图。`size` 为点，`scale` 为像素倍数。
    public static func rasterize(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()
    }

    /// 编码为 PNG。
    public static func pngData(_ image: CGImage) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }
}
