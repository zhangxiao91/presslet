import Foundation
import CoreGraphics

@main
struct PressDragEventRouterTestRunner {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    // Events remain in memory. These tests check callback output, not delivery
    // to an application or WindowServer's physical button state.
    static func event(_ type: CGEventType, _ point: CGPoint, pid: Int32 = 200,
                      window: Int64 = 0, receiverWindow: Int64 = 0) -> CGEvent {
        let value = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)!
        value.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        value.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: window)
        value.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: receiverWindow)
        value.timestamp = 123_456_789
        value.flags = [.maskShift, .maskCommand]
        value.setIntegerValueField(.mouseEventClickState, value: 2)
        value.setIntegerValueField(.mouseEventNumber, value: 37)
        value.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        value.setIntegerValueField(.mouseEventDeltaX, value: 17)
        value.setIntegerValueField(.mouseEventDeltaY, value: -9)
        value.setIntegerValueField(.eventSourceUserData, value: 0x1234)
        value.setIntegerValueField(.eventSourceUnixProcessID, value: 456)
        return value
    }

    static func preservesIdentity(_ value: CGEvent, from original: CGEvent) {
        expect(value.timestamp == original.timestamp, "Physical event timestamp is preserved")
        expect(value.flags == original.flags, "Physical event modifiers are preserved")
        for field: CGEventField in [.mouseEventClickState, .mouseEventNumber, .mouseEventButtonNumber,
                                   .eventTargetUnixProcessID, .eventSourceUnixProcessID, .eventSourceUserData,
                                   .mouseEventWindowUnderMousePointer,
                                   .mouseEventWindowUnderMousePointerThatCanHandleThisEvent] {
            expect(value.getIntegerValueField(field) == original.getIntegerValueField(field),
                   "Native event metadata \(field.rawValue) is preserved")
        }
        expect(value.type == original.type, "Physical event type is preserved")
    }

    static func main() {
        let start = CGPoint(x: 100, y: 120)
        let prePress = CGPoint(x: 105, y: 122)
        let menuPoint = CGPoint(x: 250, y: 270)

        var normal = PressDragEventRouter()
        expect(!normal.isActive && !normal.begin(targetPID: 200), "An unobserved down cannot be isolated")
        for (type, point) in [(CGEventType.leftMouseDown, start), (.leftMouseDragged, prePress),
                              (.leftMouseUp, menuPoint), (.mouseMoved, menuPoint)] {
            let physical = event(type, point)
            let original = physical.copy()!
            let result = normal.route(type: type, event: physical, frontmostPID: 200)
            expect(!result.suppress && !result.pairedMouseUp && !result.endedIsolation,
                   "Ordinary \(type.rawValue) passes without isolation side effects")
            expect(physical.location == point && result.observed?.location == point,
                   "Ordinary event and observation retain their positions")
            expect(physical.getIntegerValueField(.mouseEventDeltaX) == 17 &&
                   physical.getIntegerValueField(.mouseEventDeltaY) == -9, "Ordinary deltas remain unchanged")
            preservesIdentity(physical, from: original)
        }
        expect(!normal.begin(targetPID: 200), "Ordinary release clears the observed down")

        var router = PressDragEventRouter()
        _ = router.route(type: .leftMouseDown, event: event(.leftMouseDown, start), frontmostPID: 200)
        _ = router.route(type: .leftMouseDragged, event: event(.leftMouseDragged, prePress), frontmostPID: 200)
        expect(!router.begin(targetPID: 300), "A different source cannot claim the observed down")
        expect(router.begin(targetPID: 200) && router.isActive, "Deep pressure claims its matching sequence")
        expect(!router.begin(targetPID: 200), "Repeated pressure cannot restart isolation")
        let isolatedDrag = event(.leftMouseDragged, menuPoint)
        let dragResult = router.route(type: .leftMouseDragged, event: isolatedDrag, frontmostPID: 200)
        expect(dragResult.suppress && !dragResult.pairedMouseUp, "Captured drag is suppressed without producing a release")
        expect(isolatedDrag.location == menuPoint && dragResult.observed?.location == menuPoint,
               "Menu drag sample preserves physical coordinates")
        let physicalUp = event(.leftMouseUp, menuPoint, window: 40, receiverWindow: 41)
        let originalUp = physicalUp.copy()!
        let result = router.route(type: .leftMouseUp, event: physicalUp, frontmostPID: 200)
        expect(!result.suppress && result.pairedMouseUp && result.endedIsolation && !router.isActive,
               "The single physical release remains in the native stream and ends isolation")
        expect(physicalUp.location == prePress, "Release uses the last position passed before takeover")
        expect(result.observed?.location == menuPoint, "Menu observes the real release location")
        expect(physicalUp.getIntegerValueField(.mouseEventDeltaX) == 0 &&
               physicalUp.getIntegerValueField(.mouseEventDeltaY) == 0, "Safe release carries zero movement deltas")
        expect(result.observed?.getIntegerValueField(.mouseEventDeltaX) == 17 &&
               result.observed?.getIntegerValueField(.mouseEventDeltaY) == -9, "Menu snapshot retains physical deltas")
        preservesIdentity(physicalUp, from: originalUp)
        preservesIdentity(result.observed!, from: originalUp)
        physicalUp.location = CGPoint(x: 999, y: 999)
        physicalUp.setIntegerValueField(.mouseEventNumber, value: 500)
        expect(result.observed?.location == menuPoint && result.observed?.getIntegerValueField(.mouseEventNumber) == 37,
               "Later mutation cannot change the independently copied menu sample")
        let repeatedUp = event(.leftMouseUp, menuPoint)
        let repeated = router.route(type: .leftMouseUp, event: repeatedUp, frontmostPID: 300)
        expect(!repeated.pairedMouseUp && !repeated.suppress && !repeated.endedIsolation,
               "An extra release is passed normally without pairing another sequence")
        expect(repeatedUp.location == menuPoint, "Extra release is not relocated")

        // Foreground changes must not rewrite native targeting metadata. The
        // operating system retains responsibility for pairing native down/up.
        for (foreground, target) in [(Int32(300), Int32(300)), (300, 200), (200, 300), (300, 0)] {
            var switched = PressDragEventRouter()
            _ = switched.route(type: .leftMouseDown,
                               event: event(.leftMouseDown, start, window: 10, receiverWindow: 11), frontmostPID: 200)
            expect(switched.begin(targetPID: 200), "Source-switch scenario enters isolation")
            let drag = switched.route(type: .leftMouseDragged,
                event: event(.leftMouseDragged, menuPoint, pid: target, window: 30, receiverWindow: 31), frontmostPID: foreground)
            expect(drag.suppress, "Source switch does not release captured dragging")
            let up = event(.leftMouseUp, menuPoint, pid: target, window: 40, receiverWindow: 41)
            let original = up.copy()!
            let release = switched.route(type: .leftMouseUp, event: up, frontmostPID: foreground)
            expect(!release.suppress && release.pairedMouseUp && release.endedIsolation && !switched.isActive,
                   "Source-switch release remains native and clears isolation")
            expect(up.location == start && release.observed?.location == menuPoint,
                   "Native release uses safe coordinates while menu keeps physical coordinates")
            preservesIdentity(up, from: original)
            preservesIdentity(release.observed!, from: original)
            let second = switched.route(type: .leftMouseUp, event: event(.leftMouseUp, menuPoint, pid: target), frontmostPID: foreground)
            expect(!second.pairedMouseUp && !second.suppress, "Source switch still pairs only one physical release")
        }

        var fallback = PressDragEventRouter()
        _ = fallback.route(type: .leftMouseDown, event: event(.leftMouseDown, start, pid: 0), frontmostPID: 200)
        expect(fallback.begin(targetPID: 200), "A missing down target uses the cached foreground app for eligibility")
        let fallbackUp = event(.leftMouseUp, menuPoint, pid: 0)
        let fallbackResult = fallback.route(type: .leftMouseUp, event: fallbackUp, frontmostPID: 300)
        expect(!fallbackResult.suppress && fallbackResult.pairedMouseUp && fallbackUp.location == start,
               "Missing-target release remains native at the safe point")
        expect(fallbackUp.getIntegerValueField(.eventTargetUnixProcessID) == 0, "Missing native target is not invented")
        var missing = PressDragEventRouter()
        _ = missing.route(type: .leftMouseDown, event: event(.leftMouseDown, start, pid: 0), frontmostPID: 0)
        expect(!missing.begin(targetPID: 200), "Unknown down source cannot be isolated")

        var recovery = PressDragEventRouter()
        _ = recovery.route(type: .leftMouseDown, event: event(.leftMouseDown, start), frontmostPID: 200)
        expect(recovery.begin(targetPID: 200), "Recovery scenario enters isolation")
        let newStart = CGPoint(x: 700, y: 710)
        let fresh = recovery.route(type: .leftMouseDown, event: event(.leftMouseDown, newStart, pid: 300), frontmostPID: 300)
        expect(fresh.endedIsolation && !fresh.suppress && !fresh.pairedMouseUp && !recovery.isActive,
               "Fresh physical down recovers a missed-release sequence without inventing an up")
        expect(!recovery.begin(targetPID: 200) && recovery.begin(targetPID: 300), "Fresh down replaces source eligibility")
        let recoveryUp = event(.leftMouseUp, menuPoint, pid: 300)
        let recoveryResult = recovery.route(type: .leftMouseUp, event: recoveryUp, frontmostPID: 300)
        expect(!recoveryResult.suppress && recoveryResult.pairedMouseUp && recoveryUp.location == newStart,
               "Recovered sequence leaves its physical release native at its own safe point")

        let freeMove = event(.mouseMoved, menuPoint, pid: 300)
        let moveResult = recovery.route(type: .mouseMoved, event: freeMove, frontmostPID: 300)
        expect(!moveResult.suppress && !moveResult.pairedMouseUp && freeMove.location == menuPoint,
               "Pointer movement after release is untouched")
        let nextDown = event(.leftMouseDown, newStart, pid: 300)
        let nextDrag = event(.leftMouseDragged, menuPoint, pid: 300)
        let nextUp = event(.leftMouseUp, menuPoint, pid: 300)
        for physical in [nextDown, nextDrag, nextUp] {
            let ordinary = recovery.route(type: physical.type, event: physical, frontmostPID: 300)
            expect(!ordinary.suppress && !ordinary.pairedMouseUp, "Next ordinary selection sequence passes normally")
        }
        expect(nextDrag.location == menuPoint && nextUp.location == menuPoint,
               "Subsequent ordinary drag and release keep physical coordinates")
        print("PressDragEventRouter: \(assertions) assertions passed")
    }
}
