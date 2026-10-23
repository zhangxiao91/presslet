import AppKit
import QuartzCore

private enum RadialMotion {
    static let reveal: CFTimeInterval = 0.32
    static let dismiss: CFTimeInterval = 0.22
    static let focus: CFTimeInterval = 0.10
    static let reduced: CFTimeInterval = 0.15
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    static func transform(_ layer: CALayer, to target: CATransform3D, duration: CFTimeInterval, key: String) {
        let current = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()
        let animation: CABasicAnimation
        if key == "appearance" && duration > reduced {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1
            spring.stiffness = 400
            spring.damping = 39
            spring.initialVelocity = 0
            animation = spring
        } else {
            animation = CABasicAnimation(keyPath: "transform")
            animation.timingFunction = easeOut
        }
        animation.fromValue = NSValue(caTransform3D: current)
        animation.toValue = NSValue(caTransform3D: target)
        animation.duration = duration
        layer.add(animation, forKey: key)
    }

    static func opacity(_ layer: CALayer, to target: Float, duration: CFTimeInterval) {
        let current = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = easeOut
        layer.add(animation, forKey: "visibility")
    }
}

private final class RadialGlassTile: NSView {
    private let attractionHost = NSView()
    private let surfaceHost = NSView()
    private let decoration = NSView()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let edge = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private let tint = CALayer()
    private var material: NSView?
    private var floatingBackdrop: NSVisualEffectView?
    private let round: Bool
    private var selected = false
    private var available = true
    private var currentSymbol = ""
    private var compression: CGFloat = 0
    private var opaqueMaterial: Bool?
    private var displayObserver: NSObjectProtocol?

