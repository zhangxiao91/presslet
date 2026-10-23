import CoreGraphics
import Foundation

@main
struct PressDragIsolationTestRunner {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let down = CGPoint(x: 120, y: 80)
        let selectedEnd = CGPoint(x: 145, y: 85)
        let menuEnd = CGPoint(x: 250, y: 125)
        var isolation = PressDragIsolation()

        expect(!isolation.isActive, "A new connection has no isolated mouse sequence")
        expect(isolation.activeTargetPID == nil, "An ordinary sequence has no isolated release target")
        expect(!isolation.begin(targetPID: 200), "Pressure without an observed down cannot take over")
        expect(!isolation.mouseDragged(at: menuEnd), "Unpaired drags pass through")
        expect(isolation.mouseUp() == nil, "Unpaired release passes through")

        isolation.mouseDown(at: down, targetPID: 200)
        expect(!isolation.mouseDragged(at: selectedEnd), "Ordinary text selection passes through before deep pressure")
        expect(!isolation.isActive, "Light pressure and ordinary dragging do not claim the sequence")
        expect(isolation.begin(targetPID: 200), "Deep pressure can claim the observed source")
        expect(isolation.isActive, "The sequence is isolated immediately at takeover")
        expect(isolation.activeTargetPID == 200, "The original application remains the release target")
        expect(!isolation.begin(targetPID: 200), "Repeated pressure cannot move the release point")
        for index in 0..<100 {
            expect(isolation.mouseDragged(at: CGPoint(x: menuEnd.x + CGFloat(index), y: menuEnd.y)),
                   "Every menu drag stays private")
        }
        expect(isolation.mouseUp() == selectedEnd, "Physical release completes at the last delivered pre-takeover drag")
        expect(!isolation.isActive, "Physical release ends isolation")
        expect(isolation.activeTargetPID == nil, "Physical release clears the target")
        expect(isolation.mouseUp() == nil, "Repeated release is never rewritten")
        expect(!isolation.begin(targetPID: 200), "A released press cannot be reclaimed")

        isolation.mouseDown(at: down, targetPID: 200)
        expect(!isolation.mouseDragged(at: menuEnd), "The next ordinary drag is unaffected")
        expect(isolation.mouseUp() == nil, "An ordinary drag preserves its actual release point")
        isolation.mouseDown(at: down, targetPID: 200)
        expect(!isolation.begin(targetPID: 300), "Another application cannot claim the observed down")
        expect(!isolation.isActive, "Source mismatch leaves ordinary input untouched")
        expect(isolation.begin(targetPID: 200), "A failed source match does not destroy the real source")
        expect(isolation.mouseUp() == down, "A stationary deep press pairs its release with its down")

        // Cancellation paths affect the menu/filter, not the physical sequence.
        // No reset API exists here, so all of them retain drag isolation.
        for reason in ["pause", "stop", "retry", "source change", "overflow", "tap timeout", "Escape"] {
            isolation.mouseDown(at: down, targetPID: 200)
            expect(isolation.begin(targetPID: 200), "Takeover starts before \(reason)")
            expect(isolation.mouseDragged(at: menuEnd), "\(reason) cannot leak the rest of the drag")
            expect(isolation.mouseUp() == down, "\(reason) still finishes the underlying mouse sequence")
            expect(!isolation.isActive, "\(reason) recovers after physical release")
        }

        isolation.mouseDown(at: down, targetPID: 200)
        isolation.begin(targetPID: 200)
        expect(isolation.mouseDown(at: selectedEnd, targetPID: 300), "Fresh down recovers an old sequence whose up was missed")
        expect(!isolation.isActive, "Recovered new click starts without isolation")
        expect(isolation.activeTargetPID == nil, "Recovery clears the previous release target")
        expect(!isolation.begin(targetPID: 200), "Old source cannot claim the new click")
        expect(isolation.begin(targetPID: 300), "New source can claim only its own new sequence")
        expect(isolation.activeTargetPID == 300, "The recovered sequence has its new source target")
        expect(isolation.mouseUp() == selectedEnd, "Recovered sequence uses the new click location")

        isolation.mouseDown(at: down, targetPID: 0)
        expect(!isolation.begin(targetPID: 0), "An unresolved source is not isolated")
        expect(!isolation.begin(targetPID: 200), "A later foreground value cannot claim an unresolved down")
        expect(isolation.mouseUp() == nil, "An unresolved sequence remains unchanged")
        isolation.mouseDown(at: CGPoint(x: CGFloat.nan, y: 2), targetPID: 200)
        expect(!isolation.begin(targetPID: 200), "Invalid coordinates never become a rewritten release")
        isolation.mouseDown(at: down, targetPID: 200)
        expect(!isolation.mouseDragged(at: CGPoint(x: 10, y: CGFloat.infinity)), "Invalid ordinary drag is not consumed")
        expect(isolation.begin(targetPID: 200), "Last finite position remains available")
        expect(isolation.mouseUp() == down, "A nonfinite drag cannot poison the release position")

        print("PressDragIsolation: \(assertions) assertions passed")
    }
}
