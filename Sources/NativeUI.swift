import AppKit

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
