import Foundation
import CoreGraphics

/// Keeps the entire menu on its display while preserving one shared visual and
/// selection center. The presenter separately retains the physical press point.
struct RadialMenuPlacement {
    let frame: CGRect
    let center: CGPoint

    init(trigger: CGPoint, panelSize: CGSize, anchor: CGPoint, visibleFrame: CGRect) {
        let available = visibleFrame.insetBy(dx: 8, dy: 8)
        func origin(_ proposed: CGFloat, minimum: CGFloat, maximum: CGFloat, length: CGFloat) -> CGFloat {
            guard length <= maximum - minimum else { return minimum + (maximum - minimum - length) / 2 }
            return min(maximum - length, max(minimum, proposed))
        }
        let x = origin(trigger.x - anchor.x, minimum: available.minX, maximum: available.maxX, length: panelSize.width)
        let y = origin(trigger.y - anchor.y, minimum: available.minY, maximum: available.maxY, length: panelSize.height)
        frame = CGRect(origin: CGPoint(x: x, y: y), size: panelSize)
        center = CGPoint(x: x + anchor.x, y: y + anchor.y)
    }
}
