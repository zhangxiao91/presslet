import AppKit

final class ActionPanel: NSPanel {
    var perform: ((Int) -> Void)?
    var radialMenu: RadialMenuView?
    var radialSelectedIndex: Int?
    var onRadialPoint: ((NSPoint, Bool) -> Void)?
    var onRadialKey: ((UInt16) -> Void)?
    var actionCount = 3
    var onDismiss: (() -> Void)?
    private var motionGeneration = 0
    private var pressHeld = false
    private var dismissing = false
    private var presentedAt: TimeInterval = 0
    private static var retiringPanel: ActionPanel?

    override var canBecomeKey: Bool { !pressHeld }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        guard event.timestamp >= presentedAt else { return }
        if event.keyCode == 53 { onDismiss?(); return }
        guard !pressHeld, !dismissing else { return }
        if [UInt16(123), 124, 125, 126, 36, 49].contains(event.keyCode) {
            onRadialKey?(event.keyCode); return
        }
        if let c = event.charactersIgnoringModifiers, let n = Int(c), (1...max(1, actionCount)).contains(n) {
            perform?(n)
        } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.timestamp >= presentedAt else { return }
        if !pressHeld, !dismissing {
            onRadialPoint?(convertPoint(toScreen: event.locationInWindow), true)
        } else { super.mouseDown(with: event) }
    }

    func setPressHeld(_ held: Bool) {
        pressHeld = held
        ignoresMouseEvents = held || dismissing
    }

    func present(from screenPoint: NSPoint) {
        Self.retiringPanel?.orderOut(nil)
        Self.retiringPanel = nil
        motionGeneration += 1
        presentedAt = ProcessInfo.processInfo.systemUptime
        dismissing = false
        animationBehavior = .none
        ignoresMouseEvents = pressHeld
        contentView?.layoutSubtreeIfNeeded()
        alphaValue = 1
        if pressHeld { orderFrontRegardless() } else { makeKeyAndOrderFront(nil) }
        if let host = contentView {
            radialMenu?.present(at: NSPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY), in: host)
        }
    }

    func dismissWithMotion() {
        guard isVisible, !dismissing else { return }
        motionGeneration += 1
        let generation = motionGeneration
        dismissing = true
        Self.retiringPanel?.orderOut(nil)
        Self.retiringPanel = self
        ignoresMouseEvents = true
        guard let radialMenu else { orderOut(nil); return }
        radialMenu.dismiss(selectedIndex: radialSelectedIndex) { [self] in
            guard self.motionGeneration == generation else { return }
            self.orderOut(nil)
            if Self.retiringPanel === self { Self.retiringPanel = nil }
        }
    }

    override func orderOut(_ sender: Any?) {
        motionGeneration += 1
        super.orderOut(sender)
    }
}
