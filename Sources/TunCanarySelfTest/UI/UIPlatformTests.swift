import Foundation
import TunCanaryCore
import TunCanaryUI
import ServiceManagement
import UserNotifications

/// 通知器与登录项在非 .app 环境下的降级行为，以及 `AppActions.live` 的接线。
/// 测试运行器不在 .app 包内：全程不会触碰 UNUserNotificationCenter 与 SMAppService。
enum UIPlatformTests {
    static let appEnvironment = AppBundleEnvironment(
        bundleIdentifier: AppIdentity.bundleID, bundlePath: "/Users/tester/Applications/TunCanary.app")
    static let cliEnvironment = AppBundleEnvironment(
        bundleIdentifier: nil, bundlePath: "/Users/tester/projects/tuncanary/.build/debug")

    final class StubNotifier: UserNotifying {
        var delivered: [PendingNotification] = []
        var status: NotificationAuthorization = .notDetermined
        func requestAuthorization() async -> Bool {
            status = .authorized
            return true
        }
        func authorizationStatus() async -> NotificationAuthorization { status }
        func deliver(_ notification: PendingNotification) async { delivered.append(notification) }
    }

    final class StubLoginItem: LoginItemControlling {
        var status: LoginItemStatus = .disabled
        var opened = 0
        func setEnabled(_ enabled: Bool) throws { status = enabled ? .enabled : .disabled }
        func openSystemSettings() { opened += 1 }
    }

    final class StubMainAppService: MainAppServiceControlling {
        var status: SMAppService.Status
        var registerCalls = 0
        var unregisterCalls = 0
        init(_ status: SMAppService.Status) { self.status = status }
        func register() throws { registerCalls += 1 }
        func unregister() throws {
            unregisterCalls += 1
            // 模拟系统：未登记的服务注销会报错。
            guard status == .enabled || status == .requiresApproval else {
                throw NSError(domain: "SMAppServiceErrorDomain", code: 3)
            }
            status = .notRegistered
        }
    }

