import Foundation

enum RadialDirection: String, CaseIterable {
    case up, right, down, left

    fileprivate var angle: CGFloat {
        switch self {
        case .up: return .pi / 2
        case .right: return 0
        case .down: return -.pi / 2
        case .left: return .pi
        }
    }
}

struct RadialItem {
    let id: String
    let title: String
    let symbol: String
    let direction: RadialDirection?
    let angle: CGFloat

    init(id: String, title: String, symbol: String, direction: RadialDirection) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.direction = direction
        self.angle = direction.angle
    }

    init(id: String, title: String, symbol: String, angle: CGFloat) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.direction = nil
        self.angle = angle.isFinite ? angle : .pi / 2
    }

    static func menuAngle(index: Int, count: Int) -> CGFloat {
        guard count > 3 else {
            return [CGFloat.pi / 2, .pi, 0][max(0, min(2, index))]
        }
        let count = max(4, min(9, count))
        let radii = menuRadii(count: count)
        let angle = CGFloat.pi / 2 - CGFloat(index) * 2 * .pi / CGFloat(count)
        return atan2(sin(angle) * radii.y, cos(angle) * radii.x)
    }

    static func menuOffset(angle: CGFloat, count: Int) -> CGPoint {
        guard angle.isFinite else { return CGPoint(x: 0, y: 0) }
        let radii = menuRadii(count: count)
        if count <= 3 {
            return CGPoint(x: cos(angle) * radii.x, y: sin(angle) * radii.y)
        }
        // Use the same ray for placement and selection even though the ring is elliptical.
        let x = cos(angle), y = sin(angle)
        let radius = 1 / sqrt(x * x / (radii.x * radii.x) + y * y / (radii.y * radii.y))
        return CGPoint(x: x * radius, y: y * radius)
    }

    static func menuOuterRadius(count: Int) -> CGFloat {
        guard count > 3 else { return 230 }
        let count = min(9, count)
        let furthestCenter = (0..<count).map { index -> CGFloat in
            let offset = menuOffset(angle: menuAngle(index: index, count: count), count: count)
            return hypot(offset.x, offset.y)
        }.max() ?? 0
        return max(230, furthestCenter + 90)
    }

    private static func menuRadii(count: Int) -> CGPoint {
        // Sparse menus stay within a short thumb movement. Denser rings reserve
        // space for 142 × 56 cards, their selected scale and magnetic movement.
        switch count {
        case ...4: return CGPoint(x: 120, y: 92)
        case 5: return CGPoint(x: 146, y: 112)
        case 6: return CGPoint(x: 196, y: 96)
        case 7: return CGPoint(x: 216, y: 114)
        case 8: return CGPoint(x: 238, y: 110)
        default: return CGPoint(x: 260, y: 176)
        }
    }
}

enum RadialFocus: Equatable {
    case center
    case action(Int)
    case outside
}

struct RadialSelection {
    private(set) var isActive = true
    private(set) var focus: RadialFocus = .center
    private(set) var hasLeftCenter = false

    private let center: CGPoint
    private let items: [RadialItem]
    private let defaultIndex: Int?
    private let isRing: Bool
    private let innerRadius: CGFloat
    private let outerRadius: CGFloat
    private let selectionAngle: CGFloat = 48 * .pi / 180
    private let hysteresisAngle: CGFloat = 8 * .pi / 180

    init(center: CGPoint, items: [RadialItem], defaultIndex: Int? = nil,
         innerRadius: CGFloat = 34, outerRadius: CGFloat = 200) {
        self.center = center
        let configuredItems = Array(items.prefix(9))
        self.items = configuredItems
        self.isRing = configuredItems.count >= 4 && configuredItems.contains { $0.direction == nil }
        self.defaultIndex = defaultIndex.flatMap {
            configuredItems.indices.contains($0) ? $0 : nil
        }
        self.innerRadius = innerRadius.isFinite ? max(0, innerRadius) : 34
        self.outerRadius = outerRadius.isFinite
            ? max(self.innerRadius, outerRadius) : max(self.innerRadius, 200)
    }

    @discardableResult
    mutating func update(_ point: CGPoint) -> RadialFocus {
        guard isActive else { return focus }
        guard center.x.isFinite, center.y.isFinite,
              point.x.isFinite, point.y.isFinite else {
            hasLeftCenter = true
            focus = .outside
            return focus
        }

        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance.isFinite else {
            hasLeftCenter = true
            focus = .outside
            return focus
        }
        if distance <= innerRadius {
            focus = .center
            return focus
        }
        hasLeftCenter = true
        guard distance <= outerRadius else {
            focus = .outside
            return focus
        }

        let angle = atan2(dy, dx)
        let closest = items.indices.min {
            angularDistance(angle, items[$0].angle)
                < angularDistance(angle, items[$1].angle)
        }
        if case .action(let index) = focus,
           items.indices.contains(index) {
            let currentDistance = angularDistance(angle, items[index].angle)
            if isRing, let closest {
                if currentDistance <= angularDistance(angle, items[closest].angle) + hysteresisAngle * 2 {
                    return focus
                }
            } else if currentDistance <= selectionAngle + hysteresisAngle {
                return focus
            }
        }
        if let index = closest,
           isRing || angularDistance(angle, items[index].angle) <= selectionAngle {
            focus = .action(index)
        } else {
            focus = .outside
        }
        return focus
    }

    mutating func release() -> Int? {
        guard isActive else { return nil }
        isActive = false
        switch focus {
        case .action(let index): return index
        case .center: return hasLeftCenter ? nil : defaultIndex
        case .outside: return nil
        }
    }

    mutating func cancel() {
        isActive = false
        focus = .outside
    }

    private func angularDistance(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        abs(atan2(sin(first - second), cos(first - second)))
    }
}
