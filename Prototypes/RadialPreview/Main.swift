import AppKit

private struct PreviewScene {
    let name: String
    let symbol: String
    let context: String
    let detail: String
    let actions: [RadialItem]
}

private let scenes: [PreviewScene] = [
    .init(name: "Finder", symbol: "folder.fill", context: "项目资料", detail: "设计稿 · 文档 · 灵感", actions: [
        .init(id: "path", title: "复制路径", symbol: "link", direction: .up),
        .init(id: "code", title: "用 Code 打开", symbol: "curlybraces", direction: .left),
        .init(id: "collect", title: "移到收集箱", symbol: "tray.and.arrow.down", direction: .right)]),
    .init(name: "VS Code", symbol: "curlybraces", context: "理解这一段代码", detail: "function createSomething()", actions: [
        .init(id: "definition", title: "查看定义", symbol: "arrow.turn.down.right", direction: .up),
        .init(id: "references", title: "查找引用", symbol: "text.magnifyingglass", direction: .left),
        .init(id: "fix", title: "快速修复", symbol: "wand.and.stars", direction: .right)]),
    .init(name: "Edge", symbol: "globe", context: "让阅读保持连贯", detail: "选中一句值得继续探索的话", actions: [
        .init(id: "search", title: "搜索选中文字", symbol: "magnifyingglass", direction: .up),
        .init(id: "translate", title: "翻译选中文字", symbol: "character.bubble", direction: .left),
        .init(id: "quote", title: "引用到 ChatGPT", symbol: "quote.bubble", direction: .right)]),
    .init(name: "ChatGPT", symbol: "bubble.left.and.bubble.right", context: "接着这个想法聊", detail: "把有用的回答留在手边", actions: [
        .init(id: "quote", title: "引用到输入框", symbol: "quote.bubble", direction: .up),
        .init(id: "copy", title: "复制整条回答", symbol: "doc.on.doc", direction: .left),
        .init(id: "note", title: "保存为笔记", symbol: "square.and.pencil", direction: .right)])
]

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.alignment = .center
    return field
}

