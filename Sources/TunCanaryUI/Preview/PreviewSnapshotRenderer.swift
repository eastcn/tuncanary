import AppKit
import SwiftUI
import TunCanaryCore

/// 离屏渲染：把 SwiftUI 视图或菜单栏图标输出为 PNG，用于检查排版和深浅色效果。
///
/// 使用不显示的无边框窗口承载 NSHostingView，再 `cacheDisplay` 到位图，不会在屏幕上出现窗口，
/// 也不会激活应用。进程不是前台应用，原生开关等控件会以“非活动窗口”的样式绘制。
@MainActor
public enum PreviewSnapshotRenderer {
    /// 渲染任意视图。高度取视图的理想高度。
    /// - Parameters:
    ///   - width: 宽度（点）。
    ///   - dark: 深色外观。
    ///   - scale: 像素倍数，默认 2（Retina）。
    public static func pngData<V: View>(of view: V, width: CGFloat, dark: Bool, scale: CGFloat = 2) async -> Data? {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting

        // 等 SwiftUI 完成布局（偏好值回传后高度可能变化），再按理想高度定尺寸。
        var size = hosting.fittingSize
        for _ in 0..<3 {
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: max(size.height, 1))
            window.setContentSize(hosting.frame.size)
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 60_000_000)
            let next = hosting.fittingSize
            if abs(next.height - size.height) < 0.5 { break }
            size = next
        }
        size = CGSize(width: width, height: ceil(max(hosting.fittingSize.height, 1)))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 60_000_000)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        window.close()
        return rep.representation(using: .png, properties: [:])
    }

    /// 按实际弹窗的默认滚动高度渲染，预览尺寸与用户看到的弹窗一致。
    public static func popoverPNG(model: AppModel, dark: Bool, scale: CGFloat = 2) async -> Data? {
        await pngData(of: PopoverRootView(model: model),
                      width: PopoverMetrics.width, dark: dark, scale: scale)
    }

    /// 模拟菜单栏上的图标效果（菜单栏底色 + 着色剪影 + 彩色徽标）。
    public static func menuBarPNG(severity: Severity, isChecking: Bool, dark: Bool, scale: CGFloat) -> Data? {
        LogoRenderer.menuBarSample(severity: severity, isChecking: isChecking, dark: dark, scale: scale)
            .map(LogoRenderer.pngData)
    }
}
