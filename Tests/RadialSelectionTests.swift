import Foundation
import CoreGraphics

@main
struct RadialSelectionTestRunner {
    static var assertions = 0
    static let center = CGPoint(x: 240, y: 180)
    static let items = RadialDirection.allCases.map {
        RadialItem(id: $0.rawValue, title: $0.rawValue, symbol: "circle", direction: $0)
    }

    static func expect(_ condition: @autoclosure () -> Bool,
                       _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    static func point(_ degrees: CGFloat, radius: CGFloat = 100) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(x: center.x + cos(angle) * radius,
                       y: center.y + sin(angle) * radius)
    }

    static func main() {
        for (index, angle) in [CGFloat(90), 0, -90, 180].enumerated() {
            var selection = RadialSelection(center: center, items: items)
            expect(selection.isActive && selection.focus == .center,
                   "A new gesture starts active in the center")
            expect(selection.update(point(angle)) == .action(index),
                   "Each cardinal direction selects its configured action")
            expect(selection.hasLeftCenter, "Moving to an action leaves the center")
            expect(selection.release() == index, "Release executes the focused action")
            expect(!selection.isActive, "Release ends the gesture")
            expect(selection.focus == .action(index), "Release retains focus for the exit animation")
            expect(selection.release() == nil, "A gesture executes only once")
            expect(selection.update(center) == .action(index), "Ended gestures retain their focus")
        }

        let threeItems = items.filter { $0.direction != .down }
        var three = RadialSelection(center: center, items: threeItems)
        expect(three.update(point(-90)) == .outside, "The unassigned bottom direction cancels")
        expect(three.release() == nil, "An unassigned direction cannot execute")
        for (index, angle) in [CGFloat(90), 0, 180].enumerated() {
            var selection = RadialSelection(center: center, items: threeItems)
            expect(selection.update(point(angle)) == .action(index),
                   "Three-action layouts retain their item indices")
        }

        var edge = RadialSelection(center: center, items: items)
        expect(edge.update(CGPoint(x: center.x + 34, y: center.y)) == .center,
               "The inner boundary belongs to the center")
        expect(edge.update(CGPoint(x: center.x + 200, y: center.y)) == .action(1),
               "The outer boundary remains selectable")
        expect(edge.update(CGPoint(x: center.x + 201, y: center.y)) == .outside,
               "Crossing the outer boundary immediately clears an action")
        expect(edge.release() == nil, "Releasing outside cancels")

        var neutral = RadialSelection(center: center, items: items)
        expect(neutral.release() == nil, "The center cancels without a configured default")
        var defaultAction = RadialSelection(center: center, items: items, defaultIndex: 2)
        expect(defaultAction.update(point(0, radius: 20)) == .center,
               "Small movement stays in the center")
        expect(defaultAction.release() == 2, "A configured default executes on a stationary release")
        var returnToCenter = RadialSelection(center: center, items: items, defaultIndex: 2)
        returnToCenter.update(point(0))
        expect(returnToCenter.update(center) == .center, "Returning to the center clears focus")
        expect(returnToCenter.hasLeftCenter, "Returning does not erase gesture history")
        expect(returnToCenter.release() == nil, "Returning to the center always cancels")
        var returnFromOutside = RadialSelection(center: center, items: items, defaultIndex: 2)
        returnFromOutside.update(point(0, radius: 250))
        returnFromOutside.update(center)
        expect(returnFromOutside.release() == nil, "Returning from outside also cancels the default")
        for invalid in [-1, 4, 100] {
            var selection = RadialSelection(center: center, items: items, defaultIndex: invalid)
            expect(selection.release() == nil, "Invalid defaults are ignored")
        }

        var hysteresis = RadialSelection(center: center, items: items)
        expect(hysteresis.update(point(0)) == .action(1), "Right is selected initially")
        expect(hysteresis.update(point(47)) == .action(1), "Crossing a shared edge retains the selection")
        expect(hysteresis.update(point(55)) == .action(1), "The eight-degree extension prevents flicker")
        expect(hysteresis.update(point(57)) == .action(0), "A decisive move selects the next action")
        expect(hysteresis.update(point(42)) == .action(0), "Hysteresis works in the reverse direction")
        expect(hysteresis.update(point(33)) == .action(1), "A decisive reverse move switches back")
        expect(hysteresis.update(center) == .center, "The center overrides angular hysteresis")
        expect(hysteresis.update(point(90)) == .action(0), "Selection resumes after leaving the center")
        expect(hysteresis.update(point(90, radius: 210)) == .outside,
               "The outer boundary overrides angular hysteresis")

        var missing = RadialSelection(center: center, items: threeItems)
        expect(missing.update(point(-49)) == .outside, "An unassigned wedge is outside the selection angle")
        expect(missing.update(point(-47)) == .action(1), "The configured wedge accepts points within 48 degrees")
        expect(missing.update(point(-55)) == .action(1), "Hysteresis also works beside an unassigned wedge")
        expect(missing.update(point(-57)) == .outside, "Moving far enough into an unassigned wedge cancels")

        var cancelled = RadialSelection(center: center, items: items, defaultIndex: 0)
        cancelled.update(point(90))
        cancelled.cancel()
        expect(!cancelled.isActive && cancelled.focus == .outside, "Cancel ends and clears the selection")
        expect(cancelled.release() == nil, "Cancel prevents execution")
        cancelled.cancel()
        expect(cancelled.release() == nil, "Repeated cancellation is harmless")

        for invalidPoint in [CGPoint(x: CGFloat.nan, y: 0),
                             CGPoint(x: 0, y: CGFloat.infinity),
                             CGPoint(x: -CGFloat.infinity, y: 0)] {
            var selection = RadialSelection(center: center, items: items, defaultIndex: 0)
            expect(selection.update(invalidPoint) == .outside, "Nonfinite points cancel safely")
            selection.update(center)
            expect(selection.release() == nil, "An invalid point cannot fall back to the default")
        }
        var noItems = RadialSelection(center: center, items: [])
        expect(noItems.update(point(0)) == .outside, "An empty menu has no selectable direction")
        expect(noItems.release() == nil, "An empty menu cannot execute")
        for count in 1...9 {
            let ringItems = (0..<count).map { index in
                RadialItem(id: "action-\(index)", title: "Action \(index)", symbol: "circle",
                           angle: RadialItem.menuAngle(index: index, count: count))
            }
            for index in ringItems.indices {
                let offset = RadialItem.menuOffset(angle: ringItems[index].angle, count: count)
                let target = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
                var selection = RadialSelection(center: center, items: ringItems, outerRadius: 310)
                expect(selection.update(target) == .action(index), "Every displayed action is selected along its actual placement ray")
                expect(selection.release() == index, "All nine configured action indices remain executable")
                expect(selection.release() == nil, "Ring releases execute once")
                let measured = atan2(offset.y, offset.x)
                let error = abs(atan2(sin(measured - ringItems[index].angle), cos(measured - ringItems[index].angle)))
                expect(error < 0.00001, "Rendered and selected angles agree")
            }
            if count >= 4 {
                for angle in stride(from: CGFloat(-180), to: 180, by: 3) {
                    var selection = RadialSelection(center: center, items: ringItems, outerRadius: 310)
                    if case .action(let index) = selection.update(point(angle)) {
                        expect(ringItems.indices.contains(index), "Every ring sector refers to a configured action")
                    } else { expect(false, "Expanded rings leave no unreachable gaps between actions") }
                }
                let rects = ringItems.map { item -> CGRect in
                    let offset = RadialItem.menuOffset(angle: item.angle, count: count)
                    return CGRect(x: offset.x - 71, y: offset.y - 28, width: 142, height: 56)
                }
                for first in rects.indices {
                    for second in rects.indices where second > first {
                        expect(!rects[first].intersects(rects[second]), "Expanded action capsules never overlap")
                    }
                }
                var back = RadialSelection(center: center, items: ringItems, defaultIndex: count - 1, outerRadius: 310)
                back.update(point(90))
                expect(back.update(center) == .center, "Returning from an expanded ring clears focus")
                expect(back.release() == nil, "Returning to center cancels an expanded menu default")
                var outside = RadialSelection(center: center, items: ringItems, outerRadius: 310)
                expect(outside.update(point(90, radius: 311)) == .outside, "Expanded rings retain their outer cancellation boundary")
                expect(outside.release() == nil, "No ring action executes beyond the outer boundary")
                // The midpoint uses the actual ellipse angles rather than nominal equal wedges.
                let first = ringItems[0].angle, second = ringItems[1].angle
                let midpoint = (first + second) / 2
                var stable = RadialSelection(center: center, items: ringItems, outerRadius: 310)
                expect(stable.update(point(first * 180 / .pi)) == .action(0), "A ring starts on its upper action")
                expect(stable.update(point((midpoint - 7 * .pi / 180) * 180 / .pi)) == .action(0), "A small move over a ring boundary does not flicker")
                expect(stable.update(point((midpoint - 9 * .pi / 180) * 180 / .pi)) == .action(1), "A deliberate move crosses the ring boundary")
            } else {
                var bottom = RadialSelection(center: center, items: ringItems)
                expect(bottom.update(point(-90)) == .outside, "Small menus retain their open bottom cancellation direction")
            }
        }
        let tooManyItems = (0..<12).map { index in
            RadialItem(id: "\(index)", title: "\(index)", symbol: "circle",
                       angle: RadialItem.menuAngle(index: index, count: 9))
        }
        var bounded = RadialSelection(center: center, items: tooManyItems, defaultIndex: 9)
        expect(bounded.release() == nil, "Action indices above the nine-action configuration limit are ignored")
        expect(RadialItem(id: "invalid", title: "invalid", symbol: "circle", angle: .nan).angle.isFinite,
               "An invalid custom angle is normalized safely")
        expect(RadialItem.menuOffset(angle: .infinity, count: 9) == CGPoint(x: 0, y: 0),
               "An invalid render angle does not produce a nonfinite position")
        print("PASS: \(assertions) radial selection assertions")
    }
}
