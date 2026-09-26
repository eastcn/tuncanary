import AppKit
import AppKit
import Foundation
import TunCanaryCore
import TunCanaryUI

/// 离屏渲染预览 PNG，供人工检查排版与深浅色。
///
/// 只有设置了环境变量 `TUNCANARY_RENDER_DIR` 时才有用例；未设置时本套件为空，不计入用例数。例如：
///     TUNCANARY_RENDER_DIR="$TMPDIR/tuncanary-ui-previews" scripts/test.sh UI.RenderPreviews
enum UIRenderPreviewTests {
    static let environmentKey = "TUNCANARY_RENDER_DIR"

    static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var suite: TestSuite {
        guard let directory = outputDirectory else { return TestSuite("UI.RenderPreviews", []) }
        return TestSuite("UI.RenderPreviews", [
            TestCase("弹窗：各预览状态（浅色与深色）", timeout: 180) { t in
                try prepare(directory)
                for scenario in PreviewScenario.allCases {
                    for dark in [false, true] {
                        let data = await render(model: { AppModel.preview(scenario) }, dark: dark)
                        writePopover(data, to: directory, name: "popover-\(scenario.rawValue)-\(suffix(dark)).png", t)
                    }
                }
            },
            TestCase("设置与手动恢复步骤（浅色与深色）", timeout: 120) { t in
                try prepare(directory)
                for variant in SettingsVariant.allCases {
                    for dark in [false, true] {
                        let data = await render(model: { settingsModel(variant) }, dark: dark)
                        writePopover(data, to: directory, name: "settings-\(variant.rawValue)-\(suffix(dark)).png", t)
                    }
                }
                for dark in [false, true] {
                    let data = await render(model: {
                        let model = AppModel.preview(.dnsCritical)
                        model.route = .recovery
                        return model
                    }, dark: dark)
                    writePopover(data, to: directory, name: "recovery-\(suffix(dark)).png", t)
                }
            },
            TestCase("菜单栏图标：各状态（浅色与深色菜单栏）") { t in
                try prepare(directory)
                for dark in [false, true] {
                    for severity in Severity.allCases {
                        for checking in [false, true] {
                            let name = "menubar-\(severity.rawValue)\(checking ? "-checking" : "")-\(suffix(dark)).png"
                            let data = await MainActor.run {
                                PreviewSnapshotRenderer.menuBarPNG(severity: severity, isChecking: checking, dark: dark, scale: 8)
                            }
                            write(data, to: directory, name: name, t)
                        }
                    }
                    write(menuBarSheet(dark: dark), to: directory, name: "menubar-sheet-\(suffix(dark)).png", t)
                }
            },
            TestCase("应用图标：16 到 1024") { t in
                try prepare(directory)
                for size in UILogoTests.iconSizes {
                    write(LogoRenderer.appIconPNG(pixelSize: size), to: directory, name: "appicon-\(size).png", t)
                }
            },
        ])
    }

    /// 设置页的几种状态。
    enum SettingsVariant: String, CaseIterable {
        /// 默认：通知已允许、登录项关闭。
        case normal
        /// 需处理：输入有误、通知被拒绝、登录项待批准。
        case attention
        /// 命令行环境：通知与登录项不可用、通知尚未授权。
        case unavailable
    }

    @MainActor
    static func settingsModel(_ variant: SettingsVariant) -> AppModel {
        let model = AppModel.preview(.allGreen)
        model.route = .settings
        switch variant {
        case .normal:
            model.notificationAuthorization = .authorized
            model.loginItemStatus = .disabled
        case .attention:
            model.settingsDraft.intranetURL = "intranet.corp.example/health"
            model.settingsDraft.expectedDNS = "119.29.29.29, 223.5.5.500"
            model.settingsDraft.localCheckInterval = "4"
            model.settingsDraft.lightProbeInterval = "120.5"
            model.settingsDraft.proxyClient = .manual
            model.settingsDraft.manualDNSPort = "70000"
            model.notificationAuthorization = .denied
            model.loginItemStatus = .requiresApproval
        case .unavailable:
            model.settings = AppSettings()
            model.settingsDraft = SettingsDraft(settings: model.settings)
            model.notificationsAvailable = false
            model.notificationAuthorization = .denied
            model.loginItemStatus = .unavailable
        }
        return model
    }

    static func suffix(_ dark: Bool) -> String { dark ? "dark" : "light" }

    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @MainActor
    static func render(model make: @MainActor () -> AppModel, dark: Bool) async -> Data? {
        await PreviewSnapshotRenderer.popoverPNG(model: make(), dark: dark, scale: 2)
    }

    static func write(_ data: Data?, to directory: URL, name: String, _ t: TestContext) {
        guard let data, data.count > 100 else {
            t.fail("\(name) 渲染失败")
            return
        }
        do {
            try data.write(to: directory.appendingPathComponent(name))
        } catch {
            t.fail("\(name) 写入失败：\(error)")
        }
    }

    /// 常规预览应模拟限高弹窗；否则全展开内容会生成超过屏幕的图片。
    static func writePopover(_ data: Data?, to directory: URL, name: String, _ t: TestContext) {
        write(data, to: directory, name: name, t)
        guard let data, let image = NSBitmapImageRep(data: data) else { return }
        t.expectEqual(image.pixelsWide, 760, "\(name) 应为 380 pt 宽的 Retina 弹窗")
        t.expect(image.pixelsHigh <= 1_600, "\(name) 应在 800 pt 内；实际为 \(image.pixelsHigh / 2) pt")
    }

    /// 全部菜单栏状态并排（2 倍），便于一眼对比：上排为空闲，下排为进行中。
    static func menuBarSheet(dark: Bool) -> Data? {
        let scale: CGFloat = 4
        let cell = CGSize(width: 40, height: 24)
        let columns = Severity.allCases.count
        let size = CGSize(width: cell.width * CGFloat(columns), height: cell.height * 2)
        let image = LogoRenderer.rasterize(size: size, scale: scale) { ctx in
            for (column, severity) in Severity.allCases.enumerated() {
                for (row, checking) in [true, false].enumerated() {
                    guard let sample = LogoRenderer.menuBarSample(severity: severity, isChecking: checking,
                                                                  dark: dark, scale: scale) else { continue }
                    ctx.draw(sample, in: CGRect(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height,
                                                width: cell.width, height: cell.height))
                }
            }
        }
        return image.map(LogoRenderer.pngData)
    }
}
