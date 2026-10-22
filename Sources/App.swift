import AppKit
import Carbon
import ApplicationServices

private let accent = NSColor.systemBlue

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
           color: NSColor = .labelColor) -> NSTextField {
    let v = NSTextField(wrappingLabelWithString: text)
    v.font = .systemFont(ofSize: size, weight: weight)
    v.textColor = color
    v.isSelectable = false
    return v
}

func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    return b
}

func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 10) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = vertical ? .vertical : .horizontal
    s.alignment = vertical ? .leading : .centerY
    s.spacing = spacing
    return s
}

final class PressurePad: NSView {
    var force: Double = 0
    var stage = 0
    var isDown = false
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("力度显示区")
        setAccessibilityHelp("把指针放在此处，按下触控板并继续加力，查看力度变化。")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDown = true
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        isDown = false
        force = 0
        stage = 0
        needsDisplay = true
    }
    override func pressureChange(with event: NSEvent) {
        force = Double(event.pressure)
        stage = event.stage
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let bg = NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20)
        accent.withAlphaComponent(isDown ? 0.12 : 0.055).setFill()
        bg.fill()
        accent.withAlphaComponent(0.16).setStroke()
        bg.lineWidth = 1
        bg.stroke()
        let center = NSPoint(x: bounds.midX, y: bounds.midY + 12)
        let radius: CGFloat = 43
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x-radius, y: center.y-radius,
                                             width: radius*2, height: radius*2))
        accent.withAlphaComponent(0.12).setStroke()
        ring.lineWidth = 7
        ring.stroke()
        if force > 0 || stage >= 2 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90-CGFloat(max(0.015, min(1, force)))*360, clockwise: true)
            (stage >= 2 ? NSColor.systemGreen : accent).setStroke()
            arc.lineWidth = 7
            arc.lineCapStyle = .round
            arc.stroke()
        }
        let mark = stage >= 2 ? "重按" : (isDown ? "加力" : "按下")
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 21, weight: .medium),
                                                  .foregroundColor: stage >= 2 ? NSColor.systemGreen : accent]
        let size = mark.size(withAttributes: attrs)
        mark.draw(at: NSPoint(x: center.x-size.width/2, y: center.y-size.height/2), withAttributes: attrs)
        let hint = "指针放在这里 · 按下后继续加力"
        let hintAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                      .foregroundColor: NSColor.secondaryLabelColor]
        let hintSize = hint.size(withAttributes: hintAttrs)
        hint.draw(at: NSPoint(x: center.x-hintSize.width/2, y: 19), withAttributes: hintAttrs)
    }
}

struct EventRecord: Codable {
    let elapsed: Double
    let source: String
    let app: String
    let bundleID: String
    let type: String
    let stage: Int?
    let pressure: Double?
    let transition: Double?
    let firstDeep: Bool
}

