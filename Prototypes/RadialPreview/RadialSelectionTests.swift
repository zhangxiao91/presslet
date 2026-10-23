import Foundation

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
        print("PASS: \(assertions) radial selection assertions")
    }
}
