import AppKit

private final class ForceCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ForceCaptureView: NSView {
    var onEvent: ((NSEvent) -> Void)?
    var appName = ""
    var bundleID = ""
    var pressure = 0.0
    var stage = 0
    private var normalizedPressure: Double { pressure.isFinite ? min(1, max(0, pressure)) : 0 }
    var message = "按下并继续加力；Esc 取消"

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("指针浮层")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { onEvent?(event) }
    override func mouseUp(with event: NSEvent) { onEvent?(event) }
    override func pressureChange(with event: NSEvent) { onEvent?(event) }
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}

    func refresh() {
        setAccessibilityValue("当前应用：\(appName)，力度 \(Int(normalizedPressure * 100))%。\(message)")
        needsDisplay = true
    }

    private func drawText(_ value: String, in rect: NSRect, size: CGFloat,
                          weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                          monospaced: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                              : NSFont.systemFont(ofSize: size, weight: weight)
        value.draw(in: rect, withAttributes: [.font: font, .foregroundColor: color,
                                             .paragraphStyle: paragraph])
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
        NSColor.windowBackgroundColor.setFill()
        body.fill()
        NSColor.systemBlue.withAlphaComponent(0.09).setFill()
        body.fill()
        NSColor.systemBlue.withAlphaComponent(0.3).setStroke()
        body.lineWidth = 1
        body.stroke()
        drawText(appName, in: NSRect(x: 16, y: 139, width: 268, height: 18), size: 13, weight: .semibold)
        drawText("重按后选择动作", in: NSRect(x: 16, y: 123, width: 268, height: 15), size: 10, color: .secondaryLabelColor)

        let center = NSPoint(x: bounds.midX, y: 83)
        let ringRect = NSRect(x: center.x - 28, y: center.y - 28, width: 56, height: 56)
        NSColor.systemBlue.withAlphaComponent(0.16).setStroke()
        let ring = NSBezierPath(ovalIn: ringRect)
        ring.lineWidth = 6
        ring.stroke()
        let progress = pressure.isFinite ? min(1, max(0, pressure)) : 0
        if progress > 0 || stage >= 2 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: 28, startAngle: 90,
                          endAngle: 90 - CGFloat(max(0.02, progress)) * 360, clockwise: true)
            (stage >= 2 ? NSColor.systemGreen : NSColor.systemBlue).setStroke()
            arc.lineWidth = 6
            arc.lineCapStyle = .round
            arc.stroke()
        }
        let centerText = stage >= 2 ? "重按" : "按下"
        drawText(centerText, in: NSRect(x: center.x - 16, y: center.y - 9, width: 40, height: 20),
                 size: 14, weight: .medium, color: stage >= 2 ? .systemGreen : .systemBlue)
        drawText("力度", in: NSRect(x: 199, y: 85, width: 90, height: 17),
                 size: 11, color: .secondaryLabelColor, monospaced: true)
        drawText(String(format: "%.0f%%", normalizedPressure * 100), in: NSRect(x: 199, y: 67, width: 90, height: 17),
                 size: 11, color: .secondaryLabelColor, monospaced: true)
        drawText(message, in: NSRect(x: 16, y: 15, width: 268, height: 21), size: 12,
                 color: stage >= 2 ? .systemGreen : .secondaryLabelColor)
    }
}

final class CaptureOverlayController: NSObject {
    var onEvent: ((NSEvent) -> Void)?
    var onCommit: ((String, String) -> Void)?
    var onCancel: ((String) -> Void)?
    var isVisible: Bool { panel?.isVisible ?? false }

    private var panel: ForceCapturePanel?
    private var captureView: ForceCaptureView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var idleTimer: Timer?
    private var cycle = PressureCycle(source: "overlay")
    private var holding = false
    private var hasDeepPress = false
    private var originAppName = ""
    private var originBundleID = ""

    func show(appName: String, bundleID: String) {
        precondition(Thread.isMainThread)
        if isVisible {
            dismiss(reason: "再次唤出，已收起浮层")
            return
        }
        ensurePanel()
        guard let panel, let captureView else { return }
        originAppName = appName
        originBundleID = bundleID
        holding = false
        hasDeepPress = false
        cycle = PressureCycle(source: "overlay")
        _ = cycle.accept(.cancel)
        captureView.appName = appName
        captureView.bundleID = bundleID
        captureView.stage = 0
        captureView.pressure = 0
        captureView.message = "按下并继续加力；Esc 取消"
        captureView.refresh()

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let size = NSSize(width: 300, height: 170)
        var origin = NSPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2)
        if let bounds = screen?.frame {
            origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
            origin.y = max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        installMonitors()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(captureView)
        scheduleIdleTimer()
    }

    func dismiss(reason: String, notify: Bool = true) {
        precondition(Thread.isMainThread)
        let wasVisible = isVisible
        idleTimer?.invalidate()
        idleTimer = nil
        removeMonitors()
        holding = false
        hasDeepPress = false
        _ = cycle.accept(.cancel)
        panel?.orderOut(nil)
        if wasVisible && notify { onCancel?(reason) }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let window = ForceCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 170),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = ForceCaptureView(frame: NSRect(x: 0, y: 0, width: 300, height: 170))
        view.onEvent = { [weak self] event in self?.receive(event) }
        window.contentView = view
        captureView = view
        panel = window
    }

    private func receive(_ event: NSEvent) {
        guard isVisible, let captureView else { return }
        switch event.type {
        case .leftMouseDown:
            holding = true
            idleTimer?.invalidate()
            idleTimer = nil
            _ = cycle.accept(.mouseDown)
            captureView.message = "继续加力，直到第二次触感反馈"
        case .pressure:
            let value = Double(event.pressure)
            let stage = event.stage
            if stage > 0 {
                holding = true
                idleTimer?.invalidate()
                idleTimer = nil
            }
            captureView.pressure = value
            captureView.stage = stage
            if cycle.accept(.pressure(stage: stage, value: value)) { hasDeepPress = true }
            if stage < 0 || !value.isFinite || !(0...1).contains(value) { hasDeepPress = false }
            if hasDeepPress { captureView.message = "已就绪，松开后选择动作" }
        case .leftMouseUp:
            holding = false
            _ = cycle.accept(.mouseUp)
            captureView.pressure = 0
            captureView.stage = 0
        default:
            return
        }
        captureView.refresh()
        onEvent?(event)
        guard isVisible else { return }
        if event.type == .leftMouseUp {
            if hasDeepPress {
                let name = originAppName
                let bundle = originBundleID
                dismiss(reason: "重按完成", notify: false)
                onCommit?(name, bundle)
            } else {
                captureView.message = "刚才是普通点击；按下后请继续加力"
                captureView.refresh()
                scheduleIdleTimer()
            }
        }
    }

    private func installMonitors() {
        removeMonitors()
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] _ in
            self?.cancelIfOutside()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [mouseMask, .keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 && self.panel?.isKeyWindow == true {
                    self.dismiss(reason: "按 Esc 取消")
                    return nil
                }
            } else {
                self.cancelIfOutside()
            }
            return event
        }
    }

    private func cancelIfOutside() {
        guard isVisible, let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        dismiss(reason: "点击区域外，已取消")
    }

    private func scheduleIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard isVisible, !holding else { return }
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, self.isVisible, !self.holding else { return }
            self.dismiss(reason: "10 秒未操作，已收起浮层")
        }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    deinit {
        idleTimer?.invalidate()
        removeMonitors()
        panel?.orderOut(nil)
    }
}
