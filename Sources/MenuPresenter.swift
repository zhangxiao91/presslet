import AppKit

final class MenuPresenter: NSObject {
    var onAction: ((MenuAction, NSRunningApplication?, ActionContext?, NSPoint) -> Void)?
    var onDismiss: ((String) -> Void)?
    var onConfigure: (() -> Void)?
    var onStateChange: (() -> Void)?

    private(set) var menuID: UUID?
    private(set) var targetApp: NSRunningApplication?
    private(set) var profileBundleID = "*"
    var isVisible: Bool { panel?.isVisible == true }
    var isPressHeld: Bool { pressHeld }
    var frame: NSRect? { panel?.frame }
    var hasRadialMenu: Bool { panel?.radialMenu != nil }

    private var panel: ActionPanel?
    private var actions: [MenuAction] = []
    private var context: ActionContext?
    private var inputButtons: [NSButton] = []
    private var inputLabel: NSTextField?
    private var pressHeld = false
    private var radialSelection: RadialSelection?
    private var radialOrigin = NSPoint.zero
    private var radialLastPoint = NSPoint.zero
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
        actions = enabled
        targetApp = target
        profileBundleID = profile.bundleID
        self.context = acceptedContext(context)
        inputButtons = []
        inputLabel = nil
        pressHeld = held

        let radial = actions.count <= 3
        let p = ActionPanel(contentRect: NSRect(x: 0, y: 0, width: radial ? 480 : 340,
                                               height: radial ? 400 : 168 + CGFloat(actions.count) * 38),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.actionCount = actions.count
        p.title = "动作菜单"
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = !radial
        p.isReleasedWhenClosed = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let appName = profile.bundleID == "*" ? (target?.localizedName ?? "通用动作") : profile.appName
        let visible = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)

        if radial {
            let host = NSView(frame: NSRect(origin: .zero, size: p.frame.size))
            host.wantsLayer = true
            p.contentView = host
            let directions: [RadialDirection] = [.up, .left, .right]
            let items = actions.enumerated().map { index, action in
                RadialItem(id: action.id, title: action.title,
                           symbol: action.kind == .workflow ? "wand.and.stars" : action.kind == .open ? "arrow.up.forward.app" : "command",
                           direction: directions[index])
            }
            p.radialMenu = RadialMenuView(items: items, appName: appName, defaultIndex: nil)
            p.radialMenu?.useFloatingBackdrop()
            radialOrigin = point
            radialLastPoint = point
            radialSelection = RadialSelection(center: point, items: items, outerRadius: 230)
            radialFeedback.reset()
            radialCompression = held ? PressureFeedback.minimumCompression : 0
            let heading = label(appName, size: 12, weight: .medium, color: .secondaryLabelColor)
            heading.alignment = .center
            let caption = label("", size: 12, color: .secondaryLabelColor)
            caption.alignment = .center
            caption.maximumNumberOfLines = 2
            caption.lineBreakMode = .byTruncatingTail
            p.setFrameOrigin(NSPoint(x: point.x - 240, y: point.y - 165))
            let infoSurface = NSVisualEffectView(frame: NSRect(x: 56, y: 326, width: 368, height: 68))
            infoSurface.material = .popover
            infoSurface.blendingMode = .behindWindow
            infoSurface.state = .active
            infoSurface.wantsLayer = true
            infoSurface.layer?.cornerRadius = 18
            infoSurface.layer?.masksToBounds = true
            host.addSubview(infoSurface)
            heading.frame = NSRect(x: 68, y: 365, width: 344, height: 20)
            caption.frame = NSRect(x: 68, y: 330, width: 344, height: 32)
            host.addSubview(heading)
            host.addSubview(caption)
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
        } else {
            radialSelection = nil
            let background = NSVisualEffectView()
            background.material = .menu
            background.blendingMode = .behindWindow
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 12
            background.layer?.masksToBounds = true
            p.contentView = background
            let caption = label("", size: 12, color: .secondaryLabelColor)
            inputLabel = caption
            var views: [NSView] = [label(appName, size: 18, weight: .semibold), caption]
            for (index, action) in actions.enumerated() {
                let row = button("\(index + 1)   \(action.title)", self, #selector(configuredAction(_:)))
                row.tag = index + 1
                row.alignment = .left
                row.lineBreakMode = .byTruncatingTail
                inputButtons.append(row)
                views.append(row)
            }
            let configure = button("配置…", self, #selector(configure))
            views.append(stack([label("数字选择 · Esc 关闭", size: 11, color: .secondaryLabelColor), configure], vertical: false, spacing: 16))
            let content = stack(views, spacing: 10)
            content.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
                content.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
                content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20)
            ])
            p.setFrameOrigin(NSPoint(x: min(max(visible.minX + 8, point.x + 12), visible.maxX - p.frame.width - 8),
                                     y: min(max(visible.minY + 8, point.y - p.frame.height - 12), visible.maxY - p.frame.height - 8)))
        }

        p.perform = { [weak self] n in self?.performAction(n) }
        p.onDismiss = { [weak self] in self?.dismiss(reason: "按 Esc") }
        panel = p
        p.setPressHeld(pressHeld)
        refreshInputState()
        p.present(from: point)
        if radial {
            p.radialMenu?.updateInteraction(displacement: .zero, compression: pressHeld ? PressureFeedback.minimumCompression : 0)
        }
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
        if hasRadialMenu {
            updatePointer(point)
            commitRadialSelection()
            return
        }
        pressHeld = false
        let heldPanel = panel
        onStateChange?()
        // The release that opened a list must not activate one of its rows.
        DispatchQueue.main.async { [weak self, weak heldPanel] in
            guard let self, let heldPanel, self.panel === heldPanel, !self.pressHeld else { return }
            heldPanel.setPressHeld(false)
        }
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

    @objc private func configuredAction(_ sender: NSButton) { performAction(sender.tag) }

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
        for (index, row) in inputButtons.enumerated() {
            row.isEnabled = states[index].isAvailable
            row.toolTip = states[index].reason ?? actions[index].inputRequirement.displayName
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
        context = nil
        inputLabel = nil
        inputButtons = []
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