private final class PreviewCanvas: NSView {
    var sceneIndex = 0 { didSet { cancel(); needsDisplay = true } }
    var useDefault = false
    var ordinaryPress = false
    var onStatus: ((String) -> Void)?
    var onPressure: ((String) -> Void)?
    private var selection: RadialSelection?
    private var radialMenu: RadialMenuView?
    private var tracking: NSTrackingArea?
    private var previewMode = false
    private var pressConsumed = false
    private var physicalDown = false
    private var pressureFeedback = PressureFeedback()
    private var gestureOrigin = CGPoint.zero
    private var pointerDisplacement = CGPoint.zero
    private var compression: CGFloat = 0
    private var feedbackTimer: Timer?
    private var lastFocus = RadialFocus.center
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("重按手势体验区")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        let scene = scenes[sceneIndex]
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 27, weight: .semibold), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82)]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
        func drawText(_ text: String, y: CGFloat, attrs: [NSAttributedString.Key: Any]) {
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: center.x-size.width/2, y: y), withAttributes: attrs)
        }
        drawText(scene.name, y: bounds.height-54, attrs: subtitleAttributes)
        drawText(scene.context, y: bounds.height-99, attrs: titleAttributes)
        drawText(scene.detail, y: bounds.height-126, attrs: subtitleAttributes)
        if selection == nil {
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x-39, y: center.y-39, width: 78, height: 78))
        NSColor.controlAccentColor.withAlphaComponent(0.045).setFill(); ring.fill()
        ring.lineWidth = 1
        NSColor.controlAccentColor.withAlphaComponent(0.2).setStroke(); ring.stroke()
        if let image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: nil) {
            image.withSymbolConfiguration(.init(pointSize: 24, weight: .light).applying(.init(paletteColors: [.secondaryLabelColor])))?.draw(in: NSRect(x: center.x-15, y: center.y-15, width: 30, height: 30))
        }
        drawText(ordinaryPress ? "在这里按住，滑向动作后松手" : "在这里重按，滑向动作后松手", y: center.y-77, attrs: subtitleAttributes)
        }
        drawText("回到中央或滑远即可取消", y: 27, attrs: subtitleAttributes)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if previewMode { update(point); finish(); return }
        feedbackTimer?.invalidate(); feedbackTimer = nil
        pressureFeedback.reset(); compression = 0
        pressConsumed = false
        physicalDown = true
        if ordinaryPress { begin(at: point) }
    }
    override func pressureChange(with event: NSEvent) {
        guard physicalDown, !ordinaryPress else { return }
        let wasDeepPressed = pressureFeedback.isDeepPressed
        compression = pressureFeedback.update(stage: event.stage, pressure: CGFloat(event.pressure))
        onPressure?("力度 \(Int(event.pressure * 100))% · 第 \(event.stage) 阶段" + (pressureFeedback.isDeepPressed ? " · 深压" : ""))
        if !pressConsumed, event.stage >= 2, selection == nil {
            begin(at: convert(event.locationInWindow, from: nil))
        }
        radialMenu?.updateInteraction(displacement: pointerDisplacement, compression: compression)
        if !wasDeepPressed, pressureFeedback.isDeepPressed, selection != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }
    override func mouseDragged(with event: NSEvent) { update(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) {
        if previewMode { update(convert(event.locationInWindow, from: nil)) }
    }
    override func mouseUp(with event: NSEvent) {
        physicalDown = false
        guard !previewMode else { return }
        if selection != nil { update(convert(event.locationInWindow, from: nil)); finish() }
        pressConsumed = false
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel(); return }
        if previewMode {
            let offset: CGPoint
            switch event.keyCode {
            case 123: offset = CGPoint(x: -145, y: 0)
            case 124: offset = CGPoint(x: 145, y: 0)
            case 125: offset = CGPoint(x: 0, y: -118)
            case 126: offset = CGPoint(x: 0, y: 118)
            case 36: finish(); return
            case 49: offset = .zero
            default: super.keyDown(with: event); return
            }
            update(CGPoint(x: gestureOrigin.x + offset.x, y: gestureOrigin.y + offset.y))
        } else { super.keyDown(with: event) }
    }
    override func resignFirstResponder() -> Bool { cancel(); return true }
    func showPreview() {
        cancel()
        window?.makeFirstResponder(self)
        compression = PressureFeedback.minimumCompression
        begin(at: CGPoint(x: bounds.midX, y: bounds.midY))
        previewMode = true
        onStatus?("外观预览：移动指针或按方向键选择；Esc 取消")
    }
    func demonstrateCompression() {
        showPreview()
        guard let target = radialMenu else { return }
        feedbackTimer?.invalidate()
        let started = ProcessInfo.processInfo.systemUptime
        onStatus?("加力演示 · 中央玻璃随力度轻微形变")
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak target] timer in
            guard let self, let target, self.radialMenu === target, self.previewMode else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let value: CGFloat
            if elapsed < 0.26 {
                let t = CGFloat(elapsed / 0.26); value = t * t * (3 - 2 * t)
            } else if elapsed < 0.66 { value = 1 }
            else {
                let t = min(1, CGFloat((elapsed - 0.66) / 0.30)); value = 1 - t * t * (3 - 2 * t)
            }
            let simulatedCompression = PressureFeedback.minimumCompression + (1 - PressureFeedback.minimumCompression) * value
            self.compression = simulatedCompression
            target.updateInteraction(displacement: self.pointerDisplacement, compression: simulatedCompression)
            if elapsed >= 0.96 {
                timer.invalidate(); self.feedbackTimer = nil
                self.onStatus?("移动指针选择，点击确认；Esc 取消")
            }
        }
        feedbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func begin(at point: CGPoint) {
        guard selection == nil else { return }
        guard point.x >= 230, point.x <= bounds.width-230, point.y >= 165, point.y <= bounds.height-165 else {
            onStatus?("请在体验区中央附近重按")
            return
        }
        pressConsumed = true
        gestureOrigin = point; pointerDisplacement = .zero; lastFocus = .center
        let scene = scenes[sceneIndex]
        let defaultIndex: Int? = useDefault ? 0 : nil
        needsDisplay = true
        selection = RadialSelection(center: point, items: scene.actions, defaultIndex: defaultIndex, outerRadius: 230)
        let view = RadialMenuView(items: scene.actions, appName: scene.name, defaultIndex: defaultIndex)
        radialMenu = view
        view.present(at: point, in: self)
        update(point)
    }
    private func update(_ point: CGPoint) {
        guard var current = selection else { return }
        let focus = current.update(point)
        pointerDisplacement = CGPoint(x: point.x - gestureOrigin.x, y: point.y - gestureOrigin.y)
        selection = current
        radialMenu?.update(focus: focus, hasLeftCenter: current.hasLeftCenter)
        radialMenu?.updateInteraction(displacement: pointerDisplacement, compression: compression)
        if focus != lastFocus, case .action = focus, physicalDown, !ordinaryPress {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastFocus = focus
        switch focus {
        case .action(let index): onStatus?("松手：\(scenes[sceneIndex].actions[index].title)")
        case .center: onStatus?(useDefault && !current.hasLeftCenter ? "松手：\(scenes[sceneIndex].actions[0].title)" : "松手：取消")
        case .outside: onStatus?("松手：取消")
        }
    }
    private func finish() {
        guard var current = selection else { return }
        let chosen = current.release()
        feedbackTimer?.invalidate(); feedbackTimer = nil
        pressureFeedback.reset(); compression = 0
        selection = nil; previewMode = false; needsDisplay = true
        if let chosen { onStatus?("已选择：\(scenes[sceneIndex].actions[chosen].title)") }
        else { onStatus?("已取消 · 再按一次试试") }
        let closing = radialMenu; radialMenu = nil
        closing?.dismiss(selectedIndex: chosen, released: true) {}
    }
    func cancel() {
        feedbackTimer?.invalidate(); feedbackTimer = nil
        pressureFeedback.reset(); compression = 0
        physicalDown = false
        guard selection != nil || radialMenu != nil else { return }
        selection?.cancel(); selection = nil; previewMode = false; needsDisplay = true
        let closing = radialMenu; radialMenu = nil
        closing?.dismiss(selectedIndex: nil) {}
        onStatus?("已取消 · 再按一次试试")
    }
}