    static var suite: TestSuite {
        TestSuite("UI.Platform", [
            TestCase("M5：单实例锁默认位于 Application Support/TunCanary") { t in
                let expected = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/TunCanary/instance.lock")
                t.expectEqual(ApplicationInstance.defaultLockURL.standardizedFileURL.path, expected.standardizedFileURL.path)
            },
            TestCase("M5：锁目录不存在时以 700 创建；同一锁只有一个主实例") { t in
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tuncanary-lock-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let lock = root.appendingPathComponent("TunCanary/instance.lock")
                var first: ApplicationInstance? = try ApplicationInstance(lockURL: lock, otherInstanceRunning: { false })
                t.expectEqual(first?.isPrimary, true)
                let attributes = try FileManager.default.attributesOfItem(atPath: lock.deletingLastPathComponent().path)
                t.expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
                let second = try ApplicationInstance(lockURL: lock, otherInstanceRunning: { false })
                t.expect(!second.isPrimary, "锁被占用时不是主实例")
                first = nil
                t.expect(try ApplicationInstance(lockURL: lock, otherInstanceRunning: { false }).isPrimary,
                         "原实例退出后可重新取得锁")
            },
            TestCase("M5：锁可用但已有其他 pid 的实例在运行时不是主实例") { t in
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tuncanary-lock-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let lock = root.appendingPathComponent("instance.lock")
                t.expect(!(try ApplicationInstance(lockURL: lock, otherInstanceRunning: { true }).isPrimary))
                t.expect(try ApplicationInstance(lockURL: lock, otherInstanceRunning: { false }).isPrimary)
            },
            TestCase("M4：登录项未注册或 .notFound 时注销视为成功，不调用 unregister") { t in
                for status in [SMAppService.Status.notFound, .notRegistered] {
                    let service = StubMainAppService(status)
                    let controller = MainAppLoginItemController(environment: appEnvironment, service: service)
                    do {
                        try controller.setEnabled(false)
                    } catch {
                        t.fail("状态 \(status.rawValue) 时注销不应失败：\(error)")
                    }
                    t.expectEqual(service.unregisterCalls, 0, "状态 \(status.rawValue) 无需注销")
                }
                let notFound = MainAppLoginItemController(environment: appEnvironment,
                                                          service: StubMainAppService(.notFound))
                t.expectEqual(try notFound.unregisterIfNeeded(), .notFound)
                t.expectContains(LoginItemUnregisterResult.notFound.message, "无需注销")
                let enabled = StubMainAppService(.enabled)
                t.expectEqual(try MainAppLoginItemController(environment: appEnvironment, service: enabled)
                    .unregisterIfNeeded(), .unregistered)
                t.expectThrows(try MainAppLoginItemController(environment: cliEnvironment).unregisterIfNeeded())
                for status in [SMAppService.Status.enabled, .requiresApproval] {
                    let service = StubMainAppService(status)
                    let controller = MainAppLoginItemController(environment: appEnvironment, service: service)
                    do { try controller.setEnabled(false) } catch { t.fail("注销失败：\(error)") }
                    t.expectEqual(service.unregisterCalls, 1, "状态 \(status.rawValue) 应注销")
                }
            },
            TestCase("包环境：bundle id 非空且路径以 .app 结尾") { t in
                t.expect(appEnvironment.isAppBundle)
                t.expect(AppBundleEnvironment(bundleIdentifier: "x", bundlePath: "/Applications/Foo.APP/").isAppBundle)
                t.expect(!cliEnvironment.isAppBundle)
                t.expect(!AppBundleEnvironment(bundleIdentifier: "", bundlePath: "/Applications/Foo.app").isAppBundle)
                t.expect(!AppBundleEnvironment(bundleIdentifier: nil, bundlePath: "/Applications/Foo.app").isAppBundle)
                t.expect(!AppBundleEnvironment(bundleIdentifier: "x", bundlePath: "/usr/local/bin").isAppBundle)
                t.expect(!AppBundleEnvironment.current.isAppBundle, "测试运行器不在 .app 包内")
            },
            TestCase("通知器：非 .app 环境全部为空操作") { t in
                for notifier in [UserNotificationCenterNotifier(environment: cliEnvironment), UserNotificationCenterNotifier()] {
                    t.expect(!notifier.isAvailable)
                    let granted = await notifier.requestAuthorization()
                    t.expect(!granted, "不可用时不申请权限")
                    let status = await notifier.authorizationStatus()
                    t.expectEqual(status, .denied, "不可用时视为不能发送")
                    await notifier.deliver(PendingNotification(key: .dnsNotRestored, severity: .critical,
                                                               title: "TunCanary：故障", body: "测试"))
                }
            },
            TestCase("通知授权状态映射") { t in
                t.expectEqual(UserNotificationCenterNotifier.map(.notDetermined), .notDetermined)
                t.expectEqual(UserNotificationCenterNotifier.map(.denied), .denied)
                t.expectEqual(UserNotificationCenterNotifier.map(.authorized), .authorized)
                t.expectEqual(UserNotificationCenterNotifier.map(.provisional), .authorized)
            },
            TestCase("登录项：非 .app 环境为 unavailable，不触碰系统") { t in
                var opened = 0
                let controller = MainAppLoginItemController(environment: cliEnvironment, openSettings: { opened += 1 })
                t.expectEqual(controller.status, .unavailable)
                do {
                    try controller.setEnabled(true)
                    t.fail("不可用时应抛错")
                } catch let error as LoginItemControlError {
                    t.expectEqual(error, .unavailable)
                    t.expectEqual(error.message, "登录时启动仅在安装后的应用包中可用")
                } catch {
                    t.fail("错误类型不对：\(error)")
                }
                t.expectThrows(try controller.setEnabled(false))
                controller.openSystemSettings()
                t.expectEqual(opened, 0, "不可用时不打开系统设置")
                t.expectEqual(MainAppLoginItemController().status, .unavailable, "测试运行器中默认环境同样降级")
            },
            TestCase("登录项状态映射") { t in
                t.expectEqual(MainAppLoginItemController.map(.enabled), .enabled)
                t.expectEqual(MainAppLoginItemController.map(.notRegistered), .disabled)
                t.expectEqual(MainAppLoginItemController.map(.requiresApproval), .requiresApproval)
                t.expectEqual(MainAppLoginItemController.map(.notFound), .unavailable)
                t.expectEqual(LoginItemControlError.failed("被拒绝").message, "无法更改登录时启动：被拒绝")
            },
            TestCase("系统设置链接：通知页带 bundle id") { t in
                let urls = SystemSettingsLinks.notificationSettingsURLs()
                t.expectEqual(urls.first?.absoluteString,
                              "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.eastcn.tuncanary")
                t.expect(urls.count >= 2, "应有退回的通知总页")
            },
            TestCase("AppActions.live：保存设置、登录项与通知的接线") { t in
                let (suite, directory) = try SettingsTests.makeTemporaryDefaultsSuite()
                defer { SettingsTests.removeTemporaryDefaultsSuite(suite, directory: directory) }
                await liveActions(t, store: SettingsStore(suiteName: suite))
            },
        ])
    }

    @MainActor
    static func liveActions(_ t: TestContext, store: SettingsStore) async {
        let notifier = StubNotifier()
        let loginItem = StubLoginItem()
        var rechecks = 0
        var changed: [AppSettings] = []
        let actions = AppActions.live(settingsStore: store, notifier: notifier, loginItem: loginItem,
                                      recheck: { rechecks += 1 }, settingsDidChange: { changed.append($0) })
        let model = AppModel(actions: actions)

        model.recheck()
        t.expectEqual(rechecks, 1)

        model.openSettings()
        model.settingsDraft.intranetURL = "https://intranet.corp.example/health"
        model.settingsDraft.expectedDNS = "119.29.29.29, 223.5.5.5"
        t.expect(model.saveSettings())
        let saved = store.load()
        t.expectEqual(saved.intranetURL?.absoluteString, "https://intranet.corp.example/health")
        t.expectEqual(saved.expectedDNS, ["119.29.29.29", "223.5.5.5"])
        t.expectEqual(changed, [saved])

        model.setLoginItemEnabled(true)
        t.expectEqual(model.loginItemStatus, .enabled)
        model.openLoginItemSettings()
        t.expectEqual(loginItem.opened, 1)

        await model.refreshSystemStatus()
        t.expect(model.notificationsAvailable, "桩通知器视为可用")
        t.expectEqual(model.notificationAuthorization, .notDetermined)
        await model.requestNotificationPermission()
        t.expectEqual(model.notificationAuthorization, .authorized)

        let unavailable = AppActions.live(settingsStore: store, notifier: UserNotificationCenterNotifier(),
                                          loginItem: MainAppLoginItemController(), recheck: {})
        t.expect(!unavailable.notificationsAvailable(), "非 .app 环境通知不可用")
        t.expectEqual(unavailable.loginItemStatus(), .unavailable)
        let status = await unavailable.notificationAuthorization()
        t.expectEqual(status, .denied)
    }
}