    init(frame: NSRect, round: Bool = false) {
        self.round = round
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for view in [attractionHost, surfaceHost, decoration] {
            view.frame = bounds
            view.wantsLayer = true
            view.autoresizingMask = [.width, .height]
        }
        addSubview(attractionHost)
        attractionHost.addSubview(surfaceHost)
        surfaceHost.layer?.shadowColor = NSColor.black.cgColor
        surfaceHost.layer?.shadowOpacity = 0.07
        surfaceHost.layer?.shadowRadius = round ? 10 : 13
        surfaceHost.layer?.shadowOffset = CGSize(width: 0, height: -4)
        surfaceHost.layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
        decoration.layer?.cornerRadius = bounds.height / 2
        decoration.layer?.masksToBounds = true
        tint.frame = bounds
        decoration.layer?.addSublayer(tint)
        sheen.frame = bounds
        sheen.startPoint = CGPoint(x: 0.25, y: 1)
        sheen.endPoint = CGPoint(x: 0.75, y: 0)
        sheen.locations = [0, 0.35, 1]
        decoration.layer?.addSublayer(sheen)
        edge.path = CGPath(roundedRect: bounds.insetBy(dx: 0.45, dy: 0.45), cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
        edge.fillColor = NSColor.clear.cgColor
        edge.lineWidth = 0.65
        decoration.layer?.addSublayer(edge)

        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .labelColor
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: round ? 10 : 12, weight: .medium)
        titleLabel.textColor = .labelColor
        if round {
            symbolView.frame = NSRect(x: 19, y: 29, width: 18, height: 18)
            titleLabel.frame = NSRect(x: 2, y: 10, width: 52, height: 14)
            titleLabel.alignment = .center
        } else {
            symbolView.frame = NSRect(x: 15, y: 19, width: 18, height: 18)
            titleLabel.frame = NSRect(x: 41, y: 18, width: bounds.width - 51, height: 20)
        }
        attractionHost.addSubview(symbolView)
        attractionHost.addSubview(titleLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refreshMaterial()
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshMaterial()
            self?.setInteraction(attraction: .zero, compression: 0)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMaterial()
    }

    func setContent(title: String, symbol: String) {
        guard titleLabel.stringValue != title || currentSymbol != symbol else { return }
        titleLabel.stringValue = title
        currentSymbol = symbol
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setAccessibilityLabel(title)
    }

    func setAvailable(_ available: Bool) {
        self.available = available
        alphaValue = available ? 1 : 0.38
        setAccessibilityEnabled(available)
    }

    func useFloatingBackdrop() {
        guard floatingBackdrop == nil else { return }
        let backdrop = NSVisualEffectView(frame: bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = bounds.height / 2
        backdrop.layer?.masksToBounds = true
        backdrop.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        surfaceHost.addSubview(backdrop, positioned: .below, relativeTo: material)
        floatingBackdrop = backdrop
    }

    func setSelected(_ selected: Bool, reduceMotion: Bool, animate: Bool = true) {
        let selected = selected && available
        guard self.selected != selected else { return }
        self.selected = selected
        updateChrome()
        symbolView.contentTintColor = selected ? .controlAccentColor : .labelColor
        titleLabel.textColor = selected ? .controlAccentColor : .labelColor
        titleLabel.font = .systemFont(ofSize: round ? 10 : 12, weight: selected ? .semibold : .medium)
        updateShapeTransform()
    }

    /// Input-driven transforms are immediate; entrance and exit live on the outer layer.
    func setInteraction(attraction: CGPoint, compression: CGFloat) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.compression = reduce ? 0 : max(0, min(1, compression))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attractionHost.layer?.transform = reduce ? CATransform3DIdentity : CATransform3DMakeTranslation(attraction.x, attraction.y, 0)
        CATransaction.commit()
        updateShapeTransform()
        updateChrome()
    }

    private func updateShapeTransform() {
        guard let layer = surfaceHost.layer else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let lift: CGFloat = selected && !reduce ? 1.015 : 1
        let squeeze = round && !reduce ? compression : 0
        let sx = lift + squeeze * 0.19
        let sy = lift - squeeze * 0.13
        let pivot = CGPoint(x: layer.bounds.width * (0.5 - layer.anchorPoint.x), y: layer.bounds.height * (0.5 - layer.anchorPoint.y))
        let transform = CATransform3DScale(CATransform3DMakeTranslation(pivot.x * (1 - sx), pivot.y * (1 - sy), 0), sx, sy, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
    }

    private func updateChrome() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let pressure = round ? compression : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(opaque ? 0.10 : 0.13).cgColor : NSColor.clear.cgColor
        edge.strokeColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.36).cgColor : NSColor.white.withAlphaComponent(0.20 + pressure * 0.24).cgColor
        sheen.colors = [NSColor.white.withAlphaComponent(0.045 + pressure * 0.14).cgColor, NSColor.white.withAlphaComponent(0.008).cgColor, NSColor.black.withAlphaComponent(0.008).cgColor]
        CATransaction.commit()
    }

    private func refreshMaterial() {
        guard surfaceHost.layer != nil else { return }
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        floatingBackdrop?.isHidden = opaque
        if opaqueMaterial != opaque {
            if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
                glass.contentView = nil
            }
            decoration.removeFromSuperview()
            material?.removeFromSuperview()
            let next: NSView
            if opaque {
                let solid = NSView(frame: bounds)
                solid.wantsLayer = true
                solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                solid.layer?.cornerRadius = bounds.height / 2
                solid.addSubview(decoration)
                next = solid
            } else if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: bounds)
                glass.style = .clear
                glass.cornerRadius = bounds.height / 2
                glass.tintColor = nil
                glass.contentView = decoration
                next = glass
            } else {
                let effect = NSVisualEffectView(frame: bounds)
                effect.material = .menu
                effect.blendingMode = .withinWindow
                effect.state = .active
                effect.wantsLayer = true
                effect.layer?.cornerRadius = bounds.height / 2
                effect.layer?.masksToBounds = true
                effect.addSubview(decoration)
                next = effect
            }
            next.autoresizingMask = [.width, .height]
            surfaceHost.addSubview(next)
            material = next
            opaqueMaterial = opaque
        } else if opaque {
            material?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        updateChrome()
    }
}

