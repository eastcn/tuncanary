import AppKit
import Foundation
import TunCanaryCore
import TunCanarySystem
import TunCanaryProbe
import TunCanaryUI
import TunCanaryRuntime
import os
import Darwin

/// 命令行在创建 NSApplication 和通知器之前分流，避免检测命令触发界面或权限申请。
@main
enum TunCanaryMain {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--export-icon" {
            guard arguments.count == 2 else { fail("用法：--export-icon <iconset 目录>", code: 64) }
            do { try exportIcon(to: URL(fileURLWithPath: arguments[1], isDirectory: true)) }
            catch { fail("导出图标失败：\(error.localizedDescription)", code: 1) }
            return
        }
        if arguments.first == "--unregister-login-item" {
            guard arguments.count == 1 else { fail("--unregister-login-item 不接受其他参数", code: 64) }
            do { print(try MainAppLoginItemController().unregisterIfNeeded().message) }
            catch { fail(error.localizedDescription, code: 1) }
            return
        }
        switch CommandLineParser.parse(arguments) {
        case .help:
            print(CommandLineParser.usage)
        case .version:
            print("\(AppIdentity.name) \(AppIdentity.version)")
        case .usageError(let message):
            fail(message + "\n" + CommandLineParser.usage, code: CLIExitCode.usage.rawValue)
        case .check(let options):
            let settings = SettingsStore().load()
            let paths = KnownPaths.currentUser()
            let adapters = VPNAdapterStore(paths: paths).load()
            let runner = CheckRunner(snapshotProvider: SystemSnapshotProvider(paths: paths, adapters: adapters.adapters,
                                                                            proxySource: { settings.proxySource }),
                                     prober: URLSessionSiteProber(), settings: settings,
                                     paths: paths, adapters: adapters)
            Task {
                let verdict = await runner.run(options: options)
                let redactor = Redactor(homeDirectory: NSHomeDirectory(), intranetURL: settings.intranetURL,
                                        siteURLs: settings.sites.map(\.url))
                print(options.json ? verdict.renderJSON(redactor: redactor) : verdict.renderText(redactor: redactor))
                exit(verdict.exitCode.rawValue)
            }
            dispatchMain()
        case .app:
            let instance: ApplicationInstance
            do { instance = try ApplicationInstance() }
            catch { fail("无法建立应用实例锁：\(error.localizedDescription)", code: 1) }
            guard instance.isPrimary else {
                DistributedNotificationCenter.default().postNotificationName(
                    ApplicationInstance.showNotification, object: nil, deliverImmediately: true)
                return
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let delegate = PulseAppDelegate()
            application.delegate = delegate
            withExtendedLifetime((delegate, instance)) { application.run() }
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    private static func exportIcon(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let data = LogoRenderer.appIconPNG(pixelSize: size * scale)
                guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), options: .atomic)
            }
        }
    }
}

@MainActor
private final class PulseAppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var monitor: MonitorController?
    private var reopenObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SettingsStore()
        let model = AppModel(settings: store.load(), egressChecker: EgressIPChecker())
        let notifier = UserNotificationCenterNotifier()
        let loginItem = MainAppLoginItemController()
        let paths = KnownPaths.currentUser()
        // 适配器目录变化后，调度器在下一轮检查前重新加载；采集与判定读取同一个 registry。
        let adapterRegistry = VPNAdapterRegistry(store: VPNAdapterStore(paths: paths))
        var snapshotConfiguration = SystemSnapshotProvider.Configuration(
            paths: paths, proxySource: { SettingsStore().load().proxySource })
        snapshotConfiguration.adapters = { adapterRegistry.current.adapters }
        let monitor = MonitorController(model: model,
                                        snapshotProvider: SystemSnapshotProvider(configuration: snapshotConfiguration),
                                        prober: URLSessionSiteProber(), observer: SystemNetworkChangeObserver(),
                                        notifier: notifier, paths: paths, adapterRegistry: adapterRegistry)
        self.monitor = monitor
        model.actions = AppActions.live(settingsStore: store, notifier: notifier, loginItem: loginItem,
                                         recheck: { [weak monitor] in monitor?.recheck() },
                                         reloadAdapters: { [weak monitor] in monitor?.reloadAdapters() },
                                         settingsDidChange: { [weak monitor] in monitor?.settingsDidChange($0) })
        let statusController = StatusItemController(model: model)
        self.statusController = statusController
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: ApplicationInstance.showNotification, object: nil, queue: .main
        ) { [weak statusController] _ in
            Task { @MainActor [weak statusController] in statusController?.showPopover() }
        }
        notifier.onActivate = { [weak statusController] in statusController?.showPopover() }
        monitor.start()
        logger.info("菜单栏监控已启动")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logger.debug("app.reopen")
        statusController?.showPopover()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        statusController?.invalidate()
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
        logger.info("菜单栏监控已停止")
    }
}