struct AppStats: Codable {
    var app: String
    var bundleID: String
    var source: String
    var pressureEvents = 0
    var deepPresses = 0
    var clicks = 0
}

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
    let instruction = label("在 App 中重按并松开，选择动作。⌃⌥空格可打开指针浮层。", size: 13)
    let feedback = label("重按触控板，打开常用动作。", size: 12, color: .secondaryLabelColor)
    let logView = NSTextView()
    let summaryView = NSTextView()
    let pauseButton = NSButton(title: "暂停记录", target: nil, action: nil)
    let observeButton = NSButton(title: "启用跨 App 重按", target: nil, action: nil)
    let menuOnRelease = NSButton(checkboxWithTitle: "重按时立即打开菜单", target: nil, action: nil)
    var activeFiltering = false
    var blockedPressureEvents = 0
    var blockedPresses = 0
    var blockedThisPress = false
    var diagnosticsWindow: NSWindow?
    let runningSwitch = NSSwitch()
    let homeStatus = label("准备就绪", size: 13, weight: .medium)
    let homeDetail = label("", size: 12, color: .secondaryLabelColor)
    let profileSummary = label("", size: 13, color: .secondaryLabelColor)
    let permissionButton = NSButton(title: "允许辅助功能…", target: nil, action: nil)
    let retryButton = NSButton(title: "重试连接", target: nil, action: nil)
    var permissionRow: NSStackView?
    let configurationStore = ActionConfigurationStore()
    let actionExecutor = ActionExecutor()
    var profileSettings: ProfileSettingsController?
    var menuActions: [MenuAction] = []
    var menuTargetApp: NSRunningApplication?
    var menuProfileBundleID = "*"
    var configuredActionsSubmitted = 0
    var configuredActionFailures = 0
    var panel: ActionPanel?
    let captureOverlay = CaptureOverlayController()
    var overlayOrigin = ("未知应用", "unknown")
    var overlaySamples = 0, overlayDeep = 0
    var gestureSamples = 0, gestureDeep = 0, rawGestureEvents = 0
    var localMonitor: Any?
    var globalMonitor: Any?
    var observationRequested = false
    var workspaceObserver: Any?
    var updateTimer: Timer?
    var tap: CFMachPort?
    var tapRunLoopSource: CFRunLoopSource?
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
    var menuPressHeld = false
    var pendingMenuStartedUptime: TimeInterval?
    var menuResponseMilliseconds: [Double] = []
    var pendingMenuPoint: NSPoint?
    var gestureContext: (String, String)?
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
        if let error = configurationStore.loadError {
            feedback.stringValue = error
            addLine(error)
        } else if !FileManager.default.fileExists(atPath: configurationStore.fileURL.path) {
            do { try configurationStore.save(configurationStore.configuration) }
            catch { feedback.stringValue = "预设尚未保存：\(error.localizedDescription)" }
        }
        installLocalMonitor()
        captureOverlay.onEvent = { [weak self] event in self?.receive(event, source: "overlay") }
        captureOverlay.onCommit = { [weak self] app, bundleID in
            guard let self, !self.isPaused else { return }
            self.pressMenusShown += 1
            self.showActionMenu(origin: "指针浮层 · \(app)", targetBundleID: bundleID)
        }
        captureOverlay.onCancel = { [weak self] reason in self?.addLine("接收层已收起：\(reason)。") }
        installHotKey()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self.lastExternalApp = app }
            if self.captureOverlay.isVisible { self.captureOverlay.dismiss(reason: "切换应用") }
            // Preserve a menu opening in the same physical press. Command-Tab
            // remains an explicit cancellation, including while the finger is held.
            let explicitSwitch = NSEvent.modifierFlags.contains(.command)
            if explicitSwitch || (!self.menuPressHeld && self.menuShowTask == nil) {
                self.cancelCycles()
                self.cancelPendingMenu()
                self.gestureContext = nil
                if self.panel?.isVisible == true { self.dismissActionMenu(reason: "切换应用") }
            }
        }
        updateTimer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(updateTimer!, forMode: .common)
        addLine("按刻已打开。")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        toggleObservation()
        refresh()
    }

    func makeMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let menu = NSMenu()
        menu.addItem(withTitle: "关于按刻", action: #selector(showAbout), keyEquivalent: "")
        let settingsItem = menu.addItem(withTitle: "按 App 配置…", action: #selector(showProfileSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出按刻", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = menu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "按刻")
        let statusMenu = NSMenu()
        let show = statusMenu.addItem(withTitle: "打开按刻", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        let preview = statusMenu.addItem(withTitle: "预览动作菜单", action: #selector(previewMenu), keyEquivalent: "")
        preview.target = self
        let fallback = statusMenu.addItem(withTitle: "指针浮层  ⌃⌥空格", action: #selector(toggleCaptureOverlay), keyEquivalent: "")
        fallback.target = self
        let configure = statusMenu.addItem(withTitle: "按 App 配置…", action: #selector(showProfileSettings), keyEquivalent: "")
        configure.target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem?.menu = statusMenu
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "按刻"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let content = NSView()
        window.contentView = content
        menuOnRelease.state = .on
        gestureEnabled.state = .on

        let logo = NSImageView(image: NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)!)
        logo.contentTintColor = accent
        logo.symbolConfiguration = .init(pointSize: 30, weight: .medium)
        logo.widthAnchor.constraint(equalToConstant: 44).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let brand = stack([label("按刻", size: 27, weight: .semibold),
                           label("PRESSLET", size: 10, weight: .medium, color: .secondaryLabelColor)], spacing: 2)
        runningSwitch.target = self
        runningSwitch.action = #selector(toggleRunning)
        runningSwitch.setAccessibilityLabel("启用按刻")
        let status = stack([homeStatus, homeDetail], spacing: 3)
        let header = stack([logo, brand, NSView(), status, runningSwitch], vertical: false, spacing: 13)
        status.alignment = .trailing
        homeDetail.preferredMaxLayoutWidth = 225

        permissionButton.target = self
        permissionButton.action = #selector(requestFilterPermission)
        permissionButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryTap)
        retryButton.bezelStyle = .rounded
        let permissions = stack([permissionButton, retryButton], vertical: false, spacing: 8)
        permissionRow = permissions

        let configure = button("管理 App 动作…", self, #selector(showProfileSettings))
        configure.bezelStyle = .rounded
        configure.controlSize = .large
        configure.keyEquivalent = ","
        configure.keyEquivalentModifierMask = .command
        let appHeader = stack([label("App 动作", size: 19, weight: .semibold), NSView(), configure], vertical: false)
        let appBody = stack([appHeader, profileSummary,
                             label("发送快捷键 · 打开应用或网址 · 运行快捷指令", size: 13, color: .secondaryLabelColor)], spacing: 11)
        let appCard = makeHomeCard(appBody)
        appHeader.widthAnchor.constraint(equalTo: appBody.widthAnchor).isActive = true

        let preview = button("预览菜单", self, #selector(previewMenu))
        let floating = button("打开指针浮层", self, #selector(toggleCaptureOverlay))
        let previewRow = stack([stack([label("随时预览", size: 13, weight: .medium),
                                      label("⌃⌥M", size: 12, color: .secondaryLabelColor)], spacing: 4), NSView(), preview], vertical: false)
        let floatingRow = stack([stack([label("指针浮层", size: 13, weight: .medium),
                                       label("⌃⌥空格 · 为不便直接重按的场景准备", size: 12, color: .secondaryLabelColor)], spacing: 4), NSView(), floating], vertical: false)
        let separator = NSBox()
        separator.boxType = .separator
        let ways = stack([previewRow, separator, floatingRow], spacing: 13)
        for row in [previewRow, floatingRow, separator] {
            row.widthAnchor.constraint(equalTo: ways.widthAnchor).isActive = true
        }
        let waysCard = makeHomeCard(ways)
        let footer = stack([feedback, NSView(), button("诊断…", self, #selector(showDiagnostics))], vertical: false, spacing: 14)
        feedback.preferredMaxLayoutWidth = 530
        feedback.stringValue = "在 App 中按下触控板并继续加力，松开后选择动作。"
        let root = stack([header, permissions, appCard, waysCard, NSView(), footer], spacing: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -23)
        ])
        for v in [header, appCard, waysCard, footer] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        profileSummary.preferredMaxLayoutWidth = 590
    }

    func makeHomeCard(_ body: NSStackView) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.titlePosition = .noTitle
        card.borderColor = .separatorColor.withAlphaComponent(0.3)
        card.borderWidth = 0.5
        card.cornerRadius = 13
        card.fillColor = .controlBackgroundColor
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    @objc func toggleRunning() {
        if runningSwitch.state == .on {
            if isPaused { togglePause() }
            if !observationRequested { toggleObservation() }
        } else {
            stopObservation()
            if !isPaused { togglePause() }
        }
        dirty = true
        refresh()
    }

    func refreshHome() {
        let allowed = AXIsProcessTrusted()
        let connected = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        let ready = connected && activeFiltering
        let enabled = observationRequested && !isPaused
        runningSwitch.state = enabled ? .on : .off
        homeStatus.stringValue = !enabled ? "已暂停" : ready ? "运行中" : "等待连接"
        homeStatus.textColor = enabled && ready ? .systemGreen : .secondaryLabelColor
        homeDetail.stringValue = !allowed ? "允许辅助功能后即可接管重按" : !enabled ? "打开开关即可继续" : ready ? "重按即可呼出动作" : "点重试连接，开启重按接管"
        permissionButton.isHidden = allowed
        retryButton.isHidden = ready || !enabled
        permissionRow?.isHidden = allowed && (ready || !enabled)
        let profiles = configurationStore.configuration.profiles
        let apps = profiles.filter { $0.bundleID != "*" }.count
        let actions = profiles.reduce(0) { $0 + $1.actions.filter { $0.isEnabled }.count }
        profileSummary.stringValue = "已配置 \(apps) 个 App · \(actions) 个动作 · 其他 App 使用通用菜单"
    }

    @objc func showDiagnostics() {
        if let diagnosticsWindow {
            diagnosticsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let diagnostic = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        diagnostic.title = "力度与诊断"
        diagnostic.minSize = NSSize(width: 640, height: 720)
        diagnostic.isReleasedWhenClosed = false
        diagnosticsWindow = diagnostic
        let container = NSView()
        diagnostic.contentView = container
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.heightAnchor.constraint(equalToConstant: 168).isActive = true
        let counts = stack([ownCount, globalCount], vertical: false, spacing: 24)
        let tools = stack([button("清空记录", self, #selector(clearRecords)),
                           button("导出诊断…", self, #selector(exportReport))], vertical: false, spacing: 8)
        let summary = makeTextBox(summaryView, height: 75)
        let log = makeTextBox(logView, height: 100)
        let root = stack([pad, live, counts, samples, overlayCount, tapStatus, tools, summary, log], spacing: 11)
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20)
        ])
        for v in [pad, summary, log] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        live.preferredMaxLayoutWidth = 620
        tapStatus.preferredMaxLayoutWidth = 620
        diagnostic.center()
        diagnostic.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeTextBox(_ text: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        scroll.documentView = text
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 9, height: 7)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    func installLocalMonitor() {
        let mask: NSEvent.EventTypeMask = [.pressure, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown, self.tap == nil {
                self.suppressGestureUntilUp = self.panel?.isVisible == true
            }
            if let p = self.panel, p.isVisible,
               [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), event.window !== p {
                if event.type == .leftMouseDown { self.suppressGestureUntilUp = true }
                self.dismissActionMenu(reason: "点击菜单外")
            }
            if let diagnostic = self.diagnosticsWindow, event.window === diagnostic { self.receive(event, source: "local") }
            return event
        }
    }

    @objc func toggleObservation() {
        if observationRequested { stopObservation(); return }
        observationRequested = true
        cancelCycles()
        cancelPendingMenu()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.pressure, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown, self.tap == nil {
                self.suppressGestureUntilUp = self.panel?.isVisible == true
            }
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
               let panel = self.panel, panel.isVisible, !panel.frame.contains(event.cgEvent.map { self.appKitPoint(from: $0.location) } ?? NSEvent.mouseLocation) {
                if event.type == .leftMouseDown { self.suppressGestureUntilUp = true }
                self.dismissActionMenu(reason: "点击菜单外")
            }
            self.receive(event, source: "global")
        }
        if globalMonitor != nil {
            observeButton.title = "停止跨 App 重按"
            monitoring.stringValue = "跨 App 输入已开启；重按时立即打开菜单。"
            addLine("跨 App 重按已开启。")
            startTap()
        } else {
            monitoring.stringValue = "正在重新连接跨 App 输入。"
            addLine("后台输入连接失败。")
            startTap()
        }
        dirty = true
    }

    func stopObservation() {
        observationRequested = false
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
        stopTap()
        cancelPendingMenu()
        cancelCycles()
        observeButton.title = "启用跨 App 重按"
        monitoring.stringValue = "跨 App 输入已停止；⌃⌥空格仍可使用备用接收层。"
        tapStatus.stringValue = "手势监听已停止。"
        dismissActionMenu(reason: "停止跨 App 输入")
        addLine("跨 App 输入已停止。")
    }

    @objc func requestInputPermission() {
        if CGPreflightListenEventAccess() {
            tapStatus.stringValue = "系统已允许输入监控；可点击重试恢复跨 App 输入。"
        } else {
            let granted = CGRequestListenEventAccess()
            tapStatus.stringValue = granted ? "输入监控已允许；请重试辅助监听。" : "请在系统设置中允许“按刻”使用输入监控，再返回重试；系统可能要求重开 App。"
        }
        addLine("用户打开了输入监控权限流程。当前状态：\(CGPreflightListenEventAccess() ? "已允许" : "未允许")。")
        dirty = true
    }

    @objc func retryTap() {
        if !observationRequested { toggleObservation(); return }
        cancelPendingMenu()
        stopTap()
        startTap()
    }

    @objc func toggleGestureCapture() {
        _ = cycles["gestureTap"]?.accept(.cancel)
        cancelPendingMenu()
        if !observationRequested { toggleObservation() }
        else { stopTap(); startTap() }
        addLine(gestureEnabled.state == .on ? "跨 App 手势输入已选择。" : "跨 App 手势输入已关闭，可使用备用接收层。")
    }

    @objc func requestFilterPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let allowed = AXIsProcessTrustedWithOptions(options)
        addLine("辅助功能权限：\(allowed ? "已允许" : "等待允许")。")
        if !allowed {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    func startTap() {
        guard tap == nil else { return }
        let canFilter = AXIsProcessTrusted()
        guard canFilter || CGPreflightListenEventAccess() else {
            monitoring.stringValue = "跨 App 输入等待系统授权；备用接收层可用。"
            tapStatus.stringValue = "等待输入监控权限。可手动授权后重试；现在也可按 ⌃⌥空格使用备用接收层。"
            return
        }
        var mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
                 | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
                 | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
        // Hammerspoon demonstrates pressure carried inside a CG gesture (29).
        // This delivery path is experimental; it is not a public CGEventType guarantee.
        if gestureEnabled.state == .on { mask |= CGEventMask(1) << NSEvent.EventType.gesture.rawValue }
        activeFiltering = canFilter
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                               options: canFilter ? .defaultTap : .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<LabController>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.cancelPendingMenu()
                owner.cancelCycles()
                owner.blockedThisPress = false
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                owner.addLine("辅助监听被系统暂停，已尝试恢复。")
                return Unmanaged.passUnretained(event)
            }
            if type.rawValue == UInt32(NSEvent.EventType.gesture.rawValue) {
                guard !owner.isPaused else { return Unmanaged.passUnretained(event) }
                owner.rawGestureEvents += 1
                owner.dirty = true
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let targetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
                if let converted = NSEvent(cgEvent: event), converted.type == .pressure {
                    let target = NSRunningApplication(processIdentifier: pid_t(targetPID))?.bundleIdentifier
                        ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    // Decide filtering before excluding the now-visible menu.
                    // The remainder of an intercepted press must stay intercepted
                    // even though its menu has already appeared under the pointer.
                    let eligibleInput = !owner.captureOverlay.isVisible
                        && owner.panel?.isVisible != true && !owner.suppressGestureUntilUp
                        && targetPID != Int64(ownPID) && !(targetPID == 0 && NSApp.isActive)
                    let shouldBlock = owner.activeFiltering
                        && owner.menuOnRelease.state == .on && converted.stage >= 2
                        && (owner.blockedThisPress || (eligibleInput && owner.shouldIntercept(bundleID: target ?? "")))
                    if eligibleInput { owner.receive(converted, source: "gestureTap") }
                    if shouldBlock {
                        owner.blockedPressureEvents += 1
                        if !owner.blockedThisPress {
                            owner.blockedThisPress = true
                            owner.blockedPresses += 1
                            owner.addLine("已按 App 配置接管重按；普通点击及结束压感继续放行。")
                        }
                        return nil
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            owner.receiveTap(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }, userInfo: ptr)
        if let tap {
            monitoring.stringValue = "跨 App 输入已开启；重按时立即打开菜单。"
            tapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = tapRunLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
            tapStatus.stringValue = activeFiltering
                ? "正在按 App 配置接收重按；仅拦截已选择接管的 App。"
                : "系统重按仍可用；允许辅助功能后可按配置接管。"
            addLine("手势监听已运行；主动过滤权限\(activeFiltering ? "可用" : "不可用")，按 App 配置已载入。")
        } else {
            tapStatus.stringValue = "输入连接未完成，允许辅助功能后请重试。"
            addLine("输入连接失败。")
        }
    }

    func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = tapRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        activeFiltering = false
        blockedThisPress = false
        tapRunLoopSource = nil
    }

    func currentApp(source: String) -> (String, String) {
        if source == "local" { return ("按刻", Bundle.main.bundleIdentifier ?? "dev.zxlab.Presslet") }
        if source == "overlay" { return overlayOrigin }
        if source == "gestureTap", let context = gestureContext { return context }
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName ?? "未知应用", app?.bundleIdentifier ?? "unknown")
    }

    func receive(_ event: NSEvent, source: String) {
        guard !isPaused else { return }
        let (app, bundle) = currentApp(source: source)
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        var isDeep = false
        var stage: Int?
        var force: Double?
        var transition: Double?
        var type: String
        switch event.type {
        case .pressure:
            type = "pressure"
            stage = event.stage
            force = Double(event.pressure)
            transition = Double(event.stageTransition)
            isDeep = cycles[source]?.accept(.pressure(stage: event.stage, value: Double(event.pressure))) ?? false
            if source == "local" { ownSamples += 1 }
            else if source == "overlay" { overlaySamples += 1 }
            else if source == "gestureTap" { gestureSamples += 1 }
            else { otherSamples += 1 }
            let location = source == "local" ? "本窗口" : source == "overlay" ? "指针浮层" : source == "gestureTap" ? "跨 App · \(app)" : app
            live.stringValue = "\(location)  ·  阶段 \(event.stage)  ·  阶段力度 \(String(format: "%.3f", event.pressure))"
            if isDeep {
                if source == "local" { ownDeep += 1 }
                else if source == "overlay" { overlayDeep += 1 }
                else if source == "gestureTap" { gestureDeep += 1 }
                else { otherDeep += 1 }
                addLine("重按 · \(location) · 阶段 \(event.stage)")
                if (source == "gestureTap" || source == "local"), menuOnRelease.state == .on,
                   panel?.isVisible != true, !suppressGestureUntilUp, hasActions(bundleID: bundle) {
                    menuShowTask?.cancel()
                    menuShowTask = nil
                    menuGate.arm(source: source, appName: app, bundleID: bundle)
                    pendingMenuStartedUptime = ProcessInfo.processInfo.systemUptime
                    pendingMenuPoint = source == "gestureTap" ? (gestureBeginPoint ?? NSEvent.mouseLocation) : NSEvent.mouseLocation
                    openMenuImmediately(source: source)
                }
            }
            if event.stage == 0, (NSEvent.pressedMouseButtons & 1) == 0 { releaseMenu(source: source) }
        case .leftMouseDown:
            type = "mouseDown"
            if source == "local" { cancelPendingMenu() }
            _ = cycles[source]?.accept(.mouseDown)
        case .leftMouseUp:
            type = "mouseUp"
            _ = cycles[source]?.accept(.mouseUp)
            releaseMenu(source: source, confirmedMouseUp: true)
            if tap == nil { suppressGestureUntilUp = false }
        case .leftMouseDragged:
            type = "mouseDragged"
            // Drag samples are bounded; pressure events remain unthrottled.
            if t - (lastDragRecord[source] ?? -1) < 0.05 { return }
            lastDragRecord[source] = t
        default: return
        }
        let key = source + ":" + bundle
        var stats = statistics[key] ?? AppStats(app: app, bundleID: bundle, source: source)
        if type == "pressure" { stats.pressureEvents += 1 }
        if type == "mouseDown" { stats.clicks += 1 }
        if isDeep { stats.deepPresses += 1 }
        statistics[key] = stats
        append(EventRecord(elapsed: t, source: source, app: app, bundleID: bundle,
                           type: type, stage: stage, pressure: force, transition: transition, firstDeep: isDeep))
        dirty = true
    }

    func openMenuImmediately(source: String) {
        guard let trigger = menuGate.release(source: source) else { return }
        let point = pendingMenuPoint
        let triggeredAt = pendingMenuStartedUptime ?? ProcessInfo.processInfo.systemUptime
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.menuGate.isCurrent(trigger) else { return }
            self.menuShowTask = nil
            guard !self.isPaused, self.menuOnRelease.state == .on,
                  source != "gestureTap" || (self.observationRequested && self.tap != nil) else {
                self.cancelPendingMenu()
                return
            }
            self.pressMenusShown += 1
            self.showActionMenu(origin: "\(source == "gestureTap" ? "跨 App 重按" : "窗口重按") · \(trigger.appName)",
                                near: point, holdUntilMouseUp: true, targetBundleID: trigger.bundleID)
            let response = (ProcessInfo.processInfo.systemUptime - triggeredAt) * 1000
            self.menuResponseMilliseconds.append(response)
            self.addLine("重按至菜单开始显示：\(String(format: "%.1f", response)) ms。")
        }
        menuShowTask?.cancel()
        menuShowTask = task
        // Leave the event-tap callback before constructing and presenting windows.
        DispatchQueue.main.async(execute: task)
    }

    func releaseMenu(source: String, confirmedMouseUp: Bool = false) {
        guard confirmedMouseUp || (NSEvent.pressedMouseButtons & 1) == 0 else { return }
        guard menuPressHeld else { return }
        menuPressHeld = false
        let heldPanel = panel
        // Keep the release belonging to the triggering press out of the new menu.
        DispatchQueue.main.async { [weak self, weak heldPanel] in
            guard let self, let heldPanel, self.panel === heldPanel, !self.menuPressHeld else { return }
            heldPanel.setPressHeld(false)
        }
    }

    func cancelPendingMenu() {
        menuGate.cancel()
        menuShowTask?.cancel()
        menuShowTask = nil
        pendingMenuStartedUptime = nil
        pendingMenuPoint = nil
    }

    func dismissActionMenu(reason: String) {
        let visible = panel?.isVisible == true
        let closingPanel = panel
        panel = nil
        menuPressHeld = false
        closingPanel?.dismissWithMotion()
        cancelPendingMenu()
        if visible { addLine("动作菜单已关闭：\(reason)。") }
    }

    func appKitPoint(from point: CGPoint) -> NSPoint {
        let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSPoint(x: point.x, y: displayHeight - point.y)
    }

    func receiveTap(type: CGEventType, event: CGEvent) {
        guard !isPaused else { return }
        if type == .leftMouseDown {
            blockedThisPress = false
            suppressGestureUntilUp = panel?.isVisible == true
            if let panel, panel.isVisible {
                suppressGestureUntilUp = true
                if !panel.frame.contains(appKitPoint(from: event.location)) { dismissActionMenu(reason: "点击菜单外") }
            }
            if !suppressGestureUntilUp && !captureOverlay.isVisible {
                cancelPendingMenu()
                let app = NSWorkspace.shared.frontmostApplication
                gestureContext = (app?.localizedName ?? "未知应用", app?.bundleIdentifier ?? "unknown")
                gestureBeginPoint = appKitPoint(from: event.location)
                _ = cycles["gestureTap"]?.accept(.mouseDown)
            }
        }
        if type == .leftMouseUp {
            _ = cycles["gestureTap"]?.accept(.mouseUp)
            releaseMenu(source: "gestureTap", confirmedMouseUp: true)
            suppressGestureUntilUp = false
        }
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        if type == .leftMouseDragged {
            if t - (lastDragRecord["tap"] ?? -1) < 0.05 { return }
            lastDragRecord["tap"] = t
        }
        let app = currentApp(source: "tap")
        let name = type == .leftMouseDown ? "mouseDown" : type == .leftMouseUp ? "mouseUp" : "mouseDragged"
        let pressure = event.getDoubleValueField(.mouseEventPressure)
        if type == .leftMouseDown { tapClicks += 1 }
        append(EventRecord(elapsed: t, source: "tap", app: app.0, bundleID: app.1,
                           type: name, stage: nil, pressure: pressure.isFinite ? pressure : nil,
                           transition: nil, firstDeep: false))
        dirty = true
    }

    func append(_ event: EventRecord) {
        if records.count >= 8000 { records.removeFirst(256); droppedRecords += 256 }
        records.append(event)
    }

    func addLine(_ value: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startUptime
        lines.append(String(format: "%7.2fs  ", elapsed) + value)
        if lines.count > 120 { lines.removeFirst(lines.count-120) }
        dirty = true
    }

    func refresh() {
        refreshHome()
        guard dirty else { return }
        dirty = false
        ownCount.stringValue = "窗口重按  \(ownDeep)"
        globalCount.stringValue = "跨 App 重按  \(gestureDeep)"
        samples.stringValue = "压感事件：本窗口 \(ownSamples) · 跨 App \(gestureSamples)"
        overlayCount.stringValue = "指针浮层：\(overlayDeep) 次重按 · \(overlaySamples) 个压感事件"
        gestureCount.stringValue = "重按菜单 \(pressMenusShown) 次 · 动作完成 \(actionsCompleted) 次"
        var text = "来源 / App                       点击    压感事件    重按\n"
        for s in statistics.values.sorted(by: { ($0.source, $0.app) < ($1.source, $1.app) }) {
            let name = s.source == "local" ? "本窗口" : s.source == "overlay" ? "指针浮层" : s.source == "gestureTap" ? "跨 App" : "其他事件"
            text += "\(name) / \(s.app)    \(s.clicks)       \(s.pressureEvents)       \(s.deepPresses)\n"
        }
        text += "鼠标事件：\(tapClicks) 次鼠标按下；不推算重按。"
        summaryView.string = text
        logView.string = lines.suffix(120).joined(separator: "\n")
        logView.scrollToEndOfDocument(nil)
    }

    func cancelCycles() {
        let input: PressureInput = (NSEvent.pressedMouseButtons & 1) == 0 ? .mouseUp : .cancel
        for key in Array(cycles.keys) { _ = cycles[key]?.accept(input) }
    }

    @objc func menuPreferenceChanged() {
        cancelPendingMenu()
        if menuOnRelease.state != .on { dismissActionMenu(reason: "关闭自动菜单") }
        if menuOnRelease.state == .on {
            addLine("重按菜单已启用；识别到重按即显示菜单，松开后可选择。")
        } else { addLine("重按菜单已关闭；保留事件观察。") }
    }

    @objc func togglePause() {
        isPaused.toggle()
        cancelPendingMenu()
        for key in Array(cycles.keys) { cycles[key]?.setEnabled(!isPaused) }
        if isPaused { dismissActionMenu(reason: "暂停") }
        if isPaused { captureOverlay.dismiss(reason: "暂停记录") }
        pauseButton.title = isPaused ? "继续记录" : "暂停记录"
        live.stringValue = isPaused ? "记录已暂停" : "记录已恢复，请先松开再重按"
        addLine(isPaused ? "记录已暂停。" : "记录已恢复；等待松开后进入下一个周期。")
    }

    @objc func clearRecords() {
        records.removeAll(); statistics.removeAll(); lines.removeAll()
        ownDeep = 0; otherDeep = 0; ownSamples = 0; otherSamples = 0; tapClicks = 0
        overlayDeep = 0; overlaySamples = 0
        gestureDeep = 0; gestureSamples = 0; rawGestureEvents = 0
        menusShown = 0; pressMenusShown = 0; actionsCompleted = 0
        menuResponseMilliseconds.removeAll()
        blockedPressureEvents = 0; blockedPresses = 0; blockedThisPress = false
        dismissActionMenu(reason: "清空记录")
        captureOverlay.dismiss(reason: "开始新一轮记录", notify: false)
        droppedRecords = 0
        startedAt = Date(); startUptime = ProcessInfo.processInfo.systemUptime
        lastDragRecord.removeAll()
        cancelPendingMenu()
        cancelCycles()
        live.stringValue = "记录已清空，请先松开再重按"
        addLine("开始新一轮记录。")
        refresh()
    }

    @objc func previewMenu() {
        showActionMenu(origin: "手动预览 · 不计入重按")
    }

    @objc func toggleCaptureOverlay() {
        guard !isPaused else { feedback.stringValue = "请先开启按刻，再打开指针浮层。"; return }
        cancelPendingMenu()
        if !captureOverlay.isVisible {
            let app = NSWorkspace.shared.frontmostApplication
            overlayOrigin = (app?.localizedName ?? "未知应用", app?.bundleIdentifier ?? "unknown")
            _ = cycles["overlay"]?.accept(.mouseUp)
            panel?.orderOut(nil)
            addLine("呼出重按接收层 · 当前应用 \(overlayOrigin.0)。")
        }
        captureOverlay.show(appName: overlayOrigin.0, bundleID: overlayOrigin.1)
    }

    func hasActions(bundleID: String) -> Bool {
        guard let profile = configurationStore.configuration.profile(for: bundleID) else { return false }
        return profile.isEnabled && profile.actions.contains(where: { $0.isEnabled })
    }

    func shouldIntercept(bundleID: String) -> Bool {
        guard let profile = configurationStore.configuration.profile(for: bundleID) else { return false }
        return profile.isEnabled && profile.interceptForceClick && profile.actions.contains(where: { $0.isEnabled })
    }

    @objc func showProfileSettings() {
        dismissActionMenu(reason: "打开配置")
        if let settings = profileSettings {
            // Existing unsaved edits belong to the editor until saved or discarded.
            settings.showWindow(nil)
            settings.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let settings = ProfileSettingsController(configuration: configurationStore.configuration) { [weak self] configuration in
            guard let self else { return }
            try self.configurationStore.save(configuration)
            self.dismissActionMenu(reason: "配置已更新")
            self.cancelCycles()
            self.feedback.stringValue = "配置已保存，下一次重按即生效。"
            self.addLine("按 App 配置已保存。")
        }
        settings.onPreview = { [weak self] profile in
            self?.showActionMenu(origin: "配置预览", targetBundleID: profile.bundleID, profileOverride: profile)
        }
        profileSettings = settings
        settings.showWindow(nil)
        settings.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showActionMenu(origin: String, near point: NSPoint? = nil, holdUntilMouseUp: Bool = false,
                        targetBundleID: String? = nil, profileOverride: AppProfile? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        let external = front?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? front : lastExternalApp
        let bundleID = (targetBundleID == "*" ? external?.bundleIdentifier : targetBundleID)
            ?? external?.bundleIdentifier ?? Bundle.main.bundleIdentifier ?? ""
        guard let profile = profileOverride ?? configurationStore.configuration.profile(for: bundleID),
              profile.isEnabled || profileOverride != nil else { return }
        let actions = Array(profile.actions.filter { $0.isEnabled }.prefix(9))
        guard !actions.isEmpty else {
            feedback.stringValue = "此 App 尚无启用的动作，请在配置中添加。"
            return
        }
        let target: NSRunningApplication? = {
            if front?.bundleIdentifier == bundleID { return front }
            if lastExternalApp?.bundleIdentifier == bundleID, lastExternalApp?.isTerminated == false { return lastExternalApp }
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }()
        cancelPendingMenu()
        captureOverlay.dismiss(reason: "显示动作菜单", notify: false)
        panel?.orderOut(nil)
        menuActions = actions
        menuTargetApp = target
        menuProfileBundleID = profile.bundleID
        let p = ActionPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 136 + CGFloat(actions.count) * 38),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.actionCount = actions.count
        p.title = "动作菜单"
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let bg = NSVisualEffectView()
        bg.material = .menu
        bg.isEmphasized = false
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        p.contentView = bg
        let appName = profile.bundleID == "*" ? (target?.localizedName ?? "通用动作") : profile.appName
        let subtitle = profile.bundleID == "*" ? "通用动作" : "App 专用动作"
        var views: [NSView] = [label(appName, size: 18, weight: .semibold), label(subtitle, size: 12, color: .secondaryLabelColor)]
        for (index, action) in actions.enumerated() {
            let row = button("\(index + 1)   \(action.title)", self, #selector(configuredAction(_:)))
            row.tag = index + 1
            row.alignment = .left
            row.lineBreakMode = .byTruncatingTail
            row.toolTip = action.kind.displayName
            views.append(row)
        }
        let configure = button("配置…", self, #selector(showProfileSettings))
        let footer = stack([label("数字选择 · Esc 关闭", size: 11, color: .secondaryLabelColor), configure], vertical: false, spacing: 16)
        views.append(footer)
        let content = stack(views, spacing: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
                                     content.topAnchor.constraint(equalTo: bg.topAnchor, constant: 16),
                                     content.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20)])
        p.perform = { [weak self] n in self?.performAction(n) }
        p.onDismiss = { [weak self] in self?.dismissActionMenu(reason: "按 Esc") }
        let triggerPoint = point ?? NSEvent.mouseLocation
        var location = triggerPoint
        let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        location.x = min(max(visible.minX + 8, location.x + 12), visible.maxX-p.frame.width-8)
        location.y = min(max(visible.minY + 8, location.y-p.frame.height-12), visible.maxY-p.frame.height-8)
        p.setFrameOrigin(location)
        panel = p
        menuPressHeld = holdUntilMouseUp && (NSEvent.pressedMouseButtons & 1) != 0
        p.setPressHeld(menuPressHeld)
        p.present(from: triggerPoint)
        menusShown += 1
        addLine("动作菜单已显示：\(origin) · \(appName)。")
    }

    @objc func configuredAction(_ sender: NSButton) { performAction(sender.tag) }

    func performAction(_ n: Int) {
        guard panel?.isVisible == true, !menuPressHeld, n > 0, n <= menuActions.count else { return }
        let action = menuActions[n - 1]
        let target = menuTargetApp
        let closingPanel = panel
        panel = nil
        menuPressHeld = false
        closingPanel?.dismissWithMotion()
        cancelPendingMenu()
        configuredActionsSubmitted += 1
        feedback.stringValue = "正在执行：\(action.title)…"
        actionExecutor.execute(action, target: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.actionsCompleted += 1
                self.feedback.stringValue = message
                self.addLine("动作已执行：\(action.title)。")
            case .failure(let error):
                self.configuredActionFailures += 1
                self.feedback.stringValue = "\(action.title)：\(error.localizedDescription)"
                self.addLine("动作失败：\(action.title) · \(error.localizedDescription)")
            }
            self.dirty = true
            self.refresh()
        }
    }

    func installHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let handlerResult = InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let info, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<LabController>.fromOpaque(info).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            if id.id == 1 { owner.toggleCaptureOverlay() }
            else if id.id == 2 { owner.showActionMenu(origin: "快捷键预览 · 不计入重按") }
            return noErr
        }, 1, &eventType, ptr, &hotKeyHandler)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: 0x46504C42, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        let menuResult = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey),
                                             EventHotKeyID(signature: 0x46504C42, id: 2),
                                             GetApplicationEventTarget(), 0, &menuHotKey)
        hotKeyStatus = "handler=\(handlerResult), capture=\(result), menu=\(menuResult)"
        if result == noErr && handlerResult == noErr { addLine("快捷键已注册：⌃⌥空格呼出接收层；⌃⌥M直接预览菜单。") }
        else { addLine("快捷键注册失败（\(result)）；仍可点击预览菜单。") }
    }

    @objc func exportReport() {
        let save = NSSavePanel()
        save.nameFieldStringValue = "Presslet-diagnostics.json"
        save.title = "导出诊断记录"
        save.message = "保存事件和计数。报告不包含选中文字、按键内容或屏幕。"
        save.beginSheetModal(for: diagnosticsWindow?.isVisible == true ? diagnosticsWindow! : window) { [weak self] response in
            guard let self, response == .OK, let url = save.url else { return }
            do {
                let data = try self.reportData()
                try data.write(to: url, options: .atomic)
                self.feedback.stringValue = "报告已保存：\(url.lastPathComponent)"
                self.addLine("用户已导出本次报告。")
            } catch {
                self.feedback.stringValue = "报告保存失败：\(error.localizedDescription)"
            }
        }
    }

    func reportData() throws -> Data {
        struct Report: Encodable {
            let formatVersion: Int
            let appVersion: String
            let startedAt: String
            let exportedAt: String
            let os: String
            let globalMonitorInstalled: Bool
            let cgTapInstalled: Bool
            let cgTapEnabled: Bool
            let inputMonitoringAllowed: Bool
            let accessibilityAllowed: Bool
            let activeFiltering: Bool
            let configuredProfileCount: Int
            let configurationPath: String
            let configuredActionsSubmitted: Int
            let configuredActionFailures: Int
            let menuProfileBundleID: String
            let edgeTakeoverSelected: Bool
            let blockedPressureEvents: Int
            let blockedPresses: Int
            let isPaused: Bool
            let primaryInput: String
            let autoMenuEnabled: Bool
            let primaryPressureEvents: Int
            let primaryDeepPresses: Int
            let menusShown: Int
            let pressMenusShown: Int
            let actionsCompleted: Int
            let menuMotion: String
            let menuTrigger: String
            let menuResponseLastMilliseconds: Double?
            let menuResponseAverageMilliseconds: Double?
            let menuResponseMaxMilliseconds: Double?
            let reducedMotion: Bool
            let hotkeyStatus: String
            let localPressureEvents: Int
            let localDeepPresses: Int
            let globalPressureEvents: Int
            let globalDeepPresses: Int
            let overlayPressureEvents: Int
            let overlayDeepPresses: Int
            let gestureTapSelected: Bool
            let gestureTapPressureEvents: Int
            let gestureTapDeepPresses: Int
            let rawGestureEvents: Int
            let auxiliaryMouseDowns: Int
            let recordsDiscarded: Int
            let countsMeaning: String
            let perApp: [AppStats]
            let activity: [String]
            let events: [EventRecord]
        }
        let iso = ISO8601DateFormatter()
        let report = Report(formatVersion: 3, appVersion: "1.0.0", startedAt: iso.string(from: startedAt),
                            exportedAt: iso.string(from: Date()), os: ProcessInfo.processInfo.operatingSystemVersionString,
                            globalMonitorInstalled: globalMonitor != nil, cgTapInstalled: tap != nil,
                            cgTapEnabled: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
                            inputMonitoringAllowed: CGPreflightListenEventAccess(),
                            accessibilityAllowed: AXIsProcessTrusted(), activeFiltering: activeFiltering,
                            configuredProfileCount: configurationStore.configuration.profiles.count,
                            configurationPath: configurationStore.fileURL.path,
                            configuredActionsSubmitted: configuredActionsSubmitted,
                            configuredActionFailures: configuredActionFailures,
                            menuProfileBundleID: menuProfileBundleID,
                            edgeTakeoverSelected: shouldIntercept(bundleID: "com.microsoft.edgemac"),
                            blockedPressureEvents: blockedPressureEvents, blockedPresses: blockedPresses,
                            isPaused: isPaused,
                            primaryInput: "gestureTap", autoMenuEnabled: menuOnRelease.state == .on,
                            primaryPressureEvents: gestureSamples, primaryDeepPresses: gestureDeep,
                            menusShown: menusShown, pressMenusShown: pressMenusShown, actionsCompleted: actionsCompleted,
                            menuMotion: "popover scale ease-out (0.23,1,0.32,1), opacity native ease-out; enter 320ms opacity 0.12 to 1 + scale 0.97; exit 220ms opacity + scale 0.95; native menu background material",
                            menuTrigger: "first stage 2; next main-queue turn, before mouse release; response measured through present() submission, not displayed-frame latency",
                            menuResponseLastMilliseconds: menuResponseMilliseconds.last,
                            menuResponseAverageMilliseconds: menuResponseMilliseconds.isEmpty ? nil : menuResponseMilliseconds.reduce(0, +) / Double(menuResponseMilliseconds.count),
                            menuResponseMaxMilliseconds: menuResponseMilliseconds.max(),
                            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                            hotkeyStatus: hotKeyStatus,
                            localPressureEvents: ownSamples, localDeepPresses: ownDeep,
                            globalPressureEvents: otherSamples, globalDeepPresses: otherDeep,
                            overlayPressureEvents: overlaySamples, overlayDeepPresses: overlayDeep,
                            gestureTapSelected: gestureEnabled.state == .on,
                            gestureTapPressureEvents: gestureSamples, gestureTapDeepPresses: gestureDeep,
                            rawGestureEvents: rawGestureEvents,
                            auxiliaryMouseDowns: tapClicks, recordsDiscarded: droppedRecords,
                            countsMeaning: "Deep presses count the first stage >= 2 of each real NSEvent pressure cycle. Overlay pressure is received by our own nonactivating panel; its app identity describes the foreground app before showing the overlay. The optional gestureTap path follows Hammerspoon's CG gesture (29) to NSEvent pressure conversion; it excludes our process and active overlay before counting pressure. Raw gesture totals may include our process. Manual previews and CGEventTap mousePressure are excluded. Zero global events means none observed in this session. Event records retain the newest 8000 entries; summary counts cover the session. Drag samples are limited to 20 per second per source. Global app identity is the frontmost app at observation time, not a verified event recipient.",
                            perApp: statistics.values.sorted { ($0.source, $0.app) < ($1.source, $1.app) },
                            activity: lines, events: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    @objc func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "按刻", .applicationVersion: "1.0.0",
                                                   .credits: NSAttributedString(string: "重按触控板，打开当前 App 的常用动作。\n快捷键、应用与网址、快捷指令，按需配置。")])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            sender.orderOut(nil)
            return false
        }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let settings = profileSettings, settings.hasUnsavedChanges,
           let settingsWindow = settings.window, !settings.windowShouldClose(settingsWindow) {
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        cancelPendingMenu()
        captureOverlay.dismiss(reason: "退出", notify: false)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        stopTap()
        actionExecutor.cancelAll()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let menuHotKey { UnregisterEventHotKey(menuHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
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
