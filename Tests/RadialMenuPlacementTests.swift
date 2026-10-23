import Foundation
import CoreGraphics

@main
struct RadialMenuPlacementTests {
    static func main() {
        var assertions = 0
        func expect(_ condition: Bool) {
            assertions += 1
            precondition(condition, "Menu placement assertion \(assertions) failed")
        }
        for screen in [CGRect(x: 0, y: 24, width: 1440, height: 876), CGRect(x: -1920, y: -200, width: 1920, height: 1080)] {
            for size in [CGSize(width: 480, height: 406), CGSize(width: 660, height: 526)] {
                let anchor = CGPoint(x: size.width / 2, y: (size.height - 76) / 2)
                for trigger in [CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.maxX, y: screen.minY),
                                CGPoint(x: screen.minX, y: screen.maxY), CGPoint(x: screen.maxX, y: screen.maxY),
                                CGPoint(x: screen.midX, y: screen.midY)] {
                    let placed = RadialMenuPlacement(trigger: trigger, panelSize: size, anchor: anchor, visibleFrame: screen)
                    expect(screen.insetBy(dx: 8, dy: 8).contains(placed.frame))
                    expect(placed.center.x == placed.frame.minX + anchor.x)
                    expect(placed.center.y == placed.frame.minY + anchor.y)
                }
                let middle = CGPoint(x: screen.midX, y: screen.midY)
                let placed = RadialMenuPlacement(trigger: middle, panelSize: size, anchor: anchor, visibleFrame: screen)
                expect(placed.center == middle)
            }
        }
        print("PASS: \(assertions) menu placement assertions")
    }
}
