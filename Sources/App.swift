import AppKit
import Carbon
import ApplicationServices

final class LabController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let pad = PressurePad(frame: .zero)
    let live = label("等待压感事件", size: 15, weight: .medium)
    let ownCount = label("窗口重按  0", size: 20, weight: .semibold)
    let globalCount = label("跨 App 重按  0", size: 20, weight: .semibold)
    let overlayCount = label("指针浮层：0 次重按 · 0 个压感事件", size: 12, color: .secondaryLabelColor)
    let samples = label("压感事件：本窗口 0 · 跨 App 0", color: .secondaryLabelColor)
    let monitoring = label("正在准备跨 App 重按", color: .secondaryLabelColor)
    let tapStatus = label("等待输入连接。", size: 12, color: .secondaryLabelColor)
    let gestureCount = label("跨 App 重按", size: 12, color: .secondaryLabelColor)
    let gestureEnabled = NSButton(checkboxWithTitle: "跨 App 手势输入", target: nil, action: nil)
    let instruction = label("重按后保持按住，滑向动作再松手；回中央取消。⌃⌥空格可打开指针浮层。", size: 13)
    let feedback = label("重按触控板，打开常用动作。", size: 12, color: .secondaryLabelColor)
    let logView = NSTextView()
    let summaryView = NSTextView()
    let pauseButton = NSButton(title: "暂停记录", target: nil, action: nil)
    let observeButton = NSButton(title: "启用跨 App 重按", target: nil, action: nil)
    let menuOnRelease = NSButton(checkboxWithTitle: "重按时立即打开菜单", target: nil, action: nil)
    var diagnosticsWindow: NSWindow?
    let runningSwitch = NSSwitch()
    let homeStatus = label("准备就绪", size: 13, weight: .medium)
    let homeDetail = label("", size: 12, color: .secondaryLabelColor)
    let profileSummary = label("", size: 13, color: .secondaryLabelColor)
    let permissionButton = NSButton(title: "允许辅助功能…", target: nil, action: nil)
    let retryButton = NSButton(title: "重试连接", target: nil, action: nil)
    var permissionRow: NSStackView?
    let actionProvider = ActionProvider()
    var configurationStore: ActionConfigurationStore { actionProvider.store }
    let actionExecutor = ActionExecutor()
    let actionResults = ActionResultController()
    let inputManager = PressureInputManager()
    let menuPresenter = MenuPresenter()
    lazy var contextResolver = ContextResolver(shouldObserve: { [weak self] bundleID in
        guard let self, !self.isPaused else { return false }
        return self.actionProvider.observesSelection(bundleID: bundleID)
    })
    var inputState = InputConnectionState()
    var inputStatsStart = PressureInputStats()
    var activeFiltering: Bool { inputState.canFilter }
    var blockedPressureEvents: Int { max(0, inputManager.stats.blockedPressureEvents - inputStatsStart.blockedPressureEvents) }
    var blockedPresses: Int { max(0, inputManager.stats.blockedPresses - inputStatsStart.blockedPresses) }
    var rawGestureEvents: Int { max(0, inputManager.stats.rawGestureEvents - inputStatsStart.rawGestureEvents) }
    var menuPressHeld: Bool { menuPresenter.isPressHeld }
    var menuProfileBundleID: String { menuPresenter.profileBundleID }
    var gestureCaptureID: UUID?
    var profileSettings: ProfileSettingsController?
    var configuredActionsSubmitted = 0
    var configuredActionFailures = 0
    let captureOverlay = CaptureOverlayController()
    var overlayOrigin = ("未知应用", "unknown")
    var overlaySamples = 0, overlayDeep = 0
    var gestureSamples = 0, gestureDeep = 0
    var observationRequested = false
    var workspaceObserver: Any?
    var updateTimer: Timer?
    var hotKey: EventHotKeyRef?
    var menuHotKey: EventHotKeyRef?
    var hotKeyHandler: EventHandlerRef?
    var cycles: [String: PressureCycle] = ["local": PressureCycle(source: "local"),
                                           "global": PressureCycle(source: "global"),
                                           "gestureTap": PressureCycle(source: "gestureTap"),
                                           "overlay": PressureCycle(source: "overlay")]
    var records: [EventRecord] = []
    var statistics: [String: AppStats] = [:]
    var lines: [String] = []
    var ownDeep = 0, otherDeep = 0, ownSamples = 0, otherSamples = 0, tapClicks = 0
    var droppedRecords = 0
    var isPaused = false
    var dirty = true
    var startedAt = Date()
    var startUptime = ProcessInfo.processInfo.systemUptime
    var menuGate = PressMenuGate()
    var menuShowTask: DispatchWorkItem?
    var pendingMenuStartedUptime: TimeInterval?
    var menuResponseMilliseconds: [Double] = []
    var pendingMenuPoint: NSPoint?
    var gestureContext: (String, String)?
    var gestureSourcePID: Int32?
    var gestureBeginPoint: NSPoint?
    var suppressGestureUntilUp = false
    var menusShown = 0, pressMenusShown = 0, actionsCompleted = 0
    var lastDragRecord: [String: Double] = [:]
    var statusItem: NSStatusItem?
    var hotKeyStatus = "尚未注册"
    var lastExternalApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        makeWindow()
        if let error = configurationStore.loadError { feedback.stringValue = error; addLine(error) }
        else if !FileManager.default.fileExists(atPath: configurationStore.fileURL.path) {
            do { try actionProvider.save(actionProvider.configuration) }
            catch { feedback.stringValue = "预设尚未保存：\(error.localizedDescription)" }
        }
        configureComponents()
        contextResolver.start()
        inputManager.startLocal()
        installHotKey()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                self.lastExternalApp = app
                if let target = self.menuPresenter.targetApp, target.processIdentifier != app.processIdentifier {
                    self.dismissActionMenu(reason: "切换应用")
                }
            }
            if self.captureOverlay.isVisible { self.captureOverlay.dismiss(reason: "切换应用") }
            if (self.gestureSourcePID != nil && self.gestureSourcePID != app.processIdentifier)
                || NSEvent.modifierFlags.contains(.command) || (!self.menuPressHeld && self.menuShowTask == nil) {
                self.cancelCycles(); self.cancelPendingMenu(); self.gestureContext = nil
                self.gestureSourcePID = nil; self.contextResolver.cancel(); self.gestureCaptureID = nil
                if self.menuPresenter.isVisible { self.dismissActionMenu(reason: "切换应用") }
            }
            self.updateInputPolicy()
        }
        updateTimer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(updateTimer!, forMode: .common)
        addLine("按刻已打开。")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        toggleObservation()
        refresh()
    }

    func configureComponents() {
        inputManager.onLocalEvent = { [weak self] event in self?.routeLocalInput(event) }
        inputManager.onGlobalEvent = { [weak self] event in self?.routeGlobalInput(event) }
        inputManager.onTapMouse = { [weak self] type, event in self?.receiveTap(type: type, event: event) }
        inputManager.onPressure = { [weak self] event, eligible in
            guard let self else { return }
            let validSource = self.acceptsGestureSource(event.cgEvent)
            if validSource || (self.menuPresenter.isPressHeld
                && self.menuPresenter.targetApp?.processIdentifier == self.gestureSourcePID
                && self.acceptsGestureSource(event.cgEvent, allowMenuTarget: true)) {
                self.menuPresenter.updatePressure(event)
            }
            if eligible && validSource { self.receive(event, source: "gestureTap") }
        }
        inputManager.onCancelGesture = { [weak self] reason in
            self?.cancelCycles(); self?.dismissActionMenu(reason: reason)
        }
        inputManager.onStatus = { [weak self] state in
            guard let self else { return }
            self.inputState = state
            self.tapStatus.stringValue = state.error ?? (state.hasTap ? "正在按 App 配置接收重按。" : "等待输入连接。")
            self.dirty = true
        }
        menuPresenter.onAction = { [weak self] action, target, context, point in
            self?.contextResolver.cancel()
            self?.dispatchAction(action, target: target, context: context, near: point)
        }
        menuPresenter.onDismiss = { [weak self] reason in
            self?.contextResolver.cancel(); self?.gestureCaptureID = nil
            self?.cancelPendingMenu(); self?.feedback.stringValue = reason
            self?.addLine("动作菜单已关闭：\(reason)。")
        }
        menuPresenter.onConfigure = { [weak self] in self?.showProfileSettings() }
        menuPresenter.onStateChange = { [weak self] in self?.updateInputPolicy() }
        captureOverlay.onEvent = { [weak self] event in self?.receive(event, source: "overlay") }
        captureOverlay.onCommit = { [weak self] app, bundleID in
            guard let self, !self.isPaused else { return }
            self.pressMenusShown += 1
            self.showActionMenu(origin: "指针浮层 · \(app)", targetBundleID: bundleID)
        }
        captureOverlay.onCancel = { [weak self] reason in
            self?.addLine("接收层已收起：\(reason)。"); self?.updateInputPolicy()
        }
    }

    func updateInputPolicy() {
        let intercepted = Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
            actionProvider.shouldIntercept(bundleID: app.bundleIdentifier ?? "") ? app.processIdentifier : nil
        })
        let menuPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
            actionProvider.hasActions(bundleID: app.bundleIdentifier ?? "") ? app.processIdentifier : nil
        })
        inputManager.updatePolicy(PressureInputPolicy(enabled: observationRequested, paused: isPaused,
            autoMenu: menuOnRelease.state == .on, gestureEnabled: gestureEnabled.state == .on,
            overlayVisible: captureOverlay.isVisible, menuVisible: menuPresenter.isVisible,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            interceptedPIDs: intercepted, menuPIDs: menuPIDs))
    }

    @objc func toggleObservation() {
        if observationRequested { stopObservation(); return }
        observationRequested = true
        cancelCycles(); cancelPendingMenu(); updateInputPolicy()
        inputManager.start()
        inputState = inputManager.connectionState
        observeButton.title = "停止跨 App 重按"
        monitoring.stringValue = "跨 App 输入已开启；重按时立即打开菜单。"
        dirty = true
    }

    func stopObservation() {
        observationRequested = false
        updateInputPolicy(); inputManager.stop(); inputState = inputManager.connectionState
        cancelCycles(); dismissActionMenu(reason: "停止跨 App 输入")
        observeButton.title = "启用跨 App 重按"
        monitoring.stringValue = "跨 App 输入已停止；⌃⌥空格仍可使用备用接收层。"
        tapStatus.stringValue = "手势监听已停止。"
    }

    @objc func retryTap() {
        if !observationRequested { toggleObservation(); return }
        dismissActionMenu(reason: "重新连接输入"); cancelCycles(); updateInputPolicy(); inputManager.retry()
        inputState = inputManager.connectionState
    }

    @objc func toggleGestureCapture() {
        cancelPendingMenu(); cancelCycles(); updateInputPolicy()
        if !observationRequested { toggleObservation() }
    }

    func hasActions(bundleID: String) -> Bool { actionProvider.hasActions(bundleID: bundleID) }
    func shouldIntercept(bundleID: String) -> Bool { actionProvider.shouldIntercept(bundleID: bundleID) }

    func showActionMenu(origin: String, near point: NSPoint? = nil, holdUntilMouseUp: Bool = false,
                        targetBundleID: String? = nil, profileOverride: AppProfile? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        let external = front?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? front : lastExternalApp
        let bundleID = (targetBundleID == "*" ? external?.bundleIdentifier : targetBundleID)
            ?? external?.bundleIdentifier ?? Bundle.main.bundleIdentifier ?? ""
        guard let profile = profileOverride ?? actionProvider.profile(for: bundleID),
              profile.isEnabled || profileOverride != nil else { return }
        let target = front?.bundleIdentifier == bundleID ? front
            : lastExternalApp?.bundleIdentifier == bundleID && lastExternalApp?.isTerminated == false ? lastExternalApp
            : NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        cancelPendingMenu()
        captureOverlay.dismiss(reason: "显示动作菜单", notify: false)
        let held = holdUntilMouseUp && (NSEvent.pressedMouseButtons & 1) != 0
        let gestureID = held ? gestureCaptureID : nil
        guard let id = menuPresenter.show(profile: profile, target: target, near: point ?? NSEvent.mouseLocation, held: held) else { return }
        menusShown += 1
        addLine("动作菜单已显示：\(origin)。")
        guard profile.actions.contains(where: { $0.isEnabled && $0.inputRequirement != .none }) else { return }
        contextResolver.resolve(for: target, gestureID: gestureID) { [weak self] context in
            self?.menuPresenter.updateContext(context, for: id)
        }
    }

    func releaseMenu(source: String, confirmedMouseUp: Bool = false, point: NSPoint? = nil) {
        guard confirmedMouseUp || (NSEvent.pressedMouseButtons & 1) == 0 else { return }
        if confirmedMouseUp {
            menuPresenter.release(at: point ?? NSEvent.mouseLocation)
            contextResolver.endGesture(); gestureCaptureID = nil
        }
    }

    func dismissActionMenu(reason: String) {
        menuPresenter.dismiss(reason: reason)
        contextResolver.cancel(); gestureCaptureID = nil; cancelPendingMenu(); updateInputPolicy()
    }

    func dispatchAction(_ action: MenuAction, target: NSRunningApplication?, context: ActionContext?, near point: NSPoint) {
        configuredActionsSubmitted += 1
        feedback.stringValue = "正在执行：\(action.title)…"
        actionExecutor.execute(action, target: target, context: context) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.actionsCompleted += 1; self.feedback.stringValue = message
                if action.inputRequirement != .none { self.actionResults.show(title: action.title, message: message, near: point) }
                self.addLine("动作已执行：\(action.title)。")
            case .failure(let error):
                self.configuredActionFailures += 1; self.feedback.stringValue = "\(action.title)：\(error.localizedDescription)"
                if action.inputRequirement != .none { self.actionResults.show(title: action.title, message: error.localizedDescription, near: point, isError: true) }
                self.addLine("动作失败：\(action.title)。详细原因显示在窗口中。")
            }
            self.dirty = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate(); cancelPendingMenu()
        captureOverlay.dismiss(reason: "退出", notify: false)
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        inputManager.stop(); inputManager.stopLocal(); contextResolver.stop()
        actionExecutor.cancelAll(); actionResults.dismiss()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let menuHotKey { UnregisterEventHotKey(menuHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }


    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let settings = profileSettings, settings.hasUnsavedChanges,
           let settingsWindow = settings.window, !settings.windowShouldClose(settingsWindow) {
            return .terminateCancel
        }
        // Stop accepting new gestures and decide whether to wait under the input
        // manager's lock. A separate isActive check races with a new deep press.
        observationRequested = false
        dismissActionMenu(reason: "退出按刻")
        inputManager.stop(afterRelease: { NSApp.reply(toApplicationShouldTerminate: true) })
        return .terminateLater
    }
}

@main
enum Presslet {
    static func main() {
        let app = NSApplication.shared
        let controller = LabController()
        app.setActivationPolicy(.regular)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
