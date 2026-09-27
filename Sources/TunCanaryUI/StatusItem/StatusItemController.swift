import AppKit
import Combine
import SwiftUI
import TunCanaryCore
import os

/// 管理菜单栏图标与弹窗。
///
/// - 图标：`button.image` 为模板图像（金丝雀剪影，系统自动适配深浅色菜单栏），彩色状态徽标是叠加在
///   按钮上的子视图 `StatusBadgeView`，位置与模板图像中挖出的圆孔对齐。
/// - 检查进行中：颜色保持上一轮结果，只在模板图像右上角加三个小圆点。为避免每 20 秒闪一次，
///   检查持续超过 `indicatorDelay` 才显示，显示后至少保留 `indicatorMinimumVisible`。
/// - 悬停提示取 `OverallAssessment.tooltip`，辅助功能标签为 “TunCanary：<状态>”。
/// - 点击切换 NSPopover（`.transient`），弹窗内容为 NSHostingController 承载的 `PopoverRootView`。
/// - `.transient` 只在应用处于激活状态时可靠：应用失去激活后，点击其他应用不一定能收起弹窗。
///   所以弹窗打开期间另外监听其他应用中的鼠标按下和应用失去激活，两者都收起弹窗。
/// - 弹窗显示后关闭尺寸动画：检查结果更新时内容高度会变，带动画调整尺寸后光标区域可能没有刷新，
///   指针会一直不可见，直到点击或移出弹窗。尺寸变化后也主动刷新一次光标区域。
///
/// 创建即在菜单栏显示图标；只应在应用模式下创建（命令行与测试中不要创建）。
@MainActor
public final class StatusItemController: NSObject, NSPopoverDelegate {
    public let model: AppModel
    public let statusItem: NSStatusItem
    public let popover: NSPopover

    /// 检查持续多久后才显示“进行中”指示（秒）。
    public var indicatorDelay: TimeInterval = 0.8
    /// “进行中”指示显示后至少保留多久（秒）。
    public var indicatorMinimumVisible: TimeInterval = 1.0

    private let hostingController: NSHostingController<PopoverRootView>
    private let badgeView = StatusBadgeView()
    private let idleImage = LogoRenderer.menuBarTemplateImage(isChecking: false)
    private let checkingImage = LogoRenderer.menuBarTemplateImage(isChecking: true)
    private var cancellables: Set<AnyCancellable> = []
    private var indicatorVisible = false
    private var indicatorShownAt: Date?
    private var indicatorTask: Task<Void, Never>?
    /// 弹窗打开期间：其他应用中的鼠标按下。
    private var outsideClickMonitor: Any?
    /// 弹窗打开期间：应用失去激活。
    private var resignObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - model: 界面的视图模型。
    ///   - statusBar: 默认为系统菜单栏。
    public init(model: AppModel, statusBar: NSStatusBar = .system) {
        self.model = model
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        hostingController = NSHostingController(rootView: PopoverRootView(model: model))
        hostingController.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.delegate = self

        // 使用固定名称保存菜单栏位置与可见状态。
        statusItem.autosaveName = "TunCanary.StatusItem"
        configureButton()
        bind()
        refresh()
    }

    /// 从菜单栏移除图标（退出前可调用）。
    public func invalidate() {
        indicatorTask?.cancel()
        stopDismissMonitors()
        cancellables.removeAll()
        popover.performClose(nil)
        statusItem.statusBar?.removeStatusItem(statusItem)
    }

    // MARK: 弹窗

    @objc public func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    /// 打开弹窗（通知被点击时也可调用）。
    public func showPopover() {
        Logger(subsystem: AppIdentity.bundleID, category: "interface").debug("popover.show")
        guard let button = statusItem.button else { return }
        let visibleHeight = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        hostingController.rootView = PopoverRootView(
            model: model, maxScrollHeight: Self.maxScrollHeight(forVisibleHeight: visibleHeight))
        NSApp.activate(ignoringOtherApps: true)
        popover.animates = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startDismissMonitors()
        let window = popover.contentViewController?.view.window
        window?.makeKey()
        clearInitialFocus(in: window)
        Task { await model.refreshSystemStatus() }
    }

