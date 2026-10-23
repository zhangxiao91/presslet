import AppKit

final class MenuPresenter: NSObject {
    var onAction: ((MenuAction, NSRunningApplication?, ActionContext?, NSPoint) -> Void)?
    var onDismiss: ((String) -> Void)?
    var onConfigure: (() -> Void)?
    var onStateChange: (() -> Void)?

    private(set) var menuID: UUID?
    private(set) var presentedAt: TimeInterval = 0
    private(set) var targetApp: NSRunningApplication?
    private(set) var profileBundleID = "*"
    var isVisible: Bool { panel?.isVisible == true }
    var isPressHeld: Bool { pressHeld }
    var frame: NSRect? { panel?.frame }
    var hasRadialMenu: Bool { panel?.radialMenu != nil }

    private var panel: ActionPanel?
    private var actions: [MenuAction] = []
    private var context: ActionContext?
    private var inputLabel: NSTextField?
    private var pressHeld = false
    private var radialSelection: RadialSelection?
    private var radialOrigin = NSPoint.zero
    private var radialLastPoint = NSPoint.zero
    private var radialTriggerPoint: NSPoint?
    private var radialFeedback = PressureFeedback()
    private var radialCompression: CGFloat = 0

    func contains(window: NSWindow?) -> Bool {
        guard let window, let panel else { return false }
        return panel === window
    }