/// A passive rendering surface. The host owns pressure, drag and release events.
final class RadialMenuView: NSView {
    static let layoutSize = NSSize(width: 460, height: 330)
    private static let anchor = NSPoint(x: 230, y: 165)
    private let items: [RadialItem]
    private let appName: String
    private let defaultIndex: Int?
    private var tiles: [RadialGlassTile] = []
    private let centerTile = RadialGlassTile(frame: NSRect(x: 202, y: 137, width: 56, height: 56), round: true)
    private var currentFocus = RadialFocus.center
    private var hasLeftCenter = false
    private var closing = false
    private var visibilityGeneration = 0
    private var actionAvailability: [Bool] = []
    var onClick: ((Int) -> Void)?

    init(items: [RadialItem], appName: String, defaultIndex: Int?) {
        self.items = items
        self.appName = appName
        self.defaultIndex = defaultIndex
        super.init(frame: NSRect(origin: .zero, size: Self.layoutSize))
        wantsLayer = true
        layer?.masksToBounds = false
        for item in items {
            let offset = Self.offset(for: item.direction)
            let frame = NSRect(x: Self.anchor.x + offset.x - 71, y: Self.anchor.y + offset.y - 28, width: 142, height: 56)
            let tile = RadialGlassTile(frame: frame)
            tile.setContent(title: item.title, symbol: item.symbol)
            addSubview(tile)
            tiles.append(tile)
        }
        addSubview(centerTile)
        update(focus: .center, hasLeftCenter: false)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(appName)动作菜单")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Enables sampling of the underlying application in a transparent floating panel.
    /// The standalone preview keeps its existing in-window material by default.
    func useFloatingBackdrop() {
        tiles.forEach { $0.useFloatingBackdrop() }
        centerTile.useFloatingBackdrop()
    }

    func present(at point: CGPoint, in host: NSView) {
        visibilityGeneration += 1
        closing = false
        frame.origin = NSPoint(x: point.x - Self.anchor.x, y: point.y - Self.anchor.y)
        if superview !== host { host.addSubview(self) }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduce ? RadialMotion.reduced : RadialMotion.reveal
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = 0
        for (index, tile) in tiles.enumerated() {
            let offset = Self.offset(for: items[index].direction)
            tile.layer?.transform = reduce ? CATransform3DIdentity : Self.collapsedTransform(offset: offset)
        }
        centerTile.layer?.transform = reduce ? CATransform3DIdentity : CATransform3DMakeScale(0.97, 0.97, 1)
        CATransaction.commit()
        if let layer = layer { RadialMotion.opacity(layer, to: 1, duration: duration) }
        for tile in tiles {
            if let layer = tile.layer { RadialMotion.transform(layer, to: CATransform3DIdentity, duration: duration, key: "appearance") }
        }
        if let layer = centerTile.layer { RadialMotion.transform(layer, to: CATransform3DIdentity, duration: duration, key: "appearance") }
    }

    func setAvailability(_ availability: [Bool]) {
        actionAvailability = availability
        for (index, tile) in tiles.enumerated() { tile.setAvailable(availability.indices.contains(index) ? availability[index] : true) }
    }
    func update(focus: RadialFocus, hasLeftCenter: Bool) {
        guard !closing else { return }
        self.currentFocus = focus
        self.hasLeftCenter = hasLeftCenter
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, tile) in tiles.enumerated() {
            tile.setSelected(focus == .action(index), reduceMotion: reduce)
        }
        switch focus {
        case .center:
            if !hasLeftCenter, let index = defaultIndex, items.indices.contains(index) {
                centerTile.setContent(title: "松手执行", symbol: items[index].symbol)
                centerTile.setSelected(true, reduceMotion: reduce)
            } else {
                centerTile.setContent(title: "取消", symbol: "xmark")
                centerTile.setSelected(false, reduceMotion: reduce)
            }
        case .action(let index):
            if actionAvailability.indices.contains(index), !actionAvailability[index] {
                centerTile.setContent(title: "不可用", symbol: "xmark")
                centerTile.setSelected(false, reduceMotion: reduce)
                return
            }
            centerTile.setContent(title: "松手执行", symbol: items.indices.contains(index) ? Self.arrow(for: items[index].direction) : "arrow.up")
            centerTile.setSelected(false, reduceMotion: reduce)
        case .outside:
            centerTile.setContent(title: "取消", symbol: "xmark")
            centerTile.setSelected(false, reduceMotion: reduce)
        }
        needsDisplay = true
    }

