import AppKit
import QuartzCore

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
    private static var retiringPanel: ActionPanel?
    private let motionKey = "menu.scale"
    private let easing = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    private let fadeEasing = CAMediaTimingFunction(name: .easeOut)
    private let enterDuration: TimeInterval = 0.32
    private let exitDuration: TimeInterval = 0.22

    override var canBecomeKey: Bool { radialMenu == nil || !pressHeld }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?(); return }
        guard !pressHeld, !dismissing else { return }
        if radialMenu != nil, [UInt16(123), 124, 125, 126, 36, 49].contains(event.keyCode) {
            onRadialKey?(event.keyCode); return
        }
        if let c = event.charactersIgnoringModifiers, let n = Int(c), (1...max(1, actionCount)).contains(n) {
            perform?(n)
        } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if radialMenu != nil, !pressHeld, !dismissing {
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
        dismissing = false
        animationBehavior = .none
        ignoresMouseEvents = pressHeld
        contentView?.layoutSubtreeIfNeeded()
        if let radialMenu, let host = contentView {
            alphaValue = 1
            if pressHeld { orderFrontRegardless() } else { makeKeyAndOrderFront(nil) }
            radialMenu.present(at: NSPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY), in: host)
            return
        }
        if let layer = contentView?.layer {
            let anchor = CGPoint(x: min(1, max(0, (screenPoint.x - frame.minX) / frame.width)),
                                 y: min(1, max(0, (screenPoint.y - frame.minY) / frame.height)))
            let oldAnchor = layer.anchorPoint
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.position.x += (anchor.x - oldAnchor.x) * layer.bounds.width
            layer.position.y += (anchor.y - oldAnchor.y) * layer.bounds.height
            layer.anchorPoint = anchor
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A faint first frame confirms the press before the slower fade settles.
        alphaValue = 0.12
        makeKeyAndOrderFront(nil)
        if !reduced { scale(from: CATransform3DMakeScale(0.97, 0.97, 1), to: CATransform3DIdentity, duration: enterDuration) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.15 : enterDuration
            context.timingFunction = fadeEasing
            animator().alphaValue = 1
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
        if let radialMenu {
            radialMenu.dismiss(selectedIndex: radialSelectedIndex) { [self] in
                guard self.motionGeneration == generation else { return }
                self.orderOut(nil)
                if Self.retiringPanel === self { Self.retiringPanel = nil }
            }
            return
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduced, let layer = contentView?.layer {
            scale(from: layer.presentation()?.transform ?? layer.transform,
                  to: CATransform3DMakeScale(0.95, 0.95, 1), duration: exitDuration)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? 0.15 : exitDuration
            context.timingFunction = fadeEasing
            animator().alphaValue = 0
        }, completionHandler: { [self] in
            guard self.motionGeneration == generation else { return }
            self.orderOut(nil)
            if Self.retiringPanel === self { Self.retiringPanel = nil }
        })
    }

    private func scale(from: CATransform3D, to: CATransform3D, duration: TimeInterval) {
        guard let layer = contentView?.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: to)
        animation.duration = duration
        animation.timingFunction = easing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = to
        layer.add(animation, forKey: motionKey)
        CATransaction.commit()
    }

    override func orderOut(_ sender: Any?) {
        motionGeneration += 1
        super.orderOut(sender)
        contentView?.layer?.removeAnimation(forKey: motionKey)
    }
}
