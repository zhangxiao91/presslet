import AppKit

private final class ActionResultPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

final class ActionResultController: NSObject {
    private var panel: ActionResultPanel?
    private var fullResult = ""
    private var copyAllowed = false

    func show(title: String, message: String, near point: NSPoint, isError: Bool = false) {
        precondition(Thread.isMainThread)
        panel?.orderOut(nil)
        panel = nil

        let completionPrefix = "快捷指令已完成。\n"
        fullResult = message.hasPrefix(completionPrefix)
            ? String(message.dropFirst(completionPrefix.count)) : message
        copyAllowed = !isError && !fullResult.isEmpty
        let shortened = fullResult.count > 2_000
        let visibleText = String(fullResult.prefix(2_000))
            + (shortened ? "\n\n……\n复制结果可获取完整内容。" : "")
        let body = visibleText.isEmpty ? (isError ? "动作未完成。" : "已完成。") : visibleText
        let width: CGFloat = 380
        let contentWidth = width - 36
        let font = NSFont.systemFont(ofSize: 13)
        let measured = (body as NSString).boundingRect(
            with: NSSize(width: contentWidth - 16, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let bodyHeight = min(260, max(56, ceil(measured.height) + 16))
        let height = bodyHeight + 108

        let resultPanel = ActionResultPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                            styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
        resultPanel.isReleasedWhenClosed = false
        resultPanel.level = .popUpMenu
        resultPanel.hidesOnDeactivate = false
        resultPanel.becomesKeyOnlyIfNeeded = true
        resultPanel.isFloatingPanel = true
        resultPanel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        resultPanel.backgroundColor = .clear
        resultPanel.isOpaque = false
        resultPanel.hasShadow = true
        resultPanel.animationBehavior = .none
        resultPanel.title = title
        resultPanel.onDismiss = { [weak self] in self?.dismiss() }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        resultPanel.contentView = root

        let material: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(frame: root.bounds)
            solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            material = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: root.bounds)
            glass.style = .regular
            glass.cornerRadius = 18
            material = glass
        } else {
            let effect = NSVisualEffectView(frame: root.bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            material = effect
        }
        material.autoresizingMask = [.width, .height]
        root.addSubview(material)

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.textColor = isError ? .systemRed : .labelColor
        heading.lineBreakMode = .byTruncatingTail
        heading.maximumNumberOfLines = 1

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: bodyHeight))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.string = body
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: bodyHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                 height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        textView.setAccessibilityLabel("动作结果")

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView

        let copy = NSButton(title: "复制结果", target: self, action: #selector(copyResult(_:)))
        copy.bezelStyle = .rounded
        copy.isEnabled = copyAllowed
        let close = NSButton(title: "关闭", target: self, action: #selector(closeResult(_:)))
        close.bezelStyle = .rounded

        for view in [heading, scroll, copy, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            heading.heightAnchor.constraint(equalToConstant: 22),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.heightAnchor.constraint(equalToConstant: bodyHeight),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            close.heightAnchor.constraint(equalToConstant: 28),
            copy.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            copy.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            copy.heightAnchor.constraint(equalToConstant: 28)
        ])
        root.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()

        let finitePoint = point.x.isFinite && point.y.isFinite
            ? point : (NSScreen.main?.visibleFrame.origin ?? .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(finitePoint) } ?? NSScreen.main
        if let bounds = screen?.visibleFrame.insetBy(dx: 12, dy: 12) {
            var origin = NSPoint(x: finitePoint.x + 14, y: finitePoint.y - height - 14)
            if origin.y < bounds.minY { origin.y = finitePoint.y + 14 }
            origin.x = min(max(bounds.minX, origin.x), max(bounds.minX, bounds.maxX - width))
            origin.y = min(max(bounds.minY, origin.y), max(bounds.minY, bounds.maxY - height))
            resultPanel.setFrameOrigin(origin)
        }
        panel = resultPanel
        resultPanel.alphaValue = 0
        resultPanel.orderFront(nil)
        // Fading also suits Reduce Motion; no spatial animation moves the result.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            resultPanel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        precondition(Thread.isMainThread)
        guard let closing = panel else { return }
        panel = nil
        fullResult = ""
        copyAllowed = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            closing.animator().alphaValue = 0
        }, completionHandler: {
            closing.orderOut(nil)
        })
    }

    @objc private func copyResult(_ sender: Any?) {
        guard copyAllowed, panel != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullResult, forType: .string)
    }

    @objc private func closeResult(_ sender: Any?) { dismiss() }
}
