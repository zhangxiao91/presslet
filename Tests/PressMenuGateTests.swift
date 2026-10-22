import Foundation

@main
struct PressMenuGateTestRunner {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool,
                       _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        var gate = PressMenuGate()
        expect(gate.release(source: "verifiedGestureTap") == nil, "Release before deep does nothing")
        let invented = PressMenuTrigger(source: "verifiedGestureTap", appName: "Browser",
                                         bundleID: "example.browser", generation: 0)
        expect(!gate.isCurrent(invented), "An initial generation cannot authorize a trigger")

        gate.arm(source: "verifiedGestureTap", appName: "Browser", bundleID: "example.browser")
        expect(gate.release(source: "overlay") == nil, "A different source cannot consume the pending cycle")
        let first = gate.release(source: "verifiedGestureTap")!
        expect(first.source == "verifiedGestureTap", "Released source is retained")
        expect(first.appName == "Browser" && first.bundleID == "example.browser", "Origin identity is retained")
        expect(gate.isCurrent(first), "The released trigger can show its queued menu")
        expect(gate.release(source: "verifiedGestureTap") == nil, "Stage zero then mouse up cannot release twice")
        expect(gate.release(source: "overlay") == nil, "A foreign release cannot duplicate a finished cycle")
        expect(gate.isCurrent(first), "Duplicate release leaves the first queued trigger valid")

        gate.arm(source: "verifiedGestureTap", appName: "Editor", bundleID: "example.editor")
        expect(!gate.isCurrent(first), "A new deep cycle invalidates an old queued menu before release")
        let second = gate.release(source: "verifiedGestureTap")!
        expect(second.generation != first.generation, "Each arm advances the generation")
        expect(gate.isCurrent(second), "The new cycle can show its own menu")
        expect(!gate.isCurrent(first), "The old cycle stays invalid after the new release")
        let wrongIdentity = PressMenuTrigger(source: second.source, appName: "Wrong App",
                                             bundleID: second.bundleID, generation: second.generation)
        expect(!gate.isCurrent(wrongIdentity), "A generation does not authorize a different origin")
        let wrongSource = PressMenuTrigger(source: "overlay", appName: second.appName,
                                           bundleID: second.bundleID, generation: second.generation)
        expect(!gate.isCurrent(wrongSource), "A generation does not authorize a different input source")

        gate.arm(source: "overlay", appName: "Finder", bundleID: "com.apple.finder")
        gate.cancel()
        expect(gate.release(source: "overlay") == nil, "Cancel before up clears the pending trigger")
        expect(!gate.isCurrent(second), "Cancel also invalidates earlier queued triggers")
        gate.arm(source: "overlay", appName: "Finder", bundleID: "com.apple.finder")
        let third = gate.release(source: "overlay")!
        expect(gate.isCurrent(third), "Overlay follows the same release rule")
        gate.cancel()
        expect(!gate.isCurrent(third), "Cancel after release invalidates the queued trigger")
        expect(gate.release(source: "overlay") == nil, "Cancel after release does not rearm")
        gate.cancel()
        expect(!gate.isCurrent(third), "Repeated cancellation is harmless")

        gate.arm(source: "verifiedGestureTap", appName: "A", bundleID: "example.a")
        gate.arm(source: "overlay", appName: "B", bundleID: "example.b")
        expect(gate.release(source: "verifiedGestureTap") == nil, "A stale source cannot consume a replacement arm")
        let replacement = gate.release(source: "overlay")!
        expect(replacement.appName == "B", "Replacing an arm keeps the latest origin")
        expect(gate.isCurrent(replacement), "The replacement trigger remains valid")

        for index in 0..<100 {
            gate.arm(source: "verifiedGestureTap", appName: "App \(index)", bundleID: "example.\(index)")
            expect(!gate.isCurrent(replacement), "Repeated cycles keep older queued triggers invalid")
            expect(gate.release(source: "wrong") == nil, "Wrong-source releases never consume a real cycle")
            let current = gate.release(source: "verifiedGestureTap")!
            expect(gate.isCurrent(current), "Every independent cycle releases normally")
            expect(gate.release(source: "verifiedGestureTap") == nil, "Every cycle releases at most once")
        }
        print("PASS: \(assertions) press-menu gate assertions")
    }
}
