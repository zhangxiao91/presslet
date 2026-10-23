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
    private let dimple = CAGradientLayer()
    private let innerEdge = CAShapeLayer()
    private var pullX = RadialSpring(response: 0.24, dampingRatio: 0.84)
    private var pullY = RadialSpring(response: 0.24, dampingRatio: 0.84)
    private var pressure = RadialSpring(response: 0.22, dampingRatio: 0.62)
    private var emphasis = RadialSpring(response: 0.24, dampingRatio: 0.82)
    private var armed = RadialSpring(value: 1, response: 0.20, dampingRatio: 0.88)
    private var material: NSView?
    private var floatingBackdrop: NSVisualEffectView?
    private let round: Bool
    private var selected = false
    private var available = true
    private var currentSymbol = ""
    private var compression: CGFloat = 0
    private var opaqueMaterial: Bool?
    private var displayObserver: NSObjectProtocol?
    var onPress: (() -> Void)?
    var onNeedsAnimation: (() -> Void)?
    private var cornerRadius: CGFloat { round ? bounds.height / 2 : 17 }

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
        surfaceHost.layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        decoration.layer?.cornerRadius = cornerRadius
        decoration.layer?.masksToBounds = true
        decoration.layer?.cornerCurve = .continuous
        tint.frame = bounds
        decoration.layer?.addSublayer(tint)
        sheen.frame = bounds
        sheen.startPoint = CGPoint(x: 0.25, y: 1)
        sheen.endPoint = CGPoint(x: 0.75, y: 0)
        sheen.locations = [0, 0.35, 1]
        decoration.layer?.addSublayer(sheen)
        if round {
            dimple.type = .radial
            dimple.frame = bounds.insetBy(dx: 5, dy: 5)
            dimple.startPoint = CGPoint(x: 0.50, y: 0.55)
            dimple.endPoint = CGPoint(x: 1, y: 1)
            dimple.locations = [0, 0.42, 0.78, 1]
            let mask = CAShapeLayer()
            mask.path = CGPath(ellipseIn: dimple.bounds, transform: nil)
            dimple.mask = mask
            decoration.layer?.addSublayer(dimple)
            innerEdge.path = CGPath(ellipseIn: bounds.insetBy(dx: 7, dy: 7), transform: nil)
            innerEdge.fillColor = NSColor.clear.cgColor
            innerEdge.lineWidth = 0.75
            decoration.layer?.addSublayer(innerEdge)
        }
        edge.path = CGPath(roundedRect: bounds.insetBy(dx: 0.45, dy: 0.45), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        edge.fillColor = NSColor.clear.cgColor
        edge.lineWidth = 0.65
        decoration.layer?.addSublayer(edge)

        symbolView.wantsLayer = true
        titleLabel.wantsLayer = true
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
            guard let self else { return }
            self.refreshMaterial()
            self.setInteraction(attraction: .zero, compression: self.compression)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMaterial()
    }

    override func accessibilityPerformPress() -> Bool {
        guard available, let onPress else { return false }
        onPress()
        return true
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
        backdrop.layer?.cornerRadius = cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        surfaceHost.addSubview(backdrop, positioned: .below, relativeTo: material)
        floatingBackdrop = backdrop
    }

    func setSelected(_ selected: Bool, reduceMotion: Bool, animate: Bool = true) {
        let selected = selected && available
        guard self.selected != selected else { return }
        self.selected = selected
        emphasis.target = selected ? 1 : 0
        symbolView.contentTintColor = selected ? .controlAccentColor : .labelColor
        titleLabel.textColor = selected ? .controlAccentColor : .labelColor
        titleLabel.font = .systemFont(ofSize: round ? 10 : 12, weight: selected ? .semibold : .medium)
        requestFrame()
    }

    func setCenterArmed(_ value: Bool) {
        armed.target = value ? 1 : 0
        requestFrame()
    }

    func setInteraction(attraction: CGPoint, compression: CGFloat) {
        pullX.target = attraction.x.isFinite ? attraction.x : 0
        pullY.target = attraction.y.isFinite ? attraction.y : 0
        self.compression = compression.isFinite ? max(0, min(1, compression)) : 0
        pressure.target = min(1, self.compression * 1.28)
        requestFrame()
    }

    func releasePressure() {
        compression = 0
        pressure.target = 0
        pullX.target = 0
        pullY.target = 0
        armed.target = 1
        requestFrame()
    }

    @discardableResult
    func advance(by delta: TimeInterval) -> Bool {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            snapMotion()
            renderMaterial()
            return false
        }
        let moving = [pullX.advance(by: delta), pullY.advance(by: delta),
                      pressure.advance(by: delta), emphasis.advance(by: delta), armed.advance(by: delta)]
        renderMaterial()
        return moving.contains(true)
    }

    private func requestFrame() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            snapMotion()
            renderMaterial()
        } else {
            onNeedsAnimation?()
        }
    }

    private func snapMotion() {
        pullX.snap(to: 0); pullY.snap(to: 0)
        pressure.snap(to: compression)
        emphasis.snap(to: selected ? 1 : 0)
        armed.snap(to: armed.target)
    }

    private func renderMaterial() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let focus = max(0, min(1.1, emphasis.value))
        let force = round ? max(-0.12, min(1.12, pressure.value)) : 0
        let contact = round ? force * (0.62 + 0.38 * max(0, min(1, armed.value))) : 0
        let squeeze = reduce ? 0 : contact
        let sx: CGFloat = round ? 1 + squeeze * 0.24 : 1 + focus * 0.04
        let sy: CGFloat = round ? 1 - squeeze * 0.19 : 1 + focus * 0.04
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attractionHost.layer?.transform = reduce ? CATransform3DIdentity : CATransform3DMakeTranslation(pullX.value, pullY.value, 0)
        if let layer = surfaceHost.layer {
            let pivot = CGPoint(x: layer.bounds.width * (0.5 - layer.anchorPoint.x), y: layer.bounds.height * (0.5 - layer.anchorPoint.y))
            layer.transform = reduce ? CATransform3DIdentity : CATransform3DScale(CATransform3DMakeTranslation(pivot.x * (1 - sx), pivot.y * (1 - sy), 0), sx, sy, 1)
            layer.shadowOpacity = round ? Float(0.085 - max(0, contact) * 0.055) : Float(0.07 + focus * 0.045)
            layer.shadowRadius = round ? 10 - max(0, contact) * 5 : 13 + focus * 3
            layer.shadowOffset = CGSize(width: 0, height: round ? -4 + max(0, contact) * 3 : -4 - focus * 2)
        }
        // The material deforms; its label stays optically stable above the dent.
        symbolView.layer?.transform = reduce ? CATransform3DIdentity : CATransform3DMakeTranslation(0, -max(0, contact) * 1.5, 0)
        titleLabel.layer?.transform = reduce ? CATransform3DIdentity : CATransform3DMakeTranslation(0, -max(0, contact) * 0.5, 0)
        updateChrome(contact: max(0, contact), emphasis: focus)
        CATransaction.commit()
    }

    private func updateChrome(contact: CGFloat? = nil, emphasis: CGFloat? = nil) {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let p = contact ?? (round ? max(0, pressure.value) : 0)
        let focus = emphasis ?? max(0, min(1, self.emphasis.value))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.backgroundColor = NSColor.controlAccentColor.withAlphaComponent((opaque ? 0.10 : 0.13) * focus).cgColor
        edge.strokeColor = focus > 0.01 ? NSColor.controlAccentColor.withAlphaComponent(0.20 + 0.28 * focus).cgColor : NSColor.white.withAlphaComponent(0.28 + p * 0.28).cgColor
        sheen.startPoint = CGPoint(x: 0.20 - p * 0.09, y: 1)
        sheen.endPoint = CGPoint(x: 0.80 + p * 0.09, y: 0)
        sheen.colors = [NSColor.white.withAlphaComponent(0.075 + p * 0.16).cgColor, NSColor.white.withAlphaComponent(0.012).cgColor, NSColor.black.withAlphaComponent(0.012 + p * 0.035).cgColor]
        if round {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            dimple.colors = [NSColor.black.withAlphaComponent(p * (dark ? 0.30 : 0.23)).cgColor,
                             NSColor.black.withAlphaComponent(p * 0.045).cgColor,
                             NSColor.white.withAlphaComponent(p * (dark ? 0.12 : 0.25)).cgColor,
                             NSColor.clear.cgColor]
            innerEdge.strokeColor = NSColor.white.withAlphaComponent(p * 0.38).cgColor
            dimple.startPoint = CGPoint(x: 0.50 + pullX.value * 0.012, y: 0.56 + pullY.value * 0.012)
            let insetScale = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 1 - p * 0.23
            let pivot = CGPoint(x: dimple.bounds.width * (0.5 - dimple.anchorPoint.x), y: dimple.bounds.height * (0.5 - dimple.anchorPoint.y))
            dimple.transform = CATransform3DScale(CATransform3DMakeTranslation(pivot.x * (1 - insetScale), pivot.y * (1 - insetScale), 0), insetScale, insetScale, 1)
        }
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
                solid.layer?.cornerRadius = cornerRadius
                solid.layer?.cornerCurve = .continuous
                solid.addSubview(decoration)
                next = solid
            } else if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: bounds)
                glass.style = .clear
                glass.cornerRadius = self.cornerRadius
                glass.tintColor = nil
                glass.contentView = decoration
                next = glass
            } else {
                let effect = NSVisualEffectView(frame: bounds)
                effect.material = .menu
                effect.blendingMode = .withinWindow
                effect.state = .active
                effect.wantsLayer = true
                effect.layer?.cornerRadius = cornerRadius
                effect.layer?.cornerCurve = .continuous
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

private final class RadialFrameTarget: NSObject {
    weak var owner: RadialMenuView?
    init(owner: RadialMenuView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.advanceMotion(link) }
}

/// A passive rendering surface. The host owns pressure, drag and release events.
final class RadialMenuView: NSView {
    static let layoutSize = NSSize(width: 460, height: 330)
    static func layoutSize(for count: Int) -> NSSize {
        let count = max(1, min(9, count))
        let offsets = (0..<count).map { RadialItem.menuOffset(angle: RadialItem.menuAngle(index: $0, count: count), count: count) }
        let horizontal = offsets.map { abs($0.x) }.max() ?? 0
        let vertical = offsets.map { abs($0.y) }.max() ?? 0
        return NSSize(width: max(360, ceil((horizontal + 98) * 2)),
                      height: max(280, ceil((vertical + 54) * 2)))
    }
    static func anchor(for count: Int) -> NSPoint {
        let size = layoutSize(for: count)
        return NSPoint(x: size.width / 2, y: size.height / 2)
    }
    private let anchor: NSPoint
    private let items: [RadialItem]
    private let appName: String
    private let defaultIndex: Int?
    private var tiles: [RadialGlassTile] = []
    private let centerTile: RadialGlassTile
    private var currentFocus = RadialFocus.center
    private var hasLeftCenter = false
    private var closing = false
    private var visibilityGeneration = 0
    private var actionAvailability: [Bool] = []
    private var animationLink: CADisplayLink?
    private lazy var frameTarget = RadialFrameTarget(owner: self)
    private var lastFrameTime: TimeInterval = 0
    var onClick: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    init(items: [RadialItem], appName: String, defaultIndex: Int?) {
        let items = Array(items.prefix(9))
        self.items = items
        anchor = Self.anchor(for: items.count)
        centerTile = RadialGlassTile(frame: NSRect(x: anchor.x - 28, y: anchor.y - 28, width: 56, height: 56), round: true)
        self.appName = appName
        self.defaultIndex = defaultIndex
        super.init(frame: NSRect(origin: .zero, size: Self.layoutSize(for: items.count)))
        wantsLayer = true
        layer?.masksToBounds = false
        for (index, item) in items.enumerated() {
            let offset = RadialItem.menuOffset(angle: item.angle, count: items.count)
            let frame = NSRect(x: anchor.x + offset.x - 71, y: anchor.y + offset.y - 28, width: 142, height: 56)
            let tile = RadialGlassTile(frame: frame)
            tile.setContent(title: item.title, symbol: item.symbol)
            tile.onPress = { [weak self] in
                guard let self, !self.closing else { return }
                self.onClick?(index)
            }
            tile.onNeedsAnimation = { [weak self] in self?.wakeMotion() }
            addSubview(tile)
            tiles.append(tile)
        }
        addSubview(centerTile)
        centerTile.onNeedsAnimation = { [weak self] in self?.wakeMotion() }
        centerTile.onPress = { [weak self] in
            guard let self, !self.closing else { return }
            self.onCancel?()
        }
        update(focus: .center, hasLeftCenter: false)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(appName)动作菜单")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { animationLink?.invalidate() }
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            animationLink?.invalidate()
            animationLink = nil
            lastFrameTime = 0
        } else { wakeMotion() }
    }

    private func wakeMotion() {
        guard window != nil else { return }
        if animationLink == nil {
            let link = displayLink(target: frameTarget, selector: #selector(RadialFrameTarget.tick(_:)))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            animationLink = link
        }
        if animationLink?.isPaused == true {
            lastFrameTime = 0
            animationLink?.isPaused = false
        }
    }

    fileprivate func advanceMotion(_ link: CADisplayLink) {
        let delta = lastFrameTime > 0 ? min(0.06, max(0, link.timestamp - lastFrameTime)) : 1.0 / 60
        lastFrameTime = link.timestamp
        var moving = centerTile.advance(by: delta)
        for tile in tiles { if tile.advance(by: delta) { moving = true } }
        if !moving { link.isPaused = true; lastFrameTime = 0 }
    }

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
        frame.origin = NSPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        if superview !== host { host.addSubview(self) }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduce ? RadialMotion.reduced : RadialMotion.reveal
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = 0
        for (index, tile) in tiles.enumerated() {
            let offset = RadialItem.menuOffset(angle: items[index].angle, count: items.count)
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
        update(focus: currentFocus, hasLeftCenter: hasLeftCenter)
    }
    func update(focus: RadialFocus, hasLeftCenter: Bool) {
        guard !closing else { return }
        self.currentFocus = focus
        self.hasLeftCenter = hasLeftCenter
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, tile) in tiles.enumerated() {
            tile.setSelected(focus == .action(index), reduceMotion: reduce)
        }
        centerTile.setCenterArmed(focus == .center)
        if !hasLeftCenter, focus == .center, let index = defaultIndex, items.indices.contains(index),
           !actionAvailability.indices.contains(index) || actionAvailability[index] {
            centerTile.setContent(title: "松手执行", symbol: items[index].symbol)
            centerTile.setSelected(true, reduceMotion: reduce)
        } else {
            // Keep the central escape target stable while the action tiles carry intent.
            centerTile.setContent(title: "取消", symbol: "xmark")
            centerTile.setSelected(false, reduceMotion: reduce)
        }
        wakeMotion()
        needsDisplay = true
    }

    func dismiss(selectedIndex: Int?, released: Bool = false, completion: @escaping () -> Void) {
        guard !closing else { completion(); return }
        closing = true
        if released { centerTile.releasePressure(); wakeMotion() }
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
            let transform = reduce ? CATransform3DIdentity : Self.collapsedTransform(offset: RadialItem.menuOffset(angle: items[index].angle, count: items.count))
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
        guard !closing, displacement.x.isFinite, displacement.y.isFinite else { return }
        let radius = hypot(displacement.x, displacement.y)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let pointerUnit = radius > 0.01 ? CGPoint(x: displacement.x / radius, y: displacement.y / radius) : .zero
        let approach = min(1, radius / 76)
        let edgeFade = max(0, min(1, (RadialItem.menuOuterRadius(count: items.count) - radius) / 40))
        for (index, tile) in tiles.enumerated() {
            let offset = RadialItem.menuOffset(angle: items[index].angle, count: items.count)
            let offsetLength = max(1, hypot(offset.x, offset.y))
            let alignment = max(0, (offset.x * pointerUnit.x + offset.y * pointerUnit.y) / offsetLength)
            let amount = reduce ? 0 : 8 * pow(alignment, 4) * approach * edgeFade
            let toward = CGPoint(x: displacement.x - offset.x, y: displacement.y - offset.y)
            let length = hypot(toward.x, toward.y)
            let falloff = hypot(length, 34)
            let attraction = CGPoint(x: toward.x / falloff * amount, y: toward.y / falloff * amount)
            tile.setInteraction(attraction: attraction, compression: 0)
        }
        let resistance = 1 + radius / 24
        let centerPull = reduce ? CGPoint.zero : CGPoint(x: displacement.x / resistance * 0.12,
                                                        y: displacement.y / resistance * 0.12)
        centerTile.setInteraction(attraction: centerPull, compression: compression)
        wakeMotion()
    }

    private static func collapsedTransform(offset: CGPoint) -> CATransform3D {
        let translation = CATransform3DMakeTranslation(-offset.x * 0.17, -offset.y * 0.17, 0)
        return CATransform3DScale(translation, 0.97, 0.97, 1)
    }
}
