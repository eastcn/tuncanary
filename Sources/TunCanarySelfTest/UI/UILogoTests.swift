import AppKit
import Foundation
import ImageIO
import TunCanaryCore
import TunCanaryUI

/// logo、菜单栏图标与应用图标能在各尺寸生成非空图像。
enum UILogoTests {
    /// RGBA 位图（8 位、预乘），`pixel(x:y:)` 的 y 以底边为 0。
    struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard ok else { return nil }
            bytes = buffer
        }

        func pixel(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let row = height - 1 - y
            let i = (row * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }

        /// 不透明度超过阈值的像素数。
        func inkCount(alphaAbove threshold: Int = 40) -> Int {
            stride(from: 3, to: bytes.count, by: 4).filter { Int(bytes[$0]) > threshold }.count
        }
    }

    /// 把 NSImage 按 `scale` 倍绘制成位图。
    static func rasterize(_ image: NSImage, scale: CGFloat) -> CGImage? {
        let size = image.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 徽标位图（半径 20 px）。
    static func badgeBitmap(_ severity: Severity, dark: Bool) -> Bitmap? {
        LogoRenderer.rasterize(size: CGSize(width: 40, height: 40), scale: 1) { ctx in
            LogoRenderer.drawBadge(in: ctx, center: CGPoint(x: 20, y: 20), radius: 20, severity: severity, dark: dark)
        }.flatMap(Bitmap.init)
    }

    static let iconSizes = [16, 32, 64, 128, 256, 512, 1024]

    static var suite: TestSuite {
        TestSuite("UI.Logo", [
            TestCase("菜单栏模板图像：18 pt 高、模板、可绘制并留出徽标孔") { t in
                await MainActor.run {
                    for checking in [false, true] {
                        let image = LogoRenderer.menuBarTemplateImage(isChecking: checking)
                        t.expectEqual(image.size.height, 18)
                        t.expectEqual(image.size, LogoRenderer.menuBarImageSize)
                        t.expect(image.isTemplate, "应为模板图像，由系统按菜单栏深浅着色")
                    }
                    guard let idle = rasterize(LogoRenderer.menuBarTemplateImage(isChecking: false), scale: 2).flatMap(Bitmap.init),
                          let busy = rasterize(LogoRenderer.menuBarTemplateImage(isChecking: true), scale: 2).flatMap(Bitmap.init)
                    else { return t.fail("菜单栏图像无法绘制") }
                    t.expectEqual(idle.width, 48)
                    t.expectEqual(idle.height, 36)
                    t.expect(idle.inkCount() > 60, "剪影应有足够的像素：\(idle.inkCount())")
                    t.expect(busy.inkCount() > idle.inkCount(), "进行中应多出指示点")
                    let center = LogoRenderer.menuBarBadgeCenter
                    t.expectEqual(idle.pixel(x: Int(center.x * 2), y: Int(center.y * 2)).a, 0, "徽标位置应挖空")
                }
            },
            TestCase("状态徽标：四种状态颜色与形状都不同") { t in
                for dark in [false, true] {
                    var fills: [Severity: [Int]] = [:]
                    var glyphs: [Severity: [Bool]] = [:]
                    for severity in Severity.allCases {
                        guard let bitmap = badgeBitmap(severity, dark: dark) else { return t.fail("徽标无法绘制") }
                        let fill = bitmap.pixel(x: 20, y: 4)
                        t.expectEqual(fill.a, 255, "\(severity) 底色应不透明")
                        fills[severity] = [fill.r, fill.g, fill.b]
                        // 圆内与底色明显不同的像素即符号。
                        var mask: [Bool] = []
                        for y in 0..<40 {
                            for x in 0..<40 {
                                let dx = Double(x) + 0.5 - 20, dy = Double(y) + 0.5 - 20
                                guard dx * dx + dy * dy < 17 * 17 else { continue }
                                let p = bitmap.pixel(x: x, y: y)
                                mask.append(abs(p.r - fill.r) + abs(p.g - fill.g) + abs(p.b - fill.b) > 120)
                            }
                        }
                        let glyphPixels = mask.filter { $0 }.count
                        t.expect(glyphPixels > 40, "\(severity) 应有可见符号：\(glyphPixels)")
                        glyphs[severity] = mask
                    }
                    t.expectEqual(Set(fills.values).count, 4, "四种状态底色应互不相同（dark=\(dark)）")
                    let all = Severity.allCases
                    for i in 0..<all.count {
                        for j in (i + 1)..<all.count {
                            let a = glyphs[all[i]] ?? [], b = glyphs[all[j]] ?? []
                            let diff = zip(a, b).filter { $0 != $1 }.count
                            t.expect(diff > 40, "\(all[i]) 与 \(all[j]) 的符号形状应不同：\(diff)")
                        }
                    }
                }
            },
            TestCase("徽标图像与菜单栏预览：各状态、深浅色都能生成") { t in
                await MainActor.run {
                    for severity in Severity.allCases {
                        let badge = LogoRenderer.badgeImage(severity: severity, diameter: 16)
                        t.expectEqual(badge.size, CGSize(width: 16, height: 16))
                        let ink = rasterize(badge, scale: 2).flatMap(Bitmap.init)?.inkCount() ?? 0
                        t.expect(ink > 100, "\(severity) 徽标图像应非空：\(ink)")
                        for checking in [false, true] {
                            for dark in [false, true] {
                                guard let sample = LogoRenderer.menuBarSample(severity: severity, isChecking: checking,
                                                                              dark: dark, scale: 2) else {
                                    t.fail("菜单栏预览生成失败：\(severity) \(checking) \(dark)")
                                    continue
                                }
                                t.expectEqual(sample.width, 80)
                                t.expectEqual(sample.height, 48)
                            }
                        }
                    }
                }
            },
            TestCase("菜单栏预览：进行中保留徽标颜色") { t in
                let center = LogoRenderer.menuBarBadgeCenter
                // 预览在图像四周各留 8×3 pt。
                let x = Int((center.x + 8) * 4), y = Int((center.y + 3 - LogoRenderer.menuBarBadgeRadius * 0.8) * 4)
                for severity in Severity.allCases {
                    guard let idle = LogoRenderer.menuBarSample(severity: severity, isChecking: false, dark: false, scale: 4)
                            .flatMap(Bitmap.init),
                          let busy = LogoRenderer.menuBarSample(severity: severity, isChecking: true, dark: false, scale: 4)
                            .flatMap(Bitmap.init)
                    else { return t.fail("菜单栏预览生成失败") }
                    let a = idle.pixel(x: x, y: y), b = busy.pixel(x: x, y: y)
                    t.expect(a == b, "\(severity) 进行中徽标颜色应不变：\(a) vs \(b)")
                    let expected = StatusPalette.badgeFill(severity, dark: false).usingColorSpace(.sRGB)!
                    t.expect(abs(a.r - Int(expected.redComponent * 255)) <= 3
                             && abs(a.g - Int(expected.greenComponent * 255)) <= 3
                             && abs(a.b - Int(expected.blueComponent * 255)) <= 3,
                             "\(severity) 徽标颜色应为状态色：\(a)")
                }
            },
            TestCase("应用图标：16 到 1024 各尺寸生成非空 PNG") { t in
                for size in iconSizes {
                    let data = LogoRenderer.appIconPNG(pixelSize: size)
                    t.expect(data.count > 100, "\(size) PNG 过小：\(data.count)")
                    t.expectEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "\(size) 应为 PNG")
                    guard let image = decodePNG(data), let bitmap = Bitmap(image) else {
                        t.fail("\(size) PNG 无法解码")
                        continue
                    }
                    t.expectEqual(image.width, size)
                    t.expectEqual(image.height, size)
                    let center = bitmap.pixel(x: size / 2, y: size / 2)
                    t.expect(center.a > 200, "\(size) 中心应不透明：\(center)")
                    t.expectEqual(bitmap.pixel(x: 0, y: size - 1).a, 0, "\(size) 左上角应透明（圆角外）")
                    let body = bitmap.pixel(x: size / 2, y: size * 3 / 10)
                    t.expect(body.b > body.r, "\(size) 底色应为蓝色调：\(body)")
                }
                t.expect(LogoRenderer.appIconPNG(pixelSize: 0).isEmpty, "非法尺寸返回空")
            },
            TestCase("应用图标矢量版可在界面中绘制") { t in
                await MainActor.run {
                    let image = LogoRenderer.appIconImage(pointSize: 32)
                    let ink = rasterize(image, scale: 2).flatMap(Bitmap.init)?.inkCount() ?? 0
                    t.expect(ink > 32 * 32 * 2, "应用图标矢量版应非空：\(ink)")
                }
            },
            TestCase("应用图标：金丝雀身体为黄色，眼睛为深色") { t in
                guard let image = LogoRenderer.appIconCGImage(pixelSize: 512), let bitmap = Bitmap(image) else {
                    return t.fail("应用图标无法绘制")
                }
                // 512 画布：主体方块从 50 开始、边长 412；金丝雀区域从 (91, 108) 开始、边长约 272。
                let belly = bitmap.pixel(x: 219, y: 189)
                t.expect(belly.r > 200 && belly.g > 140 && belly.b < 110, "身体应为黄色：\(belly)")
                let eye = bitmap.pixel(x: 284, y: 309)
                t.expect(eye.r < 60 && eye.b > eye.r, "眼睛应为深蓝色：\(eye)")
            },
            TestCase("菜单栏剪影：眼睛挖空") { t in
                await MainActor.run {
                    let image = LogoRenderer.menuBarTemplateImage(isChecking: false)
                    guard let bitmap = rasterize(image, scale: 2).flatMap(Bitmap.init) else { return t.fail("无法绘制") }
                    t.expectEqual(bitmap.pixel(x: 23, y: 25).a, 0, "眼睛位置应透明")
                    t.expect(bitmap.pixel(x: 19, y: 25).a > 200, "头部应不透明")
                }
            },
        ])
    }
}