    func dismiss(selectedIndex: Int?, completion: @escaping () -> Void) {
        guard !closing else { completion(); return }
        closing = true
        if layer?.presentation() == nil {
            removeFromSuperview()
            completion()
            return
        }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduce ? RadialMotion.reduced : RadialMotion.dismiss
        if let selectedIndex = selectedIndex, tiles.indices.contains(selectedIndex) {
            tiles[selectedIndex].setSelected(true, reduceMotion: reduce)
        }
        if let layer = layer { RadialMotion.opacity(layer, to: 0, duration: duration) }
        for (index, tile) in tiles.enumerated() {
            guard let layer = tile.layer else { continue }
            let transform = reduce ? CATransform3DIdentity : Self.collapsedTransform(offset: Self.offset(for: items[index].direction))
            RadialMotion.transform(layer, to: transform, duration: duration, key: "appearance")
        }
        if let layer = centerTile.layer, !reduce {
            RadialMotion.transform(layer, to: CATransform3DMakeScale(0.97, 0.97, 1), duration: duration, key: "appearance")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.visibilityGeneration == generation else { return }
            self.removeFromSuperview()
            completion()
        }
    }

    func updateInteraction(displacement: CGPoint, compression: CGFloat) {
        guard !closing else { return }
        let radius = hypot(displacement.x, displacement.y)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let pointerUnit = radius > 0.01 ? CGPoint(x: displacement.x / radius, y: displacement.y / radius) : .zero
        let approach = min(1, radius / 110)
        let edgeFade = max(0, min(1, (265 - radius) / 35))
        for (index, tile) in tiles.enumerated() {
            let offset = Self.offset(for: items[index].direction)
            let offsetLength = hypot(offset.x, offset.y)
            let alignment = max(0, (offset.x * pointerUnit.x + offset.y * pointerUnit.y) / offsetLength)
            let amount = reduce ? 0 : 5 * pow(alignment, 4) * approach * edgeFade
            let toward = CGPoint(x: displacement.x - offset.x, y: displacement.y - offset.y)
            let length = hypot(toward.x, toward.y)
            let falloff = hypot(length, 40)
            let attraction = CGPoint(x: toward.x / falloff * amount, y: toward.y / falloff * amount)
            tile.setInteraction(attraction: attraction, compression: 0)
        }
        centerTile.setInteraction(attraction: .zero, compression: max(0, min(1, compression)))
    }

    private static func offset(for direction: RadialDirection) -> CGPoint {
        switch direction {
        case .up: return CGPoint(x: 0, y: 118)
        case .right: return CGPoint(x: 145, y: 0)
        case .down: return CGPoint(x: 0, y: -118)
        case .left: return CGPoint(x: -145, y: 0)
        }
    }

    private static func arrow(for direction: RadialDirection) -> String {
        switch direction {
        case .up: return "arrow.up"
        case .right: return "arrow.right"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        }
    }

    private static func collapsedTransform(offset: CGPoint) -> CATransform3D {
        let translation = CATransform3DMakeTranslation(-offset.x * 0.17, -offset.y * 0.17, 0)
        return CATransform3DScale(translation, 0.97, 0.97, 1)
    }
}