@main
private final class PreviewApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let canvas = PreviewCanvas()
    private let status = label("重按后保持按住，滑动选择，松手完成", size: 15, weight: .medium)
    private let pressure = label("等待按压", size: 11, color: .tertiaryLabelColor)
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let appMenu = NSMenu()
        let root = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "退出手势预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = submenu; appMenu.addItem(root); NSApp.mainMenu = appMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "按刻 · 手势预览"
        window.minSize = NSSize(width: 880, height: 760)
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let rootView = NSView(); window.contentView = rootView
        let heading = label("动作，随手展开", size: 25, weight: .semibold)
        let subtitle = label("重按 · 滑动 · 松手", size: 13, color: .secondaryLabelColor)
        let picker = NSSegmentedControl(labels: scenes.map(\.name), trackingMode: .selectOne, target: self, action: #selector(sceneChanged(_:)))
        picker.selectedSegment = 0
        let defaultToggle = NSButton(checkboxWithTitle: "原地松手执行上方动作", target: self, action: #selector(defaultChanged(_:)))
        defaultToggle.font = .systemFont(ofSize: 12)
        let mouseToggle = NSButton(checkboxWithTitle: "普通按住预览", target: self, action: #selector(mouseChanged(_:)))
        mouseToggle.font = .systemFont(ofSize: 12)
        let preview = NSButton(title: "展开预览", target: self, action: #selector(showPreview))
        preview.bezelStyle = .rounded
        let pressureDemo = NSButton(title: "加力演示", target: self, action: #selector(showCompression))
        pressureDemo.bezelStyle = .rounded
        let note = label("交互预览 · 选择结果会显示在下方", size: 11, color: .secondaryLabelColor)
        let controls = NSStackView(views: [defaultToggle, mouseToggle, preview, pressureDemo]); controls.spacing = 22; controls.alignment = .centerY
        for view in [heading, subtitle, picker, canvas, status, pressure, controls, note] {
            view.translatesAutoresizingMaskIntoConstraints = false; rootView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.centerXAnchor.constraint(equalTo: rootView.centerXAnchor), heading.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 22),
            subtitle.centerXAnchor.constraint(equalTo: rootView.centerXAnchor), subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            picker.centerXAnchor.constraint(equalTo: rootView.centerXAnchor), picker.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            canvas.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 20), canvas.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 28), canvas.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -28),
            canvas.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -18),
            status.centerXAnchor.constraint(equalTo: rootView.centerXAnchor), status.bottomAnchor.constraint(equalTo: pressure.topAnchor, constant: -7),
            pressure.centerXAnchor.constraint(equalTo: rootView.centerXAnchor), pressure.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -17),
            controls.centerXAnchor.constraint(equalTo: rootView.centerXAnchor), controls.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -12),
            note.centerXAnchor.constraint(equalTo: rootView.centerXAnchor), note.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16)
        ])
        canvas.onStatus = { [weak self] in self?.status.stringValue = $0 }
        canvas.onPressure = { [weak self] in self?.pressure.stringValue = $0 }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.canvas.cancel() }
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func sceneChanged(_ sender: NSSegmentedControl) { canvas.sceneIndex = sender.selectedSegment; status.stringValue = "重按后保持按住，滑动选择，松手完成" }
    @objc private func defaultChanged(_ sender: NSButton) { canvas.cancel(); canvas.useDefault = sender.state == .on }
    @objc private func mouseChanged(_ sender: NSButton) { canvas.cancel(); canvas.ordinaryPress = sender.state == .on; canvas.needsDisplay = true }
    @objc private func showPreview() { canvas.showPreview() }
    @objc private func showCompression() { canvas.demonstrateCompression() }
    func windowDidResignKey(_ notification: Notification) { canvas.cancel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    static func main() {
        let application = NSApplication.shared
        let delegate = PreviewApp(); application.delegate = delegate; application.run()
    }
}
