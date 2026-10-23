import Foundation

@main
struct PressureInputManagerTestRunner {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    static func policy() -> PressureInputPolicy {
        PressureInputPolicy(ownPID: 100, frontmostPID: 200, interceptedPIDs: [200])
    }

    static func main() {
        var p = policy()
        var filter = PressureInputFilter()
        filter.mouseDown(policy: p)
        let light = filter.pressure(stage: 1, targetPID: 200, policy: p, canFilter: true)
        expect(light.eligibleInput && !light.shouldBlock, "Light pressure is observed and passed through")
        let deep = filter.pressure(stage: 2, targetPID: 200, policy: p, canFilter: true)
        expect(deep.eligibleInput && deep.shouldBlock, "An intercepted application's first deep stage is blocked")
        expect(filter.stats.blockedPresses == 1 && filter.stats.blockedPressureEvents == 1, "First interception is counted once")

        p.menuVisible = true
        for _ in 0..<40 {
            let continuation = filter.pressure(stage: 2, targetPID: 100, policy: p, canFilter: true)
            expect(!continuation.eligibleInput && continuation.shouldBlock, "Showing our menu cannot release an already intercepted deep stage")
        }
        expect(filter.stats.blockedPresses == 1, "Repeated stage 2 has one intercepted press")
        expect(filter.stats.blockedPressureEvents == 41, "Every intercepted sample remains countable")
        expect(!filter.pressure(stage: 1, targetPID: 200, policy: p, canFilter: true).shouldBlock, "Returning to light pressure is passed through")
        expect(!filter.pressure(stage: 0, targetPID: 200, policy: p, canFilter: true).shouldBlock, "Pressure end is never blocked")
        filter.mouseUp()
        expect(!filter.blockedThisPress && !filter.suppressGestureUntilUp, "Physical release clears both press flags")
        expect(!filter.pressure(stage: 2, targetPID: 100, policy: p, canFilter: true).shouldBlock, "Interception cannot persist after physical release")

        filter.mouseDown(policy: p)
        expect(filter.suppressGestureUntilUp, "Clicking an open menu suppresses recognition for the whole click")
        p.menuVisible = false
        expect(!filter.pressure(stage: 2, targetPID: 200, policy: p, canFilter: true).eligibleInput, "Closing the menu during that click cannot rearm it")
        filter.mouseUp()
        filter.mouseDown(policy: p)
        expect(filter.pressure(stage: 2, targetPID: 200, policy: p, canFilter: true).shouldBlock, "A fresh physical press can rearm interception")

        var paused = p
        paused.paused = true
        expect(filter.pressure(stage: 2, targetPID: 200, policy: paused, canFilter: true) == .init(), "Pause passes pressure through without delivery eligibility")
        var disabled = p
        disabled.enabled = false
        expect(filter.pressure(stage: 2, targetPID: 200, policy: disabled, canFilter: true) == .init(), "Disabled input never consumes pressure")
        disabled = p; disabled.gestureEnabled = false
        expect(filter.pressure(stage: 2, targetPID: 200, policy: disabled, canFilter: true) == .init(), "Disabling gesture capture passes pressure through")
        expect(!filter.pressure(stage: 2, targetPID: 200, policy: p, canFilter: false).shouldBlock, "A passive listener never claims to block")
        var noMenu = p; noMenu.autoMenu = false
        expect(!filter.pressure(stage: 2, targetPID: 200, policy: noMenu, canFilter: true).shouldBlock, "Turning automatic menus off also stops interception")

        filter.cancelUntilNextDown()
        expect(!filter.blockedThisPress && !filter.suppressGestureUntilUp && filter.awaitingFreshDown, "Tap-disabled cancellation immediately clears the old press")
        for stage in [2, 1, 0, 2] {
            expect(filter.pressure(stage: stage, targetPID: 200, policy: p, canFilter: true) == .init(), "After tap-disabled, pressure is ignored until new down")
        }
        filter.mouseUp()
        expect(filter.awaitingFreshDown, "Release alone cannot rearm after an interruption")
        filter.mouseDown(policy: p)
        expect(!filter.awaitingFreshDown, "A new down rearms after an interruption")
        expect(filter.pressure(stage: 2, targetPID: 200, policy: p, canFilter: true).shouldBlock, "New press after interruption can be intercepted")

        filter.mouseUp(); filter.mouseDown(policy: p)
        expect(!filter.pressure(stage: 2, targetPID: 300, policy: p, canFilter: true).shouldBlock, "Unselected application keeps system behavior")
        expect(filter.pressure(stage: 2, targetPID: 300, policy: p, canFilter: true).eligibleInput, "Unselected application may still supply menu input")
        filter.mouseUp(); filter.mouseDown(policy: p)
        expect(filter.pressure(stage: 2, targetPID: 0, policy: p, canFilter: true).shouldBlock, "Missing target uses the cached foreground PID")
        filter.mouseUp(); filter.mouseDown(policy: p)
        var own = p; own.frontmostPID = own.ownPID
        expect(!filter.pressure(stage: 2, targetPID: 0, policy: own, canFilter: true).eligibleInput, "Missing target in our foreground is excluded")
        expect(!filter.pressure(stage: 2, targetPID: own.ownPID, policy: p, canFilter: true).eligibleInput, "Our own pressure belongs to the local path")
        var overlay = p; overlay.overlayVisible = true
        expect(!filter.pressure(stage: 2, targetPID: 200, policy: overlay, canFilter: true).eligibleInput, "The separate overlay path excludes global pressure recognition")

        let rawBefore = filter.stats.rawGestureEvents
        filter.rawGesture(policy: p)
        filter.rawGesture(policy: paused)
        filter.rawGesture(policy: disabled)
        expect(filter.stats.rawGestureEvents == rawBefore + 1, "Raw counts honor paused and gesture-disabled state")

        var buffer = PressureEventBuffer<String>(capacity: 8, generation: 7)
        expect(buffer.append("down", kind: .mouseDown, generation: 7) == .appended, "Mouse down is queued")
        expect(buffer.append("stage1", kind: .pressure(stage: 1), generation: 7) == .appended, "Pressure stage one is queued")
        expect(buffer.append("stage2", kind: .pressure(stage: 2), generation: 7) == .appended, "Pressure stage two is queued")
        expect(buffer.append("stage0", kind: .pressure(stage: 0), generation: 7) == .appended, "Pressure zero is queued")
        expect(buffer.append("up", kind: .mouseUp, generation: 7) == .appended, "Fast release is queued")
        expect(buffer.take().map(\.payload) == ["down", "stage1", "stage2", "stage0", "up"], "Fast release preserves down, pressure boundaries, and up in original order")
        expect(buffer.isEmpty, "Draining empties the buffer")

        _ = buffer.append("move1", kind: .coalescible("tap.drag"), generation: 7)
        expect(buffer.append("move2", kind: .coalescible("tap.drag"), generation: 7) == .coalesced, "Adjacent movement combines")
        _ = buffer.append("pressure", kind: .pressure(stage: 2), generation: 7)
        _ = buffer.append("move3", kind: .coalescible("tap.drag"), generation: 7)
        _ = buffer.append("globalMove", kind: .coalescible("global.move"), generation: 7)
        expect(buffer.take().map(\.payload) == ["move2", "pressure", "move3", "globalMove"], "Coalescing cannot cross pressure boundaries or input sources")

        _ = buffer.append("late", kind: .mouseDown, generation: 7)
        buffer.reset(generation: 8)
        expect(buffer.isEmpty, "Restart clears pending old input")
        expect(buffer.append("old", kind: .pressure(stage: 2), generation: 7) == .stale, "Late callback from prior connection cannot enter the new generation")
        expect(buffer.isEmpty, "Late generations leave no queued event")
        _ = buffer.append("new", kind: .mouseDown, generation: 8)
        expect(buffer.take().map(\.payload) == ["new"], "Only the current generation is delivered")

        var small = PressureEventBuffer<String>(capacity: 3, generation: 1)
        for item in ["down", "stage1", "stage2"] {
            _ = small.append(item, kind: .other, generation: 1)
        }
        expect(small.append("up", kind: .mouseUp, generation: 1) == .overflow, "Critical events overflow explicitly instead of silently dropping a boundary")
        expect(small.count == 0, "Overflow invalidates the entire unfinished batch")
        filter.recordOverflow()
        small.replaceWithCancellation("cancel", generation: 1)
        expect(filter.awaitingFreshDown && !filter.blockedThisPress, "Overflow stops interception immediately")
        expect(filter.stats.overflows == 1, "Overflow is visible in statistics")
        expect(small.take().map(\.payload) == ["cancel"], "Cancellation replaces the invalid batch")
        expect(filter.pressure(stage: 2, targetPID: 200, policy: p, canFilter: true) == .init(), "Overflow cannot accidentally trigger a later stage of the same gesture")
        filter.mouseDown(policy: p)
        expect(filter.pressure(stage: 2, targetPID: 200, policy: p, canFilter: true).shouldBlock, "A new gesture recovers from overload")

        for generation in UInt64(10)..<UInt64(110) {
            buffer.reset(generation: generation)
            for stage in [0, 1, 2, 2, 1, 0] {
                _ = buffer.append("\(stage)", kind: .pressure(stage: stage), generation: generation)
            }
            let first = buffer.take(limit: 2).map(\.payload)
            let second = buffer.take(limit: 2).map(\.payload)
            let third = buffer.take(limit: 2).map(\.payload)
            expect(first + second + third == ["0", "1", "2", "2", "1", "0"], "Batching preserves pressure order across drain boundaries")
            expect(buffer.append("late", kind: .mouseUp, generation: generation - 1) == .stale, "Every reconnection rejects prior-generation release")
        }
        print("PressureInputManagerTests: \(assertions) assertions passed")
    }
}