    /// 弹窗成为主窗口后，AppKit 会把焦点交给第一个可聚焦的控件（“立即复测”），
    /// 按钮显示为选中，按空格或回车会误触发复测。这里清掉初始焦点；SwiftUI 在布局后可能再次分配，
    /// 所以下一轮主循环再清一次。按 Tab 仍可用键盘在控件间移动。
    private func clearInitialFocus(in window: NSWindow?) {
        guard let window else { return }
        window.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isKeyWindow else { return }
            window.makeFirstResponder(nil)
        }
    }

    public func closePopover() {
        guard popover.isShown else { return }
        popover.animates = true
        popover.performClose(nil)
    }

    public func popoverDidShow(_ notification: Notification) {
        // 打开动画结束后，内容尺寸变化直接生效，不再动画。
        popover.animates = false
    }

    public func popoverDidClose(_ notification: Notification) {
        Logger(subsystem: AppIdentity.bundleID, category: "interface").debug("popover.close")
        stopDismissMonitors()
        model.popoverDidClose()
    }

    private func startDismissMonitors() {
        stopDismissMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopover() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopover() }
        }
    }

    private func stopDismissMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// 内容尺寸变化后刷新光标区域；指针在弹窗内时恢复为箭头，移动后由各控件重新设置。
    private func refreshCursor() {
        guard popover.isShown, let window = popover.contentViewController?.view.window,
              let contentView = window.contentView else { return }
        window.invalidateCursorRects(for: contentView)
        if window.frame.contains(NSEvent.mouseLocation) {
            NSCursor.arrow.set()
        }
    }

    /// 可滚动区域的最大高度：给顶部、操作区、工具区和底栏留出约 320 pt。
    public static func maxScrollHeight(forVisibleHeight height: CGFloat) -> CGFloat {
        max(260, min(PopoverMetrics.defaultMaxScrollHeight, height - 320))
    }

    // MARK: 图标

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = idleImage
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // 徽标子视图与模板图像中的圆孔对齐（图像在按钮中居中；AppKit 约束的 y 向下为正）。
        let size = LogoRenderer.menuBarImageSize
        let center = LogoRenderer.menuBarBadgeCenter
        let diameter = LogoRenderer.menuBarBadgeRadius * 2
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badgeView)
        NSLayoutConstraint.activate([
            badgeView.widthAnchor.constraint(equalToConstant: diameter),
            badgeView.heightAnchor.constraint(equalToConstant: diameter),
            badgeView.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: center.x - size.width / 2),
            badgeView.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: size.height / 2 - center.y),
        ])
    }

    private func bind() {
        hostingController.publisher(for: \.preferredContentSize)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // 等弹窗按新尺寸布局完再刷新。
                DispatchQueue.main.async { self?.refreshCursor() }
            }
            .store(in: &cancellables)
        model.$overall
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        model.$checkProgress
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] checking in
                self?.updateIndicator(checking: checking)
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        let state = model.menuBarIconState
        button.image = indicatorVisible ? checkingImage : idleImage
        badgeView.severity = state.severity
        button.toolTip = state.tooltip
        button.setAccessibilityLabel(state.accessibilityLabel)
        button.setAccessibilityHelp(state.tooltip)
    }

    /// 进行中指示的去抖：短于 `indicatorDelay` 的检查不显示；显示后至少保留 `indicatorMinimumVisible`。
    private func updateIndicator(checking: Bool) {
        indicatorTask?.cancel()
        if checking {
            guard !indicatorVisible else { return }
            let delay = indicatorDelay
            indicatorTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.indicatorVisible = true
                self.indicatorShownAt = Date()
                self.refresh()
            }
        } else {
            guard indicatorVisible else { return }
            let elapsed = Date().timeIntervalSince(indicatorShownAt ?? .distantPast)
            let wait = max(0, indicatorMinimumVisible - elapsed)
            indicatorTask = Task { @MainActor [weak self] in
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard let self, !Task.isCancelled else { return }
                self.indicatorVisible = false
                self.refresh()
            }
        }
    }
}

/// 菜单栏上的彩色状态徽标。不参与模板着色；点击穿透到状态栏按钮。
final class StatusBadgeView: NSView {
    var severity: Severity = .unknown {
        didSet {
            if severity != oldValue { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let radius = min(bounds.width, bounds.height) / 2
        LogoRenderer.drawBadge(in: ctx, center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                               severity: severity, dark: effectiveAppearance.isDarkAppearance)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { false }
}
