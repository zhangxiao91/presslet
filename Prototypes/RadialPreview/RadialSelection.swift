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
    let direction: RadialDirection
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
    private let innerRadius: CGFloat
    private let outerRadius: CGFloat
    private let selectionAngle: CGFloat = 48 * .pi / 180
    private let hysteresisAngle: CGFloat = 8 * .pi / 180

    init(center: CGPoint, items: [RadialItem], defaultIndex: Int? = nil,
         innerRadius: CGFloat = 34, outerRadius: CGFloat = 200) {
        self.center = center
        let configuredItems = Array(items.prefix(4))
        self.items = configuredItems
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
        if case .action(let index) = focus,
           items.indices.contains(index),
           angularDistance(angle, items[index].direction.angle)
                <= selectionAngle + hysteresisAngle {
            return focus
        }

        let closest = items.indices.min {
            angularDistance(angle, items[$0].direction.angle)
                < angularDistance(angle, items[$1].direction.angle)
        }
        if let index = closest,
           angularDistance(angle, items[index].direction.angle) <= selectionAngle {
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