    @discardableResult
    func show(profile: AppProfile, target: NSRunningApplication?, near point: NSPoint,
              held: Bool, context: ActionContext? = nil) -> UUID? {
        let enabled = Array(profile.actions.filter { $0.isEnabled }.prefix(9))
        guard !enabled.isEmpty else { return nil }
        if panel != nil { dismiss(reason: "打开新菜单") }
        let id = UUID()
        menuID = id
        presentedAt = ProcessInfo.processInfo.systemUptime
        actions = enabled
        targetApp = target
        profileBundleID = profile.bundleID
        self.context = acceptedContext(context)
        inputLabel = nil
        pressHeld = held

        let layout = RadialMenuView.layoutSize(for: actions.count)
        let anchor = RadialMenuView.anchor(for: actions.count)
        let p = ActionPanel(contentRect: NSRect(x: 0, y: 0, width: layout.width + 20, height: layout.height + 76),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.actionCount = actions.count
        p.title = "动作菜单"
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let appName = profile.bundleID == "*" ? (target?.localizedName ?? "通用动作") : profile.appName
        let visible = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let panelAnchor = NSPoint(x: anchor.x + 10, y: anchor.y)
        let placement = RadialMenuPlacement(trigger: point, panelSize: p.frame.size, anchor: panelAnchor, visibleFrame: visible)
        p.setFrameOrigin(placement.frame.origin)
        radialOrigin = placement.center
        radialLastPoint = radialOrigin
        radialTriggerPoint = held ? point : nil

        let host = NSView(frame: NSRect(origin: .zero, size: p.frame.size))
        host.wantsLayer = true
        p.contentView = host
        let items = actions.enumerated().map { index, action in
            RadialItem(id: action.id, title: action.title,
                       symbol: action.kind == .workflow ? "wand.and.stars" : action.kind == .open ? "arrow.up.forward.app" : "command",
                       angle: RadialItem.menuAngle(index: index, count: actions.count))
        }
        p.radialMenu = RadialMenuView(items: items, appName: appName, defaultIndex: nil)
        p.radialMenu?.useFloatingBackdrop()
        p.radialMenu?.onClick = { [weak self] index in self?.performAction(index + 1) }
        p.radialMenu?.onCancel = { [weak self] in self?.dismiss(reason: "取消") }
        radialSelection = RadialSelection(center: radialOrigin, items: items, outerRadius: actions.count <= 3 ? 230 : 310)
        radialFeedback.reset()
        radialCompression = held ? PressureFeedback.minimumCompression : 0
        let heading = label(appName, size: 12, weight: .medium, color: .secondaryLabelColor)
        heading.alignment = .center
        let caption = label("", size: 12, color: .secondaryLabelColor)
        caption.alignment = .center
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byTruncatingTail
        let infoWidth = min(368, layout.width - 80)
        let infoX = (p.frame.width - infoWidth) / 2
        let infoY = layout.height - 4
        let infoSurface = NSVisualEffectView(frame: NSRect(x: infoX, y: infoY, width: infoWidth, height: 68))
        infoSurface.material = .popover
        infoSurface.blendingMode = .behindWindow
        infoSurface.state = .active
        infoSurface.wantsLayer = true
        infoSurface.layer?.cornerRadius = 18
        infoSurface.layer?.masksToBounds = true
        host.addSubview(infoSurface)
        heading.frame = NSRect(x: infoX + 32, y: infoY + 39, width: infoWidth - 64, height: 20)
        caption.frame = NSRect(x: infoX + 12, y: infoY + 4, width: infoWidth - 24, height: 32)
        host.addSubview(heading)
        host.addSubview(caption)
        let configureButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "配置动作")!,
                                       target: self, action: #selector(configure))
        configureButton.isBordered = false
        configureButton.toolTip = "配置动作"
        configureButton.frame = NSRect(x: infoX + infoWidth - 30, y: infoY + 38, width: 22, height: 22)
        host.addSubview(configureButton)
        inputLabel = caption
        p.onRadialPoint = { [weak self] point, commit in
            self?.updatePointer(point)
            if commit { self?.commitRadialSelection() }
        }
        p.onRadialKey = { [weak self] key in
            guard let self else { return }
            if key == 36 { self.commitRadialSelection(); return }
            let offset: CGPoint = key == 123 ? CGPoint(x: -145, y: 0)
                : key == 124 ? CGPoint(x: 145, y: 0)
                : key == 126 ? CGPoint(x: 0, y: 118)
                : key == 125 ? CGPoint(x: 0, y: -118) : .zero
            self.updatePointer(NSPoint(x: self.radialOrigin.x + offset.x, y: self.radialOrigin.y + offset.y))
        }
        p.perform = { [weak self] n in self?.performAction(n) }
        p.onDismiss = { [weak self] in self?.dismiss(reason: "按 Esc") }
        panel = p
        p.setPressHeld(pressHeld)
        refreshInputState()
        p.present(from: radialOrigin)
        p.radialMenu?.updateInteraction(displacement: .zero, compression: radialCompression)
        onStateChange?()
        return id
    }

    func updateContext(_ context: ActionContext, for menuID: UUID) {
        guard self.menuID == menuID, isVisible, let context = acceptedContext(context) else { return }
        self.context = context
        refreshInputState()
    }

    func updatePointer(_ point: NSPoint) {
        guard var selection = radialSelection, let view = panel?.radialMenu else { return }
        // At a screen edge the menu shifts inward. Releasing at the original
        // press location must still cancel, even when that point is off-center.
        let point = radialTriggerPoint.map { hypot(point.x - $0.x, point.y - $0.y) <= 16 } == true ? radialOrigin : point
        radialLastPoint = point
        let previous = selection.focus
        let focus = selection.update(point)
        radialSelection = selection
        view.update(focus: focus, hasLeftCenter: selection.hasLeftCenter)
        view.updateInteraction(displacement: CGPoint(x: point.x - radialOrigin.x, y: point.y - radialOrigin.y), compression: radialCompression)
        if case .action(let index) = focus, actions.indices.contains(index) {
            let action = actions[index]
            let availability = context?.availability(for: action.inputRequirement)
            if action.inputRequirement != .none, availability?.isAvailable != true {
                inputLabel?.stringValue = availability?.reason ?? "正在读取选中内容…"
            } else {
                inputLabel?.stringValue = "松手：\(action.title)"
                if previous != focus, pressHeld {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
        } else { inputLabel?.stringValue = "松手取消" }
    }

    func updatePressure(_ event: NSEvent) {
        guard pressHeld, let view = panel?.radialMenu else { return }
        radialCompression = radialFeedback.update(stage: event.stage, pressure: CGFloat(event.pressure))
        view.updateInteraction(displacement: CGPoint(x: radialLastPoint.x - radialOrigin.x, y: radialLastPoint.y - radialOrigin.y), compression: radialCompression)
    }

    func release(at point: NSPoint) {
        guard pressHeld, isVisible else { return }
        updatePointer(point)
        commitRadialSelection()
    }

    func dismiss(reason: String) {
        let wasVisible = isVisible
        clearAndDismiss()
        if wasVisible { onDismiss?(reason) }
    }

    func performAction(_ n: Int) {
        guard isVisible, !pressHeld, n > 0, n <= actions.count else { return }
        let action = actions[n - 1]
        let actionContext = action.inputRequirement == .none ? nil : acceptedContext(context)
        if action.inputRequirement != .none {
            guard let availability = actionContext?.availability(for: action.inputRequirement), availability.isAvailable else {
                dismiss(reason: actionContext?.availability(for: action.inputRequirement).reason ?? "尚未取得动作需要的选中内容。")
                return
            }
        }
        let target = targetApp
        let resultPoint = hasRadialMenu ? radialOrigin : NSEvent.mouseLocation
        if hasRadialMenu { panel?.radialSelectedIndex = n - 1 }
        clearAndDismiss()
        onAction?(action, target, actionContext, resultPoint)
    }

    @objc private func configure() {
        dismiss(reason: "打开配置")
        onConfigure?()
    }

    private func acceptedContext(_ context: ActionContext?) -> ActionContext? {
        guard let context else { return nil }
        guard let target = targetApp else { return context.sourcePID == 0 ? context : nil }
        return context.sourcePID == target.processIdentifier ? context : nil
    }

    private func refreshInputState() {
        let states = actions.map { action -> ActionAvailability in
            if action.inputRequirement == .none { return ActionAvailability(isAvailable: true) }
            return context?.availability(for: action.inputRequirement)
                ?? ActionAvailability(isAvailable: false, reason: "正在读取选中内容…")
        }
        panel?.radialMenu?.setAvailability(states.map { $0.isAvailable })
        if let text = context?.selectedText, !text.isEmpty {
            inputLabel?.stringValue = "选中 \(text.count) 字 · \(text.prefix(36).replacingOccurrences(of: "\n", with: " "))"
        } else if let files = context?.fileURLs, !files.isEmpty {
            inputLabel?.stringValue = files.count == 1 ? files[0].lastPathComponent : "已选 \(files.count) 个文件"
        } else if actions.contains(where: { $0.inputRequirement != .none }) {
            inputLabel?.stringValue = context?.unavailableReason ?? (context == nil ? "正在读取选中内容…" : "请先在原 App 中选中文字或文件")
        } else { inputLabel?.stringValue = "按住滑选 · 松手执行 · 回中央取消" }
        if let selection = radialSelection {
            panel?.radialMenu?.update(focus: selection.focus, hasLeftCenter: selection.hasLeftCenter)
        }
    }

    private func commitRadialSelection() {
        guard var selection = radialSelection else { return }
        let index = selection.release()
        radialSelection = nil
        pressHeld = false
        panel?.setPressHeld(false)
        if let index { performAction(index + 1) }
        else { dismiss(reason: "回中央取消") }
    }

    private func clearAndDismiss() {
        let closing = panel
        panel = nil
        radialSelection = nil
        radialTriggerPoint = nil
        context = nil
        inputLabel = nil
        actions = []
        menuID = nil
        targetApp = nil
        pressHeld = false
        radialFeedback.reset()
        radialCompression = 0
        closing?.dismissWithMotion()
        onStateChange?()
    }
}
